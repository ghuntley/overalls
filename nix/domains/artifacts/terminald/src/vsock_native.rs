//! ADR-0190 custom native-kernel socket ABI; stock kernels provide no transport.
#![cfg_attr(
    not(any(target_os = "freebsd", target_os = "illumos")),
    expect(
        dead_code,
        reason = "Linux compiles this module only for its address-layout tests"
    )
)]
use std::io;
use std::os::fd::RawFd;

#[cfg(target_os = "freebsd")]
pub(crate) const AF_VSOCK: i32 = 45;
#[cfg(not(target_os = "freebsd"))]
pub(crate) const AF_VSOCK: i32 = 40;
pub(crate) const CID_ANY: u32 = u32::MAX;
pub(crate) const CID_HOST: u32 = 2;
#[cfg(test)]
pub(crate) const CID_LOCAL: u32 = 1;
pub(crate) type Listener = RawFd;
const ADDRESS_BYTES: usize = 16;
/// `ADDRESS_BYTES` as a socket address length.
#[expect(
    clippy::cast_possible_truncation,
    reason = "ADDRESS_BYTES is 16, far below socklen_t::MAX"
)]
const ADDRESS_LENGTH: libc::socklen_t = ADDRESS_BYTES as libc::socklen_t;
/// `ADDRESS_BYTES` as the BSD sockaddr length byte.
#[cfg(any(target_os = "freebsd", test))]
#[expect(
    clippy::cast_possible_truncation,
    reason = "ADDRESS_BYTES is 16, far below u8::MAX"
)]
const BSD_LENGTH: u8 = ADDRESS_BYTES as u8;

#[repr(C)]
#[derive(Clone, Copy, Default)]
#[cfg(any(target_os = "freebsd", test))]
pub(crate) struct BsdAddress {
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
pub(crate) struct FlatAddress {
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
            length: BSD_LENGTH,
            family: 45,
            port,
            cid,
            ..Self::default()
        }
    }
    fn valid(&self) -> bool {
        self.length == BSD_LENGTH && self.family == 45
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
pub(crate) type SockaddrVm = BsdAddress;
#[cfg(not(target_os = "freebsd"))]
pub(crate) type SockaddrVm = FlatAddress;

/// @cc [owner:ghuntley,label:security;protocol] terminald-native-vsock-abi
/// Native listeners MUST use the same sixteen-byte ABI as Lyra: BSD length/
/// family45 on FreeBSD, flat family40 on illumos, and any-local CID. Descriptor
/// creation MUST be close-on-exec; compiling or listening MUST NOT establish
/// native transport acceptance or catalog admission.
pub(crate) fn listen(port: u32) -> io::Result<Listener> {
    // SAFETY: socket(2) takes integer arguments only and touches no memory.
    let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let address = SockaddrVm::new(CID_ANY, port);
    // SAFETY: bind(2) reads `ADDRESS_LENGTH` bytes from `address`, a live
    // repr(C) sixteen-byte native vsock address.
    if unsafe { libc::bind(fd, (&raw const address).cast(), ADDRESS_LENGTH) } != 0
        // SAFETY: listen(2) takes integer arguments only and touches no memory.
        || unsafe { libc::listen(fd, 64) } != 0
    {
        let error = io::Error::last_os_error();
        // SAFETY: close(2) touches no memory; this function owns `fd`, which
        // is never returned on this path.
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
pub(crate) fn accept(listener: Listener) -> io::Result<(RawFd, u32, u32)> {
    let mut peer = SockaddrVm::default();
    let mut length = ADDRESS_LENGTH;
    // SAFETY: accept4(2) writes at most `length` bytes to `peer`, a live
    // sixteen-byte repr(C) address, and updates `length`, a live local.
    let fd = unsafe {
        libc::accept4(
            listener,
            (&raw mut peer).cast(),
            &raw mut length,
            libc::SOCK_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != ADDRESS_BYTES || !peer.valid() {
        // SAFETY: close(2) touches no memory; the refused descriptor is owned
        // here and never returned.
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
pub(crate) fn address(cid: u32, port: u32) -> SockaddrVm {
    SockaddrVm::new(cid, port)
}

#[cfg(test)]
pub(crate) fn bound_port(listener: RawFd) -> io::Result<u32> {
    let mut address = SockaddrVm::default();
    let mut length = ADDRESS_LENGTH;
    // SAFETY: getsockname(2) writes at most `length` bytes to `address`, a live
    // sixteen-byte repr(C) address, and updates `length`, a live local.
    if unsafe { libc::getsockname(listener, (&raw mut address).cast(), &raw mut length) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != ADDRESS_BYTES || !address.valid() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(address.port)
}

#[cfg(test)]
pub(crate) fn available() -> bool {
    match listen(0) {
        Ok(fd) => {
            // SAFETY: close(2) touches no memory; `fd` is the probe listener
            // this function owns and never uses again.
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
        assert_eq!(size_of::<BsdAddress>(), ADDRESS_BYTES);
        assert_eq!(size_of::<FlatAddress>(), ADDRESS_BYTES);
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
