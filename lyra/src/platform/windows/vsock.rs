//! `AF_VSOCK` on Windows through the virtio-win `viosock` driver and its Winsock
//! provider (ADR-0171).
//!
//! Windows has no `AF_VSOCK` constant: the provider registers a dynamic
//! address family, exposed through the `\\.\Viosock` control device and the
//! Winsock catalog. Everything here discovers it at runtime and never assumes
//! a number. `SOCKADDR_VM` is 12 bytes in host byte order.

use crate::sys::windows::winsock::{self, SockaddrVm, Socket};
use std::io::{self, Read, Write};
use std::time::{Duration, Instant};
use windows_sys::Win32::Networking::WinSock::{SO_RCVTIMEO, SO_SNDTIMEO};

/// The host side of every Firecracker vsock connection.
pub const HOST_CID: u32 = 2;
const VMADDR_CID_ANY: u32 = 0xFFFF_FFFF;
/// viosock control device and its "get address family" request.
const DEVICE: &str = "\\\\.\\Viosock";
const IOCTL_GET_AF: u32 = 0x0801_300C;

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

/// Initialise Winsock 2.2 for this process; idempotent per call site.
pub fn startup() -> io::Result<()> {
    winsock::startup()
}

fn ioctl_family() -> io::Result<u16> {
    let (out, returned) = winsock::device_ioctl_out4(DEVICE, IOCTL_GET_AF)?;
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
    Ok(winsock::protocols()?
        .iter()
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
    socket: Socket,
    pub family: Family,
    pub port: u32,
}

/// An accepted connection with its peer identity.
#[derive(Debug)]
pub struct Connection {
    socket: Socket,
    pub peer_cid: u32,
    pub peer_port: u32,
}

impl Listener {
    /// @cc [owner:ghuntley,label:security] windows-vsock-listener-any-cid
    /// bind MUST use the discovered family, the requested port and
    /// `VMADDR_CID_ANY`, and MUST fail (closing the socket) rather than listen
    /// on a different port or family when bind or listen refuses.
    pub fn bind(family: Family, port: u32, backlog: i32) -> io::Result<Self> {
        let socket = Socket::stream(i32::from(family.number))?;
        let address = SockaddrVm {
            family: family.number,
            reserved: 0,
            port,
            cid: VMADDR_CID_ANY,
        };
        socket.bind_vm(&address)?;
        socket.listen(backlog)?;
        Ok(Self {
            socket,
            family,
            port,
        })
    }

    /// Block for the next connection; `timeout` bounds its reads and writes.
    pub fn accept(&self, timeout: Duration) -> io::Result<Connection> {
        let (connection, mut peer) = self.socket.accept_vm()?;
        let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            connection.set_dword_option(option, millis);
        }
        if peer.cid == 0 {
            // Some accepts complete before the provider fills the peer address;
            // ask for it once more. An unknown peer is reported as CID 0 and is
            // never the host.
            connection.peer_vm(&mut peer);
        }
        Ok(Connection {
            socket: connection,
            peer_cid: peer.cid,
            peer_port: peer.port,
        })
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
        self.socket.recv(buf)
    }
}

impl Write for Connection {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.socket.send(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
