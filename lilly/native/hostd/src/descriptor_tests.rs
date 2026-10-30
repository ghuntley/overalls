//! Connect-on-behalf and the ingress handoff (ADR-0184): requests carrying
//! the caller's own socket, the descriptor-count rule, and hostd releasing
//! every received copy.

use crate::descriptors::bridge_handoff;
use crate::exec::{run_handoff, start_reaper, Custody, Spec};
use crate::leases::Leases;
use crate::protocol::*;
use crate::session::{serve, Daemon};
use crate::utilities::Table;
use hegel::{generators as gs, TestCase};
use rustix::net::{
    connect, recv, sendmsg, socket_with, socketpair, AddressFamily, RecvFlags, SendAncillaryBuffer,
    SendAncillaryMessage, SendFlags, SocketAddrUnix, SocketFlags, SocketType,
};
use std::ffi::CString;
use std::io::{IoSlice, Read, Write};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

// ---------------------------------------------------------------- protocol

fn path_model(path: &[u8]) -> bool {
    path.len() <= 4096
        && path.first() == Some(&b'/')
        && !path.contains(&0)
        && path[1..]
            .split(|byte| *byte == b'/')
            .all(|part| !part.is_empty() && part != b"." && part != b"..")
}

/// @cc [owner:ghuntley,label:verification] hostd-connect-unix-decoding
/// `ConnectUnix` datagrams MUST be accepted exactly when the timeout is in
/// 1..=30000 ms and the path satisfies the directory model, and re-encode to
/// the received bytes.
#[hegel::test]
fn connect_unix_decoding_matches_model(tc: TestCase) {
    let timeout = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(0).max_value(3),
        gs::integers::<u32>().min_value(29_998).max_value(30_002),
        gs::integers::<u32>(),
    ));
    let path = tc.draw(hegel::one_of!(
        gs::just(b"/run/vm/api.sock".to_vec()),
        gs::just(b"/run/../v.sock".to_vec()),
        gs::just(b"relative".to_vec()),
        gs::just(Vec::new()),
        gs::binary().max_size(12),
    ));
    let mut body = vec![12_u8];
    body.extend(5_u64.to_be_bytes());
    body.extend(timeout.to_be_bytes());
    body.extend(&path);
    let model = (1..=30_000).contains(&timeout) && path_model(&path);
    let decoded = decode(&body);
    assert_eq!(decoded.is_ok(), model, "path {path:?} timeout {timeout}");
    if let Ok(envelope) = decoded {
        assert!(carries_descriptor(&envelope.request));
        assert_eq!(encode_request(&envelope), body);
    }
}

/// @cc [owner:ghuntley,label:verification] hostd-bridge-decoding
/// `BridgeNetnsTcp` datagrams MUST be accepted exactly when the port is
/// nonzero, the timeout is in 1..=30000 ms and both the namespace (its length
/// byte) and the device that follows it are nonempty, and re-encode to the
/// received bytes.
#[hegel::test]
fn bridge_decoding_matches_model(tc: TestCase) {
    let port = tc.draw(hegel::one_of!(gs::just(0_u16), gs::integers::<u16>()));
    let timeout = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(0).max_value(2),
        gs::integers::<u32>().min_value(29_999).max_value(30_001),
    ));
    let namespace = tc.draw(gs::binary().max_size(5));
    let device = tc.draw(gs::binary().max_size(5));
    let declared = tc.draw(hegel::one_of!(
        gs::just(u8::try_from(namespace.len()).unwrap()),
        gs::integers::<u8>().max_value(12),
    ));
    let mut body = vec![13_u8];
    body.extend(6_u64.to_be_bytes());
    body.extend(7_u32.to_be_bytes());
    body.extend([10, 0, 0, 2]);
    body.extend(port.to_be_bytes());
    body.extend([0, 0, 0, 0]);
    body.extend(timeout.to_be_bytes());
    body.push(declared);
    body.extend(&namespace);
    body.extend(&device);
    let rest = namespace.len() + device.len();
    let model = port != 0
        && (1..=30_000).contains(&timeout)
        && declared != 0
        && usize::from(declared) < rest;
    let decoded = decode(&body);
    assert_eq!(decoded.is_ok(), model, "body {body:?}");
    if let Ok(envelope) = decoded {
        assert!(carries_descriptor(&envelope.request));
        assert_eq!(encode_request(&envelope), body);
    }
}

/// Every other request carries no descriptor, and the removed lending
/// operations no longer decode.
#[test]
fn only_connect_requests_carry_descriptors() {
    for request in [
        Request::Hello { version: 1 },
        Request::Release { lease: 1 },
        Request::Cancel { target: 1 },
        Request::Attach {
            key: [0; JOB_KEY],
            wait_ms: 0,
        },
    ] {
        assert!(!carries_descriptor(&request));
    }
    let mut lend_unix = vec![8_u8];
    lend_unix.extend(1_u64.to_be_bytes());
    lend_unix.extend(b"/run/vm/api.sock");
    assert_eq!(decode(&lend_unix), Err(DecodeError::Operation));
    let mut lend_tcp = vec![9_u8];
    lend_tcp.extend(1_u64.to_be_bytes());
    lend_tcp.extend([0; 24]);
    assert_eq!(decode(&lend_tcp), Err(DecodeError::Operation));
}

// ---------------------------------------------------------------- sessions

struct Fixture {
    directory: tempfile::TempDir,
    socket: PathBuf,
    root: PathBuf,
}

/// A daemon whose socket root and private directory live in a temp dir.
fn daemon() -> Fixture {
    start_reaper().expect("subreaper");
    let directory = tempfile::tempdir().expect("tempdir");
    let root = directory.path().join("sockets");
    let private = directory.path().join("private");
    let leases = directory.path().join("leases");
    for path in [&root, &private, &leases] {
        std::fs::create_dir(path).unwrap();
    }
    let mut daemon = Daemon::new(
        Leases::new(std::slice::from_ref(&leases)).unwrap(),
        Table::default(),
        Custody::ProcessGroup,
        rustix::process::geteuid().as_raw(),
        Vec::new(),
    );
    daemon.socket_roots = vec![root.clone()];
    daemon.private_dir = Some(private);
    let daemon = Arc::new(daemon);
    let socket = directory.path().join("hostd.sock");
    let listener = socket_with(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    rustix::net::bind(&listener, &SocketAddrUnix::new(&socket).unwrap()).unwrap();
    rustix::net::listen(&listener, 16).unwrap();
    std::thread::spawn(move || loop {
        let Ok(connection) = rustix::net::accept_with(&listener, SocketFlags::CLOEXEC) else {
            return;
        };
        let daemon = Arc::clone(&daemon);
        std::thread::spawn(move || serve(daemon, connection));
    });
    Fixture {
        directory,
        socket,
        root,
    }
}

struct Client {
    socket: OwnedFd,
}

impl Client {
    fn connect(fixture: &Fixture) -> Client {
        let socket = socket_with(
            AddressFamily::UNIX,
            SocketType::SEQPACKET,
            SocketFlags::CLOEXEC,
            None,
        )
        .unwrap();
        connect(&socket, &SocketAddrUnix::new(&fixture.socket).unwrap()).unwrap();
        let client = Client { socket };
        client.send(1, Request::Hello { version: 1 }, &[]);
        assert_eq!(client.receive(), Some((1, Reply::Hello { version: 1 })));
        client
    }

    fn send(&self, id: u64, request: Request, descriptors: &[BorrowedFd<'_>]) {
        let datagram = encode_request(&Envelope { id, request });
        let mut space = [std::mem::MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(2))];
        let mut ancillary = SendAncillaryBuffer::new(&mut space);
        if !descriptors.is_empty() {
            assert!(ancillary.push(SendAncillaryMessage::ScmRights(descriptors)));
        }
        sendmsg(
            &self.socket,
            &[IoSlice::new(&datagram)],
            &mut ancillary,
            SendFlags::NOSIGNAL,
        )
        .unwrap();
    }

    /// The next reply, or None once hostd ended the session.
    fn receive(&self) -> Option<(u64, Reply)> {
        let mut buffer = vec![0_u8; 70_000];
        match recv(&self.socket, &mut buffer, RecvFlags::empty()) {
            Ok((0, _)) | Err(_) => None,
            Ok((size, _)) => Some(decode_reply(&buffer[..size]).expect("reply decodes")),
        }
    }

    fn connect_unix(&self, id: u64, path: &Path, socket: BorrowedFd<'_>) -> Option<Reply> {
        self.send(
            id,
            Request::ConnectUnix {
                timeout_ms: 1000,
                path: path.as_os_str().as_encoded_bytes().to_vec(),
            },
            &[socket],
        );
        self.receive().map(|(answered, reply)| {
            assert_eq!(answered, id);
            reply
        })
    }
}

fn unconnected() -> OwnedFd {
    socket_with(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        None,
    )
    .unwrap()
}

/// A Firecracker-like listener at `<root>/vm/<name>`.
fn listener(root: &Path, name: &str) -> (UnixListener, PathBuf) {
    let directory = root.join("vm");
    let _ = std::fs::create_dir(&directory);
    let path = directory.join(name);
    (UnixListener::bind(&path).unwrap(), path)
}

/// @cc [owner:ghuntley,label:verification;security] hostd-connects-callers-socket
/// `ConnectUnix` MUST connect the caller's own non-blocking socket to a
/// confined Firecracker socket and keep no copy: the caller's close alone
/// MUST give the listener's peer end of stream.
#[test]
fn connect_unix_connects_the_callers_socket_and_keeps_no_copy() {
    let fixture = daemon();
    let client = Client::connect(&fixture);
    let (listener, path) = listener(&fixture.root, "api.sock");
    let socket = unconnected();
    assert_eq!(
        client.connect_unix(2, &path, socket.as_fd()),
        Some(Reply::Connected)
    );
    let (mut peer, _) = listener.accept().unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    rustix::fs::fcntl_setfl(&socket, rustix::fs::OFlags::empty()).unwrap();
    let mut mine = UnixStream::from(socket);
    mine.write_all(b"GET / HTTP/1.1\r\n").unwrap();
    let mut received = [0_u8; 16];
    peer.read_exact(&mut received).unwrap();
    assert_eq!(&received, b"GET / HTTP/1.1\r\n");
    drop(mine);
    let mut rest = Vec::new();
    peer.read_to_end(&mut rest)
        .expect("end of stream once the caller closes: hostd kept no copy");
    // Compare lengths: the received bytes stay out of the failure message.
    assert_eq!(rest.len(), 0);
}

/// @cc [owner:ghuntley,label:verification;security] hostd-connect-refusals
/// `ConnectUnix` MUST refuse a path outside the socket roots, another basename
/// or a symbolic-link component (Unavailable), and a received descriptor
/// that is connected, listening or not a stream socket (Malformed); each
/// refused descriptor is closed by hostd.
#[test]
fn connect_unix_refuses_paths_and_socket_kinds() {
    let fixture = daemon();
    let client = Client::connect(&fixture);
    let (_api, api) = listener(&fixture.root, "api.sock");
    let (_other, other) = listener(&fixture.root, "other.sock");
    let link = fixture.root.join("link");
    std::os::unix::fs::symlink(fixture.root.join("vm"), &link).unwrap();
    let outside = fixture.directory.path().join("api.sock");
    let _outside = UnixListener::bind(&outside).unwrap();
    let unavailable = Some(Reply::Refused {
        reason: Refusal::Unavailable,
    });
    let malformed = Some(Reply::Refused {
        reason: Refusal::Malformed,
    });
    for (id, path) in [(10, other), (11, link.join("api.sock")), (12, outside)] {
        assert_eq!(
            client.connect_unix(id, &path, unconnected().as_fd()),
            unavailable
        );
    }
    let (connected, peer) = socketpair(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    assert_eq!(client.connect_unix(13, &api, connected.as_fd()), malformed);
    let datagram = socket_with(
        AddressFamily::UNIX,
        SocketType::DGRAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    assert_eq!(client.connect_unix(14, &api, datagram.as_fd()), malformed);
    let listening = unconnected();
    rustix::net::bind(
        &listening,
        &SocketAddrUnix::new(fixture.directory.path().join("listening.sock")).unwrap(),
    )
    .unwrap();
    rustix::net::listen(&listening, 1).unwrap();
    assert_eq!(client.connect_unix(15, &api, listening.as_fd()), malformed);
    // hostd closed its copy of the refused connected socket.
    drop(connected);
    let mut peer = UnixStream::from(peer);
    peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut rest = Vec::new();
    peer.read_to_end(&mut rest)
        .expect("hostd released the refused descriptor");
}

/// @cc [owner:ghuntley,label:verification;security] hostd-descriptor-count-rule
/// A `ConnectUnix` without a descriptor, a request that must carry none but
/// does, and a datagram carrying two descriptors MUST each end the session.
#[test]
fn misplaced_descriptors_end_the_session() {
    let fixture = daemon();
    let (_api, api) = listener(&fixture.root, "api.sock");
    let request = || Request::ConnectUnix {
        timeout_ms: 1000,
        path: api.as_os_str().as_encoded_bytes().to_vec(),
    };
    let missing = Client::connect(&fixture);
    missing.send(2, request(), &[]);
    assert_eq!(missing.receive(), None);
    let stray = Client::connect(&fixture);
    let socket = unconnected();
    stray.send(3, Request::Cancel { target: 9 }, &[socket.as_fd()]);
    assert_eq!(stray.receive(), None);
    let doubled = Client::connect(&fixture);
    let (first, second) = (unconnected(), unconnected());
    doubled.send(4, request(), &[first.as_fd(), second.as_fd()]);
    assert_eq!(doubled.receive(), None);
}

// ---------------------------------------------------------------- bridge

/// @cc [owner:ghuntley,label:verification;security] hostd-bridge-handoff-fixture
/// `bridge_handoff` MUST connect the caller's socket to hostd's private
/// listener, return the accepted end of exactly that connection and remove
/// the listener's path.
#[test]
fn bridge_handoff_returns_the_accepted_end_and_removes_its_listener() {
    let private = tempfile::tempdir().unwrap();
    let socket = unconnected();
    let accepted =
        bridge_handoff(private.path(), 3, 7, &socket, Duration::from_secs(1)).expect("handoff");
    assert_eq!(std::fs::read_dir(private.path()).unwrap().count(), 0);
    rustix::fs::fcntl_setfl(&socket, rustix::fs::OFlags::empty()).unwrap();
    let mut mine = UnixStream::from(socket);
    let mut theirs = UnixStream::from(accepted);
    mine.write_all(b"preface").unwrap();
    let mut received = [0_u8; 7];
    theirs.read_exact(&mut received).unwrap();
    assert_eq!(&received, b"preface");
    let (connected, _peer) = socketpair(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    assert!(bridge_handoff(private.path(), 3, 8, &connected, Duration::from_secs(1)).is_err());
    assert_eq!(std::fs::read_dir(private.path()).unwrap().count(), 0);
}

/// @cc [owner:ghuntley,label:verification;recovery] hostd-handoff-fixture
/// `run_handoff` MUST give the child the handed-off descriptors at 3 and 4,
/// signal its start once, and keep no copy: each peer sees end of stream when
/// the child exits.
#[test]
fn handoff_places_descriptors_at_three_and_four_and_keeps_no_copy() {
    start_reaper().expect("subreaper");
    let directory = tempfile::tempdir().unwrap();
    let child = directory.path().join("child");
    std::fs::write(&child, "#!/bin/sh\nprintf three >&3\nprintf four >&4\n").unwrap();
    std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o755)).unwrap();
    let pair = || {
        socketpair(
            AddressFamily::UNIX,
            SocketType::STREAM,
            SocketFlags::CLOEXEC,
            None,
        )
        .unwrap()
    };
    let ((first, first_peer), (second, second_peer)) = (pair(), pair());
    let started = AtomicBool::new(false);
    let cancelled = AtomicBool::new(false);
    let arguments: Vec<CString> = Vec::new();
    let (status, _, _) = run_handoff(
        &Spec {
            executable: &child,
            arguments: &arguments,
            timeout: Duration::from_secs(10),
            output_limit: 65_536,
            lease: None,
            inherit: &[],
        },
        vec![first, second],
        &Custody::ProcessGroup,
        &cancelled,
        &|| assert!(!started.swap(true, Ordering::SeqCst), "started once"),
    );
    assert_eq!(status, Status::Succeeded);
    assert!(started.load(Ordering::SeqCst));
    for (peer, expected) in [(first_peer, "three"), (second_peer, "four")] {
        let mut peer = UnixStream::from(peer);
        peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut received = String::new();
        peer.read_to_string(&mut received)
            .expect("end of stream: hostd kept no copy");
        assert_eq!(received, expected);
    }
}

/// A handoff never coexists with a lease or inherited descriptors.
#[test]
fn handoff_refuses_mixed_descriptors() {
    let lease = unconnected();
    let arguments: Vec<CString> = Vec::new();
    let (status, _, _) = run_handoff(
        &Spec {
            executable: Path::new("/bin/true"),
            arguments: &arguments,
            timeout: Duration::from_secs(1),
            output_limit: 65_536,
            lease: Some(&lease),
            inherit: &[],
        },
        vec![unconnected()],
        &Custody::ProcessGroup,
        &AtomicBool::new(false),
        &|| panic!("never started"),
    );
    assert_eq!(status, Status::Setup);
}
