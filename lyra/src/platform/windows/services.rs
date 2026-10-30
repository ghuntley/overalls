//! Service Control Manager queries for the readiness probe.

use super::{last_error, wide};
use std::io;
use std::mem::zeroed;
use std::ptr::null;
use windows_sys::Win32::System::Services::{
    CloseServiceHandle, OpenSCManagerW, OpenServiceW, QueryServiceStatus, SC_HANDLE,
    SC_MANAGER_CONNECT, SERVICE_QUERY_STATUS, SERVICE_RUNNING, SERVICE_STATUS, SERVICE_STOPPED,
};

struct Handle(SC_HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: the handle came from the SCM and is closed exactly once.
        unsafe {
            CloseServiceHandle(self.0);
        }
    }
}

/// Whether the named Windows service is currently RUNNING. An unknown service
/// is an error, not `false`, so misspelt requirements are visible.
pub fn running(name: &str) -> io::Result<bool> {
    Ok(status(name)? == SERVICE_RUNNING)
}

/// Whether the service has fully stopped, including its listener process.
pub fn stopped(name: &str) -> io::Result<bool> {
    Ok(status(name)? == SERVICE_STOPPED)
}

fn status(name: &str) -> io::Result<u32> {
    // SAFETY: null machine and database select the local active database.
    let manager = unsafe { OpenSCManagerW(null(), null(), SC_MANAGER_CONNECT) };
    if manager.is_null() {
        return Err(last_error());
    }
    let manager = Handle(manager);
    let wide_name = wide(name);
    // SAFETY: `wide_name` is NUL-terminated UTF-16 that outlives the call.
    let service = unsafe { OpenServiceW(manager.0, wide_name.as_ptr(), SERVICE_QUERY_STATUS) };
    if service.is_null() {
        return Err(last_error());
    }
    let service = Handle(service);
    // SAFETY: SERVICE_STATUS is plain data that QueryServiceStatus fills.
    let mut status: SERVICE_STATUS = unsafe { zeroed() };
    // SAFETY: `status` is a writable SERVICE_STATUS.
    if unsafe { QueryServiceStatus(service.0, &raw mut status) } == 0 {
        return Err(last_error());
    }
    Ok(status.dwCurrentState)
}
