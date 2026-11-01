//! Process observation, prior-worker recovery and peer identity.

use super::account::{process_token, token_sid};
use super::{JOB_OBJECT_QUERY, KERNEL_PARENTS, PROCESS_LIST_LIMIT, owned, raw, wide};
use crate::Refusal;
use crate::windows_model::{
    CustodianGeneration, LocalPath, PipePeer, PriorWorker, ProcessIdentity, ProcessObservation,
    TokenObservation, WorkerIdentity,
};
use std::mem::{size_of, zeroed};
use std::os::windows::io::OwnedHandle;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::{
    ERROR_FILE_NOT_FOUND, ERROR_INVALID_PARAMETER, ERROR_NO_MORE_FILES, FILETIME, GetLastError,
    SetLastError, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::TOKEN_QUERY;
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::JobObjects::{IsProcessInJob, OpenJobObjectW};
use windows_sys::Win32::System::Threading::{
    GetProcessId, GetProcessTimes, OpenProcess, OpenProcessToken,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    QueryFullProcessImageNameW, TerminateProcess, WaitForSingleObject,
};

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-prior-job-absence
/// A prior generation's exact job name MUST be reported present whenever it
/// opens, and absent only on `ERROR_FILE_NOT_FOUND`. Any other failure MUST
/// refuse. The probe MUST NOT retain, adopt, terminate or modify that job.
pub fn prior_job_present(
    identity: &WorkerIdentity,
    generation: CustodianGeneration,
) -> Result<bool, Refusal> {
    job_name_present(&identity.job_name(generation))
}

pub(super) fn job_name_present(name: &str) -> Result<bool, Refusal> {
    let name = wide(name);
    // SAFETY: SetLastError only writes this thread's last-error value.
    unsafe {
        SetLastError(0);
    }
    // SAFETY: `name` is a live NUL-terminated UTF-16 job name.
    let handle = unsafe { OpenJobObjectW(JOB_OBJECT_QUERY, 0, name.as_ptr()) };
    if !handle.is_null() {
        drop(owned(handle, Refusal::Custody)?);
        return Ok(true);
    }
    // SAFETY: GetLastError only reads this thread's last-error value.
    if unsafe { GetLastError() } == ERROR_FILE_NOT_FOUND {
        Ok(false)
    } else {
        Err(Refusal::Custody)
    }
}

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-process-observation
/// Recovery MUST observe one complete bounded kernel process snapshot. Each
/// entry is opened with query/synchronize rights only; an exited entry, an
/// unopenable kernel-parented entry, a readable token and its exact kernel
/// creation identity are the only facts reported. Every other failure MUST be
/// reported as unobservable/unreadable, and snapshot failure MUST refuse.
pub fn observe_processes() -> Result<Vec<ProcessObservation>, Refusal> {
    let entry_size = u32::try_from(size_of::<PROCESSENTRY32W>()).map_err(|_| Refusal::Custody)?;
    let snapshot = owned(
        // SAFETY: CreateToolhelp32Snapshot takes only integer arguments.
        unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) },
        Refusal::Custody,
    )?;
    // SAFETY: PROCESSENTRY32W is a plain C struct for which all-zero bytes are a valid value.
    let mut entry: PROCESSENTRY32W = unsafe { zeroed() };
    entry.dwSize = entry_size;
    // SAFETY: the snapshot handle is owned and open, and `entry` is a live writable local with dwSize set.
    if unsafe { Process32FirstW(raw(&snapshot), &raw mut entry) } == 0 {
        return Err(Refusal::Custody);
    }
    let mut observations = Vec::new();
    loop {
        if observations.len() >= PROCESS_LIST_LIMIT {
            return Err(Refusal::Capacity);
        }
        observations.push(observe_process(
            entry.th32ProcessID,
            entry.th32ParentProcessID,
        ));
        // SAFETY: PROCESSENTRY32W is a plain C struct for which all-zero bytes are a valid value.
        entry = unsafe { zeroed() };
        entry.dwSize = entry_size;
        // SAFETY: the snapshot handle is owned and open, and `entry` is a live writable local with dwSize set.
        if unsafe { Process32NextW(raw(&snapshot), &raw mut entry) } == 0 {
            // Only normal end-of-list completes the snapshot.
            // SAFETY: GetLastError only reads this thread's last-error value.
            return if unsafe { GetLastError() } == ERROR_NO_MORE_FILES {
                Ok(observations)
            } else {
                Err(Refusal::Custody)
            };
        }
    }
}

fn observe_process(pid: u32, parent: u32) -> ProcessObservation {
    if KERNEL_PARENTS.contains(&pid) {
        return ProcessObservation::KernelCreated;
    }
    // SAFETY: SetLastError only writes this thread's last-error value.
    unsafe {
        SetLastError(0);
    }
    // SAFETY: OpenProcess takes only integer arguments and returns a new handle or null.
    let handle = unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            0,
            pid,
        )
    };
    let Ok(process) = owned(handle, Refusal::Custody) else {
        // SAFETY: GetLastError only reads this thread's last-error value.
        return match unsafe { GetLastError() } {
            ERROR_INVALID_PARAMETER => ProcessObservation::Exited,
            _ if KERNEL_PARENTS.contains(&parent) => ProcessObservation::KernelCreated,
            _ => ProcessObservation::Unobservable,
        };
    };
    // SAFETY: the process handle is owned and open; a zero timeout never blocks.
    match unsafe { WaitForSingleObject(raw(&process), 0) } {
        WAIT_OBJECT_0 => return ProcessObservation::Exited,
        WAIT_TIMEOUT => {}
        _ => return ProcessObservation::Unobservable,
    }
    match process_identity(&process) {
        Ok(identity) => ProcessObservation::Opened {
            process: identity,
            token: process_token(&process),
        },
        Err(_) => ProcessObservation::Unobservable,
    }
}

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-straggler-termination
/// A straggler MAY be terminated only through a handle whose kernel PID and
/// creation identity equal the planned process and whose primary token still
/// has the prior worker's exact account SID and logon session. PID reuse is
/// left to the next complete observation. Any other mismatch, or failure to
/// observe exit within two seconds, MUST refuse.
pub fn terminate_straggler(prior: &PriorWorker, target: ProcessIdentity) -> Result<(), Refusal> {
    // SAFETY: SetLastError only writes this thread's last-error value.
    unsafe {
        SetLastError(0);
    }
    // SAFETY: OpenProcess takes only integer arguments and returns a new handle or null.
    let handle = unsafe {
        OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            0,
            target.pid,
        )
    };
    let process = match owned(handle, Refusal::Custody) {
        Ok(process) => process,
        // SAFETY: GetLastError only reads this thread's last-error value.
        Err(_) if unsafe { GetLastError() } == ERROR_INVALID_PARAMETER => return Ok(()),
        Err(reason) => return Err(reason),
    };
    if process_identity(&process)? != target {
        // A different process now owns this PID; rescan classifies it afresh.
        return Ok(());
    }
    // SAFETY: the process handle is owned and open; a zero timeout never blocks.
    match unsafe { WaitForSingleObject(raw(&process), 0) } {
        WAIT_OBJECT_0 => return Ok(()),
        WAIT_TIMEOUT => {}
        _ => return Err(Refusal::Custody),
    }
    match process_token(&process) {
        TokenObservation::Account(owner)
            if owner.sid == prior.sid && owner.logon == prior.logon => {}
        _ => return Err(Refusal::Custody),
    }
    // SAFETY: the process handle is owned, open and was opened with PROCESS_TERMINATE.
    if unsafe { TerminateProcess(raw(&process), 1) } == 0
        // SAFETY: the process handle is owned and open; a zero timeout never blocks.
        && unsafe { WaitForSingleObject(raw(&process), 0) } != WAIT_OBJECT_0
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: the process handle is owned and open, and the wait is bounded to two seconds.
    if unsafe { WaitForSingleObject(raw(&process), 2_000) } != WAIT_OBJECT_0 {
        return Err(Refusal::Custody);
    }
    Ok(())
}

pub(super) fn process_identity(process: &OwnedHandle) -> Result<ProcessIdentity, Refusal> {
    // SAFETY: FILETIME is a plain C struct for which all-zero bytes are a valid value.
    let mut created: FILETIME = unsafe { zeroed() };
    // SAFETY: FILETIME is a plain C struct for which all-zero bytes are a valid value.
    let mut exit: FILETIME = unsafe { zeroed() };
    // SAFETY: FILETIME is a plain C struct for which all-zero bytes are a valid value.
    let mut kernel: FILETIME = unsafe { zeroed() };
    // SAFETY: FILETIME is a plain C struct for which all-zero bytes are a valid value.
    let mut user: FILETIME = unsafe { zeroed() };
    // SAFETY: the process handle is owned and open, and all four out-pointers are live writable locals.
    if unsafe {
        GetProcessTimes(
            raw(process),
            &raw mut created,
            &raw mut exit,
            &raw mut kernel,
            &raw mut user,
        )
    } == 0
    {
        return Err(Refusal::Custody);
    }
    Ok(ProcessIdentity {
        // SAFETY: the process handle is owned and open.
        pid: unsafe { GetProcessId(raw(process)) },
        created: (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime),
    })
}

pub(super) fn peer(
    process: &OwnedHandle,
    job: &OwnedHandle,
    executable: &LocalPath,
) -> Result<PipePeer, Refusal> {
    let mut token = null_mut();
    // SAFETY: the process handle is owned and open, and `token` is a writable out-pointer.
    if unsafe { OpenProcessToken(raw(process), TOKEN_QUERY, &raw mut token) } == 0 {
        return Err(Refusal::Custody);
    }
    let token = owned(token, Refusal::Custody)?;
    let mut path = [0_u16; 4096];
    let mut length = u32::try_from(path.len()).map_err(|_| Refusal::Custody)?;
    // SAFETY: the process handle is owned and open, and `path` is a live writable buffer whose UTF-16 length is passed in `length`.
    if unsafe { QueryFullProcessImageNameW(raw(process), 0, path.as_mut_ptr(), &raw mut length) }
        == 0
        || length as usize >= path.len()
    {
        return Err(Refusal::Custody);
    }
    let path = String::from_utf16(&path[..length as usize]).map_err(|_| Refusal::Custody)?;
    let mut member = 0;
    // SAFETY: both handles are owned and open, and `member` is a live writable local.
    if unsafe { IsProcessInJob(raw(process), raw(job), &raw mut member) } == 0 {
        return Err(Refusal::Custody);
    }
    Ok(PipePeer {
        process: process_identity(process)?,
        sid: token_sid(raw(&token))?,
        in_expected_job: member != 0,
        exact_executable: path.eq_ignore_ascii_case(executable.as_str()),
    })
}
