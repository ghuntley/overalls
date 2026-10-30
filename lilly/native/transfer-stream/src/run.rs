use crate::pin;
use crate::{Request, CREDIT_CAP_MS, DIAGNOSTICS_LIMIT, EXIT_IO, EXIT_SETUP, SPLICE_WINDOW};
use rustix::event::{PollFd, PollFlags};
use rustix::fs::OFlags;
use rustix::io::Errno;
use rustix::pipe::{pipe_with, splice, PipeFlags, SpliceFlags};
use rustix::process::{getpid, kill_process, kill_process_group, set_child_subreaper};
use rustix::process::{wait, waitid, Pid, Signal, WaitId, WaitIdOptions, WaitOptions};
use std::ffi::OsString;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::process::CommandExt as _;
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

/// Overwrite the 8-byte big-endian progress counter at offset 0.
fn report(progress: Option<BorrowedFd<'_>>, total: u64) -> Result<(), ()> {
    let Some(fd) = progress else {
        return Ok(());
    };
    let bytes = total.to_be_bytes();
    loop {
        match rustix::io::pwrite(fd, &bytes, 0) {
            Err(Errno::INTR) => {}
            Ok(8) => return Ok(()),
            _ => return Err(()),
        }
    }
}

/// The running register of one side of the pipeline.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Side {
    Running,
    Succeeded,
    Failed,
}

impl Side {
    /// Outcome mapping of one observed pair, mirroring the C order exactly.
    /// The 7-class requires both known-failed at the same observation quantum;
    /// join ordering belongs to the timing of the two exits, never causality.
    pub(crate) fn classify(self, other: Side) -> Option<u8> {
        match (self, other) {
            (Side::Failed, Side::Failed) => Some(7),
            (Side::Failed, _) => Some(5),
            (_, Side::Failed) => Some(6),
            (Side::Succeeded, Side::Succeeded) => Some(0),
            _ => None,
        }
    }
    /// Peek the leader without reaping; the reaps happen in cleanup so a group
    /// id cannot be re-adopted while the sibling side still runs.
    fn poll(child: &std::process::Child) -> Self {
        let pid = child.id();
        let Some(raw) = i32::try_from(pid).ok().and_then(Pid::from_raw) else {
            return Self::Failed;
        };
        match waitid(
            WaitId::Pid(raw),
            WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
        ) {
            Err(_) => Self::Failed,
            Ok(None) => Self::Running,
            Ok(Some(status)) => {
                if status.exited() && status.exit_status() == Some(0) {
                    Self::Succeeded
                } else {
                    Self::Failed
                }
            }
        }
    }
}

/// @cc [owner:ghuntley,label:recovery] transfer-reap-before-ownership-release
/// finish MUST kill both private process groups and reap all adopted children
/// across every process group/session before
/// the helper exits (hostd releases the stream lease only after that exit).
/// Leaders remain unreaped until this cleanup, preventing
/// PID reuse while another side still runs. Reap uncertainty never confirms
/// quiescence.
fn finish(
    producer: &mut std::process::Child,
    consumer: Option<&mut std::process::Child>,
    status: u8,
) -> u8 {
    let mut uncertain = false;
    if let Some(pid) = i32::try_from(producer.id()).ok().and_then(Pid::from_raw) {
        let _ = kill_process_group(pid, Signal::KILL);
        let _ = kill_process(pid, Signal::KILL);
    } else {
        uncertain = true;
        let _ = producer.kill();
    }
    let mut consumer = consumer;
    if let Some(side) = consumer.as_mut() {
        if let Some(pid) = i32::try_from(side.id()).ok().and_then(Pid::from_raw) {
            let _ = kill_process_group(pid, Signal::KILL);
            let _ = kill_process(pid, Signal::KILL);
        } else {
            uncertain = true;
            let _ = side.kill();
        }
    }
    uncertain |= producer.wait().is_err();
    if let Some(side) = consumer.as_mut() {
        uncertain |= side.wait().is_err();
    }
    // Subreaper: adopted descendants are ours until ECHILD.
    loop {
        match wait(WaitOptions::empty()) {
            Err(Errno::INTR) | Ok(_) => {}
            Err(Errno::CHILD) => return if uncertain { EXIT_IO } else { status },
            Err(_) => return EXIT_IO,
        }
    }
}

/// Run the pipeline. The progress descriptor, when given, is borrowed from
/// the process's inherited table.
pub fn run(request: &Request) -> u8 {
    if set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_SETUP;
    }
    #[expect(
        unsafe_code,
        reason = "borrowing the caller-opened progress descriptor by number"
    )]
    // SAFETY: the descriptor number came from the trusted caller, which
    // opened it for this process; it stays open for the whole run and is
    // only ever borrowed.
    let progress = request
        .progress
        .map(|fd| unsafe { BorrowedFd::borrow_raw(fd) });
    if let Some(fd) = progress {
        if rustix::fs::fstat(fd).map_or(true, |stat| stat.st_mode & libc::S_IFMT != libc::S_IFREG)
            || report(Some(fd), 0).is_err()
        {
            return EXIT_SETUP;
        }
    }
    let pipes = pipe_with(PipeFlags::CLOEXEC)
        .and_then(|data| pipe_with(PipeFlags::CLOEXEC).map(|sink| (data, sink)))
        .and_then(|pair| pipe_with(PipeFlags::CLOEXEC).map(|diag| (pair.0, pair.1, diag)));
    let Ok((data, sink, diag)) = pipes else {
        return EXIT_SETUP;
    };
    let (data_reader, data_writer) = data;
    let (sink_reader, sink_writer) = sink;
    let (diag_reader, diag_writer) = diag;
    if rustix::fs::fcntl_setfl(&diag_reader, OFlags::NONBLOCK).is_err() {
        return EXIT_SETUP;
    }
    transfer(
        request,
        data_reader,
        data_writer,
        sink_reader,
        sink_writer,
        diag_reader,
        diag_writer,
        progress,
    )
}

fn spawn(
    args: &[OsString],
    uid: Option<u32>,
    stdin: Stdio,
    stdout: Stdio,
    stderr: Stdio,
) -> Result<std::process::Child, ()> {
    // hostd already gave this process a cleared environment (PATH, LC_ALL).
    let mut builder = Process::new(args[0].clone());
    builder
        .args(&args[1..])
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr);
    builder.process_group(0);
    pin::to_caller(&mut builder, getpid(), uid);
    builder.spawn().map_err(|_| ())
}

/// The plumbing harness: three kernel pipes whose writer ends ride into the
/// two children and whose reader ends the caller owns.
#[expect(
    clippy::too_many_arguments,
    reason = "each of the six pipe ends has a distinct custody destination; a struct would hide which side owns which end"
)]
fn transfer(
    request: &Request,
    data_reader: OwnedFd,
    data_writer: OwnedFd,
    sink_reader: OwnedFd,
    sink_writer: OwnedFd,
    diag_reader: OwnedFd,
    diag_writer: OwnedFd,
    progress: Option<BorrowedFd<'_>>,
) -> u8 {
    // The C twin-dup2 puts one diag descriptor into both consumer channels.
    let Ok(consumer_stdout) = diag_writer.try_clone() else {
        return EXIT_SETUP;
    };
    let Ok(consumer_stderr) = diag_writer.try_clone() else {
        return EXIT_SETUP;
    };
    // Producer: stdin=null, stdout=data pipe, stderr=diag (same channel).
    let mut producer = match spawn(
        &request.producer,
        request.producer_uid,
        Stdio::null(),
        Stdio::from(data_writer),
        Stdio::from(diag_writer),
    ) {
        Err(()) => return EXIT_SETUP,
        Ok(child) => child,
    };
    // Consumer: stdin=sink reader; stdout and stderr both ride diag into the
    // bounded discard, exactly like the C twin-dup2.
    let mut consumer = match spawn(
        &request.consumer,
        request.consumer_uid,
        Stdio::from(sink_reader),
        Stdio::from(consumer_stdout),
        Stdio::from(consumer_stderr),
    ) {
        Err(()) => {
            let _ = finish(&mut producer, None, EXIT_SETUP);
            return EXIT_SETUP;
        }
        Ok(child) => child,
    };
    sweep(
        request,
        &mut producer,
        &mut consumer,
        data_reader,
        sink_writer,
        diag_reader,
        progress,
    )
}

/// Throttle credit after `elapsed_ms` of monotonic time at `rate` bytes per
/// second; a zero rate is unthrottled and leaves the credit untouched.
pub(crate) fn refill(credit: i64, elapsed_ms: i64, rate: u64) -> i64 {
    if rate != 0 && elapsed_ms > 0 {
        // Clamp elapsed before multiplication to bound arithmetic after suspension.
        let refill = elapsed_ms.min(1000) * i64::try_from(rate).unwrap_or(CREDIT_CAP_MS);
        credit.saturating_add(refill).min(CREDIT_CAP_MS)
    } else {
        credit
    }
}

/// The splice window the current credit allows.
pub(crate) fn window(credit: i64, rate: u64) -> usize {
    if rate != 0 {
        usize::try_from(credit / 1000)
            .unwrap_or(usize::MAX)
            .min(SPLICE_WINDOW)
    } else {
        SPLICE_WINDOW
    }
}

/// Throttle credit after `count` bytes were spliced.
pub(crate) fn debit(credit: i64, count: usize, rate: u64) -> i64 {
    if rate != 0 {
        credit - i64::try_from(count).unwrap_or(0) * 1000
    } else {
        credit
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "one reviewed poll loop: deadline, throttle, splice, progress, diagnostics and outcome must stay in order"
)]
#[expect(
    clippy::needless_pass_by_value,
    reason = "sweep owns the data and diagnostics readers so they close when the pipeline ends"
)]
fn sweep(
    request: &Request,
    producer: &mut std::process::Child,
    consumer: &mut std::process::Child,
    data_reader: OwnedFd,
    sink_writer: OwnedFd,
    diag_reader: OwnedFd,
    progress: Option<BorrowedFd<'_>>,
) -> u8 {
    let mut last = Instant::now();
    let deadline = last + Duration::from_millis(request.timeout_ms);
    let mut credit: i64 = CREDIT_CAP_MS;
    let mut eof = false;
    let mut copied_total: u64 = 0;
    let mut reported_at = last;
    let mut diagnostics = 0_usize;
    let mut sink = Some(sink_writer);
    loop {
        if Instant::now() >= deadline {
            return finish(producer, Some(consumer), 2);
        }
        let now = Instant::now();
        #[expect(
            clippy::cast_possible_truncation,
            reason = "monotonic time between two sweeps is far below i64::MAX milliseconds (292 million years)"
        )]
        let elapsed = now.duration_since(last).as_millis() as i64;
        last = now;
        credit = refill(credit, elapsed, request.rate);
        let mut delay = 1;
        if !eof {
            let available = window(credit, request.rate);
            if available > 0 {
                #[expect(
                    clippy::expect_used,
                    reason = "sink is Some until eof is set, and this splice runs only while !eof"
                )]
                let live_sink = sink.as_ref().expect("live sink");
                match splice(
                    &data_reader,
                    None,
                    live_sink,
                    None,
                    available,
                    SpliceFlags::NONBLOCK | SpliceFlags::MOVE,
                ) {
                    Ok(0) => {
                        drop(sink.take());
                        eof = true;
                    }
                    Ok(count) => {
                        delay = 0;
                        copied_total = match copied_total.checked_add(count as u64) {
                            None => return finish(producer, Some(consumer), 1),
                            Some(total) => total,
                        };
                        credit = debit(credit, count, request.rate);
                    }
                    Err(Errno::AGAIN | Errno::INTR) => {}
                    Err(_) => return finish(producer, Some(consumer), 8),
                }
            }
        }
        if progress.is_some() && now.duration_since(reported_at).as_millis() >= 1000 {
            if report(progress, copied_total).is_err() {
                return finish(producer, Some(consumer), 4);
            }
            reported_at = now;
        }
        let mut fds = [PollFd::from_borrowed_fd(
            diag_reader.as_fd(),
            PollFlags::IN | PollFlags::HUP,
        )];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: delay * 1_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return finish(producer, Some(consumer), 4),
            Ok(_) => {}
        }
        loop {
            let mut discard = [0_u8; 4096];
            match rustix::io::read(&diag_reader, &mut discard) {
                Err(Errno::AGAIN | Errno::INTR) | Ok(0) => break,
                Err(_) => return finish(producer, Some(consumer), 3),
                Ok(count) => {
                    diagnostics += count;
                    if diagnostics > DIAGNOSTICS_LIMIT {
                        return finish(producer, Some(consumer), 3);
                    }
                }
            }
        }
        let a = Side::poll(producer);
        let b = Side::poll(consumer);
        match a.classify(b) {
            Some(0) => {
                // The completion record reports the final counter.
                if report(progress, copied_total).is_err() {
                    return finish(producer, Some(consumer), 4);
                }
                let status = finish(producer, Some(consumer), 0);
                // Reaped writers cannot race this final bounded diagnostic drain.
                loop {
                    let mut discard = [0_u8; 4096];
                    match rustix::io::read(&diag_reader, &mut discard) {
                        Err(_) | Ok(0) => break,
                        Ok(count) => diagnostics += count,
                    }
                }
                return if diagnostics > DIAGNOSTICS_LIMIT {
                    3
                } else {
                    status
                };
            }
            Some(code) => return finish(producer, Some(consumer), code),
            None => {}
        }
    }
}
