use super::{Labels, Lookup};
use super::{
    ATTR_CONNLABELS, ATTR_L3PROTO, ATTR_L4PROTO, ATTR_ORIG_IPV4_DST, ATTR_ORIG_IPV4_SRC,
    ATTR_ORIG_PORT_DST, ATTR_ORIG_PORT_SRC, CONNTRACK_SUBSYSTEM,
};
use super::{CB_CONTINUE, CB_FAILURE};
use std::os::fd::RawFd;

#[repr(C)]
pub(crate) struct Handle {
    _private: [u8; 0],
}

#[repr(C)]
pub(crate) struct Ct {
    _private: [u8; 0],
}

#[repr(C)]
pub(crate) struct Bitmask {
    _private: [u8; 0],
}

type Callback = extern "C" fn(libc::c_int, *mut Ct, *mut libc::c_void) -> libc::c_int;

#[link(name = "netfilter_conntrack")]
unsafe extern "C" {
    pub(crate) fn nfct_open(subsys: u8, events: libc::c_uint) -> *mut Handle;
    pub(crate) fn nfct_close(handle: *mut Handle);
    pub(crate) fn nfct_new() -> *mut Ct;
    pub(crate) fn nfct_destroy(ct: *mut Ct);
    pub(crate) fn nfct_fd(handle: *const Handle) -> RawFd;
    pub(crate) fn nfct_set_attr_u8(ct: *mut Ct, attr: u8, value: u8);
    pub(crate) fn nfct_set_attr_u16(ct: *mut Ct, attr: u8, value: u16);
    pub(crate) fn nfct_set_attr_u32(ct: *mut Ct, attr: u8, value: u32);
    pub(crate) fn nfct_attr_is_set(ct: *const Ct, attr: u8) -> libc::c_int;
    pub(crate) fn nfct_get_attr_u8(ct: *mut Ct, attr: u8) -> u8;
    pub(crate) fn nfct_get_attr_u16(ct: *mut Ct, attr: u8) -> u16;
    pub(crate) fn nfct_get_attr_u32(ct: *mut Ct, attr: u8) -> u32;
    pub(crate) fn nfct_get_attr(ct: *mut Ct, attr: u8) -> *const Bitmask;
    pub(crate) fn nfct_bitmask_maxbit(bits: *const Bitmask) -> libc::c_int;
    pub(crate) fn nfct_bitmask_test_bit(bits: *const Bitmask, bit: libc::c_uint) -> libc::c_int;
    pub(crate) fn nfct_callback_register(
        handle: *mut Handle,
        message_type: libc::c_int,
        cb: Callback,
        data: *mut libc::c_void,
    ) -> libc::c_int;
    pub(crate) fn nfct_query(handle: *mut Handle, query: u32, ct: *mut Ct) -> libc::c_int;
}

pub(super) struct HandleRef(pub *mut Handle);

impl HandleRef {
    pub(super) fn fd(&self) -> RawFd {
        // SAFETY: self.0 is the non-null handle nfct_open returned; HandleRef
        // owns it and closes it only on drop.
        unsafe { nfct_fd(self.0) }
    }
}

impl Drop for HandleRef {
    fn drop(&mut self) {
        // SAFETY: self.0 is the owned non-null handle, closed exactly once here.
        unsafe { nfct_close(self.0) }
    }
}

pub(super) struct CtRef(pub *mut Ct);

impl Drop for CtRef {
    fn drop(&mut self) {
        // SAFETY: self.0 is the owned non-null ct from nfct_new, destroyed
        // exactly once here.
        unsafe { nfct_destroy(self.0) }
    }
}

pub(super) fn open() -> Option<HandleRef> {
    // SAFETY: nfct_open takes two integers and no pointers; a null result is
    // checked before use.
    let handle = unsafe { nfct_open(CONNTRACK_SUBSYSTEM, 0) };
    if handle.is_null() {
        None
    } else {
        Some(HandleRef(handle))
    }
}

pub(super) fn new_ct() -> Option<CtRef> {
    // SAFETY: nfct_new takes no arguments; a null result is checked before use.
    let ct = unsafe { nfct_new() };
    if ct.is_null() {
        None
    } else {
        Some(CtRef(ct))
    }
}

#[expect(
    clippy::cast_possible_truncation,
    reason = "AF_INET is 2 and IPPROTO_TCP is 6, both fit in u8"
)]
pub(super) fn set_query_tuple(ct: &mut CtRef, query: &super::Query) {
    // SAFETY: ct.0 is the live non-null ct CtRef owns; the arguments are integers.
    unsafe { nfct_set_attr_u8(ct.0, ATTR_L3PROTO, libc::AF_INET as u8) };
    // SAFETY: ct.0 is the live non-null ct CtRef owns; the arguments are integers.
    unsafe { nfct_set_attr_u8(ct.0, ATTR_L4PROTO, libc::IPPROTO_TCP as u8) };
    // SAFETY: ct.0 is the live non-null ct CtRef owns; the arguments are integers.
    unsafe { nfct_set_attr_u32(ct.0, ATTR_ORIG_IPV4_SRC, query.source) };
    // SAFETY: ct.0 is the live non-null ct CtRef owns; the arguments are integers.
    unsafe { nfct_set_attr_u32(ct.0, ATTR_ORIG_IPV4_DST, query.destination) };
    // SAFETY: ct.0 is the live non-null ct CtRef owns; the arguments are integers.
    unsafe { nfct_set_attr_u16(ct.0, ATTR_ORIG_PORT_SRC, query.sport) };
    // SAFETY: ct.0 is the live non-null ct CtRef owns; the arguments are integers.
    unsafe { nfct_set_attr_u16(ct.0, ATTR_ORIG_PORT_DST, query.dport) };
}

pub(super) fn register_get(
    handle: &mut HandleRef,
    callback: Callback,
    lookup: &mut Lookup,
) -> bool {
    // SAFETY: handle.0 is the live handle. The registered pointer is the
    // caller's exclusive &mut Lookup; the library dereferences it only from
    // collect during nfct_query, which `lookup` runs while that Lookup lives
    // and is not otherwise accessed.
    let status = unsafe {
        nfct_callback_register(
            handle.0,
            super::NFCT_T_ALL,
            callback,
            std::ptr::from_mut::<Lookup>(lookup).cast::<libc::c_void>(),
        )
    };
    status >= 0
}

pub(super) fn query_get(handle: &mut HandleRef, ct: &mut CtRef) -> bool {
    // SAFETY: handle.0 and ct.0 are the live non-null objects their owners
    // hold for the duration of the call.
    let result = unsafe { nfct_query(handle.0, super::NFCT_Q_GET, ct.0) };
    result >= 0
}

/// @cc [owner:ghuntley,label:security] native-flow-callback-confined
/// The C callback's pointer surface is confined here: the scalar reads map
/// into typed values before any policy decision; the write-out accumulates
/// into Labels only. No argument or network data flows elsewhere.
#[expect(
    clippy::cast_possible_truncation,
    reason = "AF_INET is 2 and IPPROTO_TCP is 6, both fit in u8"
)]
extern "C" fn collect(
    _message_type: libc::c_int,
    ct: *mut Ct,
    data: *mut libc::c_void,
) -> libc::c_int {
    // SAFETY: data is the &mut Lookup register_get registered; nfct_query
    // calls back synchronously while that Lookup is live and unaliased.
    let lookup = unsafe { &mut *data.cast::<Lookup>() };
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
        // SAFETY: ct is the library's ct, valid for this callback.
        if unsafe { nfct_attr_is_set(ct, attr) } != 1 {
            return CB_FAILURE;
        }
    }
    // SAFETY: ct is valid for this callback and the attribute is set.
    if unsafe { nfct_get_attr_u8(ct, ATTR_L3PROTO) } != libc::AF_INET as u8
        // SAFETY: ct is valid for this callback and the attribute is set.
        || unsafe { nfct_get_attr_u8(ct, ATTR_L4PROTO) } != libc::IPPROTO_TCP as u8
        // SAFETY: ct is valid for this callback and the attribute is set.
        || unsafe { nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_SRC) } != lookup.query.source
        // SAFETY: ct is valid for this callback and the attribute is set.
        || unsafe { nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_DST) } != lookup.query.destination
        // SAFETY: ct is valid for this callback and the attribute is set.
        || unsafe { nfct_get_attr_u16(ct, ATTR_ORIG_PORT_SRC) } != lookup.query.sport
        // SAFETY: ct is valid for this callback and the attribute is set.
        || unsafe { nfct_get_attr_u16(ct, ATTR_ORIG_PORT_DST) } != lookup.query.dport
    {
        return CB_FAILURE;
    }
    // SAFETY: ct is valid for this callback; the returned bitmask belongs to
    // ct and is null-checked before use.
    let bits = unsafe { nfct_get_attr(ct, ATTR_CONNLABELS) };
    if bits.is_null() {
        return CB_FAILURE;
    }
    // SAFETY: bits is the non-null bitmask ct owns for this callback.
    if unsafe { nfct_bitmask_maxbit(bits) } < 127
        // SAFETY: bits is non-null and its maxbit is at least 127.
        || unsafe { nfct_bitmask_test_bit(bits, 127) } != 1
    {
        return CB_FAILURE;
    }
    let mut label = Labels::zero();
    for bit in 0..128_u32 {
        // SAFETY: bits is non-null and bit is at most 127, within its maxbit.
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
    // SAFETY: fd is nonnegative and owned by the netlink handle, which the
    // caller's borrow keeps open for the whole sockopt call.
    let borrowed = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) };
    rustix::net::sockopt::set_socket_timeout(
        borrowed,
        rustix::net::sockopt::Timeout::Recv,
        Some(std::time::Duration::from_secs(seconds)),
    )
}
