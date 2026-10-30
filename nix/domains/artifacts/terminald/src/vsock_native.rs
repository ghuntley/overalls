//! ADR-0190 custom native-kernel socket ABI; stock kernels provide no transport.
#![cfg_attr(
    not(any(target_os = "freebsd", target_os = "illumos")),
    allow(dead_code)
)]
use std::io;
use std::os::fd::RawFd;

#[cfg(target_os = "freebsd")]
pub const AF_VSOCK: i32 = 45;
#[cfg(not(target_os = "freebsd"))]
pub const AF_VSOCK: i32 = 40;
pub const CID_ANY: u32 = u32::MAX;
pub const CID_HOST: u32 = 2;
#[cfg(test)]
pub const CID_LOCAL: u32 = 1;
pub type Listener = RawFd;
const ADDRESS_BYTES: usize = 16;

#[repr(C)]
#[derive(Clone, Copy, Default)]
#[cfg(any(target_os = "freebsd", test))]
pub struct BsdAddress {
    length: u8,
    family: u8,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
#[cfg(any(not(target_os = "freebsd"), test))]
pub struct FlatAddress {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

trait Address: Default {
    fn new(cid: u32, port: u32) -> Self;
    fn valid(&self) -> bool;
}

#[cfg(any(target_os = "freebsd", test))]
impl Address for BsdAddress {
    fn new(cid: u32, port: u32) -> Self {
        Self {
            length: ADDRESS_BYTES as u8,
            family: 45,
            port,
            cid,
            ..Self::default()
        }
    }
    fn valid(&self) -> bool {
        self.length == ADDRESS_BYTES as u8 && self.family == 45
    }
}

#[cfg(any(not(target_os = "freebsd"), test))]
impl Address for FlatAddress {
    fn new(cid: u32, port: u32) -> Self {
        Self {
            family: 40,
            port,
            cid,
            ..Self::default()
        }
    }
    fn valid(&self) -> bool {
        self.family == 40
    }
}

#[cfg(target_os = "freebsd")]
pub type SockaddrVm = BsdAddress;
#[cfg(not(target_os = "freebsd"))]
pub type SockaddrVm = FlatAddress;

/// @cc [owner:ghuntley,label:security;protocol] terminald-native-vsock-abi
/// Native listeners MUST use the same sixteen-byte ABI as Lyra: BSD length/
/// family45 on FreeBSD, flat family40 on illumos, and any-local CID. Descriptor
/// creation MUST be close-on-exec; compiling or listening MUST NOT establish
/// native transport acceptance or catalog admission.
pub fn listen(port: u32) -> io::Result<Listener> {
    let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let address = SockaddrVm::new(CID_ANY, port);
    if unsafe {
        libc::bind(
            fd,
            (&raw const address).cast(),
            ADDRESS_BYTES as libc::socklen_t,
        )
    } != 0
        || unsafe { libc::listen(fd, 64) } != 0
    {
        let error = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(error);
    }
    Ok(fd)
}

/// @cc [owner:ghuntley,label:security] terminald-native-observed-peer
/// Accept MUST validate the returned address size and OS-specific family before
/// exposing the observed CID. The caller MUST reject any CID other than2 before
/// reading bytes; its existing boot-bound HELLO and session-token checks apply.
pub fn accept(listener: Listener) -> io::Result<(RawFd, u32, u32)> {
    let mut peer = SockaddrVm::default();
    let mut length = ADDRESS_BYTES as libc::socklen_t;
    let fd = unsafe {
        libc::accept4(
            listener,
            (&raw mut peer).cast(),
            &mut length,
            libc::SOCK_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != ADDRESS_BYTES || !peer.valid() {
        unsafe {
            libc::close(fd);
        }
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid native peer address",
        ));
    }
    Ok((fd, peer.cid, peer.port))
}

#[cfg(test)]
pub fn address(cid: u32, port: u32) -> SockaddrVm {
    SockaddrVm::new(cid, port)
}

#[cfg(test)]
pub fn bound_port(listener: RawFd) -> io::Result<u32> {
    let mut address = SockaddrVm::default();
    let mut length = ADDRESS_BYTES as libc::socklen_t;
    if unsafe { libc::getsockname(listener, (&raw mut address).cast(), &mut length) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != ADDRESS_BYTES || !address.valid() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(address.port)
}

#[cfg(test)]
pub fn available() -> bool {
    match listen(0) {
        Ok(fd) => {
            unsafe {
                libc::close(fd);
            }
            true
        }
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_layouts_match_native_kernel_contract_and_refuse_malformed_families() {
        assert_eq!(std::mem::size_of::<BsdAddress>(), ADDRESS_BYTES);
        assert_eq!(std::mem::size_of::<FlatAddress>(), ADDRESS_BYTES);
        assert_eq!(std::mem::offset_of!(BsdAddress, family), 1);
        assert_eq!(std::mem::offset_of!(BsdAddress, port), 4);
        assert_eq!(std::mem::offset_of!(FlatAddress, port), 4);
        let mut bsd = BsdAddress::new(CID_HOST, 1075);
        assert!(bsd.valid());
        bsd.length = 0;
        assert!(!bsd.valid());
        let mut flat = FlatAddress::new(CID_HOST, 1075);
        assert!(flat.valid());
        flat.family = 45;
        assert!(!flat.valid());
    }
}
