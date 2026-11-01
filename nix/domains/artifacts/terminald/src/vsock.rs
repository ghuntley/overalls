//! `AF_VSOCK` listener and peer-CID verification via libc.
use crate::sys::unix as sys;
use std::io;
use std::os::unix::io::RawFd;

pub(crate) const AF_VSOCK: i32 = 40;
pub(crate) const CID_ANY: u32 = 0xffff_ffff;
pub(crate) const CID_HOST: u32 = 2;
#[cfg(test)]
pub(crate) const CID_LOCAL: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct SockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

impl SockaddrVm {
    fn new(cid: u32, port: u32) -> Self {
        SockaddrVm {
            #[expect(
                clippy::cast_possible_truncation,
                reason = "AF_VSOCK is the constant 40, which fits sa_family_t"
            )]
            family: AF_VSOCK as u16,
            reserved: 0,
            port,
            cid,
            zero: [0; 4],
        }
    }
}

#[cfg(test)]
pub(crate) fn address(cid: u32, port: u32) -> SockaddrVm {
    SockaddrVm::new(cid, port)
}

#[cfg(test)]
pub(crate) fn bound_port(listener: RawFd) -> io::Result<u32> {
    let mut bound = SockaddrVm::new(0, 0);
    let (status, _) = sys::getsockname(listener, &mut bound);
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(bound.port)
}

#[cfg(test)]
pub(crate) fn available() -> bool {
    let Ok(fd) = listen(0) else {
        return false;
    };
    // `fd` is the probe listener this function owns and never uses again.
    sys::close(fd);
    true
}

/// The listening vsock descriptor.
pub(crate) type Listener = RawFd;

pub(crate) fn listen(port: u32) -> io::Result<Listener> {
    let fd = sys::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let one: libc::c_int = 1;
    sys::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, &one);
    let address = SockaddrVm::new(CID_ANY, port);
    let result = sys::bind(fd, &address);
    if result < 0 {
        let error = io::Error::last_os_error();
        // This function owns `fd`, which is never returned on this path.
        sys::close(fd);
        return Err(error);
    }
    if sys::listen(fd, 64) < 0 {
        let error = io::Error::last_os_error();
        // This function owns `fd`, which is never returned on this path.
        sys::close(fd);
        return Err(error);
    }
    Ok(fd)
}

/// @cc [owner:ghuntley,label:security] vsock-host-peer-only
/// `accept` MUST return the peer CID observed by the kernel; the caller MUST
/// reject any peer other than the host CID before reading requests.
pub(crate) fn accept(listener: RawFd) -> io::Result<(RawFd, u32, u32)> {
    let mut peer = SockaddrVm::new(0, 0);
    let (fd, _) = sys::accept4(listener, &mut peer, libc::SOCK_CLOEXEC);
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((fd, peer.cid, peer.port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[allow(
        clippy::print_stderr,
        reason = "the skip notice explains why the test passed without vsock"
    )]
    fn loopback_connection_observes_peer_cids() {
        if !available() {
            eprintln!("skipping: AF_VSOCK unavailable in this environment");
            return;
        }
        let listener = listen(0).expect("bind ephemeral vsock port");
        let mut bound = SockaddrVm::new(0, 0);
        assert_eq!(sys::getsockname(listener, &mut bound).0, 0);
        let client = sys::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
        assert!(client >= 0);
        let local = SockaddrVm::new(CID_LOCAL, bound.port);
        let connected = sys::connect(client, &local);
        if connected < 0 {
            eprintln!("skipping: vsock local loopback connect failed");
            // The test owns `client` and `listener`.
            sys::close(client);
            sys::close(listener);
            return;
        }
        let (server, cid, _port) = accept(listener).expect("accept loopback peer");
        assert_ne!(cid, 0);
        // The test owns `client`, `server` and `listener`.
        sys::close(client);
        sys::close(server);
        sys::close(listener);
    }
}
