//! `AF_VSOCK` on Windows guests through the virtio-win `viosock` driver and its
//! Winsock provider (ADR-0171).
//!
//! This mirrors Lyra's `platform::windows::vsock` (terminald is a separate,
//! dependency-light crate): Windows has no `AF_VSOCK` constant, so the family
//! is discovered at runtime from the `\\.\Viosock` control device, then the
//! Winsock catalog. `SOCKADDR_VM` is 12 bytes in host byte order.
use crate::conn::Conn;
use std::io;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Networking::WinSock::{
    accept as wsa_accept, bind, closesocket, getpeername, listen as wsa_listen, socket,
    WSAEnumProtocolsW, WSAGetLastError, WSAStartup, INVALID_SOCKET, SOCKADDR, SOCKET, SOCKET_ERROR,
    SOCK_STREAM, WSADATA, WSAPROTOCOL_INFOW,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::DeviceIoControl;

/// The host side of every Firecracker vsock connection.
pub(crate) const CID_HOST: u32 = 2;
const CID_ANY: u32 = 0xFFFF_FFFF;
const DEVICE: &str = "\\\\.\\Viosock";
const IOCTL_GET_AF: u32 = 0x0801_300C;
/// The driver binds through plug-and-play at first boot and its provider
/// service starts afterwards; discovery retries within this budget.
const DISCOVERY_BUDGET: Duration = Duration::from_mins(10);

/// The listening viosock socket.
pub(crate) type Listener = SOCKET;

#[repr(C)]
#[derive(Clone, Copy)]
struct SockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
}

/// `size_of::<SockaddrVm>()` as a Winsock address length.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    reason = "SOCKADDR_VM is 12 bytes, far below i32::MAX"
)]
const SOCKADDR_VM_LEN: i32 = size_of::<SockaddrVm>() as i32;

fn wsa_error() -> io::Error {
    // SAFETY: WSAGetLastError only reads this thread's last Winsock error.
    io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn ioctl_family() -> io::Result<u16> {
    let name = wide(DEVICE);
    // SAFETY: `name` is NUL-terminated UTF-16 that outlives the call.
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
        return Err(io::Error::from_raw_os_error(
            // SAFETY: GetLastError only reads this thread's last error code.
            unsafe { GetLastError() }.cast_signed(),
        ));
    }
    let mut out = [0u8; 4];
    let mut returned = 0u32;
    #[expect(
        clippy::cast_possible_truncation,
        reason = "`out` is a four-byte array"
    )]
    let out_len = out.len() as u32;
    // SAFETY: `out` and `returned` are writable and live across the synchronous call.
    let ok = unsafe {
        DeviceIoControl(
            handle,
            IOCTL_GET_AF,
            null(),
            0,
            out.as_mut_ptr().cast(),
            out_len,
            &raw mut returned,
            null_mut(),
        )
    };
    // SAFETY: GetLastError only reads this thread's last error code.
    let error = unsafe { GetLastError() };
    // SAFETY: the handle came from CreateFileW above and is closed exactly once.
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        return Err(io::Error::from_raw_os_error(error.cast_signed()));
    }
    match returned {
        2 => Ok(u16::from_ne_bytes([out[0], out[1]])),
        4 => u16::try_from(u32::from_ne_bytes(out))
            .map_err(|_| io::Error::other("vsock family out of range")),
        _ => Err(io::Error::other("unexpected vsock family size")),
    }
}

fn catalog_family() -> io::Result<u16> {
    let mut length = 0u32;
    // SAFETY: a null buffer with a zero length asks Winsock for the size.
    if unsafe { WSAEnumProtocolsW(null(), null_mut(), &raw mut length) } != SOCKET_ERROR {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no vsock provider"));
    }
    let count = length as usize / size_of::<WSAPROTOCOL_INFOW>() + 1;
    // SAFETY: WSAPROTOCOL_INFOW is plain data; zero is a valid bit pattern.
    let mut buffer: Vec<WSAPROTOCOL_INFOW> = vec![unsafe { zeroed() }; count];
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the buffer is one record above the u32 size Winsock just reported \
                  for its catalog of a few KiB"
    )]
    let mut length = (buffer.len() * size_of::<WSAPROTOCOL_INFOW>()) as u32;
    // SAFETY: `buffer` holds `length` writable bytes.
    let filled = unsafe { WSAEnumProtocolsW(null(), buffer.as_mut_ptr(), &raw mut length) };
    if filled == SOCKET_ERROR {
        return Err(wsa_error());
    }
    #[expect(
        clippy::cast_sign_loss,
        reason = "WSAEnumProtocolsW returns SOCKET_ERROR (handled above) or a record count"
    )]
    let filled = filled as usize;
    buffer
        .iter()
        .take(filled)
        .find_map(|info| {
            let end = info
                .szProtocol
                .iter()
                .position(|&unit| unit == 0)
                .unwrap_or(info.szProtocol.len());
            let name = String::from_utf16_lossy(&info.szProtocol[..end]).to_ascii_lowercase();
            (name.contains("virtio") || name.contains("vsock"))
                .then(|| u16::try_from(info.iAddressFamily).ok())
                .flatten()
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no vsock provider"))
}

fn discover() -> io::Result<u16> {
    let started = Instant::now();
    loop {
        match ioctl_family().or_else(|_| catalog_family()) {
            Ok(family) => return Ok(family),
            Err(error) if started.elapsed() >= DISCOVERY_BUDGET => return Err(error),
            Err(_) => std::thread::sleep(Duration::from_secs(2)),
        }
    }
}

/// @cc [owner:ghuntley,label:security] windows-terminald-listener-any-cid
/// `listen` MUST bind the discovered viosock family on the requested port and
/// `VMADDR_CID_ANY`, and MUST fail (closing the socket) rather than listen on
/// another port or family when Winsock, discovery, bind or listen refuses.
pub(crate) fn listen(port: u32) -> io::Result<Listener> {
    // SAFETY: WSADATA is plain data that WSAStartup fills.
    let mut data: WSADATA = unsafe { zeroed() };
    // SAFETY: WSAStartup writes one WSADATA to `data`, a live local.
    let started = unsafe { WSAStartup(0x0202, &raw mut data) };
    if started != 0 {
        return Err(io::Error::from_raw_os_error(started));
    }
    let family = discover()?;
    // SAFETY: plain socket creation after WSAStartup.
    let handle = unsafe { socket(i32::from(family), SOCK_STREAM, 0) };
    if handle == INVALID_SOCKET {
        return Err(wsa_error());
    }
    let address = SockaddrVm {
        family,
        reserved: 0,
        port,
        cid: CID_ANY,
    };
    // SAFETY: `address` is a 12-byte SOCKADDR_VM passed with its exact size.
    let bound = unsafe {
        bind(
            handle,
            (&raw const address).cast::<SOCKADDR>(),
            SOCKADDR_VM_LEN,
        )
    };
    if bound == SOCKET_ERROR
        // SAFETY: listen takes a socket handle and a backlog and touches no memory.
        || unsafe { wsa_listen(handle, 64) } == SOCKET_ERROR
    {
        let error = wsa_error();
        // SAFETY: closed exactly once on this failure path.
        unsafe { closesocket(handle) };
        return Err(error);
    }
    Ok(handle)
}

/// @cc [owner:ghuntley,label:security] windows-terminald-peer-cid
/// `accept` MUST return the peer CID the provider reports, asking again with
/// `getpeername` when the accept left it zero; an unknown peer stays CID 0,
/// which is never the host.
pub(crate) fn accept(listener: Listener) -> io::Result<(Conn, u32, u32)> {
    // SAFETY: SockaddrVm is plain data; zero is a valid bit pattern.
    let mut peer: SockaddrVm = unsafe { zeroed() };
    let mut size = SOCKADDR_VM_LEN;
    // SAFETY: `peer` is a writable 12-byte address buffer and `size` its length.
    let connection =
        unsafe { wsa_accept(listener, (&raw mut peer).cast::<SOCKADDR>(), &raw mut size) };
    if connection == INVALID_SOCKET {
        return Err(wsa_error());
    }
    if peer.cid == 0 {
        let mut size = SOCKADDR_VM_LEN;
        // SAFETY: `peer` is a writable 12-byte address buffer and `size` its
        // length, both live across the call.
        unsafe {
            getpeername(
                connection,
                (&raw mut peer).cast::<SOCKADDR>(),
                &raw mut size,
            )
        };
    }
    Ok((connection, peer.cid, peer.port))
}
