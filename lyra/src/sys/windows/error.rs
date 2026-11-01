//! The thread's last Win32 error and the system RNG.

use std::io;
use windows_sys::Win32::Foundation::GetLastError;
use windows_sys::Win32::Security::Cryptography::{
    BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
};

/// The thread's last Win32 error as an `io::Error`.
pub fn last_error() -> io::Error {
    // SAFETY: GetLastError has no preconditions.
    let code = unsafe { GetLastError() };
    io::Error::from_raw_os_error(code.cast_signed())
}

/// Fill `buffer` from the system-preferred RNG; `false` when the RNG fails or
/// the buffer is longer than one request can describe.
pub fn system_random(buffer: &mut [u8]) -> bool {
    let Ok(length) = u32::try_from(buffer.len()) else {
        return false;
    };
    // SAFETY: `buffer` is writable for `length` bytes; the system-preferred
    // RNG needs no algorithm handle.
    let status = unsafe {
        BCryptGenRandom(
            std::ptr::null_mut(),
            buffer.as_mut_ptr(),
            length,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    status == 0
}
