//! AF_VSOCK listener and peer-CID verification via libc.
use std::io;
use std::os::unix::io::RawFd;

pub const AF_VSOCK: i32 = 40;
pub const CID_ANY: u32 = 0xffff_ffff;
pub const CID_HOST: u32 = 2;
#[cfg(test)]
pub const CID_LOCAL: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

impl SockaddrVm {
    fn new(cid: u32, port: u32) -> Self {
        SockaddrVm {
            family: AF_VSOCK as u16,
            reserved: 0,
            port,
            cid,
            zero: [0; 4],
        }
    }
}

#[cfg(test)]
pub fn address(cid: u32, port: u32) -> SockaddrVm {
    SockaddrVm::new(cid, port)
}

#[cfg(test)]
pub fn bound_port(listener: RawFd) -> io::Result<u32> {
    let mut bound = SockaddrVm::new(0, 0);
    let mut length = std::mem::size_of::<SockaddrVm>() as u32;
    let status = unsafe {
        libc::getsockname(
            listener,
            &mut bound as *mut SockaddrVm as *mut libc::sockaddr,
            &mut length,
        )
    };
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(bound.port)
}

#[cfg(test)]
pub fn available() -> bool {
    let Ok(fd) = listen(0) else {
        return false;
    };
    unsafe { libc::close(fd) };
    true
}

/// The listening vsock descriptor.
pub type Listener = RawFd;

pub fn listen(port: u32) -> io::Result<Listener> {
    let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let one: libc::c_int = 1;
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_REUSEADDR,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as u32,
        )
    };
    let address = SockaddrVm::new(CID_ANY, port);
    let result = unsafe {
        libc::bind(
            fd,
            &address as *const SockaddrVm as *const libc::sockaddr,
            std::mem::size_of::<SockaddrVm>() as u32,
        )
    };
    if result < 0 {
        let error = io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(error);
    }
    if unsafe { libc::listen(fd, 64) } < 0 {
        let error = io::Error::last_os_error();
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

/// @cc [owner:ghuntley,label:security] vsock-host-peer-only
/// `accept` MUST return the peer CID observed by the kernel; the caller MUST
/// reject any peer other than the host CID before reading requests.
pub fn accept(listener: RawFd) -> io::Result<(RawFd, u32, u32)> {
    let mut peer = SockaddrVm::new(0, 0);
    let mut length = std::mem::size_of::<SockaddrVm>() as u32;
    let fd = unsafe {
        libc::accept4(
            listener,
            &mut peer as *mut SockaddrVm as *mut libc::sockaddr,
            &mut length,
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
    #[allow(clippy::print_stderr)]
    fn loopback_connection_observes_peer_cids() {
        if !available() {
            eprintln!("skipping: AF_VSOCK unavailable in this environment");
            return;
        }
        let listener = listen(0).expect("bind ephemeral vsock port");
        let mut bound = SockaddrVm::new(0, 0);
        let mut length = std::mem::size_of::<SockaddrVm>() as u32;
        assert_eq!(
            unsafe {
                libc::getsockname(
                    listener,
                    &mut bound as *mut SockaddrVm as *mut libc::sockaddr,
                    &mut length,
                )
            },
            0
        );
        let client = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
        assert!(client >= 0);
        let local = SockaddrVm::new(CID_LOCAL, bound.port);
        let connected = unsafe {
            libc::connect(
                client,
                &local as *const SockaddrVm as *const libc::sockaddr,
                std::mem::size_of::<SockaddrVm>() as u32,
            )
        };
        if connected < 0 {
            eprintln!("skipping: vsock local loopback connect failed");
            unsafe { libc::close(client) };
            unsafe { libc::close(listener) };
            return;
        }
        let (server, cid, _port) = accept(listener).expect("accept loopback peer");
        assert_ne!(cid, 0);
        unsafe { libc::close(client) };
        unsafe { libc::close(server) };
        unsafe { libc::close(listener) };
    }
}
