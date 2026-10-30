//! `AF_VSOCK` on Windows through the virtio-win `viosock` driver and its Winsock
//! provider (ADR-0171).
//!
//! Windows has no `AF_VSOCK` constant: the provider registers a dynamic
//! address family, exposed through the `\\.\Viosock` control device and the
//! Winsock catalog. Everything here discovers it at runtime and never assumes
//! a number. `SOCKADDR_VM` is 12 bytes in host byte order.

use super::{last_error, wide};
use std::io::{self, Read, Write};
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    CloseHandle, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Networking::WinSock::{
    accept, bind, closesocket, getpeername, listen, recv, send, setsockopt, socket,
    WSAEnumProtocolsW, WSAGetLastError, WSAStartup, INVALID_SOCKET, SOCKADDR, SOCKET, SOCKET_ERROR,
    SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, WSADATA, WSAPROTOCOL_INFOW,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::DeviceIoControl;

/// The host side of every Firecracker vsock connection.
pub const HOST_CID: u32 = 2;
const VMADDR_CID_ANY: u32 = 0xFFFF_FFFF;
/// viosock control device and its "get address family" request.
const DEVICE: &str = "\\\\.\\Viosock";
const IOCTL_GET_AF: u32 = 0x0801_300C;

/// `SOCKADDR_VM` as viosock defines it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct SockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
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

/// How the address family was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The `\\.\Viosock` control device answered the family IOCTL.
    Ioctl,
    /// A Winsock catalog entry named the virtio provider.
    Catalog,
}

impl Source {
    pub fn name(self) -> &'static str {
        match self {
            Source::Ioctl => "ioctl",
            Source::Catalog => "catalog",
        }
    }
}

/// The discovered vsock address family.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Family {
    pub number: u16,
    pub source: Source,
}

fn wsa_error() -> io::Error {
    // SAFETY: WSAGetLastError has no preconditions.
    io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

/// Initialise Winsock 2.2 for this process; idempotent per call site.
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

fn ioctl_family() -> io::Result<u16> {
    let name = wide(DEVICE);
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
            IOCTL_GET_AF,
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
    match returned {
        2 => Ok(u16::from_ne_bytes([out[0], out[1]])),
        4 => u16::try_from(u32::from_ne_bytes(out))
            .map_err(|_| io::Error::other("vsock family out of range")),
        _ => Err(io::Error::other("unexpected vsock family size")),
    }
}

/// One Winsock catalog entry.
#[derive(Clone, Debug)]
pub struct Provider {
    pub name: String,
    pub family: i32,
    pub socket_type: i32,
    pub protocol: i32,
}

/// Every protocol provider in the Winsock catalog.
pub fn catalog() -> io::Result<Vec<Provider>> {
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
    Ok(buffer
        .iter()
        .take(usize::try_from(filled).map_err(|_| wsa_error())?)
        .map(|info| {
            let end = info
                .szProtocol
                .iter()
                .position(|&unit| unit == 0)
                .unwrap_or(info.szProtocol.len());
            Provider {
                name: String::from_utf16_lossy(&info.szProtocol[..end]),
                family: info.iAddressFamily,
                socket_type: info.iSocketType,
                protocol: info.iProtocol,
            }
        })
        .collect())
}

/// One discovery attempt: the control device first, then the catalog.
pub fn discover_once() -> io::Result<Family> {
    if let Ok(number) = ioctl_family() {
        return Ok(Family {
            number,
            source: Source::Ioctl,
        });
    }
    let providers = catalog()?;
    providers
        .iter()
        .find(|provider| {
            let name = provider.name.to_ascii_lowercase();
            name.contains("virtio") || name.contains("vsock")
        })
        .and_then(|provider| u16::try_from(provider.family).ok())
        .map(|number| Family {
            number,
            source: Source::Catalog,
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no vsock provider"))
}

/// Discover the family, retrying every two seconds within `budget`: the
/// driver binds through plug-and-play at first boot and its provider service
/// starts afterwards. `report` receives each failed attempt's error.
pub fn discover(budget: Duration, mut report: impl FnMut(&io::Error)) -> io::Result<Family> {
    let started = Instant::now();
    loop {
        match discover_once() {
            Ok(family) => return Ok(family),
            Err(error) => {
                report(&error);
                if started.elapsed() >= budget {
                    return Err(error);
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
}

/// A vsock listener bound to one port on any CID.
#[derive(Debug)]
pub struct Listener {
    socket: SOCKET,
    pub family: Family,
    pub port: u32,
}

/// An accepted connection with its peer identity.
#[derive(Debug)]
pub struct Connection {
    socket: SOCKET,
    pub peer_cid: u32,
    pub peer_port: u32,
}

impl Listener {
    /// @cc [owner:ghuntley,label:security] windows-vsock-listener-any-cid
    /// bind MUST use the discovered family, the requested port and
    /// `VMADDR_CID_ANY`, and MUST fail (closing the socket) rather than listen
    /// on a different port or family when bind or listen refuses.
    pub fn bind(family: Family, port: u32, backlog: i32) -> io::Result<Self> {
        // SAFETY: plain socket creation after startup().
        let handle = unsafe { socket(i32::from(family.number), SOCK_STREAM, 0) };
        if handle == INVALID_SOCKET {
            return Err(wsa_error());
        }
        let address = SockaddrVm {
            family: family.number,
            reserved: 0,
            port,
            cid: VMADDR_CID_ANY,
        };
        // SAFETY: `address` is a 12-byte SOCKADDR_VM passed with its exact size.
        let bound = unsafe {
            bind(
                handle,
                (&raw const address).cast::<SOCKADDR>(),
                SOCKADDR_VM_LEN,
            )
        };
        // SAFETY: `handle` is a valid socket from socket() above.
        if bound == SOCKET_ERROR || unsafe { listen(handle, backlog) } == SOCKET_ERROR {
            let error = wsa_error();
            // SAFETY: the socket is closed exactly once here.
            unsafe {
                closesocket(handle);
            }
            return Err(error);
        }
        Ok(Self {
            socket: handle,
            family,
            port,
        })
    }

    /// Block for the next connection; `timeout` bounds its reads and writes.
    pub fn accept(&self, timeout: Duration) -> io::Result<Connection> {
        // SAFETY: SockaddrVm is plain data; zero is a valid bit pattern.
        let mut peer: SockaddrVm = unsafe { zeroed() };
        let mut size = SOCKADDR_VM_LEN;
        // SAFETY: `peer` is a writable 12-byte address buffer and `size` its length.
        let connection = unsafe {
            accept(
                self.socket,
                (&raw mut peer).cast::<SOCKADDR>(),
                &raw mut size,
            )
        };
        if connection == INVALID_SOCKET {
            return Err(wsa_error());
        }
        let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            // SAFETY: the option value is a u32 (DWORD milliseconds) passed with its size.
            unsafe {
                setsockopt(
                    connection,
                    SOL_SOCKET,
                    option,
                    (&raw const millis).cast::<u8>(),
                    DWORD_LEN,
                );
            }
        }
        if peer.cid == 0 {
            // Some accepts complete before the provider fills the peer address;
            // ask for it once more. An unknown peer is reported as CID 0 and is
            // never the host.
            let mut size = SOCKADDR_VM_LEN;
            // SAFETY: `peer` is a writable 12-byte address buffer and `size` its length.
            unsafe {
                getpeername(
                    connection,
                    (&raw mut peer).cast::<SOCKADDR>(),
                    &raw mut size,
                );
            }
        }
        Ok(Connection {
            socket: connection,
            peer_cid: peer.cid,
            peer_port: peer.port,
        })
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: the listening socket is closed exactly once.
        unsafe {
            closesocket(self.socket);
        }
    }
}

impl Connection {
    /// Whether the peer is the host (Firecracker's vsock muxer).
    pub fn from_host(&self) -> bool {
        self.peer_cid == HOST_CID
    }
}

impl Read for Connection {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
        // SAFETY: `buf` is writable for `len` bytes during the call.
        let received = unsafe { recv(self.socket, buf.as_mut_ptr(), len, 0) };
        if received == SOCKET_ERROR {
            Err(wsa_error())
        } else {
            usize::try_from(received).map_err(|_| wsa_error())
        }
    }
}

impl Write for Connection {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let len = i32::try_from(buf.len()).unwrap_or(i32::MAX);
        // SAFETY: `buf` is readable for `len` bytes during the call.
        let sent = unsafe { send(self.socket, buf.as_ptr(), len, 0) };
        if sent == SOCKET_ERROR {
            Err(wsa_error())
        } else {
            usize::try_from(sent).map_err(|_| wsa_error())
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // SAFETY: the accepted socket is closed exactly once.
        unsafe {
            closesocket(self.socket);
        }
    }
}
