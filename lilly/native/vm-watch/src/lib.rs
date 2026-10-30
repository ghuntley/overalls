#![deny(unsafe_code)]
#![doc = "Event-driven VMM exit watcher; stdout is a private fixed-line protocol."]

use rustix::event::{poll, PollFd, PollFlags};
use rustix::fs::inotify;
use rustix::process::{pidfd_open, Pid, PidfdFlags};
use std::ffi::OsString;
use std::io::Write;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};

/// Largest Linux PID (`PID_MAX_LIMIT` on 64-bit).
pub const PID_MAX: u32 = 4_194_304;
const CGROUP_ROOT: &str = "/sys/fs/cgroup/";

/// The exact VMM process and the unit cgroup that must contain it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Target {
    pub cgroup: PathBuf,
    pub pid: u32,
}

/// How a watch ended. `Detached` means Lilly closed our stdin: nothing to report.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Exited,
    Detached,
    Error,
}

/// @cc [owner:ghuntley,label:security] vm-watch-closed-arguments
/// Only `<cgroup> <pid>` is accepted: an absolute, normalized UTF-8 path
/// strictly below /sys/fs/cgroup with no `.`/`..` components or trailing
/// slash, and a canonical decimal PID in `1..=PID_MAX`. Anything else selects no
/// process and the helper reports `error`.
pub fn parse_cli(arguments: &[OsString]) -> Option<Target> {
    let [cgroup, pid] = arguments else {
        return None;
    };
    Some(Target {
        cgroup: cgroup_path(cgroup.to_str()?)?,
        pid: pid_value(pid.to_str()?)?,
    })
}

pub fn cgroup_path(text: &str) -> Option<PathBuf> {
    let rest = text.strip_prefix(CGROUP_ROOT)?;
    if rest.is_empty() || rest.ends_with('/') || text.len() > 4096 || text.contains('\0') {
        return None;
    }
    // Check the text itself: Path::components() silently drops `.` segments,
    // which would admit the cgroup root (`/sys/fs/cgroup/.`).
    let segments_ok = rest
        .split('/')
        .all(|segment| !segment.is_empty() && segment != "." && segment != "..");
    segments_ok.then(|| Path::new(text).to_path_buf())
}

pub fn pid_value(text: &str) -> Option<u32> {
    let bytes = text.as_bytes();
    if bytes.is_empty()
        || bytes.len() > 7
        || bytes[0] == b'0'
        || !bytes.iter().all(u8::is_ascii_digit)
    {
        return None;
    }
    text.parse::<u32>()
        .ok()
        .filter(|pid| (1..=PID_MAX).contains(pid))
}

/// `Some(true)` while the cgroup holds processes, `Some(false)` once empty.
pub fn populated(events: &str) -> Option<bool> {
    events.lines().find_map(|line| match line.split_once(' ') {
        Some(("populated", "1")) => Some(true),
        Some(("populated", "0")) => Some(false),
        _ => None,
    })
}

/// Whether `procs` (a cgroup.procs listing) contains exactly `pid`.
pub fn member(procs: &str, pid: u32) -> bool {
    procs
        .lines()
        .any(|line| pid_value(line.trim()) == Some(pid))
}

/// @cc [owner:ghuntley,label:security;isolation] vm-watch-bound-exit
/// The watcher MUST bind the PID with a pidfd before checking it is a member
/// of the unit cgroup, so a reused PID outside the unit is refused. It MUST
/// print `armed` only after both checks and the cgroup.events watch exist, and
/// MUST print `exited` as soon as the pidfd becomes readable or the cgroup is
/// no longer populated. Lost evidence prints `error`; stdin EOF detaches
/// silently. It never signals, reads guest data or changes any cgroup.
pub fn watch(target: &Target, out: &mut impl Write) -> Outcome {
    watch_with(target, out, &rustix::stdio::stdin())
}

/// `watch/2` with an explicit parent descriptor whose EOF or input detaches.
pub fn watch_with(target: &Target, out: &mut impl Write, parent: &impl AsFd) -> Outcome {
    match arm(target) {
        Ok(Armed::AlreadyEmpty) => Outcome::Exited,
        Ok(Armed::Watching(pidfd, notify)) => {
            if writeln!(out, "armed").and_then(|()| out.flush()).is_err() {
                return Outcome::Error;
            }
            wait(target, &pidfd, &notify, parent)
        }
        Err(()) => Outcome::Error,
    }
}

enum Armed {
    AlreadyEmpty,
    Watching(std::os::fd::OwnedFd, std::os::fd::OwnedFd),
}

fn arm(target: &Target) -> Result<Armed, ()> {
    let pid = Pid::from_raw(i32::try_from(target.pid).map_err(|_| ())?).ok_or(())?;
    let pidfd = pidfd_open(pid, PidfdFlags::empty()).map_err(|_| ())?;
    let procs = std::fs::read_to_string(target.cgroup.join("cgroup.procs")).map_err(|_| ())?;
    if !member(&procs, target.pid) {
        return Err(());
    }
    let notify = inotify::init(inotify::CreateFlags::CLOEXEC | inotify::CreateFlags::NONBLOCK)
        .map_err(|_| ())?;
    inotify::add_watch(
        &notify,
        target.cgroup.join("cgroup.events"),
        inotify::WatchFlags::MODIFY,
    )
    .map_err(|_| ())?;
    match events(target) {
        Some(false) => Ok(Armed::AlreadyEmpty),
        Some(true) => Ok(Armed::Watching(pidfd, notify)),
        None => Err(()),
    }
}

fn events(target: &Target) -> Option<bool> {
    populated(&std::fs::read_to_string(target.cgroup.join("cgroup.events")).ok()?)
}

fn wait(target: &Target, pidfd: &impl AsFd, notify: &impl AsFd, parent: &impl AsFd) -> Outcome {
    let mut buffer = [std::mem::MaybeUninit::<u8>::uninit(); 4096];
    loop {
        let mut fds = [
            PollFd::new(pidfd, PollFlags::IN),
            PollFd::new(notify, PollFlags::IN),
            PollFd::new(parent, PollFlags::IN),
        ];
        if poll(&mut fds, None).is_err() {
            continue;
        }
        let [vmm, cgroup, parent] = fds.map(|fd| fd.revents());
        if !vmm.is_empty() {
            return Outcome::Exited;
        }
        if !parent.is_empty() {
            // Lilly closed the port (or sent data, which is not part of the protocol).
            return Outcome::Detached;
        }
        if !cgroup.is_empty() {
            drain(notify, &mut buffer);
            match events(target) {
                Some(true) => {}
                Some(false) => return Outcome::Exited,
                None => return Outcome::Error,
            }
        }
    }
}

fn drain(notify: &impl AsFd, buffer: &mut [std::mem::MaybeUninit<u8>]) {
    let mut reader = inotify::Reader::new(notify, buffer);
    while reader.next().is_ok() {}
}

#[cfg(test)]
mod tests;
