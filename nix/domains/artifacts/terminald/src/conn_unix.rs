//! Connection sockets on Linux guests: checked wrappers over the accepted
//! `AF_VSOCK` descriptor. The session engine owns lifetimes; these calls only
//! translate results into `io::Result` so the engine is platform neutral.
use crate::sys::unix as sys;
use std::io;
use std::os::unix::io::RawFd;

/// An accepted vsock connection descriptor.
pub(crate) type Conn = RawFd;

/// One `read(2)`; `Ok(0)` is end of stream.
pub(crate) fn read(conn: Conn, buf: &mut [u8]) -> io::Result<usize> {
    let read = sys::read(conn, buf);
    if read < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(read.cast_unsigned())
    }
}

/// One `write(2)`; a zero-byte write is reported as `WriteZero`.
pub(crate) fn write(conn: Conn, buf: &[u8]) -> io::Result<usize> {
    let written = sys::write(conn, buf);
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
    sys::shutdown(conn, libc::SHUT_RDWR);
}

/// Release this descriptor.
pub(crate) fn close(conn: Conn) {
    // The session engine closes each descriptor it owns exactly once.
    sys::close(conn);
}

/// A distinct close-on-exec descriptor for the same socket, so reader and
/// writer threads can close independently without reusing each other's number.
pub(crate) fn duplicate(conn: Conn) -> io::Result<Conn> {
    let copy = sys::duplicate_cloexec(conn, 3);
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
    if sys::setsockopt(conn, libc::SOL_SOCKET, libc::SO_SNDTIMEO, &timeout) != 0 {
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
    sys::poll_one(&mut poller, millis);
}
