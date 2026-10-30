use super::{Labels, Lookup};
use super::{
    ATTR_CONNLABELS, ATTR_L3PROTO, ATTR_L4PROTO, ATTR_ORIG_IPV4_DST, ATTR_ORIG_IPV4_SRC,
    ATTR_ORIG_PORT_DST, ATTR_ORIG_PORT_SRC, CONNTRACK_SUBSYSTEM,
};
use super::{CB_CONTINUE, CB_FAILURE};
use std::os::fd::RawFd;

#[repr(C)]
pub struct Handle {
    _private: [u8; 0],
}

#[repr(C)]
pub struct Ct {
    _private: [u8; 0],
}

#[repr(C)]
pub struct Bitmask {
    _private: [u8; 0],
}

type Callback = extern "C" fn(libc::c_int, *mut Ct, *mut libc::c_void) -> libc::c_int;

#[link(name = "netfilter_conntrack")]
unsafe extern "C" {
    pub fn nfct_open(subsys: u8, events: libc::c_uint) -> *mut Handle;
    pub fn nfct_close(handle: *mut Handle);
    pub fn nfct_new() -> *mut Ct;
    pub fn nfct_destroy(ct: *mut Ct);
    pub fn nfct_fd(handle: *const Handle) -> RawFd;
    pub fn nfct_set_attr_u8(ct: *mut Ct, attr: u8, value: u8);
    pub fn nfct_set_attr_u16(ct: *mut Ct, attr: u8, value: u16);
    pub fn nfct_set_attr_u32(ct: *mut Ct, attr: u8, value: u32);
    pub fn nfct_attr_is_set(ct: *const Ct, attr: u8) -> libc::c_int;
    pub fn nfct_get_attr_u8(ct: *mut Ct, attr: u8) -> u8;
    pub fn nfct_get_attr_u16(ct: *mut Ct, attr: u8) -> u16;
    pub fn nfct_get_attr_u32(ct: *mut Ct, attr: u8) -> u32;
    pub fn nfct_get_attr(ct: *mut Ct, attr: u8) -> *const Bitmask;
    pub fn nfct_bitmask_maxbit(bits: *const Bitmask) -> libc::c_int;
    pub fn nfct_bitmask_test_bit(bits: *const Bitmask, bit: libc::c_uint) -> libc::c_int;
    pub fn nfct_callback_register(
        handle: *mut Handle,
        message_type: libc::c_int,
        cb: Callback,
        data: *mut libc::c_void,
    ) -> libc::c_int;
    pub fn nfct_query(handle: *mut Handle, query: u32, ct: *mut Ct) -> libc::c_int;
}

pub(super) struct HandleRef(pub *mut Handle);

impl HandleRef {
    pub(super) fn fd(&self) -> RawFd {
        unsafe { nfct_fd(self.0) }
    }
}

impl Drop for HandleRef {
    fn drop(&mut self) {
        unsafe { nfct_close(self.0) }
    }
}

pub(super) struct CtRef(pub *mut Ct);

impl Drop for CtRef {
    fn drop(&mut self) {
        unsafe { nfct_destroy(self.0) }
    }
}

pub(super) fn open() -> Option<HandleRef> {
    let handle = unsafe { nfct_open(CONNTRACK_SUBSYSTEM, 0) };
    if handle.is_null() {
        None
    } else {
        Some(HandleRef(handle))
    }
}

pub(super) fn new_ct() -> Option<CtRef> {
    let ct = unsafe { nfct_new() };
    if ct.is_null() {
        None
    } else {
        Some(CtRef(ct))
    }
}

pub(super) fn set_query_tuple(ct: &mut CtRef, query: &super::Query) {
    unsafe {
        nfct_set_attr_u8(ct.0, ATTR_L3PROTO, libc::AF_INET as u8);
        nfct_set_attr_u8(ct.0, ATTR_L4PROTO, libc::IPPROTO_TCP as u8);
        nfct_set_attr_u32(ct.0, ATTR_ORIG_IPV4_SRC, query.source);
        nfct_set_attr_u32(ct.0, ATTR_ORIG_IPV4_DST, query.destination);
        nfct_set_attr_u16(ct.0, ATTR_ORIG_PORT_SRC, query.sport);
        nfct_set_attr_u16(ct.0, ATTR_ORIG_PORT_DST, query.dport);
    }
}

pub(super) fn register_get(
    handle: &mut HandleRef,
    callback: Callback,
    lookup: &mut Lookup,
) -> bool {
    let status = unsafe {
        nfct_callback_register(
            handle.0,
            super::NFCT_T_ALL,
            callback,
            lookup as *mut Lookup as *mut libc::c_void,
        )
    };
    status >= 0
}

pub(super) fn query_get(handle: &mut HandleRef, ct: &mut CtRef) -> bool {
    let result = unsafe { nfct_query(handle.0, super::NFCT_Q_GET, ct.0) };
    result >= 0
}

/// @cc [owner:ghuntley,label:security] native-flow-callback-confined
/// The C callback's pointer surface is confined here: the scalar reads map
/// into typed values before any policy decision; the write-out accumulates
/// into Labels only. No argument or network data flows elsewhere.
extern "C" fn collect(
    _message_type: libc::c_int,
    ct: *mut Ct,
    data: *mut libc::c_void,
) -> libc::c_int {
    let lookup = unsafe { &mut *(data as *mut Lookup) };
    lookup.count += 1;
    if lookup.count != 1 {
        return CB_FAILURE;
    }
    for attr in [
        ATTR_L3PROTO,
        ATTR_L4PROTO,
        ATTR_ORIG_IPV4_SRC,
        ATTR_ORIG_IPV4_DST,
        ATTR_ORIG_PORT_SRC,
        ATTR_ORIG_PORT_DST,
        ATTR_CONNLABELS,
    ] {
        if unsafe { nfct_attr_is_set(ct, attr) } != 1 {
            return CB_FAILURE;
        }
    }
    if unsafe { nfct_get_attr_u8(ct, ATTR_L3PROTO) } != libc::AF_INET as u8
        || unsafe { nfct_get_attr_u8(ct, ATTR_L4PROTO) } != libc::IPPROTO_TCP as u8
        || unsafe { nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_SRC) } != lookup.query.source
        || unsafe { nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_DST) } != lookup.query.destination
        || unsafe { nfct_get_attr_u16(ct, ATTR_ORIG_PORT_SRC) } != lookup.query.sport
        || unsafe { nfct_get_attr_u16(ct, ATTR_ORIG_PORT_DST) } != lookup.query.dport
    {
        return CB_FAILURE;
    }
    let bits = unsafe { nfct_get_attr(ct, ATTR_CONNLABELS) };
    if bits.is_null() {
        return CB_FAILURE;
    }
    if unsafe { nfct_bitmask_maxbit(bits) } < 127
        || unsafe { nfct_bitmask_test_bit(bits, 127) } != 1
    {
        return CB_FAILURE;
    }
    let mut label = Labels::zero();
    for bit in 0..128_u32 {
        if unsafe { nfct_bitmask_test_bit(bits, bit) } == 1 {
            label.set(bit);
        }
    }
    lookup.label = Some(label);
    CB_CONTINUE
}

pub(super) const COLLECT: Callback = collect;

/// fd 0/1/2-clone for setsockopt works through raw numbers; routing the
/// handle-borrowed descriptor through the typed sockopt call keeps the
/// lifetime with the netlink handle.
pub(super) fn set_recv_timeout(handle: &HandleRef, seconds: u64) -> Result<(), rustix::io::Errno> {
    let fd = handle.fd();
    if fd < 0 {
        return Err(rustix::io::Errno::BADF);
    }
    let borrowed = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) };
    rustix::net::sockopt::set_socket_timeout(
        borrowed,
        rustix::net::sockopt::Timeout::Recv,
        Some(std::time::Duration::from_secs(seconds)),
    )
}
