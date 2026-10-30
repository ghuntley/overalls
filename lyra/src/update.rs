use crate::config;
use crate::http;
use crate::log::{self, Event};
use fs2::FileExt;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_ARTIFACT_BYTES: usize = 100 * 1024 * 1024;
const GUEST_ORIGIN: &str = "https://llm.internal";

#[derive(Deserialize)]
struct Artifact {
    path: String,
    sha256: String,
    bytes: Option<usize>,
}
#[derive(Deserialize)]
struct Manifest {
    artifacts: std::collections::BTreeMap<String, Artifact>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Status {
    pub installed: String,
    pub staged: Option<String>,
    pub last_check: Option<String>,
    pub rejected: Option<String>,
    pub rejected_until_ms: Option<u64>,
    pub applied: Option<String>,
}

fn update_dir() -> io::Result<PathBuf> {
    let dir = config::state_dir()?.join("update");
    fs::create_dir_all(&dir)?;
    lyra::platform::restrict_directory(&dir)?;
    Ok(dir)
}

/// Open `path` for writing with a Unix creation mode (owner-only state 0600,
/// executables 0700); Windows files inherit the profile ACL.
fn create_with_mode(path: &Path, mode: u32, truncate: bool) -> io::Result<fs::File> {
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(truncate);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    #[cfg(not(unix))]
    let _ = mode;
    options.open(path)
}

// @cc [owner:ghuntley,label:recovery] lyra-update-lock-released-explicitly
// Every `.lock` holder MUST release the flock with LOCK_UN, not by closing its
// descriptor. The flock belongs to the open file description, which a process
// spawned by another thread duplicates until exec despite O_CLOEXEC; a close
// would let that copy keep the update lock after its holder finished.
struct UpdateGate(fs::File);

impl std::ops::Deref for UpdateGate {
    type Target = fs::File;
    fn deref(&self) -> &fs::File {
        &self.0
    }
}

impl Drop for UpdateGate {
    fn drop(&mut self) {
        // A no-op when this description never acquired the lock.
        let _ = FileExt::unlock(&self.0);
    }
}

fn lock(dir: &Path) -> io::Result<UpdateGate> {
    create_with_mode(&dir.join(".lock"), 0o600, false).map(UpdateGate)
}

fn read_status(dir: &Path) -> Status {
    fs::read(dir.join("status.json"))
        .ok()
        .filter(|v| v.len() < 4096)
        .and_then(|v| serde_json::from_slice(&v).ok())
        .unwrap_or_default()
}

fn write_status(dir: &Path, status: &Status) -> io::Result<()> {
    let temp = dir.join("status.tmp");
    let mut file = create_with_mode(&temp, 0o600, true)?;
    file.write_all(&serde_json::to_vec(status).map_err(io::Error::other)?)?;
    file.sync_all()?;
    drop(file);
    lyra::durable::rename(&temp, &dir.join("status.json"))
}

pub(crate) fn status() -> io::Result<Status> {
    Ok(read_status(&update_dir()?))
}

/// Continue this invocation in the binary at `path`: `exec` on Unix. Windows
/// has no `exec`, so the new binary runs as a child with inherited console
/// handles and this process exits with its status; only a failed spawn returns.
#[cfg(unix)]
fn reexec(path: &Path) -> io::Error {
    use std::os::unix::process::CommandExt;
    Command::new(path).args(env::args_os().skip(1)).exec()
}

#[cfg(windows)]
fn reexec(path: &Path) -> io::Error {
    match Command::new(path).args(env::args_os().skip(1)).status() {
        Ok(status) => std::process::exit(status.code().unwrap_or(1)),
        Err(error) => error,
    }
}

/// Mark a fresh executable owner-executable (0700) on Unix.
#[cfg_attr(
    not(unix),
    expect(
        clippy::unnecessary_wraps,
        reason = "only Unix sets permissions fallibly; callers share one signature"
    )
)]
fn make_executable(file: &fs::File) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o700))
    }
    #[cfg(not(unix))]
    {
        let _ = file;
        Ok(())
    }
}

fn digest_file(path: &Path) -> io::Result<String> {
    Ok(hex::encode(Sha256::digest(fs::read(path)?)))
}

pub(crate) fn current_digest() -> io::Result<String> {
    digest_file(&env::current_exe()?)
}

fn install_seed(executable: &Path, managed: &Path) -> io::Result<()> {
    if !managed.exists() {
        let parent = managed
            .parent()
            .ok_or_else(|| io::Error::other("missing parent"))?;
        fs::create_dir_all(parent)?;
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        let mut source = fs::File::open(executable)?;
        io::copy(&mut source, &mut temp)?;
        make_executable(temp.as_file())?;
        temp.as_file().sync_all()?;
        match temp.persist_noclobber(managed) {
            Ok(_) => {}
            Err(error) if error.error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.error),
        }
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:recovery] lyra-image-seed-and-next-run-update
/// Outside managed guests, immutable package binaries MUST delegate to a
/// user-owned copy without overwriting a newer copy. A staged verified desktop
/// binary may activate only on a later invocation and MUST be atomically
/// replaced before re-exec, provided the installed binary is still the one
/// from which the update was staged. Managed guests leave activation to the
/// seed supervisor.
pub(crate) fn startup() -> io::Result<()> {
    let executable = env::current_exe()?;
    let managed = config::managed_bin()?;
    if cfg!(windows) && executable == managed {
        // The binary a previous activation renamed aside (see `replace_running`).
        let _ = fs::remove_file(managed.with_extension("old"));
    }
    if executable != managed {
        install_seed(&executable, &managed)?;
        return Err(reexec(&managed));
    }
    if config::guest_root() {
        return Ok(());
    }
    let dir = update_dir()?;
    let gate = lock(&dir)?;
    if gate.try_lock_exclusive().is_ok() {
        if activate_staged_desktop_at(&managed, &dir)? {
            let _ = log::emit(Event::UpdateActivated, None);
            FileExt::unlock(&*gate)?;
            return Err(reexec(&managed));
        }
        FileExt::unlock(&*gate)?;
    }
    Ok(())
}

// @cc [owner:ghuntley,label:recovery] desktop-update-base-digest
// A pending desktop update MUST NOT replace a fresh installer copy or any
// binary whose digest differs from the one recorded when staging began.
fn activate_staged_desktop_at(managed: &Path, dir: &Path) -> io::Result<bool> {
    let pending = managed.with_extension("pending");
    if !pending.is_file() {
        return Ok(false);
    }
    let mut state = read_status(dir);
    let installed = digest_file(managed)?;
    let staged = digest_file(&pending).ok();
    if state.installed == installed
        && state.staged.as_deref() == staged.as_deref()
        && staged.is_some()
    {
        replace_running(&pending, managed)?;
        state.installed = state.staged.take().unwrap_or_default();
        write_status(dir, &state)?;
        return Ok(true);
    }
    fs::remove_file(&pending)?;
    state.installed = installed;
    state.staged = None;
    state.last_check = Some("invalid_staged".to_owned());
    write_status(dir, &state)?;
    let _ = log::emit(Event::UpdateFailed, None);
    Ok(false)
}

/// @cc [owner:ghuntley,label:recovery] windows-update-rename-aside
/// Replace the managed binary with the staged one. Unix renames over it. A
/// running Windows image cannot be replaced but can be renamed, so Windows
/// MUST first move the running binary aside to `<name>.old` and then move the
/// staged binary into place with a write-through rename; if the second step
/// fails the original MUST be moved back. `startup` deletes `<name>.old` on a
/// later run.
fn replace_running(pending: &Path, managed: &Path) -> io::Result<()> {
    if cfg!(windows) {
        let aside = managed.with_extension("old");
        let _ = fs::remove_file(&aside);
        lyra::durable::rename(managed, &aside)?;
        if let Err(error) = lyra::durable::rename(pending, managed) {
            let _ = lyra::durable::rename(&aside, managed);
            return Err(error);
        }
        Ok(())
    } else {
        fs::rename(pending, managed)
    }
}

pub(crate) fn spawn_check() -> io::Result<()> {
    let current = config::managed_bin()?;
    let mut child = Command::new(current);
    child
        .arg("__update-worker")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    detach(&mut child);
    child.spawn()?;
    Ok(())
}

/// Run the update worker outside this terminal session.
#[cfg(unix)]
fn detach(child: &mut Command) {
    use std::os::unix::process::CommandExt;
    let hook = || {
        // SAFETY: setsid takes no arguments and is async-signal-safe.
        if unsafe { libc::setsid() } < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    };
    // SAFETY: the hook runs between fork and exec and only calls the
    // async-signal-safe setsid and reads errno; it neither allocates nor locks.
    unsafe {
        child.pre_exec(hook);
    }
}

#[cfg(windows)]
fn detach(child: &mut Command) {
    use std::os::windows::process::CommandExt;
    // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
    child.creation_flags(0x0000_0008 | 0x0000_0200 | 0x0800_0000);
}

fn target() -> &'static str {
    platform_target(env::consts::OS, env::consts::ARCH)
}

/// The published artifact name for an operating system and architecture.
fn platform_target(os: &str, arch: &str) -> &'static str {
    match (os, arch) {
        ("linux", "x86_64") => "linux-amd64",
        ("linux", "aarch64") => "linux-arm64",
        ("macos", "x86_64") => "darwin-amd64",
        ("macos", "aarch64") => "darwin-arm64",
        ("windows", "x86_64") => "windows-amd64",
        _ => "unsupported",
    }
}

fn valid_artifact(artifact: &Artifact, prefix: &str, target: &str) -> bool {
    artifact.path == format!("{prefix}{target}")
        && artifact
            .bytes
            .is_none_or(|size| size > 0 && size <= MAX_ARTIFACT_BYTES)
        && artifact.sha256.len() == 64
        && artifact
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_download(content: &[u8], expected: &[u8]) -> bool {
    content.len() <= MAX_ARTIFACT_BYTES && Sha256::digest(content).as_slice() == expected
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |time| {
            u64::try_from(time.as_millis()).unwrap_or(u64::MAX)
        })
}

fn fetch(url: &str, maximum: usize, timeout: Duration) -> io::Result<Vec<u8>> {
    http::request(url, Method::GET, None, None, maximum, timeout)
}

fn work() -> io::Result<()> {
    let (origin, manifest_path, binary_prefix) = if config::guest_root() {
        (
            GUEST_ORIGIN.to_owned(),
            "/agent/v1/update/manifest.json",
            "/agent/v1/update/bin/",
        )
    } else {
        (config::load()?.origin, "/bin/manifest.json", "/bin/")
    };
    let dir = update_dir()?;
    let gate = lock(&dir)?;
    match gate.try_lock_exclusive() {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
        Err(error) => return Err(error),
    }
    let _ = log::emit(Event::UpdateStarted, None);
    let bytes = fetch(
        &format!("{origin}{manifest_path}"),
        16_384,
        Duration::from_secs(30),
    )?;
    if bytes.len() > 16384 {
        return Err(io::Error::other("manifest too large"));
    }
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    let artifact = manifest
        .artifacts
        .get(target())
        .ok_or_else(|| io::Error::other("missing target"))?;
    let expected = hex::decode(&artifact.sha256).map_err(io::Error::other)?;
    if expected.len() != 32 || !valid_artifact(artifact, binary_prefix, target()) {
        return Err(io::Error::other("invalid artifact"));
    }
    let managed = config::managed_bin()?;
    let mut status = read_status(&dir);
    status.installed = digest_file(&managed)?;
    let pending = managed.with_extension("pending");
    let verified_staged = status.staged.as_deref() == Some(&artifact.sha256)
        && digest_file(&pending).is_ok_and(|digest| digest == artifact.sha256);
    let rejected = status.rejected.as_deref() == Some(&artifact.sha256)
        && status
            .rejected_until_ms
            .is_some_and(|deadline| now_ms() < deadline);
    if status.installed == artifact.sha256 || verified_staged || rejected {
        if status.installed == artifact.sha256 && !verified_staged {
            status.staged = None;
            let _ = fs::remove_file(&pending);
        }
        status.last_check = Some(if rejected {
            "rejected".to_owned()
        } else {
            "current".to_owned()
        });
        return write_status(&dir, &status);
    }
    let content = fetch(
        &format!("{origin}{}", artifact.path),
        MAX_ARTIFACT_BYTES,
        Duration::from_mins(2),
    )?;
    if !valid_download(&content, &expected)
        || artifact.bytes.is_some_and(|size| size != content.len())
    {
        return Err(io::Error::other("invalid binary"));
    }
    let temp = managed.with_extension("download");
    let mut file = create_with_mode(&temp, 0o700, true)?;
    file.write_all(&content)?;
    file.sync_all()?;
    drop(file);
    lyra::durable::rename(&temp, &managed.with_extension("pending"))?;
    status.staged = Some(artifact.sha256.clone());
    status.last_check = Some("staged".to_owned());
    write_status(&dir, &status)?;
    FileExt::unlock(&*gate)?;
    let _ = log::emit(Event::UpdateStaged, None);
    Ok(())
}

fn activate_staged() -> io::Result<Option<String>> {
    let managed = config::managed_bin()?;
    let dir = update_dir()?;
    let activated = activate_staged_at(&managed, &dir)?;
    if activated.is_some() {
        let _ = log::emit(Event::UpdateActivated, None);
    }
    Ok(activated)
}

fn activate_staged_at(managed: &Path, dir: &Path) -> io::Result<Option<String>> {
    let gate = lock(dir)?;
    gate.lock_exclusive()?;
    let mut state = read_status(dir);
    let pending = managed.with_extension("pending");
    let Some(digest) = state.staged.clone() else {
        return Ok(None);
    };
    if digest_file(&pending).ok().as_deref() != Some(digest.as_str()) {
        state.staged = None;
        let _ = fs::remove_file(&pending);
        state.last_check = Some("invalid_staged".to_owned());
        write_status(dir, &state)?;
        return Ok(None);
    }
    let previous = managed.with_extension("previous");
    let previous_temp = managed.with_extension("previous.tmp");
    let _ = fs::remove_file(&previous_temp);
    fs::hard_link(managed, &previous_temp)?;
    fs::rename(&previous_temp, &previous)?;
    let parent = managed
        .parent()
        .ok_or_else(|| io::Error::other("missing parent"))?;
    fs::File::open(parent)?.sync_all()?;
    fs::rename(&pending, managed)?;
    fs::File::open(parent)?.sync_all()?;
    state.installed.clone_from(&digest);
    state.staged = None;
    write_status(dir, &state)?;
    Ok(Some(digest))
}

fn restore_previous(rejected: String) -> io::Result<()> {
    let managed = config::managed_bin()?;
    let dir = update_dir()?;
    restore_previous_at(&managed, &dir, rejected)?;
    let _ = log::emit(Event::UpdateRolledBack, None);
    Ok(())
}

fn restore_previous_at(managed: &Path, dir: &Path, rejected: String) -> io::Result<()> {
    let gate = lock(dir)?;
    gate.lock_exclusive()?;
    fs::rename(managed.with_extension("previous"), managed)?;
    fs::File::open(
        managed
            .parent()
            .ok_or_else(|| io::Error::other("missing parent"))?,
    )?
    .sync_all()?;
    let mut state = read_status(dir);
    state.installed = digest_file(managed)?;
    state.staged = None;
    state.rejected = Some(rejected);
    state.rejected_until_ms = Some(now_ms().saturating_add(900_000));
    state.applied = Some(state.installed.clone());
    state.last_check = Some("rolled_back".to_owned());
    write_status(dir, &state)?;
    Ok(())
}

fn mark_applied(digest: &str) -> io::Result<()> {
    let dir = update_dir()?;
    let gate = lock(&dir)?;
    gate.lock_exclusive()?;
    let mut state = read_status(&dir);
    state.applied = Some(digest.to_owned());
    write_status(&dir, &state)
}

fn spawn_executor() -> io::Result<std::process::Child> {
    let _ = fs::remove_file("/run/overalls-agent/ready");
    Command::new(config::managed_bin()?)
        .arg("agent-executor")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

fn spawn_guest_check() -> io::Result<std::process::Child> {
    Command::new(config::managed_bin()?)
        .arg("__update-worker")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

fn registered(child: &mut std::process::Child, digest: &str) -> io::Result<bool> {
    let deadline = Instant::now() + Duration::from_secs(90);
    while Instant::now() < deadline {
        if fs::read_to_string("/run/overalls-agent/ready").is_ok_and(|ready| ready == digest) {
            return Ok(true);
        }
        if child.try_wait()?.is_some() {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(500));
    }
    Ok(false)
}

/// @cc [owner:ghuntley,label:recovery] guest-candidate-start-failure
/// A failed spawn or unsuccessful registration result MUST restore the saved
/// executable before restarting; registration/status I/O errors still propagate.
/// A successfully registered candidate MUST retain its applied identity; later
/// semantic failures do not authorize rollback.
fn start_candidate(digest: &str) -> io::Result<std::process::Child> {
    if let Ok(mut candidate) = spawn_executor() {
        if registered(&mut candidate, digest)? {
            mark_applied(digest)?;
            return Ok(candidate);
        }
        let _ = candidate.kill();
        let _ = candidate.wait();
    }
    restore_previous(digest.to_owned())?;
    spawn_executor()
}

fn next_check() -> Instant {
    let jitter = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |time| u64::from(time.subsec_millis()) % 31);
    Instant::now() + Duration::from_secs(120 + jitter)
}

/// @cc [owner:ghuntley,label:recovery] guest-seed-supervisor
/// The immutable guest seed MUST keep the previous verified executable until
/// the candidate registers. Update activation MUST wait for the executor's
/// graceful exit between commands; a failed registration MUST restore the
/// previous executable before restarting the executor.
pub(crate) fn supervise() -> io::Result<i32> {
    if !config::guest_root() || env::current_exe()? == config::managed_bin()? {
        return Err(io::Error::other("not guest seed"));
    }
    fs::create_dir_all("/run/overalls-agent")?;
    let managed = config::managed_bin()?;
    let previous = managed.with_extension("previous");
    if !managed.exists() && previous.exists() {
        fs::rename(&previous, &managed)?;
    }
    install_seed(&env::current_exe()?, &managed)?;
    let dir = update_dir()?;
    let mut state = read_status(&dir);
    state.installed = digest_file(&managed)?;
    write_status(&dir, &state)?;
    let mut child =
        if previous.exists() && state.applied.as_deref() != Some(state.installed.as_str()) {
            start_candidate(&state.installed)?
        } else {
            spawn_executor()?
        };
    let mut due = Instant::now();
    let mut check: Option<std::process::Child> = None;
    loop {
        if child.try_wait()?.is_some() {
            child = spawn_executor()?;
        }
        if Instant::now() >= due && check.is_none() {
            check = Some(spawn_guest_check()?);
            due = next_check();
        }
        let check_finished = match check.as_mut() {
            Some(running) => running.try_wait()?.is_some(),
            None => false,
        };
        if check_finished {
            check = None;
            if read_status(&update_dir()?).staged.is_some() {
                fs::write("/run/overalls-agent/stop", b"")?;
                let deadline = Instant::now() + Duration::from_mins(1);
                while child.try_wait()?.is_none() && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(500));
                }
                let exited = child.try_wait()?.is_some();
                fs::remove_file("/run/overalls-agent/stop")?;
                if exited {
                    if let Some(digest) = activate_staged()? {
                        child = start_candidate(&digest)?;
                    }
                }
            }
        }
        thread::sleep(Duration::from_millis(500));
    }
}

// @cc [owner:ghuntley,label:recovery] lyra-failed-check-preserves-cooldown
// A failed update check (including a transient manifest fetch failure such as
// a closed 503 denial) MUST mark only last_check. It MUST NOT create, extend
// or clear the rejection cooldown, staged or applied identity: only a
// successful digest receipt followed by a failed candidate registration may
// reject an artifact.

// @cc [owner:ghuntley,label:recovery] lyra-failed-check-defers-to-lock-holder
// mark_failed MUST NOT block on the update lock. When `.lock` is held it MUST
// skip its write: the holder is a concurrent check or activation whose newer
// outcome supersedes this failure, and waiting would overwrite that outcome.
// Holders release explicitly (lyra-update-lock-released-explicitly), so a
// fork-inherited descriptor copy never makes mark_failed skip after release.
fn mark_failed(dir: &Path) {
    if let Ok(gate) = lock(dir) {
        if gate.try_lock_exclusive().is_ok() {
            let mut status = read_status(dir);
            status.last_check = Some("failed".to_owned());
            let _ = write_status(dir, &status);
        }
    }
}

pub(crate) fn worker() {
    if work().is_err() {
        let _ = log::emit(Event::UpdateFailed, None);
        if let Ok(dir) = update_dir() {
            mark_failed(&dir);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn published_targets_cover_windows_x86_64_only() {
        assert_eq!(platform_target("windows", "x86_64"), "windows-amd64");
        assert_eq!(platform_target("windows", "aarch64"), "unsupported");
        assert_eq!(platform_target("linux", "x86_64"), "linux-amd64");
        assert_eq!(platform_target("macos", "aarch64"), "darwin-arm64");
    }
    use hegel::{generators as gs, TestCase};

    #[hegel::test(test_cases = 100)]
    fn arbitrary_payload_requires_its_exact_digest(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let digest = Sha256::digest(&bytes);
        assert!(valid_download(&bytes, &digest));
        if !bytes.is_empty() {
            let mut altered = bytes.clone();
            altered[0] ^= 1;
            assert!(!valid_download(&altered, &digest));
        }
    }

    #[hegel::test(test_cases = 100)]
    fn artifact_path_and_hex_digest_are_closed(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let digest = hex::encode(Sha256::digest(&bytes));
        let valid = Artifact {
            path: "/agent/v1/update/bin/linux-amd64".to_owned(),
            sha256: digest.clone(),
            bytes: Some(bytes.len().max(1)),
        };
        assert!(valid_artifact(
            &valid,
            "/agent/v1/update/bin/",
            "linux-amd64"
        ));
        assert!(!valid_artifact(&valid, "/bin/", "linux-amd64"));
        let invalid = Artifact {
            path: valid.path,
            sha256: format!("A{}", digest.get(1..).unwrap()),
            bytes: valid.bytes,
        };
        assert!(!valid_artifact(
            &invalid,
            "/agent/v1/update/bin/",
            "linux-amd64"
        ));
    }

    #[test]
    fn public_artifact_path_uses_flat_bin_route() {
        let artifact = Artifact {
            path: "/bin/linux-amd64".to_owned(),
            sha256: "a".repeat(64),
            bytes: Some(1),
        };
        assert!(valid_artifact(&artifact, "/bin/", "linux-amd64"));
        assert!(!valid_artifact(&artifact, "/overalls/bin/", "linux-amd64"));
        assert!(!valid_artifact(
            &artifact,
            "/agent/v1/update/bin/",
            "linux-amd64"
        ));
    }

    #[test]
    fn size_limit_is_exact() {
        assert_eq!(MAX_ARTIFACT_BYTES, 104_857_600);
        assert!(!valid_download(&vec![0; MAX_ARTIFACT_BYTES + 1], &[0; 32]));
    }

    #[test]
    fn guest_check_interval_is_two_minutes_with_bounded_jitter() {
        let delay = next_check().duration_since(Instant::now());
        assert!(delay >= Duration::from_secs(119));
        assert!(delay <= Duration::from_secs(150));
    }

    #[hegel::test(test_cases = 100)]
    fn installer_replacement_cannot_be_downgraded_by_staged_update(tc: TestCase) {
        let mut fresh = tc.draw(gs::vecs(gs::integers::<u8>()));
        if fresh.is_empty() {
            fresh.push(1);
        }
        let dir = tempfile::tempdir().expect("test directory");
        let managed = dir.path().join("overalls");
        let old = b"previous installed CLI";
        let pending = b"previous staged CLI";
        fs::write(&managed, old).expect("old binary");
        fs::write(managed.with_extension("pending"), pending).expect("staged binary");
        write_status(
            dir.path(),
            &Status {
                installed: hex::encode(Sha256::digest(old)),
                staged: Some(hex::encode(Sha256::digest(pending))),
                ..Status::default()
            },
        )
        .expect("staged status");
        if fresh != old {
            fs::write(&managed, &fresh).expect("installer replacement");
            assert!(!activate_staged_desktop_at(&managed, dir.path()).expect("activation check"));
            assert_eq!(fs::read(&managed).expect("installed binary"), fresh);
            assert!(!managed.with_extension("pending").exists());
            assert_eq!(
                read_status(dir.path()).installed,
                digest_file(&managed).unwrap()
            );
        }
    }

    #[test]
    fn staged_desktop_update_activates_when_base_matches() {
        let dir = tempfile::tempdir().expect("test directory");
        let managed = dir.path().join("overalls");
        let old = b"previous installed CLI";
        let pending = b"new staged CLI";
        fs::write(&managed, old).unwrap();
        fs::write(managed.with_extension("pending"), pending).unwrap();
        write_status(
            dir.path(),
            &Status {
                installed: hex::encode(Sha256::digest(old)),
                staged: Some(hex::encode(Sha256::digest(pending))),
                ..Status::default()
            },
        )
        .unwrap();
        assert!(activate_staged_desktop_at(&managed, dir.path()).unwrap());
        assert_eq!(fs::read(&managed).unwrap(), pending);
        assert!(read_status(dir.path()).staged.is_none());
    }

    #[hegel::test(test_cases = 100)]
    fn staged_bytes_switch_once_and_restore_prior_binary(tc: TestCase) {
        let mut bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        if bytes.is_empty() {
            bytes.push(0);
        }
        let digest = hex::encode(Sha256::digest(&bytes));
        let dir = tempfile::tempdir().expect("test directory");
        let managed = dir.path().join("overalls");
        fs::write(&managed, b"previous binary").expect("old binary");
        fs::write(managed.with_extension("pending"), &bytes).expect("candidate binary");
        write_status(
            dir.path(),
            &Status {
                staged: Some(digest.clone()),
                ..Status::default()
            },
        )
        .expect("staged status");

        assert_eq!(
            activate_staged_at(&managed, dir.path()).expect("activation"),
            Some(digest.clone())
        );
        assert_eq!(fs::read(&managed).expect("managed binary"), bytes);
        assert_eq!(
            fs::read(managed.with_extension("previous")).expect("previous binary"),
            b"previous binary"
        );
        assert_eq!(
            activate_staged_at(&managed, dir.path()).expect("idempotent activation"),
            None
        );

        restore_previous_at(&managed, dir.path(), digest.clone()).expect("rollback");
        assert_eq!(
            fs::read(&managed).expect("restored binary"),
            b"previous binary"
        );
        assert_eq!(read_status(dir.path()).rejected, Some(digest));
    }

    #[hegel::test(test_cases = 100)]
    fn failed_checks_never_poison_cooldown_staging_or_identity(tc: TestCase) {
        let raw = tc.draw(gs::vecs(gs::integers::<u8>()));
        let bits = tc.draw(gs::integers::<u8>());
        let status = Status {
            installed: hex::encode(Sha256::digest(&raw)),
            staged: (bits & 1 != 0).then(|| hex::encode(Sha256::digest(b"staged"))),
            last_check: (bits & 2 != 0).then(|| "staged".to_owned()),
            rejected: (bits & 4 != 0).then(|| hex::encode(Sha256::digest(b"rejected"))),
            rejected_until_ms: (bits & 8 != 0).then_some(1_234_567_890_123u64),
            applied: (bits & 16 != 0).then(|| hex::encode(Sha256::digest(b"applied"))),
        };
        let dir = tempfile::tempdir().expect("test directory");
        write_status(dir.path(), &status).expect("seed status");
        mark_failed(dir.path());
        let after = read_status(dir.path());
        assert_eq!(after.last_check.as_deref(), Some("failed"));
        assert_eq!(after.staged, status.staged);
        assert_eq!(after.rejected, status.rejected);
        assert_eq!(after.rejected_until_ms, status.rejected_until_ms);
        assert_eq!(after.applied, status.applied);
        assert_eq!(after.installed, status.installed);
    }

    #[test]
    fn released_update_lock_ignores_surviving_descriptor_copies() {
        let dir = tempfile::tempdir().expect("test directory");
        write_status(
            dir.path(),
            &Status {
                last_check: Some("rolled_back".to_owned()),
                ..Status::default()
            },
        )
        .expect("seed status");
        let gate = lock(dir.path()).expect("update lock");
        gate.lock_exclusive().expect("held update lock");
        // A duplicate shares the open file description exactly as a forked
        // child's inherited descriptor does between fork and exec.
        let inherited = gate.try_clone().expect("duplicate descriptor");

        mark_failed(dir.path());
        assert_eq!(
            read_status(dir.path()).last_check.as_deref(),
            Some("rolled_back"),
            "mark_failed must skip rather than wait while the lock is held"
        );

        drop(gate);
        mark_failed(dir.path());
        assert_eq!(
            read_status(dir.path()).last_check.as_deref(),
            Some("failed"),
            "a released lock must not be held by a surviving descriptor copy"
        );
        drop(inherited);
    }

    #[test]
    fn failed_check_after_rollback_keeps_the_rejection_cooldown() {
        let digest = hex::encode(Sha256::digest(b"candidate binary"));
        let dir = tempfile::tempdir().expect("test directory");
        let managed = dir.path().join("overalls");
        fs::write(&managed, b"previous binary").expect("old binary");
        fs::write(managed.with_extension("pending"), b"candidate binary")
            .expect("candidate binary");
        write_status(
            dir.path(),
            &Status {
                staged: Some(digest.clone()),
                ..Status::default()
            },
        )
        .expect("staged status");
        assert_eq!(
            activate_staged_at(&managed, dir.path()).expect("activation"),
            Some(digest.clone())
        );
        restore_previous_at(&managed, dir.path(), digest.clone()).expect("rollback");
        let before = read_status(dir.path());
        assert_eq!(before.rejected.as_deref(), Some(digest.as_str()));
        let deadline = before.rejected_until_ms.expect("cooldown deadline");

        // Transient failures after a rollback (e.g. a closed 503 manifest
        // denial) must not move or extend that cooldown.
        mark_failed(dir.path());
        let after = read_status(dir.path());
        assert_eq!(after.last_check.as_deref(), Some("failed"));
        assert_eq!(after.rejected.as_deref(), Some(digest.as_str()));
        assert_eq!(after.rejected_until_ms, Some(deadline));
        assert_eq!(after.applied, before.applied);
    }

    #[hegel::test(test_cases = 100)]
    fn corrupt_staged_bytes_never_replace_installed_binary(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let dir = tempfile::tempdir().expect("test directory");
        let managed = dir.path().join("overalls");
        fs::write(&managed, b"installed binary").expect("installed binary");
        fs::write(managed.with_extension("pending"), &bytes).expect("candidate binary");
        write_status(
            dir.path(),
            &Status {
                staged: Some("0".repeat(64)),
                ..Status::default()
            },
        )
        .expect("staged status");
        if digest_file(&managed.with_extension("pending")).expect("digest") != "0".repeat(64) {
            assert_eq!(
                activate_staged_at(&managed, dir.path()).expect("invalid staging"),
                None
            );
            assert_eq!(
                fs::read(&managed).expect("installed binary"),
                b"installed binary"
            );
            assert!(read_status(dir.path()).staged.is_none());
        }
    }
}
