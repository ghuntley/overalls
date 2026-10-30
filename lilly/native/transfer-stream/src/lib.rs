#![deny(unsafe_code)]
#![doc = "Pipeline owner run by lilly-hostd. Disk bytes stay in kernel pipes."]

use rustix::event::{PollFd, PollFlags};
use rustix::fs::OFlags;
use rustix::io::Errno;
use rustix::pipe::{pipe_with, splice, PipeFlags, SpliceFlags};
use rustix::process::{getpid, kill_process, kill_process_group, set_child_subreaper};
use rustix::process::{wait, waitid, Pid, Signal, WaitId, WaitIdOptions, WaitOptions};
use std::ffi::{OsStr, OsString};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt as _;
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_IO: u8 = 74;

/// Byte total cap for the producer + consumer argument vector.
pub const ARGV_TOTAL_LIMIT: usize = 65536;
/// Maximum consumer argv entries.
pub const CONSUMER_ARGS_LIMIT: usize = 128;
/// Producer argv entries live between 1 and 128 inclusive.
pub const PRODUCER_ARGS_LIMIT: usize = 128;
/// Largest transferred diagnostics window in bytes.
pub const DIAGNOSTICS_LIMIT: usize = 65536;
/// Rate credit quantum, in byte-milliseconds (64 KiB per second of credit).
pub const CREDIT_CAP_MS: i64 = 65_536_000;
/// Per-iteration splice ceiling in bytes.
pub const SPLICE_WINDOW: usize = 65536;
/// Largest accepted byte rate.
pub const RATE_LIMIT: i64 = 1_073_741_824;

/// A validated invocation.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub timeout_ms: u64,
    /// Bytes per second; zero is unthrottled.
    pub rate: u64,
    /// An inherited descriptor receiving the progress counter.
    pub progress: Option<i32>,
    /// The uid (and equal gid) each side drops to; None keeps the helper's.
    pub producer_uid: Option<u32>,
    pub consumer_uid: Option<u32>,
    pub producer: Vec<OsString>,
    pub consumer: Vec<OsString>,
}

/// Strict decimal: nonempty, no leading zeros, digits only, then bounds.
fn number(text: &OsStr, min: i64, max: i64) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let value: i64 = text.parse().ok()?;
    (min..=max).contains(&value).then_some(value)
}

/// `-` or a strict decimal in `min..=max`.
fn optional(text: &OsStr, min: i64, max: i64) -> Option<Option<i64>> {
    if text.as_bytes() == b"-" {
        return Some(None);
    }
    number(text, min, max).map(Some)
}

/// Accepted side uids: never root, never the overflow uid.
pub const SIDE_UIDS: std::ops::RangeInclusive<i64> = 1..=4_294_967_294;
/// Accepted inherited progress descriptors.
pub const PROGRESS_FDS: std::ops::RangeInclusive<i64> = 3..=1023;

/// @cc [owner:ghuntley,label:security] transfer-cli-bounded-absolute
/// The command line MUST be: timeout (1000..=86400000 ms), rate
/// (0..=1073741824 bytes/s), progress descriptor (`-` or 3..=1023), producer
/// uid and consumer uid (`-` or 1..=4294967294, never root), producer count,
/// then absolute producer argv and absolute consumer argv whose byte span
/// never exceeds 65536. Anything else is a usage error. The caller (hostd)
/// derives every argv itself; this helper reads no environment settings.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [timeout, rate, progress, producer_uid, consumer_uid, producers, rest @ ..] = arguments
    else {
        return None;
    };
    let timeout_ms: u64 = u64::try_from(number(timeout, 1000, 86_400_000)?).ok()?;
    let rate = u64::try_from(number(rate, 0, RATE_LIMIT)?).ok()?;
    let progress = optional(progress, *PROGRESS_FDS.start(), *PROGRESS_FDS.end())?
        .and_then(|fd| i32::try_from(fd).ok());
    let uid = |text: &OsStr| -> Option<Option<u32>> {
        match optional(text, *SIDE_UIDS.start(), *SIDE_UIDS.end())? {
            None => Some(None),
            Some(uid) => Some(Some(u32::try_from(uid).ok()?)),
        }
    };
    let producer_uid = uid(producer_uid)?;
    let consumer_uid = uid(consumer_uid)?;
    let producer_count = usize::try_from(number(producers, 1, PRODUCER_ARGS_LIMIT as i64)?).ok()?;
    if rest.len() < producer_count + 1 || rest.len() - producer_count > CONSUMER_ARGS_LIMIT {
        return None;
    }
    let (producer, consumer) = rest.split_at(producer_count);
    if !producer[0].as_os_str().as_bytes().starts_with(b"/")
        || !consumer[0].as_os_str().as_bytes().starts_with(b"/")
    {
        return None;
    }
    if producer
        .iter()
        .chain(consumer.iter())
        .any(|arg| arg.is_empty() || arg.as_os_str().as_bytes().contains(&0))
    {
        return None;
    }
    let argument_bytes: usize = producer
        .iter()
        .chain(consumer.iter())
        .map(|arg| arg.as_os_str().as_bytes().len() + 1)
        .sum();
    if argument_bytes > ARGV_TOTAL_LIMIT {
        return None;
    }
    Some(Request {
        timeout_ms,
        rate,
        progress,
        producer_uid,
        consumer_uid,
        producer: producer.to_vec(),
        consumer: consumer.to_vec(),
    })
}

/// Overwrite the 8-byte big-endian progress counter at offset 0.
fn report(progress: Option<BorrowedFd<'_>>, total: u64) -> Result<(), ()> {
    let Some(fd) = progress else {
        return Ok(());
    };
    let bytes = total.to_be_bytes();
    loop {
        match rustix::io::pwrite(fd, &bytes, 0) {
            Err(Errno::INTR) => continue,
            Ok(8) => return Ok(()),
            _ => return Err(()),
        }
    }
}

/// The running register of one side of the pipeline.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Side {
    Running,
    Succeeded,
    Failed,
}

impl Side {
    /// Outcome mapping of one observed pair, mirroring the C order exactly.
    /// The 7-class requires both known-failed at the same observation quantum;
    /// join ordering belongs to the timing of the two exits, never causality.
    fn classify(self, other: Side) -> Option<u8> {
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
    #[allow(clippy::needless_option_as_deref)]
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
    #[allow(clippy::needless_option_as_deref)]
    if let Some(side) = consumer.as_mut() {
        uncertain |= side.wait().is_err();
    }
    // Subreaper: adopted descendants are ours until ECHILD.
    loop {
        match wait(WaitOptions::empty()) {
            Err(Errno::INTR) => continue,
            Err(Errno::CHILD) => return if uncertain { EXIT_IO } else { status },
            Err(_) => return EXIT_IO,
            Ok(_) => continue,
        }
    }
}

/// Run the pipeline. The progress descriptor, when given, is borrowed from
/// the process's inherited table.
pub fn run(request: &Request) -> u8 {
    if set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_SETUP;
    }
    #[allow(unsafe_code)]
    // SAFETY: the descriptor number came from the trusted caller, which
    // opened it for this process; it stays open for the whole run and is
    // only ever borrowed.
    let progress = request
        .progress
        .map(|fd| unsafe { BorrowedFd::borrow_raw(fd) });
    if let Some(fd) = progress {
        if rustix::fs::fstat(fd)
            .map(|stat| stat.st_mode & libc::S_IFMT != libc::S_IFREG)
            .unwrap_or(true)
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

#[allow(unsafe_code)]
mod pin {
    use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    /// @cc [owner:ghuntley,label:security] transfer-pins-children-to-owner
    /// Producer and consumer must not outlive the helper: set the parent-death
    /// signal and verify the recorded parent before exec. A side given a uid
    /// MUST drop every supplementary group, then its gid and uid (both that
    /// uid), and set no_new_privs before exec; the parent-death signal MUST be
    /// set after that credential change (which may clear it). Any failure aborts
    /// the spawn.
    /// The closure performs only async-signal-safe system calls.
    pub(super) fn to_caller(command: &mut Command, parent: Pid, uid: Option<u32>) {
        unsafe {
            command.pre_exec(move || {
                // Credentials change first, so the death signal is set on the
                // final credentials (a credential change may clear it).
                if let Some(uid) = uid {
                    if libc::setgroups(0, std::ptr::null()) != 0
                        || libc::setresgid(uid, uid, uid) != 0
                        || libc::setresuid(uid, uid, uid) != 0
                        || libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
                    {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                if set_parent_process_death_signal(Some(Signal::KILL)).is_err()
                    || getppid() != Some(parent)
                {
                    return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
                }
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
                Ok(())
            })
        };
    }
}

/// The plumbing harness: three kernel pipes whose writer ends ride into the
/// two children and whose reader ends the caller owns.
#[allow(clippy::too_many_arguments)]
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
    let consumer_stdout = match diag_writer.try_clone() {
        Err(_) => return EXIT_SETUP,
        Ok(clone) => clone,
    };
    let consumer_stderr = match diag_writer.try_clone() {
        Err(_) => return EXIT_SETUP,
        Ok(clone) => clone,
    };
    // Producer: stdin=null, stdout=data pipe, stderr=diag (same channel).
    let mut producer = match spawn(
        &request.producer,
        request.producer_uid,
        Stdio::null(),
        Stdio::from(data_writer),
        Stdio::from(diag_writer),
    ) {
        Err(_) => return EXIT_SETUP,
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
        Err(_) => {
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
fn refill(credit: i64, elapsed_ms: i64, rate: u64) -> i64 {
    if rate != 0 && elapsed_ms > 0 {
        // Clamp elapsed before multiplication to bound arithmetic after suspension.
        let refill = elapsed_ms.min(1000) * i64::try_from(rate).unwrap_or(CREDIT_CAP_MS);
        credit.saturating_add(refill).min(CREDIT_CAP_MS)
    } else {
        credit
    }
}

/// The splice window the current credit allows.
fn window(credit: i64, rate: u64) -> usize {
    if rate != 0 {
        usize::try_from(credit / 1000)
            .unwrap_or(usize::MAX)
            .min(SPLICE_WINDOW)
    } else {
        SPLICE_WINDOW
    }
}

/// Throttle credit after `count` bytes were spliced.
fn debit(credit: i64, count: usize, rate: u64) -> i64 {
    if rate != 0 {
        credit - i64::try_from(count).unwrap_or(0) * 1000
    } else {
        credit
    }
}

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
        let elapsed = now.duration_since(last).as_millis() as i64;
        last = now;
        credit = refill(credit, elapsed, request.rate);
        let mut delay = 1;
        if !eof {
            let available = window(credit, request.rate);
            if available > 0 {
                match splice(
                    &data_reader,
                    None,
                    sink.as_ref().expect("live sink"),
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
                    Err(Errno::AGAIN) | Err(Errno::INTR) => {}
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
                Err(Errno::AGAIN) | Err(Errno::INTR) => break,
                Err(_) => return finish(producer, Some(consumer), 3),
                Ok(0) => break,
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

#[cfg(test)]
mod tests;
