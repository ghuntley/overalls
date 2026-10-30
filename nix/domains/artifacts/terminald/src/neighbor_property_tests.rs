//! Local Linux PTY/socket pressure; this does not authenticate guest authority.
use super::{AttachRequest, Attached, Config, Daemon, Session};
use crate::{frame, pty};
use hegel::{generators as gs, TestCase};
use std::fmt::Write as _;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, IntoRawFd};
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
        while !self.0.list().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] stalled-session-neighbor-progress
/// While one session's actual viewer queue remains above its high watermark,
/// a distinct live session MUST deliver successive newly executed output.
/// Explicit retirement of the stalled session MUST preserve the neighbor's ID,
/// viewer, ring reservation and subsequent progress, before either peer closes.
#[hegel::test(test_cases = 3)]
fn a_credit_stalled_session_preserves_neighbor_progress(tc: TestCase) {
    let watermark = tc.draw(gs::sampled_from(&[0_usize, 1, 2, 32767, 32768, 32769]));
    let rounds = tc.draw(gs::integers::<usize>().min_value(2).max_value(4));
    let default = Config::default().viewer_hwm;
    for watermark in [watermark, 0, default - 1, default, default + 1] {
        verify_neighbor(watermark, rounds);
    }
}

fn verify_neighbor(watermark: usize, rounds: usize) {
    let daemon = Daemon::new(
        Config {
            viewer_hwm: watermark,
            ..Config::default()
        },
        [3; 32],
        "neighbor-fixture".into(),
        "1".into(),
    );
    let _cleanup = Cleanup(daemon.clone());
    let user = pty::current_user_name();
    let (blocked_id, blocked_token) = daemon
        .create(&user, "xterm-256color", 80, 24)
        .expect("owned pressure PTY");
    let (healthy_id, healthy_token) = daemon
        .create(&user, "xterm-256color", 80, 24)
        .expect("owned neighbor PTY");
    let mut blocked = attach(&daemon, blocked_id, blocked_token);
    let mut healthy = attach(&daemon, healthy_id, healthy_token);
    blocked
        .write_all(b"while :; do printf 'pressure_0123456789\\n'; done\n")
        .expect("pressure command submission");
    let session = daemon.live_session(blocked_id).expect("live pressure PTY");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !stalled(&session, watermark) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        stalled(&session, watermark),
        "fixture must reach real viewer pressure"
    );
    for turn in 0..rounds {
        execute_marker(&mut healthy, turn);
        assert!(
            stalled(&session, watermark),
            "pressure must persist during neighbor progress"
        );
        assert_eq!(daemon.list().len(), 2);
        assert_eq!(daemon.viewers.load(Ordering::SeqCst), 2);
    }
    daemon.kill(blocked_id).expect("owned pressure retirement");
    let deadline = Instant::now() + Duration::from_secs(5);
    while (daemon.list().len() != 1 || daemon.viewers.load(Ordering::SeqCst) != 1)
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        daemon
            .list()
            .iter()
            .map(|entry| entry.0)
            .collect::<Vec<u64>>(),
        vec![healthy_id]
    );
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), 1);
    assert_eq!(
        daemon.ring_total.load(Ordering::SeqCst),
        Config::default().ring_default
    );
    for turn in rounds..rounds + 2 {
        execute_marker(&mut healthy, turn);
    }
    daemon.kill(healthy_id).expect("owned neighbor retirement");
    let deadline = Instant::now() + Duration::from_secs(5);
    while (!daemon.list().is_empty() || daemon.viewers.load(Ordering::SeqCst) != 0)
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(daemon.list().is_empty(), "no sessions remain");
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), 0);
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), 0);
    // Both clients remain owned/open through all retirement and permit assertions.
    drop((blocked, healthy));
}

fn attach(daemon: &Arc<Daemon>, id: u64, token: [u8; 16]) -> UnixStream {
    let (mut client, server) = UnixStream::pair().expect("isolated viewer sockets");
    client
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("read deadline");
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
    client.read_exact(&mut header).expect("attachment response");
    assert_eq!(&header[..4], &[frame::MAGIC, frame::OP_OK, 0, 12]);
    let replay_len = usize::try_from(u32::from_be_bytes(header[12..16].try_into().unwrap()))
        .expect("bounded replay length");
    assert!(replay_len <= Config::default().ring_max);
    client
        .read_exact(&mut vec![0; replay_len])
        .expect("initial replay");
    client
}

fn stalled(session: &Session, watermark: usize) -> bool {
    let inner = session.inner.lock().unwrap();
    inner.alive
        && inner.viewers.iter().any(|viewer| {
            let queue = viewer.queue.0.lock().unwrap();
            queue.bytes > watermark && !queue.closed && !queue.aborted
        })
}

fn execute_marker(viewer: &mut UnixStream, turn: usize) {
    let marker = format!("NEIGHBOR_{turn}_DONE").into_bytes();
    let escaped = marker.iter().fold(String::new(), |mut text, byte| {
        let _ = write!(text, "\\{byte:03o}");
        text
    });
    let command = format!("printf '{escaped}\\012'\n");
    assert!(
        !command
            .as_bytes()
            .windows(marker.len())
            .any(|bytes| bytes == marker),
        "command echo must not satisfy the output oracle"
    );
    viewer
        .write_all(command.as_bytes())
        .expect("neighbor command submission");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut output: Vec<u8> = Vec::new();
    let mut scratch = [0_u8; 4096];
    let mut observed = false;
    while Instant::now() < deadline {
        match viewer.read(&mut scratch) {
            Ok(0) => break,
            Ok(size) => {
                output.extend_from_slice(&scratch[..size]);
                assert!(
                    output.len() <= 16 << 10,
                    "neighbor fixture output must remain bounded"
                );
                if output.windows(marker.len()).any(|bytes| bytes == marker) {
                    observed = true;
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock
                        | std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::Interrupted
                ) => {}
            Err(_) => break,
        }
    }
    assert!(
        observed,
        "neighbor must execute and deliver each fresh output marker"
    );
}
