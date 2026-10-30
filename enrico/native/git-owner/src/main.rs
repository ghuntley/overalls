#![deny(unsafe_code)]

use rustix::event::{poll, PollFd, PollFlags, Timespec};
use rustix::fd::{AsFd, OwnedFd};
use rustix::fs::{flock, fstat, open, FlockOperation, Mode, OFlags};
use rustix::io::Errno;
use rustix::process::{
    geteuid, getpid, kill_process_group, set_child_subreaper, wait, waitid, Pid, Signal, WaitId,
    WaitIdOptions, WaitOptions,
};
use std::io;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

const MAX_OUTPUT: usize = 67_108_864;
const CHUNK: usize = 65_536;

struct Request {
    timeout: Duration,
    limit: usize,
    directory: PathBuf,
    repository: String,
    shared: bool,
    executable: PathBuf,
    arguments: Vec<String>,
}

fn parse(arguments: &[String]) -> Option<Request> {
    if !(7..=134).contains(&arguments.len()) {
        return None;
    }
    let timeout = arguments[0].parse::<u64>().ok()?;
    let limit = arguments[1].parse::<usize>().ok()?;
    let directory = PathBuf::from(&arguments[2]);
    let repository = &arguments[3];
    let shared = match arguments[4].as_str() {
        "shared" => true,
        "exclusive" => false,
        _ => return None,
    };
    let executable = PathBuf::from(&arguments[5]);
    if !(1..=3_600_000).contains(&timeout)
        || !(1..=MAX_OUTPUT).contains(&limit)
        || !directory.is_absolute()
        || !executable.is_absolute()
        || repository.is_empty()
        || repository.len() > 128
        || !repository
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".-_".contains(&byte))
        || repository == "."
        || repository == ".."
        || arguments.iter().map(String::len).sum::<usize>() > CHUNK
    {
        return None;
    }
    Some(Request {
        timeout: Duration::from_millis(timeout),
        limit,
        directory,
        repository: repository.clone(),
        shared,
        executable,
        arguments: arguments[6..].to_vec(),
    })
}

/// @cc [owner:ghuntley,label:security;recovery] stable-owned-lock-inode
/// Locks MUST be regular, singly linked, private caller-owned files, opened
/// without following links; flock descriptors MUST survive utility exec.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract metadata [owner:…,label:…] is code-contracts syntax, not an intra-doc link"
)]
fn lock(path: &Path, shared: bool) -> Result<OwnedFd, u8> {
    let fd = open(
        path,
        OFlags::CREATE | OFlags::RDWR | OFlags::NOFOLLOW,
        Mode::RUSR | Mode::WUSR,
    )
    .map_err(|_| 126_u8)?;
    let stat = fstat(&fd).map_err(|_| 126_u8)?;
    if stat.st_uid != geteuid().as_raw()
        || stat.st_nlink != 1
        || stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_mode & 0o077 != 0
    {
        return Err(126);
    }
    flock(
        &fd,
        if shared {
            FlockOperation::NonBlockingLockShared
        } else {
            FlockOperation::NonBlockingLockExclusive
        },
    )
    .map_err(|_| 75_u8)?;
    Ok(fd)
}

fn admission(directory: &Path) -> Result<OwnedFd, u8> {
    for index in 0..8 {
        match lock(
            &directory.join(format!(".enrico-git-slot-{index}.lock")),
            false,
        ) {
            Ok(fd) => return Ok(fd),
            Err(75) => {}
            Err(code) => return Err(code),
        }
    }
    Err(75)
}

#[expect(
    unsafe_code,
    reason = "pre_exec and the async-signal-safe SIGPIPE reset are the only unsafe operations"
)]
mod child_fence {
    use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    /// @cc [owner:ghuntley,label:recovery] git-child-parent-death
    /// Before exec, children MUST install parent-death SIGKILL and verify the
    /// recorded parent, closing the setup race. Lock descriptors survive exec.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract metadata [owner:…,label:…] is code-contracts syntax, not an intra-doc link"
    )]
    pub(super) fn install(command: &mut Command, parent: Pid) {
        let fence = move || {
            if set_parent_process_death_signal(Some(Signal::KILL)).is_err()
                || getppid() != Some(parent)
            {
                return Err(std::io::ErrorKind::PermissionDenied.into());
            }
            // SAFETY: signal(2) is async-signal-safe and only restores the
            // default SIGPIPE disposition in the forked child before exec.
            unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
            Ok(())
        };
        // SAFETY: the pre-exec closure runs in the forked child and only calls
        // prctl(2), getppid(2) and signal(2), which are async-signal-safe; it
        // allocates nothing and touches no locks shared with the parent.
        unsafe {
            command.pre_exec(fence);
        }
    }
}

/// @cc [owner:ghuntley,label:recovery] group-reap-before-lock-release
/// The leader MUST remain unreaped until group termination, preventing PID
/// reuse. Adopted descendants in every process group/session MUST be reaped
/// before cleanup is confirmed;
/// unresolved cleanup MUST report failure and retain descendant-held locks.
#[expect(
    rustdoc::broken_intra_doc_links,
    reason = "the @cc contract metadata [owner:…,label:…] is code-contracts syntax, not an intra-doc link"
)]
fn terminate(child: &mut Child, pid: Pid) -> Result<(), u8> {
    let _ = kill_process_group(pid, Signal::KILL);
    let _ = child.kill();
    child.wait().map_err(|_| 126_u8)?;
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match wait(WaitOptions::NOHANG) {
            Ok(Some(_)) | Err(Errno::INTR) => {}
            Err(Errno::CHILD) => return Ok(()),
            Err(_) => return Err(126),
            Ok(None) if Instant::now() >= deadline => return Err(126),
            Ok(None) => std::thread::sleep(Duration::from_millis(5)),
        }
    }
}

fn run(request: Request) -> Result<u8, u8> {
    set_child_subreaper(Some(getpid())).map_err(|_| 126_u8)?;
    let _slot = admission(&request.directory)?;
    let _repository = if request.shared {
        None
    } else {
        Some(lock(
            &request
                .directory
                .join(format!(".enrico-{}.lock", request.repository)),
            false,
        )?)
    };
    let (reader, writer) =
        rustix::pipe::pipe_with(rustix::pipe::PipeFlags::CLOEXEC).map_err(|_| 126_u8)?;
    let errors = writer.try_clone().map_err(|_| 126_u8)?;
    let mut command = Command::new(request.executable);
    command
        .args(request.arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::from(writer))
        .stderr(Stdio::from(errors))
        .process_group(0);
    child_fence::install(&mut command, getpid());
    let mut child = command.spawn().map_err(|_| 126_u8)?;
    drop(command);
    let pid = Pid::from_raw(i32::try_from(child.id()).map_err(|_| 126_u8)?).ok_or(126_u8)?;
    let outcome = stream(&mut child, &reader, request.timeout, request.limit);
    terminate(&mut child, pid)?;
    outcome
}

/// @cc [owner:ghuntley,label:capacity;recovery] caller-responsive-stream
/// Forwarding MUST retain at most one bounded chunk, observe caller EOF even
/// while stdout is blocked, and preserve exact bytes within the command limit.
#[expect(
    rustdoc::broken_intra_doc_links,
    clippy::too_many_lines,
    reason = "the @cc metadata is code-contracts syntax, not an intra-doc link; one poll loop owns the caller, child and output state that the bounded-chunk contract reasons about"
)]
fn stream(child: &mut Child, reader: &OwnedFd, timeout: Duration, limit: usize) -> Result<u8, u8> {
    let input = io::stdin();
    let output = io::stdout();
    rustix::fs::fcntl_setfl(reader, OFlags::NONBLOCK).map_err(|_| 126_u8)?;
    rustix::fs::fcntl_setfl(output.as_fd(), OFlags::NONBLOCK).map_err(|_| 126_u8)?;
    let deadline = Instant::now() + timeout;
    let mut pending = Vec::<u8>::new();
    let mut written = 0_usize;
    let mut total = 0_usize;
    let mut ended = false;
    let mut status = None::<u8>;
    loop {
        if Instant::now() >= deadline {
            return Err(124);
        }
        let mut fds = [
            PollFd::from_borrowed_fd(input.as_fd(), PollFlags::IN | PollFlags::HUP),
            PollFd::from_borrowed_fd(
                reader.as_fd(),
                if pending.is_empty() && !ended {
                    PollFlags::IN | PollFlags::HUP
                } else {
                    PollFlags::empty()
                },
            ),
            PollFd::from_borrowed_fd(
                output.as_fd(),
                if pending.is_empty() {
                    PollFlags::empty()
                } else {
                    PollFlags::OUT
                },
            ),
        ];
        match poll(
            &mut fds,
            Some(&Timespec {
                tv_sec: 0,
                tv_nsec: 20_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return Err(126),
            Ok(_) => {}
        }
        if !fds[0].revents().is_empty() {
            return Err(126);
        }
        if pending.is_empty() && !ended {
            #[expect(
                clippy::large_stack_arrays,
                reason = "one 64 KiB CHUNK on the main thread stack is the single bounded read buffer"
            )]
            let mut bytes = [0_u8; CHUNK];
            match rustix::io::read(reader, &mut bytes) {
                Ok(0) => ended = true,
                Ok(count) => {
                    total = total.checked_add(count).ok_or(125_u8)?;
                    if total > limit {
                        return Err(125);
                    }
                    pending.extend_from_slice(&bytes[..count]);
                    written = 0;
                }
                Err(Errno::AGAIN | Errno::INTR) => {}
                Err(_) => return Err(126),
            }
        }
        if !pending.is_empty() {
            match rustix::io::write(output.as_fd(), &pending[written..]) {
                Ok(0) => return Err(126),
                Ok(count) => {
                    written += count;
                    if written == pending.len() {
                        pending.clear();
                        written = 0;
                    }
                }
                Err(Errno::AGAIN | Errno::INTR) => {}
                Err(_) => return Err(126),
            }
        }
        if status.is_none() {
            let pid =
                Pid::from_raw(i32::try_from(child.id()).map_err(|_| 126_u8)?).ok_or(126_u8)?;
            match waitid(
                WaitId::Pid(pid),
                WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
            ) {
                Ok(value) => {
                    status = value.map(|value| {
                        value
                            .exit_status()
                            .and_then(|code| u8::try_from(code).ok())
                            .unwrap_or(127)
                    });
                }
                Err(Errno::INTR) => continue,
                Err(_) => return Err(126),
            }
            if status.is_some() {
                if let Some(pid) = Pid::from_raw(i32::try_from(child.id()).map_err(|_| 126_u8)?) {
                    let _ = kill_process_group(pid, Signal::KILL);
                }
            }
        }
        if ended && pending.is_empty() {
            if let Some(code) = status {
                return Ok(code);
            }
        }
    }
}

fn main() -> ExitCode {
    let arguments: Result<Vec<String>, _> = std::env::args_os()
        .skip(1)
        .map(std::ffi::OsString::into_string)
        .collect();
    let result = arguments
        .map_err(|_| 64_u8)
        .and_then(|code| parse(&code).ok_or(64_u8))
        .and_then(run);
    ExitCode::from(result.unwrap_or_else(|code| code))
}
