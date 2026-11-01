//! Named mutexes.

use super::error::last_error;
use super::wide;
use std::io;
use std::ptr::null;
use windows_sys::Win32::Foundation::{
    CloseHandle, HANDLE, INVALID_HANDLE_VALUE, WAIT_ABANDONED, WAIT_OBJECT_0,
};
use windows_sys::Win32::System::Threading::{
    CreateMutexW, ReleaseMutex, WaitForSingleObject, INFINITE,
};

/// A held named mutex: released and closed exactly once on drop.
#[derive(Debug)]
pub struct NamedMutexGuard(HANDLE);

impl NamedMutexGuard {
    /// Open or create the mutex `name` and wait for it without a timeout. An
    /// abandoned mutex counts as acquired; any other wait result is
    /// `unavailable`.
    pub fn acquire(name: &str, unavailable: &'static str) -> io::Result<Self> {
        let name = wide(name);
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
            return Err(io::Error::other(unavailable));
        }
        Ok(Self(handle))
    }
}

impl Drop for NamedMutexGuard {
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
