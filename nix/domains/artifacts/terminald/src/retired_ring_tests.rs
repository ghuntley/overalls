//! Native local EOF/drain accounting; no authenticated guest or RSS claim.
use super::{AttachRequest, Attached, Config, Daemon};
use crate::{frame, pty};
use hegel::{generators as gs, TestCase};
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
    }
}

/// @cc [owner:ghuntley,label:verification;capacity;recovery] eof-releases-backing-before-quota
/// After natural EOF releases a session's scrollback reservation, SUT-owned
/// viewer references MUST NOT retain its scrollback allocation. A stalled
/// viewer MUST still receive every queued output byte when it resumes reading.
#[hegel::test(test_cases = 3)]
fn natural_eof_releases_scrollback_before_stalled_tail_drains(tc: TestCase) {
    let defaults = Config::default();
    let capacity = tc.draw(gs::sampled_from(&[
        defaults.ring_default,
        defaults.ring_max,
    ]));
    let tail = tc.draw(gs::sampled_from(&[
        8192_usize, 32767, 32768, 32769, 131_072,
    ]));
    for (capacity, tail) in [
        (defaults.ring_default, 131_072),
        (defaults.ring_max, 8192),
        (capacity, tail),
    ] {
        verify_retired_tail(capacity, tail);
    }
}

fn verify_retired_tail(capacity: usize, tail: usize) {
    let daemon = Daemon::new(
        Config {
            ring_default: capacity,
            ring_max: capacity,
            ..Config::default()
        },
        [3; 32],
        "retired-ring-fixture".into(),
        "1".into(),
    );
    let _cleanup = Cleanup(daemon.clone());
    let (id, token) = daemon
        .create(&pty::current_user_name(), "xterm-256color", 80, 24)
        .expect("owned EOF PTY");
    let session = daemon.live_session(id).expect("live EOF PTY");
    let weak = Arc::downgrade(&session);
    drop(session);
    let mut viewer = attach(&daemon, id, token);
    assert!([8192_usize, 32767, 32768, 32769, 131_072].contains(&tail));
    let command = format!("set +m; printf '\\000%.0s' {{1..{tail}}}; exit\n");
    viewer
        .write_all(command.as_bytes())
        .expect("finite tail submission");
    let deadline = Instant::now() + Duration::from_secs(10);
    while (!daemon.list().is_empty() || daemon.ring_total.load(Ordering::SeqCst) != 0)
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        daemon.list().is_empty(),
        "finite tail must reach natural EOF below watermark"
    );
    assert_eq!(daemon.ring_total.load(Ordering::SeqCst), 0);
    assert_eq!(
        daemon.viewers.load(Ordering::SeqCst),
        1,
        "stalled SUT writer still owns permit"
    );
    let retired = weak
        .upgrade()
        .expect("SUT viewer still retains retired session");
    {
        let inner = retired.inner.lock().unwrap();
        assert!(!inner.alive);
        assert_eq!(
            inner.ring.allocated_capacity(),
            0,
            "retired backing allocation must be released before reservation"
        );
        assert_eq!(inner.ring.tail() - inner.ring.base(), 0);
    }
    drop(retired);
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut nul_bytes = 0_usize;
    let mut scratch = [0_u8; 8192];
    loop {
        assert!(
            Instant::now() < deadline,
            "queued tail must finish draining"
        );
        match viewer.read(&mut scratch) {
            Ok(0) => break,
            #[expect(
                clippy::naive_bytecount,
                reason = "a test-only count does not warrant the bytecount dependency"
            )]
            Ok(count) => nul_bytes += scratch[..count].iter().filter(|byte| **byte == 0).count(),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) => panic!("tail socket read failed: {:?}", error.kind()),
        }
    }
    assert_eq!(
        nul_bytes, tail,
        "exact queued NUL count without payload diagnostics"
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while daemon.viewers.load(Ordering::SeqCst) != 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(daemon.viewers.load(Ordering::SeqCst), 0);
}

fn attach(daemon: &Arc<Daemon>, id: u64, token: [u8; 16]) -> UnixStream {
    let (mut client, server) = UnixStream::pair().expect("isolated tail sockets");
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
        .expect("bounded replay");
    assert!(replay_len <= Config::default().ring_max);
    client
        .read_exact(&mut vec![0; replay_len])
        .expect("initial replay");
    client
}
