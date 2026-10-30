#![forbid(unsafe_code)]

//! The real `lilly-hostd` binary against malformed datagrams. Under the
//! `hardened` profile (panic = "abort") a decoder panic would kill the whole
//! daemon, so these tests only pass when no malformed datagram can panic it.

use hegel::{generators as gs, TestCase};
use lilly_hostd::protocol::{
    decode, decode_reply, encode_request, Envelope, Mode, Refusal, Reply, Request, JOB_KEY,
    PROTOCOL_VERSION,
};
use lilly_hostd::utilities::Utility;
use lilly_hostd::vm_launch::Launch;
use rustix::net::{
    connect, recv, send, socket_with, AddressFamily, RecvFlags, SendFlags, SocketAddrUnix,
    SocketFlags, SocketType,
};
use std::ffi::CString;
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const HOSTD: &str = env!("CARGO_BIN_EXE_lilly-hostd");

/// A running daemon on a private socket. Its PATH is an empty directory, so
/// no utility resolves; `--stdin-lifetime` ends it when this process exits.
struct Hostd {
    child: Child,
    socket: PathBuf,
    _directory: tempfile::TempDir,
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn hostd() -> &'static Mutex<Hostd> {
    static HOSTD_DAEMON: OnceLock<Mutex<Hostd>> = OnceLock::new();
    HOSTD_DAEMON.get_or_init(|| {
        let directory = tempfile::tempdir().expect("tempdir");
        let root = directory.path().join("root");
        let empty = directory.path().join("empty");
        std::fs::create_dir(&root).expect("root");
        std::fs::create_dir(&empty).expect("empty PATH");
        let socket = directory.path().join("hostd.sock");
        let child = Command::new(HOSTD)
            .arg("--socket")
            .arg(&socket)
            .arg("--root")
            .arg(&root)
            .arg("--stdin-lifetime")
            .env_clear()
            .env("PATH", &empty)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("hostd spawns");
        let deadline = Instant::now() + Duration::from_secs(10);
        while !socket.exists() {
            assert!(Instant::now() < deadline, "hostd never listened");
            std::thread::sleep(Duration::from_millis(5));
        }
        Mutex::new(Hostd {
            child,
            socket,
            _directory: directory,
        })
    })
}

impl Hostd {
    #[expect(
        clippy::expect_used,
        clippy::panic,
        reason = "a socket failure fails the calling test"
    )]
    fn connect(&mut self) -> OwnedFd {
        let socket = socket_with(
            AddressFamily::UNIX,
            SocketType::SEQPACKET,
            SocketFlags::CLOEXEC,
            None,
        )
        .expect("socket");
        if let Err(error) = connect(
            &socket,
            &SocketAddrUnix::new(&self.socket).expect("address"),
        ) {
            let status = self.child.try_wait();
            panic!("hostd refused a connection ({error}); its exit status: {status:?}");
        }
        socket
    }

    /// The daemon is still running.
    #[expect(clippy::expect_used, reason = "a wait failure fails the calling test")]
    fn assert_alive(&mut self, after: &[u8]) {
        let status = self.child.try_wait().expect("try_wait");
        assert!(
            status.is_none(),
            "hostd exited ({status:?}) after {after:?}"
        );
    }
}

#[expect(clippy::expect_used, reason = "a send failure fails the calling test")]
fn send_request(socket: &OwnedFd, id: u64, request: Request) {
    send(
        socket,
        &encode_request(&Envelope { id, request }),
        SendFlags::NOSIGNAL,
    )
    .expect("send");
}

/// The next reply, or None at end of stream.
#[expect(
    clippy::expect_used,
    reason = "a receive failure fails the calling test"
)]
fn reply(socket: &OwnedFd) -> Option<(u64, Reply)> {
    let mut buffer = vec![0_u8; 70_000];
    let (size, _) = recv(socket, &mut buffer, RecvFlags::empty()).expect("recv");
    let datagram = buffer.get(..size).expect("received within the buffer");
    (size > 0).then(|| decode_reply(datagram).expect("reply decodes"))
}

/// Send `frame` (after Hello when `hello`) on a fresh connection, require a
/// clean close with no reply, then require the daemon alive and a new
/// connection to answer Hello and a request.
fn malformed_then_valid(frame: &[u8], hello: bool) {
    let mut daemon = hostd()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let client = daemon.connect();
    if hello {
        send_request(
            &client,
            1,
            Request::Hello {
                version: PROTOCOL_VERSION,
            },
        );
        assert_eq!(
            reply(&client),
            Some((
                1,
                Reply::Hello {
                    version: PROTOCOL_VERSION
                }
            ))
        );
    }
    let _ = send(&client, frame, SendFlags::NOSIGNAL);
    assert_eq!(reply(&client), None, "malformed {frame:?} got a reply");
    drop(client);
    let next = daemon.connect();
    send_request(
        &next,
        2,
        Request::Hello {
            version: PROTOCOL_VERSION,
        },
    );
    assert_eq!(
        reply(&next),
        Some((
            2,
            Reply::Hello {
                version: PROTOCOL_VERSION
            }
        )),
        "no session after {frame:?}"
    );
    send_request(&next, 3, Request::Release { lease: 99 });
    assert_eq!(
        reply(&next),
        Some((
            3,
            Reply::Refused {
                reason: Refusal::UnknownLease
            }
        ))
    );
    daemon.assert_alive(frame);
}

#[expect(clippy::expect_used, reason = "fixed fixture arguments are NUL-free")]
fn valid_frames() -> Vec<Vec<u8>> {
    let requests = [
        Request::Hello { version: 1 },
        Request::Acquire {
            mode: Mode::Shared,
            wait_ms: 10,
            directory: b"/var/lib/lilly/locks/a".to_vec(),
        },
        Request::Run {
            lease: 1,
            timeout_ms: 5_000,
            output_limit: 65_536,
            utility: Utility::Stat,
            arguments: vec![
                CString::new("one").expect("argument"),
                CString::new("2").expect("argument"),
            ],
        },
        Request::Attach {
            key: [1; JOB_KEY],
            wait_ms: 5,
        },
        Request::BridgeNetnsTcp {
            mark: 7,
            destination: [10, 0, 0, 2],
            port: 22,
            source: [0; 4],
            timeout_ms: 1_000,
            namespace: b"lilly-abc".to_vec(),
            device: b"tap0".to_vec(),
        },
        Request::BridgeIngress {
            key: [2; lilly_hostd::ingress::KEY],
            greeting: b"hi".to_vec(),
            preface: b"PROXY".to_vec(),
            expect: b"OK".to_vec(),
            ready_ms: 1_000,
            mark: 7,
            destination: [10, 0, 0, 2],
            port: 443,
            source: [10, 0, 0, 1],
            timeout_ms: 1_000,
            namespace: b"lilly-abc".to_vec(),
            device: b"tap0".to_vec(),
        },
        Request::LaunchVm {
            lease: 1,
            launch: Launch {
                placement: *b"11111111-2222-4333-8444-555555555555",
                epoch: 7,
                generation: 9,
                uid: 1_000_010,
                memory_bytes: 1_342_177_280,
                vcpus: 2,
                firmware: false,
                logging: true,
                restore: false,
                state_dir: b"/var/lib/lilly/vms".to_vec(),
                namespace: b"lilly-guests".to_vec(),
                pool: b"/pool".to_vec(),
            },
        },
    ];
    requests
        .into_iter()
        .map(|request| encode_request(&Envelope { id: 9, request }))
        .collect()
}

/// @cc [owner:ghuntley,label:verification;security] hostd-binary-survives-malformed
/// For truncated, byte-corrupted and arbitrary datagrams, the real hostd
/// binary MUST close only the offending session, stay running and serve a
/// new session; built with `panic = "abort"` this proves no such datagram
/// panics the daemon.
#[hegel::test(test_cases = 150)]
fn malformed_datagrams_never_stop_the_daemon(tc: TestCase) {
    let frames = valid_frames();
    let mut frame = frames[tc.draw(gs::integers::<usize>().max_value(frames.len() - 1))].clone();
    match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => frame.truncate(tc.draw(gs::integers::<usize>().max_value(frame.len() - 1))),
        1 => {
            let at = tc.draw(gs::integers::<usize>().max_value(frame.len() - 1));
            frame[at] = tc.draw(gs::integers::<u8>());
        }
        _ => frame = tc.draw(gs::binary().max_size(300)),
    }
    tc.assume(decode(&frame).is_err());
    malformed_then_valid(&frame, tc.draw(gs::booleans()));
}

#[test]
fn oversized_and_corrupt_length_datagrams_never_stop_the_daemon() {
    let mut launch = valid_frames().remove(6);
    // The state directory length runs past the datagram.
    launch[9 + 74] = 255;
    let mut bridge = valid_frames().remove(4);
    // The namespace length leaves no device, then runs past the datagram.
    bridge[9 + 18] = 255;
    let oversized = vec![1_u8; 65_537];
    for frame in [launch, bridge, oversized, Vec::new(), vec![1; 8]] {
        malformed_then_valid(&frame, true);
        malformed_then_valid(&frame, false);
    }
}
