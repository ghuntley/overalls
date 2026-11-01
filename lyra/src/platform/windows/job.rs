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

use crate::sys::windows::job::JobHandle;
use std::io;
use std::process::Child;

/// One kill-on-close job holding a child process tree.
#[derive(Debug)]
pub struct Job(JobHandle);

impl Job {
    /// @cc [owner:ghuntley,label:security;recovery] windows-job-owns-child-tree
    /// `attach` MUST place the child in a fresh kill-on-close job or fail
    /// without leaving the job open; `terminate` and dropping the job MUST end
    /// every process in it.
    pub fn attach(child: &Child) -> io::Result<Self> {
        let job = Self(JobHandle::create()?);
        job.0.set_kill_on_close()?;
        job.0.assign(child)?;
        Ok(job)
    }

    /// End every process in the job.
    pub fn terminate(&self) {
        self.0.terminate();
    }
}
