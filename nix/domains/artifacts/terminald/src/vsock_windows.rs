//! `AF_VSOCK` on Windows guests through the virtio-win `viosock` driver and its
//! Winsock provider (ADR-0171).
//!
//! This mirrors Lyra's `platform::windows::vsock` (terminald is a separate,
//! dependency-light crate): Windows has no `AF_VSOCK` constant, so the family
//! is discovered at runtime from the `\\.\Viosock` control device, then the
//! Winsock catalog. `SOCKADDR_VM` is 12 bytes in host byte order.
use crate::conn::Conn;
use crate::sys::windows as sys;
use std::io;
use std::mem::size_of;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
use windows_sys::Win32::Networking::WinSock::{
    INVALID_SOCKET, SOCKET, SOCKET_ERROR, SOCK_STREAM, WSAPROTOCOL_INFOW,
};

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
pub(crate) struct SockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
}

fn wsa_error() -> io::Error {
    io::Error::from_raw_os_error(sys::wsa_last_error())
}

fn ioctl_family() -> io::Result<u16> {
    let handle = sys::open_device(DEVICE);
    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::from_raw_os_error(
            sys::last_error().cast_signed(),
        ));
    }
    let mut out = [0u8; 4];
    let mut returned = 0u32;
    let ok = sys::device_io_control_out(handle, IOCTL_GET_AF, &mut out, &mut returned);
    let error = sys::last_error();
    // The handle came from open_device above and is closed exactly once.
    sys::close_handle(handle);
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
    if sys::enum_protocols_size(&mut length) != SOCKET_ERROR {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no vsock provider"));
    }
    let count = length as usize / size_of::<WSAPROTOCOL_INFOW>() + 1;
    let mut buffer: Vec<WSAPROTOCOL_INFOW> = vec![sys::empty_protocol_info(); count];
    let filled = sys::enum_protocols(&mut buffer);
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
    let started = sys::wsa_startup();
    if started != 0 {
        return Err(io::Error::from_raw_os_error(started));
    }
    let family = discover()?;
    let handle = sys::open_socket(i32::from(family), SOCK_STREAM, 0);
    if handle == INVALID_SOCKET {
        return Err(wsa_error());
    }
    let address = SockaddrVm {
        family,
        reserved: 0,
        port,
        cid: CID_ANY,
    };
    let bound = sys::bind_socket(handle, &address);
    if bound == SOCKET_ERROR || sys::listen_socket(handle, 64) == SOCKET_ERROR {
        let error = wsa_error();
        // Closed exactly once on this failure path.
        sys::close_socket(handle);
        return Err(error);
    }
    Ok(handle)
}

/// @cc [owner:ghuntley,label:security] windows-terminald-peer-cid
/// `accept` MUST return the peer CID the provider reports, asking again with
/// `getpeername` when the accept left it zero; an unknown peer stays CID 0,
/// which is never the host.
pub(crate) fn accept(listener: Listener) -> io::Result<(Conn, u32, u32)> {
    let mut peer = SockaddrVm {
        family: 0,
        reserved: 0,
        port: 0,
        cid: 0,
    };
    let connection = sys::accept_socket(listener, &mut peer);
    if connection == INVALID_SOCKET {
        return Err(wsa_error());
    }
    if peer.cid == 0 {
        sys::peer_name(connection, &mut peer);
    }
    Ok((connection, peer.cid, peer.port))
}
