//! Gateway-only guest broker; worker process lifetime belongs to systemd.

use overalls_vscode_web_broker::{Binding, Boot, Descriptor, PORT, Refusal};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::fmt::Write as _;
use std::fs;
use std::io::{Read, Write};
use std::mem::{self, MaybeUninit};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant};

const MAX_CONNECTIONS: usize = 64;
const MAX_ACCOUNTS: usize = 512;
const STARTUP: Duration = Duration::from_secs(20);
const ROOT: &str = "/run/overalls-vscode";

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    descriptor: Descriptor,
    editor_executable: PathBuf,
    systemd_run: PathBuf,
    systemctl: PathBuf,
    account_authorizer: PathBuf,
    worker_path: String,
}

type AccountLocks = Mutex<BTreeMap<u32, Arc<Mutex<()>>>>;

struct Runtime {
    configuration: Configuration,
    boot: Boot,
    account_locks: AccountLocks,
    connections: AtomicUsize,
}

struct ConnectionGuard(Arc<Runtime>);

trait DeadlineSocket: Read {
    fn read_timeout(&self, timeout: Duration) -> std::io::Result<()>;
}

impl DeadlineSocket for TcpStream {
    fn read_timeout(&self, timeout: Duration) -> std::io::Result<()> {
        self.set_read_timeout(Some(timeout))
    }
}

impl DeadlineSocket for UnixStream {
    fn read_timeout(&self, timeout: Duration) -> std::io::Result<()> {
        self.set_read_timeout(Some(timeout))
    }
}

struct DeadlineReader<'a, S> {
    stream: &'a mut S,
    deadline: Instant,
}

impl<S: DeadlineSocket> Read for DeadlineReader<'_, S> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(std::io::ErrorKind::TimedOut.into());
        }
        self.stream.read_timeout(remaining)?;
        self.stream.read(buffer)
    }
}

fn lock_before<T>(mutex: &Mutex<T>, deadline: Instant) -> Result<MutexGuard<'_, T>, Refusal> {
    loop {
        match mutex.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(TryLockError::Poisoned(_)) => return Err(Refusal::Capacity),
            Err(TryLockError::WouldBlock) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(TryLockError::WouldBlock) => return Err(Refusal::Startup),
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.0.connections.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Clone, Copy)]
enum Event {
    Started,
    Refused,
    WorkerStarted,
    Ready,
    Lingered,
    LingerExpired,
    Failed,
}

fn emit(event: Event, reason: Option<Refusal>) {
    let event = match event {
        Event::Started => "editor.broker_started",
        Event::Refused => "editor.refused",
        Event::WorkerStarted => "editor.worker_started",
        Event::Ready => "editor.ready",
        Event::Lingered => "editor.lingered",
        Event::LingerExpired => "editor.linger_expired",
        Event::Failed => "editor.broker_failed",
    };
    if let Some(reason) = reason {
        eprintln!(
            "{{\"service\":\"overalls-vscode-web-broker\",\"event\":\"{event}\",\"reason\":\"{}\"}}",
            reason.name()
        );
    } else {
        eprintln!("{{\"service\":\"overalls-vscode-web-broker\",\"event\":\"{event}\"}}");
    }
}

fn emit_closed(ending: Ending) {
    let event = "editor.closed";
    eprintln!(
        "{{\"service\":\"overalls-vscode-web-broker\",\"event\":\"{event}\",\"reason\":\"{}\"}}",
        ending.name()
    );
}

fn read_configuration(path: &Path) -> Result<Configuration, Refusal> {
    let metadata = fs::symlink_metadata(path).map_err(|_| Refusal::Package)?;
    if !metadata.is_file()
        || metadata.len() > 8192
        || metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
    {
        return Err(Refusal::Package);
    }
    let bytes = fs::read(path).map_err(|_| Refusal::Package)?;
    let configuration: Configuration =
        serde_json::from_slice(&bytes).map_err(|_| Refusal::Package)?;
    configuration.descriptor.validate()?;
    for executable in [
        &configuration.editor_executable,
        &configuration.systemd_run,
        &configuration.systemctl,
        &configuration.account_authorizer,
    ] {
        if !executable.is_absolute() || !executable.is_file() {
            return Err(Refusal::Package);
        }
    }
    if configuration.worker_path.len() > 4096
        || configuration.worker_path.contains(['\0', '\r', '\n'])
    {
        return Err(Refusal::Package);
    }
    Ok(configuration)
}

/// @cc [owner:ghuntley,label:security] editor-current-passwd-identity
/// After account reconciliation, NSS MUST return this exact non-system UID,
/// same GID, name and /home/name directory. The home MUST be a real private
/// directory owned by that UID; caller strings cannot choose another home.
fn account(binding: &Binding) -> Result<PathBuf, Refusal> {
    let name = CString::new(binding.username.as_str()).map_err(|_| Refusal::Account)?;
    let mut record = MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = [0_i8; 16384];
    let mut result = std::ptr::null_mut();
    // The result's strings borrow this fixed buffer through the checks below.
    // SAFETY: `name` is NUL-terminated, `record` and `result` are valid writable out-pointers, and `buffer`/`buffer.len()` describe one live writable allocation that outlives every use of the returned strings.
    let status = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            record.as_mut_ptr(),
            buffer.as_mut_ptr(),
            buffer.len(),
            &raw mut result,
        )
    };
    if status != 0 || result.is_null() {
        return Err(Refusal::Account);
    }
    // SAFETY: getpwnam_r returned 0 with a non-null result, so it fully initialized `record`.
    let record = unsafe { record.assume_init() };
    if record.pw_name.is_null() || record.pw_dir.is_null() {
        return Err(Refusal::Account);
    }
    // SAFETY: `pw_name` is non-null and points to a NUL-terminated string inside `buffer`, which is still live.
    let actual_name = unsafe { CStr::from_ptr(record.pw_name) }
        .to_str()
        .map_err(|_| Refusal::Account)?;
    // SAFETY: `pw_dir` is non-null and points to a NUL-terminated string inside `buffer`, which is still live.
    let actual_home = unsafe { CStr::from_ptr(record.pw_dir) }
        .to_str()
        .map_err(|_| Refusal::Account)?;
    let home = PathBuf::from(format!("/home/{}", binding.username));
    if actual_name != binding.username
        || record.pw_uid != binding.uid
        || record.pw_gid != binding.uid
        || Path::new(actual_home) != home
    {
        return Err(Refusal::Account);
    }
    let metadata = fs::symlink_metadata(&home).map_err(|_| Refusal::Account)?;
    if !metadata.is_dir()
        || metadata.uid() != binding.uid
        || metadata.gid() != binding.uid
        || metadata.mode() & 0o777 != 0o700
    {
        return Err(Refusal::Account);
    }
    Ok(home)
}

fn command(program: &Path, arguments: &[String], deadline: Instant) -> Result<bool, Refusal> {
    let mut child = Command::new(program)
        .args(arguments)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| Refusal::Startup)?;
    loop {
        if let Some(status) = child.try_wait().map_err(|_| Refusal::Startup)? {
            return Ok(status.success());
        }
        if Instant::now() >= deadline {
            // The reconciler can launch subprocesses; kill its whole new group.
            // SAFETY: kill takes plain integers; the negated child PID names the process group that `process_group(0)` created.
            let _ = unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
            let _ = child.wait();
            return Err(Refusal::Startup);
        }
        thread::sleep(Duration::from_millis(20));
    }
}

const MAX_UNIT_METADATA: usize = 1024;

#[derive(Debug, PartialEq, Eq)]
enum WorkerUnit {
    Missing,
    Inactive,
    Live { description: String },
}

#[derive(Serialize)]
struct LaunchIdentity<'a> {
    uid: u32,
    username: &'a str,
    protocol: u8,
    commit: &'a str,
    release: &'a str,
    origin: &'a str,
}

fn launch_description(binding: &Binding) -> Result<String, Refusal> {
    let identity = LaunchIdentity {
        uid: binding.uid,
        username: &binding.username,
        protocol: binding.editor_protocol,
        commit: &binding.editor_commit,
        release: &binding.editor_release,
        origin: &binding.editor_origin,
    };
    let bytes = serde_json::to_vec(&identity).map_err(|_| Refusal::Startup)?;
    let digest = Sha256::digest(bytes)
        .iter()
        .fold(String::with_capacity(64), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        });
    Ok(format!("Overalls editor {digest}"))
}

fn parse_unit_metadata(bytes: &[u8]) -> Result<WorkerUnit, Refusal> {
    if bytes.len() > MAX_UNIT_METADATA {
        return Err(Refusal::Startup);
    }
    let output = std::str::from_utf8(bytes).map_err(|_| Refusal::Startup)?;
    let mut fields = BTreeMap::new();
    for line in output.lines() {
        let (key, value) = line.split_once('=').ok_or(Refusal::Startup)?;
        if !["LoadState", "ActiveState", "Description"].contains(&key)
            || fields.insert(key, value).is_some()
        {
            return Err(Refusal::Startup);
        }
    }
    let load = fields.get("LoadState").ok_or(Refusal::Startup)?;
    let active = fields.get("ActiveState").ok_or(Refusal::Startup)?;
    let description = fields.get("Description").ok_or(Refusal::Startup)?;
    match (*load, *active) {
        ("not-found", "inactive") => Ok(WorkerUnit::Missing),
        ("loaded", "inactive" | "failed") => Ok(WorkerUnit::Inactive),
        (
            "loaded",
            "active" | "reloading" | "refreshing" | "activating" | "deactivating" | "maintenance",
        ) => Ok(WorkerUnit::Live {
            description: (*description).to_owned(),
        }),
        _ => Err(Refusal::Startup),
    }
}

/// @cc [owner:ghuntley,label:security;recovery] editor-worker-launch-identity
/// Reuse MUST require the root systemd unit's exact origin and package launch
/// identity. Metadata failure MUST refuse admission without stopping a worker;
/// metadata output MUST remain bounded, private and within the startup deadline.
fn unit_metadata(
    program: &Path,
    arguments: &[String],
    deadline: Instant,
) -> Result<WorkerUnit, Refusal> {
    if Instant::now() >= deadline {
        return Err(Refusal::Startup);
    }
    let mut child = Command::new(program)
        .args(arguments)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| Refusal::Startup)?;
    let mut reaped = false;
    let result = (|| {
        let mut output = child.stdout.take().ok_or(Refusal::Startup)?;
        // SAFETY: F_GETFL on the child's open stdout descriptor, which `output` owns for this call.
        let flags = unsafe { libc::fcntl(output.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            // SAFETY: F_SETFL on the same owned open descriptor with flags just read from it.
            || unsafe { libc::fcntl(output.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(Refusal::Startup);
        }
        let mut bytes = Vec::with_capacity(MAX_UNIT_METADATA);
        let mut buffer = [0_u8; 256];
        let mut ended = false;
        loop {
            if Instant::now() >= deadline {
                return Err(Refusal::Startup);
            }
            while !ended {
                match output.read(&mut buffer) {
                    Ok(0) => ended = true,
                    Ok(length) if bytes.len() + length <= MAX_UNIT_METADATA => {
                        bytes.extend_from_slice(&buffer[..length]);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Ok(_) | Err(_) => return Err(Refusal::Startup),
                }
            }
            // Keep the leader unreaped while a descendant retains stdout, so
            // deadline cleanup cannot signal a reused process-group identity.
            if ended && let Some(status) = child.try_wait().map_err(|_| Refusal::Startup)? {
                reaped = true;
                if !status.success() {
                    return Err(Refusal::Startup);
                }
                return parse_unit_metadata(&bytes);
            }
            thread::sleep(Duration::from_millis(10));
        }
    })();
    if result.is_err() && !reaped {
        // SAFETY: kill takes plain integers; the negated child PID names the process group that `process_group(0)` created.
        let _ = unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
        let _ = child.wait();
    }
    result
}

fn runtime_directory(uid: u32) -> Result<PathBuf, Refusal> {
    let root = fs::symlink_metadata(ROOT).map_err(|_| Refusal::Custody)?;
    if !root.is_dir() || root.uid() != 0 || root.mode() & 0o777 != 0o711 {
        return Err(Refusal::Custody);
    }
    let path = Path::new(ROOT).join(format!("u{uid}"));
    match fs::create_dir(&path) {
        Ok(()) => {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .map_err(|_| Refusal::Custody)?;
            let encoded =
                CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| Refusal::Custody)?;
            // SAFETY: `encoded` is a live NUL-terminated path; chown does not retain the pointer.
            if unsafe { libc::chown(encoded.as_ptr(), uid, uid) } != 0 {
                return Err(Refusal::Custody);
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err(Refusal::Custody),
    }
    let metadata = fs::symlink_metadata(&path).map_err(|_| Refusal::Custody)?;
    if !metadata.is_dir()
        || metadata.uid() != uid
        || metadata.gid() != uid
        || metadata.mode() & 0o777 != 0o700
    {
        return Err(Refusal::Custody);
    }
    Ok(path)
}

fn socket_custody(path: &Path, uid: u32) -> Result<(), Refusal> {
    use std::os::unix::fs::FileTypeExt;
    let metadata = fs::symlink_metadata(path).map_err(|_| Refusal::Readiness)?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != uid
        || metadata.mode() & 0o777 != 0o600
    {
        return Err(Refusal::Custody);
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] editor-unix-kernel-peer
/// Every connected socket MUST independently prove its server's expected UID
/// through `SO_PEERCRED`; pathname ownership alone MUST NOT authorize forwarding.
fn connect(path: &Path, uid: u32, deadline: Instant) -> Result<UnixStream, Refusal> {
    socket_custody(path, uid)?;
    // SAFETY: sockaddr_un is a plain C struct for which all-zero bytes are a valid value.
    let mut address = unsafe { mem::zeroed::<libc::sockaddr_un>() };
    #[expect(clippy::cast_possible_truncation, reason = "AF_UNIX is the constant 1")]
    let family = libc::AF_UNIX as libc::sa_family_t;
    address.sun_family = family;
    let path = path.as_os_str().as_encoded_bytes();
    if path.is_empty() || path.len() >= address.sun_path.len() || path.contains(&0) {
        return Err(Refusal::Custody);
    }
    for (destination, source) in address.sun_path.iter_mut().zip(path) {
        *destination = libc::c_char::from_ne_bytes([*source]);
    }
    // SAFETY: socket takes only integer arguments and returns a new descriptor or -1.
    let raw = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if raw < 0 {
        return Err(Refusal::Readiness);
    }
    // SAFETY: `raw` is a freshly created, non-negative descriptor that nothing else owns.
    let descriptor = unsafe { OwnedFd::from_raw_fd(raw) };
    let address_length = libc::socklen_t::try_from(size_of::<libc::sockaddr_un>())
        .map_err(|_| Refusal::Readiness)?;
    // SAFETY: the descriptor is open and owned, and `address` is a live initialized sockaddr_un whose exact size is passed.
    let status = unsafe {
        libc::connect(
            descriptor.as_raw_fd(),
            (&raw const address).cast(),
            address_length,
        )
    };
    if status != 0 {
        let error = std::io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(libc::EINPROGRESS | libc::EAGAIN)) {
            return Err(Refusal::Readiness);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Refusal::Readiness);
        }
        let mut poll = libc::pollfd {
            fd: descriptor.as_raw_fd(),
            events: libc::POLLOUT,
            revents: 0,
        };
        let milliseconds = i32::try_from(remaining.as_millis().max(1)).unwrap_or(i32::MAX);
        // SAFETY: `poll` is one live pollfd and the count is 1.
        if unsafe { libc::poll(&raw mut poll, 1, milliseconds) } <= 0 {
            return Err(Refusal::Readiness);
        }
        let mut error = 0_i32;
        let mut length =
            libc::socklen_t::try_from(size_of::<i32>()).map_err(|_| Refusal::Readiness)?;
        // SAFETY: `error` and `length` are live writable locals and `length` holds the size of `error`.
        if unsafe {
            libc::getsockopt(
                descriptor.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                (&raw mut error).cast(),
                &raw mut length,
            )
        } != 0
            || error != 0
        {
            return Err(Refusal::Readiness);
        }
    }
    let stream = UnixStream::from(descriptor);
    stream
        .set_nonblocking(false)
        .map_err(|_| Refusal::Readiness)?;
    check_peer(&stream, uid)?;
    Ok(stream)
}

fn check_peer(stream: &UnixStream, uid: u32) -> Result<(), Refusal> {
    let mut peer = MaybeUninit::<libc::ucred>::uninit();
    let mut length =
        libc::socklen_t::try_from(size_of::<libc::ucred>()).map_err(|_| Refusal::Custody)?;
    // SAFETY: `peer` is writable storage for one ucred and `length` holds its size; the descriptor is borrowed from the live stream.
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            peer.as_mut_ptr().cast(),
            &raw mut length,
        )
    } != 0
        || length as usize != size_of::<libc::ucred>()
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: getsockopt succeeded and reported exactly size_of::<ucred>() bytes, so `peer` is initialized.
    let peer = unsafe { peer.assume_init() };
    if peer.uid != uid || peer.pid <= 0 {
        return Err(Refusal::Custody);
    }
    Ok(())
}

fn probe(path: &Path, binding: &Binding, deadline: Instant) -> Result<(), Refusal> {
    let mut stream = connect(path, binding.uid, deadline)?;
    let probe_deadline = deadline.min(Instant::now() + Duration::from_secs(2));
    let timeout = probe_deadline.saturating_duration_since(Instant::now());
    if timeout.is_zero() {
        return Err(Refusal::Readiness);
    }
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|_| Refusal::Readiness)?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|_| Refusal::Readiness)?;
    let authority = binding
        .editor_origin
        .strip_prefix("https://")
        .ok_or(Refusal::Origin)?;
    write!(
        stream,
        "GET /version HTTP/1.0\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
    )
    .map_err(|_| Refusal::Readiness)?;
    let mut bytes = Vec::with_capacity(1024);
    DeadlineReader {
        stream: &mut stream,
        deadline: probe_deadline,
    }
    .take(16385)
    .read_to_end(&mut bytes)
    .map_err(|_| Refusal::Readiness)?;
    if bytes.len() > 16384 {
        return Err(Refusal::Readiness);
    }
    let response = std::str::from_utf8(&bytes).map_err(|_| Refusal::Readiness)?;
    let (head, body) = response.split_once("\r\n\r\n").ok_or(Refusal::Readiness)?;
    if !head
        .lines()
        .next()
        .is_some_and(|line| line.starts_with("HTTP/1.1 200 ") || line.starts_with("HTTP/1.0 200 "))
        || body != binding.editor_commit
    {
        return Err(Refusal::Readiness);
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:product;security] editor-worker-unconditional-trust
/// Every personal worker MUST disable workspace trust through the upstream CLI,
/// independently of user settings or workspace location, and MUST open the
/// shared `/workspace` folder by default so a `?folder=` query is the only way
/// to choose another folder. Its data directory and Unix socket MUST remain the
/// reconciled personal paths; no request field may add editor arguments.
/// Folder the workbench opens when the URL names none: the guest's repository
/// checkout location (`/workspace/REPO`), created by every guest image.
const DEFAULT_FOLDER: &str = "/workspace";

fn editor_arguments(executable: &Path, home: &Path, socket: &Path) -> Result<Vec<String>, Refusal> {
    let home = home.to_str().ok_or(Refusal::Account)?;
    Ok(vec![
        executable.to_str().ok_or(Refusal::Package)?.to_owned(),
        "--without-connection-token".to_owned(),
        "--socket-path".to_owned(),
        socket.to_str().ok_or(Refusal::Custody)?.to_owned(),
        "--server-data-dir".to_owned(),
        format!("{home}/.local/share/overalls/vscode-web"),
        "--enable-remote-auto-shutdown".to_owned(),
        "--reconnection-grace-time".to_owned(),
        "1500".to_owned(),
        "--disable-telemetry".to_owned(),
        "--disable-workspace-trust".to_owned(),
        "--default-folder".to_owned(),
        DEFAULT_FOLDER.to_owned(),
    ])
}

#[expect(
    clippy::too_many_lines,
    reason = "one single-flight reuse/stop/start sequence held under the account lock"
)]
fn ensure_worker(
    runtime: &Runtime,
    binding: &Binding,
    deadline: Instant,
) -> Result<PathBuf, Refusal> {
    let account_lock = {
        let mut locks = lock_before(&runtime.account_locks, deadline)?;
        if !locks.contains_key(&binding.uid) && locks.len() >= MAX_ACCOUNTS {
            return Err(Refusal::Capacity);
        }
        locks.entry(binding.uid).or_default().clone()
    };
    let _guard = lock_before(&account_lock, deadline)?;
    if Instant::now() >= deadline {
        return Err(Refusal::Startup);
    }
    if !command(
        &runtime.configuration.account_authorizer,
        &["ensure".to_owned(), binding.username.clone()],
        deadline,
    )? {
        return Err(Refusal::Account);
    }
    let home = account(binding)?;
    let directory = runtime_directory(binding.uid)?;
    let socket = directory.join("editor.sock");
    let readiness = probe(&socket, binding, deadline);
    if readiness == Err(Refusal::Custody) {
        return Err(Refusal::Custody);
    }
    let unit = format!("overalls-vscode-u{}.service", binding.uid);
    let description = launch_description(binding)?;
    let state = unit_metadata(
        &runtime.configuration.systemctl,
        &[
            "show".to_owned(),
            "--property=LoadState,ActiveState,Description".to_owned(),
            "--".to_owned(),
            unit.clone(),
        ],
        deadline,
    )?;
    let launch = match state {
        WorkerUnit::Live {
            description: current,
        } if current == description => {
            if readiness.is_ok() {
                return Ok(socket);
            }
            false
        }
        WorkerUnit::Live { .. } => {
            if !command(
                &runtime.configuration.systemctl,
                &["stop".to_owned(), "--".to_owned(), unit.clone()],
                deadline,
            )? {
                return Err(Refusal::Startup);
            }
            true
        }
        WorkerUnit::Missing | WorkerUnit::Inactive => true,
    };
    if launch {
        if fs::symlink_metadata(&socket).is_ok() {
            socket_custody(&socket, binding.uid)?;
            fs::remove_file(&socket).map_err(|_| Refusal::Custody)?;
        }
        let editor = editor_arguments(&runtime.configuration.editor_executable, &home, &socket)?;
        let home = home.to_str().ok_or(Refusal::Account)?;
        let mut arguments = vec![
            "--quiet".to_owned(),
            "--collect".to_owned(),
            "--service-type=exec".to_owned(),
            format!("--unit={unit}"),
            format!("--property=Description={description}"),
            format!("--uid={}", binding.uid),
            format!("--gid={}", binding.uid),
            format!("--working-directory={home}"),
            "--property=UMask=0077".to_owned(),
            "--property=Restart=no".to_owned(),
            "--property=KillMode=control-group".to_owned(),
            "--property=StandardOutput=null".to_owned(),
            "--property=StandardError=null".to_owned(),
            "--property=TasksMax=256".to_owned(),
            format!("--setenv=HOME={home}"),
            format!("--setenv=USER={}", binding.username),
            format!("--setenv=LOGNAME={}", binding.username),
            format!("--setenv=PATH={}", runtime.configuration.worker_path),
            format!("--setenv=OVERALLS_EDITOR_ORIGIN={}", binding.editor_origin),
            format!(
                "--setenv=OVERALLS_WEBVIEW_ENDPOINT_TEMPLATE={}",
                overalls_vscode_web_broker::webview_template(binding)?
            ),
            "--".to_owned(),
        ];
        arguments.extend(editor);
        // Native Node workers inherit ordinary guest CA trust, without credentials.
        arguments.insert(
            17,
            "--setenv=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt".to_owned(),
        );
        if !command(&runtime.configuration.systemd_run, &arguments, deadline)? {
            return Err(Refusal::Startup);
        }
        emit(Event::WorkerStarted, None);
    }
    while Instant::now() < deadline {
        if probe(&socket, binding, deadline).is_ok() {
            return Ok(socket);
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(Refusal::Readiness)
}

/// Which relay direction reached its end first and how: the closed record
/// names it without carrying any byte of either stream.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Ending {
    /// The worker ended before sending one byte to the gateway.
    Silent,
    /// The worker ended after sending a response.
    Worker,
    /// Reading from the worker failed.
    WorkerFault,
    /// Writing the worker's bytes to the gateway failed.
    GatewayWrite,
    /// The gateway ended its stream.
    Client,
    /// Reading from the gateway failed.
    GatewayRead,
    /// Writing the gateway's bytes to the worker failed.
    WorkerClosed,
}

impl Ending {
    fn name(self) -> &'static str {
        match self {
            Self::Silent => "silent",
            Self::Worker => "worker",
            Self::WorkerFault => "workerfault",
            Self::GatewayWrite => "gatewaywrite",
            Self::Client => "client",
            Self::GatewayRead => "gatewayread",
            Self::WorkerClosed => "workerclosed",
        }
    }
}

/// How one relay direction ended, and how many bytes it moved first.
enum Pumped {
    End(u64),
    Read,
    Write,
}

fn pump(source: &mut impl Read, sink: &mut impl Write) -> Pumped {
    let mut buffer = [0_u8; 16 * 1024];
    let mut moved = 0_u64;
    loop {
        let count = match source.read(&mut buffer) {
            Ok(0) => return Pumped::End(moved),
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Pumped::Read,
        };
        if sink.write_all(&buffer[..count]).is_err() {
            return Pumped::Write;
        }
        moved += count as u64;
    }
}

/// Read and discard the gateway's remaining bytes until it ends its stream.
fn drain(source: &mut impl Read) {
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        match source.read(&mut buffer) {
            Ok(0) => return,
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

/// How long a gateway may keep sending after the worker's side ended before
/// the broker closes the connection regardless.
const LINGER: Duration = Duration::from_secs(10);

/// @cc [owner:ghuntley,label:recovery;protocol] editor-relay-orderly-close
/// A failed write of gateway bytes to the worker MUST NOT end the response
/// direction: every byte the worker sends until its own end of stream MUST
/// still reach the gateway, then the broker half-closes the gateway for
/// writing and discards further gateway bytes until the gateway ends or
/// LINGER passes. A worker that answers early and closes therefore yields
/// its response, never an empty close the gateway reports as a missing
/// response. A gateway end of stream or failure still closes both sides.
/// Record the first relay ending and emit its closed record at that moment,
/// before any linger, so the journal times the end itself.
fn record(ending: &Mutex<Option<Ending>>, outcome: Ending) -> Ending {
    let mut slot = ending
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if slot.is_none() {
        *slot = Some(outcome);
        emit_closed(outcome);
    }
    slot.unwrap_or(outcome)
}

fn relay(mut client: TcpStream, mut worker: UnixStream) -> Result<Ending, Refusal> {
    let mut client_writer = client.try_clone().map_err(|_| Refusal::Transport)?;
    let mut worker_reader = worker.try_clone().map_err(|_| Refusal::Transport)?;
    let ending = Mutex::new(None);
    let (gateway_done, gateway_ended) = std::sync::mpsc::channel::<()>();
    thread::scope(|scope| {
        let ending = &ending;
        let (client_writer, worker_reader) = (&mut client_writer, &mut worker_reader);
        scope.spawn(move || {
            let outcome = match pump(worker_reader, client_writer) {
                Pumped::End(0) => Ending::Silent,
                Pumped::End(_) => Ending::Worker,
                Pumped::Read => Ending::WorkerFault,
                Pumped::Write => Ending::GatewayWrite,
            };
            let recorded = record(ending, outcome);
            if !matches!(
                recorded,
                Ending::Client | Ending::GatewayRead | Ending::GatewayWrite
            ) {
                let _ = client_writer.shutdown(Shutdown::Write);
                let lingering = Instant::now();
                if gateway_ended.recv_timeout(LINGER).is_ok() {
                    if lingering.elapsed() >= Duration::from_secs(1) {
                        emit(Event::Lingered, None);
                    }
                    return;
                }
                emit(Event::LingerExpired, None);
            }
            let _ = client_writer.shutdown(Shutdown::Both);
        });
        let outcome = match pump(&mut client, &mut worker) {
            Pumped::End(_) => Ending::Client,
            Pumped::Read => Ending::GatewayRead,
            Pumped::Write => Ending::WorkerClosed,
        };
        let recorded = record(ending, outcome);
        if matches!(
            recorded,
            Ending::Client | Ending::GatewayRead | Ending::GatewayWrite
        ) {
            let _ = worker.shutdown(Shutdown::Both);
        } else {
            drain(&mut client);
        }
        let _ = gateway_done.send(());
        let _ = client.shutdown(Shutdown::Both);
        let _ = worker.shutdown(Shutdown::Both);
    });
    Ok(ending
        .into_inner()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .unwrap_or(Ending::Client))
}

fn connection(mut client: TcpStream, runtime: &Arc<Runtime>) -> Result<(), Refusal> {
    let _guard = ConnectionGuard(runtime.clone());
    client
        .set_read_timeout(Some(STARTUP))
        .map_err(|_| Refusal::Transport)?;
    client
        .set_write_timeout(Some(STARTUP))
        .map_err(|_| Refusal::Transport)?;
    let deadline = Instant::now() + STARTUP;
    let preface = overalls_vscode_web_broker::read_preface(&mut DeadlineReader {
        stream: &mut client,
        deadline,
    })?;
    overalls_vscode_web_broker::validate(
        &preface,
        &runtime.boot,
        &runtime.configuration.descriptor,
    )?;
    let socket = ensure_worker(runtime, &preface.binding, deadline)?;
    let worker = connect(&socket, preface.binding.uid, deadline)?;
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(Refusal::Startup);
    }
    client
        .set_write_timeout(Some(remaining))
        .map_err(|_| Refusal::Transport)?;
    overalls_vscode_web_broker::ready(&mut client).map_err(|_| Refusal::Transport)?;
    client
        .set_read_timeout(None)
        .map_err(|_| Refusal::Transport)?;
    client
        .set_write_timeout(None)
        .map_err(|_| Refusal::Transport)?;
    emit(Event::Ready, None);
    relay(client, worker)?;
    Ok(())
}

// systemd MUST NOT report the broker started until its listener is bound, so a
// restart cannot race the gateway into a refused connection. Outside a
// Type=notify unit there is no socket and readiness is implicit.
fn notify_ready() {
    if let Some(path) = std::env::var_os("NOTIFY_SOCKET") {
        notify_ready_to(&path);
    }
}

fn notify_ready_to(path: &std::ffi::OsStr) {
    use std::os::linux::net::SocketAddrExt;
    use std::os::unix::net::{SocketAddr, UnixDatagram};
    let bytes = path.as_encoded_bytes();
    let address = match bytes.split_first() {
        Some((b'@', name)) => SocketAddr::from_abstract_name(name),
        Some((b'/', _)) => SocketAddr::from_pathname(Path::new(path)),
        _ => return,
    };
    if let (Ok(address), Ok(socket)) = (address, UnixDatagram::unbound()) {
        let _ = socket.send_to_addr(b"READY=1", &address);
    }
}

fn serve(configuration: Configuration) -> Result<(), Refusal> {
    // SAFETY: geteuid has no preconditions and cannot fail.
    if unsafe { libc::geteuid() } != 0 {
        return Err(Refusal::Account);
    }
    let cmdline = fs::read_to_string("/proc/cmdline").map_err(|_| Refusal::Boot)?;
    let boot = overalls_vscode_web_broker::parse_boot(&cmdline)?;
    let listener = TcpListener::bind((boot.address, PORT)).map_err(|_| Refusal::Transport)?;
    let device = b"eth0\0";
    let device_length = libc::socklen_t::try_from(device.len()).map_err(|_| Refusal::Transport)?;
    // SAFETY: `device` is a live NUL-terminated interface name whose exact length is passed, and the listener descriptor is open.
    if unsafe {
        libc::setsockopt(
            listener.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_BINDTODEVICE,
            device.as_ptr().cast(),
            device_length,
        )
    } != 0
    {
        return Err(Refusal::Transport);
    }
    let runtime = Arc::new(Runtime {
        configuration,
        boot,
        account_locks: Mutex::new(BTreeMap::new()),
        connections: AtomicUsize::new(0),
    });
    emit(Event::Started, None);
    notify_ready();
    for accepted in listener.incoming() {
        let client = accepted.map_err(|_| Refusal::Transport)?;
        if client.peer_addr().map_err(|_| Refusal::Transport)?.ip() != runtime.boot.gateway {
            emit(Event::Refused, Some(Refusal::Transport));
            continue;
        }
        if runtime.connections.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
            runtime.connections.fetch_sub(1, Ordering::AcqRel);
            emit(Event::Refused, Some(Refusal::Capacity));
            continue;
        }
        let runtime = runtime.clone();
        thread::spawn(move || {
            if let Err(reason) = connection(client, &runtime) {
                emit(Event::Refused, Some(reason));
            }
        });
    }
    Err(Refusal::Transport)
}

fn execute() -> Result<(), Refusal> {
    let arguments = std::env::args_os().skip(1).collect::<Vec<_>>();
    match arguments.as_slice() {
        [configuration] => serve(read_configuration(Path::new(configuration))?),
        _ => Err(Refusal::Package),
    }
}

pub(crate) fn main() -> ExitCode {
    match execute() {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            emit(Event::Failed, Some(reason));
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readiness_reaches_path_and_abstract_notify_sockets() {
        use std::os::linux::net::SocketAddrExt;
        use std::os::unix::net::{SocketAddr, UnixDatagram};
        let directory = std::env::temp_dir().join(format!("broker-notify-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("notify");
        let _ = fs::remove_file(&path);
        let receiver = UnixDatagram::bind(&path).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        notify_ready_to(path.as_os_str());
        let mut buffer = [0_u8; 32];
        let length = receiver.recv(&mut buffer).unwrap();
        assert_eq!(&buffer[..length], b"READY=1");
        fs::remove_dir_all(&directory).unwrap();

        let name = format!("broker-notify-{}", std::process::id());
        let abstract_receiver =
            UnixDatagram::bind_addr(&SocketAddr::from_abstract_name(name.as_bytes()).unwrap())
                .unwrap();
        abstract_receiver
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        notify_ready_to(std::ffi::OsStr::new(&format!("@{name}")));
        let length = abstract_receiver.recv(&mut buffer).unwrap();
        assert_eq!(&buffer[..length], b"READY=1");

        notify_ready_to(std::ffi::OsStr::new("relative"));
    }

    fn launch_binding() -> Binding {
        Binding {
            vm_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            host_id: "00000000-0000-4000-8000-000000000002".to_owned(),
            placement_id: "00000000-0000-4000-8000-000000000003".to_owned(),
            session_id: "00000000-0000-4000-8000-000000000004".to_owned(),
            execution_epoch: 1,
            generation: 1,
            label: "e-aaaaaaaaaaaaaaaaaaaaaaaaaa-aaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
            service: "editor".to_owned(),
            port: PORT,
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            guest_account_id: "00000000-0000-4000-8000-000000000006".to_owned(),
            uid: 200_001,
            username: "alice".to_owned(),
            editor_protocol: 1,
            editor_commit: "a".repeat(40),
            editor_release: "b".repeat(64),
            editor_origin: "https://editor.apps.example.test".to_owned(),
        }
    }

    #[test]
    fn personal_launch_disables_trust_for_every_account_and_keeps_data_personal() {
        for username in ["alice", "bob"] {
            let home = PathBuf::from(format!("/home/{username}"));
            let socket = Path::new("/run/overalls-vscode/u200001/editor.sock");
            let arguments = editor_arguments(
                Path::new("/nix/store/editor/bin/overalls-code"),
                &home,
                socket,
            )
            .unwrap();
            assert_eq!(
                arguments
                    .iter()
                    .filter(|argument| argument.as_str() == "--disable-workspace-trust")
                    .count(),
                1
            );
            let data = arguments
                .iter()
                .position(|argument| argument == "--server-data-dir")
                .unwrap();
            assert_eq!(
                arguments[data + 1],
                format!("/home/{username}/.local/share/overalls/vscode-web")
            );
            let unix = arguments
                .iter()
                .position(|argument| argument == "--socket-path")
                .unwrap();
            assert_eq!(arguments[unix + 1], socket.to_str().unwrap());
            let folder = arguments
                .iter()
                .position(|argument| argument == "--default-folder")
                .unwrap();
            assert_eq!(arguments[folder + 1], "/workspace");
            assert!(
                !arguments
                    .iter()
                    .any(|argument| argument.starts_with("--extensions-dir"))
            );
        }
    }

    #[test]
    fn launch_identity_binds_account_package_and_origin_without_disclosure() {
        let binding = launch_binding();
        let description = launch_description(&binding).unwrap();
        assert_eq!(description, launch_description(&binding.clone()).unwrap());
        let digest = description.strip_prefix("Overalls editor ").unwrap();
        assert!(overalls_vscode_web_broker::hex(digest, 64));
        assert!(!description.contains(&binding.username));
        assert!(!description.contains(&binding.editor_origin));
        for mutation in 0..6 {
            let mut changed = binding.clone();
            match mutation {
                0 => changed.uid += 1,
                1 => changed.username = "bob".to_owned(),
                2 => changed.editor_protocol += 1,
                3 => changed.editor_commit = "c".repeat(40),
                4 => changed.editor_release = "d".repeat(64),
                _ => changed.editor_origin.push_str(":8443"),
            }
            assert_ne!(description, launch_description(&changed).unwrap());
        }
    }

    #[test]
    fn manager_metadata_distinguishes_absence_and_live_identity() {
        assert_eq!(
            parse_unit_metadata(b"Description=unit\nLoadState=not-found\nActiveState=inactive\n"),
            Ok(WorkerUnit::Missing)
        );
        assert_eq!(
            parse_unit_metadata(b"LoadState=loaded\nActiveState=failed\nDescription=unit\n"),
            Ok(WorkerUnit::Inactive)
        );
        assert_eq!(
            parse_unit_metadata(b"LoadState=loaded\nActiveState=active\nDescription=identity\n"),
            Ok(WorkerUnit::Live {
                description: "identity".to_owned()
            })
        );
        for invalid in [
            b"LoadState=loaded\nActiveState=active\n".as_slice(),
            b"LoadState=loaded\nActiveState=active\nDescription=x\nDescription=y\n".as_slice(),
            b"LoadState=loaded\nActiveState=active\nDescription=x\nUnknown=y\n".as_slice(),
            b"LoadState=error\nActiveState=inactive\nDescription=x\n".as_slice(),
            b"LoadState=loaded\nActiveState=unknown\nDescription=x\n".as_slice(),
        ] {
            assert_eq!(parse_unit_metadata(invalid), Err(Refusal::Startup));
        }
        assert_eq!(
            parse_unit_metadata(&vec![b'x'; MAX_UNIT_METADATA + 1]),
            Err(Refusal::Startup)
        );
    }

    #[test]
    fn stalled_manager_output_obeys_absolute_deadline() {
        let executable = std::env::current_exe().unwrap();
        let arguments = [
            "--exact".to_owned(),
            "tests::metadata_stall_fixture".to_owned(),
            "--ignored".to_owned(),
            "--nocapture".to_owned(),
        ];
        let started = Instant::now();
        assert_eq!(
            unit_metadata(
                &executable,
                &arguments,
                started + Duration::from_millis(100)
            ),
            Err(Refusal::Startup)
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    #[ignore = "subprocess fixture selected only by the deadline test"]
    fn metadata_stall_fixture() {
        std::io::stdout()
            .write_all(b"Description=partial\n")
            .unwrap();
        std::io::stdout().flush().unwrap();
        thread::sleep(Duration::from_secs(30));
    }

    #[test]
    fn kernel_peer_credentials_are_independent_of_socket_path_ownership() {
        let (stream, _peer) = UnixStream::pair().unwrap();
        // SAFETY: geteuid has no preconditions and cannot fail.
        let uid = unsafe { libc::geteuid() };
        assert_eq!(check_peer(&stream, uid), Ok(()));
        assert_eq!(check_peer(&stream, uid + 1), Err(Refusal::Custody));
    }

    #[test]
    fn concurrent_account_wait_obeys_absolute_deadline() {
        let mutex = Mutex::new(());
        let _held = mutex.lock().unwrap();
        let started = Instant::now();
        assert!(matches!(
            lock_before(&mutex, started + Duration::from_millis(30)),
            Err(Refusal::Startup)
        ));
        assert!(started.elapsed() < Duration::from_millis(250));
    }

    #[test]
    fn partial_frame_bytes_do_not_extend_absolute_deadline() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        thread::scope(|scope| {
            scope.spawn(|| {
                let (mut stream, _) = listener.accept().unwrap();
                stream.write_all(&[0]).unwrap();
                thread::sleep(Duration::from_millis(20));
                stream.write_all(&[0]).unwrap();
                thread::sleep(Duration::from_millis(150));
            });
            let mut stream = TcpStream::connect(address).unwrap();
            let started = Instant::now();
            let mut reader = DeadlineReader {
                stream: &mut stream,
                deadline: started + Duration::from_millis(50),
            };
            assert_eq!(
                overalls_vscode_web_broker::read_preface(&mut reader),
                Err(Refusal::Frame)
            );
            assert!(started.elapsed() < Duration::from_millis(120));
        });
    }

    /// Run one relay between a loopback gateway connection and a Unix worker
    /// pair, letting `gateway` and `worker` drive their ends.
    fn relay_ending(
        gateway: impl FnOnce(TcpStream) + Send + 'static,
        worker: impl FnOnce(UnixStream) + Send + 'static,
    ) -> Ending {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let gateway = thread::spawn(move || gateway(TcpStream::connect(address).unwrap()));
        let (client, _) = listener.accept().unwrap();
        let (relayed, peer) = UnixStream::pair().unwrap();
        let worker = thread::spawn(move || worker(peer));
        let ending = relay(client, relayed).unwrap();
        gateway.join().unwrap();
        worker.join().unwrap();
        ending
    }

    #[test]
    fn closed_names_the_side_that_ended_first() {
        // A worker that closes without answering is reported as silent.
        let silent = relay_ending(
            |mut gateway| {
                gateway.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
                let mut response = Vec::new();
                let _ = gateway.read_to_end(&mut response);
                assert_eq!(response, Vec::<u8>::new());
            },
            |mut worker| {
                let mut request = [0_u8; 18];
                worker.read_exact(&mut request).unwrap();
            },
        );
        assert_eq!(silent, Ending::Silent);
        let answered = relay_ending(
            |mut gateway| {
                gateway.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
                let mut response = Vec::new();
                let _ = gateway.read_to_end(&mut response);
                assert_eq!(response, b"HTTP/1.1 204 \r\n\r\n");
            },
            |mut worker| {
                let mut request = [0_u8; 18];
                worker.read_exact(&mut request).unwrap();
                worker.write_all(b"HTTP/1.1 204 \r\n\r\n").unwrap();
            },
        );
        assert_eq!(answered, Ending::Worker);
        let gateway_first = relay_ending(
            |gateway| gateway.shutdown(Shutdown::Write).unwrap(),
            |mut worker| {
                let mut rest = Vec::new();
                let _ = worker.read_to_end(&mut rest);
                assert_eq!(rest, Vec::<u8>::new());
            },
        );
        assert_eq!(gateway_first, Ending::Client);
    }

    #[test]
    fn response_survives_a_worker_that_stopped_reading_the_request() {
        // The worker stops reading after the request line, so the broker's
        // next write of gateway bytes fails, and only then answers and
        // closes. That response MUST still reach the gateway, followed by
        // end of stream, rather than an empty close.
        let ending = relay_ending(
            |mut gateway| {
                gateway.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
                thread::sleep(Duration::from_millis(100));
                let _ = gateway.write_all(b"trailing request bytes");
                let mut response = Vec::new();
                gateway.read_to_end(&mut response).unwrap();
                assert_eq!(response, b"HTTP/1.1 400 \r\n\r\n");
            },
            |mut worker| {
                let mut request = [0_u8; 18];
                worker.read_exact(&mut request).unwrap();
                worker.shutdown(Shutdown::Read).unwrap();
                thread::sleep(Duration::from_millis(300));
                worker.write_all(b"HTTP/1.1 400 \r\n\r\n").unwrap();
            },
        );
        assert_eq!(ending, Ending::WorkerClosed);
    }
}
