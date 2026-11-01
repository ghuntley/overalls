//! Registry keys and values under `HKEY_LOCAL_MACHINE`.

use super::{byte_capacity, wide};
use std::io;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegGetValueW, RegQueryValueExW, RegSetValueExW, HKEY,
    HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE, REG_OPTION_VOLATILE, REG_SZ, RRF_RT_REG_EXPAND_SZ,
    RRF_RT_REG_SZ,
};

/// Read the string value `field` of `HKLM\key` into `buffer`, expanding
/// `REG_EXPAND_SZ`. `bytes` holds the capacity offered (clamped to the
/// buffer's real size) and receives the value's byte length. Returns the
/// Win32 status, zero on success.
pub fn local_machine_string(key: &str, field: &str, buffer: &mut [u16], bytes: &mut u32) -> u32 {
    let key = wide(key);
    let field = wide(field);
    *bytes = (*bytes).min(byte_capacity(buffer));
    // SAFETY: the writable UTF-16 buffer has at least `bytes` bytes of
    // capacity (clamped above); key and field are NUL-terminated.
    unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            key.as_ptr(),
            field.as_ptr(),
            RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ,
            null_mut(),
            buffer.as_mut_ptr().cast(),
            bytes,
        )
    }
}

/// One open registry key, closed exactly once on drop.
#[derive(Debug)]
pub struct Key(HKEY);

impl Key {
    /// Open or create the volatile key `HKLM\path` for reading and writing.
    /// A volatile key vanishes at the next reboot.
    pub fn create_volatile_local_machine(path: &str) -> io::Result<Self> {
        let path = wide(path);
        let mut key: HKEY = null_mut();
        let mut disposition = 0u32;
        // SAFETY: `path` is NUL-terminated UTF-16; `key` and `disposition` are
        // writable outputs; the volatile option makes the key vanish at reboot.
        let status = unsafe {
            RegCreateKeyExW(
                HKEY_LOCAL_MACHINE,
                path.as_ptr(),
                0,
                null(),
                REG_OPTION_VOLATILE,
                KEY_READ | KEY_WRITE,
                null(),
                &raw mut key,
                &raw mut disposition,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(io::Error::from_raw_os_error(status.cast_signed()));
        }
        Ok(Self(key))
    }

    /// Read value `name` into `buffer`. `size` holds the capacity offered
    /// (clamped to the buffer's real size) and receives the value's byte
    /// length. Returns the value's type, or `None` when the query fails.
    pub fn query(&self, name: &str, buffer: &mut [u16], size: &mut u32) -> Option<u32> {
        let name = wide(name);
        let mut kind = 0u32;
        *size = (*size).min(byte_capacity(buffer));
        // SAFETY: `buffer` holds at least `size` writable bytes (clamped
        // above); `kind` and `size` are writable outputs.
        let status = unsafe {
            RegQueryValueExW(
                self.0,
                name.as_ptr(),
                null(),
                &raw mut kind,
                buffer.as_mut_ptr().cast::<u8>(),
                size,
            )
        };
        (status == ERROR_SUCCESS).then_some(kind)
    }

    /// Store the first `bytes` bytes of `data` (clamped to its real size) as
    /// the `REG_SZ` value `name`; `data` should end with a NUL unit.
    pub fn set_string(&self, name: &str, data: &[u16], bytes: u32) -> io::Result<()> {
        let name = wide(name);
        let bytes = bytes.min(byte_capacity(data));
        // SAFETY: `data` is readable for `bytes` bytes (clamped above) and
        // `name` is NUL-terminated.
        let status = unsafe {
            RegSetValueExW(
                self.0,
                name.as_ptr(),
                0,
                REG_SZ,
                data.as_ptr().cast::<u8>(),
                bytes,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(io::Error::from_raw_os_error(status.cast_signed()));
        }
        Ok(())
    }
}

impl Drop for Key {
    fn drop(&mut self) {
        // SAFETY: the key handle is closed exactly once.
        unsafe {
            RegCloseKey(self.0);
        }
    }
}
