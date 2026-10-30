#![forbid(unsafe_code)]

//! Process fixtures: the real binary bridging two socketpairs, standing in
//! for Lilly's socket and the guest connection hostd dialled.

use rustix::net::{socketpair, AddressFamily, SocketFlags, SocketType};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const HELPER: &str = env!("CARGO_BIN_EXE_lilly-ingress-bridge");

/// Clearing CLOEXEC is process-wide: serialise spawns so no concurrently
/// spawned fixture inherits another fixture's socket and holds it open.
static SPAWN: Mutex<()> = Mutex::new(());

struct Bridge {
    child: Child,
    /// Lilly's end.
    lilly: UnixStream,
    /// The guest's end.
    guest: UnixStream,
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn pair() -> (OwnedFd, OwnedFd) {
    socketpair(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .expect("socketpair")
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn spawn(extra: &[&str]) -> Bridge {
    let (lilly, bridge_client) = pair();
    let (bridge_guest, guest) = pair();
    let _serial = SPAWN.lock().expect("spawn lock");
    for fd in [&bridge_client, &bridge_guest] {
        rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::empty()).expect("inheritable");
    }
    let child = Command::new(HELPER)
        .arg(bridge_client.as_raw_fd().to_string())
        .arg(bridge_guest.as_raw_fd().to_string())
        .args(extra)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("bridge spawns");
    // The parent's copies close here, as hostd drops its copies after spawn.
    drop((bridge_client, bridge_guest));
    Bridge {
        child,
        lilly: UnixStream::from(lilly),
        guest: UnixStream::from(guest),
    }
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn wait(child: &mut Child) -> ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().expect("wait") {
            return status;
        }
        assert!(Instant::now() < deadline, "bridge must exit");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn silent(child: &mut Child) {
    let mut out = Vec::new();
    child
        .stdout
        .take()
        .expect("stdout")
        .read_to_end(&mut out)
        .expect("stdout");
    child
        .stderr
        .take()
        .expect("stderr")
        .read_to_end(&mut out)
        .expect("stderr");
    assert!(
        out.is_empty(),
        "the bridge writes nothing to stdout or stderr"
    );
}

#[expect(
    clippy::cast_possible_truncation,
    reason = "the payload pattern deliberately wraps the index modulo 256"
)]
fn payload(length: usize, seed: u8) -> Vec<u8> {
    (0..length)
        .map(|index| (index as u8).wrapping_mul(31).wrapping_add(seed))
        .collect()
}

/// @cc [owner:ghuntley,label:verification] bridge-exact-custody
/// Bytes larger than the pipe window MUST arrive intact in both directions at
/// once, a guest end of stream MUST reach Lilly's side only after the guest's
/// bytes, and Lilly's close MUST end the bridge successfully with the guest
/// seeing end of stream, with nothing on stdout or stderr.
#[test]
fn bytes_cross_both_ways_and_lilly_closing_ends_the_bridge() {
    let mut bridge = spawn(&[]);
    let up = payload(1_048_576 + 17, 3);
    let down = payload(786_433, 101);
    let mut lilly_writer = bridge.lilly.try_clone().expect("clone");
    let mut guest_writer = bridge.guest.try_clone().expect("clone");
    let up_sent = up.clone();
    let down_sent = down.clone();
    let writers = [
        std::thread::spawn(move || {
            for chunk in up_sent.chunks(7919) {
                lilly_writer.write_all(chunk).expect("lilly writes");
            }
        }),
        std::thread::spawn(move || {
            for chunk in down_sent.chunks(4099) {
                guest_writer.write_all(chunk).expect("guest writes");
            }
            guest_writer
                .shutdown(std::net::Shutdown::Write)
                .expect("guest half-closes");
        }),
    ];
    let mut guest_reader = bridge.guest.try_clone().expect("clone");
    let up_reader = std::thread::spawn(move || {
        let mut received = vec![0_u8; 1_048_576 + 17];
        guest_reader.read_exact(&mut received).expect("guest reads");
        received
    });
    let mut received_down = Vec::new();
    bridge
        .lilly
        .read_to_end(&mut received_down)
        .expect("lilly reads to the guest's end of stream");
    assert_eq!(received_down, down);
    for writer in writers {
        writer.join().expect("writer");
    }
    assert_eq!(up_reader.join().expect("reader"), up);
    bridge
        .lilly
        .shutdown(std::net::Shutdown::Both)
        .expect("lilly closes");
    drop(bridge.lilly);
    let mut rest = Vec::new();
    bridge
        .guest
        .read_to_end(&mut rest)
        .expect("guest sees end of stream");
    assert_eq!(rest, Vec::<u8>::new());
    assert!(wait(&mut bridge.child).success());
    silent(&mut bridge.child);
}

/// @cc [owner:ghuntley,label:verification] bridge-silent-guest
/// Lilly closing MUST end the bridge even when the guest never closes.
#[test]
fn a_silent_guest_cannot_keep_the_bridge_alive() {
    let mut bridge = spawn(&[]);
    bridge.lilly.write_all(b"preface").expect("lilly writes");
    drop(bridge.lilly);
    let mut received = [0_u8; 7];
    bridge.guest.read_exact(&mut received).expect("guest reads");
    assert_eq!(&received, b"preface");
    assert!(wait(&mut bridge.child).success());
    drop(bridge.guest);
}

/// @cc [owner:ghuntley,label:verification] bridge-guest-loss
/// Lilly writing after the guest vanished MUST end the bridge with a failure
/// and close Lilly's side.
#[test]
fn guest_loss_ends_the_bridge_and_closes_lilly() {
    let mut bridge = spawn(&[]);
    drop(bridge.guest);
    let mut rest = Vec::new();
    bridge
        .lilly
        .read_to_end(&mut rest)
        .expect("lilly sees end of stream");
    let _ = bridge.lilly.write_all(&payload(262_144, 9));
    assert!(!wait(&mut bridge.child).success());
}

/// Splicing into a socket whose peer closed MUST end the bridge with its
/// I/O failure status, never by SIGPIPE, even when its parent restored the
/// default SIGPIPE disposition before exec (hostd's `spawn_detached` does).
#[test]
fn guest_loss_while_relaying_exits_with_io_failure_not_sigpipe() {
    use std::os::unix::process::ExitStatusExt;
    let mut bridge = spawn(&[]);
    drop(bridge.guest);
    let _ = bridge.lilly.write_all(&payload(262_144, 11));
    let status = wait(&mut bridge.child);
    assert_eq!(status.signal(), None, "{status:?}");
    assert_eq!(status.code(), Some(74), "{status:?}");
}

/// @cc [owner:ghuntley,label:verification] bridge-refuses-bad-input
/// A malformed command line exits 64 and a descriptor that is not a socket
/// exits 70, before any byte moves.
#[test]
fn bad_command_lines_and_non_sockets_are_refused() {
    let status = Command::new(HELPER)
        .args(["2", "4"])
        .status()
        .expect("bridge runs");
    assert_eq!(status.code(), Some(64));
    let file = tempfile::tempfile().expect("regular file");
    let (_peer, socket) = pair();
    let _serial = SPAWN.lock().expect("spawn lock");
    let file = OwnedFd::from(file);
    for fd in [&file, &socket] {
        rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::empty()).expect("inheritable");
    }
    let status = Command::new(HELPER)
        .arg(file.as_raw_fd().to_string())
        .arg(socket.as_raw_fd().to_string())
        .status()
        .expect("bridge runs");
    assert_eq!(status.code(), Some(70));
}

/// @cc [owner:ghuntley,label:verification;security] bridge-drops-privileges
/// Run as root with a uid, the bridge MUST run as that uid and gid with no
/// supplementary groups and `no_new_privs`. Skipped without root.
#[test]
fn root_bridge_runs_as_the_given_uid() {
    if !rustix::process::geteuid().is_root() {
        return;
    }
    let mut bridge = spawn(&["65534"]);
    bridge.lilly.write_all(b"x").expect("lilly writes");
    let mut byte = [0_u8; 1];
    bridge
        .guest
        .read_exact(&mut byte)
        .expect("bridge is running");
    let status = std::fs::read_to_string(format!("/proc/{}/status", bridge.child.id()))
        .expect("bridge status");
    let field = |name: &str| {
        status
            .lines()
            .find_map(|line| line.strip_prefix(name))
            .map(|value| value.split_whitespace().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    assert_eq!(field("Uid:"), ["65534"; 4]);
    assert_eq!(field("Gid:"), ["65534"; 4]);
    assert_eq!(field("Groups:"), Vec::<&str>::new());
    assert_eq!(field("NoNewPrivs:"), ["1"]);
    drop(bridge.lilly);
    assert!(wait(&mut bridge.child).success());
}

/// A detached bridge with hostd's end of its control socket.
struct Detached {
    bridge: Bridge,
    control: UnixStream,
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn spawn_detached() -> Detached {
    let (lilly, bridge_client) = pair();
    let (bridge_guest, guest) = pair();
    let (control, bridge_control) = pair();
    let _serial = SPAWN.lock().expect("spawn lock");
    for fd in [&bridge_client, &bridge_guest, &bridge_control] {
        rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::empty()).expect("inheritable");
    }
    let child = Command::new(HELPER)
        .arg("--detached")
        .arg(bridge_control.as_raw_fd().to_string())
        .arg(bridge_client.as_raw_fd().to_string())
        .arg(bridge_guest.as_raw_fd().to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("bridge spawns");
    drop((bridge_client, bridge_guest, bridge_control));
    Detached {
        bridge: Bridge {
            child,
            lilly: UnixStream::from(lilly),
            guest: UnixStream::from(guest),
        },
        control: UnixStream::from(control),
    }
}

/// @cc [owner:ghuntley,label:verification;security] bridge-detached-handshake-fixture
/// A detached bridge MUST send READY, move no guest byte to its client before
/// GO, bridge exactly after GO, and exit 70 without moving a byte when the
/// control socket ends before GO.
#[test]
fn detached_bridge_moves_nothing_before_go() {
    let mut detached = spawn_detached();
    let mut ready = [0_u8; 1];
    detached
        .control
        .read_exact(&mut ready)
        .expect("bridge reports ready");
    assert_eq!(ready[0], lilly_ingress_bridge::READY);
    detached
        .bridge
        .guest
        .write_all(b"banner")
        .expect("guest speaks first");
    detached
        .bridge
        .lilly
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("timeout");
    let mut early = [0_u8; 6];
    assert!(
        detached.bridge.lilly.read(&mut early).is_err(),
        "no guest byte may reach the client before GO"
    );
    detached
        .bridge
        .lilly
        .write_all(b"greeting")
        .expect("the client writes before GO");
    detached
        .control
        .write_all(&[lilly_ingress_bridge::GO])
        .expect("hostd answers GO");
    detached
        .bridge
        .lilly
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("timeout");
    detached
        .bridge
        .lilly
        .read_exact(&mut early)
        .expect("guest bytes after GO");
    assert_eq!(&early, b"banner");
    let mut moved = [0_u8; 8];
    detached
        .bridge
        .guest
        .read_exact(&mut moved)
        .expect("client bytes reach the guest");
    assert_eq!(&moved, b"greeting");
    drop(detached.bridge.lilly);
    assert!(wait(&mut detached.bridge.child).success());
    silent(&mut detached.bridge.child);

    let mut abandoned = spawn_detached();
    abandoned
        .control
        .read_exact(&mut ready)
        .expect("bridge reports ready");
    drop(abandoned.control);
    assert_eq!(wait(&mut abandoned.bridge.child).code(), Some(70));
    abandoned
        .bridge
        .guest
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("timeout");
    let mut rest = Vec::new();
    abandoned
        .bridge
        .guest
        .read_to_end(&mut rest)
        .expect("guest sees end of stream");
    assert!(rest.is_empty(), "an abandoned bridge moves no byte");
}
