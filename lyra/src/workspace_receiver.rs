//! Boot-bound receipt and guest clone state for `overalls-workspaced` (ADR-0157).
//!
//! The binary owns vsock I/O and the kernel command line. Everything that
//! decides what is persisted, what is replied and which `git` argument vectors
//! run lives here so tests can drive it against a temporary root and a fake
//! git runner.
use crate::workspace_checkout::{self, Checkout, CheckoutRevision, ObjectFormat};
use crate::workspace_source::{self, WorkspaceSource};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Vsock port Lilly connects to on host CID 2.
pub const PORT: u32 = 1031;
/// Maximum request line, excluding its terminating newline.
pub const MAXIMUM_REQUEST: usize = 4096;
/// Maximum reply line, including its terminating newline.
pub const MAXIMUM_REPLY: usize = 512;

/// This kernel boot's identity from the Lilly command line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub placement_id: String,
    pub execution_epoch: u64,
    pub boot_challenge: String,
}

fn valid_hex(value: &str, size: usize) -> bool {
    value.len() == size && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_lower_hex(value: &str, size: usize) -> bool {
    value.len() == size
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

/// Parse the Lilly boot binding exactly as `overalls-trustd` does: the
/// `lilly.placement`, `lilly.execution_epoch` and `lilly.boot_challenge` keys,
/// each present once, a UUID placement, a positive epoch and a 64-hex challenge.
pub fn parse_binding(command_line: &str) -> io::Result<Binding> {
    if command_line.len() > 4096 {
        return Err(io::Error::other("invalid boot"));
    }
    let mut placement = None;
    let mut epoch = None;
    let mut challenge = None;
    for field in command_line.split_whitespace() {
        let (name, value) = field.split_once('=').unwrap_or((field, ""));
        let slot = match name {
            "lilly.placement" => &mut placement,
            "lilly.execution_epoch" => &mut epoch,
            "lilly.boot_challenge" => &mut challenge,
            _ => continue,
        };
        if slot.replace(value.to_owned()).is_some() {
            return Err(io::Error::other("invalid boot"));
        }
    }
    let placement_id = placement.ok_or_else(|| io::Error::other("invalid boot"))?;
    let execution_epoch = epoch
        .ok_or_else(|| io::Error::other("invalid boot"))?
        .parse::<u64>()
        .map_err(|_| io::Error::other("invalid boot"))?;
    let boot_challenge = challenge.ok_or_else(|| io::Error::other("invalid boot"))?;
    if !valid_uuid(&placement_id) || execution_epoch == 0 || !valid_hex(&boot_challenge, 64) {
        return Err(io::Error::other("invalid boot"));
    }
    Ok(Binding {
        placement_id,
        execution_epoch,
        boot_challenge,
    })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    placement_id: String,
    execution_epoch: u64,
    boot_challenge: String,
    nonce: String,
    source: Value,
}

/// A request that matched this boot and carried a valid source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Delivery {
    pub nonce: String,
    pub source: WorkspaceSource,
}

/// @cc [owner:ghuntley,label:security;protocol] guest-workspace-exact-boot
/// Only one bounded JSON line from host CID 2 whose version, placement,
/// execution epoch and boot challenge equal this kernel boot, with a 64-char
/// lowercase hex nonce, no unknown fields and a source the shared grammar
/// accepts, may be persisted or answered. Anything else closes without reply.
pub fn validate_request(line: &[u8], binding: &Binding) -> Result<Delivery, InvalidRequest> {
    if line.len() > MAXIMUM_REQUEST {
        return Err(InvalidRequest);
    }
    let request: Request = serde_json::from_slice(line).map_err(|_| InvalidRequest)?;
    if request.version != 1
        || request.placement_id != binding.placement_id
        || request.execution_epoch != binding.execution_epoch
        || request.boot_challenge != binding.boot_challenge
        || !valid_lower_hex(&request.nonce, 64)
    {
        return Err(InvalidRequest);
    }
    let source = workspace_source::decode(&request.source).map_err(|_| InvalidRequest)?;
    Ok(Delivery {
        nonce: request.nonce,
        source,
    })
}

/// A closed refusal without detail; the connection is dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidRequest;

/// The two reply states on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reply {
    Accepted,
    Conflict,
}

#[derive(Serialize)]
struct ReplyWire<'a> {
    version: u8,
    state: &'static str,
    placement_id: &'a str,
    execution_epoch: u64,
    boot_challenge: &'a str,
    nonce: &'a str,
}

/// Encode the one-line reply echoing the binding and nonce.
pub fn encode_reply(reply: Reply, binding: &Binding, nonce: &str) -> io::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(&ReplyWire {
        version: 1,
        state: match reply {
            Reply::Accepted => "accepted",
            Reply::Conflict => "conflict",
        },
        placement_id: &binding.placement_id,
        execution_epoch: binding.execution_epoch,
        boot_challenge: &binding.boot_challenge,
        nonce,
    })?;
    bytes.push(b'\n');
    if bytes.len() > MAXIMUM_REPLY {
        return Err(io::Error::other("reply too large"));
    }
    Ok(bytes)
}

/// Read one request line of at most [`MAXIMUM_REQUEST`] bytes (newline excluded).
pub fn read_request(stream: &mut impl Read) -> io::Result<Vec<u8>> {
    use std::io::BufRead;
    let limit = u64::try_from(MAXIMUM_REQUEST + 1).map_err(io::Error::other)?;
    let mut reader = io::BufReader::new(stream.take(limit));
    let mut line = Vec::with_capacity(1024);
    reader.read_until(b'\n', &mut line)?;
    if line.last() == Some(&b'\n') {
        line.pop();
    }
    if line.is_empty() || line.len() > MAXIMUM_REQUEST || line.contains(&b'\n') {
        return Err(io::Error::other("invalid request"));
    }
    Ok(line)
}

/// Answer one delivery on an accepted host connection: validate it against
/// this boot, persist it through `state` and write the bound reply. Both the
/// Linux and the Windows receiver use this; only the transport differs.
pub fn answer(
    stream: &mut (impl Read + Write),
    binding: &Binding,
    state: &Receiver,
) -> io::Result<(Decision, WorkspaceSource)> {
    let line = read_request(stream)?;
    let delivery =
        validate_request(&line, binding).map_err(|_| io::Error::other("invalid request"))?;
    let decision = state.deliver(&delivery.source)?;
    let reply = encode_reply(decision.reply, binding, &delivery.nonce)?;
    stream.write_all(&reply)?;
    stream.flush()?;
    Ok((decision, delivery.source))
}

/// Clone status published to login users.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Waiting,
    Cloning,
    Done,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Waiting => "waiting",
            Self::Cloning => "cloning",
            Self::Done => "done",
            Self::Failed => "failed",
        }
    }
}

/// Guest locations; production uses [`Paths::guest`], tests a temporary root.
#[derive(Clone, Debug)]
pub struct Paths {
    pub state: PathBuf,
    pub run: PathBuf,
    pub workspace: PathBuf,
}

impl Paths {
    pub fn guest() -> Self {
        Self::under(Path::new("/"))
    }

    /// Windows guest locations (ADR-0171): state and run markers under the
    /// agents' tree, checkouts under `C:\workspace`.
    pub fn windows() -> Self {
        Self {
            state: PathBuf::from(r"C:\overalls\workspace-state"),
            run: PathBuf::from(r"C:\overalls\run\workspace"),
            workspace: PathBuf::from(r"C:\workspace"),
        }
    }

    pub fn under(root: &Path) -> Self {
        Self {
            state: root.join("var/lib/overalls-workspace"),
            run: root.join("run/overalls-workspace"),
            workspace: root.join("workspace"),
        }
    }

    pub fn source(&self) -> PathBuf {
        self.state.join("source.json")
    }

    pub fn done(&self) -> PathBuf {
        self.state.join("done")
    }

    pub fn status(&self) -> PathBuf {
        self.run.join("status")
    }

    pub fn git_configuration(&self) -> PathBuf {
        self.run.join("gitconfig")
    }

    pub fn checkout(&self, source: &WorkspaceSource) -> PathBuf {
        self.workspace.join(source.repository())
    }

    pub fn partial(&self, source: &WorkspaceSource) -> PathBuf {
        self.workspace
            .join(format!(".{}.partial", source.repository()))
    }
}

/// Runs one `git` argument vector (without the program name).
pub trait GitRunner {
    fn run(&mut self, arguments: &[String]) -> io::Result<bool>;
    fn output(&mut self, _arguments: &[String]) -> io::Result<Vec<u8>> {
        Err(io::Error::other("git output unavailable"))
    }
    fn change_head(&mut self, _source: &WorkspaceSource) -> io::Result<Checkout> {
        Err(io::Error::other("change head unavailable"))
    }
}

/// Plain system `git` with a fixed environment; never a shell.
#[derive(Debug)]
pub struct SystemGit {
    pub program: PathBuf,
    pub ca_bundle: PathBuf,
    pub home: PathBuf,
    /// Native guests use a root-controlled system Git include for the exact
    /// shared checkout ownership exception. Other callers keep system config
    /// disabled so ambient host configuration cannot affect a checkout.
    pub system_configuration: Option<PathBuf>,
}

impl SystemGit {
    fn command(&self, arguments: &[String]) -> Command {
        let mut command = Command::new(&self.program);
        command
            .args(arguments)
            .env_clear()
            .env("HOME", &self.home)
            .env("LANG", "C")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_SSL_CAINFO", &self.ca_bundle)
            .env("SSL_CERT_FILE", &self.ca_bundle)
            .stdin(Stdio::null())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            // Keep the fixed system search path, while also making helpers
            // shipped beside a native guest's git executable discoverable.
            // FreeBSD installs git under /usr/local/bin; Linux and illumos
            // continue to resolve through their existing system directories.
            let mut path = std::ffi::OsString::new();
            if let Some(parent) = self.program.parent() {
                path.push(parent);
                path.push(":");
            }
            path.push("/run/current-system/sw/bin:/usr/bin:/bin");
            command
                .process_group(0)
                .env("PATH", path)
                .env("GIT_CONFIG_GLOBAL", "/dev/null");
            if let Some(configuration) = &self.system_configuration {
                command.env("GIT_CONFIG_SYSTEM", configuration);
            } else {
                command.env("GIT_CONFIG_NOSYSTEM", "1");
            }
        }
        #[cfg(windows)]
        {
            // Win32-OpenSSH and the CRT need the system root; Git for Windows finds its
            // helpers next to git.exe. Nothing from the caller's environment.
            let system_root =
                std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
            let mut path = std::ffi::OsString::new();
            if let Some(parent) = self.program.parent() {
                path.push(parent);
                path.push(";");
            }
            path.push(&system_root);
            path.push("\\System32;");
            path.push(&system_root);
            // Git for Windows defaults to schannel, which ignores GIT_SSL_CAINFO; the
            // OpenSSL backend trusts exactly the delivered bundle, as on Linux.
            command
                .env("PATH", path)
                .env("SystemRoot", &system_root)
                .env("TEMP", self.home.join("tmp"))
                .env("TMP", self.home.join("tmp"))
                .env("GIT_CONFIG_GLOBAL", "NUL")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_COUNT", "1")
                .env("GIT_CONFIG_KEY_0", "http.sslBackend")
                .env("GIT_CONFIG_VALUE_0", "openssl");
        }
        command
    }
}
/// The process tree one git invocation owns: its process group on Unix, a
/// kill-on-close Job Object on Windows.
#[cfg(unix)]
struct GitGroup(i32);
#[cfg(unix)]
impl GitGroup {
    fn attach(child: &std::process::Child) -> io::Result<Self> {
        i32::try_from(child.id())
            .map(Self)
            .map_err(|_| io::Error::other("invalid git process"))
    }

    fn kill(&self) {
        // SAFETY: command() creates our child's process group with its PID. The
        // positive validated PID identifies only the group owned by this invocation.
        unsafe {
            libc::killpg(self.0, libc::SIGKILL);
        }
    }
}
#[cfg(windows)]
struct GitGroup(crate::platform::windows::job::Job);
#[cfg(windows)]
impl GitGroup {
    fn attach(child: &std::process::Child) -> io::Result<Self> {
        crate::platform::windows::job::Job::attach(child).map(Self)
    }

    fn kill(&self) {
        self.0.terminate();
    }
}
impl SystemGit {
    /// @cc [owner:ghuntley,label:security;recovery] workspace-ref-output-bounded
    /// Advertised-ref capture MUST bound stdout to 1 MiB and cancel the entire
    /// owned git process group at its deadline or overflow before joining its
    /// pipe reader. HTTPS helpers MUST NOT retain a pipe beyond cancellation.
    #[doc(hidden)]
    pub fn output_with_timeout(
        &mut self,
        arguments: &[String],
        timeout: Duration,
    ) -> io::Result<Vec<u8>> {
        let started = std::time::Instant::now();
        let mut child = self.command(arguments).stdout(Stdio::piped()).spawn()?;
        let group = match GitGroup::attach(&child) {
            Ok(group) => group,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("git output unavailable"))?;
        let (sender, receiver) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = stdout
                .take(1_048_577)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = sender.send(result);
        });
        let output = receiver.recv_timeout(timeout);
        if !matches!(&output, Ok(Ok(bytes)) if bytes.len() <= 1_048_576) {
            group.kill();
        }
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if started.elapsed() >= timeout {
                group.kill();
                break child.wait()?;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let _ = reader.join();
        match output {
            Ok(Ok(bytes)) if bytes.len() <= 1_048_576 && status.success() => Ok(bytes),
            _ => Err(io::Error::other("git output unavailable")),
        }
    }
}
impl GitRunner for SystemGit {
    fn run(&mut self, arguments: &[String]) -> io::Result<bool> {
        Ok(self
            .command(arguments)
            .stdout(Stdio::null())
            .status()?
            .success())
    }
    fn output(&mut self, arguments: &[String]) -> io::Result<Vec<u8>> {
        self.output_with_timeout(arguments, Duration::from_secs(30))
    }
    fn change_head(&mut self, source: &WorkspaceSource) -> io::Result<Checkout> {
        workspace_checkout::fetch_head(source, &self.ca_bundle)
    }
}

/**
 * @cc [owner:ghuntley,label:security] guest-workspace-git-argv
 * Git MUST run as an argument vector without a shell. Every input-derived
 * value is a separate argument after a fixed option or `--`; URL and path
 * positionals always follow `--`, and the grammar forbids a leading "-".
 */
/**
 * @cc [owner:ghuntley,label:protocol] guest-workspace-object-format
 * Fetch-only checkouts MUST initialize the resolved Git object format, including
 * SHA256 full commit IDs and advertised refs. Clone paths negotiate with git.
 */
/// The exact git invocations for one clone attempt into `directory`.
///
/// Clones are shallow: branches and the default branch clone one commit, and a
/// full commit SHA or pull request is fetched alone into an empty repository
/// with the resolved object format. An abbreviated SHA cannot
/// be fetched by name, so it uses a blobless partial clone and resolves locally.
pub fn git_plan(target: &Checkout, directory: &Path) -> Vec<Vec<String>> {
    let url = target.url.clone();
    let directory = directory.to_string_lossy().into_owned();
    let owned = |values: &[&str]| {
        values
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>()
    };
    let clone = |options: &[&str]| {
        let mut arguments = owned(&["clone"]);
        arguments.extend(owned(options));
        arguments.extend(["--".to_owned(), url.clone(), directory.clone()]);
        arguments
    };
    let within = |rest: &[&str]| {
        let mut arguments = vec!["-C".to_owned(), directory.clone()];
        arguments.extend(owned(rest));
        arguments
    };
    let fetch_only = |refspec: String, checkout: String| {
        let mut init = vec!["init".to_owned()];
        if target.object_format == ObjectFormat::Sha256 {
            init.push("--object-format=sha256".to_owned());
        }
        init.extend(["--".to_owned(), directory.clone()]);
        vec![
            init,
            within(&["remote", "add", "--", "origin", &url]),
            within(&[
                "fetch",
                "--depth",
                "1",
                "--no-tags",
                "--",
                "origin",
                &refspec,
            ]),
            within(&["checkout", "--detach", &checkout, "--"]),
        ]
    };
    let mut plan = match &target.revision {
        CheckoutRevision::Ref(value) => fetch_only(value.clone(), "FETCH_HEAD".to_owned()),
        CheckoutRevision::Commit(value)
            if value.len() == 64
                || value.len() == 40 && target.object_format == ObjectFormat::Sha1 =>
        {
            fetch_only(value.clone(), value.clone())
        }
        CheckoutRevision::Commit(value) => vec![
            clone(&["--filter=blob:none", "--no-checkout"]),
            within(&["checkout", "--detach", value, "--"]),
        ],
        CheckoutRevision::Default => vec![clone(&["--depth", "1"])],
    };
    plan.push(within(&["config", "core.sharedRepository", "world"]));
    plan
}

/// Outcome of a delivery against persisted state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Decision {
    pub reply: Reply,
    /// True when the persisted source still needs a clone attempt.
    pub clone: bool,
}

/// Bounded retry schedule for clone attempts.
#[derive(Clone, Copy, Debug)]
pub struct Retry {
    pub attempts: u32,
    pub initial: Duration,
    pub maximum: Duration,
}

impl Retry {
    /// Ten attempts spread over roughly nine minutes while egress comes up.
    pub const GUEST: Self = Self {
        attempts: 10,
        initial: Duration::from_secs(5),
        maximum: Duration::from_secs(90),
    };

    pub fn delay(&self, attempt: u32) -> Duration {
        let factor = 1u32.checked_shl(attempt.min(16)).unwrap_or(u32::MAX);
        self.initial.saturating_mul(factor).min(self.maximum)
    }
}

/// Persistent receiver state rooted at [`Paths`].
#[derive(Debug)]
pub struct Receiver {
    paths: Paths,
    shared_git_configuration: bool,
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("invalid state path"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::other("invalid state path"))?;
    let temporary = parent.join(format!(".{}.next", name.to_string_lossy()));
    match fs::remove_file(&temporary) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(mode);
    let mut file = options.open(&temporary)?;
    set_mode(&file, mode)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    crate::durable::rename(&temporary, path)
}

fn directory(path: &Path, mode: u32) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid state directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir_all(path)?,
        Err(error) => return Err(error),
    }
    set_path_mode(path, mode)
}

/// POSIX mode of an open file; Windows files inherit their directory's ACL.
#[cfg(unix)]
fn set_mode(file: &File, mode: u32) -> io::Result<()> {
    file.set_permissions(fs::Permissions::from_mode(mode))
}
#[cfg(windows)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Windows files inherit their directory ACL; the Unix variant shares the signature"
)]
fn set_mode(_file: &File, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// POSIX mode of a path; Windows paths inherit their directory's ACL.
#[cfg(unix)]
fn set_path_mode(path: &Path, mode: u32) -> io::Result<()> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}
#[cfg(windows)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Windows paths inherit their directory ACL; the Unix variant shares the signature"
)]
fn set_path_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

fn remove_tree(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

impl Receiver {
    pub fn new(paths: Paths) -> io::Result<Self> {
        directory(&paths.state, 0o700)?;
        directory(&paths.run, 0o755)?;
        Ok(Self {
            paths,
            shared_git_configuration: false,
        })
    }

    /// Enable the native image's root-controlled system Git include.
    #[must_use]
    pub fn with_shared_git_configuration(mut self) -> Self {
        self.shared_git_configuration = true;
        self
    }

    /// @cc [owner:ghuntley,label:security;recovery] native-workspace-exact-git-ownership
    /// Native completion MUST publish one exact checkout ownership exception
    /// from the validated persisted source before Done, and restore it before
    /// publishing Done after a reboot. The include MUST remain outside the
    /// writable checkout in a daemon-owned non-writable runtime directory;
    /// checkout/parent links and group/other-writable configuration MUST refuse.
    /// The receiver's isolated Git environment MUST remain unchanged.
    fn publish_shared_git_configuration(&self, source: &WorkspaceSource) -> io::Result<()> {
        if !self.shared_git_configuration {
            return Ok(());
        }
        if self.persisted()?.as_ref() != Some(source) {
            return Err(io::Error::other("invalid shared checkout source"));
        }
        let checkout = self.paths.checkout(source);
        let checkout_metadata = fs::symlink_metadata(&checkout)?;
        let run_metadata = fs::symlink_metadata(&self.paths.run)?;
        if !checkout_metadata.file_type().is_dir()
            || !run_metadata.file_type().is_dir()
            || fs::canonicalize(&checkout)? != checkout
            || fs::canonicalize(&self.paths.run)? != self.paths.run
        {
            return Err(io::Error::other(
                "invalid shared checkout configuration path",
            ));
        }
        #[cfg(unix)]
        {
            // SAFETY: geteuid has no arguments or memory access requirements.
            let owner = unsafe { libc::geteuid() };
            if checkout_metadata.uid() != owner
                || run_metadata.uid() != owner
                || run_metadata.mode() & 0o022 != 0
            {
                return Err(io::Error::other(
                    "invalid shared checkout configuration owner",
                ));
            }
        }
        let path = self.paths.git_configuration();
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if !metadata.file_type().is_file() {
                    return Err(io::Error::other(
                        "invalid shared checkout configuration file",
                    ));
                }
                #[cfg(unix)]
                if metadata.uid() != run_metadata.uid() || metadata.mode() & 0o022 != 0 {
                    return Err(io::Error::other(
                        "invalid shared checkout configuration file",
                    ));
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let directory = checkout
            .to_str()
            .ok_or_else(|| io::Error::other("invalid shared checkout configuration path"))?
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\t', "\\t")
            .replace('\u{8}', "\\b");
        let configuration = format!("[safe]\n\tdirectory = \"{directory}\"\n");
        write_atomic(&path, configuration.as_bytes(), 0o644)
    }

    pub fn paths(&self) -> &Paths {
        &self.paths
    }

    /// Publish the world-readable status file (`/run/overalls-workspace/status`).
    pub fn publish(&self, status: Status) -> io::Result<()> {
        let mut bytes = status.as_str().as_bytes().to_vec();
        bytes.push(b'\n');
        write_atomic(&self.paths.status(), &bytes, 0o644)
    }

    pub fn done(&self) -> bool {
        fs::symlink_metadata(self.paths.done()).is_ok()
    }

    /// The persisted source, if any. A corrupt record is an error, never absence.
    pub fn persisted(&self) -> io::Result<Option<WorkspaceSource>> {
        let bytes = match fs::read(self.paths.source()) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        if bytes.len() > MAXIMUM_REQUEST {
            return Err(io::Error::other("invalid persisted source"));
        }
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|_| io::Error::other("invalid persisted source"))?;
        workspace_source::decode(&value)
            .map(Some)
            .map_err(|_| io::Error::other("invalid persisted source"))
    }

    /// Startup state: `done` wins, an undone persisted source resumes cloning,
    /// otherwise wait for Lilly.
    pub fn start(&self) -> io::Result<Option<WorkspaceSource>> {
        if self.shared_git_configuration {
            self.publish(Status::Waiting)?;
        }
        let persisted = self.persisted()?;
        if self.done() {
            if self.shared_git_configuration {
                self.publish_shared_git_configuration(
                    persisted
                        .as_ref()
                        .ok_or_else(|| io::Error::other("missing completed checkout source"))?,
                )?;
            }
            self.publish(Status::Done)?;
            return Ok(None);
        }
        if let Some(source) = persisted {
            self.publish(Status::Cloning)?;
            Ok(Some(source))
        } else {
            self.publish(Status::Waiting)?;
            Ok(None)
        }
    }

    /// @cc [owner:ghuntley,label:security;recovery] guest-workspace-source-once
    /// source.json MUST be written at most once, atomically (0600, fsync,
    /// rename, directory fsync) and before an accepted reply. An identical
    /// redelivery is accepted without rewriting; a different source is a
    /// conflict and never replaces the stored one. After `done` no delivery
    /// starts another clone.
    pub fn deliver(&self, source: &WorkspaceSource) -> io::Result<Decision> {
        match self.persisted()? {
            Some(existing) if existing == *source => Ok(Decision {
                reply: Reply::Accepted,
                clone: !self.done(),
            }),
            Some(_) => Ok(Decision {
                reply: Reply::Conflict,
                clone: false,
            }),
            None => {
                let bytes = serde_json::to_vec(&source.encode())?;
                write_atomic(&self.paths.source(), &bytes, 0o600)?;
                Ok(Decision {
                    reply: Reply::Accepted,
                    clone: !self.done(),
                })
            }
        }
    }

    /// One clone attempt; `Ok(true)` when the checkout is complete and `done` is written.
    pub fn attempt(&self, source: &WorkspaceSource, git: &mut impl GitRunner) -> io::Result<bool> {
        if self.done() {
            self.publish_shared_git_configuration(source)?;
            return Ok(true);
        }
        let workspace = &self.paths.workspace;
        match fs::symlink_metadata(workspace) {
            Ok(metadata) if metadata.file_type().is_dir() => {}
            Ok(_) => return Err(io::Error::other("invalid workspace")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                fs::create_dir_all(workspace)?;
                set_path_mode(workspace, 0o755)?;
            }
            Err(error) => return Err(error),
        }
        let checkout = self.paths.checkout(source);
        // A crash between rename and the done marker leaves a finished checkout.
        let finished = fs::symlink_metadata(&checkout).is_ok_and(|metadata| metadata.is_dir());
        if !finished {
            let partial = self.paths.partial(source);
            remove_tree(&partial)?;
            let target = workspace_checkout::resolve(source, git)?;
            for arguments in git_plan(&target, &partial) {
                if !git.run(&arguments)? {
                    remove_tree(&partial)?;
                    return Ok(false);
                }
            }
            if fs::symlink_metadata(&checkout).is_ok() {
                remove_tree(&partial)?;
                return Err(io::Error::other("checkout path occupied"));
            }
            share(&partial)?;
            crate::durable::rename(&partial, &checkout)?;
        }
        self.publish_shared_git_configuration(source)?;
        write_atomic(&self.paths.done(), b"done\n", 0o600)?;
        self.publish(Status::Done)?;
        Ok(true)
    }

    /// Bounded attempts; publishes `failed` when exhausted.
    pub fn clone_with_retry(
        &self,
        source: &WorkspaceSource,
        git: &mut impl GitRunner,
        retry: Retry,
        sleep: &mut impl FnMut(Duration),
        mut on_retry: impl FnMut(),
    ) -> io::Result<Status> {
        self.publish(Status::Cloning)?;
        for attempt in 0..retry.attempts {
            if attempt > 0 {
                on_retry();
                sleep(retry.delay(attempt - 1));
            }
            // A failed or erroring attempt is retried until the budget ends.
            if let Ok(true) = self.attempt(source, git) {
                return Ok(Status::Done);
            }
        }
        self.publish(Status::Failed)?;
        Ok(Status::Failed)
    }
}

/// @cc [owner:ghuntley,label:security;isolation] guest-workspace-shared-checkout
/// Every guest login account is a Cedar writer with passwordless sudo
/// (ADR-0110), so the checkout is a shared workspace, not a per-user boundary.
/// The root-owned checkout MUST be made writable by those accounts without
/// following symlinks from repository content: directories 0777, regular files
/// 0666 (0777 when executable). Native images MUST use the receiver's trusted
/// exact-path include for Git ownership; other images retain their reviewed
/// system ownership policy. Repository-owned config MUST NOT supply trust.
#[cfg(unix)]
fn share(root: &Path) -> io::Result<()> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(path) = pending.pop() {
        let metadata = fs::symlink_metadata(&path)?;
        let kind = metadata.file_type();
        if kind.is_symlink() {
            continue;
        }
        if kind.is_dir() {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o777))?;
            for entry in fs::read_dir(&path)? {
                pending.push(entry?.path());
            }
        } else if kind.is_file() {
            let executable = metadata.permissions().mode() & 0o111 != 0;
            let mode = if executable { 0o777 } else { 0o666 };
            fs::set_permissions(&path, fs::Permissions::from_mode(mode))?;
        }
    }
    Ok(())
}
/// Windows checkouts are shared through the workspace directory's ACL, which
/// the Windows workspace service sets once (gate 5); no per-file mode exists.
#[cfg(windows)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "the Windows service sets the workspace ACL once; the Unix variant shares the signature"
)]
fn share(_root: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binding() -> Binding {
        Binding {
            placement_id: "11111111-1111-4111-8111-111111111111".into(),
            execution_epoch: 3,
            boot_challenge: "a".repeat(64),
        }
    }

    #[test]
    fn binding_matches_trustd_command_line_shape() {
        let line = format!(
            "console=ttyS0 lilly.placement=11111111-1111-4111-8111-111111111111 lilly.execution_epoch=3 lilly.boot_challenge={}",
            "a".repeat(64)
        );
        assert_eq!(parse_binding(&line).ok(), Some(binding()));
        assert!(parse_binding(&format!("{line} lilly.execution_epoch=3")).is_err());
        assert!(parse_binding(&line.replace("epoch=3", "epoch=0")).is_err());
    }

    #[test]
    fn reply_is_one_bounded_line() {
        let bytes = encode_reply(Reply::Accepted, &binding(), &"b".repeat(64)).expect("reply");
        assert!(bytes.len() <= MAXIMUM_REPLY);
        assert_eq!(bytes.split(|byte| *byte == b'\n').count(), 2);
        let value: Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["state"], "accepted");
        assert_eq!(value["execution_epoch"], 3);
    }

    #[test]
    fn retry_delays_are_bounded() {
        let retry = Retry::GUEST;
        let total: Duration = (0..retry.attempts - 1)
            .map(|attempt| retry.delay(attempt))
            .sum();
        assert!(total <= Duration::from_mins(15));
        assert!(total >= Duration::from_mins(5));
    }

    #[test]
    fn obsolete_persisted_source_is_refused_even_after_done() {
        let root = tempfile::tempdir().unwrap();
        let receiver = Receiver::new(Paths::under(root.path())).unwrap();
        let old = br#"{"version":1,"host":"github.com","owner":"o","repo":"r","ref_kind":"default","ref":null}"#;
        fs::write(receiver.paths().source(), old).unwrap();
        fs::write(receiver.paths().done(), b"done\n").unwrap();
        assert!(receiver.start().is_err());
        assert_eq!(fs::read(receiver.paths().source()).unwrap(), old);
    }

    #[test]
    fn clone_plans_are_shallow_and_use_exact_resolved_refs() {
        let directory = Path::new("/workspace/.r.partial");
        for revision in [
            CheckoutRevision::Default,
            CheckoutRevision::Ref("refs/heads/feature/x".into()),
            CheckoutRevision::Commit("a".repeat(40)),
        ] {
            let target = Checkout {
                url: "https://github.com/o/r.git".into(),
                revision,
                object_format: ObjectFormat::Sha1,
            };
            let plan = git_plan(&target, directory);
            assert!(plan
                .iter()
                .any(|call| call.iter().any(|arg| arg == "--depth")));
            assert_eq!(plan.last().unwrap().last().unwrap(), "world");
            if matches!(target.revision, CheckoutRevision::Ref(_)) {
                assert!(plan
                    .iter()
                    .any(|call| call.iter().any(|arg| arg == "refs/heads/feature/x")));
                assert!(plan
                    .iter()
                    .any(|call| call.iter().any(|arg| arg == "FETCH_HEAD")));
            }
        }
    }
}
