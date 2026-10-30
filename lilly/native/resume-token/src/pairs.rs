use super::*;

#[repr(C)]
pub struct LibzfsHandle {
    _private: [u8; 0],
}

#[repr(C)]
pub struct Nvlist {
    _private: [u8; 0],
}

#[repr(C)]
pub struct Nvpair {
    _private: [u8; 0],
}

#[link(name = "zfs")]
unsafe extern "C" {
    pub fn libzfs_init() -> *mut LibzfsHandle;
    pub fn libzfs_fini(handle: *mut LibzfsHandle);
    pub fn libzfs_print_on_error(handle: *mut LibzfsHandle, show: libc::c_int);
    pub fn zfs_send_resume_token_to_nvlist(
        handle: *mut LibzfsHandle,
        token: *const libc::c_char,
    ) -> *mut Nvlist;
}

#[link(name = "nvpair")]
unsafe extern "C" {
    pub fn nvlist_free(list: *mut Nvlist);
    pub fn nvlist_next_nvpair(list: *mut Nvlist, previous: *mut Nvpair) -> *mut Nvpair;
    pub fn nvpair_name(pair: *mut Nvpair) -> *const libc::c_char;
    pub fn nvpair_value_string(pair: *mut Nvpair, value: *mut *const libc::c_char) -> libc::c_int;
    pub fn nvpair_value_uint64(pair: *mut Nvpair, value: *mut u64) -> libc::c_int;
    pub fn nvpair_type(pair: *mut Nvpair) -> libc::c_int;
}

/// libzfs handle with RAII teardown and print-on-error disabled.
pub struct Library(*mut LibzfsHandle);

impl Library {
    pub fn init() -> Option<Self> {
        let handle = unsafe { libzfs_init() };
        if handle.is_null() {
            None
        } else {
            unsafe { libzfs_print_on_error(handle, 0) };
            Some(Self(handle))
        }
    }

    pub fn decode_token(&self, token: &str) -> Option<NvlistBorrow<'_>> {
        let text = std::ffi::CString::new(token).ok()?;
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
        unsafe { libzfs_fini(self.0) }
    }
}

/// A borrowed nvlist; disposed before the library on drop.
pub struct NvlistBorrow<'library> {
    list: *mut Nvlist,
    _library: &'library Library,
}

impl NvlistBorrow<'_> {
    pub fn pairs(&self) -> Vec<Pair> {
        let mut out = Vec::new();
        let mut previous: *mut Nvpair = std::ptr::null_mut();
        loop {
            let pair = unsafe { nvlist_next_nvpair(self.list, previous) };
            if pair.is_null() {
                break;
            }
            let name_c = unsafe { nvpair_name(pair) };
            if name_c.is_null() {
                break;
            }
            let name = unsafe { std::ffi::CStr::from_ptr(name_c) }
                .to_string_lossy()
                .into_owned();
            let entry = match unsafe { nvpair_type(pair) } {
                1 => Pair::Bool(name),
                9 => {
                    let mut text: *const libc::c_char = std::ptr::null();
                    match unsafe { nvpair_value_string(pair, &mut text) } {
                        0 if !text.is_null() => Pair::Str(
                            name,
                            unsafe { std::ffi::CStr::from_ptr(text) }
                                .to_string_lossy()
                                .into_owned(),
                        ),
                        _ => Pair::Other(name, 9),
                    }
                }
                8 => {
                    let mut value = 0_u64;
                    match unsafe { nvpair_value_uint64(pair, &mut value) } {
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
        unsafe { nvlist_free(self.list) }
    }
}
