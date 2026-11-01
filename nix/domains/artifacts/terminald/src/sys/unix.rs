//! Descriptor, socket, signal and clock calls on Unix guests.
//!
//! Each wrapper makes exactly the libc call its caller made before, and returns
//! libc's raw result, so callers read `errno` (`io::Error::last_os_error`)
//! unchanged. Descriptor arguments are plain numbers: passing a descriptor the
//! caller does not own can at worst make the call fail or act on another open
//! file, never touch Rust memory; callers keep their ownership rules.
#[cfg(test)]
use std::ffi::CStr;
#[cfg(test)]
use std::io;
use std::os::fd::RawFd;
#[cfg(test)]
use std::os::fd::{FromRawFd, OwnedFd};

mod sealed {
    pub(crate) trait Sealed {}
}

/// A `#[repr(C)]` socket address made only of integer fields, so the kernel
/// may read or write all `size_of::<Self>()` bytes of it. Implemented here, for
/// the vsock address types only.
pub(crate) trait SocketAddress: sealed::Sealed + Copy {}

impl sealed::Sealed for crate::vsock::SockaddrVm {}
impl SocketAddress for crate::vsock::SockaddrVm {}

#[cfg(all(test, target_os = "linux"))]
impl sealed::Sealed for crate::native_vsock_layout_tests::SockaddrVm {}
#[cfg(all(test, target_os = "linux"))]
impl SocketAddress for crate::native_vsock_layout_tests::SockaddrVm {}

/// A plain-integer socket option value (`c_int` or `timeval`).
pub(crate) trait SocketOption: sealed::Sealed {}

impl sealed::Sealed for libc::c_int {}
impl SocketOption for libc::c_int {}
impl sealed::Sealed for libc::timeval {}
impl SocketOption for libc::timeval {}

#[expect(
    clippy::cast_possible_truncation,
    reason = "socket addresses and options are a few dozen bytes, far below socklen_t::MAX"
)]
const fn length_of<T>() -> libc::socklen_t {
    size_of::<T>() as libc::socklen_t
}

/// One `read(2)` into `buf`.
pub(crate) fn read(fd: RawFd, buf: &mut [u8]) -> isize {
    // SAFETY: `buf` is a live exclusive slice, so read(2) may store up to
    // `buf.len()` bytes at its start.
    unsafe { libc::read(fd, buf.as_mut_ptr().cast::<libc::c_void>(), buf.len()) }
}

/// One `read(2)` of a whole `c_int` into `value`.
pub(crate) fn read_c_int(fd: RawFd, value: &mut libc::c_int) -> isize {
    // SAFETY: read(2) stores at most size_of::<c_int>() bytes into `value`, a
    // live exclusive c_int.
    unsafe {
        libc::read(
            fd,
            std::ptr::from_mut(value).cast::<libc::c_void>(),
            size_of::<libc::c_int>(),
        )
    }
}

/// One `write(2)` of `buf`.
pub(crate) fn write(fd: RawFd, buf: &[u8]) -> isize {
    // SAFETY: `buf` is a live slice, so write(2) may read `buf.len()` bytes.
    unsafe { libc::write(fd, buf.as_ptr().cast::<libc::c_void>(), buf.len()) }
}

/// `shutdown(2)`.
pub(crate) fn shutdown(fd: RawFd, how: libc::c_int) -> libc::c_int {
    // SAFETY: shutdown(2) takes only integers and touches no memory; a stale
    // descriptor only makes it fail.
    unsafe { libc::shutdown(fd, how) }
}

/// `close(2)`. Callers close each descriptor they own exactly once.
pub(crate) fn close(fd: RawFd) -> libc::c_int {
    // SAFETY: close(2) takes only a descriptor number and touches no memory.
    unsafe { libc::close(fd) }
}

/// `fcntl(fd, F_DUPFD_CLOEXEC, minimum)`.
pub(crate) fn duplicate_cloexec(fd: RawFd, minimum: libc::c_int) -> libc::c_int {
    // SAFETY: F_DUPFD_CLOEXEC takes integer arguments only and touches no
    // memory.
    unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, minimum) }
}

/// `fcntl(fd, F_DUPFD, minimum)`, owned: an inheritable duplicate at or above
/// `minimum`.
#[cfg(test)]
pub(crate) fn duplicate_inheritable(fd: RawFd, minimum: libc::c_int) -> io::Result<OwnedFd> {
    // SAFETY: F_DUPFD takes integer arguments only and touches no memory.
    let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD, minimum) };
    if copy < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `copy` is a fresh duplicate that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(copy) })
}

/// `fcntl(fd, F_GETFD)`: the descriptor flags.
#[cfg(test)]
pub(crate) fn descriptor_flags(fd: RawFd) -> libc::c_int {
    // SAFETY: F_GETFD reads descriptor flags only and touches no memory.
    unsafe { libc::fcntl(fd, libc::F_GETFD) }
}

/// `open(2)` of `path`, owned.
#[cfg(test)]
pub(crate) fn open(path: &CStr, flags: libc::c_int) -> io::Result<OwnedFd> {
    // SAFETY: `path` is NUL-terminated and outlives the call.
    let fd = unsafe { libc::open(path.as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` is a freshly opened descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// `flock(2)`.
#[cfg(feature = "antithesis-observer")]
pub(crate) fn flock(fd: RawFd, operation: libc::c_int) -> libc::c_int {
    // SAFETY: flock(2) takes only integers and touches no memory.
    unsafe { libc::flock(fd, operation) }
}

/// `poll(2)` on exactly one descriptor.
pub(crate) fn poll_one(poller: &mut libc::pollfd, millis: libc::c_int) -> libc::c_int {
    // SAFETY: poll(2) reads and updates exactly one pollfd (nfds = 1) at
    // `poller`, a live exclusive reference.
    unsafe { libc::poll(std::ptr::from_mut(poller), 1, millis) }
}

/// `setsockopt(2)` with one plain-integer option value.
pub(crate) fn setsockopt<T: SocketOption>(
    fd: RawFd,
    level: libc::c_int,
    name: libc::c_int,
    value: &T,
) -> libc::c_int {
    // SAFETY: setsockopt(2) reads `size_of::<T>()` bytes from `value`, a live
    // integer-only option of exactly that size.
    unsafe {
        libc::setsockopt(
            fd,
            level,
            name,
            std::ptr::from_ref(value).cast::<libc::c_void>(),
            length_of::<T>(),
        )
    }
}

/// `socket(2)`.
pub(crate) fn socket(domain: libc::c_int, kind: libc::c_int, protocol: libc::c_int) -> libc::c_int {
    // SAFETY: socket(2) takes integer arguments only and touches no memory.
    unsafe { libc::socket(domain, kind, protocol) }
}

/// `bind(2)` to `address`, passed with its exact size.
pub(crate) fn bind<A: SocketAddress>(fd: RawFd, address: &A) -> libc::c_int {
    // SAFETY: bind(2) reads `size_of::<A>()` bytes from `address`, a live
    // repr(C) socket address of exactly that size.
    unsafe {
        libc::bind(
            fd,
            std::ptr::from_ref(address).cast::<libc::sockaddr>(),
            length_of::<A>(),
        )
    }
}

/// `connect(2)` to `address`, passed with its exact size.
#[cfg(test)]
pub(crate) fn connect<A: SocketAddress>(fd: RawFd, address: &A) -> libc::c_int {
    // SAFETY: connect(2) reads `size_of::<A>()` bytes from `address`, a live
    // repr(C) socket address of exactly that size.
    unsafe {
        libc::connect(
            fd,
            std::ptr::from_ref(address).cast::<libc::sockaddr>(),
            length_of::<A>(),
        )
    }
}

/// `listen(2)`.
pub(crate) fn listen(fd: RawFd, backlog: libc::c_int) -> libc::c_int {
    // SAFETY: listen(2) takes integer arguments only and touches no memory.
    unsafe { libc::listen(fd, backlog) }
}

/// `accept4(2)`, storing the peer in `peer`: the new descriptor (or -1) and the
/// address length the kernel reported.
pub(crate) fn accept4<A: SocketAddress>(
    listener: RawFd,
    peer: &mut A,
    flags: libc::c_int,
) -> (libc::c_int, libc::socklen_t) {
    let mut length = length_of::<A>();
    // SAFETY: accept4(2) writes at most `length` bytes to `peer`, a live
    // exclusive repr(C) address of exactly that size, and updates `length`, a
    // live local.
    let fd = unsafe {
        libc::accept4(
            listener,
            std::ptr::from_mut(peer).cast::<libc::sockaddr>(),
            &raw mut length,
            flags,
        )
    };
    (fd, length)
}

/// `getsockname(2)` into `address`: the status and the reported length.
#[cfg(test)]
pub(crate) fn getsockname<A: SocketAddress>(
    fd: RawFd,
    address: &mut A,
) -> (libc::c_int, libc::socklen_t) {
    let mut length = length_of::<A>();
    // SAFETY: getsockname(2) writes at most `length` bytes to `address`, a live
    // exclusive repr(C) address of exactly that size, and updates `length`, a
    // live local.
    let status = unsafe {
        libc::getsockname(
            fd,
            std::ptr::from_mut(address).cast::<libc::sockaddr>(),
            &raw mut length,
        )
    };
    (status, length)
}

/// `kill(2)`. Callers signal only process (group) IDs whose leader they have
/// not reaped yet, so the ID cannot have been reused.
pub(crate) fn kill(pid: libc::pid_t, signal: libc::c_int) -> libc::c_int {
    // SAFETY: kill(2) takes integers only and touches no memory.
    unsafe { libc::kill(pid, signal) }
}

/// `waitpid(2)`, storing the status in `status` when one is given.
pub(crate) fn waitpid(
    pid: libc::pid_t,
    status: Option<&mut libc::c_int>,
    options: libc::c_int,
) -> libc::pid_t {
    let pointer = status.map_or(std::ptr::null_mut(), std::ptr::from_mut);
    // SAFETY: waitpid(2) writes one int through `pointer`, which is null or a
    // live exclusive c_int.
    unsafe { libc::waitpid(pid, pointer, options) }
}

/// `getpgid(2)`.
#[cfg(test)]
pub(crate) fn getpgid(pid: libc::pid_t) -> libc::pid_t {
    // SAFETY: getpgid takes an integer and touches no memory.
    unsafe { libc::getpgid(pid) }
}

/// `geteuid(2)`.
#[cfg(test)]
pub(crate) fn geteuid() -> libc::uid_t {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

/// `clock_gettime(2)` into `time`.
pub(crate) fn clock_gettime(clock: libc::clockid_t, time: &mut libc::timespec) -> libc::c_int {
    // SAFETY: clock_gettime(2) writes one timespec to `time`, a live exclusive
    // reference.
    unsafe { libc::clock_gettime(clock, std::ptr::from_mut(time)) }
}

/// `ioctl(fd, TIOCSWINSZ, size)`.
pub(crate) fn set_winsize(fd: RawFd, size: &libc::winsize) -> libc::c_int {
    // SAFETY: TIOCSWINSZ reads one winsize from `size`, a live reference.
    unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, std::ptr::from_ref(size)) }
}

/// `ioctl(fd, TIOCGWINSZ, size)`.
#[cfg(test)]
pub(crate) fn get_winsize(fd: RawFd, size: &mut libc::winsize) -> libc::c_int {
    // SAFETY: TIOCGWINSZ writes one winsize to `size`, a live exclusive
    // reference.
    unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, std::ptr::from_mut(size)) }
}
