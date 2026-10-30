use super::Pair;

#[repr(C)]
pub(crate) struct LibzfsHandle {
    _private: [u8; 0],
}

#[repr(C)]
pub(crate) struct Nvlist {
    _private: [u8; 0],
}

#[repr(C)]
pub(crate) struct Nvpair {
    _private: [u8; 0],
}

#[link(name = "zfs")]
unsafe extern "C" {
    pub(crate) fn libzfs_init() -> *mut LibzfsHandle;
    pub(crate) fn libzfs_fini(handle: *mut LibzfsHandle);
    pub(crate) fn libzfs_print_on_error(handle: *mut LibzfsHandle, show: libc::c_int);
    pub(crate) fn zfs_send_resume_token_to_nvlist(
        handle: *mut LibzfsHandle,
        token: *const libc::c_char,
    ) -> *mut Nvlist;
}

#[link(name = "nvpair")]
unsafe extern "C" {
    pub(crate) fn nvlist_free(list: *mut Nvlist);
    pub(crate) fn nvlist_next_nvpair(list: *mut Nvlist, previous: *mut Nvpair) -> *mut Nvpair;
    pub(crate) fn nvpair_name(pair: *mut Nvpair) -> *const libc::c_char;
    pub(crate) fn nvpair_value_string(
        pair: *mut Nvpair,
        value: *mut *const libc::c_char,
    ) -> libc::c_int;
    pub(crate) fn nvpair_value_uint64(pair: *mut Nvpair, value: *mut u64) -> libc::c_int;
    pub(crate) fn nvpair_type(pair: *mut Nvpair) -> libc::c_int;
}

/// libzfs handle with RAII teardown and print-on-error disabled.
pub(crate) struct Library(*mut LibzfsHandle);

impl Library {
    pub(crate) fn init() -> Option<Self> {
        // SAFETY: libzfs_init takes no arguments; null is checked below.
        let handle = unsafe { libzfs_init() };
        if handle.is_null() {
            None
        } else {
            // SAFETY: handle is the non-null handle libzfs_init just returned.
            unsafe { libzfs_print_on_error(handle, 0) };
            Some(Self(handle))
        }
    }

    pub(crate) fn decode_token(&self, token: &str) -> Option<NvlistBorrow<'_>> {
        let text = std::ffi::CString::new(token).ok()?;
        // SAFETY: self.0 is the live handle Library owns and text is a
        // NUL-terminated CString that outlives the call.
        let list = unsafe { zfs_send_resume_token_to_nvlist(self.0, text.as_ptr()) };
        if list.is_null() {
            None
        } else {
            Some(NvlistBorrow {
                list,
                _library: self,
            })
        }
    }
}

impl Drop for Library {
    fn drop(&mut self) {
        // SAFETY: self.0 is the owned non-null handle, released exactly once;
        // every NvlistBorrow borrows the Library, so its lists are freed first.
        unsafe { libzfs_fini(self.0) }
    }
}

/// A borrowed nvlist; disposed before the library on drop.
pub(crate) struct NvlistBorrow<'library> {
    list: *mut Nvlist,
    _library: &'library Library,
}

impl NvlistBorrow<'_> {
    pub(crate) fn pairs(&self) -> Vec<Pair> {
        let mut out = Vec::new();
        let mut previous: *mut Nvpair = std::ptr::null_mut();
        loop {
            // SAFETY: self.list is the live non-null list and previous is null
            // or the pair this list returned last.
            let pair = unsafe { nvlist_next_nvpair(self.list, previous) };
            if pair.is_null() {
                break;
            }
            // SAFETY: pair is a non-null pair of the live list.
            let name_c = unsafe { nvpair_name(pair) };
            if name_c.is_null() {
                break;
            }
            // SAFETY: name_c is a non-null NUL-terminated name owned by the live
            // list; it is copied before the next library call.
            let name = unsafe { std::ffi::CStr::from_ptr(name_c) }
                .to_string_lossy()
                .into_owned();
            // SAFETY: pair is a non-null pair of the live list.
            let entry = match unsafe { nvpair_type(pair) } {
                1 => Pair::Bool(name),
                9 => {
                    let mut text: *const libc::c_char = std::ptr::null();
                    // SAFETY: pair is a live string pair and text is a valid
                    // out pointer to a local.
                    match unsafe { nvpair_value_string(pair, &raw mut text) } {
                        0 if !text.is_null() => Pair::Str(
                            name,
                            // SAFETY: text is a non-null NUL-terminated value
                            // owned by the live list and copied immediately.
                            unsafe { std::ffi::CStr::from_ptr(text) }
                                .to_string_lossy()
                                .into_owned(),
                        ),
                        _ => Pair::Other(name, 9),
                    }
                }
                8 => {
                    let mut value = 0_u64;
                    // SAFETY: pair is a live uint64 pair and value is a valid
                    // out pointer to a local.
                    match unsafe { nvpair_value_uint64(pair, &raw mut value) } {
                        0 => Pair::Uint(name, value),
                        _ => Pair::Other(name, 8),
                    }
                }
                kind => Pair::Other(name, u32::try_from(kind).unwrap_or(u32::MAX)),
            };
            out.push(entry);
            previous = pair;
        }
        out
    }
}

impl Drop for NvlistBorrow<'_> {
    fn drop(&mut self) {
        // SAFETY: self.list is the owned non-null list, freed exactly once
        // while the borrowed Library is still alive.
        unsafe { nvlist_free(self.list) }
    }
}
