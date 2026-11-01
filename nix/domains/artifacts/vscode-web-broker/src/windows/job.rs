//! SYSTEM-owned job objects, kernel object ACLs and launch attributes.

use super::{JOB_ALL_ACCESS, owned, raw, wide};
use crate::Refusal;
use crate::windows_model::{CustodianGeneration, WorkerIdentity};
use crate::windows_pipe::Pipe;
use std::mem::{size_of, zeroed};
use std::os::windows::io::OwnedHandle;
use std::ptr::{null, null_mut};
use std::thread;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    ERROR_ALREADY_EXISTS, GetLastError, HANDLE, LocalFree, SetLastError,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SE_KERNEL_OBJECT,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetSecurityDescriptorControl,
    OWNER_SECURITY_INFORMATION, SE_DACL_PROTECTED, SECURITY_ATTRIBUTES,
};
use windows_sys::Win32::System::JobObjects::{
    CreateJobObjectW, JOB_OBJECT_LIMIT_ACTIVE_PROCESS, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JobObjectBasicAccountingInformation, JobObjectExtendedLimitInformation,
    QueryInformationJobObject, SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Threading::{
    DeleteProcThreadAttributeList, InitializeProcThreadAttributeList,
    PROC_THREAD_ATTRIBUTE_JOB_LIST, UpdateProcThreadAttribute,
};

/// A named job owned solely by SYSTEM; closing its final handle kills its workers.
pub(super) fn new_job(
    identity: &WorkerIdentity,
    generation: CustodianGeneration,
) -> Result<OwnedHandle, Refusal> {
    new_job_named(&identity.job_name(generation))
}

pub(super) fn new_job_named(name: &str) -> Result<OwnedHandle, Refusal> {
    let sddl = wide("O:SYG:SYD:P(A;;0x001f003f;;;SY)");
    let mut descriptor = null_mut();
    // SAFETY: `sddl` is a live NUL-terminated UTF-16 string and `descriptor` is a writable out-pointer; the optional length pointer is null.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &raw mut descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(Refusal::Custody);
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>()).map_err(|_| Refusal::Custody)?,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let name = wide(name);
    // SAFETY: SetLastError only writes this thread's last-error value.
    unsafe {
        SetLastError(0);
    }
    // SAFETY: `attributes` points to the converted descriptor and `name` is a live NUL-terminated UTF-16 job name.
    let handle = unsafe { CreateJobObjectW(&raw const attributes, name.as_ptr()) };
    // SAFETY: GetLastError only reads this thread's last-error value.
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    // SAFETY: `descriptor` was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    let handle = owned(handle, Refusal::Startup)?;
    if existed {
        return Err(Refusal::Custody);
    }
    system_job(&handle)?;
    // SAFETY: JOBOBJECT_EXTENDED_LIMIT_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
    // Only the independent custodian owns job handles. Its loss kills the whole
    // job; a gateway restart closes streams without affecting custody.
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    limits.BasicLimitInformation.ActiveProcessLimit = 256;
    let limits_length = u32::try_from(size_of_val(&limits)).map_err(|_| Refusal::Startup)?;
    // SAFETY: the job handle is owned and open, and `limits` is a live initialized struct whose exact size is passed.
    if unsafe {
        SetInformationJobObject(
            raw(&handle),
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            limits_length,
        )
    } == 0
    {
        return Err(Refusal::Startup);
    }
    Ok(handle)
}

pub(super) fn system_job(job: &OwnedHandle) -> Result<(), Refusal> {
    system_object(raw(job), JOB_ALL_ACCESS)
}

/// A local custody pipe has one protected SYSTEM-only full-access ACE.
pub fn system_pipe(pipe: &Pipe) -> Result<(), Refusal> {
    system_object(
        pipe.raw_handle().map_err(|_| Refusal::Custody)?,
        0x001f_01ff,
    )
}

fn system_object(handle: HANDLE, access: u32) -> Result<(), Refusal> {
    let mut owner = null_mut();
    let mut dacl = null_mut();
    let mut descriptor = null_mut();
    // SAFETY: the caller's handle is open, and every out-pointer is a live writable local or null.
    if unsafe {
        GetSecurityInfo(
            handle,
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &raw mut owner,
            null_mut(),
            &raw mut dacl,
            null_mut(),
            &raw mut descriptor,
        )
    } != 0
    {
        return Err(Refusal::Custody);
    }
    let result = (|| {
        // Aligned binary S-1-5-18 (LocalSystem).
        let system = [0x0000_0101_u32, 0x0500_0000, 18];
        let system_sid = system.as_ptr().cast_mut().cast();
        let mut control = 0;
        let mut revision = 0;
        if owner.is_null()
            || dacl.is_null()
            // SAFETY: `owner` is non-null and points into the live `descriptor`; `system_sid` points to the live `system` array.
            || unsafe { EqualSid(owner, system_sid) } == 0
            // SAFETY: `descriptor` was returned by GetSecurityInfo and is live; `control` and `revision` are live writable locals.
            || unsafe {
                GetSecurityDescriptorControl(descriptor, &raw mut control, &raw mut revision)
            } == 0
            || control & SE_DACL_PROTECTED == 0
            // SAFETY: `dacl` is non-null and points to the ACL inside the live descriptor.
            || unsafe { (*dacl).AceCount } != 1
        {
            return Err(Refusal::Custody);
        }
        let mut ace = null_mut();
        // SAFETY: `dacl` is a live ACL with exactly one ACE, and `ace` is a writable out-pointer.
        if unsafe { GetAce(dacl, 0, &raw mut ace) } == 0 || ace.is_null() {
            return Err(Refusal::Custody);
        }
        // SAFETY: GetAce returned a non-null pointer to an ACE inside the live DACL; its header is checked before the type-specific fields are trusted.
        let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        if allowed.Header.AceType != 0
            || allowed.Header.AceFlags != 0
            || allowed.Header.AceSize as usize != size_of::<ACCESS_ALLOWED_ACE>() + 8
            || allowed.Mask != access
            // SAFETY: the SID starts at SidStart inside the live ACE whose size was just checked, and `system_sid` points to the live `system` array.
            || unsafe { EqualSid((&raw const allowed.SidStart).cast_mut().cast(), system_sid) } == 0
        {
            return Err(Refusal::Custody);
        }
        Ok(())
    })();
    // SAFETY: `descriptor` was allocated by GetSecurityInfo and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    result
}

/// @cc [owner:ghuntley,label:security;recovery] windows-editor-complete-owned-job-stop
/// Stopping a proven SYSTEM-owned worker job MUST wait at most five seconds
/// for all of its descendants to exit. A missing retained root process MUST
/// NOT leave owned descendants behind, and failed termination/accounting MUST
/// refuse replacement. Foreign or incompletely identified jobs MUST NOT reach
/// this operation.
pub(super) fn stop_owned_job(job: &OwnedHandle) -> Result<(), Refusal> {
    system_job(job)?;
    // SAFETY: the job handle is owned, open and was verified as SYSTEM-only.
    if unsafe { TerminateJobObject(raw(job), 1) } == 0 {
        return Err(Refusal::Startup);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        // SAFETY: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
        let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = unsafe { zeroed() };
        let mut returned = 0;
        let accounting_length =
            u32::try_from(size_of_val(&accounting)).map_err(|_| Refusal::Startup)?;
        // SAFETY: the job handle is owned and open, `accounting` is a live writable struct whose exact size is passed, and `returned` is a live writable local.
        if unsafe {
            QueryInformationJobObject(
                raw(job),
                JobObjectBasicAccountingInformation,
                (&raw mut accounting).cast(),
                accounting_length,
                &raw mut returned,
            )
        } == 0
            || returned as usize != size_of_val(&accounting)
        {
            return Err(Refusal::Startup);
        }
        if accounting.ActiveProcesses == 0 {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(Refusal::Startup);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// Attribute backing storage and handle list outlive `CreateProcessAsUserW`.
pub(super) struct JobAttributes {
    storage: Vec<usize>,
    job: Box<HANDLE>,
}

impl JobAttributes {
    pub(super) fn new(job: &OwnedHandle) -> Result<Self, Refusal> {
        let mut bytes = 0;
        // SAFETY: a null list with zero count only queries the required size into the live `bytes` local.
        unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &raw mut bytes) };
        if bytes == 0 || bytes > 65536 {
            return Err(Refusal::Startup);
        }
        let mut attributes = Self {
            storage: vec![0; bytes.div_ceil(size_of::<usize>())],
            job: Box::new(raw(job)),
        };
        // SAFETY: `storage` holds at least `bytes` bytes, as the size query required, and outlives the list.
        if unsafe { InitializeProcThreadAttributeList(attributes.pointer(), 1, 0, &raw mut bytes) }
            == 0
        {
            // An uninitialized attribute list must not be deleted.
            attributes.storage.clear();
            return Err(Refusal::Startup);
        }
        // SAFETY: the list was initialized above; `attributes.job` is a boxed handle that outlives the list and its size is passed.
        if unsafe {
            UpdateProcThreadAttribute(
                attributes.pointer(),
                0,
                PROC_THREAD_ATTRIBUTE_JOB_LIST as usize,
                (&raw mut *attributes.job).cast(),
                size_of::<HANDLE>(),
                null_mut(),
                null(),
            )
        } == 0
        {
            return Err(Refusal::Startup);
        }
        Ok(attributes)
    }

    pub(super) fn pointer(
        &self,
    ) -> windows_sys::Win32::System::Threading::LPPROC_THREAD_ATTRIBUTE_LIST {
        self.storage.as_ptr().cast_mut().cast()
    }
}

impl Drop for JobAttributes {
    fn drop(&mut self) {
        if !self.storage.is_empty() {
            // SAFETY: a non-empty `storage` holds a list that InitializeProcThreadAttributeList initialized, deleted exactly once here.
            unsafe { DeleteProcThreadAttributeList(self.pointer()) };
        }
    }
}
