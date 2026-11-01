//! Win32 shims for the Windows guest platform layer and the shared modules.
//!
//! Each submodule wraps one Win32 area. Handle types close themselves exactly
//! once on drop, and every buffer length handed to Win32 is derived from (or
//! clamped to) the Rust slice it describes.

pub mod error;
pub mod fs;
pub mod iphlp;
pub mod job;
pub mod net_api;
pub mod registry;
pub mod security;
pub mod services;
pub mod sync;
pub mod trust;
pub mod winsock;

/// The byte size of `units` UTF-16 units as a Win32 `DWORD`, saturating to the
/// largest even value: understating a buffer's capacity is always safe.
fn byte_capacity(units: &[u16]) -> u32 {
    u32::try_from(size_of_val(units)).unwrap_or(u32::MAX - 1)
}

/// NUL-terminated UTF-16 for Win32 wide-string parameters.
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}
