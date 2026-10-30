//! Per-boot identity for Windows guests (ADR-0171).
//!
//! Linux agents read `/proc/sys/kernel/random/boot_id`. Windows has no such
//! value, so the first agent of a boot generates a `UUIDv4` and keeps it in a
//! **volatile** registry key (`HKLM\SOFTWARE\Overalls\Boot`, value `BootId`):
//! stable for every process of this boot, gone at the next one. A named mutex
//! serialises the first generation so all agents agree.

use super::{last_error, wide};
use std::io;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_SUCCESS, INVALID_HANDLE_VALUE, WAIT_ABANDONED, WAIT_OBJECT_0,
};
use windows_sys::Win32::Security::Cryptography::{
    BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegQueryValueExW, RegSetValueExW, HKEY, HKEY_LOCAL_MACHINE,
    KEY_READ, KEY_WRITE, REG_OPTION_VOLATILE, REG_SZ,
};
use windows_sys::Win32::System::Threading::{
    CreateMutexW, ReleaseMutex, WaitForSingleObject, INFINITE,
};

const KEY: &str = "SOFTWARE\\Overalls\\Boot";
const VALUE: &str = "BootId";
const MUTEX: &str = "Global\\OverallsBootId";

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

/// A fresh lowercase `UUIDv4` from the system RNG.
pub fn generate() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    let length =
        u32::try_from(bytes.len()).map_err(|_| io::Error::other("system RNG unavailable"))?;
    // SAFETY: `bytes` is a writable 16-byte buffer; the system-preferred RNG
    // needs no algorithm handle.
    let status = unsafe {
        BCryptGenRandom(
            null_mut(),
            bytes.as_mut_ptr(),
            length,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status != 0 {
        return Err(io::Error::other("system RNG unavailable"));
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{}-{}-{}-{}-{}",
        hex::encode(&bytes[0..4]),
        hex::encode(&bytes[4..6]),
        hex::encode(&bytes[6..8]),
        hex::encode(&bytes[8..10]),
        hex::encode(&bytes[10..16])
    ))
}

struct Mutex(windows_sys::Win32::Foundation::HANDLE);

impl Mutex {
    fn acquire() -> io::Result<Self> {
        let name = wide(MUTEX);
        // SAFETY: `name` is NUL-terminated UTF-16 that outlives the call.
        let handle = unsafe { CreateMutexW(null(), 0, name.as_ptr()) };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(last_error());
        }
        // SAFETY: `handle` is a mutex this process owns a reference to.
        let waited = unsafe { WaitForSingleObject(handle, INFINITE) };
        if waited != WAIT_OBJECT_0 && waited != WAIT_ABANDONED {
            // SAFETY: the handle is closed exactly once.
            unsafe {
                CloseHandle(handle);
            }
            return Err(io::Error::other("boot identity mutex unavailable"));
        }
        Ok(Self(handle))
    }
}

impl Drop for Mutex {
    fn drop(&mut self) {
        // SAFETY: this process holds the mutex, released exactly once.
        unsafe {
            ReleaseMutex(self.0);
        }
        // SAFETY: the handle is owned by this guard and closed exactly once.
        unsafe {
            CloseHandle(self.0);
        }
    }
}

struct Key(HKEY);

impl Key {
    fn open_volatile() -> io::Result<Self> {
        let path = wide(KEY);
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

    fn read(&self) -> Option<String> {
        let name = wide(VALUE);
        let mut kind = 0u32;
        let mut buffer = [0u16; 64];
        let mut size = u32::try_from(size_of_val(&buffer)).ok()?;
        // SAFETY: `buffer` holds `size` writable bytes; `kind` and `size` are
        // writable outputs.
        let status = unsafe {
            RegQueryValueExW(
                self.0,
                name.as_ptr(),
                null(),
                &raw mut kind,
                buffer.as_mut_ptr().cast::<u8>(),
                &raw mut size,
            )
        };
        if status != ERROR_SUCCESS || kind != REG_SZ {
            return None;
        }
        let units = (size as usize / 2).min(buffer.len());
        let text = String::from_utf16_lossy(&buffer[..units]);
        let text = text.trim_end_matches('\0').to_owned();
        valid_uuid(&text).then_some(text)
    }

    fn write(&self, value: &str) -> io::Result<()> {
        let name = wide(VALUE);
        let data = wide(value);
        let bytes =
            u32::try_from(data.len() * 2).map_err(|_| io::Error::other("invalid boot ID"))?;
        // SAFETY: `data` is NUL-terminated UTF-16 of the stated byte length.
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

/// @cc [owner:ghuntley,label:security;recovery] windows-boot-id-volatile-once
/// `boot_id` MUST return the same lowercase `UUIDv4` to every process of one
/// Windows boot and a different one after a reboot: it lives only in a
/// volatile registry key, is generated at most once per boot under a named
/// mutex, and a malformed stored value is replaced rather than returned.
pub fn boot_id() -> io::Result<String> {
    let _guard = Mutex::acquire()?;
    let key = Key::open_volatile()?;
    if let Some(existing) = key.read() {
        return Ok(existing);
    }
    let fresh = generate()?;
    key.write(&fresh)?;
    Ok(fresh)
}

/// @cc [owner:ghuntley,label:recovery] windows-per-boot-marker
/// `C:\overalls\run` survives reboots and relocation, unlike Linux's `/run`, so
/// a run marker MUST name the boot that wrote it: `write_marker` stores this
/// boot's id and `marker_is_current` is true only when the marker holds exactly
/// that id. A marker from an earlier boot, an unreadable marker or an
/// unavailable boot id is not current.
pub fn marker_is_current(path: &std::path::Path) -> bool {
    match (std::fs::read_to_string(path), boot_id()) {
        (Ok(content), Ok(current)) => content.trim() == current,
        _ => false,
    }
}

/// Record that `path` was reached during this boot (see [`marker_is_current`]).
pub fn write_marker(path: &std::path::Path) -> io::Result<()> {
    std::fs::write(path, format!("{}\n", boot_id()?))
}
