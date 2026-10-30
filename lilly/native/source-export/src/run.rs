use crate::{
    fd_abi, install_cancel_handlers, parse_control, pin_sender, Control, Request, CANCELLED,
    CONTROL_FRAME_LIMIT, DIAGNOSTICS_LIMIT, EXIT_DEADLINE, EXIT_DIAGNOSTICS, EXIT_INSECURE_LOCK,
    EXIT_IO, EXIT_REVOKED, EXIT_SENDER_FAILED, EXIT_SETUP,
};
use rustix::event::{PollFd, PollFlags};
use rustix::fs::{flock, open, FlockOperation, Mode as FileMode, OFlags};
use rustix::io::Errno;
use rustix::pipe::{pipe_with, PipeFlags};
use rustix::process::{
    getpid, kill_process_group, wait, waitid, Pid, Signal, WaitId, WaitIdOptions, WaitOptions,
};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::process::CommandExt as _;
use std::path::Path;
use std::process::{Command as Process, Stdio};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

/// The lock-file custody check for the sender's private boundary. Returns a
/// held exclusive lock on success.
fn acquire_lock(path: &Path) -> Result<Held, u8> {
    let descriptor = open(
        path,
        OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW,
        FileMode::from_raw_mode(0o600),
    )
    .map_err(|_| EXIT_INSECURE_LOCK)?;
    let file: std::fs::File = descriptor.into();
    let metadata = file.metadata().map_err(|_| EXIT_INSECURE_LOCK)?;
    {
        use std::os::unix::fs::MetadataExt as _;
        // This process's uid, or the owner of the lock's directory (Lilly's
        // service uid when it runs unprivileged, ADR-0182): never a third party.
        let directory_owner = path
            .parent()
            .and_then(|parent| std::fs::symlink_metadata(parent).ok())
            .filter(std::fs::Metadata::is_dir)
            .map(|parent| parent.uid());
        let private = metadata.is_file()
            && metadata.nlink() == 1
            && (metadata.uid() == rustix::process::geteuid().as_raw()
                || Some(metadata.uid()) == directory_owner)
            && metadata.mode() & 0o022 == 0;
        if !private {
            return Err(EXIT_INSECURE_LOCK);
        }
    }
    let fd: OwnedFd = file.into();
    flock(&fd, FlockOperation::NonBlockingLockExclusive).map_err(|_| EXIT_INSECURE_LOCK)?;
    if rustix::fs::fchmod(&fd, FileMode::from_raw_mode(0o600)).is_err() {
        return Err(EXIT_INSECURE_LOCK);
    }
    Ok(Held { descriptor: fd })
}

/// The custody-owned lock for the sweep's duration.
pub struct Held {
    #[allow(dead_code)]
    descriptor: OwnedFd,
}

fn write_all(fd: BorrowedFd<'_>, mut buffer: &[u8]) -> Result<(), ()> {
    while !buffer.is_empty() {
        match rustix::io::write(fd, buffer) {
            Err(Errno::INTR) => continue,
            Err(_) | Ok(0) => return Err(()),
            Ok(count) => buffer = &buffer[count..],
        }
    }
    Ok(())
}

pub fn run(request: &Request) -> u8 {
    // The entry points close the attacker-inherited window: f3/f4 must never
    // ride into the sender.
    let control = fd_abi::control();
    let ack = fd_abi::ack();
    install_cancel_handlers();
    // Sender's descendants reparent here for reaping before ownership releases.
    if rustix::process::set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_SETUP;
    }
    if rustix::io::fcntl_setfd(control, rustix::io::FdFlags::CLOEXEC).is_err()
        || rustix::io::fcntl_setfd(ack, rustix::io::FdFlags::CLOEXEC).is_err()
    {
        return EXIT_SETUP;
    }
    let mut deadline = Instant::now() + Duration::from_millis(u64::from(request.lease_ms));
    // Startup phase: exactly one bounded control line before ownership.
    let mut frame: Vec<u8> = Vec::with_capacity(CONTROL_FRAME_LIMIT);
    loop {
        if CANCELLED.load(Ordering::Relaxed) || Instant::now() >= deadline {
            return EXIT_REVOKED;
        }
        match rustix::event::poll(
            &mut [PollFd::from_borrowed_fd(
                control,
                PollFlags::IN | PollFlags::HUP,
            )],
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 50_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return EXIT_IO,
            Ok(0) => continue,
            Ok(_) => {}
        }
        let mut byte = [0_u8; 1];
        match rustix::io::read(control, &mut byte) {
            Err(_) | Ok(0) => return EXIT_IO,
            Ok(_) => {}
        }
        if frame.len() >= CONTROL_FRAME_LIMIT {
            return EXIT_IO;
        }
        frame.push(byte[0]);
        if byte[0] == b'\n' {
            break;
        }
    }
    let _held = match acquire_lock(&request.lock) {
        Err(code) => return code,
        Ok(held) => held,
    };
    run_sender(request, control, ack, &mut deadline, &frame)
}

fn run_sender(
    request: &Request,
    control: BorrowedFd<'_>,
    ack: BorrowedFd<'_>,
    deadline: &mut Instant,
    startup_frame: &[u8],
) -> u8 {
    let (diag_read, diag_write) = match pipe_with(PipeFlags::CLOEXEC) {
        Err(_) => return EXIT_SETUP,
        Ok(pair) => pair,
    };
    if rustix::fs::fcntl_setfl(&diag_read, OFlags::NONBLOCK).is_err() {
        return EXIT_SETUP;
    }
    let mut child = match spawn_sender(request, diag_write) {
        Err(_) => return EXIT_SETUP,
        Ok(child) => child,
    };
    let Some(sender_pid) = i32::try_from(child.id()).ok().and_then(Pid::from_raw) else {
        return finish(&mut child, EXIT_SETUP);
    };
    if write_all(ack, startup_frame).is_err() {
        return finish(&mut child, EXIT_REVOKED);
    }
    if rustix::fs::fcntl_setfl(control, OFlags::NONBLOCK).is_err() {
        return finish(&mut child, EXIT_SETUP);
    }
    let mut frame: Vec<u8> = Vec::with_capacity(CONTROL_FRAME_LIMIT);
    let mut diagnostics_total = 0_usize;
    loop {
        if CANCELLED.load(Ordering::Relaxed) {
            return finish(&mut child, EXIT_REVOKED);
        }
        if Instant::now() >= *deadline {
            return finish(&mut child, EXIT_DEADLINE);
        }
        let mut fds = [
            PollFd::from_borrowed_fd(control, PollFlags::IN | PollFlags::HUP),
            PollFd::from_borrowed_fd(diag_read.as_fd(), PollFlags::IN | PollFlags::HUP),
        ];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 25_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return finish(&mut child, EXIT_REVOKED),
            Ok(_) => {}
        }
        if !fds[0].revents().is_empty() {
            let mut chunk = [0_u8; CONTROL_FRAME_LIMIT];
            match rustix::io::read(control, &mut chunk) {
                Ok(0) | Err(_) => return finish(&mut child, EXIT_REVOKED),
                Ok(count) => {
                    for byte in chunk[..count].iter() {
                        if *byte == b'\n' {
                            match parse_control(&frame) {
                                Some(Control::Renew(lease)) => {
                                    *deadline =
                                        Instant::now() + Duration::from_millis(u64::from(lease));
                                }
                                _ => return finish(&mut child, EXIT_REVOKED),
                            }
                            frame.clear();
                        } else {
                            if frame.len() >= CONTROL_FRAME_LIMIT - 1 {
                                return finish(&mut child, EXIT_REVOKED);
                            }
                            frame.push(*byte);
                        }
                    }
                }
            }
        }
        let mut discard = [0_u8; 4096];
        match rustix::io::read(&diag_read, &mut discard) {
            Err(Errno::AGAIN) | Err(Errno::INTR) => {}
            Err(_) => return finish(&mut child, EXIT_DIAGNOSTICS),
            Ok(count) => {
                diagnostics_total += count;
                if diagnostics_total > DIAGNOSTICS_LIMIT {
                    return finish(&mut child, EXIT_DIAGNOSTICS);
                }
            }
        }
        match waitid(
            WaitId::Pid(sender_pid),
            WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return finish(&mut child, EXIT_SENDER_FAILED),
            Ok(Some(status)) => {
                let code = if status.exit_status() == Some(0) {
                    0
                } else {
                    1
                };
                let finished = finish(&mut child, code);
                // Writers are reaped; drain the remaining bounded diagnostics.
                loop {
                    match rustix::io::read(&diag_read, &mut discard) {
                        Err(_) | Ok(0) => break,
                        Ok(count) => diagnostics_total += count,
                    }
                }
                if diagnostics_total > DIAGNOSTICS_LIMIT {
                    return EXIT_DIAGNOSTICS;
                }
                return finished;
            }
            Ok(None) => {}
        }
    }
}

fn spawn_sender(request: &Request, diag_write: OwnedFd) -> Result<std::process::Child, ()> {
    let mut builder = Process::new(&request.sender);
    builder
        .args(&request.arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::from(diag_write));
    builder.process_group(0);
    pin_sender::pin(&mut builder, getpid());
    builder.spawn().map_err(|_| ())
}

/// @cc [owner:ghuntley,label:recovery] source-export-reap-before-release
/// finish MUST kill the private sender process group and reap all adopted
/// children in every process group/session before releasing transfer ownership. The leader MUST remain
/// unreaped until this point, preventing PID reuse. An uncertain reap MUST
/// never confirm quiescence.
fn finish(child: &mut std::process::Child, status: u8) -> u8 {
    let pid = match i32::try_from(child.id()).ok().and_then(Pid::from_raw) {
        Some(pid) => pid,
        None => return EXIT_IO,
    };
    let _ = kill_process_group(pid, Signal::KILL);
    let _ = child.kill();
    if child.wait().is_err() {
        return EXIT_IO;
    }
    // Subreaper adoption: every grandchild is ours until ECHILD.
    loop {
        match wait(WaitOptions::empty()) {
            Err(Errno::INTR) => continue,
            Err(Errno::CHILD) => return status,
            Err(_) => return EXIT_IO,
            Ok(_) => continue,
        }
    }
}
