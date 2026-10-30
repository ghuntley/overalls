//! Connection sockets on Windows guests (ADR-0171): accepted viosock sockets.
//!
//! Winsock cannot `dup` a socket inside one process, so `duplicate` returns
//! the same handle with a reference count and `close` releases it only when
//! the last holder closes. That keeps the engine's rule (reader and writer
//! close independently and never reuse each other's handle) without relying
//! on provider support for `WSADuplicateSocket`. A viewer socket is switched to
//! non-blocking mode and every wait is a bounded `select`, which gives writers
//! the same "pause on withheld credit, observe departure" behaviour as the
//! Linux send timeout.
use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use windows_sys::Win32::Networking::WinSock::{
    closesocket, ioctlsocket, recv, select, send, shutdown as wsa_shutdown, WSAGetLastError,
    FD_SET, FIONBIO, SD_BOTH, SOCKET, SOCKET_ERROR, TIMEVAL, WSAEWOULDBLOCK,
};

/// An accepted viosock connection handle.
pub type Conn = SOCKET;

/// Extra holders per socket beyond the first.
static HOLDERS: Mutex<Option<HashMap<SOCKET, usize>>> = Mutex::new(None);

fn wsa_error() -> io::Error {
    io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

fn wait(conn: Conn, millis: i32, for_write: bool) {
    let mut set = FD_SET {
        fd_count: 1,
        fd_array: [0; 64],
    };
    set.fd_array[0] = conn;
    let timeout = TIMEVAL {
        tv_sec: millis / 1000,
        tv_usec: (millis % 1000) * 1000,
    };
    let set_pointer: *mut FD_SET = &mut set;
    let (reads, writes) = if for_write {
        (std::ptr::null_mut(), set_pointer)
    } else {
        (set_pointer, std::ptr::null_mut())
    };
    // SAFETY: one valid FD_SET and TIMEVAL live across the call; nfds is ignored.
    unsafe { select(0, reads, writes, std::ptr::null_mut(), &timeout) };
}

/// One receive; `Ok(0)` is end of stream. A non-blocking viewer socket waits
/// in bounded slices instead of returning `WouldBlock`, so readers block as
/// they do on Linux and still wake on shutdown.
pub fn read(conn: Conn, buf: &mut [u8]) -> io::Result<usize> {
    let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
    loop {
        // SAFETY: `buf` is writable for `len` bytes during the call.
        let received = unsafe { recv(conn, buf.as_mut_ptr(), len, 0) };
        if received != SOCKET_ERROR {
            return Ok(received as usize);
        }
        if unsafe { WSAGetLastError() } == WSAEWOULDBLOCK {
            wait(conn, 100, false);
            continue;
        }
        return Err(wsa_error());
    }
}

/// One send; a full non-blocking socket reports `WouldBlock`.
pub fn write(conn: Conn, buf: &[u8]) -> io::Result<usize> {
    let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
    // SAFETY: `buf` is readable for `len` bytes during the call.
    let sent = unsafe { send(conn, buf.as_ptr(), len, 0) };
    if sent == SOCKET_ERROR {
        return Err(wsa_error());
    }
    if sent == 0 {
        return Err(io::ErrorKind::WriteZero.into());
    }
    Ok(sent as usize)
}

/// Shut both directions down, waking any thread waiting on this socket.
pub fn shutdown(conn: Conn) {
    // SAFETY: shutting down an open or already shut socket has no memory effects.
    unsafe { wsa_shutdown(conn, SD_BOTH) };
}

/// Release one holder; the socket closes when the last holder releases it.
pub fn close(conn: Conn) {
    let last = {
        let mut guard = HOLDERS.lock().unwrap();
        let holders = guard.get_or_insert_with(HashMap::new);
        match holders.get_mut(&conn) {
            Some(extra) => {
                *extra -= 1;
                if *extra == 0 {
                    holders.remove(&conn);
                }
                false
            }
            None => true,
        }
    };
    if last {
        // SAFETY: the final holder closes the socket exactly once.
        unsafe { closesocket(conn) };
    }
}

/// Another holder of the same socket (see the module notes).
pub fn duplicate(conn: Conn) -> io::Result<Conn> {
    let mut guard = HOLDERS.lock().unwrap();
    *guard
        .get_or_insert_with(HashMap::new)
        .entry(conn)
        .or_insert(0) += 1;
    Ok(conn)
}

/// Switch a viewer's socket to non-blocking mode for bounded writer waits.
pub fn prepare_viewer(conn: Conn) -> io::Result<()> {
    let mut enabled: u32 = 1;
    // SAFETY: FIONBIO takes a writable u32 flag.
    if unsafe { ioctlsocket(conn, FIONBIO, &mut enabled) } == SOCKET_ERROR {
        return Err(wsa_error());
    }
    Ok(())
}

/// Wait up to `millis` for send space.
pub fn wait_writable(conn: Conn, millis: i32) {
    wait(conn, millis, true);
}
