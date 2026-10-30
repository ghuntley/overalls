//! Native Unix command deadlines without an external timeout executable.

use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub(super) struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

struct Group(Option<libc::pid_t>);

impl Group {
    fn kill(&mut self) {
        let Some(pid) = self.0.take() else {
            return;
        };
        // SAFETY: the child was started in a new process group with this PID.
        // No command or parent process belongs to the executor's own group.
        unsafe { libc::killpg(pid, libc::SIGKILL) };
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        self.kill();
    }
}

struct Pipe<R> {
    source: R,
    bytes: Vec<u8>,
    eof: bool,
}

impl<R: Read + AsRawFd> Pipe<R> {
    fn new(source: R) -> io::Result<Self> {
        let fd = source.as_raw_fd();
        // SAFETY: source owns the descriptor; only its status flags change.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: as above; F_SETFL only adds O_NONBLOCK to the owned descriptor.
        if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            source,
            bytes: Vec::new(),
            eof: false,
        })
    }

    fn drain(&mut self, limit: usize) -> io::Result<()> {
        let mut buffer = [0_u8; 4096];
        // Bound work per turn so an endlessly writing pipe cannot prevent
        // checking the deadline or draining the other output stream.
        for _ in 0..16 {
            match self.source.read(&mut buffer) {
                Ok(0) => {
                    self.eof = true;
                    break;
                }
                Ok(count) => {
                    let retained = count.min(limit.saturating_sub(self.bytes.len()));
                    self.bytes.extend_from_slice(&buffer[..retained]);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

/// @cc [owner:ghuntley,label:security;recovery] native-command-duration-output
/// Native command execution MUST use a separate process group, concurrently
/// drain both output pipes without blocking past the deadline, and retain at
/// most `limit` bytes per stream. At completion, deadline or failure it MUST
/// kill that group and reap the direct child. Descendants that explicitly
/// escape that group MUST NOT keep the executor blocked on inherited pipes.
/// The current lease/stop callback MUST authorize spawning and every authority
/// polling turn; refusal MUST kill and reap without returning command output.
/// Child collection MUST enforce the deadline even while a lease RPC blocks.
pub(super) fn run(
    command: &mut Command,
    limit: usize,
    budget: Duration,
    heartbeat: &mut impl FnMut() -> bool,
) -> io::Result<Output> {
    if !heartbeat() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let cancelled = AtomicBool::new(false);
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::scope(|scope| {
        let cancellation = &cancelled;
        // Start the child only inside a successfully created scoped worker.
        // Joining that worker also guarantees cleanup before this call returns.
        let _worker = thread::Builder::new()
            .name("native-command".to_owned())
            .spawn_scoped(scope, move || {
                let _ = sender.send(collect(command, limit, budget, cancellation));
            })?;
        loop {
            if !heartbeat() {
                cancelled.store(true, Ordering::Release);
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            match receiver.recv_timeout(Duration::from_millis(5)) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::other("native command worker unavailable"));
                }
            }
        }
    })
}

fn collect(
    command: &mut Command,
    limit: usize,
    budget: Duration,
    cancelled: &AtomicBool,
) -> io::Result<Output> {
    if cancelled.load(Ordering::Acquire) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let deadline = Instant::now() + budget;
    command
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let Ok(pid) = libc::pid_t::try_from(child.id()) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::other("invalid native child PID"));
    };
    let mut group = Group(Some(pid));
    let result = (|| {
        let mut stdout = Pipe::new(
            child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("missing native stdout"))?,
        )?;
        let mut stderr = Pipe::new(
            child
                .stderr
                .take()
                .ok_or_else(|| io::Error::other("missing native stderr"))?,
        )?;
        let mut status = None;
        loop {
            if cancelled.load(Ordering::Acquire) {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            stdout.drain(limit)?;
            stderr.drain(limit)?;
            if status.is_none() {
                status = child.try_wait()?;
                if status.is_some() {
                    group.kill();
                }
            }
            if status.is_some() && stdout.eof && stderr.eof {
                break;
            }
            if Instant::now() >= deadline {
                group.kill();
                if status.is_none() {
                    let _ = child.kill();
                    status = Some(child.wait()?);
                }
                stdout.drain(limit)?;
                stderr.drain(limit)?;
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        Ok(Output {
            status: status.ok_or_else(|| io::Error::other("missing native command status"))?,
            stdout: stdout.bytes,
            stderr: stderr.bytes,
        })
    })();
    group.kill();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn drains_both_pipes_and_bounds_retained_output() {
        let output = run(
            Command::new("/bin/sh").args([
                "-c",
                "i=0; while [ $i -lt 5000 ]; do printf 1234; printf 5678 >&2; i=$((i+1)); done",
            ]),
            31,
            Duration::from_secs(5),
            &mut || true,
        )
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout.len(), 31);
        assert_eq!(output.stderr.len(), 31);
    }

    #[test]
    fn kills_a_waiting_command_at_its_deadline() {
        let start = Instant::now();
        let output = run(
            Command::new("/bin/sh").args(["-c", "sleep 30 & wait"]),
            32,
            Duration::from_millis(100),
            &mut || true,
        )
        .unwrap();
        assert!(!output.status.success());
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn inherited_background_pipes_do_not_block_after_shell_exit() {
        let start = Instant::now();
        let output = run(
            Command::new("/bin/sh").args(["-c", "sleep 30 & exit 0"]),
            32,
            Duration::from_secs(2),
            &mut || true,
        )
        .unwrap();
        assert!(output.status.success());
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn refused_authority_never_spawns_a_command() {
        let directory = tempfile::tempdir().unwrap();
        let marker = directory.path().join("started");
        let error = run(
            Command::new("/bin/sh")
                .args(["-c", "touch \"$1\"", "fixture"])
                .arg(&marker),
            32,
            Duration::from_secs(5),
            &mut || false,
        )
        .err()
        .unwrap();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(!marker.exists());
    }

    #[test]
    fn lost_authority_kills_and_reaps_the_running_group_without_returning_output() {
        let directory = tempfile::tempdir().unwrap();
        let marker = directory.path().join("started");
        let start = Instant::now();
        let error = run(
            Command::new("/bin/sh")
                .args([
                    "-c",
                    "sleep 30 & printf '%s\\n%s\\n' \"$$\" \"$!\" > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; printf private-fixture-output; wait",
                    "fixture",
                ])
                .arg(&marker),
            32,
            Duration::from_secs(5),
            &mut || !marker.exists(),
        )
        .err()
        .unwrap();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(start.elapsed() < Duration::from_secs(3));
        let pids: Vec<libc::pid_t> = fs::read_to_string(marker)
            .unwrap()
            .lines()
            .map(|value| value.parse().unwrap())
            .collect();
        assert_eq!(pids.len(), 2);
        // SAFETY: signal zero checks only the owned fixture's direct child.
        assert_eq!(unsafe { libc::kill(pids[0], 0) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
        // The direct child has already been reaped by the command runner.
        assert_eq!(
            // SAFETY: a null status pointer is permitted and WNOHANG never blocks.
            unsafe { libc::waitpid(pids[0], std::ptr::null_mut(), libc::WNOHANG) },
            -1
        );
        assert_eq!(
            io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
    }

    #[test]
    fn a_blocked_lease_check_cannot_extend_the_child_deadline() {
        let directory = tempfile::tempdir().unwrap();
        let completed = directory.path().join("completed");
        let mut initial = true;
        let output = run(
            Command::new("/bin/sh")
                .args(["-c", "sleep 1; touch \"$1\"", "fixture"])
                .arg(&completed),
            32,
            Duration::from_millis(100),
            &mut || {
                if initial {
                    initial = false;
                } else {
                    thread::sleep(Duration::from_millis(1200));
                }
                true
            },
        )
        .unwrap();
        assert!(!output.status.success());
        assert!(!completed.exists());
    }
}
