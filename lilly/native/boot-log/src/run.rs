use crate::log::open_log;
use crate::signal_reraise;
use crate::{Drained, Request, Retention, EXIT_CHILD_SETUP, EXIT_CUSTODY};
use rustix::io::Errno;
use rustix::pipe::{pipe_with, PipeFlags};
use std::os::fd::OwnedFd;
use std::os::unix::process::ExitStatusExt as _;
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

/// @cc [owner:ghuntley,label:recovery;security] bounded-byte-safe-boot-log
/// The child MUST be drained continuously; at most BOOT_LOG_LIMIT bytes of the
/// line-stamped stream (boot-log-line-timestamps) are persisted without other
/// interpretation, and output beyond the limit is discarded without blocking
/// or terminating the VM. The child's exit
/// status is preserved; a child dead by signal re-raises that signal so the
/// owning service observes a real signal death.
pub fn run(request: &Request) -> u8 {
    let mut output = match open_log(&request.log, request.reader) {
        Err(()) => return EXIT_CUSTODY,
        Ok(file) => file,
    };
    let Ok((reader, writer)) = pipe_with(PipeFlags::CLOEXEC) else {
        return EXIT_CHILD_SETUP;
    };
    let stderr_writer = match writer.try_clone() {
        Err(_) => return EXIT_CHILD_SETUP,
        Ok(clone) => clone,
    };
    let outcome = {
        let mut builder = Process::new(&request.program);
        builder
            .args(&request.arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::from(writer))
            .stderr(Stdio::from(stderr_writer));
        let spawned = builder.spawn();
        // Dropping the builder closes the parent's copies of both writer ends,
        // so the reader observes EOF exactly when the exec'd image closes them.
        drop(builder);
        spawned
    };
    let mut child = match outcome {
        Err(_) => return EXIT_CHILD_SETUP,
        Ok(child) => child,
    };
    let started = Instant::now();
    match drain(&reader, &mut output, &|| started.elapsed()) {
        Drained::Complete => {}
        Drained::ReadFailed | Drained::WriteFailed => return EXIT_CUSTODY,
    }
    drop(reader);
    settle(&mut child)
}

pub(crate) fn drain(
    reader: &OwnedFd,
    output: &mut std::fs::File,
    clock: &dyn Fn() -> Duration,
) -> Drained {
    let mut retention = Retention::new();
    let mut buffer = [0_u8; 65536];
    loop {
        match rustix::io::read(reader, &mut buffer) {
            Err(Errno::INTR) => continue,
            Err(_) => return Drained::ReadFailed,
            Ok(0) => return Drained::Complete,
            Ok(count) => {
                let kept = retention.admit(&buffer[..count], clock());
                if !kept.is_empty() {
                    use std::io::Write as _;
                    if output.write_all(kept).is_err() {
                        return Drained::WriteFailed;
                    }
                }
            }
        }
    }
}

pub(crate) fn settle(child: &mut std::process::Child) -> u8 {
    let status = match child.wait() {
        Err(_) => return EXIT_CHILD_SETUP,
        Ok(status) => status,
    };
    if let Some(code) = status.code() {
        return u8::try_from(code).unwrap_or(EXIT_CHILD_SETUP);
    }
    if let Some(signal) = status.signal() {
        // Die with the child's signal; unkillable dispositions land at 71.
        signal_reraise::re_raise(signal);
    }
    EXIT_CHILD_SETUP
}
