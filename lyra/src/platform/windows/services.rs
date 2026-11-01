//! Service Control Manager queries for the readiness probe.

use crate::sys::windows::services::ScHandle;
use std::io;
use windows_sys::Win32::System::Services::{SERVICE_RUNNING, SERVICE_STOPPED};

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
    let manager = ScHandle::connect_local()?;
    let service = manager.open_service(name)?;
    service.current_state()
}
