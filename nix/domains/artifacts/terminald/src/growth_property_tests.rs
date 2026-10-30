//! Actual PTY-driven growth and backing accounting; local Linux scope only.
use super::{AttachRequest, Attached, Config, Daemon};
use crate::{frame, pty};
use hegel::{generators as gs, TestCase};
use std::collections::BTreeSet;
use std::io::{Read, Write};
use std::os::fd::IntoRawFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

struct Cleanup(Arc<Daemon>);
impl Drop for Cleanup {
    fn drop(&mut self) {
        for entry in self.0.list() {
            let _ = self.0.kill(entry.0);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while (!self.0.list().is_empty()
            || self.0.ring_total.load(Ordering::SeqCst) != 0
            || self.0.viewers.load(Ordering::SeqCst) != 0)
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

struct Peer {
    id: u64,
    socket: UnixStream,
}

struct RingSnapshot {
    alive: bool,
    limit: usize,
    allocated: usize,
    retained: u64,
}

/// @cc [owner:ghuntley,label:verification;capacity] actual-growth-keeps-aggregate-backing
/// Real PTY growth to a full aggregate reservation MUST keep actual live ring
/// backing within that budget, refuse new sessions without changing survivors,
/// and return exactly enough quota to grow a replacement after retirement.
#[hegel::test(test_cases = 2)]
fn actual_growth_preserves_shared_backing_budget(tc: TestCase) {
    let target = tc.draw(gs::sampled_from(&[2_usize << 20, 4 << 20, 8 << 20]));
    let boundary = tc.draw(gs::sampled_from(&[32767_usize, 32768, 32769]));
    verify_growth(Config::default().ring_max, 32768);
    verify_growth(target, boundary);
}

fn verify_growth(target: usize, boundary: usize) {
    let cfg = Config {
        ring_max: target,
        ..Config::default()
    };
    let count = cfg.ring_total_max / target;
    assert!(count < cfg.sessions_max);
    let daemon = Daemon::new(
        cfg.clone(),
        [3; 32],
        "growth-budget-fixture".into(),
        "1".into(),
    );
    let _cleanup = Cleanup(daemon.clone());
    let head = std::env::var("TERMINALD_TEST_HEAD").expect("pinned native output helper");
    assert!(head.starts_with("/nix/store/") && head.ends_with("/bin/head"));
    assert!(head
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/_-.".contains(&byte)));
    let user = pty::current_user_name();
    let mut peers: Vec<Peer> = (0..count).map(|_| create_peer(&daemon, &user)).collect();
    let mut expected: BTreeSet<u64> = peers.iter().map(|peer| peer.id).collect();
    // Intermediate full rings discard the rest of a read before the next growth.
    // Emit a complete target so arbitrary PTY chunking cannot miss the last step.
    let payload = target + boundary;
    for peer in &mut peers {
        execute_growth(peer, &head, payload, 0);
    }
    verify_inventory(&daemon, &expected, target, cfg.ring_total_max, false);
    for peer in &mut peers {
        execute_growth(peer, &head, target + boundary, 1);
    }
    verify_inventory(&daemon, &expected, target, cfg.ring_total_max, true);
    for _ in 0..3 {
        assert!(matches!(
            daemon.create(&user, "xterm-256color", 80, 24),
            Err(frame::ERR_LIMIT)
        ));
        verify_inventory(&daemon, &expected, target, cfg.ring_total_max, true);
    }
    let retired_id = peers[0].id;
    let inspected = daemon
        .live_session(retired_id)
        .expect("owned retirement session");
    let retired = Arc::downgrade(&inspected);
    drop(inspected);
    daemon.kill(retired_id).expect("owned growth retirement");
    expected.remove(&retired_id);
    await_quota(&daemon, expected.len(), cfg.ring_total_max - target);
    if let Some(session) = retired.upgrade() {
        assert_eq!(session.inner.lock().unwrap().ring.allocated_capacity(), 0);
    }
    verify_inventory(
        &daemon,
        &expected,
        target,
        cfg.ring_total_max - target,
        true,
    );
    let mut replacement = create_peer(&daemon, &user);
    execute_growth(&mut replacement, &head, payload, 0);
    execute_growth(&mut replacement, &head, target + boundary, 1);
    expected.insert(replacement.id);
    verify_inventory(&daemon, &expected, target, cfg.ring_total_max, true);
    for id in &expected {
        daemon.kill(*id).expect("owned final growth retirement");
    }
    await_quota(&daemon, 0, 0);
    assert!(daemon.list().is_empty());
    // All peer descriptors remain open through final retirement/quota assertions.
    drop((replacement, peers));
}

fn verify_inventory(
    daemon: &Daemon,
    expected: &BTreeSet<u64>,
    target: usize,
    reservation: usize,
    require_full: bool,
) {
    let actual: BTreeSet<u64> = daemon.list().iter().map(|entry| entry.0).collect();
    assert_eq!(&actual, expected);
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), expected.len());
    let snapshots: Vec<RingSnapshot> = expected
        .iter()
        .map(|id| {
            let session = daemon.live_session(*id).expect("surviving native PTY");
            let inner = session.inner.lock().unwrap();
            RingSnapshot {
                alive: inner.alive,
                limit: inner.ring.capacity(),
                allocated: inner.ring.allocated_capacity(),
                retained: inner.ring.tail() - inner.ring.base(),
            }
        })
        .collect();
    let logical: usize = snapshots.iter().map(|snapshot| snapshot.limit).sum();
    let backing: usize = snapshots.iter().map(|snapshot| snapshot.allocated).sum();
    assert_eq!(logical, reservation);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), reservation);
    for snapshot in &snapshots {
        assert!(snapshot.alive);
        assert_eq!(
            snapshot.limit, target,
            "actual pump must reach expected growth"
        );
        if require_full {
            assert_eq!(
                snapshot.retained,
                u64::try_from(target).expect("bounded retained target"),
                "overwrite workload must reach actual full retained ring"
            );
        }
    }
    assert!(
        backing <= reservation,
        "aggregate backing={backing} reservation={reservation}"
    );
    for snapshot in snapshots {
        assert!(
            snapshot.allocated <= target,
            "live backing must fit reserved growth"
        );
    }
}

fn await_quota(daemon: &Daemon, sessions: usize, reservation: usize) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while (daemon.list().len() != sessions
        || daemon.viewers.load(Ordering::SeqCst) != sessions
        || daemon.ring_total.load(Ordering::SeqCst) != reservation)
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(daemon.list().len(), sessions);
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), sessions);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), reservation);
}

fn create_peer(daemon: &Arc<Daemon>, user: &str) -> Peer {
    let (id, token) = daemon
        .create(user, "xterm-256color", 80, 24)
        .expect("owned growth PTY");
    let (mut client, server) = UnixStream::pair().expect("isolated growth viewer");
    client
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("growth read deadline");
    let request = AttachRequest {
        id,
        token: token.to_vec(),
        mode: 1,
        cursor: 0,
        cols: 0,
        rows: 0,
    };
    assert!(matches!(
        daemon.attach(&request, server.into_raw_fd()),
        Attached::Streams
    ));
    let mut header = [0_u8; 16];
    client
        .read_exact(&mut header)
        .expect("growth attachment response");
    assert_eq!(&header[..4], &[frame::MAGIC, frame::OP_OK, 0, 12]);
    let replay = usize::try_from(u32::from_be_bytes(header[12..16].try_into().unwrap()))
        .expect("bounded replay");
    assert!(replay <= Config::default().ring_max);
    client
        .read_exact(&mut vec![0; replay])
        .expect("initial growth replay");
    Peer { id, socket: client }
}

fn execute_growth(peer: &mut Peer, head: &str, payload: usize, round: usize) {
    assert!(payload <= Config::default().ring_max + 32769 && round <= 1);
    let marker = format!("GROWTH_COMPLETE_{}_ROUND_{round}_DONE", peer.id).into_bytes();
    let escaped: String = marker.iter().map(|byte| format!("\\{byte:03o}")).collect();
    let command = format!("set +m; {head} -c {payload} /dev/zero; printf '{escaped}\\012'\n");
    assert!(!command
        .as_bytes()
        .windows(marker.len())
        .any(|window| window == marker));
    peer.socket
        .write_all(command.as_bytes())
        .expect("finite native growth command");
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut zeros = 0_usize;
    let mut matched = 0_usize;
    let mut scratch = [0_u8; 8192];
    loop {
        assert!(Instant::now() < deadline, "native growth marker deadline");
        match peer.socket.read(&mut scratch) {
            Ok(0) => panic!("live growth socket ended before marker"),
            Ok(count) => {
                for byte in &scratch[..count] {
                    if *byte == 0 {
                        zeros += 1;
                    }
                    matched = if *byte == marker[matched] {
                        matched + 1
                    } else {
                        usize::from(*byte == marker[0])
                    };
                    if matched == marker.len() {
                        assert_eq!(zeros, payload, "exact generated growth-byte count");
                        return;
                    }
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => panic!("native growth read failed"),
        }
    }
}
