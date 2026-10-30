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

use std::io;
use windows_sys::Win32::Foundation::GetLastError;

/// The thread's last Win32 error as an `io::Error`.
pub fn last_error() -> io::Error {
    // SAFETY: GetLastError has no preconditions.
    let code = unsafe { GetLastError() };
    io::Error::from_raw_os_error(code.cast_signed())
}

/// NUL-terminated UTF-16 for Win32 wide-string parameters.
pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}
