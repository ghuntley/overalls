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
use crate::sys::windows as sys;
use std::collections::HashMap;
use std::io;
use std::sync::Mutex;
use windows_sys::Win32::Networking::WinSock::{
    FIONBIO, SD_BOTH, SOCKET, SOCKET_ERROR, TIMEVAL, WSAEWOULDBLOCK,
};

/// An accepted viosock connection handle.
pub(crate) type Conn = SOCKET;

/// Extra holders per socket beyond the first.
static HOLDERS: Mutex<Option<HashMap<SOCKET, usize>>> = Mutex::new(None);

fn wsa_error() -> io::Error {
    io::Error::from_raw_os_error(sys::wsa_last_error())
}

fn wait(conn: Conn, millis: i32, for_write: bool) {
    let timeout = TIMEVAL {
        tv_sec: millis / 1000,
        tv_usec: (millis % 1000) * 1000,
    };
    sys::select_one(conn, for_write, &timeout);
}

/// One receive; `Ok(0)` is end of stream. A non-blocking viewer socket waits
/// in bounded slices instead of returning `WouldBlock`, so readers block as
/// they do on Linux and still wake on shutdown.
pub(crate) fn read(conn: Conn, buf: &mut [u8]) -> io::Result<usize> {
    loop {
        let received = sys::receive(conn, buf);
        if received != SOCKET_ERROR {
            #[expect(
                clippy::cast_sign_loss,
                reason = "recv returns SOCKET_ERROR (handled above) or a non-negative count"
            )]
            return Ok(received as usize);
        }
        if sys::wsa_last_error() == WSAEWOULDBLOCK {
            wait(conn, 100, false);
            continue;
        }
        return Err(wsa_error());
    }
}

/// One send; a full non-blocking socket reports `WouldBlock`.
pub(crate) fn write(conn: Conn, buf: &[u8]) -> io::Result<usize> {
    let sent = sys::transmit(conn, buf);
    if sent == SOCKET_ERROR {
        return Err(wsa_error());
    }
    if sent == 0 {
        return Err(io::ErrorKind::WriteZero.into());
    }
    #[expect(
        clippy::cast_sign_loss,
        reason = "send returns SOCKET_ERROR (handled above) or a non-negative count"
    )]
    Ok(sent as usize)
}

/// Shut both directions down, waking any thread waiting on this socket.
pub(crate) fn shutdown(conn: Conn) {
    sys::shutdown_socket(conn, SD_BOTH);
}

/// Release one holder; the socket closes when the last holder releases it.
pub(crate) fn close(conn: Conn) {
    let last = {
        #[expect(
            clippy::unwrap_used,
            reason = "release builds use panic = abort, so a panicking holder ends the \
                      process before any thread can observe poison"
        )]
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
        // The final holder closes the socket exactly once.
        sys::close_socket(conn);
    }
}

/// Another holder of the same socket (see the module notes).
#[expect(
    clippy::unnecessary_wraps,
    reason = "shares the platform-neutral signature of the fallible Unix duplicate"
)]
pub(crate) fn duplicate(conn: Conn) -> io::Result<Conn> {
    #[expect(
        clippy::unwrap_used,
        reason = "release builds use panic = abort, so a panicking holder ends the \
                  process before any thread can observe poison"
    )]
    let mut guard = HOLDERS.lock().unwrap();
    *guard
        .get_or_insert_with(HashMap::new)
        .entry(conn)
        .or_insert(0) += 1;
    Ok(conn)
}

/// Switch a viewer's socket to non-blocking mode for bounded writer waits.
pub(crate) fn prepare_viewer(conn: Conn) -> io::Result<()> {
    let mut enabled: u32 = 1;
    if sys::ioctl_socket(conn, FIONBIO, &mut enabled) == SOCKET_ERROR {
        return Err(wsa_error());
    }
    Ok(())
}

/// Wait up to `millis` for send space.
pub(crate) fn wait_writable(conn: Conn, millis: i32) {
    wait(conn, millis, true);
}
