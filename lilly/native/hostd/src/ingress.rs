//! Detached ingress bridges (ADR-0187).
//!
//! Every ingress connection (SSH, web, nested SSH and HTTPS, and, since
//! ADR-0192, the editor) is bridged straight from Audi's connection to the
//! guest by `lilly-ingress-bridge`, which runs in its own transient
//! `lilly-ingress-<key>.scope` in `lilly_ingress.slice`. A preface Lilly
//! derived and the exact ready frame Lilly requires are exchanged with the
//! guest by hostd before the bridge starts (`stage`). The scope is
//! not part of hostd's unit or of Lilly's, so the bridge, and the guest
//! session inside it, survive a restart of either. hostd starts it, lists the
//! live ones and ends one by killing its scope's cgroup; Lilly decides which
//! bridges may live (its execution guardian) and re-adopts them by key after
//! a restart.

use crate::protocol::Refusal;
use rustix::event::{PollFd, PollFlags};
use rustix::io::Errno;
use rustix::net::{AddressFamily, SocketType};
use std::ffi::CString;
use std::fmt::Write as _;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Bytes in a bridge key.
pub const KEY: usize = 16;
/// Largest greeting hostd writes to the client before the bridge moves bytes.
pub const MAX_GREETING: usize = 256;
/// Largest preface hostd writes to the guest before the bridge starts: the
/// editor's length-framed binding (at most 2048 + 4 bytes) or a 28-byte
/// PROXY v2 header (ADR-0192).
pub const MAX_PREFACE: usize = 4096;
/// Largest frame hostd requires from the guest before the bridge starts.
pub const MAX_EXPECT: usize = 256;
/// Longest wait for that frame: the editor's bounded cold start.
pub const MAX_READY_MS: u32 = 30_000;
/// Most live detached bridges on a host; further requests are Unavailable.
pub const MAX_BRIDGES: usize = 1024;
/// How long a bridge may take to report READY after it is spawned.
pub const START_TIMEOUT: Duration = Duration::from_secs(4);
/// How long ending a bridge may wait for its scope to empty.
pub const END_TIMEOUT: Duration = Duration::from_secs(10);
/// A bridge's hard lifetime: its scope's `RuntimeMaxSec`.
pub const LIFETIME_SECONDS: u64 = 30 * 24 * 3600;

/// Detached bridge configuration; absent, `BridgeIngress` is Unavailable.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    /// The only uid whose connection may be a bridge's client (Audi).
    pub peer_uid: u32,
    /// The top-level slice the scopes are created in (`lilly.slice`).
    pub slice: String,
    /// That slice's cgroup directory.
    pub cgroup: PathBuf,
    /// `systemd-run`; None runs the helper directly (unit tests only).
    pub launcher: Option<PathBuf>,
}

/// @cc [owner:ghuntley,label:security] ingress-slice-name
/// `valid_slice` MUST accept only a top-level slice name: 1 to 64 lowercase
/// letters, digits or `_`, then `.slice`. A `-` would nest the slice, so the
/// cgroup directory hostd lists and kills in would not be the one systemd uses.
pub fn valid_slice(slice: &str) -> bool {
    slice.strip_suffix(".slice").is_some_and(|name| {
        !name.is_empty()
            && name.len() <= 64
            && name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    })
}

/// The scope unit name of a key: `lilly-ingress-<32 lowercase hex>.scope`.
pub fn unit(key: &[u8; KEY]) -> String {
    let mut name = String::from("lilly-ingress-");
    for byte in key {
        // Writing to a String cannot fail.
        let _ = write!(name, "{byte:02x}");
    }
    name.push_str(".scope");
    name
}

/// @cc [owner:ghuntley,label:security] ingress-scope-names-closed
/// `key_of` MUST return a key only for exactly `lilly-ingress-` followed by 32
/// lowercase hexadecimal digits and `.scope`, the inverse of unit; hostd never
/// lists or kills any other cgroup in the slice.
pub fn key_of(name: &[u8]) -> Option<[u8; KEY]> {
    let hex = name
        .strip_prefix(b"lilly-ingress-")?
        .strip_suffix(b".scope")?;
    if hex.len() != KEY * 2 {
        return None;
    }
    let digit = |byte: u8| match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    };
    let mut key = [0_u8; KEY];
    for (slot, pair) in key.iter_mut().zip(hex.chunks(2)) {
        *slot = (digit(pair[0])? << 4) | digit(pair[1])?;
    }
    Some(key)
}

fn populated(cgroup: &Path) -> Option<bool> {
    let events = std::fs::read(cgroup.join("cgroup.events")).ok()?;
    events
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"populated "))
        .map(|value| value != b"0")
}

/// @cc [owner:ghuntley,label:recovery] ingress-bridges-listed-from-cgroups
/// live MUST list exactly the keys of `lilly-ingress-<key>.scope` cgroups in
/// the slice whose `cgroup.events` reports `populated 1`, sorted, so every
/// running detached bridge is found after a hostd or Lilly restart without
/// any state hostd kept.
pub fn live(config: &Config) -> Vec<[u8; KEY]> {
    let Ok(entries) = std::fs::read_dir(&config.cgroup) else {
        return Vec::new();
    };
    let mut keys: Vec<[u8; KEY]> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let key = key_of(entry.file_name().as_encoded_bytes())?;
            (populated(&entry.path()) == Some(true)).then_some(key)
        })
        .collect();
    keys.sort_unstable();
    keys
}

/// @cc [owner:ghuntley,label:security;recovery] ingress-bridge-ended-by-scope
/// end MUST kill every process in the key's scope cgroup (`cgroup.kill`) and
/// return Ok only once `cgroup.events` reports `populated 0` or the scope is
/// gone; an absent scope is already ended. It never removes the cgroup,
/// which systemd owns. A scope still populated after `END_TIMEOUT` is
/// Unavailable, and the caller retries.
pub fn end(config: &Config, key: &[u8; KEY]) -> Result<(), Refusal> {
    let cgroup = config.cgroup.join(unit(key));
    let deadline = Instant::now() + END_TIMEOUT;
    let mut pause = Duration::from_millis(2);
    loop {
        match populated(&cgroup) {
            None | Some(false) => return Ok(()),
            Some(true) => {}
        }
        if Instant::now() >= deadline {
            return Err(Refusal::Unavailable);
        }
        let _ = std::fs::write(cgroup.join("cgroup.kill"), b"1");
        std::thread::sleep(pause);
        pause = (pause * 2).min(Duration::from_millis(100));
    }
}

/// @cc [owner:ghuntley,label:security] ingress-client-is-audi
/// `client_kind` MUST accept only a connected `AF_UNIX` stream socket that is not
/// listening and whose `SO_PEERCRED` uid is the configured Audi uid; anything
/// else is Malformed and left untouched. hostd therefore bridges only Audi's
/// own connection to Lilly's ingress socket, never a socket of Lilly's
/// choosing to another local service.
pub fn client_kind(socket: &OwnedFd, peer_uid: u32) -> Result<(), Refusal> {
    let stream = rustix::fs::fstat(socket)
        .is_ok_and(|stat| stat.st_mode & libc::S_IFMT == libc::S_IFSOCK)
        && rustix::net::sockopt::socket_domain(socket) == Ok(AddressFamily::UNIX)
        && rustix::net::sockopt::socket_type(socket) == Ok(SocketType::STREAM)
        && rustix::net::sockopt::socket_acceptconn(socket) == Ok(false)
        && rustix::net::getpeername(socket).is_ok();
    let audi = rustix::net::sockopt::socket_peercred(socket)
        .is_ok_and(|credentials| credentials.uid.as_raw() == peer_uid);
    if stream && audi {
        Ok(())
    } else {
        Err(Refusal::Malformed)
    }
}

/// The command line of one detached bridge: `systemd-run --scope` placing
/// the helper in its own scope, or the helper alone without a launcher.
pub fn command(
    config: &Config,
    helper: &Path,
    key: &[u8; KEY],
    uid: Option<u32>,
) -> Option<(PathBuf, Vec<CString>)> {
    let text = |value: &str| CString::new(value).ok();
    let mut bridge = vec![
        text(helper.to_str()?)?,
        text("--detached")?,
        text("5")?,
        text("3")?,
        text("4")?,
    ];
    if let Some(uid) = uid {
        bridge.push(text(&uid.to_string())?);
    }
    match &config.launcher {
        None => Some((helper.to_path_buf(), bridge[1..].to_vec())),
        Some(launcher) => {
            let mut arguments = vec![
                text("--scope")?,
                text("--quiet")?,
                text("--collect")?,
                text(&format!("--unit={}", unit(key)))?,
                text(&format!("--slice={}", config.slice))?,
                text(&format!("--property=RuntimeMaxSec={LIFETIME_SECONDS}"))?,
                text("--")?,
            ];
            arguments.extend(bridge);
            Some((launcher.clone(), arguments))
        }
    }
}

/// What hostd exchanges with the guest before a detached bridge starts
/// (ADR-0192): bytes Lilly derived for the guest and the exact frame Lilly
/// requires back. Both are empty for preface-free services.
#[derive(Clone, Copy, Debug)]
pub struct Stage<'a> {
    pub preface: &'a [u8],
    pub expect: &'a [u8],
    pub ready: Duration,
}

/// @cc [owner:ghuntley,label:security;protocol] ingress-guest-stage
/// stage MUST write the whole preface to the guest within `START_TIMEOUT` and
/// then, when an expected frame is given, read exactly its length from the
/// guest within `ready` and require byte equality. It MUST NOT read one byte
/// past the expected frame, so every later guest byte reaches the client
/// through the bridge; it interprets nothing and decides nothing beyond that
/// comparison. A short write, a closed guest, a timeout or any other byte is
/// Unavailable.
pub fn stage(guest: &OwnedFd, stage: &Stage<'_>) -> Result<(), Refusal> {
    if !write_all(guest, stage.preface, Instant::now() + START_TIMEOUT) {
        return Err(Refusal::Unavailable);
    }
    if stage.expect.is_empty() {
        return Ok(());
    }
    let deadline = Instant::now() + stage.ready;
    let mut got = vec![0_u8; stage.expect.len()];
    let mut filled = 0;
    while filled < got.len() {
        match rustix::net::recv(guest, &mut got[filled..], rustix::net::RecvFlags::DONTWAIT) {
            Ok((0, _)) => return Err(Refusal::Unavailable),
            Ok((count, _)) => filled += count,
            Err(Errno::INTR) => {}
            Err(Errno::AGAIN) => {
                if !wait(guest, PollFlags::IN, deadline) {
                    return Err(Refusal::Unavailable);
                }
            }
            Err(_) => return Err(Refusal::Unavailable),
        }
    }
    if got == stage.expect {
        Ok(())
    } else {
        Err(Refusal::Unavailable)
    }
}

/// Wait until `fd` is ready for `flags` or the deadline passes.
fn wait(fd: &OwnedFd, flags: PollFlags, deadline: Instant) -> bool {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return false;
        }
        let millis = remaining.as_millis().clamp(1, 1000) as i64;
        let timeout = rustix::event::Timespec {
            tv_sec: millis / 1000,
            tv_nsec: (millis % 1000) * 1_000_000,
        };
        let mut fds = [PollFd::from_borrowed_fd(fd.as_fd(), flags)];
        match rustix::event::poll(&mut fds, Some(&timeout)) {
            Ok(0) | Err(Errno::INTR) => {}
            Ok(_) => return true,
            Err(_) => return false,
        }
    }
}

/// Read exactly the READY byte from the control socket before the deadline.
pub fn await_ready(control: &OwnedFd, deadline: Instant) -> bool {
    let mut byte = [0_u8; 1];
    loop {
        if !wait(control, PollFlags::IN, deadline) {
            return false;
        }
        match rustix::io::read(control, &mut byte) {
            Ok(1) => return byte[0] == READY,
            Err(Errno::INTR | Errno::AGAIN) => {}
            _ => return false,
        }
    }
}

/// Write all of `bytes` to a socket whose flags hostd must not change (the
/// client's description is shared with Lilly's port), before the deadline.
pub fn write_all(socket: &OwnedFd, mut bytes: &[u8], deadline: Instant) -> bool {
    while !bytes.is_empty() {
        match rustix::net::send(
            socket,
            bytes,
            rustix::net::SendFlags::NOSIGNAL | rustix::net::SendFlags::DONTWAIT,
        ) {
            Ok(count) => bytes = &bytes[count..],
            Err(Errno::INTR) => {}
            Err(Errno::AGAIN) => {
                if !wait(socket, PollFlags::OUT, deadline) {
                    return false;
                }
            }
            Err(_) => return false,
        }
    }
    true
}

/// Start one detached bridge between `client` and `guest` and hand it the
/// greeting handshake (hostd-detached-ingress-bridge). hostd keeps a copy of
/// the client only until the greeting is written.
pub fn start(
    config: &Config,
    helper: &Path,
    key: &[u8; KEY],
    greeting: &[u8],
    client: OwnedFd,
    guest: OwnedFd,
    uid: Option<u32>,
) -> Result<(), Refusal> {
    let (executable, arguments) = command(config, helper, key, uid).ok_or(Refusal::Unavailable)?;
    let (control, bridge_control) = rustix::net::socketpair(
        AddressFamily::UNIX,
        SocketType::STREAM,
        rustix::net::SocketFlags::CLOEXEC,
        None,
    )
    .map_err(|_| Refusal::Unavailable)?;
    let writer = client.try_clone().map_err(|_| Refusal::Unavailable)?;
    let deadline = Instant::now() + START_TIMEOUT;
    let child =
        crate::exec::spawn_detached(&executable, &arguments, vec![client, guest, bridge_control])
            .ok_or(Refusal::Unavailable)?;
    let started = await_ready(&control, deadline)
        && write_all(&writer, greeting, deadline)
        && write_all(&control, &[GO], deadline);
    drop(writer);
    if started {
        return Ok(());
    }
    child.kill();
    if config.launcher.is_some() {
        let _ = end(config, key);
    }
    Err(Refusal::Unavailable)
}

/// The bridge's READY byte (lilly-ingress-bridge's READY).
pub const READY: u8 = b'R';
/// hostd's GO byte (lilly-ingress-bridge's GO).
pub const GO: u8 = b'G';
