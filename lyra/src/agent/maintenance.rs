//! Separate fenced maintenance: no conversation, arbitrary URL or shell command.
//! Artifacts are public source-built tools; the guest never receives OAuth data.
use super::{rpc, valid_identifier, AgentError, Host, LeaseRequest, ORIGIN};
use crate::{durable, http};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const POINTER_HEADER: &str = "# overalls-github-tools-v1 ";
const MAX_BINARY: usize = 100 * 1024 * 1024;
const NAMES: [&str; 3] = ["gh", "git-lfs", "github.gitconfig"];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Claim {
    maintenance: Option<Maintenance>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Maintenance {
    id: String,
    kind: String,
    generation: String,
    platform: String,
    files: Vec<Artifact>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Artifact {
    name: String,
    sha256: String,
    bytes: usize,
}

#[derive(Serialize)]
struct Transition<'a> {
    executor_id: &'a str,
    fence_epoch: u64,
    maintenance_id: &'a str,
    status: &'a str,
    result: Value,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Failure {
    InvalidArtifact,
    Activation,
    Interrupted,
    Unsupported,
}

impl Failure {
    fn code(self) -> &'static str {
        match self {
            Self::InvalidArtifact => "invalid_artifact",
            Self::Activation => "activation_failed",
            Self::Interrupted => "interrupted",
            Self::Unsupported => "unsupported",
        }
    }
}

fn platform() -> Option<&'static str> {
    if !cfg!(target_arch = "x86_64") {
        return None;
    }
    if cfg!(target_os = "linux") {
        Some("linux-amd64")
    } else if cfg!(windows) {
        Some("windows-amd64")
    } else if cfg!(target_os = "freebsd") {
        Some("freebsd-amd64")
    } else if cfg!(any(target_os = "illumos", target_os = "solaris")) {
        Some("illumos-amd64")
    } else {
        None
    }
}

fn root() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from("C:\\ProgramData\\Overalls\\GitHubTools")
    } else {
        PathBuf::from("/var/lib/overalls/github-tools")
    }
}

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid(job: &Maintenance) -> bool {
    valid_identifier(&job.id)
        && job.kind == "github-tools"
        && digest(&job.generation)
        && platform() == Some(job.platform.as_str())
        && job.files.len() == NAMES.len()
        && NAMES
            .iter()
            .all(|name| job.files.iter().filter(|file| file.name == *name).count() == 1)
        && job.files.iter().all(|file| {
            digest(&file.sha256)
                && file.bytes > 0
                && file.bytes
                    <= if file.name == "github.gitconfig" {
                        16_384
                    } else {
                        MAX_BINARY
                    }
        })
}

/// Closed native HTTPS allowlist; queries carry identifiers, never credentials.
pub(crate) fn artifact_url(url: &reqwest::Url) -> bool {
    let Some(tail) = url.path().strip_prefix("/agent/v1/maintenance/artifacts/") else {
        return false;
    };
    let pairs: Vec<_> = url.query_pairs().collect();
    url.scheme() == "https"
        && url.host_str() == Some("llm.internal")
        && url.port_or_known_default() == Some(443)
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
        && digest(tail)
        && pairs.len() == 3
        && ["executor_id", "maintenance_id", "fence_epoch"]
            .iter()
            .all(|key| pairs.iter().filter(|(name, _)| name == *key).count() == 1)
        && pairs.iter().all(|(name, value)| match name.as_ref() {
            "executor_id" | "maintenance_id" => valid_identifier(value),
            "fence_epoch" => value.parse::<u64>().is_ok_and(|epoch| epoch > 0),
            _ => false,
        })
}

fn transition(
    lease: &LeaseRequest<'_>,
    job: &Maintenance,
    status: &str,
    result: Value,
) -> Result<(), AgentError> {
    let _: Value = rpc(
        "maintenance/transition",
        &Transition {
            executor_id: lease.executor_id,
            fence_epoch: lease.fence_epoch,
            maintenance_id: &job.id,
            status,
            result,
        },
    )?;
    Ok(())
}

pub(super) fn poll(host: &impl Host, lease: &LeaseRequest<'_>) -> Result<bool, AgentError> {
    poll_observed(host, lease, &mut |_| {})
}

fn poll_observed(
    host: &impl Host,
    lease: &LeaseRequest<'_>,
    failed: &mut impl FnMut(super::RpcFailure),
) -> Result<bool, AgentError> {
    let claim: Claim = rpc("maintenance/claim", lease)?;
    let Some(job) = claim.maintenance else {
        return Ok(false);
    };
    if !valid(&job) {
        return Err(AgentError);
    }
    transition(lease, &job, "started", json!({}))?;
    let mut heartbeat_at = Instant::now();
    let mut authority = true;
    let mut heartbeat = || {
        if host.stop_requested() {
            authority = false;
        }
        if authority && heartbeat_at.elapsed() >= Duration::from_secs(2) {
            authority = super::rpc_observed::<Value, _>("heartbeat", lease, failed).is_ok();
            heartbeat_at = Instant::now();
        }
        authority
    };
    let result = install(
        &root(),
        &job,
        |artifact, destination| {
            let url = format!(
                "{ORIGIN}maintenance/artifacts/{}?executor_id={}&fence_epoch={}&maintenance_id={}",
                artifact.sha256, lease.executor_id, lease.fence_epoch, job.id
            );
            if !reqwest::Url::parse(&url).is_ok_and(|url| artifact_url(&url)) {
                return Err(Failure::InvalidArtifact);
            }
            http::download(&url, artifact.bytes, destination, &mut heartbeat)
                .map_err(|_| Failure::InvalidArtifact)
        },
        || transition(lease, &job, "started", json!({})).map_err(|_| Failure::Interrupted),
    );
    if !authority {
        return Err(AgentError);
    }
    let (status, outcome, previous) = match result {
        Ok((outcome, previous)) => ("completed", outcome, previous),
        Err(error) => ("failed", error.code(), None),
    };
    transition(
        lease,
        &job,
        status,
        json!({"generation": job.generation, "outcome": outcome, "previous_generation": previous}),
    )?;
    Ok(true)
}

fn file_name(name: &str) -> String {
    if cfg!(windows) && name != "github.gitconfig" {
        format!("{name}.exe")
    } else {
        name.to_owned()
    }
}

#[cfg_attr(
    not(unix),
    expect(
        clippy::unnecessary_wraps,
        reason = "only Unix sets permissions fallibly; callers share one signature"
    )
)]
fn mode(path: &Path, executable: bool) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if executable { 0o755 } else { 0o644 }),
        )?;
    }
    #[cfg(not(unix))]
    let _ = (path, executable);
    Ok(())
}

fn directory(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid has no preconditions and cannot fail.
        let euid = unsafe { libc::geteuid() };
        for ancestor in path.ancestors().skip(1) {
            match fs::symlink_metadata(ancestor) {
                Ok(metadata) => {
                    let bits = metadata.permissions().mode();
                    if !metadata.is_dir()
                        || metadata.file_type().is_symlink()
                        // The mounted namespace root is the trust anchor; its
                        // host UID may be unmapped in a Nix build namespace.
                        || (ancestor != Path::new("/")
                            && metadata.uid() != 0
                            && metadata.uid() != euid)
                        || (bits & 0o022 != 0 && !(metadata.uid() == 0 && bits & 0o1000 != 0))
                    {
                        return Err(io::Error::other("invalid tool ancestor"));
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
    }
    let missing: Vec<_> = path
        .ancestors()
        .filter(|ancestor| !ancestor.exists())
        .map(Path::to_path_buf)
        .collect();
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for created in missing {
            fs::set_permissions(created, fs::Permissions::from_mode(0o755))?;
        }
    }
    #[cfg(not(unix))]
    let _ = missing;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::other("invalid tool directory"));
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::other("invalid tool reparse point"));
        }
        windows_acl(path)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid has no preconditions and cannot fail.
        let euid = unsafe { libc::geteuid() };
        if metadata.uid() != euid {
            return Err(io::Error::other("invalid tool owner"));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

struct Gate(File);
impl Drop for Gate {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.0);
    }
}

fn verified(path: &Path, artifact: &Artifact) -> io::Result<bool> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() != artifact.bytes as u64
    {
        return Ok(false);
    }
    let mut source = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 65_536];
    loop {
        let bytes = source.read(&mut buffer)?;
        if bytes == 0 {
            break;
        }
        hash.update(&buffer[..bytes]);
    }
    Ok(hex::encode(hash.finalize()) == artifact.sha256)
}

fn pointer(root: &Path, generation: &str) -> Vec<u8> {
    let include = root
        .join("generations")
        .join(generation)
        .join("github.gitconfig")
        .to_string_lossy()
        .replace('\\', "/");
    format!("{POINTER_HEADER}{generation}\n[include]\n\tpath = \"{include}\"\n").into_bytes()
}

fn current(root: &Path) -> io::Result<Option<String>> {
    let path = root.join("activation.gitconfig");
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Ok(metadata)
            if metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.len() <= 4096 => {}
        _ => return Err(io::Error::other("invalid activation")),
    }
    let contents = fs::read(&path)?;
    let text =
        std::str::from_utf8(&contents).map_err(|_| io::Error::other("invalid activation"))?;
    let generation = text
        .lines()
        .next()
        .and_then(|line| line.strip_prefix(POINTER_HEADER))
        .filter(|value| digest(value))
        .ok_or_else(|| io::Error::other("invalid activation"))?;
    if contents != pointer(root, generation) {
        return Err(io::Error::other("invalid activation"));
    }
    Ok(Some(generation.to_owned()))
}

fn atomic(path: &Path, bytes: &[u8], executable: bool) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("invalid target"))?;
    let mut staged = tempfile::NamedTempFile::new_in(parent)?;
    staged.write_all(bytes)?;
    mode(staged.path(), executable)?;
    staged.as_file().sync_all()?;
    #[cfg(windows)]
    if executable && path.exists() {
        let aside = path.with_extension("overalls-old");
        let _ = fs::remove_file(&aside);
        durable::rename(path, &aside)?;
        if let Err(error) = durable::rename(staged.path(), path) {
            let _ = durable::rename(&aside, path);
            return Err(error);
        }
        return Ok(());
    }
    durable::rename(staged.path(), path)
}

// @cc [owner:ghuntley,label:security;recovery] github-tools-fenced-atomic-publication
// Every artifact MUST match its exact digest and byte count before publication.
// The current maintenance fence MUST be rechecked immediately before one durable
// activation-file rename. Failed health checks MUST restore the previous pointer.
fn install(
    root: &Path,
    job: &Maintenance,
    mut fetch: impl FnMut(&Artifact, &mut File) -> Result<usize, Failure>,
    mut fence: impl FnMut() -> Result<(), Failure>,
) -> Result<(&'static str, Option<String>), Failure> {
    if !valid(job) {
        return Err(Failure::Unsupported);
    }
    directory(root).map_err(|_| Failure::Activation)?;
    let gate_file = crate::platform::open_private(
        &root.join(".lock"),
        fs::OpenOptions::new().read(true).write(true).create(true),
    )
    .map_err(|_| Failure::Activation)?;
    let gate = Gate(gate_file);
    gate.0
        .try_lock_exclusive()
        .map_err(|_| Failure::Interrupted)?;
    #[cfg(not(test))]
    Setup::recover(root).map_err(|_| Failure::Activation)?;
    let previous = current(root).map_err(|_| Failure::Activation)?;
    let generations = root.join("generations");
    directory(&generations).map_err(|_| Failure::Activation)?;
    let target = generations.join(&job.generation);
    if !target.exists() {
        let staging = tempfile::tempdir_in(&generations).map_err(|_| Failure::Activation)?;
        let cache = root.join("artifacts");
        directory(&cache).map_err(|_| Failure::Activation)?;
        for artifact in &job.files {
            let cached = cache.join(&artifact.sha256);
            if !verified(&cached, artifact).unwrap_or(false) {
                let mut file =
                    tempfile::NamedTempFile::new_in(&cache).map_err(|_| Failure::Activation)?;
                let bytes = fetch(artifact, file.as_file_mut())?;
                file.as_file().sync_all().map_err(|_| Failure::Activation)?;
                if bytes != artifact.bytes
                    || !verified(file.path(), artifact).map_err(|_| Failure::InvalidArtifact)?
                {
                    return Err(Failure::InvalidArtifact);
                }
                mode(file.path(), artifact.name != "github.gitconfig")
                    .map_err(|_| Failure::Activation)?;
                durable::rename(file.path(), &cached).map_err(|_| Failure::Activation)?;
            }
            let path = staging.path().join(file_name(&artifact.name));
            fs::copy(&cached, &path).map_err(|_| Failure::Activation)?;
            File::open(&path)
                .and_then(|file| file.sync_all())
                .map_err(|_| Failure::Activation)?;
            mode(&path, artifact.name != "github.gitconfig").map_err(|_| Failure::Activation)?;
        }
        mode(staging.path(), true).map_err(|_| Failure::Activation)?;
        durable::rename(staging.path(), &target).map_err(|_| Failure::Activation)?;
    }
    for artifact in &job.files {
        if !verified(&target.join(file_name(&artifact.name)), artifact)
            .map_err(|_| Failure::InvalidArtifact)?
        {
            return Err(Failure::InvalidArtifact);
        }
    }
    if !health(&target) {
        return Ok(("rolled_back", previous));
    }
    fence()?;
    #[cfg(not(test))]
    let setup_guard = Setup::begin(root).map_err(|_| Failure::Activation)?;
    #[cfg(not(test))]
    if setup(root).is_err() {
        return Err(Failure::Activation);
    }
    fence()?;
    if previous.as_deref() == Some(job.generation.as_str()) {
        #[cfg(not(test))]
        setup_guard.commit().map_err(|_| Failure::Activation)?;
        #[cfg(all(target_os = "linux", not(test)))]
        reconcile_editor(root).map_err(|_| Failure::Activation)?;
        return Ok(("already_current", previous));
    }
    let activation = root.join("activation.gitconfig");
    let rollback = previous
        .as_ref()
        .map(|generation| pointer(root, generation));
    if let Some(bytes) = &rollback {
        atomic(&root.join("rollback.gitconfig"), bytes, false).map_err(|_| Failure::Activation)?;
    }
    atomic(&activation, &pointer(root, &job.generation), false).map_err(|_| Failure::Activation)?;
    if !health(&target) {
        match rollback {
            Some(bytes) => atomic(&activation, &bytes, false).map_err(|_| Failure::Activation)?,
            None => fs::remove_file(&activation).map_err(|_| Failure::Activation)?,
        }
        return Ok(("rolled_back", previous));
    }
    #[cfg(not(test))]
    setup_guard.commit().map_err(|_| Failure::Activation)?;
    #[cfg(all(target_os = "linux", not(test)))]
    reconcile_editor(root).map_err(|_| Failure::Activation)?;
    Ok(("installed", previous))
}

fn health(target: &Path) -> bool {
    for (name, argument) in [("gh", "--version"), ("git-lfs", "version")] {
        let Ok(mut child) = Command::new(target.join(file_name(name)))
            .arg(argument)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            return false;
        };
        let start = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => break,
                Ok(None) if start.elapsed() < Duration::from_secs(5) => {
                    std::thread::sleep(Duration::from_millis(25));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
            }
        }
    }
    true
}

/// Basename dispatch lets the existing verified executor act as a stable
/// launcher. It reads only the root-written public activation pointer.
pub fn run_tool() -> Option<i32> {
    let executable = std::env::current_exe().ok()?;
    let name = executable.file_stem()?.to_str()?;
    if name != "gh" && name != "git-lfs" {
        return None;
    }
    let root = root();
    let Some(generation) = current(&root).ok().flatten() else {
        return Some(127);
    };
    let target = root
        .join("generations")
        .join(generation)
        .join(file_name(name));
    let mut command = Command::new(target);
    command.args(std::env::args_os().skip(1));
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let _ = command.exec();
        Some(127)
    }
    #[cfg(not(unix))]
    {
        Some(
            command
                .status()
                .ok()
                .and_then(|status| status.code())
                .unwrap_or(127),
        )
    }
}

/// One-shot migration entrypoint for older executors. The existing executor's
/// exact lease remains authoritative; this path never registers another fence.
pub fn bootstrap_invocation() -> Option<i32> {
    struct Bootstrap;
    impl Host for Bootstrap {
        fn digest(&self) -> io::Result<String> {
            Err(io::Error::other("bootstrap does not register"))
        }
        fn tool_result(&self, _: &str, _: bool, _: Duration) {}
        fn fetch_event(&self, _: super::FetchEvent) {}
        fn stop_requested(&self) -> bool {
            false
        }
        fn ready(&self, _: &str) {}
    }
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    if arguments
        .first()
        .is_none_or(|value| value != "__github-tools-bootstrap")
    {
        return None;
    }
    if arguments.len() != 3 || !valid_identifier(&arguments[1]) {
        return Some(64);
    }
    let Ok(epoch) = arguments[2].parse::<u64>() else {
        return Some(64);
    };
    if epoch == 0 {
        return Some(64);
    }
    let lease = LeaseRequest {
        executor_id: &arguments[1],
        fence_epoch: epoch,
    };
    // Closed renewal diagnostics change only the nonzero exit category. They
    // never retry a refused request or authorize continued installation.
    let mut failure = None;
    Some(
        if reconcile().is_ok()
            && poll_observed(&Bootstrap, &lease, &mut |value| failure = Some(value)).is_ok()
        {
            0
        } else {
            failure.map_or(1, super::RpcFailure::diagnostic_code)
        },
    )
}

pub(super) fn reconcile() -> io::Result<()> {
    let root = root();
    Setup::recover(&root)?;
    if current(&root)?.is_some() {
        setup(&root)?;
        #[cfg(target_os = "linux")]
        reconcile_editor(&root)?;
    }
    Ok(())
}

fn system_gitconfig() -> &'static str {
    if cfg!(windows) {
        "C:\\Program Files\\Git\\etc\\gitconfig"
    } else if cfg!(target_os = "freebsd") {
        "/usr/local/etc/gitconfig"
    } else {
        "/etc/gitconfig"
    }
}

fn launcher(name: &str) -> PathBuf {
    if cfg!(windows) {
        if name == "gh" {
            PathBuf::from("C:\\Program Files\\GitHub CLI\\gh.exe")
        } else {
            PathBuf::from("C:\\Program Files\\Git\\mingw64\\bin\\git-lfs.exe")
        }
    } else {
        PathBuf::from("/usr/local/bin").join(name)
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SetupRecord {
    path: PathBuf,
    backup: Option<usize>,
    link: Option<PathBuf>,
    executable: bool,
}

/// A root-only recovery journal restores launcher/config originals if setup or
/// pointer publication is interrupted. It never contains OAuth or CLI stores.
struct Setup {
    journal: PathBuf,
    committed: bool,
}

impl Setup {
    fn targets() -> Vec<(PathBuf, bool)> {
        let paths = vec![
            (launcher("gh"), true),
            (launcher("git-lfs"), true),
            (PathBuf::from(system_gitconfig()), false),
        ];
        #[cfg(target_os = "linux")]
        if Path::new("/etc/NIXOS").exists() {
            return paths
                .into_iter()
                .chain([(PathBuf::from("/etc/profile.local"), false)])
                .collect();
        }
        paths
    }

    #[cfg(not(test))]
    fn begin(root: &Path) -> io::Result<Self> {
        Self::begin_at(root, Self::targets())
    }

    fn begin_at(root: &Path, targets: Vec<(PathBuf, bool)>) -> io::Result<Self> {
        let journal = root.join("setup-pending");
        fs::create_dir(&journal)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&journal, fs::Permissions::from_mode(0o700))?;
        }
        #[cfg(windows)]
        windows_acl_spec(&journal, "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")?;
        let mut records = Vec::new();
        for (index, (path, executable)) in targets.into_iter().enumerate() {
            let mut record = SetupRecord {
                path: path.clone(),
                backup: None,
                link: None,
                executable,
            };
            match fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    record.link = Some(fs::read_link(&path)?);
                }
                Ok(metadata) if metadata.is_file() => {
                    let backup = journal.join(index.to_string());
                    fs::copy(&path, &backup)?;
                    File::open(&backup)?.sync_all()?;
                    record.backup = Some(index);
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                _ => return Err(io::Error::other("invalid setup target")),
            }
            records.push(record);
        }
        let data = serde_json::to_vec(&records)?;
        atomic(&journal.join("journal.json"), &data, false)?;
        Ok(Self {
            journal,
            committed: false,
        })
    }

    fn recover(root: &Path) -> io::Result<()> {
        Self::recover_at(root, Self::targets())
    }

    fn recover_at(root: &Path, targets: Vec<(PathBuf, bool)>) -> io::Result<()> {
        let journal = root.join("setup-pending");
        if !journal.exists() {
            return Ok(());
        }
        let path = journal.join("journal.json");
        // Interrupted backup creation precedes all writes to installation paths.
        if !path.exists() {
            return fs::remove_dir_all(journal);
        }
        let records: Vec<SetupRecord> = serde_json::from_slice(&fs::read(path)?)?;
        if records.len() != targets.len()
            || records.iter().zip(targets).enumerate().any(
                |(index, (record, (path, executable)))| {
                    record.path != path
                        || record.executable != executable
                        || record.backup.is_some_and(|value| value != index)
                        || (record.backup.is_some() && record.link.is_some())
                },
            )
        {
            return Err(io::Error::other("invalid setup journal"));
        }
        for record in records {
            if let Some(index) = record.backup {
                atomic(
                    &record.path,
                    &fs::read(journal.join(index.to_string()))?,
                    record.executable,
                )?;
            } else if let Some(link) = record.link {
                let _ = fs::remove_file(&record.path);
                #[cfg(unix)]
                std::os::unix::fs::symlink(link, record.path)?;
                #[cfg(windows)]
                std::os::windows::fs::symlink_file(link, record.path)?;
            } else if record.path.exists() {
                fs::remove_file(record.path)?;
            }
        }
        fs::remove_dir_all(journal)
    }

    #[cfg(not(test))]
    fn commit(mut self) -> io::Result<()> {
        fs::remove_dir_all(&self.journal)?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for Setup {
    fn drop(&mut self) {
        if !self.committed {
            if let Some(root) = self.journal.parent() {
                let _ = Self::recover(root);
            }
        }
    }
}

/**
 * @cc [owner:ghuntley,label:security;recovery] retained-native-exact-workspace-trust
 * Native setup MUST replace the historical direct workspace wildcard Git ownership
 * exception only after validating immutable completed workspace source and its
 * exact owned checkout. The replacement MUST survive reboot, preserve unrelated
 * system Git settings, and remain covered by setup's configuration rollback.
 * Pending or corrupt persisted sources MUST refuse before removing the exception.
 * Without persisted source, setup MUST leave workspace policy unchanged so a
 * historical daemon can complete a later source delivery before a future repair.
 */
#[cfg(any(
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris",
    test
))]
fn native_workspace_policy(
    root: &Path,
    mut paths: crate::workspace_receiver::Paths,
    config: &Path,
    git: &Path,
) -> io::Result<()> {
    use crate::workspace_receiver::Receiver;
    // Historical workspaced cannot recreate a new /run policy on reboot. The
    // source is immutable, so retain its validated exact policy durably instead.
    paths.run = root.join("workspace-policy");
    let receiver = Receiver::new(paths.clone())?.with_shared_git_configuration();
    if receiver.persisted()?.is_none() {
        return Ok(());
    }
    if !receiver.done() {
        return Err(io::Error::other("workspace checkout incomplete"));
    }
    receiver.start()?;
    if config.exists() {
        let status = Command::new(git)
            .args(["config", "--file"])
            .arg(config)
            .args(["--unset-all", "safe.directory", r"^/workspace/\*$"])
            .env_clear()
            .env("PATH", "/usr/local/bin:/usr/bin:/bin")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        // Git uses 5 when the specified value is absent. Other errors withhold
        // activation; the enclosing Setup journal restores the original config.
        if !status.success() && status.code() != Some(5) {
            return Err(io::Error::other("workspace policy replacement failed"));
        }
    }
    let mut bytes = fs::read(config).or_else(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Ok(Vec::new())
        } else {
            Err(error)
        }
    })?;
    let include = format!(
        "\n[include]\n\tpath = \"{}\"\n",
        paths.git_configuration().to_string_lossy()
    );
    if !bytes
        .windows(include.len())
        .any(|part| part == include.as_bytes())
    {
        bytes.extend(include.as_bytes());
        atomic(config, &bytes, false)?;
    }
    Ok(())
}

fn setup(root: &Path) -> io::Result<()> {
    let source = fs::read(std::env::current_exe()?)?;
    for name in ["gh", "git-lfs"] {
        let target = launcher(name);
        directory(
            target
                .parent()
                .ok_or_else(|| io::Error::other("launcher parent"))?,
        )?;
        if fs::read(&target).ok().as_deref() != Some(source.as_slice()) {
            atomic(&target, &source, true)?;
        }
    }
    let config = Path::new(system_gitconfig());
    #[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
    native_workspace_policy(
        root,
        crate::workspace_receiver::Paths::guest(),
        config,
        Path::new(if cfg!(target_os = "freebsd") {
            "/usr/local/bin/git"
        } else {
            "/usr/bin/git"
        }),
    )?;
    let mut bytes = match fs::read(config) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    let include = format!(
        "\n[include]\n\tpath = \"{}\"\n",
        root.join("activation.gitconfig")
            .to_string_lossy()
            .replace('\\', "/")
    );
    if !bytes
        .windows(include.len())
        .any(|window| window == include.as_bytes())
    {
        if bytes.len() > 1_048_576 {
            return Err(io::Error::other("system Git config too large"));
        }
        bytes.extend(include.as_bytes());
        atomic(config, &bytes, false)?;
    }
    #[cfg(target_os = "linux")]
    if Path::new("/etc/NIXOS").exists() {
        let profile = Path::new("/etc/profile.local");
        let mut contents = fs::read(profile).unwrap_or_default();
        let line = b"\nexport PATH=/usr/local/bin:$PATH\n";
        if !contents.windows(line.len()).any(|window| window == line) {
            contents.extend(line);
            atomic(profile, &contents, false)?;
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct EditorDescriptor {
    protocol: u8,
    commit: String,
    release: String,
}

#[cfg(target_os = "linux")]
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct EditorConfiguration {
    descriptor: EditorDescriptor,
    editor_executable: PathBuf,
    systemd_run: PathBuf,
    systemctl: PathBuf,
    account_authorizer: PathBuf,
    worker_path: String,
}

#[cfg(target_os = "linux")]
fn systemctl(arguments: &[&str]) -> io::Result<Vec<u8>> {
    let mut child = Command::new("/run/current-system/sw/bin/systemctl")
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(None) if started.elapsed() < Duration::from_secs(3) => {
                std::thread::sleep(Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io::Error::other("editor reconciliation unavailable"));
            }
        }
    }
    let mut bytes = Vec::new();
    child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("editor output unavailable"))?
        .take(65_537)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 65_536 {
        return Err(io::Error::other("editor output too large"));
    }
    Ok(bytes)
}

// @cc [owner:ghuntley,label:recovery;security] github-retained-editor-tool-path
// Retained NixOS editors MUST receive the public managed launcher path without
// mutating Nix-store files or user homes. Only the current root broker's closed
// configuration may be copied to a root-owned runtime override. Existing worker
// units MAY be stopped for reconnection; no workspace data may be removed.
#[cfg(target_os = "linux")]
fn reconcile_editor(root: &Path) -> io::Result<()> {
    if !Path::new("/etc/NIXOS").exists() {
        return Ok(());
    }
    if !Path::new("/etc/systemd/system/overalls-vscode-web.service").exists()
        && !Path::new("/run/systemd/system/overalls-vscode-web.service").exists()
    {
        return Ok(());
    }
    let pid = systemctl(&[
        "show",
        "--property=MainPID",
        "--value",
        "overalls-vscode-web.service",
    ])?;
    let pid = std::str::from_utf8(&pid)
        .map_err(|_| io::Error::other("invalid editor pid"))?
        .trim();
    if pid == "0" || pid.is_empty() {
        return Ok(());
    }
    if pid.len() > 10 || !pid.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(io::Error::other("invalid editor pid"));
    }
    let command = fs::read(format!("/proc/{pid}/cmdline"))?;
    if command.len() > 8192 {
        return Err(io::Error::other("invalid editor command"));
    }
    let parts: Vec<_> = command
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .collect();
    if parts.len() != 2 {
        return Err(io::Error::other("invalid editor command"));
    }
    let executable =
        std::str::from_utf8(parts[0]).map_err(|_| io::Error::other("invalid editor executable"))?;
    let configuration = std::str::from_utf8(parts[1])
        .map_err(|_| io::Error::other("invalid editor configuration"))?;
    let installed = root.join("editor-broker.json");
    if !executable.starts_with("/nix/store/")
        || !executable.ends_with("/bin/overalls-vscode-web-broker")
        || Path::new(executable)
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
        || !(configuration.starts_with("/nix/store/") || Path::new(configuration) == installed)
    {
        return Err(io::Error::other("invalid editor custody"));
    }
    let contents = fs::read(configuration)?;
    if contents.len() > 16384 {
        return Err(io::Error::other("invalid editor configuration"));
    }
    let mut configuration: EditorConfiguration = serde_json::from_slice(&contents)?;
    if configuration.worker_path.split(':').next() == Some("/usr/local/bin") {
        return Ok(());
    }
    configuration.worker_path = format!("/usr/local/bin:{}", configuration.worker_path);
    atomic(&installed, &serde_json::to_vec(&configuration)?, false)?;
    let overrides = Path::new("/run/systemd/system/overalls-vscode-web.service.d");
    directory(overrides)?;
    let override_path = overrides.join("40-github-tools.conf");
    atomic(
        &override_path,
        format!(
            "[Service]\nExecStart=\nExecStart={executable} {}\n",
            installed.display()
        )
        .as_bytes(),
        false,
    )?;
    systemctl(&["daemon-reload"])?;
    // Fixed systemd glob selects only account worker services; the broker keeps
    // current account/boot authority and recreates workers on the next request.
    systemctl(&["--no-block", "stop", "overalls-vscode-u*.service"])?;
    systemctl(&["--no-block", "restart", "overalls-vscode-web.service"])?;
    Ok(())
}

#[cfg(windows)]
fn windows_acl(root: &Path) -> io::Result<()> {
    windows_acl_spec(
        root,
        "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)",
    )
}

#[cfg(windows)]
fn windows_acl_spec(root: &Path, descriptor_text: &str) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
    use windows_sys::Win32::Security::{
        SetFileSecurityW, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION,
    };
    let path: Vec<u16> = root.as_os_str().encode_wide().chain(Some(0)).collect();
    // Replace explicit inherited/user grants, and make SYSTEM the owner; merely
    // adding administrators' grants would leave a planted creator ACL intact.
    let sddl: Vec<u16> = descriptor_text.encode_utf16().chain(Some(0)).collect();
    let mut descriptor = std::ptr::null_mut();
    // SAFETY: the SDDL buffer is NUL terminated and outlives the call; on
    // success the function stores a LocalAlloc descriptor in `descriptor`.
    let converted = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &raw mut descriptor,
            std::ptr::null_mut(),
        )
    };
    if converted == 0 {
        return Err(io::Error::other("tool ACL unavailable"));
    }
    // SAFETY: the path buffer is NUL terminated and `descriptor` is the live
    // descriptor returned above; it is not freed until after this call.
    let success = unsafe {
        SetFileSecurityW(
            path.as_ptr(),
            OWNER_SECURITY_INFORMATION
                | DACL_SECURITY_INFORMATION
                | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        )
    };
    // SAFETY: `descriptor` came from LocalAlloc via the conversion above and
    // is released exactly once here.
    unsafe { LocalFree(descriptor) };
    if success == 0 {
        return Err(io::Error::other("tool ACL unavailable"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    #[test]
    #[cfg(unix)]
    fn retained_native_policy_is_exact_durable_and_preserves_unrelated_settings() {
        let guest = tempfile::tempdir().unwrap();
        let tools = tempfile::tempdir().unwrap();
        let paths = crate::workspace_receiver::Paths::under(guest.path());
        crate::workspace_receiver::Receiver::new(paths.clone()).unwrap();
        let config = guest.path().join("system.gitconfig");
        let original = b"[safe]\n\tdirectory = /workspace/*\n\tdirectory = /operator/kept\n[user]\n\tname = Preserved\n";
        fs::write(&config, original).unwrap();
        native_workspace_policy(
            tools.path(),
            paths.clone(),
            &config,
            Path::new("/unreachable/git"),
        )
        .unwrap();
        assert_eq!(fs::read(&config).unwrap(), original);
        assert!(!tools.path().join("workspace-policy/gitconfig").exists());
        // A historical daemon may deliver and finish the immutable source after
        // the first tools update. The next real setup then tightens its policy.
        fs::write(paths.source(), br#"{"version":2,"provider":"github","namespace":["owner"],"repository":"repo","revision":{"kind":"default"}}"#).unwrap();
        fs::write(paths.done(), b"done\n").unwrap();
        fs::create_dir_all(paths.workspace.join("repo")).unwrap();
        let git = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|directory| directory.join("git"))
            .find(|candidate| candidate.is_file())
            .unwrap();
        let journal = Setup::begin_at(tools.path(), vec![(config.clone(), false)]).unwrap();
        native_workspace_policy(tools.path(), paths.clone(), &config, &git).unwrap();
        let first = fs::read(&config).unwrap();
        native_workspace_policy(tools.path(), paths.clone(), &config, &git).unwrap();
        assert_eq!(fs::read(&config).unwrap(), first);
        let values = Command::new(&git)
            .args(["config", "--file"])
            .arg(&config)
            .args(["--includes", "--get-all", "safe.directory"])
            .output()
            .unwrap();
        assert!(values.status.success());
        let text = String::from_utf8(values.stdout).unwrap();
        assert_eq!(
            text.lines().collect::<Vec<_>>(),
            vec![
                "/operator/kept",
                paths.workspace.join("repo").to_str().unwrap()
            ]
        );
        assert!(String::from_utf8(first)
            .unwrap()
            .contains("name = Preserved"));
        fs::remove_dir_all(&paths.run).unwrap();
        assert!(tools.path().join("workspace-policy/gitconfig").is_file());
        #[expect(clippy::mem_forget, reason = "simulates process death that skips Drop")]
        std::mem::forget(journal);
        Setup::recover_at(tools.path(), vec![(config.clone(), false)]).unwrap();
        assert_eq!(fs::read(config).unwrap(), original);
    }

    #[test]
    #[cfg(unix)]
    fn retained_native_policy_refuses_pending_or_corrupt_source_before_config_changes() {
        let guest = tempfile::tempdir().unwrap();
        let tools = tempfile::tempdir().unwrap();
        let paths = crate::workspace_receiver::Paths::under(guest.path());
        crate::workspace_receiver::Receiver::new(paths.clone()).unwrap();
        let config = guest.path().join("system.gitconfig");
        let original = b"[safe]\n\tdirectory = /workspace/*\n";
        fs::write(&config, original).unwrap();
        for source in [br#"{"version":2,"provider":"github","namespace":["owner"],"repository":"repo","revision":{"kind":"default"}}"#.as_slice(), b"invalid"] {
            fs::write(paths.source(), source).unwrap();
            assert!(native_workspace_policy(tools.path(), paths.clone(), &config, Path::new("/unreachable/git")).is_err());
            assert_eq!(fs::read(&config).unwrap(), original);
        }
    }
    use std::collections::BTreeMap;

    fn fixture(seed: u64, succeeds: bool) -> (Maintenance, BTreeMap<String, Vec<u8>>) {
        let executable = format!(
            "#!/bin/sh\n# fixture {seed}\nexit {}\n",
            u8::from(!succeeds)
        )
        .into_bytes();
        let data = BTreeMap::from([
            ("gh".to_owned(), executable.clone()),
            ("git-lfs".to_owned(), executable),
            (
                "github.gitconfig".to_owned(),
                format!("# public fixture {seed}\n").into_bytes(),
            ),
        ]);
        let files = data
            .iter()
            .map(|(name, bytes)| Artifact {
                name: name.clone(),
                sha256: hex::encode(Sha256::digest(bytes)),
                bytes: bytes.len(),
            })
            .collect();
        (
            Maintenance {
                id: "11111111-1111-4111-8111-111111111111".to_owned(),
                kind: "github-tools".to_owned(),
                generation: hex::encode(Sha256::digest(format!("{seed}-{succeeds}"))),
                platform: platform().unwrap().to_owned(),
                files,
            },
            data,
        )
    }

    #[expect(
        clippy::unnecessary_wraps,
        reason = "matches the production fetch callback signature"
    )]
    fn fetch(
        data: &BTreeMap<String, Vec<u8>>,
        artifact: &Artifact,
        file: &mut File,
    ) -> Result<usize, Failure> {
        let bytes = &data[&artifact.name];
        file.write_all(bytes).unwrap();
        Ok(bytes.len())
    }

    #[test]
    fn claim_schema_refuses_unknown_fields_and_invalid_files() {
        assert!(
            serde_json::from_value::<Claim>(json!({"maintenance":null,"command":"arbitrary"}))
                .is_err()
        );
        let (mut job, _) = fixture(1, true);
        assert!(valid(&job));
        job.files[0].name = "../gh".to_owned();
        assert!(!valid(&job));
        let (mut job, _) = fixture(1, true);
        job.files[0].bytes = MAX_BINARY + 1;
        assert!(!valid(&job));
        let (mut job, _) = fixture(1, true);
        job.platform = "foreign-amd64".to_owned();
        assert!(!valid(&job));
    }

    #[test]
    fn exact_length_and_digest_are_required_before_activation() {
        for damage in ["short", "long", "digest"] {
            let root = tempfile::tempdir().unwrap();
            let (job, mut data) = fixture(1, true);
            match damage {
                "short" => {
                    data.get_mut("gh").unwrap().pop();
                }
                "long" => data.get_mut("gh").unwrap().push(0),
                _ => data.get_mut("gh").unwrap()[0] ^= 1,
            }
            assert_eq!(
                install(
                    root.path(),
                    &job,
                    |artifact, file| fetch(&data, artifact, file),
                    || Ok(())
                ),
                Err(Failure::InvalidArtifact)
            );
            assert_eq!(current(root.path()).unwrap(), None);
            assert_eq!(
                fs::read_dir(root.path().join("generations"))
                    .unwrap()
                    .count(),
                0
            );
        }
    }

    #[test]
    fn staged_crash_reconciles_without_refetch_and_failed_health_rolls_back() {
        let root = tempfile::tempdir().unwrap();
        let (first, data) = fixture(1, true);
        assert_eq!(
            install(
                root.path(),
                &first,
                |artifact, file| fetch(&data, artifact, file),
                || Err(Failure::Interrupted)
            ),
            Err(Failure::Interrupted)
        );
        assert_eq!(current(root.path()).unwrap(), None);
        assert_eq!(
            install(
                root.path(),
                &first,
                |_, _| panic!("complete immutable generation must be reused"),
                || Ok(())
            )
            .unwrap()
            .0,
            "installed"
        );
        let (second, data) = fixture(2, false);
        assert_eq!(
            install(
                root.path(),
                &second,
                |artifact, file| fetch(&data, artifact, file),
                || Ok(())
            )
            .unwrap()
            .0,
            "rolled_back"
        );
        assert_eq!(
            current(root.path()).unwrap(),
            Some(first.generation.clone())
        );
        assert_eq!(
            install(
                root.path(),
                &first,
                |_, _| panic!("duplicate must not refetch"),
                || Ok(())
            )
            .unwrap()
            .0,
            "already_current"
        );
    }

    #[test]
    fn activation_refuses_foreign_paths_extra_fields_and_links() {
        let root = tempfile::tempdir().unwrap();
        let generation = "a".repeat(64);
        for bytes in [
            pointer(Path::new("/foreign"), &generation),
            [
                pointer(root.path(), &generation),
                b"[credential]\nhelper = evil\n".to_vec(),
            ]
            .concat(),
        ] {
            fs::write(root.path().join("activation.gitconfig"), bytes).unwrap();
            assert!(current(root.path()).is_err());
        }
        #[cfg(unix)]
        {
            fs::remove_file(root.path().join("activation.gitconfig")).unwrap();
            fs::write(
                root.path().join("foreign"),
                pointer(root.path(), &generation),
            )
            .unwrap();
            std::os::unix::fs::symlink(
                root.path().join("foreign"),
                root.path().join("activation.gitconfig"),
            )
            .unwrap();
            assert!(current(root.path()).is_err());
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_maintenance_histories_preserve_last_healthy_generation(tc: TestCase) {
        let operations = tc.draw(gs::vecs(gs::integers::<u8>()));
        let root = tempfile::tempdir().unwrap();
        let mut model: Option<String> = None;
        for (index, operation) in operations.into_iter().take(12).enumerate() {
            let succeeds = operation % 4 != 3;
            let (job, mut data) = fixture(index as u64, succeeds);
            if operation % 4 == 1 {
                data.get_mut("gh").unwrap()[0] ^= 1;
            }
            let outcome = install(
                root.path(),
                &job,
                |artifact, file| fetch(&data, artifact, file),
                || {
                    if operation % 4 == 2 {
                        Err(Failure::Interrupted)
                    } else {
                        Ok(())
                    }
                },
            );
            match operation % 4 {
                0 => {
                    assert_eq!(outcome.unwrap().0, "installed");
                    model = Some(job.generation);
                }
                1 => assert_eq!(outcome, Err(Failure::InvalidArtifact)),
                2 => assert_eq!(outcome, Err(Failure::Interrupted)),
                _ => assert_eq!(outcome.unwrap().0, "rolled_back"),
            }
            assert_eq!(current(root.path()).unwrap(), model);
        }
    }

    #[hegel::test(test_cases = 100)]
    fn artifact_url_never_admits_a_foreign_origin_or_query(tc: TestCase) {
        let value = tc.draw(gs::integers::<u64>());
        let url = format!("https://llm.internal/agent/v1/maintenance/artifacts/{}?executor_id=11111111-1111-4111-8111-111111111111&maintenance_id=22222222-2222-4222-8222-222222222222&fence_epoch={}", "a".repeat(64), value.max(1));
        assert!(artifact_url(&reqwest::Url::parse(&url).unwrap()));
        for changed in [
            url.replace("https://", "http://"),
            url.replace("llm.internal", "llm.internal.evil"),
            format!("{url}&fence_epoch=1"),
            format!("{url}&token=secret"),
            url.replace("fence_epoch=", "other="),
        ] {
            assert!(!artifact_url(&reqwest::Url::parse(&changed).unwrap()));
        }
    }

    #[test]
    #[cfg(unix)]
    fn interrupted_setup_restores_original_regular_link_and_absent_targets() {
        let root = tempfile::tempdir().unwrap();
        let installation = tempfile::tempdir().unwrap();
        let regular = installation.path().join("gh");
        let link = installation.path().join("git-lfs");
        let absent = installation.path().join("gitconfig");
        fs::write(&regular, b"original-launcher").unwrap();
        std::os::unix::fs::symlink("original-target", &link).unwrap();
        let targets = vec![
            (regular.clone(), true),
            (link.clone(), true),
            (absent.clone(), false),
        ];
        let journal = Setup::begin_at(root.path(), targets.clone()).unwrap();
        #[expect(clippy::mem_forget, reason = "abrupt process death skips Drop")]
        std::mem::forget(journal);
        fs::write(&regular, b"interrupted-launcher").unwrap();
        fs::remove_file(&link).unwrap();
        fs::write(&link, b"interrupted-link-replacement").unwrap();
        fs::write(&absent, b"interrupted-configuration").unwrap();
        Setup::recover_at(root.path(), targets).unwrap();
        assert_eq!(fs::read(regular).unwrap(), b"original-launcher");
        assert_eq!(fs::read_link(link).unwrap(), Path::new("original-target"));
        assert!(!absent.exists());
        assert!(!root.path().join("setup-pending").exists());
    }

    #[test]
    #[cfg(unix)]
    fn setup_recovery_refuses_a_forged_destination_before_writing() {
        let root = tempfile::tempdir().unwrap();
        let installation = tempfile::tempdir().unwrap();
        let permitted = installation.path().join("gh");
        let foreign = installation.path().join("foreign");
        fs::write(&permitted, b"original-launcher").unwrap();
        fs::write(&foreign, b"foreign-preserved").unwrap();
        let targets = vec![(permitted, true)];
        let journal = Setup::begin_at(root.path(), targets.clone()).unwrap();
        #[expect(clippy::mem_forget, reason = "simulates process death that skips Drop")]
        std::mem::forget(journal);
        let path = root.path().join("setup-pending/journal.json");
        let mut records: Vec<SetupRecord> =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        records[0].path = foreign.clone();
        fs::write(path, serde_json::to_vec(&records).unwrap()).unwrap();
        assert!(Setup::recover_at(root.path(), targets).is_err());
        assert_eq!(fs::read(foreign).unwrap(), b"foreign-preserved");
        assert!(root.path().join("setup-pending").exists());
    }
}
