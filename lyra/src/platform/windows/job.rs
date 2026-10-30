//! Kill-on-close Job Objects: the Windows counterpart of a Unix process group
//! for helpers the agents start (ADR-0171).
//!
//! A child assigned to a job takes its descendants with it, so terminating the
//! job ends `git` and any `git-remote-https` it spawned, as `killpg` does on
//! Linux. Closing the last job handle also terminates whatever is left.
//! `std::process::Command` cannot start a child suspended, so assignment
//! follows the spawn: a grandchild started in that instant would escape the
//! job. Git and PowerShell start their helpers well after process start-up,
//! and this residual window is recorded in the ADR-0171 review.

use super::last_error;
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

/// One kill-on-close job holding a child process tree.
#[derive(Debug)]
pub struct Job(HANDLE);

// SAFETY: a job handle may be used and closed from any thread.
unsafe impl Send for Job {}

impl Job {
    /// @cc [owner:ghuntley,label:security;recovery] windows-job-owns-child-tree
    /// `attach` MUST place the child in a fresh kill-on-close job or fail
    /// without leaving the job open; `terminate` and dropping the job MUST end
    /// every process in it.
    pub fn attach(child: &Child) -> io::Result<Self> {
        // SAFETY: an anonymous job with default security.
        let handle = unsafe { CreateJobObjectW(null(), null()) };
        if handle.is_null() {
            return Err(last_error());
        }
        let job = Self(handle);
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
                job.0,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        if configured == 0 {
            return Err(last_error());
        }
        // SAFETY: the child's process handle is valid while `child` lives.
        if unsafe { AssignProcessToJobObject(job.0, child.as_raw_handle()) } == 0 {
            return Err(last_error());
        }
        Ok(job)
    }

    /// End every process in the job.
    pub fn terminate(&self) {
        // SAFETY: terminating our own job handle.
        unsafe {
            TerminateJobObject(self.0, 1);
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // SAFETY: the job handle is closed exactly once; kill-on-close ends
        // anything still running in it.
        unsafe {
            CloseHandle(self.0);
        }
    }
}
