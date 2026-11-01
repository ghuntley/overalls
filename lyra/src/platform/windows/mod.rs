//! Windows guest platform layer: virtio-vsock through the virtio-win `viosock`
//! provider, plus the small Win32 pieces the agents share.

pub mod accounts;
pub mod boot_id;
pub mod job;
pub mod log;
pub mod net;
pub mod services;
pub mod trust_store;
pub mod vsock;

pub use crate::sys::windows::error::last_error;

/// NUL-terminated UTF-16 for Win32 wide-string parameters.
pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}
