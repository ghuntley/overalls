//! A bounded browser journey supervisor with independent durable settlement.

use crate::request_recorder::{request, Command, Reply, Terminal};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command as ProcessCommand, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const INTERVAL: Duration = Duration::from_secs(300);
const DEADLINE: Duration = Duration::from_secs(60);
const HEARTBEAT: Duration = Duration::from_secs(5);

fn accepted(reply: Result<Reply, crate::request_recorder::Refusal>) -> bool {
    matches!(reply, Ok(Reply::Ok {}))
}

fn terminal(success: bool, elapsed: Duration) -> Terminal {
    if success && elapsed < DEADLINE {
        Terminal::Success
    } else {
        Terminal::Failure
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Slot {
    Wait,
    Journey,
    Gap,
}

fn slot(next: Instant, now: Instant, covered: bool) -> (Instant, Slot) {
    if now >= next + INTERVAL {
        (now + INTERVAL, Slot::Gap)
    } else if now >= next && covered {
        (next + INTERVAL, Slot::Journey)
    } else {
        (next, Slot::Wait)
    }
}

fn subreaper() -> bool {
    unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0 }
}

fn owned_children() -> std::io::Result<Vec<i32>> {
    let mut children = Vec::new();
    for thread in std::fs::read_dir("/proc/self/task")? {
        let path = thread?.path().join("children");
        let contents = match std::fs::read_to_string(path) {
            Ok(contents) if contents.len() <= 32_768 => contents,
            Ok(_) => return Err(std::io::Error::other("owned child limit")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        for value in contents.split_ascii_whitespace() {
            let pid = value
                .parse::<i32>()
                .ok()
                .filter(|pid| *pid > 1)
                .ok_or_else(|| std::io::Error::other("owned child identity"))?;
            if !children.contains(&pid) {
                children.push(pid);
            }
            if children.len() > 1024 {
                return Err(std::io::Error::other("owned child limit"));
            }
        }
    }
    Ok(children)
}

/// @cc [owner:ghuntley,label:security;reliability] browser-detached-descendant-cleanup
/// Playwright can detach Chromium into a second process group. The dedicated
/// supervisor MUST adopt, kill and reap its owned descendants on settlement.
/// Kernel-owned child lists alone MUST select targets, never fixture data.
fn reap_owned_children() -> bool {
    for _ in 0..100 {
        while unsafe { libc::waitpid(-1, std::ptr::null_mut(), libc::WNOHANG) } > 0 {}
        let Ok(children) = owned_children() else {
            return false;
        };
        if children.is_empty() {
            return true;
        }
        for pid in children {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
                libc::kill(pid, libc::SIGKILL);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

fn kill_group(child: &mut std::process::Child) -> bool {
    if let Ok(pid) = i32::try_from(child.id()) {
        // Linux limits PIDs to positive signed integers. This is the process
        // group created for our owned browser, never a fixture-selected PID.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
    let _ = child.wait();
    reap_owned_children()
}

fn browser(driver: &Path, fixture: &Path, chromium: &Path, started: Instant) -> bool {
    if !reap_owned_children() {
        return false;
    }
    let Ok(mut child) = ProcessCommand::new(driver)
        .arg(fixture)
        .arg("--chromium")
        .arg(chromium)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
    else {
        return false;
    };
    loop {
        if started.elapsed() >= DEADLINE {
            let _ = kill_group(&mut child);
            return false;
        }
        match child.try_wait() {
            Ok(Some(status)) => return kill_group(&mut child) && status.success(),
            Err(_) => {
                let _ = kill_group(&mut child);
                return false;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
}

fn heartbeat(socket: &Path, last: &mut Instant) -> bool {
    if last.elapsed() < HEARTBEAT {
        return true;
    }
    *last = Instant::now();
    accepted(request(socket, Command::Hello {}))
}

/// @cc [owner:ghuntley,label:reliability;security] browser-single-terminal-settlement
/// Each admitted journey MUST settle once. A deadline MUST kill the browser
/// process group, forbid late success and leave durable reconciliation to the
/// recorder if a terminal acknowledgement is lost. Child output is private.
fn journey(socket: &Path, driver: &Path, fixture: &Path, chromium: &Path) -> bool {
    let started = Instant::now();
    let Ok(Reply::Admitted { id }) = request(socket, Command::Admit {}) else {
        return false;
    };
    let mut last_heartbeat = started;
    let mut recorder_live = true;
    // The browser owner enforces the deadline independently of bounded recorder
    // RPCs, so a stalled acknowledgement cannot extend the browser's lifetime.
    let success = std::thread::scope(|scope| {
        let (sender, receiver) = mpsc::sync_channel(1);
        scope.spawn(move || {
            let _ = sender.send(browser(driver, fixture, chromium, started));
        });
        loop {
            match receiver.recv_timeout(Duration::from_millis(100)) {
                Ok(success) => break success,
                Err(mpsc::RecvTimeoutError::Disconnected) => break false,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    recorder_live &= heartbeat(socket, &mut last_heartbeat);
                }
            }
        }
    });
    let elapsed = started.elapsed();
    let outcome = if recorder_live {
        terminal(success, elapsed)
    } else {
        Terminal::Exclude
    };
    let duration_us = elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
    accepted(request(
        socket,
        Command::Finish {
            id,
            outcome,
            duration_us,
        },
    )) && recorder_live
}

/// @cc [owner:ghuntley,label:reliability] browser-no-fabricated-skipped-slots
/// A skipped interval or recorder outage MUST reset source coverage, never add
/// synthetic successes or catch-up journeys. Healthy idle time has five-second
/// producer heartbeats independently of the five-minute journey interval.
pub fn run(socket: &Path, driver: &Path, fixture: &Path, chromium: &Path) -> ! {
    if !subreaper() {
        std::process::exit(2);
    }
    let mut next = Instant::now();
    let mut last_heartbeat = Instant::now() - HEARTBEAT;
    let mut gap = true;
    loop {
        if gap {
            if accepted(request(socket, Command::Gap {})) {
                gap = false;
            } else {
                std::thread::sleep(Duration::from_secs(1));
                continue;
            }
        }
        if !heartbeat(socket, &mut last_heartbeat) {
            gap = true;
        }
        let decision;
        (next, decision) = slot(next, Instant::now(), !gap);
        match decision {
            Slot::Gap => gap = true,
            Slot::Journey => gap = !journey(socket, driver, fixture, chromium),
            Slot::Wait => {}
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::durable_slo::{Outcome, Producer, Source, State};
    use hegel::{generators as gs, TestCase};
    use std::io::{BufRead, BufReader};

    fn fixture(name: &str) -> ProcessCommand {
        let mut command = ProcessCommand::new(std::env::current_exe().unwrap());
        command.args(["--exact", name, "--ignored", "--nocapture"]);
        command
    }

    fn ready(child: &mut std::process::Child, marker: &str) {
        let output = child.stdout.take().unwrap();
        let mut found = false;
        for line in BufReader::new(output).lines().take(16) {
            if line.unwrap().contains(marker) {
                found = true;
                break;
            }
        }
        assert!(found, "owned child fixture did not start");
    }

    #[test]
    fn detached_browser_descendants_do_not_survive_settlement() {
        assert!(fixture("browser_probe::tests::cleanup_fixture")
            .stdout(Stdio::null())
            .status()
            .unwrap()
            .success());
    }

    #[test]
    #[ignore = "invoked only in a dedicated subprocess by the cleanup regression"]
    fn cleanup_fixture() {
        assert!(subreaper());
        let mut child = fixture("browser_probe::tests::middle_fixture")
            .process_group(0)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        ready(&mut child, "BROWSER_CHILD_READY");
        assert!(kill_group(&mut child));
        assert!(owned_children().unwrap().is_empty());
    }

    #[test]
    #[ignore = "invoked only by the dedicated cleanup subprocess"]
    fn middle_fixture() {
        let mut child = fixture("browser_probe::tests::detached_leaf_fixture")
            .process_group(0)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        ready(&mut child, "DETACHED_LEAF_READY");
        println!("BROWSER_CHILD_READY");
        std::thread::sleep(Duration::from_secs(30));
    }

    #[test]
    #[ignore = "invoked only by the dedicated middle subprocess"]
    fn detached_leaf_fixture() {
        println!("DETACHED_LEAF_READY");
        std::thread::sleep(Duration::from_secs(30));
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-late-browser-failure
    /// A browser exit at or after the minute deadline MUST settle as failure,
    /// whatever its exit status.
    #[hegel::test(test_cases = 256)]
    fn late_child_exit_never_becomes_success(tc: TestCase) {
        let micros = tc.draw(
            gs::integers::<u64>()
                .min_value(60_000_000)
                .max_value(999_999_999),
        );
        let success = tc.draw(gs::booleans());
        assert!(matches!(
            terminal(success, Duration::from_micros(micros)),
            Terminal::Failure
        ));
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-browser-bounds-isolated
    /// Browser bounds MUST NOT change any existing source's bounds, and a
    /// generated browser duration MUST settle exactly once.
    #[hegel::test(test_cases = 256)]
    fn browser_bounds_preserve_every_old_source(tc: TestCase) {
        let duration = tc.draw(gs::integers::<u64>().max_value(79_999_999));
        for old in [
            Source::MarshallWeb,
            Source::MarshallLive,
            Source::Galileo,
            Source::Enrico,
            Source::Brady,
            Source::Porsche,
            Source::AudiPrivate,
            Source::AudiDns,
            Source::AudiSsh,
        ] {
            assert_eq!(old.bounds_us(), crate::durable_slo::BOUNDS_US);
        }
        let mut state = State::new(Source::VscodeBrowserNixos, 1, "a".repeat(32)).unwrap();
        let producer = Producer {
            pid: 1,
            start_ticks: 1,
            boot_id: "00000000-0000-0000-0000-000000000001".to_owned(),
        };
        let id = state.admit(producer.clone(), 2, 100_000_000_000).unwrap();
        state
            .finish(id, &producer, 3, Outcome::Success, duration)
            .unwrap();
        assert!(state
            .finish(id, &producer, 4, Outcome::Success, duration)
            .is_err());
        assert_eq!(state.totals.requests, 1);
        assert_eq!(state.totals.successes, 1);
        assert_eq!(state.totals.bucket_counts.iter().sum::<u64>(), 1);
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-skipped-slot-gap
    /// A generated skipped probe slot MUST record a gap that advances coverage
    /// without fabricating health or changing totals.
    #[hegel::test(test_cases = 256)]
    fn skipped_slots_reset_coverage_without_fabricated_health(tc: TestCase) {
        let delay = tc.draw(gs::integers::<u64>().min_value(300).max_value(99_999));
        let initial = Instant::now();
        let now = initial + Duration::from_secs(delay);
        let (next, decision) = slot(initial, now, true);
        assert_eq!(decision, Slot::Gap);
        assert_eq!(slot(next, now, true).1, Slot::Wait);
        let mut state = State::new(Source::VscodeBrowserUbuntu, 1, "a".repeat(32)).unwrap();
        let totals = state.totals.clone();
        state.mark_gap(delay * 1_000_000_000).unwrap();
        assert_eq!(state.totals, totals);
        assert!(state.coverage_started_at_ns > state.started_at_ns);
    }
}
