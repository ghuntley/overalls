//! Real PTY admission and retirement at the configured aggregate ring budget.
use super::{Config, Daemon};
use crate::{frame, pty};
use hegel::{generators as gs, TestCase};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

struct Cleanup(Arc<Daemon>);

impl Drop for Cleanup {
    fn drop(&mut self) {
        for entry in self.0.list() {
            let _ = self.0.kill(entry.0);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while !self.0.list().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

/// @cc [owner:ghuntley,label:verification;capacity] real-pty-shared-ring-admission
/// At the configured 64 MiB aggregate ring boundary, competing PTY creates MUST
/// admit only the remaining whole reservations. Refusal MUST preserve all live
/// sessions and their reservations. Retirement MUST release exactly its ring
/// capacity, allowing replacement sessions without exceeding the shared bound.
/// This local PTY history MUST NOT establish authenticated vsock or VM isolation.
#[hegel::test(test_cases = 3)]
fn shared_ring_budget_admission_and_retirement(tc: TestCase) {
    let generated = tc.draw(gs::sampled_from(&[2_usize << 20, 4 << 20, 8 << 20]));
    let retirements = tc.draw(gs::integers::<usize>().min_value(1).max_value(3));
    for capacity in [
        Config::default().ring_default,
        Config::default().ring_max,
        generated,
    ] {
        verify_budget_history(capacity, retirements, tc.draw(gs::booleans()));
    }
}

fn verify_budget_history(capacity: usize, retirements: usize, reverse: bool) {
    let limit = Config::default().ring_total_max;
    assert_eq!(limit, 64 << 20);
    assert_eq!(limit % capacity, 0);
    let slots = limit / capacity;
    // Keep the session-count boundary strictly above the memory boundary so an
    // ERR_LIMIT cannot pass this oracle by being a session-count refusal instead.
    let cfg = Config {
        ring_default: capacity,
        ring_max: capacity,
        sessions_max: slots + 4,
        ..Config::default()
    };
    let daemon = Daemon::new(cfg, [3; 32], "budget-fixture".into(), "1".into());
    let _cleanup = Cleanup(daemon.clone());
    let user = pty::current_user_name();
    let mut ids: Vec<u64> = Vec::new();
    for _ in 0..slots - 1 {
        ids.push(
            daemon
                .create(&user, "xterm-256color", 80, 24)
                .expect("fixture PTY")
                .0,
        );
    }
    assert_eq!(
        daemon.ring_total.load(Ordering::SeqCst),
        (slots - 1) * capacity
    );
    let accepted = competing_creates(&daemon, &user, 3);
    assert_eq!(accepted.len(), 1, "only one whole reservation remains");
    ids.extend(accepted);
    assert_inventory(&daemon, &ids, limit);

    if reverse {
        ids.reverse();
    }
    for _ in 0..retirements {
        let retired = ids.pop().expect("bounded retirement");
        daemon.kill(retired).expect("owned live PTY");
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while daemon.list().len() != ids.len() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_inventory(&daemon, &ids, ids.len() * capacity);
    let accepted = competing_creates(&daemon, &user, retirements + 2);
    assert_eq!(
        accepted.len(),
        retirements,
        "only retired reservations are reusable"
    );
    ids.extend(accepted);
    assert_inventory(&daemon, &ids, limit);

    for id in ids {
        daemon.kill(id).expect("owned replacement or survivor PTY");
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while !daemon.list().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(daemon.list().is_empty(), "all fixture PTYs must retire");
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), 0);
}

fn competing_creates(daemon: &Arc<Daemon>, user: &str, count: usize) -> Vec<u64> {
    let barrier = Arc::new(Barrier::new(count));
    let workers: Vec<_> = (0..count)
        .map(|_| {
            let daemon = daemon.clone();
            let user = user.to_owned();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                daemon.create(&user, "xterm-256color", 80, 24)
            })
        })
        .collect();
    // Join every contender before asserting, so failure cannot leave a late
    // successful worker outside the cleanup guard's observed session inventory.
    let replies: Vec<_> = workers.into_iter().map(|worker| worker.join()).collect();
    let mut accepted: Vec<u64> = Vec::new();
    for reply in replies {
        match reply.expect("fixture create thread") {
            Ok((id, _token)) => accepted.push(id),
            Err(reason) => assert_eq!(reason, frame::ERR_LIMIT, "only budget refusal is expected"),
        }
    }
    accepted
}

fn assert_inventory(daemon: &Daemon, ids: &[u64], reserved: usize) {
    let mut expected = ids.to_vec();
    expected.sort_unstable();
    let actual: Vec<u64> = daemon
        .list()
        .into_iter()
        .map(|entry| {
            assert!(entry.5, "listed survivor must remain live");
            entry.0
        })
        .collect();
    assert_eq!(actual, expected);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), reserved);
}
