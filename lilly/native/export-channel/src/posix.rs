/// forgets the pointer.
pub(super) fn account_uid(name: &str) -> Option<u32> {
    let name = std::ffi::CString::new(name).ok()?;
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        None
    } else {
        Some(unsafe { *entry }.pw_uid)
    }
}
