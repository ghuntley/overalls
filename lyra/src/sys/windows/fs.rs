//! File moves through `MoveFileExW`.

use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Storage::FileSystem::MoveFileExW;

/// Move `source` to `target` with the `MOVEFILE_*` `flags`; `false` on
/// failure, with the reason in the thread's last error.
pub fn move_file(source: &Path, target: &Path, flags: u32) -> bool {
    let wide = |path: &Path| -> Vec<u16> {
        path.as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    };
    let (source, target) = (wide(source), wide(target));
    // SAFETY: both paths are NUL-terminated UTF-16 buffers alive for the call;
    // the flags are plain values.
    unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), flags) != 0 }
}
