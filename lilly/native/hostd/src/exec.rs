//! Running one utility with custody of its whole process tree.
//!
//! In cgroup mode (production) every command runs in its own child cgroup of
//! hostd's delegated cgroup. Ending a command writes `cgroup.kill` and waits
//! until the cgroup is unpopulated, so no descendant survives, however it
//! detached. Process-group mode (unit tests, development) kills the command's
//! group and its leader only.
//!
//! The utility inherits the lease's descriptor, so the `flock` stays held by
//! the kernel while any descendant lives, even if hostd itself is killed.

use crate::protocol::Status;
use rustix::event::{PollFd, PollFlags};
use rustix::fs::{Mode as FileMode, OFlags};
use rustix::io::{Errno, FdFlags};
use rustix::process::{kill_process_group, Pid, Signal, WaitOptions, WaitStatus};
use std::collections::HashMap;
use std::ffi::CString;
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How custody of command trees is kept.
#[derive(Debug)]
pub enum Custody {
    /// Each command in its own child cgroup of this delegated cgroup.
    Cgroup(PathBuf),
    /// Each command in its own process group (no cgroup delegation).
    ProcessGroup,
}

/// One validated command.
#[derive(Debug)]
pub struct Spec<'a> {
    pub executable: &'a Path,
    pub arguments: &'a [CString],
    pub timeout: Duration,
    pub output_limit: usize,
    pub lease: Option<&'a OwnedFd>,
    /// Further descriptors the utility inherits at their own numbers.
    pub inherit: &'a [&'a OwnedFd],
}

struct Reaper {
    waiting: Mutex<HashMap<i32, Sender<WaitStatus>>>,
    children: Mutex<u64>,
    spawned: Condvar,
}

fn reaper() -> &'static Reaper {
    static REAPER: OnceLock<Reaper> = OnceLock::new();
    REAPER.get_or_init(|| {
        std::thread::spawn(reap_forever);
        Reaper {
            waiting: Mutex::new(HashMap::new()),
            children: Mutex::new(0),
            spawned: Condvar::new(),
        }
    })
}

/// @cc [owner:ghuntley,label:recovery] hostd-single-reaper
/// Exactly one thread reaps children. It first observes an exited child
/// without reaping it, then takes the registry lock, which every spawn holds
/// from fork to registration, and only then reaps that pid. A registered
/// child's status goes to the command that spawned it; orphaned descendants
/// adopted by the subreaper are reaped and dropped. A failed spawn's child,
/// which the standard library reaps itself, is therefore never taken from it.
fn reap_forever() {
    let reaper = reaper();
    loop {
        if let Some(pid) = peek::exited() {
            let mut waiting = crate::lock(&reaper.waiting, "reaper registry");
            let Some(target) = Pid::from_raw(pid) else {
                continue;
            };
            // None or an error: already reaped by a failed spawn.
            if let Ok(Some((_, status))) =
                rustix::process::waitpid(Some(target), WaitOptions::NOHANG)
            {
                if let Some(sender) = waiting.remove(&pid) {
                    let _ = sender.send(status);
                }
            }
        } else {
            // No children: sleep until one is spawned.
            let mut count = crate::lock(&reaper.children, "reaper count");
            let seen = *count;
            while *count == seen {
                count = crate::wait_timeout(
                    &reaper.spawned,
                    count,
                    Duration::from_millis(500),
                    "reaper count",
                );
                if *count == seen {
                    break;
                }
            }
        }
    }
}

/// How a detached ingress bridge ended, as `lilly-ingress-bridge`'s exit codes
/// and the kernel's signal report it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BridgeExit {
    Ok,
    ExitIo,
    SetupFailed,
    ExitOther,
    SignalPipe,
    SignalKill,
    SignalOther,
}

impl BridgeExit {
    /// Classify a detached bridge's exit code or terminating signal.
    pub fn of(code: Option<i32>, signal: Option<i32>) -> Self {
        match (code, signal) {
            (Some(0), _) => Self::Ok,
            (Some(74), _) => Self::ExitIo,
            (Some(64 | 70), _) => Self::SetupFailed,
            (Some(_), _) => Self::ExitOther,
            (None, Some(signal)) if signal == libc::SIGPIPE => Self::SignalPipe,
            (None, Some(signal)) if signal == libc::SIGKILL => Self::SignalKill,
            _ => Self::SignalOther,
        }
    }

    /// The closed (outcome, signal) pair the report names.
    pub fn fields(self) -> (&'static str, &'static str) {
        match self {
            Self::Ok => ("ok", "none"),
            Self::ExitIo => ("exit_io", "none"),
            Self::SetupFailed => ("setup_failed", "none"),
            Self::ExitOther => ("exit_other", "none"),
            Self::SignalPipe => ("signal", "pipe"),
            Self::SignalKill => ("signal", "kill"),
            Self::SignalOther => ("signal", "other"),
        }
    }
}

/// @cc [owner:ghuntley,label:recovery;privacy] hostd-detached-bridge-exit-report
/// Every detached ingress bridge hostd itself reaps MUST be reported once on
/// hostd's stderr as one fixed-grammar line naming only the closed exit class
/// and signal class: never its pid, key, unit, path, peer or any byte it moved.
/// A bridge that outlives hostd is reaped elsewhere and is not reported.
fn detached_reports() -> Sender<WaitStatus> {
    static REPORTS: OnceLock<Mutex<Sender<WaitStatus>>> = OnceLock::new();
    let sender = REPORTS.get_or_init(|| {
        let (sender, receiver) = channel::<WaitStatus>();
        std::thread::spawn(move || {
            for status in receiver {
                let (outcome, signal) =
                    BridgeExit::of(status.exit_status(), status.terminating_signal()).fields();
                eprintln!(
                    "{{\"service\":\"lilly-hostd\",\"event\":\"ingress.bridge_exited\",\"outcome\":\"{outcome}\",\"signal\":\"{signal}\"}}"
                );
            }
        });
        Mutex::new(sender)
    });
    crate::lock(sender, "bridge exit reports").clone()
}

/// Make this process the subreaper for every descendant and start reaping.
pub fn start_reaper() -> std::io::Result<()> {
    rustix::process::set_child_subreaper(Some(rustix::process::getpid()))?;
    let _ = reaper();
    Ok(())
}

static NEXT_CGROUP: AtomicU64 = AtomicU64::new(1);

/// Prepare cgroup mode: move hostd itself into a `daemon` leaf so command
/// cgroups can be created beside it (cgroup v2 forbids processes in inner
/// nodes that have children).
pub fn prepare_cgroup(base: &Path) -> std::io::Result<()> {
    let daemon = base.join("daemon");
    match std::fs::create_dir(&daemon) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    std::fs::write(daemon.join("cgroup.procs"), b"0")?;
    // Remove command cgroups left by a previous instance; any still populated
    // are killed first so no utility from before the restart survives.
    for entry in std::fs::read_dir(base)? {
        let entry = entry?;
        let name = entry.file_name();
        if name.as_bytes().starts_with(b"run-") {
            kill_cgroup(&entry.path());
        }
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:recovery] cgroup-kill-confirms-empty
/// `kill_cgroup` MUST write `cgroup.kill` and return only after `cgroup.events`
/// reports `populated 0`, then remove the cgroup. It waits as long as that
/// takes: an unconfirmed tree keeps its lease held rather than releasing it.
fn kill_cgroup(cgroup: &Path) {
    let mut pause = Duration::from_millis(2);
    loop {
        let _ = std::fs::write(cgroup.join("cgroup.kill"), b"1");
        match std::fs::read(cgroup.join("cgroup.events")) {
            Ok(events) if populated(&events) == Some(false) => break,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            _ => {}
        }
        std::thread::sleep(pause);
        pause = (pause * 2).min(Duration::from_millis(200));
    }
    let _ = std::fs::remove_dir(cgroup);
}

fn populated(events: &[u8]) -> Option<bool> {
    events
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"populated "))
        .map(|value| value != b"0")
}

#[allow(
    unsafe_code,
    reason = "waitid with WNOWAIT has no safe wrapper; this shim is the only unsafe surface for it"
)]
mod peek {
    /// Block until some child has exited and return its pid without reaping
    /// it; None when there are no children.
    pub(super) fn exited() -> Option<i32> {
        loop {
            // SAFETY: siginfo_t is plain data; waitid fills it and we read
            // si_pid only after a successful call with WEXITED.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: `info` is a live, writable siginfo_t for the whole call,
            // which is all waitid writes through the pointer.
            let result = unsafe {
                libc::waitid(libc::P_ALL, 0, &raw mut info, libc::WEXITED | libc::WNOWAIT)
            };
            if result == 0 {
                // SAFETY: waitid succeeded with WEXITED, so the kernel filled
                // `info` for a child-exit event, whose si_pid field is valid.
                let pid = unsafe { info.si_pid() };
                if pid > 0 {
                    return Some(pid);
                }
                continue;
            }
            match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::EINTR) => {}
                _ => return None,
            }
        }
    }
}

#[allow(
    unsafe_code,
    reason = "pre_exec and the raw descriptor calls in the forked child have no safe wrapper; this shim is the only unsafe surface for them"
)]
mod child {
    use super::HANDOFF_LIMIT;

    /// Staged copies go at or above `3 + HANDOFF_LIMIT`, clear of every target.
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        reason = "HANDOFF_LIMIT is 3, far below i32::MAX"
    )]
    const STAGING_FLOOR: i32 = 3 + HANDOFF_LIMIT as i32;
    use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
    use std::os::fd::RawFd;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    /// @cc [owner:ghuntley,label:recovery;security] hostd-child-pinned
    /// Before exec a utility MUST: die with its spawning thread (parent-death
    /// signal, verified against the recorded parent) unless it is a detached
    /// ingress bridge (`spawn_detached`), which must outlive hostd, restore default SIGPIPE,
    /// move itself into its command cgroup when one is given, and keep the
    /// lease descriptor and the request's inherited descriptors (and only
    /// those) across exec. Handed-off descriptors are placed at 3, 4, ... in
    /// order, through close-on-exec duplicates so no source is overwritten
    /// before it is copied; a handoff never coexists with a lease or inherited
    /// descriptors. Any failure aborts the spawn. `pre_exec` is the only
    /// unsafe API; the closure performs only async-signal-safe system calls on
    /// descriptors opened beforehand.
    pub(super) fn pin(
        command: &mut Command,
        parent: Option<Pid>,
        cgroup_procs: Option<RawFd>,
        lease: Option<RawFd>,
        inherit: Vec<RawFd>,
        handoff: Vec<RawFd>,
    ) {
        let setup = move || {
            if let Some(parent) = parent {
                if set_parent_process_death_signal(Some(Signal::KILL)).is_err()
                    || getppid() != Some(parent)
                {
                    return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
                }
            }
            // SAFETY: signal(2) is async-signal-safe and SIG_DFL installs no
            // handler code.
            unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
            if let Some(procs) = cgroup_procs {
                // SAFETY: `procs` was opened before the fork and stays open in
                // the child; the one-byte static buffer is valid for reads.
                if unsafe { libc::write(procs, b"0".as_ptr().cast(), 1) } != 1 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            for fd in lease.iter().chain(inherit.iter()) {
                // SAFETY: fcntl(F_SETFD) only changes descriptor flags and
                // touches no memory; a stale descriptor is an error return.
                if unsafe { libc::fcntl(*fd, libc::F_SETFD, 0) } != 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            // Copy every source above the targets first: a source that is
            // itself 3 or 4 must not be overwritten before it is placed.
            let mut staged = [0; HANDOFF_LIMIT];
            for (slot, fd) in handoff.iter().enumerate() {
                // SAFETY: fcntl(F_DUPFD_CLOEXEC) only creates a descriptor
                // and touches no memory; a stale descriptor is an error return.
                let copy = unsafe { libc::fcntl(*fd, libc::F_DUPFD_CLOEXEC, STAGING_FLOOR) };
                if copy < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                staged[slot] = copy;
            }
            for (target, copy) in (3..).zip(staged.iter().take(handoff.len())) {
                // SAFETY: dup2 only replaces a descriptor slot and touches no
                // memory. It clears close-on-exec on the placed descriptor.
                if unsafe { libc::dup2(*copy, target) } < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            }
            Ok(())
        };
        // SAFETY: the closure runs in the forked child before exec and makes
        // only async-signal-safe system calls on descriptors opened before the
        // fork; it allocates nothing and takes no lock.
        unsafe { command.pre_exec(setup) };
    }
}

/// @cc [owner:ghuntley,label:recovery] hostd-command-reaped-before-reply
/// run MUST return only after the utility and every descendant it can
/// observe are gone: in cgroup mode the command cgroup is unpopulated; in
/// process-group mode the group was killed and the leader reaped. Timeout,
/// output overflow and cancellation kill the tree first and report
/// `TimedOut`, `OutputLimit` or Cancelled with no output. Normal exit still kills
/// any remaining descendants before reporting.
pub fn run(spec: &Spec<'_>, custody: &Custody, cancelled: &AtomicBool) -> (Status, Vec<u8>) {
    let (status, _, output) = run_coded(spec, custody, cancelled);
    (status, output)
}

/// run, also returning the leader's exit code when it exited normally
/// (Succeeded or Failed).
pub fn run_coded(
    spec: &Spec<'_>,
    custody: &Custody,
    cancelled: &AtomicBool,
) -> (Status, Option<i32>, Vec<u8>) {
    run_inner(spec, Vec::new(), custody, cancelled, &|| {})
}

/// Most descriptors one handoff places in a child.
pub const HANDOFF_LIMIT: usize = 3;

/// @cc [owner:ghuntley,label:security;recovery] hostd-handoff-sole-owner
/// `run_handoff` MUST place the handed-off descriptors at 3, 4, ... in the
/// child and close hostd's copies as soon as the child is spawned, so the
/// child holds the only references and sees end of stream when its peers
/// close. `started` runs once, after that, only when the spawn succeeded.
/// Otherwise it obeys run: the tree is killed and reaped before it returns.
/// A spec with a lease or inherited descriptors, or more than `HANDOFF_LIMIT`
/// descriptors, is a setup failure.
pub fn run_handoff(
    spec: &Spec<'_>,
    handoff: Vec<OwnedFd>,
    custody: &Custody,
    cancelled: &AtomicBool,
    started: &dyn Fn(),
) -> (Status, Option<i32>, Vec<u8>) {
    if spec.lease.is_some() || !spec.inherit.is_empty() || handoff.len() > HANDOFF_LIMIT {
        return (Status::Setup, None, Vec::new());
    }
    run_inner(spec, handoff, custody, cancelled, started)
}

#[expect(
    clippy::similar_names,
    reason = "receiver (status channel) and received (output bytes) are distinct roles"
)]
fn run_inner(
    spec: &Spec<'_>,
    handoff: Vec<OwnedFd>,
    custody: &Custody,
    cancelled: &AtomicBool,
    started: &dyn Fn(),
) -> (Status, Option<i32>, Vec<u8>) {
    let Ok((reader, writer)) = rustix::pipe::pipe_with(rustix::pipe::PipeFlags::CLOEXEC) else {
        return (Status::Setup, None, Vec::new());
    };
    let Ok(writer_error) = writer.try_clone() else {
        return (Status::Setup, None, Vec::new());
    };
    let cgroup = match custody {
        Custody::Cgroup(base) => {
            let path = base.join(format!(
                "run-{}",
                NEXT_CGROUP.fetch_add(1, Ordering::SeqCst)
            ));
            if std::fs::create_dir(&path).is_err() {
                return (Status::Setup, None, Vec::new());
            }
            if let Ok(procs) = rustix::fs::open(
                path.join("cgroup.procs"),
                OFlags::WRONLY | OFlags::CLOEXEC,
                FileMode::empty(),
            ) {
                Some((path, procs))
            } else {
                let _ = std::fs::remove_dir(&path);
                return (Status::Setup, None, Vec::new());
            }
        }
        Custody::ProcessGroup => None,
    };
    let mut builder = std::process::Command::new(spec.executable);
    builder
        .args(
            spec.arguments
                .iter()
                .map(|argument| std::ffi::OsStr::from_bytes(argument.as_bytes())),
        )
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("LC_ALL", "C")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::from(writer))
        .stderr(std::process::Stdio::from(writer_error))
        .process_group(0);
    child::pin(
        &mut builder,
        Some(rustix::process::getpid()),
        cgroup.as_ref().map(|(_, procs)| procs.as_raw_fd()),
        spec.lease.map(AsRawFd::as_raw_fd),
        spec.inherit.iter().map(|fd| fd.as_raw_fd()).collect(),
        handoff.iter().map(AsRawFd::as_raw_fd).collect(),
    );
    let (sender, receiver) = channel();
    let reaper = reaper();
    let spawned = {
        let mut waiting = crate::lock(&reaper.waiting, "reaper registry");
        match builder.spawn() {
            Ok(child) => {
                let pid = child.id().cast_signed();
                waiting.insert(pid, sender);
                Some(pid)
            }
            Err(_) => None,
        }
    };
    drop(builder);
    for fd in spec.lease.iter().chain(spec.inherit.iter()) {
        // The parent's copy keeps CLOEXEC; only the child cleared it.
        let _ = rustix::io::fcntl_setfd(fd.as_fd(), FdFlags::CLOEXEC);
    }
    *crate::lock(&reaper.children, "reaper count") += 1;
    reaper.spawned.notify_all();
    // The child has its own copies; hostd's close here (hostd-handoff-sole-owner).
    drop(handoff);
    let Some(pid) = spawned else {
        if let Some((path, _)) = &cgroup {
            kill_cgroup(path);
        }
        return (Status::Failed, None, Vec::new());
    };
    started();
    if rustix::fs::fcntl_setfl(&reader, OFlags::NONBLOCK).is_err() {
        finish(pid, cgroup.as_ref(), &receiver, true);
        return (Status::Setup, None, Vec::new());
    }
    let outcome = supervise(spec, &reader, &receiver, cancelled);
    let exited = outcome.1;
    finish(pid, cgroup.as_ref(), &receiver, !exited);
    let mut received = outcome.2;
    if outcome.0 == Status::Succeeded || outcome.0 == Status::Failed {
        // Bytes written between the last read and the exit.
        if drain(&reader, &mut received, spec.output_limit) {
            return (Status::OutputLimit, None, Vec::new());
        }
    }
    match outcome.0 {
        Status::Succeeded | Status::Failed => (outcome.0, outcome.3, received),
        other => (other, None, Vec::new()),
    }
}

/// Watch output, deadline and cancellation. Returns the status, whether the
/// leader already exited, and the output so far.
#[expect(
    clippy::similar_names,
    reason = "receiver (status channel) and received (output bytes) are distinct roles"
)]
fn supervise(
    spec: &Spec<'_>,
    reader: &OwnedFd,
    receiver: &Receiver<WaitStatus>,
    cancelled: &AtomicBool,
) -> (Status, bool, Vec<u8>, Option<i32>) {
    let deadline = Instant::now() + spec.timeout;
    let mut received = Vec::new();
    loop {
        if let Ok(status) = receiver.try_recv() {
            let succeeded = status.exit_status() == Some(0);
            return (
                if succeeded {
                    Status::Succeeded
                } else {
                    Status::Failed
                },
                true,
                received,
                status.exit_status(),
            );
        }
        if cancelled.load(Ordering::SeqCst) {
            return (Status::Cancelled, false, Vec::new(), None);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return (Status::TimedOut, false, Vec::new(), None);
        }
        let quantum = remaining.min(Duration::from_millis(20));
        let timeout = rustix::event::Timespec {
            tv_sec: 0,
            tv_nsec: i64::from(quantum.subsec_nanos()).max(1_000_000),
        };
        let mut fds = [PollFd::from_borrowed_fd(
            reader.as_fd(),
            PollFlags::IN | PollFlags::HUP,
        )];
        match rustix::event::poll(&mut fds, Some(&timeout)) {
            Ok(_) | Err(Errno::INTR) => {}
            Err(_) => return (Status::Setup, false, Vec::new(), None),
        }
        if drain(reader, &mut received, spec.output_limit) {
            return (Status::OutputLimit, false, Vec::new(), None);
        }
    }
}

/// Read what is available; true when the output bound was exceeded.
fn drain(reader: &OwnedFd, received: &mut Vec<u8>, limit: usize) -> bool {
    loop {
        let mut chunk = [0_u8; 8192];
        match rustix::io::read(reader, &mut chunk) {
            Err(Errno::INTR) => {}
            Err(_) | Ok(0) => return false,
            Ok(count) => {
                if received.len() + count > limit {
                    return true;
                }
                received.extend_from_slice(&chunk[..count]);
            }
        }
    }
}

/// Kill whatever remains of the command and wait for the leader's status.
fn finish(
    pid: i32,
    cgroup: Option<&(PathBuf, OwnedFd)>,
    receiver: &Receiver<WaitStatus>,
    leader_running: bool,
) {
    match cgroup {
        Some((path, _)) => {
            kill_cgroup(path);
        }
        None => {
            if let Some(group) = Pid::from_raw(pid) {
                let _ = kill_process_group(group, Signal::KILL);
            }
        }
    }
    if leader_running {
        // The leader was killed; its status arrives from the reaper.
        let _ = receiver.recv();
    }
}

/// A detached child: its pid and a pidfd that names it even after hostd's
/// reaper collected it, so a kill can never reach a reused pid.
#[derive(Debug)]
pub struct Detached {
    pub pid: i32,
    pub pidfd: OwnedFd,
}

impl Detached {
    /// Kill the child through its pidfd.
    pub fn kill(&self) {
        let _ = rustix::process::pidfd_send_signal(&self.pidfd, Signal::KILL);
    }
}

/// @cc [owner:ghuntley,label:recovery;security] hostd-detached-spawn
/// `spawn_detached` MUST start the executable with the handed-off descriptors
/// at 3, 4, ... (as hostd-handoff-sole-owner, closing hostd's copies at once),
/// stdio on /dev/null, a cleared environment, no lease, no command cgroup and
/// no parent-death signal, so it can outlive hostd. The pid is registered with
/// the single reaper and a pidfd opened before the registry lock is released,
/// so the child is reaped exactly once and never killed by a reused pid. A
/// spawn failure or more than `HANDOFF_LIMIT` descriptors returns None.
pub fn spawn_detached(
    executable: &Path,
    arguments: &[CString],
    handoff: Vec<OwnedFd>,
) -> Option<Detached> {
    if handoff.len() > HANDOFF_LIMIT {
        return None;
    }
    let mut builder = std::process::Command::new(executable);
    builder
        .args(
            arguments
                .iter()
                .map(|argument| std::ffi::OsStr::from_bytes(argument.as_bytes())),
        )
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("LC_ALL", "C")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0);
    child::pin(
        &mut builder,
        None,
        None,
        None,
        Vec::new(),
        handoff.iter().map(AsRawFd::as_raw_fd).collect(),
    );
    let sender = detached_reports();
    let reaper = reaper();
    let spawned = {
        let mut waiting = crate::lock(&reaper.waiting, "reaper registry");
        match builder.spawn() {
            Ok(child) => {
                let pid = child.id().cast_signed();
                let pidfd = Pid::from_raw(pid).and_then(|pid| {
                    rustix::process::pidfd_open(pid, rustix::process::PidfdFlags::empty()).ok()
                });
                waiting.insert(pid, sender);
                Some((pid, pidfd))
            }
            Err(_) => None,
        }
    };
    drop(builder);
    *crate::lock(&reaper.children, "reaper count") += 1;
    reaper.spawned.notify_all();
    drop(handoff);
    match spawned {
        Some((pid, Some(pidfd))) => Some(Detached { pid, pidfd }),
        Some((pid, None)) => {
            // Unreachable on supported kernels; the child is still
            // registered and unreaped, so its pid is still its own.
            if let Some(pid) = Pid::from_raw(pid) {
                let _ = rustix::process::kill_process(pid, Signal::KILL);
            }
            None
        }
        None => None,
    }
}
