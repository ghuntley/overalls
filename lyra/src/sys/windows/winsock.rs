//! Winsock sockets for the viosock `AF_VSOCK` provider, and the viosock
//! control device.

use super::error::last_error;
use super::wide;
use std::io;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{
    CloseHandle, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Networking::WinSock::{
    accept, bind, closesocket, getpeername, listen, recv, send, setsockopt, socket,
    WSAEnumProtocolsW, WSAGetLastError, WSAStartup, INVALID_SOCKET, SOCKADDR, SOCKET, SOCKET_ERROR,
    SOCK_STREAM, SOL_SOCKET, WSADATA, WSAPROTOCOL_INFOW,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::DeviceIoControl;

/// `SOCKADDR_VM` as viosock defines it: 12 bytes in host byte order.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SockaddrVm {
    pub family: u16,
    pub reserved: u16,
    pub port: u32,
    pub cid: u32,
}

/// Byte length of [`SockaddrVm`] as Winsock's `int` address length.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    reason = "SOCKADDR_VM is 12 bytes"
)]
const SOCKADDR_VM_LEN: i32 = size_of::<SockaddrVm>() as i32;

/// Byte length of a DWORD socket option value.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    reason = "a DWORD is 4 bytes"
)]
const DWORD_LEN: i32 = size_of::<u32>() as i32;

/// The thread's last Winsock error.
pub fn wsa_error() -> io::Error {
    // SAFETY: WSAGetLastError has no preconditions.
    io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

/// Initialise Winsock 2.2 for this process.
pub fn startup() -> io::Result<()> {
    // SAFETY: WSADATA is plain data that WSAStartup fills.
    let mut data: WSADATA = unsafe { zeroed() };
    // SAFETY: requests Winsock 2.2 with a writable WSADATA.
    let started = unsafe { WSAStartup(0x0202, &raw mut data) };
    if started == 0 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(started))
    }
}

/// Open `device` for reading and writing and issue the input-less IOCTL
/// `code`, returning its (up to) 4-byte output and the byte count written.
pub fn device_ioctl_out4(device: &str, code: u32) -> io::Result<([u8; 4], u32)> {
    let name = wide(device);
    // SAFETY: `name` is NUL-terminated UTF-16 that outlives the call; the
    // other arguments are plain values or null as CreateFileW permits.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(last_error());
    }
    let mut out = [0u8; 4];
    let mut returned = 0u32;
    // SAFETY: `out` is a writable 4-byte buffer and `returned` a writable u32,
    // both living across the synchronous call; no overlapped I/O.
    let ok = unsafe {
        DeviceIoControl(
            handle,
            code,
            null(),
            0,
            out.as_mut_ptr().cast(),
            4,
            &raw mut returned,
            null_mut(),
        )
    };
    let error = last_error();
    // SAFETY: the handle came from CreateFileW above and is closed exactly once.
    unsafe {
        CloseHandle(handle);
    }
    if ok == 0 {
        return Err(error);
    }
    Ok((out, returned))
}

/// Every protocol entry in the Winsock catalog (empty when the size probe
/// unexpectedly succeeds).
pub fn protocols() -> io::Result<Vec<WSAPROTOCOL_INFOW>> {
    let mut length = 0u32;
    // SAFETY: a null buffer with a zero length asks Winsock for the size.
    let probe = unsafe { WSAEnumProtocolsW(null(), null_mut(), &raw mut length) };
    if probe != SOCKET_ERROR {
        return Ok(Vec::new());
    }
    let count = length as usize / size_of::<WSAPROTOCOL_INFOW>() + 1;
    // SAFETY: WSAPROTOCOL_INFOW is plain data; zero is a valid bit pattern.
    let mut buffer: Vec<WSAPROTOCOL_INFOW> = vec![unsafe { zeroed() }; count];
    let mut length = u32::try_from(buffer.len() * size_of::<WSAPROTOCOL_INFOW>())
        .map_err(|_| io::Error::other("Winsock catalog too large"))?;
    // SAFETY: `buffer` holds `length` writable bytes of WSAPROTOCOL_INFOW.
    let filled = unsafe { WSAEnumProtocolsW(null(), buffer.as_mut_ptr(), &raw mut length) };
    if filled == SOCKET_ERROR {
        return Err(wsa_error());
    }
    buffer.truncate(usize::try_from(filled).map_err(|_| wsa_error())?);
    Ok(buffer)
}

/// One owned Winsock socket, closed exactly once on drop.
#[derive(Debug)]
pub struct Socket(SOCKET);

impl Socket {
    /// A new stream socket of address family `family` (after [`startup`]).
    pub fn stream(family: i32) -> io::Result<Self> {
        // SAFETY: plain socket creation after startup().
        let handle = unsafe { socket(family, SOCK_STREAM, 0) };
        if handle == INVALID_SOCKET {
            return Err(wsa_error());
        }
        Ok(Self(handle))
    }

    /// Bind to a vsock address.
    pub fn bind_vm(&self, address: &SockaddrVm) -> io::Result<()> {
        // SAFETY: `address` is a 12-byte SOCKADDR_VM passed with its exact size.
        let bound = unsafe {
            bind(
                self.0,
                (&raw const *address).cast::<SOCKADDR>(),
                SOCKADDR_VM_LEN,
            )
        };
        if bound == SOCKET_ERROR {
            return Err(wsa_error());
        }
        Ok(())
    }

    /// Start listening with `backlog`.
    pub fn listen(&self, backlog: i32) -> io::Result<()> {
        // SAFETY: `self.0` is a valid socket owned by this value.
        if unsafe { listen(self.0, backlog) } == SOCKET_ERROR {
            return Err(wsa_error());
        }
        Ok(())
    }

    /// Accept the next connection with its vsock peer address (zeroed when
    /// the provider did not fill it).
    pub fn accept_vm(&self) -> io::Result<(Self, SockaddrVm)> {
        // SAFETY: SockaddrVm is plain data; zero is a valid bit pattern.
        let mut peer: SockaddrVm = unsafe { zeroed() };
        let mut size = SOCKADDR_VM_LEN;
        // SAFETY: `peer` is a writable 12-byte address buffer and `size` its length.
        let connection =
            unsafe { accept(self.0, (&raw mut peer).cast::<SOCKADDR>(), &raw mut size) };
        if connection == INVALID_SOCKET {
            return Err(wsa_error());
        }
        Ok((Self(connection), peer))
    }

    /// Set a `SOL_SOCKET` DWORD option, ignoring failure.
    pub fn set_dword_option(&self, option: i32, value: u32) {
        // SAFETY: the option value is a u32 (DWORD) passed with its size.
        unsafe {
            setsockopt(
                self.0,
                SOL_SOCKET,
                option,
                (&raw const value).cast::<u8>(),
                DWORD_LEN,
            );
        }
    }

    /// Fill `peer` from `getpeername`, ignoring failure.
    pub fn peer_vm(&self, peer: &mut SockaddrVm) {
        let mut size = SOCKADDR_VM_LEN;
        // SAFETY: `peer` is a writable 12-byte address buffer and `size` its length.
        unsafe {
            getpeername(self.0, (&raw mut *peer).cast::<SOCKADDR>(), &raw mut size);
        }
    }

    /// Receive into `buf` (at most `i32::MAX` bytes per call).
    pub fn recv(&self, buf: &mut [u8]) -> io::Result<usize> {
        let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
        // SAFETY: `buf` is writable for `len` bytes during the call.
        let received = unsafe { recv(self.0, buf.as_mut_ptr(), len, 0) };
        if received == SOCKET_ERROR {
            Err(wsa_error())
        } else {
            usize::try_from(received).map_err(|_| wsa_error())
        }
    }

    /// Send from `buf` (at most `i32::MAX` bytes per call).
    pub fn send(&self, buf: &[u8]) -> io::Result<usize> {
        let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
        // SAFETY: `buf` is readable for `len` bytes during the call.
        let sent = unsafe { send(self.0, buf.as_ptr(), len, 0) };
        if sent == SOCKET_ERROR {
            Err(wsa_error())
        } else {
            usize::try_from(sent).map_err(|_| wsa_error())
        }
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        // SAFETY: the socket is owned by this value and closed exactly once.
        unsafe {
            closesocket(self.0);
        }
    }
}
