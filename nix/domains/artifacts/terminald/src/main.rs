//! Guest terminal multiplexer: vsock listener, connection handling, boot identity.
#![deny(clippy::dbg_macro, clippy::print_stderr, clippy::print_stdout)]
#[cfg_attr(unix, path = "conn_unix.rs")]
#[cfg_attr(windows, path = "conn_windows.rs")]
mod conn;
mod crypto;
mod frame;
#[cfg(any(windows, target_os = "freebsd", target_os = "illumos", test))]
mod identity_mmds;
mod log;
#[cfg(test)]
#[cfg(target_os = "linux")]
#[path = "vsock_native.rs"]
mod native_vsock_layout_tests;
#[cfg(feature = "antithesis-observer")]
mod observer;
#[cfg_attr(windows, path = "pty_windows.rs")]
mod pty;
mod ring;
mod session;
#[cfg_attr(windows, path = "vsock_windows.rs")]
#[cfg_attr(
    any(target_os = "freebsd", target_os = "illumos"),
    path = "vsock_native.rs"
)]
mod vsock;

#[cfg(test)]
#[cfg(unix)]
mod property_tests;

use conn::Conn;
use session::{Attached, Config, Daemon};
use std::sync::Arc;

fn main() {
    let identity = boot_identity();
    let Some((challenge, placement, epoch)) = identity else {
        log::event(log::Event::MissingBootIdentity);
        std::process::exit(1);
    };
    let key = crypto::digest(&[challenge.as_bytes(), b"overalls-terminald-v1"]);
    let mut cfg = Config {
        account_helper: account_helper(),
        ..Config::default()
    };
    if let Some(port) = std::env::var("LILLY_TERMINALD_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
    {
        cfg.port = port;
    }
    let daemon = Daemon::new(cfg, key, placement, epoch);
    #[cfg(feature = "antithesis-observer")]
    if observer::start(daemon.clone()).is_err() {
        std::process::exit(1);
    }
    let listener = match vsock::listen(daemon.port()) {
        Ok(listener) => listener,
        Err(error) => {
            log::event(log::Event::ListenFailed {
                errno: error.raw_os_error().unwrap_or(0),
            });
            std::process::exit(1);
        }
    };
    // Session retirement owns waitpid. Keep exited children waitable so their
    // numeric PIDs cannot be reused before retirement finishes signalling them.
    log::event(log::Event::Started {
        port: daemon.port(),
    });
    let sweeper = daemon.clone();
    std::thread::Builder::new()
        .spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_mins(1));
            sweeper.sweep_idle();
        })
        .ok();
    handle_connections(&daemon, listener);
}

/// Unix guests reconcile personal accounts through the shared helper before
/// a PTY opens (`terminal-account-before-passwd`).
#[cfg(unix)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "shares the signature of the Windows variant, which has no helper"
)]
fn account_helper() -> Option<std::path::PathBuf> {
    Some(
        std::env::var_os("LILLY_TERMINALD_ACCOUNT_HELPER").map_or_else(
            || {
                #[cfg(target_os = "freebsd")]
                let path = "/usr/local/libexec/overalls-ssh-authorize";
                #[cfg(target_os = "illumos")]
                let path = "/opt/overalls/libexec/overalls-ssh-authorize";
                #[cfg(target_os = "linux")]
                let path = "/usr/local/bin/overalls-ssh-authorize";
                path.into()
            },
            std::path::PathBuf::from,
        ),
    )
}

/// Windows guests have no helper: the roster agent owns accounts and only an
/// enabled local account resolves (`windows-terminal-roster-accounts`).
#[cfg(windows)]
fn account_helper() -> Option<std::path::PathBuf> {
    None
}

/// @cc [owner:ghuntley,label:security] connections-host-peer-only
/// Every accepted connection MUST come from vsock peer CID 2; any other peer
/// is closed and logged without reading its bytes.
pub fn handle_connections(daemon: &Arc<Daemon>, listener: vsock::Listener) {
    loop {
        match vsock::accept(listener) {
            Ok((fd, cid, _port)) => {
                if cid != vsock::CID_HOST {
                    log::event(log::Event::PeerRejected { cid });
                    conn::close(fd);
                    continue;
                }
                let bound = daemon.clone();
                std::thread::Builder::new()
                    .spawn(move || handle_connection(&bound, fd))
                    .ok();
            }
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(50)),
        }
    }
}

fn handle_connection(daemon: &Arc<Daemon>, fd: Conn) {
    let mut buffer = Vec::new();
    let Some(first) = session::read_frame(fd, &mut buffer) else {
        conn::close(fd);
        return;
    };
    let Ok(first) = first else {
        log::event(log::Event::FrameRejected);
        conn::close(fd);
        return;
    };
    if first.op != frame::OP_HELLO || !hello(daemon, fd, &first.payload) {
        conn::close(fd);
        return;
    }
    let Some(next) = session::read_frame(fd, &mut buffer) else {
        conn::close(fd);
        return;
    };
    let Ok(next) = next else {
        log::event(log::Event::FrameRejected);
        conn::close(fd);
        return;
    };
    if next.op == frame::OP_ATTACH {
        let Some(request) = session::decode_attach(&next.payload) else {
            let _ = session::write_frame(fd, frame::OP_ERR, &[frame::ERR_BAD_REQUEST]);
            conn::close(fd);
            return;
        };
        match daemon.attach(&request, fd) {
            Attached::Streams | Attached::Closed => {}
            Attached::Failed(code) => {
                let _ = session::write_frame(fd, frame::OP_ERR, &[code]);
                conn::close(fd);
            }
        }
    } else {
        control_message(daemon, fd, &next);
        control_loop(daemon, fd, &mut buffer);
        conn::close(fd);
    }
}

fn hello(daemon: &Daemon, fd: Conn, payload: &[u8]) -> bool {
    let Some((nonce, tag)) = session::decode_hello(payload) else {
        log::event(log::Event::AuthRejected);
        let _ = session::write_frame(fd, frame::OP_ERR, &[frame::ERR_AUTH]);
        return false;
    };
    if !daemon.verify_hello(&nonce, &tag) {
        log::event(log::Event::AuthRejected);
        let _ = session::write_frame(fd, frame::OP_ERR, &[frame::ERR_AUTH]);
        return false;
    }
    session::write_frame(fd, frame::OP_OK, &[]).is_ok()
}

fn control_loop(daemon: &Arc<Daemon>, fd: Conn, buffer: &mut Vec<u8>) {
    loop {
        let Some(next) = session::read_frame(fd, buffer) else {
            return;
        };
        let Ok(message) = next else {
            log::event(log::Event::FrameRejected);
            return;
        };
        if !control_message(daemon, fd, &message) {
            return;
        }
    }
}

fn control_message(daemon: &Arc<Daemon>, fd: Conn, message: &frame::Frame) -> bool {
    let outcome: Result<Vec<u8>, u8> = match message.op {
        frame::OP_CREATE => match session::decode_create(&message.payload) {
            Some((user, term, cols, rows)) => match daemon.create(&user, &term, cols, rows) {
                Ok((id, token)) => {
                    let mut out = Vec::new();
                    frame::put_u64(&mut out, id);
                    frame::put_bytes(&mut out, &token);
                    Ok(out)
                }
                Err(code) => Err(code),
            },
            None => Err(frame::ERR_BAD_REQUEST),
        },
        frame::OP_LIST => Ok(session::encode_list(&daemon.list())),
        frame::OP_USERS if message.payload.is_empty() => pty::users()
            .map(|users| {
                let mut out = Vec::new();
                #[expect(
                    clippy::cast_possible_truncation,
                    reason = "pty::users truncates the inventory to 64 names"
                )]
                frame::put_u16(&mut out, users.len() as u16);
                for user in users {
                    #[expect(
                        clippy::cast_possible_truncation,
                        reason = "pty::users keeps only names of at most 64 bytes"
                    )]
                    out.push(user.len() as u8);
                    out.extend_from_slice(user.as_bytes());
                }
                out
            })
            .map_err(|_| frame::ERR_BAD_REQUEST),
        frame::OP_CREATE_ONCE => match message.payload.split_first_chunk::<16>() {
            None => Err(frame::ERR_BAD_REQUEST),
            Some((request, rest)) => match session::decode_create(rest) {
                Some((user, term, cols, rows)) => daemon
                    .create_once(*request, &user, &term, cols, rows)
                    .map(|(id, token)| {
                        let mut out = id.to_be_bytes().to_vec();
                        out.extend_from_slice(&token);
                        out
                    }),
                None => Err(frame::ERR_BAD_REQUEST),
            },
        },
        frame::OP_CREATION_STATUS => match <[u8; 16]>::try_from(message.payload.as_slice()) {
            Ok(request) => match daemon.creation_status(&request) {
                Some((id, alive)) => {
                    let mut out = id.to_be_bytes().to_vec();
                    out.push(u8::from(alive));
                    Ok(out)
                }
                None => Err(frame::ERR_NOT_FOUND),
            },
            Err(_) => Err(frame::ERR_BAD_REQUEST),
        },
        frame::OP_CANCEL_CREATION => match <[u8; 16]>::try_from(message.payload.as_slice()) {
            Ok(request) => daemon.cancel_creation(request).map(|()| Vec::new()),
            Err(_) => Err(frame::ERR_BAD_REQUEST),
        },
        frame::OP_RECOVER_TOKEN => match session::decode_kill(&message.payload) {
            Some(id) => daemon.recover_token(id).map(|token| token.to_vec()),
            None => Err(frame::ERR_BAD_REQUEST),
        },
        frame::OP_KILL => match session::decode_kill(&message.payload) {
            Some(id) => daemon.kill(id).map(|()| Vec::new()),
            None => Err(frame::ERR_BAD_REQUEST),
        },
        frame::OP_RESIZE => match session::decode_resize(&message.payload) {
            Some((id, cols, rows)) => daemon.resize(id, cols, rows).map(|()| Vec::new()),
            None => Err(frame::ERR_BAD_REQUEST),
        },
        frame::OP_PING => Ok(Vec::new()),
        _ => Err(frame::ERR_BAD_REQUEST),
    };
    let wire = match outcome {
        Ok(payload) => session::write_frame(fd, frame::OP_OK, &payload),
        Err(code) => session::write_frame(fd, frame::OP_ERR, &[code]),
    };
    wire.is_ok()
}

/// Linux kernel guests read the boot identity from Lilly's command line.
#[cfg(target_os = "linux")]
fn boot_identity() -> Option<(String, String, String)> {
    let challenge = cmdline_value("lilly.boot_challenge")?;
    let placement = cmdline_value("lilly.placement")?;
    let epoch = cmdline_value("lilly.execution_epoch")?;
    validate_boot_identity(challenge, placement, epoch)
}

fn validate_boot_identity(
    challenge: String,
    placement: String,
    epoch: String,
) -> Option<(String, String, String)> {
    if challenge.len() != 64
        || !challenge
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return None;
    }
    let valid_placement = placement.len() == 36
        && placement.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        });
    if !valid_placement
        || epoch
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)?
            .to_string()
            != epoch
    {
        return None;
    }
    Some((challenge, placement, epoch))
}

/// Firmware guests read the same identity from Firecracker's MMDS (ADR-0171, ADR-0190).
#[cfg(any(windows, target_os = "freebsd", target_os = "illumos"))]
fn boot_identity() -> Option<(String, String, String)> {
    let (challenge, placement, epoch) = identity_mmds::fetch(std::time::Duration::from_mins(10))?;
    validate_boot_identity(challenge, placement, epoch)
}

#[cfg(target_os = "linux")]
fn cmdline_value(key: &str) -> Option<String> {
    let body = std::fs::read_to_string("/proc/cmdline").ok()?;
    for token in body.split(' ') {
        if let Some(rest) = token.strip_prefix(key) {
            if let Some(value) = rest.strip_prefix('=') {
                let cleaned = value.trim_matches(|c: char| c == '"' || c == '\n');
                if !cleaned.is_empty() {
                    return Some(cleaned.to_string());
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmdline_parses_lilly_identity() {
        let dir = std::env::temp_dir().join("terminald-cmdline-test");
        std::fs::create_dir_all(&dir).ok();
        let path = dir.join("cmdline");
        std::fs::write(&path, "console=ttyS0 lilly.ipv4=10.0.0.9 lilly.placement=abc lilly.execution_epoch=4 lilly.boot_challenge=deadbeef\n").ok();
        let body = std::fs::read_to_string(&path).unwrap();
        let value = |key: &str| {
            body.split(' ')
                .find_map(|token| token.strip_prefix(&format!("{key}=")))
                .map(|found| {
                    found
                        .trim_matches(|c: char| c == '"' || c == '\n')
                        .to_string()
                })
        };
        assert_eq!(value("lilly.boot_challenge").as_deref(), Some("deadbeef"));
        assert_eq!(value("lilly.placement").as_deref(), Some("abc"));
        assert_eq!(value("lilly.execution_epoch").as_deref(), Some("4"));
        assert_eq!(value("lilly.ipv4").as_deref(), Some("10.0.0.9"));
        assert_eq!(value("console").as_deref(), Some("ttyS0"));
        assert_eq!(value("lilly.absent"), None);
    }

    #[test]
    fn reader_rejects_trailing_bytes() {
        let mut payload = Vec::new();
        frame::put_u64(&mut payload, 7);
        payload.push(0xff);
        assert!(session::decode_kill(&payload).is_none());
    }

    #[test]
    fn boot_identity_requires_challenge_placement_and_positive_epoch() {
        let challenge = "a".repeat(64);
        let placement = "11111111-1111-4111-8111-111111111111".to_string();
        assert!(
            validate_boot_identity(challenge.clone(), placement.clone(), "4".to_string()).is_some()
        );
        assert!(
            validate_boot_identity("A".repeat(64), placement.clone(), "4".to_string()).is_none()
        );
        assert!(
            validate_boot_identity(challenge.clone(), "missing".to_string(), "4".to_string())
                .is_none()
        );
        assert!(
            validate_boot_identity(challenge.clone(), placement.clone(), "0".to_string()).is_none()
        );
        assert!(validate_boot_identity(challenge, placement, "04".to_string()).is_none());
    }
}
