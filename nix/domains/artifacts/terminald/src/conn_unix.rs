//! Connection sockets on Linux guests: checked wrappers over the accepted
//! `AF_VSOCK` descriptor. The session engine owns lifetimes; these calls only
//! translate results into `io::Result` so the engine is platform neutral.
use std::io;
use std::os::unix::io::RawFd;

/// An accepted vsock connection descriptor.
pub(crate) type Conn = RawFd;

/// One `read(2)`; `Ok(0)` is end of stream.
pub(crate) fn read(conn: Conn, buf: &mut [u8]) -> io::Result<usize> {
    // SAFETY: `buf` is a live exclusive slice, so read(2) may store up to
    // `buf.len()` bytes at its start.
    let read = unsafe { libc::read(conn, buf.as_mut_ptr().cast::<libc::c_void>(), buf.len()) };
    if read < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(read.cast_unsigned())
    }
}

/// One `write(2)`; a zero-byte write is reported as `WriteZero`.
pub(crate) fn write(conn: Conn, buf: &[u8]) -> io::Result<usize> {
    // SAFETY: `buf` is a live slice, so write(2) may read `buf.len()` bytes.
    let written = unsafe { libc::write(conn, buf.as_ptr().cast::<libc::c_void>(), buf.len()) };
    if written > 0 {
        return Ok(written.cast_unsigned());
    }
    if written == 0 {
        return Err(io::ErrorKind::WriteZero.into());
    }
    Err(io::Error::last_os_error())
}

/// Shut both directions down, waking any thread blocked on this socket.
pub(crate) fn shutdown(conn: Conn) {
    // SAFETY: shutdown(2) takes only a descriptor number and touches no
    // memory; a stale descriptor only makes it fail.
    unsafe { libc::shutdown(conn, libc::SHUT_RDWR) };
}

/// Release this descriptor.
pub(crate) fn close(conn: Conn) {
    // SAFETY: close(2) takes only a descriptor number and touches no memory;
    // the session engine closes each descriptor it owns exactly once.
    unsafe { libc::close(conn) };
}

/// A distinct close-on-exec descriptor for the same socket, so reader and
/// writer threads can close independently without reusing each other's number.
pub(crate) fn duplicate(conn: Conn) -> io::Result<Conn> {
    // SAFETY: F_DUPFD_CLOEXEC takes integer arguments only and touches no
    // memory.
    let copy = unsafe { libc::fcntl(conn, libc::F_DUPFD_CLOEXEC, 3) };
    if copy < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(copy)
    }
}

/// Configure a viewer's writer socket: a 5 s send timeout bounds each write so
/// the writer can observe peer departure while credit is withheld.
pub(crate) fn prepare_viewer(conn: Conn) -> io::Result<()> {
    let timeout = libc::timeval {
        tv_sec: 5,
        tv_usec: 0,
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a timeval is 16 bytes, far below socklen_t::MAX"
    )]
    let length = size_of_val(&timeout) as libc::socklen_t;
    // SAFETY: SO_SNDTIMEO reads one timeval of `length` bytes from `timeout`,
    // a live local of exactly that type and size.
    if unsafe {
        libc::setsockopt(
            conn,
            libc::SOL_SOCKET,
            libc::SO_SNDTIMEO,
            (&raw const timeout).cast::<libc::c_void>(),
            length,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Wait up to `millis` for send space.
pub(crate) fn wait_writable(conn: Conn, millis: i32) {
    let mut poller = libc::pollfd {
        fd: conn,
        events: libc::POLLOUT,
        revents: 0,
    };
    // SAFETY: poll(2) reads and updates exactly one pollfd (nfds = 1) at
    // `poller`, a live local.
    unsafe { libc::poll(&raw mut poller, 1, millis) };
}
