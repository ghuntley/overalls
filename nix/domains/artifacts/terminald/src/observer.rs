//! Harness-only, host-authenticated and read-only physical terminal snapshot.
use crate::{frame, session, vsock};
use std::io;
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::fd::RawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

const PORT: u32 = 1076;
const OP_SNAPSHOT: u8 = 0x20;
const OP_INPUT_STALL: u8 = 0x21;
const LEDGER: &str = "/run/overalls-terminal-probe/ledger";

/// The separate guest PTY probe fsyncs fixed-width digest records. An absent
/// ledger is a known empty history; malformed or unreadable state is unknown.
pub(crate) fn read_ledger() -> Option<Vec<[u8; 16]>> {
    let mut file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(LEDGER)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Some(Vec::new()),
        Err(_) => return None,
    };
    // SAFETY: flock(2) takes only the descriptor of `file`, which stays open
    // for the call, and touches no memory.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
        return None;
    }
    let mut bytes = Vec::new();
    file.by_ref()
        .take(128 * 33 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() % 33 != 0 || bytes.len() > 128 * 33 {
        return None;
    }
    bytes
        .as_chunks::<33>()
        .0
        .iter()
        .map(|record| {
            if record[32] != b'\n' {
                return None;
            }
            let mut digest = [0u8; 16];
            for (index, pair) in record[..32].as_chunks::<2>().0.iter().enumerate() {
                let high = hex(pair[0])?;
                let low = hex(pair[1])?;
                digest[index] = high * 16 + low;
            }
            Some(digest)
        })
        .collect()
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}

/// @cc [owner:ghuntley,label:security;verification] observer-closed-audience
/// The observer MUST accept only actual host CID 2, verify the current boot's
/// hello proof before reading a request, and serve only the closed SNAPSHOT
/// or session-ID input-stall query. It MUST NOT expose bytes, tokens or input.
pub(crate) fn start(daemon: Arc<session::Daemon>) -> io::Result<()> {
    let listener = vsock::listen(PORT)?;
    let active = Arc::new(AtomicUsize::new(0));
    std::thread::Builder::new()
        .name("terminal-observer".into())
        .spawn(move || loop {
            match vsock::accept(listener) {
                Ok((fd, cid, _)) => {
                    if cid != vsock::CID_HOST {
                        // SAFETY: close(2) touches no memory; this loop owns
                        // the freshly accepted `fd` and never uses it again.
                        unsafe { libc::close(fd) };
                        continue;
                    }
                    if !session::reserve(&active, 1, 8) {
                        // SAFETY: close(2) touches no memory; this loop owns
                        // the freshly accepted `fd` and never uses it again.
                        unsafe { libc::close(fd) };
                        continue;
                    }
                    let daemon = daemon.clone();
                    let admitted = active.clone();
                    if std::thread::Builder::new()
                        .spawn(move || {
                            handle(daemon, fd);
                            admitted.fetch_sub(1, Ordering::SeqCst);
                        })
                        .is_err()
                    {
                        active.fetch_sub(1, Ordering::SeqCst);
                        // Failed admission owns and closes the still-local accepted fd.
                        // SAFETY: close(2) touches no memory; the spawn failed, so
                        // no handler thread received `fd`.
                        unsafe { libc::close(fd) };
                    }
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(50)),
            }
        })?;
    Ok(())
}

#[expect(
    clippy::needless_pass_by_value,
    reason = "the handler thread owns its Daemon handle until the connection ends"
)]
fn handle(daemon: Arc<session::Daemon>, fd: RawFd) {
    let timeout = libc::timeval {
        tv_sec: 3,
        tv_usec: 0,
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a timeval is 16 bytes, far below socklen_t::MAX"
    )]
    let length = size_of_val(&timeout) as libc::socklen_t;
    // SAFETY: SO_RCVTIMEO reads one timeval of `length` bytes from `timeout`,
    // a live local of exactly that type and size.
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVTIMEO,
            (&raw const timeout).cast::<libc::c_void>(),
            length,
        );
    }
    // SAFETY: SO_SNDTIMEO reads one timeval of `length` bytes from `timeout`,
    // a live local of exactly that type and size.
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_SNDTIMEO,
            (&raw const timeout).cast::<libc::c_void>(),
            length,
        );
    }
    let mut buffer = Vec::new();
    let authorized = match session::read_frame(fd, &mut buffer) {
        Some(Ok(first)) if first.op == frame::OP_HELLO => session::decode_hello(&first.payload)
            .is_some_and(|(nonce, tag)| daemon.verify_hello(&nonce, &tag)),
        _ => false,
    };
    if authorized && session::write_frame(fd, frame::OP_OK, &[]).is_ok() {
        if let Some(Ok(request)) = session::read_frame(fd, &mut buffer) {
            match (request.op, request.payload.as_slice()) {
                (OP_SNAPSHOT, []) => {
                    if let Some(snapshot) = daemon.antithesis_snapshot() {
                        let _ = session::write_frame(fd, frame::OP_OK, &snapshot);
                    }
                }
                (OP_INPUT_STALL, &[b0, b1, b2, b3, b4, b5, b6, b7]) => {
                    let id = u64::from_be_bytes([b0, b1, b2, b3, b4, b5, b6, b7]);
                    if let Some(stall) = daemon.antithesis_input_stall(id) {
                        let _ = session::write_frame(fd, frame::OP_OK, &stall);
                    }
                }
                _ => {}
            }
        }
    }
    // SAFETY: close(2) touches no memory; this handler owns `fd` and this is
    // its final use.
    unsafe { libc::close(fd) };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_snapshot(daemon: &session::Daemon) -> Vec<u8> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if let Some(snapshot) = daemon.antithesis_snapshot() {
                return snapshot;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "snapshot remained unavailable"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    #[test]
    fn actual_pty_snapshot_tracks_process_and_retirement() {
        let daemon = session::Daemon::new(
            session::Config::default(),
            [0; 32],
            "observer-fixture".into(),
            "1".into(),
        );
        let user = crate::pty::current_user_name();
        let (id, _) = daemon
            .create(&user, "xterm", 80, 24)
            .expect("actual PTY birth");
        let snapshot = wait_snapshot(&daemon);
        assert_eq!(snapshot[0], 1);
        assert_eq!(snapshot[1], 1);
        assert_eq!(u64::from_be_bytes(snapshot[2..10].try_into().unwrap()), 1);
        assert_eq!(u64::from_be_bytes(snapshot[10..18].try_into().unwrap()), 0);
        let daemon_pid = u32::from_be_bytes(snapshot[24..28].try_into().unwrap());
        let daemon_ticks = u64::from_be_bytes(snapshot[28..36].try_into().unwrap());
        assert_eq!(daemon_pid, std::process::id());
        assert!(daemon_ticks > 0);
        let record = 37 + usize::from(snapshot[36]) * 16;
        assert_eq!(
            u64::from_be_bytes(snapshot[record..record + 8].try_into().unwrap()),
            id
        );
        let pid = u32::from_be_bytes(snapshot[record + 8..record + 12].try_into().unwrap());
        assert!(pid > 0 && std::path::Path::new(&format!("/proc/{pid}/stat")).exists());
        assert!(u64::from_be_bytes(snapshot[record + 12..record + 20].try_into().unwrap()) > 0);
        let limit = u32::from_be_bytes(snapshot[record + 37..record + 41].try_into().unwrap());
        let allocated = u32::from_be_bytes(snapshot[record + 41..record + 45].try_into().unwrap());
        assert!(allocated <= limit);
        daemon.kill(id).expect("kill actual PTY");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while daemon.list().iter().any(|entry| entry.0 == id)
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let retired = wait_snapshot(&daemon);
        assert_eq!(retired[1], 0);
        assert_eq!(u64::from_be_bytes(retired[10..18].try_into().unwrap()), 1);
    }
}
