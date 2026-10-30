/// forgets the pointer.
pub(super) fn account_uid(name: &str) -> Option<u32> {
    let name = std::ffi::CString::new(name).ok()?;
    // SAFETY: name is a live NUL-terminated CString for the whole call.
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        None
    } else {
        // SAFETY: a non-null getpwnam result points to libc's static passwd
        // record, valid until the next getpw* call; the single-threaded
        // helper copies pw_uid out immediately and makes no such call between.
        Some(unsafe { *entry }.pw_uid)
    }
}
