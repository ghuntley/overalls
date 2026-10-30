//! `AF_VSOCK` listener and peer-CID verification via libc.
use std::io;
use std::os::unix::io::RawFd;

pub(crate) const AF_VSOCK: i32 = 40;
pub(crate) const CID_ANY: u32 = 0xffff_ffff;
pub(crate) const CID_HOST: u32 = 2;
#[cfg(test)]
pub(crate) const CID_LOCAL: u32 = 1;

/// `size_of::<SockaddrVm>()` as a socket address length.
#[expect(
    clippy::cast_possible_truncation,
    reason = "sockaddr_vm is 16 bytes, far below u32::MAX"
)]
const SOCKADDR_VM_LEN: u32 = size_of::<SockaddrVm>() as u32;

/// `size_of::<c_int>()` as a socket option length.
#[expect(
    clippy::cast_possible_truncation,
    reason = "c_int is 4 bytes, far below u32::MAX"
)]
const C_INT_LEN: u32 = size_of::<libc::c_int>() as u32;

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
    let mut length = SOCKADDR_VM_LEN;
    // SAFETY: getsockname(2) writes at most `length` bytes to `bound`, a live
    // sockaddr_vm of exactly that size, and updates `length`, a live local.
    let status = unsafe {
        libc::getsockname(
            listener,
            (&raw mut bound).cast::<libc::sockaddr>(),
            &raw mut length,
        )
    };
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
    // SAFETY: close(2) touches no memory; `fd` is the probe listener this
    // function owns and never uses again.
    unsafe { libc::close(fd) };
    true
}

/// The listening vsock descriptor.
pub(crate) type Listener = RawFd;

pub(crate) fn listen(port: u32) -> io::Result<Listener> {
    // SAFETY: socket(2) takes integer arguments only and touches no memory.
    let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let one: libc::c_int = 1;
    // SAFETY: SO_REUSEADDR reads one c_int of `C_INT_LEN` bytes from `one`, a
    // live local of exactly that type.
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_REUSEADDR,
            (&raw const one).cast::<libc::c_void>(),
            C_INT_LEN,
        )
    };
    let address = SockaddrVm::new(CID_ANY, port);
    // SAFETY: bind(2) reads `SOCKADDR_VM_LEN` bytes from `address`, a live
    // repr(C) sockaddr_vm of exactly that size.
    let result = unsafe {
        libc::bind(
            fd,
            (&raw const address).cast::<libc::sockaddr>(),
            SOCKADDR_VM_LEN,
        )
    };
    if result < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: close(2) touches no memory; this function owns `fd`, which
        // is never returned on this path.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    // SAFETY: listen(2) takes integer arguments only and touches no memory.
    if unsafe { libc::listen(fd, 64) } < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: close(2) touches no memory; this function owns `fd`, which
        // is never returned on this path.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

/// @cc [owner:ghuntley,label:security] vsock-host-peer-only
/// `accept` MUST return the peer CID observed by the kernel; the caller MUST
/// reject any peer other than the host CID before reading requests.
pub(crate) fn accept(listener: RawFd) -> io::Result<(RawFd, u32, u32)> {
    let mut peer = SockaddrVm::new(0, 0);
    let mut length = SOCKADDR_VM_LEN;
    // SAFETY: accept4(2) writes at most `length` bytes to `peer`, a live
    // repr(C) sockaddr_vm of exactly that size, and updates `length`.
    let fd = unsafe {
        libc::accept4(
            listener,
            (&raw mut peer).cast::<libc::sockaddr>(),
            &raw mut length,
            libc::SOCK_CLOEXEC,
        )
    };
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
        let mut length = SOCKADDR_VM_LEN;
        assert_eq!(
            // SAFETY: getsockname(2) writes at most `length` bytes to `bound`,
            // a live sockaddr_vm of exactly that size, and updates `length`.
            unsafe {
                libc::getsockname(
                    listener,
                    (&raw mut bound).cast::<libc::sockaddr>(),
                    &raw mut length,
                )
            },
            0
        );
        // SAFETY: socket(2) takes integer arguments only and touches no memory.
        let client = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
        assert!(client >= 0);
        let local = SockaddrVm::new(CID_LOCAL, bound.port);
        // SAFETY: connect(2) reads `SOCKADDR_VM_LEN` bytes from `local`, a live
        // repr(C) sockaddr_vm of exactly that size.
        let connected = unsafe {
            libc::connect(
                client,
                (&raw const local).cast::<libc::sockaddr>(),
                SOCKADDR_VM_LEN,
            )
        };
        if connected < 0 {
            eprintln!("skipping: vsock local loopback connect failed");
            // SAFETY: close(2) touches no memory; the test owns `client`.
            unsafe { libc::close(client) };
            // SAFETY: close(2) touches no memory; the test owns `listener`.
            unsafe { libc::close(listener) };
            return;
        }
        let (server, cid, _port) = accept(listener).expect("accept loopback peer");
        assert_ne!(cid, 0);
        // SAFETY: close(2) touches no memory; the test owns `client`.
        unsafe { libc::close(client) };
        // SAFETY: close(2) touches no memory; the test owns `server`.
        unsafe { libc::close(server) };
        // SAFETY: close(2) touches no memory; the test owns `listener`.
        unsafe { libc::close(listener) };
    }
}
