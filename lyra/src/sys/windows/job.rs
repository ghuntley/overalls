//! Job Object handles.

use super::error::last_error;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::windows::io::AsRawHandle;
use std::process::Child;
use std::ptr::null;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

/// One owned anonymous Job Object handle, closed exactly once on drop.
#[derive(Debug)]
pub struct JobHandle(HANDLE);

// SAFETY: a job handle may be used and closed from any thread.
unsafe impl Send for JobHandle {}

impl JobHandle {
    /// Create an anonymous job with default security.
    pub fn create() -> io::Result<Self> {
        // SAFETY: an anonymous job with default security.
        let handle = unsafe { CreateJobObjectW(null(), null()) };
        if handle.is_null() {
            return Err(last_error());
        }
        Ok(Self(handle))
    }

    /// Make closing the last handle terminate every process in the job.
    pub fn set_kill_on_close(&self) -> io::Result<()> {
        // SAFETY: zero is a valid bit pattern for the plain-data limit structure.
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the limit structure is a few hundred bytes"
        )]
        // SAFETY: the structure is passed with its exact size.
        let configured = unsafe {
            SetInformationJobObject(
                self.0,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        if configured == 0 {
            return Err(last_error());
        }
        Ok(())
    }

    /// Place `child` (and its later descendants) in the job.
    pub fn assign(&self, child: &Child) -> io::Result<()> {
        // SAFETY: the child's process handle is valid while `child` lives.
        if unsafe { AssignProcessToJobObject(self.0, child.as_raw_handle()) } == 0 {
            return Err(last_error());
        }
        Ok(())
    }

    /// End every process in the job.
    pub fn terminate(&self) {
        // SAFETY: terminating our own job handle.
        unsafe {
            TerminateJobObject(self.0, 1);
        }
    }
}

impl Drop for JobHandle {
    fn drop(&mut self) {
        // SAFETY: the job handle is closed exactly once; kill-on-close ends
        // anything still running in it.
        unsafe {
            CloseHandle(self.0);
        }
    }
}
