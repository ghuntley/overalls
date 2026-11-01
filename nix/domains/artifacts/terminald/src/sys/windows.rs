//! Winsock, device and RNG calls on Windows guests (ADR-0171).
//!
//! Each wrapper makes exactly the Win32 call its caller made before and
//! returns the raw result, so callers read `GetLastError`/`WSAGetLastError`
//! unchanged. Socket and handle arguments are plain values: passing one the
//! caller does not own can at worst make the call fail or act on another
//! kernel object, never touch Rust memory; callers keep their ownership rules.
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use windows_sys::core::BOOL;
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, GENERIC_READ, GENERIC_WRITE, HANDLE,
};
use windows_sys::Win32::Networking::WinSock::{
    accept, bind, closesocket, getpeername, ioctlsocket, listen, recv, select, send, shutdown,
    socket, WSAEnumProtocolsW, WSAGetLastError, WSAStartup, FD_SET, SOCKADDR, SOCKET, TIMEVAL,
    WSADATA, WSAPROTOCOL_INFOW,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::DeviceIoControl;

mod sealed {
    pub(crate) trait Sealed {}
}

/// A `#[repr(C)]` socket address made only of integer fields, so Winsock may
/// read or write all `size_of::<Self>()` bytes of it. Implemented here, for
/// the viosock address only.
pub(crate) trait SocketAddress: sealed::Sealed + Copy {}

impl sealed::Sealed for crate::vsock::SockaddrVm {}
impl SocketAddress for crate::vsock::SockaddrVm {}

#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    reason = "socket addresses are a few dozen bytes, far below i32::MAX"
)]
const fn length_of<T>() -> i32 {
    size_of::<T>() as i32
}

/// NUL-terminated UTF-16 for a wide-string argument.
pub(crate) fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// `GetLastError`.
pub(crate) fn last_error() -> u32 {
    // SAFETY: GetLastError only reads this thread's last error code.
    unsafe { GetLastError() }
}

/// `WSAGetLastError`.
pub(crate) fn wsa_last_error() -> i32 {
    // SAFETY: WSAGetLastError only reads this thread's last Winsock error.
    unsafe { WSAGetLastError() }
}

/// `CloseHandle`. Callers close each handle they own exactly once.
pub(crate) fn close_handle(handle: HANDLE) -> BOOL {
    // SAFETY: CloseHandle takes a handle value and touches no caller memory.
    unsafe { CloseHandle(handle) }
}

/// Fill `token` from the system-preferred RNG; the NTSTATUS result.
pub(crate) fn system_random(token: &mut [u8; 16]) -> i32 {
    use windows_sys::Win32::Security::Cryptography::{
        BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the token is a 16-byte array"
    )]
    let token_length = token.len() as u32;
    // SAFETY: `token` is writable for its full length; no algorithm handle is
    // needed with the system-preferred RNG flag.
    unsafe {
        BCryptGenRandom(
            null_mut(),
            token.as_mut_ptr(),
            token_length,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    }
}

/// Open the device at `path` for synchronous read and write.
pub(crate) fn open_device(path: &str) -> HANDLE {
    let name = wide(path);
    // SAFETY: `name` is NUL-terminated UTF-16 that outlives the call.
    unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    }
}

/// A synchronous output-only `DeviceIoControl` into `out`.
pub(crate) fn device_io_control_out(
    handle: HANDLE,
    code: u32,
    out: &mut [u8],
    returned: &mut u32,
) -> BOOL {
    let out_len = u32::try_from(out.len()).unwrap_or(u32::MAX);
    // SAFETY: `out` is writable for `out_len` bytes and `returned` is a live
    // exclusive u32, both across the synchronous call.
    unsafe {
        DeviceIoControl(
            handle,
            code,
            null(),
            0,
            out.as_mut_ptr().cast(),
            out_len,
            std::ptr::from_mut(returned),
            null_mut(),
        )
    }
}

/// `WSAStartup` for Winsock 2.2.
pub(crate) fn wsa_startup() -> i32 {
    // SAFETY: WSADATA is plain data that WSAStartup fills.
    let mut data: WSADATA = unsafe { zeroed() };
    // SAFETY: WSAStartup writes one WSADATA to `data`, a live local.
    unsafe { WSAStartup(0x0202, &raw mut data) }
}

/// `WSAEnumProtocolsW` with no buffer: stores the size the catalog needs.
pub(crate) fn enum_protocols_size(length: &mut u32) -> i32 {
    // SAFETY: a null buffer with a zero length asks Winsock for the size,
    // written to `length`, a live exclusive u32.
    unsafe { WSAEnumProtocolsW(null(), null_mut(), std::ptr::from_mut(length)) }
}

/// A zeroed catalog record for `enum_protocols`.
pub(crate) fn empty_protocol_info() -> WSAPROTOCOL_INFOW {
    // SAFETY: WSAPROTOCOL_INFOW is plain data; zero is a valid bit pattern.
    unsafe { zeroed() }
}

/// `WSAEnumProtocolsW` into `buffer`: the record count or `SOCKET_ERROR`.
pub(crate) fn enum_protocols(buffer: &mut [WSAPROTOCOL_INFOW]) -> i32 {
    let mut length = u32::try_from(size_of_val(buffer)).unwrap_or(u32::MAX);
    // SAFETY: `buffer` holds at least `length` writable bytes.
    unsafe { WSAEnumProtocolsW(null(), buffer.as_mut_ptr(), &raw mut length) }
}

/// `socket`.
pub(crate) fn open_socket(family: i32, kind: i32, protocol: i32) -> SOCKET {
    // SAFETY: plain socket creation; takes integers and touches no memory.
    unsafe { socket(family, kind, protocol) }
}

/// `bind` to `address`, passed with its exact size.
pub(crate) fn bind_socket<A: SocketAddress>(handle: SOCKET, address: &A) -> i32 {
    // SAFETY: bind reads `size_of::<A>()` bytes from `address`, a live
    // repr(C) socket address of exactly that size.
    unsafe {
        bind(
            handle,
            std::ptr::from_ref(address).cast::<SOCKADDR>(),
            length_of::<A>(),
        )
    }
}

/// `listen`.
pub(crate) fn listen_socket(handle: SOCKET, backlog: i32) -> i32 {
    // SAFETY: listen takes a socket handle and a backlog and touches no memory.
    unsafe { listen(handle, backlog) }
}

/// `accept`, storing the peer in `peer`.
pub(crate) fn accept_socket<A: SocketAddress>(listener: SOCKET, peer: &mut A) -> SOCKET {
    let mut size = length_of::<A>();
    // SAFETY: `peer` is a writable address buffer of exactly `size` bytes and
    // `size` a live local, both across the call.
    unsafe {
        accept(
            listener,
            std::ptr::from_mut(peer).cast::<SOCKADDR>(),
            &raw mut size,
        )
    }
}

/// `getpeername` into `peer`.
pub(crate) fn peer_name<A: SocketAddress>(connection: SOCKET, peer: &mut A) -> i32 {
    let mut size = length_of::<A>();
    // SAFETY: `peer` is a writable address buffer of exactly `size` bytes and
    // `size` a live local, both across the call.
    unsafe {
        getpeername(
            connection,
            std::ptr::from_mut(peer).cast::<SOCKADDR>(),
            &raw mut size,
        )
    }
}

/// `closesocket`. Callers close each socket they own exactly once.
pub(crate) fn close_socket(handle: SOCKET) -> i32 {
    // SAFETY: closesocket takes a socket handle and touches no caller memory.
    unsafe { closesocket(handle) }
}

/// `shutdown`.
pub(crate) fn shutdown_socket(handle: SOCKET, how: i32) -> i32 {
    // SAFETY: shutting down an open or already shut socket has no memory effects.
    unsafe { shutdown(handle, how) }
}

/// One `recv` into `buf`.
pub(crate) fn receive(handle: SOCKET, buf: &mut [u8]) -> i32 {
    let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
    // SAFETY: `buf` is writable for `len` bytes during the call.
    unsafe { recv(handle, buf.as_mut_ptr(), len, 0) }
}

/// One `send` of `buf`.
pub(crate) fn transmit(handle: SOCKET, buf: &[u8]) -> i32 {
    let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
    // SAFETY: `buf` is readable for `len` bytes during the call.
    unsafe { send(handle, buf.as_ptr(), len, 0) }
}

/// `ioctlsocket` with a u32 argument.
pub(crate) fn ioctl_socket(handle: SOCKET, command: i32, argument: &mut u32) -> i32 {
    // SAFETY: ioctlsocket reads and may write one u32 at `argument`, a live
    // exclusive reference.
    unsafe { ioctlsocket(handle, command, std::ptr::from_mut(argument)) }
}

/// A bounded `select` on one socket, for reading or for writing.
pub(crate) fn select_one(handle: SOCKET, for_write: bool, timeout: &TIMEVAL) -> i32 {
    let mut set = FD_SET {
        fd_count: 1,
        fd_array: [0; 64],
    };
    set.fd_array[0] = handle;
    let set_pointer: *mut FD_SET = &raw mut set;
    let (reads, writes) = if for_write {
        (null_mut(), set_pointer)
    } else {
        (set_pointer, null_mut())
    };
    // SAFETY: one valid FD_SET (one entry) and TIMEVAL live across the call;
    // nfds is ignored.
    unsafe { select(0, reads, writes, null_mut(), std::ptr::from_ref(timeout)) }
}
