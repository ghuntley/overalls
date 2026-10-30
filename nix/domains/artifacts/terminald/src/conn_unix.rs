//! Connection sockets on Linux guests: checked wrappers over the accepted
//! AF_VSOCK descriptor. The session engine owns lifetimes; these calls only
//! translate results into `io::Result` so the engine is platform neutral.
use std::io;
use std::os::unix::io::RawFd;

/// An accepted vsock connection descriptor.
pub type Conn = RawFd;

/// One `read(2)`; `Ok(0)` is end of stream.
pub fn read(conn: Conn, buf: &mut [u8]) -> io::Result<usize> {
    let read = unsafe { libc::read(conn, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
    if read < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(read as usize)
    }
}

/// One `write(2)`; a zero-byte write is reported as `WriteZero`.
pub fn write(conn: Conn, buf: &[u8]) -> io::Result<usize> {
    let written = unsafe { libc::write(conn, buf.as_ptr() as *const libc::c_void, buf.len()) };
    if written > 0 {
        return Ok(written as usize);
    }
    if written == 0 {
        return Err(io::ErrorKind::WriteZero.into());
    }
    Err(io::Error::last_os_error())
}

/// Shut both directions down, waking any thread blocked on this socket.
pub fn shutdown(conn: Conn) {
    unsafe { libc::shutdown(conn, libc::SHUT_RDWR) };
}

/// Release this descriptor.
pub fn close(conn: Conn) {
    unsafe { libc::close(conn) };
}

/// A distinct close-on-exec descriptor for the same socket, so reader and
/// writer threads can close independently without reusing each other's number.
pub fn duplicate(conn: Conn) -> io::Result<Conn> {
    let copy = unsafe { libc::fcntl(conn, libc::F_DUPFD_CLOEXEC, 3) };
    if copy < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(copy)
    }
}

/// Configure a viewer's writer socket: a 5 s send timeout bounds each write so
/// the writer can observe peer departure while credit is withheld.
pub fn prepare_viewer(conn: Conn) -> io::Result<()> {
    let timeout = libc::timeval {
        tv_sec: 5,
        tv_usec: 0,
    };
    if unsafe {
        libc::setsockopt(
            conn,
            libc::SOL_SOCKET,
            libc::SO_SNDTIMEO,
            &timeout as *const _ as *const libc::c_void,
            std::mem::size_of_val(&timeout) as libc::socklen_t,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Wait up to `millis` for send space.
pub fn wait_writable(conn: Conn, millis: i32) {
    let mut poller = libc::pollfd {
        fd: conn,
        events: libc::POLLOUT,
        revents: 0,
    };
    unsafe { libc::poll(&mut poller, 1, millis) };
}
