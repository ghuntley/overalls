//! Portable `AF_VSOCK` transport for the firmware guest agents.
//!
//! Stock FreeBSD and illumos kernels do not implement this transport. This
//! adapter describes ADR-0190's reviewed custom kernel socket ABI; compiling
//! it does not establish native kernel or Firecracker transport support.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};

/// This custom ABI uses FreeBSD's vendor slot 45 (`AF_VENDOR03`).
#[cfg(target_os = "freebsd")]
pub const AF_VSOCK: libc::c_int = 45;
/// Proposed illumos family; runtime remains unavailable pending kernel evidence.
#[cfg(not(target_os = "freebsd"))]
pub const AF_VSOCK: libc::c_int = 40;
/// Firecracker's host CID.
pub const HOST_CID: u32 = 2;
/// The CID assigned to a guest by Lilly's launch contract.
pub const GUEST_CID: u32 = 3;
/// Bind a listener on any local CID.
pub const CID_ANY: u32 = u32::MAX;
const SOCKADDR_VM_SIZE: usize = 16;
#[expect(
    clippy::cast_possible_truncation,
    reason = "the 16-byte address length fits u8"
)]
#[cfg(any(target_os = "freebsd", test))]
const SOCKADDR_VM_LEN_U8: u8 = SOCKADDR_VM_SIZE as u8;
#[expect(
    clippy::cast_possible_truncation,
    reason = "the 16-byte address length fits socklen_t"
)]
const SOCKADDR_VM_SOCKLEN: libc::socklen_t = SOCKADDR_VM_SIZE as libc::socklen_t;
const VSOCK_SO_BUILD_ID: libc::c_int = 1;
const BUILD_ID_BYTES: usize = 65;
#[expect(
    clippy::cast_possible_truncation,
    reason = "the 65-byte identity length fits socklen_t"
)]
const BUILD_ID_SOCKLEN: libc::socklen_t = BUILD_ID_BYTES as libc::socklen_t;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[cfg(any(target_os = "freebsd", test))]
struct BsdSockaddrVm {
    length: u8,
    family: u8,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[cfg(any(not(target_os = "freebsd"), test))]
struct FlatSockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

trait VmAddress: Default {
    fn any(port: u32) -> Self;
    fn host_peer(&self) -> bool;
    fn peer_cid(&self) -> u32;
}

#[cfg(any(target_os = "freebsd", test))]
impl VmAddress for BsdSockaddrVm {
    fn any(port: u32) -> Self {
        Self {
            length: SOCKADDR_VM_LEN_U8,
            family: 45,
            port,
            cid: CID_ANY,
            ..Self::default()
        }
    }
    fn host_peer(&self) -> bool {
        self.length == SOCKADDR_VM_LEN_U8 && self.family == 45 && self.cid == HOST_CID
    }
    fn peer_cid(&self) -> u32 {
        self.cid
    }
}

#[cfg(any(not(target_os = "freebsd"), test))]
impl VmAddress for FlatSockaddrVm {
    fn any(port: u32) -> Self {
        Self {
            family: 40,
            port,
            cid: CID_ANY,
            ..Self::default()
        }
    }
    fn host_peer(&self) -> bool {
        self.family == 40 && self.cid == HOST_CID
    }
    fn peer_cid(&self) -> u32 {
        self.cid
    }
}

#[cfg(target_os = "freebsd")]
type SockaddrVm = BsdSockaddrVm;
#[cfg(not(target_os = "freebsd"))]
type SockaddrVm = FlatSockaddrVm;

/// A host-only listener.  [`Listener::accept`] closes a connection before
/// returning an error when its family or peer CID is not trusted.
#[derive(Debug)]
pub struct Listener {
    fd: RawFd,
}

/// A bounded native-vsock connection with the observed peer CID.
#[derive(Debug)]
pub struct Connection {
    file: File,
    pub peer_cid: u32,
}

impl Read for Connection {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.file.read(bytes)
    }
}

impl Write for Connection {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.file.write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Listener {
    /// @cc [owner:ghuntley,label:security;verification] native-running-transport-identity
    /// The read-only kernel identity MUST be exactly 64 lower-case hexadecimal
    /// bytes followed by NUL. Missing, truncated, oversized or malformed kernel
    /// output MUST refuse; a userspace environment variable cannot supply it.
    pub fn kernel_build_id(&self) -> io::Result<String> {
        let mut bytes = [0_u8; BUILD_ID_BYTES];
        let mut length = BUILD_ID_SOCKLEN;
        // SAFETY: the listener owns fd; bytes and length are writable for this
        // synchronous custom-kernel getsockopt call.
        if unsafe {
            libc::getsockopt(
                self.fd,
                AF_VSOCK,
                VSOCK_SO_BUILD_ID,
                bytes.as_mut_ptr().cast(),
                &raw mut length,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        if length != BUILD_ID_SOCKLEN {
            return Err(io::Error::other("invalid kernel build identity length"));
        }
        decode_build_id(&bytes)
    }

    /// @cc [owner:ghuntley,label:security;protocol] native-proposed-vsock-abi
    /// Binding MUST use ADR-0190's reviewed 16-byte custom-kernel ABI with socket
    /// family 45 and BSD length/family bytes on FreeBSD, or the proposed
    /// flat illumos layout. Its use assumes the patched kernel assigns guest
    /// CID 3; successful compilation MUST NOT establish that runtime evidence.
    pub fn bind(port: u32, backlog: libc::c_int) -> io::Result<Self> {
        // SAFETY: all arguments are fixed ABI constants; ownership transfers
        // to this listener when socket succeeds.
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        set_close_on_exec(fd)?;
        let address = SockaddrVm::any(port);
        // SAFETY: address is a live 16-byte sockaddr_vm for this call.
        let bound =
            unsafe { libc::bind(fd, (&raw const address).cast(), SOCKADDR_VM_SOCKLEN) } == 0;
        // SAFETY: fd is valid and owned by this setup path.
        let listening = bound && unsafe { libc::listen(fd, backlog) } == 0;
        if !listening {
            let error = io::Error::last_os_error();
            // SAFETY: fd is closed exactly once on setup failure.
            unsafe { libc::close(fd) };
            return Err(error);
        }
        Ok(Self { fd })
    }

    /// Accept one peer, requiring `AF_VSOCK` and the host CID before exposing
    /// the stream to a protocol parser.
    pub fn accept(&self) -> io::Result<Connection> {
        let mut peer = SockaddrVm::default();
        let mut length = SOCKADDR_VM_SOCKLEN;
        // SAFETY: peer and length are writable buffers valid for this call.
        let fd = unsafe { libc::accept(self.fd, (&raw mut peer).cast(), &raw mut length) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        set_close_on_exec(fd)?;
        // SAFETY: fd is newly accepted and owned by the returned connection.
        let file = unsafe { File::from_raw_fd(fd) };
        if length != SOCKADDR_VM_SOCKLEN || !peer.host_peer() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "non-host vsock peer",
            ));
        }
        set_timeouts(fd)?;
        Ok(Connection {
            file,
            peer_cid: peer.peer_cid(),
        })
    }
}

fn decode_build_id(bytes: &[u8]) -> io::Result<String> {
    if bytes.len() != BUILD_ID_BYTES
        || bytes[64] != 0
        || !bytes[..64]
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Err(io::Error::other("invalid kernel build identity"));
    }
    String::from_utf8(bytes[..64].to_vec())
        .map_err(|_| io::Error::other("invalid kernel build identity"))
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: fd is owned by this listener and closed once.
        unsafe { libc::close(self.fd) };
    }
}

fn set_close_on_exec(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl operates on the descriptor just returned by the kernel.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: fd remains owned by this setup path.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(())
}

fn set_timeouts(fd: RawFd) -> io::Result<()> {
    let timeout = libc::timeval {
        tv_sec: 5,
        tv_usec: 0,
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "timeval is 16 bytes, far below socklen_t::MAX"
    )]
    let timeout_length = size_of_val(&timeout) as libc::socklen_t;
    for option in [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO] {
        // SAFETY: timeout remains live for the synchronous setsockopt call.
        if unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                option,
                (&raw const timeout).cast(),
                timeout_length,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_build_identity_requires_exact_kernel_abi() {
        let mut bytes = [b'a'; BUILD_ID_BYTES];
        bytes[64] = 0;
        assert_eq!(decode_build_id(&bytes).unwrap(), "a".repeat(64));
        assert!(decode_build_id(&bytes[..64]).is_err());
        bytes[64] = b'\n';
        assert!(decode_build_id(&bytes).is_err());
        bytes[64] = 0;
        bytes[17] = b'A';
        assert!(decode_build_id(&bytes).is_err());
        bytes[17] = 0;
        assert!(decode_build_id(&bytes).is_err());
    }

    #[test]
    fn constants_match_guest_launch_contract() {
        assert_eq!(AF_VSOCK, if cfg!(target_os = "freebsd") { 45 } else { 40 });
        assert_eq!(HOST_CID, 2);
        assert_eq!(GUEST_CID, 3);
        assert_eq!(size_of::<SockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(SockaddrVm::any(1024).peer_cid(), CID_ANY);
        assert_eq!(size_of::<BsdSockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(size_of::<FlatSockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(std::mem::offset_of!(BsdSockaddrVm, family), 1);
        assert_eq!(std::mem::offset_of!(BsdSockaddrVm, port), 4);
        assert_eq!(std::mem::offset_of!(FlatSockaddrVm, port), 4);
        let mut bsd = BsdSockaddrVm::any(1024);
        assert_eq!(bsd.length, 16);
        assert_eq!(bsd.family, 45);
        assert!(!bsd.host_peer());
        bsd.cid = HOST_CID;
        assert!(bsd.host_peer());
        bsd.length = 0;
        assert!(!bsd.host_peer());
        let mut flat = FlatSockaddrVm::any(1024);
        flat.cid = HOST_CID;
        assert!(flat.host_peer());
        flat.family = 45;
        assert!(!flat.host_peer());
    }
}
