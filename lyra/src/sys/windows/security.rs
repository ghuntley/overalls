//! File security descriptors from SDDL.

use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::Security::SetFileSecurityW;

/// Apply the security descriptor `sddl` (SDDL revision 1) to `path`, setting
/// the parts selected by the `*_SECURITY_INFORMATION` flags in `information`.
/// `false` when the SDDL does not parse or the file refuses the descriptor.
pub fn set_file_security_sddl(path: &Path, sddl: &str, information: u32) -> bool {
    let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let sddl: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    let mut descriptor = std::ptr::null_mut();
    // SAFETY: the SDDL buffer is NUL terminated and outlives the call; on
    // success the function stores a LocalAlloc descriptor in `descriptor`.
    let converted = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &raw mut descriptor,
            std::ptr::null_mut(),
        )
    };
    if converted == 0 {
        return false;
    }
    // SAFETY: the path buffer is NUL terminated and `descriptor` is the live
    // descriptor returned above; it is not freed until after this call.
    let success = unsafe { SetFileSecurityW(path.as_ptr(), information, descriptor) };
    // SAFETY: `descriptor` came from LocalAlloc via the conversion above and
    // is released exactly once here.
    unsafe { LocalFree(descriptor) };
    success != 0
}
