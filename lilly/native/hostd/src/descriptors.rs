//! Connecting sockets Lilly may not connect itself (ADR-0182, ADR-0184).
//!
//! Lilly sends its own unconnected socket with the request and hostd
//! connects it: the BEAM cannot release a descriptor it did not create, so
//! hostd never sends one back.

use crate::protocol::Refusal;
use rustix::event::{PollFd, PollFlags};
use rustix::fs::{Mode as FileMode, OFlags};
use rustix::io::Errno;
use rustix::net::{
    accept_with, bind, connect, listen, socket_with, AddressFamily, SocketAddrUnix, SocketAddrV4,
    SocketFlags, SocketType,
};
use rustix::thread::{move_into_link_name_space, LinkNameSpaceType};
use std::net::Ipv4Addr;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Basenames of the only Unix sockets hostd connects to for Lilly.
const SOCKET_NAMES: &[&str] = &["api.sock", "v.sock"];

/// @cc [owner:ghuntley,label:security] hostd-unix-socket-confined
/// `confined_socket_path` MUST accept only a Firecracker `api.sock` or `v.sock`
/// whose absolute path, free of `.`, `..` and empty components, lies beneath
/// one of the configured socket roots and has no symbolic link at any
/// component below that root; every other path is Unavailable. hostd never
/// connects to other root-owned sockets on Lilly's behalf.
pub fn confined_socket_path(path: &Path, roots: &[PathBuf]) -> Result<(), Refusal> {
    let bytes = path.as_os_str().as_encoded_bytes();
    if !crate::protocol::valid_directory(bytes) {
        return Err(Refusal::Malformed);
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    let root = roots
        .iter()
        .find(|root| path.starts_with(root))
        .ok_or(Refusal::Unavailable)?;
    if !SOCKET_NAMES.contains(&name) {
        return Err(Refusal::Unavailable);
    }
    let mut current = root.clone();
    for component in path
        .strip_prefix(root)
        .map_err(|_| Refusal::Unavailable)?
        .components()
    {
        current.push(component);
        let stat = rustix::fs::lstat(&current).map_err(|_| Refusal::Unavailable)?;
        if stat.st_mode & libc::S_IFMT == libc::S_IFLNK {
            return Err(Refusal::Unavailable);
        }
    }
    Ok(())
}

/// Connect a received socket to a confined Firecracker socket.
pub fn connect_unix(
    socket: &OwnedFd,
    path: &Path,
    roots: &[PathBuf],
    timeout: Duration,
) -> Result<(), Refusal> {
    confined_socket_path(path, roots)?;
    let address = SocketAddrUnix::new(path).map_err(|_| Refusal::Unavailable)?;
    connect_received(socket, &address, timeout)
}

/// @cc [owner:ghuntley,label:security] hostd-received-socket-kind
/// `connect_received` MUST connect only a received descriptor that is an
/// unconnected, non-listening `AF_UNIX` stream socket; anything else is
/// Malformed and left untouched. The descriptor's file status flags are
/// shared with the caller and MUST NOT be changed: a non-blocking connect
/// that finds the listener's backlog full is retried until the timeout,
/// then Unavailable.
pub fn connect_received(
    socket: &OwnedFd,
    address: &SocketAddrUnix,
    timeout: Duration,
) -> Result<(), Refusal> {
    let unix_stream = rustix::fs::fstat(socket)
        .is_ok_and(|stat| stat.st_mode & libc::S_IFMT == libc::S_IFSOCK)
        && rustix::net::sockopt::socket_domain(socket) == Ok(AddressFamily::UNIX)
        && rustix::net::sockopt::socket_type(socket) == Ok(SocketType::STREAM)
        && rustix::net::sockopt::socket_acceptconn(socket) == Ok(false)
        && rustix::net::getpeername(socket).err() == Some(Errno::NOTCONN);
    if !unix_stream {
        return Err(Refusal::Malformed);
    }
    let deadline = Instant::now() + timeout;
    let mut pause = Duration::from_millis(1);
    loop {
        match connect(socket, address) {
            Ok(()) => return Ok(()),
            Err(Errno::INTR) => {}
            Err(Errno::AGAIN) if Instant::now() < deadline => {
                std::thread::sleep(pause.min(deadline.saturating_duration_since(Instant::now())));
                pause = (pause * 2).min(Duration::from_millis(50));
            }
            Err(_) => return Err(Refusal::Unavailable),
        }
    }
}

/// @cc [owner:ghuntley,label:security;isolation] hostd-bridge-handoff
/// `bridge_handoff` MUST connect the caller's received socket only to a fresh
/// listener that hostd bound in its private directory under a name unique to
/// the session and request, accept exactly that connection, and return the
/// accepted end only when its `SO_PEERCRED` pid is hostd's own (hostd made the
/// connection). The listener's path is removed and the listener closed
/// before returning, on every path.
pub fn bridge_handoff(
    private: &Path,
    session: u64,
    request: u64,
    socket: &OwnedFd,
    timeout: Duration,
) -> Result<OwnedFd, Refusal> {
    let path = private.join(format!("bridge-{session}-{request}.sock"));
    let _ = std::fs::remove_file(&path);
    let result = (|| {
        let listener = socket_with(
            AddressFamily::UNIX,
            SocketType::STREAM,
            SocketFlags::CLOEXEC,
            None,
        )
        .map_err(|_| Refusal::Unavailable)?;
        let address = SocketAddrUnix::new(&path).map_err(|_| Refusal::Unavailable)?;
        bind(&listener, &address).map_err(|_| Refusal::Unavailable)?;
        listen(&listener, 1).map_err(|_| Refusal::Unavailable)?;
        connect_received(socket, &address, timeout)?;
        let accepted =
            accept_with(&listener, SocketFlags::CLOEXEC).map_err(|_| Refusal::Unavailable)?;
        let peer =
            rustix::net::sockopt::socket_peercred(&accepted).map_err(|_| Refusal::Unavailable)?;
        if peer.pid != rustix::process::getpid() {
            return Err(Refusal::Unavailable);
        }
        Ok(accepted)
    })();
    let _ = std::fs::remove_file(&path);
    result
}

/// A namespace TCP connection request.
#[derive(Debug)]
pub struct NetnsTcp {
    pub namespace: String,
    pub device: String,
    pub mark: u32,
    pub destination: Ipv4Addr,
    pub port: u16,
    pub source: Option<Ipv4Addr>,
    pub timeout: Duration,
}

/// @cc [owner:ghuntley,label:security;isolation] hostd-netns-connect
/// `open_netns_tcp` MUST create the socket on a dedicated thread that entered
/// only `/run/netns/<namespace>` (a name of at most 64 letters, digits, `-`
/// or `_`), so no other hostd thread changes namespace. The socket is bound
/// to the named device (at most 15 such characters), carries the given
/// mark, binds the optional source address, and connects within the
/// timeout; any failure returns Unavailable and closes the socket. The
/// connection goes only to the ingress bridge, never to Lilly.
pub fn open_netns_tcp(request: NetnsTcp) -> Result<OwnedFd, Refusal> {
    let name_ok = |name: &str, limit: usize| {
        !name.is_empty()
            && name.len() <= limit
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    };
    if !name_ok(&request.namespace, 64) || !name_ok(&request.device, 15) {
        return Err(Refusal::Malformed);
    }
    std::thread::spawn(move || connect_in_namespace(&request))
        .join()
        .unwrap_or(Err(Refusal::Unavailable))
}

fn connect_in_namespace(request: &NetnsTcp) -> Result<OwnedFd, Refusal> {
    let namespace = rustix::fs::open(
        format!("/run/netns/{}", request.namespace),
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
        FileMode::empty(),
    )
    .map_err(|_| Refusal::Unavailable)?;
    move_into_link_name_space(namespace.as_fd(), Some(LinkNameSpaceType::Network))
        .map_err(|_| Refusal::Unavailable)?;
    let socket = socket_with(
        AddressFamily::INET,
        SocketType::STREAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        None,
    )
    .map_err(|_| Refusal::Unavailable)?;
    raw::configure(&socket, &request.device, request.mark).map_err(|_| Refusal::Unavailable)?;
    if let Some(source) = request.source {
        bind(&socket, &SocketAddrV4::new(source, 0)).map_err(|_| Refusal::Unavailable)?;
    }
    match connect(
        &socket,
        &SocketAddrV4::new(request.destination, request.port),
    ) {
        Ok(()) => {}
        Err(Errno::INPROGRESS) => {
            let millis = request.timeout.as_millis().clamp(1, 30_000) as i64;
            let timeout = rustix::event::Timespec {
                tv_sec: millis / 1000,
                tv_nsec: (millis % 1000) * 1_000_000,
            };
            let mut fds = [PollFd::from_borrowed_fd(socket.as_fd(), PollFlags::OUT)];
            match rustix::event::poll(&mut fds, Some(&timeout)) {
                Ok(1) => {}
                _ => return Err(Refusal::Unavailable),
            }
            match rustix::net::sockopt::socket_error(&socket) {
                Ok(Ok(())) => {}
                _ => return Err(Refusal::Unavailable),
            }
        }
        Err(_) => return Err(Refusal::Unavailable),
    }
    Ok(socket)
}

#[allow(
    unsafe_code,
    reason = "rustix does not wrap SO_BINDTODEVICE or SO_MARK; this shim is the only unsafe surface"
)]
mod raw {
    use std::os::fd::{AsRawFd, OwnedFd};

    /// Set `SO_BINDTODEVICE` and `SO_MARK`, which rustix does not wrap.
    pub(super) fn configure(socket: &OwnedFd, device: &str, mark: u32) -> std::io::Result<()> {
        let fd = socket.as_raw_fd();
        // The existing failure path: an unrepresentable length is an error.
        let device_length = libc::socklen_t::try_from(device.len())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        // SAFETY: fd is a live socket borrowed from `socket` for the call; the
        // device bytes are valid for reads of `device_length` bytes.
        let device_result = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_BINDTODEVICE,
                device.as_ptr().cast(),
                device_length,
            )
        };
        if device_result != 0 {
            return Err(std::io::Error::last_os_error());
        }
        #[expect(
            clippy::cast_possible_truncation,
            reason = "size_of::<u32>() is 4, which every socklen_t holds"
        )]
        let mark_length = size_of::<u32>() as libc::socklen_t;
        // SAFETY: fd is a live socket borrowed from `socket` for the call;
        // `mark` is a live local u32, valid for reads of `mark_length` bytes.
        let mark_result = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_MARK,
                (&raw const mark).cast(),
                mark_length,
            )
        };
        if mark_result != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}
