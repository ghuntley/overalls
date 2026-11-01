//! Service Control Manager handles.

use super::error::last_error;
use super::wide;
use std::io;
use std::mem::zeroed;
use std::ptr::null;
use windows_sys::Win32::System::Services::{
    CloseServiceHandle, OpenSCManagerW, OpenServiceW, QueryServiceStatus, SC_HANDLE,
    SC_MANAGER_CONNECT, SERVICE_QUERY_STATUS, SERVICE_STATUS,
};

/// One owned SCM or service handle, closed exactly once on drop.
#[derive(Debug)]
pub struct ScHandle(SC_HANDLE);

impl ScHandle {
    /// Connect to the local machine's active service database.
    pub fn connect_local() -> io::Result<Self> {
        // SAFETY: null machine and database select the local active database.
        let manager = unsafe { OpenSCManagerW(null(), null(), SC_MANAGER_CONNECT) };
        if manager.is_null() {
            return Err(last_error());
        }
        Ok(Self(manager))
    }

    /// Open the named service for status queries through this manager.
    pub fn open_service(&self, name: &str) -> io::Result<Self> {
        let wide_name = wide(name);
        // SAFETY: `wide_name` is NUL-terminated UTF-16 that outlives the call.
        let service = unsafe { OpenServiceW(self.0, wide_name.as_ptr(), SERVICE_QUERY_STATUS) };
        if service.is_null() {
            return Err(last_error());
        }
        Ok(Self(service))
    }

    /// The service's `dwCurrentState`.
    pub fn current_state(&self) -> io::Result<u32> {
        // SAFETY: SERVICE_STATUS is plain data that QueryServiceStatus fills.
        let mut status: SERVICE_STATUS = unsafe { zeroed() };
        // SAFETY: `status` is a writable SERVICE_STATUS.
        if unsafe { QueryServiceStatus(self.0, &raw mut status) } == 0 {
            return Err(last_error());
        }
        Ok(status.dwCurrentState)
    }
}

impl Drop for ScHandle {
    fn drop(&mut self) {
        // SAFETY: the handle came from the SCM and is closed exactly once.
        unsafe {
            CloseServiceHandle(self.0);
        }
    }
}
