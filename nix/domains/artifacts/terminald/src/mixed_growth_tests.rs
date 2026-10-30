//! Local Linux PTY growth/admission contention with an independent stalled peer.
use super::{AttachRequest, Attached, Config, Daemon, Session};
use crate::{frame, pty};
use hegel::{generators as gs, TestCase};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, IntoRawFd};
use std::os::unix::net::UnixStream;
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
struct Snapshot {
    alive: bool,
    limit: usize,
    backing: usize,
}

/// @cc [owner:ghuntley,label:verification;capacity;recovery] mixed-pressure-growth-admission
/// Concurrent PTY growth and session creates MUST share one reservation bound,
/// preserve a stalled neighbor and every admitted identity, and make healthy
/// output progress. Retiring an independent grown session MUST permit healthy
/// growth and exact replacement admission without exceeding actual backing.
#[hegel::test(test_cases = 2)]
fn mixed_stall_growth_and_admission_preserve_shared_backing(tc: TestCase) {
    let contenders = tc.draw(gs::sampled_from(&[2_usize, 3, 4]));
    let boundary = tc.draw(gs::sampled_from(&[32767_usize, 32768, 32769]));
    let watermark = tc.draw(gs::sampled_from(&[32767_usize, 32768, 32769]));
    verify_mixed(8, 4, contenders, boundary, watermark);
    verify_mixed(64, 8, 6, 32768, Config::default().viewer_hwm);
}

#[expect(
    clippy::too_many_lines,
    reason = "one mixed-pressure scenario with its admission and backing checks"
)]
fn verify_mixed(
    total_units: usize,
    maximum_units: usize,
    contenders: usize,
    boundary: usize,
    watermark: usize,
) {
    let unit = Config::default().ring_default;
    let maximum = maximum_units * unit;
    let cfg = Config {
        ring_total_max: total_units * unit,
        ring_max: maximum,
        viewer_hwm: watermark,
        ..Config::default()
    };
    let daemon = Daemon::new(
        cfg.clone(),
        [3; 32],
        "mixed-growth-fixture".into(),
        "1".into(),
    );
    let _cleanup = Cleanup(daemon.clone());
    let head = std::env::var("TERMINALD_TEST_HEAD").expect("pinned native output helper");
    assert!(head.starts_with("/nix/store/") && head.ends_with("/bin/head"));
    assert!(head
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/_-.".contains(&byte)));
    let user = pty::current_user_name();
    let filler_count = total_units / maximum_units - 1;
    let mut fillers: Vec<Peer> = (0..filler_count)
        .map(|_| create_peer(&daemon, &user))
        .collect();
    let mut blocked = create_peer(&daemon, &user);
    let healthy = create_peer(&daemon, &user);
    let healthy_id = healthy.id;
    for filler in &mut fillers {
        for round in 0..2 {
            execute_growth(filler, &head, maximum + boundary, round);
        }
    }
    let mut expected: BTreeMap<u64, usize> =
        fillers.iter().map(|peer| (peer.id, maximum)).collect();
    expected.insert(blocked.id, unit);
    expected.insert(healthy_id, unit);
    let viewers = filler_count + 2;
    verify_inventory(&daemon, &expected, viewers);
    let pressure_bytes = watermark + 131_072;
    blocked
        .socket
        .write_all(format!("set +m; {head} -c {pressure_bytes} /dev/zero\n").as_bytes())
        .expect("finite pressure submission");
    let stalled_session = daemon
        .live_session(blocked.id)
        .expect("owned stalled session");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !stalled(&stalled_session, watermark) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        stalled(&stalled_session, watermark),
        "actual queue must reach pressure"
    );
    let blocked_limit = if watermark >= unit { 2 * unit } else { unit };
    expected.insert(blocked.id, blocked_limit);
    verify_inventory(&daemon, &expected, viewers);
    let barrier = Arc::new(Barrier::new(contenders + 2));
    let workers: Vec<_> = (0..contenders)
        .map(|_| {
            let daemon = daemon.clone();
            let barrier = barrier.clone();
            let user = user.clone();
            std::thread::spawn(move || {
                barrier.wait();
                daemon.create(&user, "xterm-256color", 80, 24)
            })
        })
        .collect();
    let growth_barrier = barrier.clone();
    let growth_head = head.clone();
    let growth = std::thread::spawn(move || {
        let mut healthy = healthy;
        growth_barrier.wait();
        for round in 0..2 {
            execute_growth(&mut healthy, &growth_head, maximum + boundary, round);
        }
        healthy
    });
    barrier.wait();
    let results: Vec<_> = workers
        .into_iter()
        .map(std::thread::JoinHandle::join)
        .collect();
    let healthy_result = growth.join();
    let mut healthy = healthy_result.expect("healthy output worker joined");
    let mut admitted = Vec::new();
    for result in results {
        match result.expect("admission worker joined") {
            Ok((id, _token)) => {
                admitted.push(id);
                expected.insert(id, unit);
            }
            Err(error) => assert_eq!(error, frame::ERR_LIMIT),
        }
    }
    let healthy_limit = snapshot(&daemon, healthy_id).limit;
    assert!(
        healthy_limit.is_power_of_two() && healthy_limit >= unit && healthy_limit <= maximum / 2,
        "contending growth must refuse the unreserved maximum step; limit={healthy_limit}"
    );
    assert_eq!(
        admitted.len(),
        total_units - filler_count * maximum_units - blocked_limit / unit - healthy_limit / unit
    );
    expected.insert(healthy_id, healthy_limit);
    verify_inventory(&daemon, &expected, viewers);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), cfg.ring_total_max);
    assert!(
        stalled(&stalled_session, watermark),
        "pressure must persist through contention"
    );
    assert!(matches!(
        daemon.create(&user, "xterm-256color", 80, 24),
        Err(frame::ERR_LIMIT)
    ));
    daemon.kill(fillers[0].id).expect("owned grown retirement");
    expected.remove(&fillers[0].id);
    await_state(
        &daemon,
        expected.len(),
        viewers - 1,
        cfg.ring_total_max - maximum,
    );
    verify_inventory(&daemon, &expected, viewers - 1);
    execute_growth(&mut healthy, &head, maximum + boundary, 2);
    expected.insert(healthy_id, maximum);
    assert!(
        stalled(&stalled_session, watermark),
        "pressure must survive retirement and growth"
    );
    let replacement_count = total_units - expected.values().sum::<usize>() / unit;
    for _ in 0..replacement_count {
        let (id, _token) = daemon
            .create(&user, "xterm-256color", 80, 24)
            .expect("exact replacement reservation");
        expected.insert(id, unit);
    }
    verify_inventory(&daemon, &expected, viewers - 1);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), cfg.ring_total_max);
    assert!(matches!(
        daemon.create(&user, "xterm-256color", 80, 24),
        Err(frame::ERR_LIMIT)
    ));
    execute_growth(&mut healthy, &head, maximum + boundary, 3);
    verify_inventory(&daemon, &expected, viewers - 1);
    for id in expected.keys() {
        daemon.kill(*id).expect("owned final mixed retirement");
    }
    await_state(&daemon, 0, 0, 0);
    drop((healthy, blocked, fillers));
}

fn snapshot(daemon: &Daemon, id: u64) -> Snapshot {
    let session = daemon.live_session(id).expect("owned live PTY");
    let inner = session.inner.lock().unwrap();
    Snapshot {
        alive: inner.alive,
        limit: inner.ring.capacity(),
        backing: inner.ring.allocated_capacity(),
    }
}

fn verify_inventory(daemon: &Daemon, expected: &BTreeMap<u64, usize>, viewers: usize) {
    let actual: std::collections::BTreeSet<u64> =
        daemon.list().iter().map(|entry| entry.0).collect();
    assert!(
        actual.iter().copied().eq(expected.keys().copied()),
        "exact live identities"
    );
    let reserved: usize = expected.values().sum();
    assert!(reserved <= daemon.cfg.ring_total_max);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), reserved);
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), viewers);
    let snapshots: Vec<_> = expected
        .iter()
        .map(|(id, limit)| (*limit, snapshot(daemon, *id)))
        .collect();
    let backing: usize = snapshots.iter().map(|(_, snapshot)| snapshot.backing).sum();
    assert!(
        backing <= reserved,
        "mixed backing={backing} reserved={reserved}"
    );
    for (limit, snapshot) in snapshots {
        assert!(snapshot.alive);
        assert_eq!(snapshot.limit, limit);
        assert!(snapshot.backing <= limit);
    }
}

fn stalled(session: &Session, watermark: usize) -> bool {
    let inner = session.inner.lock().unwrap();
    inner.alive
        && inner.viewers.iter().any(|viewer| {
            let queue = viewer.queue.0.lock().unwrap();
            queue.bytes > watermark && !queue.closed && !queue.aborted
        })
}

fn await_state(daemon: &Daemon, sessions: usize, viewers: usize, reservation: usize) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while (daemon.list().len() != sessions
        || daemon.viewers.load(Ordering::SeqCst) != viewers
        || daemon.ring_total.load(Ordering::SeqCst) != reservation)
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(daemon.list().len(), sessions);
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), viewers);
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
    let send_bytes: libc::c_int = 1024;
    #[expect(clippy::cast_possible_truncation, reason = "a c_int is 4 bytes")]
    let send_length = size_of_val(&send_bytes) as libc::socklen_t;
    assert_eq!(
        // SAFETY: SO_SNDBUF reads one c_int of `send_length` bytes from
        // `send_bytes`, a live local.
        unsafe {
            libc::setsockopt(
                server.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_SNDBUF,
                (&raw const send_bytes).cast::<libc::c_void>(),
                send_length,
            )
        },
        0
    );
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
    assert!(payload <= Config::default().ring_max + 32769 && round <= 3);
    let marker = format!("GROWTH_COMPLETE_{}_ROUND_{round}_DONE", peer.id).into_bytes();
    let escaped = marker.iter().fold(String::new(), |mut text, byte| {
        let _ = write!(text, "\\{byte:03o}");
        text
    });
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
            Err(error) => panic!("native growth read failed: {:?}", error.kind()),
        }
    }
}
