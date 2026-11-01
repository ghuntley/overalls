//! BSD socket shims over owned descriptors, with fixed-layout vsock addresses.
//!
//! Address arguments are restricted to the sealed [`SocketAddress`] types
//! below, so every length passed to the kernel is the exact size of a live,
//! fully initialised `repr(C)` value.

use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};

mod sealed {
    pub trait Sealed {}
}

/// A fixed-layout socket address the kernel may read or fill in place.
pub trait SocketAddress: Copy + sealed::Sealed {}

/// The reviewed 16-byte custom-kernel `sockaddr_vm` with the BSD length and
/// family bytes (ADR-0190).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[cfg(any(target_os = "freebsd", test))]
pub struct BsdSockaddrVm {
    pub length: u8,
    pub family: u8,
    pub reserved: u16,
    pub port: u32,
    pub cid: u32,
    pub zero: [u8; 4],
}
#[cfg(any(target_os = "freebsd", test))]
impl sealed::Sealed for BsdSockaddrVm {}
#[cfg(any(target_os = "freebsd", test))]
impl SocketAddress for BsdSockaddrVm {}

/// The proposed flat 16-byte illumos `sockaddr_vm` layout (ADR-0190).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[cfg(any(not(target_os = "freebsd"), test))]
pub struct FlatSockaddrVm {
    pub family: u16,
    pub reserved: u16,
    pub port: u32,
    pub cid: u32,
    pub zero: [u8; 4],
}
#[cfg(any(not(target_os = "freebsd"), test))]
impl sealed::Sealed for FlatSockaddrVm {}
#[cfg(any(not(target_os = "freebsd"), test))]
impl SocketAddress for FlatSockaddrVm {}

/// The native 16-byte vsock address as raw header bytes, for the machine
/// probe's deliberately malformed and foreign-CID addresses.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
pub struct RawSockaddrVm {
    pub header: [u8; 4],
    pub port: u32,
    pub cid: u32,
    pub zero: [u8; 4],
}
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
impl sealed::Sealed for RawSockaddrVm {}
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
impl SocketAddress for RawSockaddrVm {}

#[cfg(target_os = "linux")]
impl sealed::Sealed for libc::sockaddr_vm {}
#[cfg(target_os = "linux")]
impl SocketAddress for libc::sockaddr_vm {}

/// The kernel length of an address or option value of type `T`.
#[expect(
    clippy::cast_possible_truncation,
    reason = "socket addresses and option values are a few bytes, far below socklen_t::MAX"
)]
const fn length_of<T>() -> libc::socklen_t {
    size_of::<T>() as libc::socklen_t
}

fn check(result: libc::c_int) -> io::Result<()> {
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Create a socket; the returned descriptor is owned and closed on drop.
pub fn socket(
    domain: libc::c_int,
    kind: libc::c_int,
    protocol: libc::c_int,
) -> io::Result<OwnedFd> {
    // SAFETY: socket takes only integer arguments and returns a new descriptor
    // or -1; no memory is shared with the kernel.
    let fd = unsafe { libc::socket(domain, kind, protocol) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: socket just returned this descriptor and nothing else owns it.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Set `FD_CLOEXEC` on the descriptor.
pub fn set_close_on_exec(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: fcntl F_SETFD takes an integer flag; the borrow keeps fd open.
    check(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) })
}

/// Bind the socket to `address`, passed with its exact size.
pub fn bind<A: SocketAddress>(fd: BorrowedFd<'_>, address: &A) -> io::Result<()> {
    // SAFETY: `address` is a live, initialised fixed-layout socket address of
    // exactly the length passed; the kernel only reads it.
    check(unsafe {
        libc::bind(
            fd.as_raw_fd(),
            (&raw const *address).cast(),
            length_of::<A>(),
        )
    })
}

/// Connect the socket to `address`, passed with its exact size.
pub fn connect<A: SocketAddress>(fd: BorrowedFd<'_>, address: &A) -> io::Result<()> {
    // SAFETY: as for bind; the kernel only reads the address.
    check(unsafe {
        libc::connect(
            fd.as_raw_fd(),
            (&raw const *address).cast(),
            length_of::<A>(),
        )
    })
}

/// Mark the socket as listening with `backlog`.
pub fn listen(fd: BorrowedFd<'_>, backlog: libc::c_int) -> io::Result<()> {
    // SAFETY: listen takes only integer arguments; the borrow keeps fd open.
    check(unsafe { libc::listen(fd.as_raw_fd(), backlog) })
}

/// Accept one connection, storing its peer in `peer`. Returns the owned
/// connection and the address length the kernel reported.
pub fn accept<A: SocketAddress>(
    fd: BorrowedFd<'_>,
    peer: &mut A,
) -> io::Result<(OwnedFd, libc::socklen_t)> {
    let mut length = length_of::<A>();
    // SAFETY: `peer` is writable for `length` bytes, every bit pattern the
    // kernel can store is a valid value of the plain-integer address type, and
    // `length` is writable; both live across the call.
    let connection =
        unsafe { libc::accept(fd.as_raw_fd(), (&raw mut *peer).cast(), &raw mut length) };
    if connection < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: accept just returned this descriptor and nothing else owns it.
    Ok((unsafe { OwnedFd::from_raw_fd(connection) }, length))
}

/// `accept4` with `SOCK_CLOEXEC`, storing the peer in `peer`.
#[cfg(target_os = "linux")]
pub fn accept_close_on_exec<A: SocketAddress>(
    fd: BorrowedFd<'_>,
    peer: &mut A,
) -> io::Result<OwnedFd> {
    let mut length = length_of::<A>();
    // SAFETY: as for accept: `peer` and `length` are live, writable and
    // correctly sized for the address accept4 stores.
    let connection = unsafe {
        libc::accept4(
            fd.as_raw_fd(),
            (&raw mut *peer).cast(),
            &raw mut length,
            libc::SOCK_CLOEXEC,
        )
    };
    if connection < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: accept4 just returned this descriptor and nothing else owns it.
    Ok(unsafe { OwnedFd::from_raw_fd(connection) })
}

/// Set a `SOL_SOCKET` time option (`SO_RCVTIMEO`, `SO_SNDTIMEO`).
pub fn set_time_option(
    fd: BorrowedFd<'_>,
    option: libc::c_int,
    value: &libc::timeval,
) -> io::Result<()> {
    // SAFETY: `value` is an initialised timeval that outlives the call and the
    // length passed is its exact size; the kernel only reads it.
    check(unsafe {
        libc::setsockopt(
            fd.as_raw_fd(),
            libc::SOL_SOCKET,
            option,
            (&raw const *value).cast(),
            length_of::<libc::timeval>(),
        )
    })
}

/// Set an integer socket option.
pub fn set_int_option(
    fd: BorrowedFd<'_>,
    level: libc::c_int,
    option: libc::c_int,
    value: libc::c_int,
) -> io::Result<()> {
    // SAFETY: `value` is a live c_int passed with its exact size; read only.
    check(unsafe {
        libc::setsockopt(
            fd.as_raw_fd(),
            level,
            option,
            (&raw const value).cast(),
            length_of::<libc::c_int>(),
        )
    })
}

/// Read an integer socket option; returns its value and reported length.
pub fn int_option(
    fd: BorrowedFd<'_>,
    level: libc::c_int,
    option: libc::c_int,
) -> io::Result<(libc::c_int, libc::socklen_t)> {
    let mut value: libc::c_int = 0;
    let mut length = length_of::<libc::c_int>();
    // SAFETY: value and length are writable native integer outputs of the
    // declared size, live across the call.
    check(unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            level,
            option,
            (&raw mut value).cast(),
            &raw mut length,
        )
    })?;
    Ok((value, length))
}

/// Set a byte-string socket option to exactly `value`.
pub fn set_bytes_option(
    fd: BorrowedFd<'_>,
    level: libc::c_int,
    option: libc::c_int,
    value: &[u8],
) -> io::Result<()> {
    let length = libc::socklen_t::try_from(value.len())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: `value` is readable for `length` bytes during the call.
    check(unsafe { libc::setsockopt(fd.as_raw_fd(), level, option, value.as_ptr().cast(), length) })
}

/// Read a byte-string socket option into `buffer`, offering its whole length.
/// Returns the length the kernel reported.
pub fn bytes_option(
    fd: BorrowedFd<'_>,
    level: libc::c_int,
    option: libc::c_int,
    buffer: &mut [u8],
) -> io::Result<libc::socklen_t> {
    let mut length = libc::socklen_t::try_from(buffer.len())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: `buffer` is writable for `length` bytes and `length` is writable,
    // both live across the synchronous call.
    check(unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            level,
            option,
            buffer.as_mut_ptr().cast(),
            &raw mut length,
        )
    })?;
    Ok(length)
}
