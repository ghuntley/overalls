//! Windows custodian-owned worker custody and atomic launcher.
//!
//! The caller must reconcile the account using the current boot-bound roster
//! authorizer before resolving its SID and constructing an admitted identity.
//! Package paths come from trusted, immutable deployment configuration. The
//! custodian must single-flight startup and retain a SYSTEM-owned launch receipt.

use crate::Refusal;
use crate::windows_model::{
    AccountSid, CustodianGeneration, LocalPath, LogonSession, PipePeer, PriorWorker,
    ProcessIdentity, ProcessObservation, TokenObservation, TokenOwner, WorkerIdentity, WorkerPath,
    command_line, verify_peer,
};
use crate::windows_pipe::Pipe;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::mem::{size_of, zeroed};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_INVALID_PARAMETER,
    ERROR_NO_MORE_FILES, ERROR_NOT_ALL_ASSIGNED, FILETIME, GetLastError, HANDLE, LUID, LocalFree,
    SetLastError, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NetApiBufferFree, NetUserGetInfo, UF_ACCOUNTDISABLE, USER_INFO_4,
};
use windows_sys::Win32::Security::Authentication::Identity::{
    LSA_STRING, LSA_UNICODE_STRING, LsaDeregisterLogonProcess, LsaFreeReturnBuffer, LsaLogonUser,
    LsaLookupAuthenticationPackage, LsaRegisterLogonProcess, MSV1_0_S4U_LOGON, MsV1_0S4ULogon,
    SECURITY_LOGON_TYPE,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SE_KERNEL_OBJECT,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, AdjustTokenPrivileges, AllocateLocallyUniqueId, DACL_SECURITY_INFORMATION,
    DuplicateTokenEx, EqualSid, GetAce, GetLengthSid, GetSecurityDescriptorControl,
    GetSecurityDescriptorDacl, GetSecurityDescriptorOwner, GetTokenInformation,
    IsValidSecurityDescriptor, IsValidSid, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW,
    OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, QUOTA_LIMITS, SE_ASSIGNPRIMARYTOKEN_NAME,
    SE_DACL_PROTECTED, SE_INCREASE_QUOTA_NAME, SE_PRIVILEGE_ENABLED, SE_TCB_NAME,
    SECURITY_ATTRIBUTES, SecurityImpersonation, TOKEN_ADJUST_PRIVILEGES, TOKEN_ALL_ACCESS,
    TOKEN_PRIVILEGES, TOKEN_QUERY, TOKEN_SOURCE, TOKEN_STATISTICS, TOKEN_USER, TokenPrimary,
    TokenStatistics, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    BY_HANDLE_FILE_INFORMATION, CreateDirectoryW, FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_FLAG_OVERLAPPED, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, GetFileInformationByHandle, MOVEFILE_REPLACE_EXISTING,
    MOVEFILE_WRITE_THROUGH, MoveFileExW, READ_CONTROL, SECURITY_IDENTIFICATION,
    SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::JobObjects::{
    CreateJobObjectW, IsProcessInJob, JOB_OBJECT_LIMIT_ACTIVE_PROCESS,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectBasicAccountingInformation,
    JobObjectExtendedLimitInformation, OpenJobObjectW, QueryInformationJobObject,
    SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
    CreateProcessAsUserW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT,
    GetCurrentProcess, GetProcessId, GetProcessTimes, InitializeProcThreadAttributeList,
    OpenProcess, OpenProcessToken, PROC_THREAD_ATTRIBUTE_JOB_LIST, PROCESS_INFORMATION,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    QueryFullProcessImageNameW, ResumeThread, STARTUPINFOEXW, TerminateProcess,
    UpdateProcThreadAttribute, WaitForSingleObject,
};
use windows_sys::Win32::UI::Shell::GetUserProfileDirectoryW;

const JOB_ALL_ACCESS: u32 = 0x001f_003f;
const JOB_OBJECT_QUERY: u32 = 0x0004;
/// Idle and System are the only kernel creators; user tokens cannot name them.
const KERNEL_PARENTS: [u32; 2] = [0, 4];
const PROCESS_LIST_LIMIT: usize = 65536;

fn system_sid() -> [u32; 3] {
    [0x0000_0101, 0x0500_0000, 18]
}
fn administrators_sid() -> [u32; 4] {
    [0x0000_0201, 0x0500_0000, 32, 544]
}

fn trusted_installer_sid() -> [u32; 8] {
    [
        0x0000_0601,
        0x0500_0000,
        80,
        956_008_885,
        3_418_522_649,
        1_831_038_044,
        1_853_292_631,
        2_271_478_464,
    ]
}

/// @cc [owner:ghuntley,label:security] windows-editor-platform-authority-scope
/// Only directory ancestry and explicit worker search directories MAY accept
/// the exact `TrustedInstaller` service SID as platform servicing authority.
/// Package leaves MUST remain SYSTEM/Administrators-only; private state MUST
/// remain SYSTEM-only. A trusted directory owner MUST NOT authorize foreign
/// write, deletion, reparse traversal or ACL replacement.
#[derive(Clone, Copy)]
enum FileAuthority {
    SystemOnly,
    Package,
    Ancestor,
    WorkerDirectory,
}

impl FileAuthority {
    fn platform_servicing(self) -> bool {
        matches!(self, Self::Ancestor | Self::WorkerDirectory)
    }
}

/// Refuse execution unless this broker is running as `LocalSystem`.
pub fn require_system() -> Result<(), Refusal> {
    let mut token = null_mut();
    // SAFETY: GetCurrentProcess has no preconditions and returns a pseudo-handle.
    let current = unsafe { GetCurrentProcess() };
    // SAFETY: `current` is this process's pseudo-handle and `token` is a writable out-pointer.
    if unsafe { OpenProcessToken(current, TOKEN_QUERY, &raw mut token) } == 0 {
        return Err(Refusal::Custody);
    }
    let token = owned(token, Refusal::Custody)?;
    let mut buffer = [0_usize; 32];
    let buffer_length = u32::try_from(size_of_val(&buffer)).map_err(|_| Refusal::Custody)?;
    let mut length = 0;
    // SAFETY: `buffer` is a live pointer-aligned writable allocation whose byte size is passed, and `length` is a live writable local; the token handle is owned and open.
    if unsafe {
        GetTokenInformation(
            raw(&token),
            TokenUser,
            buffer.as_mut_ptr().cast(),
            buffer_length,
            &raw mut length,
        )
    } == 0
        || length as usize > size_of_val(&buffer)
        || (length as usize) < size_of::<TOKEN_USER>()
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: GetTokenInformation succeeded with at least size_of::<TOKEN_USER>() bytes written into the pointer-aligned `buffer`, so it holds an initialized TOKEN_USER.
    let sid = unsafe { (*buffer.as_ptr().cast::<TOKEN_USER>()).User.Sid };
    let system = system_sid();
    // SAFETY: `sid` points into the live `buffer` written by GetTokenInformation, and `system` is a live well-formed SID array that EqualSid only reads.
    if unsafe { EqualSid(sid, system.as_ptr().cast_mut().cast()) } == 0 {
        return Err(Refusal::Custody);
    }
    Ok(())
}

fn path_handle(path: &str) -> Result<File, Refusal> {
    OpenOptions::new()
        .access_mode(READ_CONTROL | FILE_READ_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .map_err(|_| Refusal::Custody)
}

fn attributes(file: &File) -> Result<u32, Refusal> {
    // SAFETY: BY_HANDLE_FILE_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
    let mut information: BY_HANDLE_FILE_INFORMATION = unsafe { zeroed() };
    // SAFETY: the file handle is open for the borrow of `file` and `information` is a live writable local.
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &raw mut information) } == 0
        || information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    {
        return Err(Refusal::Custody);
    }
    Ok(information.dwFileAttributes)
}

fn file_acl(file: &File, authority: FileAuthority) -> Result<(), Refusal> {
    let mut descriptor = null_mut();
    // SAFETY: the file handle is open for the borrow of `file`; `descriptor` is a writable out-pointer and the unused out-pointers are null.
    if unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            windows_sys::Win32::Security::Authorization::SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            null_mut(),
            null_mut(),
            &raw mut descriptor,
        )
    } != 0
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: GetSecurityInfo returned the owned security descriptor; its
    // owner and DACL remain valid until LocalFree after validation.
    let result = unsafe { descriptor_acl(descriptor, authority) };
    // SAFETY: `descriptor` was allocated by GetSecurityInfo and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    result
}

/// Validate only a Windows-owned, live security descriptor. The caller MUST
/// retain its allocation through this call; arbitrary pointers are forbidden.
unsafe fn descriptor_acl(
    descriptor: PSECURITY_DESCRIPTOR,
    authority: FileAuthority,
) -> Result<(), Refusal> {
    // SAFETY: the caller guarantees `descriptor` is a live Windows-owned security descriptor, checked non-null first.
    if descriptor.is_null() || unsafe { IsValidSecurityDescriptor(descriptor) } == 0 {
        return Err(Refusal::Custody);
    }
    let mut owner = null_mut();
    let mut dacl = null_mut();
    let mut owner_defaulted = 0;
    let mut dacl_present = 0;
    let mut dacl_defaulted = 0;
    // SAFETY: `descriptor` is a valid live security descriptor and the out-pointers are live writable locals.
    if unsafe { GetSecurityDescriptorOwner(descriptor, &raw mut owner, &raw mut owner_defaulted) }
        == 0
        // SAFETY: `descriptor` is a valid live security descriptor and the out-pointers are live writable locals.
        || unsafe {
            GetSecurityDescriptorDacl(
                descriptor,
                &raw mut dacl_present,
                &raw mut dacl,
                &raw mut dacl_defaulted,
            )
        } == 0
        || dacl_present == 0
    {
        return Err(Refusal::Custody);
    }
    let system = system_sid();
    let administrators = administrators_sid();
    let trusted_installer = trusted_installer_sid();
    let system_only = matches!(authority, FileAuthority::SystemOnly);
    let ancestor = matches!(authority, FileAuthority::Ancestor);
    // SAFETY: `sid` comes from the live descriptor or DACL, and `system` is a live well-formed SID array that EqualSid only reads.
    let is_system = |sid| unsafe { EqualSid(sid, system.as_ptr().cast_mut().cast()) } != 0;
    // SAFETY: `sid` comes from the live descriptor or DACL, and `administrators` is a live well-formed SID array that EqualSid only reads.
    let is_admin = |sid| unsafe { EqualSid(sid, administrators.as_ptr().cast_mut().cast()) } != 0;
    let is_platform = |sid| {
        authority.platform_servicing()
            // SAFETY: `sid` comes from the live descriptor or DACL, and `trusted_installer` is a live well-formed SID array that EqualSid only reads.
            && unsafe { EqualSid(sid, trusted_installer.as_ptr().cast_mut().cast()) } != 0
    };
    if owner.is_null()
        || dacl.is_null()
        || (system_only && !is_system(owner))
        || (!system_only && !is_system(owner) && !is_admin(owner) && !is_platform(owner))
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: `dacl` is non-null and points to the ACL inside the live descriptor.
    let count = unsafe { (*dacl).AceCount };
    if count == 0 || count > 128 {
        return Err(Refusal::Custody);
    }
    for index in 0..u32::from(count) {
        let mut ace = null_mut();
        // SAFETY: `dacl` is a live ACL, `index` is below its AceCount, and `ace` is a writable out-pointer.
        if unsafe { GetAce(dacl, index, &raw mut ace) } == 0 || ace.is_null() {
            return Err(Refusal::Custody);
        }
        // SAFETY: GetAce returned a non-null pointer to an ACE inside the live DACL; its header is read before any type-specific field is trusted.
        let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        if allowed.Header.AceType == 1 {
            continue;
        } // Denials cannot grant write authority.
        if allowed.Header.AceType != 0
            || (allowed.Header.AceSize as usize) < size_of::<ACCESS_ALLOWED_ACE>()
        {
            return Err(Refusal::Custody);
        }
        if allowed.Header.AceFlags & 8 != 0 {
            continue;
        } // INHERIT_ONLY does not apply here.
        let sid = (&raw const allowed.SidStart).cast_mut().cast();
        if is_system(sid) {
            continue;
        }
        if system_only {
            return Err(Refusal::Custody);
        }
        if is_admin(sid) || is_platform(sid) {
            continue;
        }
        // A parent may allow creation of unrelated children. It MUST NOT
        // allow replacing/deleting this already-owned child or its ACL.
        let write_mask = 0x500d_0040 | if ancestor { 0 } else { 0x0000_0116 };
        if allowed.Mask & write_mask != 0 {
            return Err(Refusal::Custody);
        }
    }
    Ok(())
}

fn ancestors(path: &LocalPath) -> Result<(), Refusal> {
    let mut parent = std::path::Path::new(path.as_str()).parent();
    while let Some(directory) = parent {
        let text = directory.to_str().ok_or(Refusal::Custody)?;
        let handle = path_handle(text)?;
        if attributes(&handle)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
            return Err(Refusal::Custody);
        }
        file_acl(&handle, FileAuthority::Ancestor)?;
        parent = directory.parent();
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] windows-editor-package-path-custody
/// Configured executable/configuration/certificate paths MUST be real regular
/// files with SYSTEM or Administrators ownership and write authority only for
/// those principals. Every ancestor MUST refuse reparse traversal and foreign
/// replacement/delete/ACL authority. A caller path or existence alone MUST NOT
/// establish immutable package custody. Retained-worker adoption and recovery
/// MUST recheck executable custody before trusting the retained process.
pub fn package_file(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let file = path_handle(path.as_str())?;
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, FileAuthority::Package)
}

/// @cc [owner:ghuntley,label:security] windows-editor-path-directory-custody
/// Every initial worker PATH entry MUST be an existing real directory owned by
/// SYSTEM, Administrators or the exact Windows `TrustedInstaller` service SID.
/// Those principals alone may write it or control ancestor replacement/ACLs;
/// every component MUST refuse reparse traversal. `TrustedInstaller` already
/// controls platform servicing; it MUST NOT gain package-file or receipt trust.
fn package_directory(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let directory = path_handle(path.as_str())?;
    if attributes(&directory)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&directory, FileAuthority::WorkerDirectory)
}

fn checked_private_directory(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let directory = path_handle(path.as_str())?;
    if attributes(&directory)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&directory, FileAuthority::SystemOnly)
}

/// Create only the final directory under trusted ancestors, with SYSTEM-only ACL.
pub fn private_directory(path: &LocalPath) -> Result<(), Refusal> {
    require_system()?;
    ancestors(path)?;
    if std::path::Path::new(path.as_str()).exists() {
        return checked_private_directory(path);
    }
    let sddl = wide("O:SYG:SYD:P(A;OICI;FA;;;SY)");
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
    let name = wide(path.as_str());
    // SAFETY: `name` is a live NUL-terminated UTF-16 path and `attributes` points to the converted descriptor, both live for the call.
    let created = unsafe { CreateDirectoryW(name.as_ptr(), &raw const attributes) };
    // SAFETY: GetLastError only reads this thread's last-error value.
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    // SAFETY: `descriptor` was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW and is freed exactly once after its last use.
    unsafe {
        LocalFree(descriptor);
    }
    if created == 0 && !existed {
        return Err(Refusal::Custody);
    }
    checked_private_directory(path)
}

fn private_parent(path: &LocalPath) -> Result<(), Refusal> {
    let parent = std::path::Path::new(path.as_str())
        .parent()
        .and_then(std::path::Path::to_str)
        .ok_or(Refusal::Custody)?;
    checked_private_directory(&LocalPath::parse(parent).map_err(|_| Refusal::Custody)?)
}

/// Read a bounded ordinary receipt only after SYSTEM-only parent/file custody.
pub fn read_private(path: &LocalPath, maximum: usize) -> Result<Vec<u8>, Refusal> {
    require_system()?;
    private_parent(path)?;
    if maximum == 0 || maximum > 65536 {
        return Err(Refusal::Custody);
    }
    let file = OpenOptions::new()
        .read(true)
        .access_mode(0x8000_0000 | READ_CONTROL)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path.as_str())
        .map_err(|_| Refusal::Custody)?;
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, FileAuthority::SystemOnly)?;
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal::Custody)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Custody);
    }
    Ok(bytes)
}

/// Read an optional receipt. Absence is the only non-error state; ACL,
/// reparse, malformed, and other I/O failures remain custody refusals.
pub fn read_private_optional(path: &LocalPath, maximum: usize) -> Result<Option<Vec<u8>>, Refusal> {
    require_system()?;
    private_parent(path)?;
    if maximum == 0 || maximum > 65536 {
        return Err(Refusal::Custody);
    }
    let file = match OpenOptions::new()
        .read(true)
        .access_mode(0x8000_0000 | READ_CONTROL)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path.as_str())
    {
        Ok(file) => file,
        Err(error) if error.raw_os_error() == Some(ERROR_FILE_NOT_FOUND.cast_signed()) => {
            return Ok(None);
        }
        Err(_) => return Err(Refusal::Custody),
    };
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, FileAuthority::SystemOnly)?;
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal::Custody)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Custody);
    }
    Ok(Some(bytes))
}

/// Publish a complete bounded receipt by rename under its SYSTEM-only parent.
pub fn write_private(path: &LocalPath, bytes: &[u8]) -> Result<(), Refusal> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    require_system()?;
    private_parent(path)?;
    if bytes.is_empty() || bytes.len() > 65536 {
        return Err(Refusal::Custody);
    }
    let temporary = format!(
        "{}.{}.{}.tmp",
        path.as_str(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .access_mode(0x4000_0000 | READ_CONTROL)
            .share_mode(0)
            .open(&temporary)
            .map_err(|_| Refusal::Custody)?;
        attributes(&file)?;
        file_acl(&file, FileAuthority::SystemOnly)?;
        file.write_all(bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Refusal::Custody)?;
        drop(file);
        let source = wide(&temporary);
        let destination = wide(path.as_str());
        // SAFETY: `source` and `destination` are live NUL-terminated UTF-16 paths.
        if unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            return Err(Refusal::Custody);
        }
        let published = read_private(path, bytes.len())?;
        (published == bytes).then_some(()).ok_or(Refusal::Custody)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}

fn owned(handle: HANDLE, refusal: Refusal) -> Result<OwnedHandle, Refusal> {
    if handle.is_null() || handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
        return Err(refusal);
    }
    // SAFETY: the caller transferred a newly acquired, uniquely owned handle.
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

fn raw(handle: &OwnedHandle) -> HANDLE {
    handle.as_raw_handle()
}

fn copy_sid(pointer: windows_sys::Win32::Security::PSID) -> Result<AccountSid, Refusal> {
    // SAFETY: callers supply a SID pointer within a live successful Win32 result.
    if pointer.is_null() || unsafe { IsValidSid(pointer) } == 0 {
        return Err(Refusal::Account);
    }
    // SAFETY: `pointer` was checked non-null and valid by IsValidSid above.
    let length = unsafe { GetLengthSid(pointer) } as usize;
    if length != 28 {
        return Err(Refusal::Account);
    }
    // SAFETY: `pointer` is a valid SID of exactly `length` bytes inside a live Win32 result for this borrow.
    AccountSid::parse(unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), length) })
}

/// @cc [owner:ghuntley,label:security] windows-editor-resolve-current-local-sid
/// Resolution MUST use the enabled local SAM account for the exact canonical
/// `u<uid>` name after fresh roster reconciliation. It MUST NOT resolve a domain
/// fallback or infer the SID from a name, UID or profile-directory convention.
pub fn resolve_account(uid: u32, username: &str) -> Result<AccountSid, Refusal> {
    if !(200_000..=999_999).contains(&uid) || username != format!("u{uid}") {
        return Err(Refusal::Account);
    }
    let name = wide(username);
    let mut buffer = null_mut();
    // SAFETY: level four returns one local SAM record owned by NetApi.
    if unsafe { NetUserGetInfo(null(), name.as_ptr(), 4, &raw mut buffer) } != 0 || buffer.is_null()
    {
        return Err(Refusal::Account);
    }
    let result = (|| {
        // SAFETY: NetUserGetInfo succeeded at level 4, so the non-null `buffer` holds a USER_INFO_4 that stays live until NetApiBufferFree below.
        let record = unsafe { &*buffer.cast::<USER_INFO_4>() };
        if record.usri4_flags & UF_ACCOUNTDISABLE != 0 {
            return Err(Refusal::Account);
        }
        copy_sid(record.usri4_user_sid)
    })();
    // SAFETY: `buffer` was allocated by NetUserGetInfo and is freed exactly once after its last use.
    unsafe {
        NetApiBufferFree(buffer.cast());
    }
    result
}

fn token_sid(token: HANDLE) -> Result<AccountSid, Refusal> {
    // A TOKEN_USER is pointer aligned; the remaining buffer holds its SID.
    let mut buffer = [0_usize; 32];
    let buffer_length = u32::try_from(size_of_val(&buffer)).map_err(|_| Refusal::Custody)?;
    let mut length = 0;
    // SAFETY: `buffer` is a live pointer-aligned writable allocation whose byte size is passed, and `length` is a live writable local; the caller's token handle is open.
    if unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            buffer_length,
            &raw mut length,
        )
    } == 0
        || length as usize > size_of_val(&buffer)
        || (length as usize) < size_of::<TOKEN_USER>()
    {
        return Err(Refusal::Custody);
    }
    // SAFETY: GetTokenInformation succeeded with at least size_of::<TOKEN_USER>() bytes written into the pointer-aligned `buffer`, so it holds an initialized TOKEN_USER.
    let record = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    copy_sid(record.User.Sid).map_err(|_| Refusal::Custody)
}

/// The LSA logon session that every process created from this token inherits.
fn token_logon(token: HANDLE) -> Result<LogonSession, Refusal> {
    // SAFETY: TOKEN_STATISTICS is a plain C struct for which all-zero bytes are a valid value.
    let mut statistics: TOKEN_STATISTICS = unsafe { zeroed() };
    let statistics_length =
        u32::try_from(size_of_val(&statistics)).map_err(|_| Refusal::Custody)?;
    let mut length = 0;
    // SAFETY: `statistics` is a live writable local whose exact size is passed, and `length` is a live writable local; the caller's token handle is open.
    if unsafe {
        GetTokenInformation(
            token,
            TokenStatistics,
            (&raw mut statistics).cast(),
            statistics_length,
            &raw mut length,
        )
    } == 0
        || length as usize != size_of_val(&statistics)
    {
        return Err(Refusal::Custody);
    }
    LogonSession::from_luid(
        statistics.AuthenticationId.LowPart,
        statistics.AuthenticationId.HighPart,
    )
}

/// Classify a live process token without trusting any caller-supplied claim.
fn process_token(process: &OwnedHandle) -> TokenObservation {
    let mut token = null_mut();
    // SAFETY: the process handle is owned and open, and `token` is a writable out-pointer.
    if unsafe { OpenProcessToken(raw(process), TOKEN_QUERY, &raw mut token) } == 0 {
        return TokenObservation::Unreadable;
    }
    let Ok(token) = owned(token, Refusal::Custody) else {
        return TokenObservation::Unreadable;
    };
    let mut buffer = [0_usize; 32];
    let Ok(buffer_length) = u32::try_from(size_of_val(&buffer)) else {
        return TokenObservation::Unreadable;
    };
    let mut length = 0;
    // SAFETY: `buffer` is a live pointer-aligned writable allocation whose byte size is passed, and `length` is a live writable local; the token handle is owned and open.
    if unsafe {
        GetTokenInformation(
            raw(&token),
            TokenUser,
            buffer.as_mut_ptr().cast(),
            buffer_length,
            &raw mut length,
        )
    } == 0
        || length as usize > size_of_val(&buffer)
        || (length as usize) < size_of::<TOKEN_USER>()
    {
        return TokenObservation::Unreadable;
    }
    // SAFETY: GetTokenInformation succeeded with at least size_of::<TOKEN_USER>() bytes written into the pointer-aligned `buffer`, so it holds an initialized TOKEN_USER.
    let user = unsafe { (*buffer.as_ptr().cast::<TOKEN_USER>()).User.Sid };
    // SAFETY: `user` is non-null and points into the live `buffer`.
    if user.is_null() || unsafe { IsValidSid(user) } == 0 {
        return TokenObservation::Unreadable;
    }
    // A valid SID that is not a complete ordinary account is another principal.
    let Ok(sid) = copy_sid(user) else {
        return TokenObservation::NonAccount;
    };
    match token_logon(raw(&token)) {
        Ok(logon) => TokenObservation::Account(TokenOwner { sid, logon }),
        Err(_) => TokenObservation::Unreadable,
    }
}

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

fn job_name_present(name: &str) -> Result<bool, Refusal> {
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

fn privilege(name: *const u16) -> Result<(), Refusal> {
    let mut token = null_mut();
    // SAFETY: GetCurrentProcess has no preconditions and returns a pseudo-handle.
    let current = unsafe { GetCurrentProcess() };
    // SAFETY: `current` is this process's pseudo-handle and `token` is a writable out-pointer.
    if unsafe {
        OpenProcessToken(
            current,
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &raw mut token,
        )
    } == 0
    {
        return Err(Refusal::Startup);
    }
    let token = owned(token, Refusal::Startup)?;
    // SAFETY: LUID is a plain C struct for which all-zero bytes are a valid value.
    let mut luid: LUID = unsafe { zeroed() };
    // SAFETY: `name` is a live NUL-terminated privilege name supplied by the caller and `luid` is a live writable local.
    if unsafe { LookupPrivilegeValueW(null(), name, &raw mut luid) } == 0 {
        return Err(Refusal::Startup);
    }
    let privileges = TOKEN_PRIVILEGES {
        PrivilegeCount: 1,
        Privileges: [LUID_AND_ATTRIBUTES {
            Luid: luid,
            Attributes: SE_PRIVILEGE_ENABLED,
        }],
    };
    // SAFETY: SetLastError only writes this thread's last-error value.
    unsafe {
        SetLastError(0);
    }
    // SAFETY: the token handle is owned and open, `privileges` is a live TOKEN_PRIVILEGES, and the previous-state out-pointers are null.
    if unsafe {
        AdjustTokenPrivileges(
            raw(&token),
            0,
            &raw const privileges,
            0,
            null_mut(),
            null_mut(),
        )
    } == 0
        // SAFETY: GetLastError only reads this thread's last-error value.
        || unsafe { GetLastError() } == ERROR_NOT_ALL_ASSIGNED
    {
        return Err(Refusal::Startup);
    }
    Ok(())
}

/// Passwordless local-account logon, with explicit primary-token duplication.
#[expect(
    clippy::too_many_lines,
    reason = "one LSA registration whose S4U logon and deregistration must stay in a single scope"
)]
fn account_token(identity: &WorkerIdentity) -> Result<OwnedHandle, Refusal> {
    if resolve_account(identity_uid(identity)?, identity.username())? != *identity.sid() {
        return Err(Refusal::Account);
    }
    let mut process_name = *b"overalls-editor";
    let process_length = u16::try_from(process_name.len()).map_err(|_| Refusal::Account)?;
    let process = LSA_STRING {
        Length: process_length,
        MaximumLength: process_length,
        Buffer: process_name.as_mut_ptr(),
    };
    let mut lsa = null_mut();
    let mut mode = 0;
    // SAFETY: `process` is a live LSA_STRING over the live `process_name` bytes, and `lsa`/`mode` are live writable locals.
    if unsafe { LsaRegisterLogonProcess(&raw const process, &raw mut lsa, &raw mut mode) } != 0 {
        return Err(Refusal::Account);
    }
    let result = (|| {
        let mut package_name = *b"MICROSOFT_AUTHENTICATION_PACKAGE_V1_0";
        let package_length = u16::try_from(package_name.len()).map_err(|_| Refusal::Account)?;
        let package = LSA_STRING {
            Length: package_length,
            MaximumLength: package_length,
            Buffer: package_name.as_mut_ptr(),
        };
        let mut package_id = 0;
        // SAFETY: `lsa` is the registered LSA handle, `package` is a live LSA_STRING over the live `package_name` bytes, and `package_id` is a live writable local.
        if unsafe { LsaLookupAuthenticationPackage(lsa, &raw const package, &raw mut package_id) }
            != 0
        {
            return Err(Refusal::Account);
        }
        let user: Vec<u16> = identity.username().encode_utf16().collect();
        let header = size_of::<MSV1_0_S4U_LOGON>();
        let total = header + (user.len() + 1) * 2;
        let mut storage = vec![0_u64; total.div_ceil(8)];
        let base = storage.as_mut_ptr().cast::<u8>();
        let user_length = u16::try_from(user.len() * 2).map_err(|_| Refusal::Account)?;
        // SAFETY: `header` is below `total`, the byte size of `storage`.
        let user_at = unsafe { base.add(header) };
        #[expect(
            clippy::cast_ptr_alignment,
            reason = "storage is u64-aligned and header is a multiple of the request's 8-byte alignment"
        )]
        let user_at = user_at.cast::<u16>();
        // SAFETY: `user_at` has room for user.len() + 1 aligned u16s inside `storage`, which does not overlap `user`.
        unsafe { std::ptr::copy_nonoverlapping(user.as_ptr(), user_at, user.len()) };
        // SAFETY: the unit after the copied user name is still inside `storage`.
        let domain_at = unsafe { user_at.add(user.len()) };
        // SAFETY: `domain_at` is an aligned in-bounds u16 slot of `storage`.
        unsafe { *domain_at = u16::from(b'.') };
        #[expect(
            clippy::cast_ptr_alignment,
            reason = "storage is u64-aligned, satisfying the request's 8-byte alignment"
        )]
        let request_at = base.cast::<MSV1_0_S4U_LOGON>();
        // SAFETY: `request_at` is aligned and `storage` holds at least `header` bytes for the plain C request.
        unsafe {
            *request_at = MSV1_0_S4U_LOGON {
                MessageType: MsV1_0S4ULogon,
                Flags: 0,
                UserPrincipalName: LSA_UNICODE_STRING {
                    Length: user_length,
                    MaximumLength: user_length,
                    Buffer: user_at,
                },
                DomainName: LSA_UNICODE_STRING {
                    Length: 2,
                    MaximumLength: 2,
                    Buffer: domain_at,
                },
            };
        }
        // SAFETY: TOKEN_SOURCE is a plain C struct for which all-zero bytes are a valid value.
        let mut source: TOKEN_SOURCE = unsafe { zeroed() };
        for (slot, byte) in source.SourceName.iter_mut().zip(b"overalls") {
            *slot = byte.cast_signed();
        }
        // SAFETY: `source.SourceIdentifier` is a live writable LUID.
        if unsafe { AllocateLocallyUniqueId(&raw mut source.SourceIdentifier) } == 0 {
            return Err(Refusal::Account);
        }
        let mut profile = null_mut();
        let mut profile_length = 0;
        // SAFETY: LUID is a plain C struct for which all-zero bytes are a valid value.
        let mut logon: LUID = unsafe { zeroed() };
        let mut token = null_mut();
        // SAFETY: QUOTA_LIMITS is a plain C struct for which all-zero bytes are a valid value.
        let mut quotas: QUOTA_LIMITS = unsafe { zeroed() };
        let mut substatus = 0;
        let total_length = u32::try_from(total).map_err(|_| Refusal::Account)?;
        // SAFETY: `lsa` is registered, `storage` holds the initialized `total`-byte S4U request whose string buffers point inside it, and every out-pointer is a live writable local.
        let status = unsafe {
            LsaLogonUser(
                lsa,
                &raw const process,
                SECURITY_LOGON_TYPE::Network,
                package_id,
                storage.as_ptr().cast(),
                total_length,
                null(),
                &raw const source,
                &raw mut profile,
                &raw mut profile_length,
                &raw mut logon,
                &raw mut token,
                &raw mut quotas,
                &raw mut substatus,
            )
        };
        if !profile.is_null() {
            // SAFETY: `profile` is a non-null buffer returned by LsaLogonUser and is freed exactly once.
            unsafe {
                LsaFreeReturnBuffer(profile);
            }
        }
        if status != 0 {
            if !token.is_null() {
                // SAFETY: on failure LsaLogonUser may still return a token handle; it is non-null, owned here and closed exactly once.
                unsafe {
                    CloseHandle(token);
                }
            }
            return Err(Refusal::Account);
        }
        let token = owned(token, Refusal::Account)?;
        if token_sid(raw(&token))? != *identity.sid() {
            return Err(Refusal::Custody);
        }
        let mut primary = null_mut();
        // SAFETY: the token handle is owned and open, null attributes are permitted, and `primary` is a writable out-pointer.
        if unsafe {
            DuplicateTokenEx(
                raw(&token),
                TOKEN_ALL_ACCESS,
                null(),
                SecurityImpersonation,
                TokenPrimary,
                &raw mut primary,
            )
        } == 0
        {
            return Err(Refusal::Account);
        }
        let primary = owned(primary, Refusal::Account)?;
        if token_sid(raw(&primary))? != *identity.sid() {
            return Err(Refusal::Custody);
        }
        Ok(primary)
    })();
    // SAFETY: `lsa` was registered by LsaRegisterLogonProcess above and is deregistered exactly once after its last use.
    unsafe {
        LsaDeregisterLogonProcess(lsa);
    }
    result
}

fn identity_uid(identity: &WorkerIdentity) -> Result<u32, Refusal> {
    identity
        .username()
        .strip_prefix('u')
        .ok_or(Refusal::Account)?
        .parse()
        .map_err(|_| Refusal::Account)
}

fn profile_directory(token: HANDLE) -> Result<LocalPath, Refusal> {
    let mut path = [0_u16; 4096];
    let mut length = u32::try_from(path.len()).map_err(|_| Refusal::Account)?;
    // SAFETY: `path` is a live writable buffer whose UTF-16 length is passed in `length`, and the caller's token handle is open.
    if unsafe { GetUserProfileDirectoryW(token, path.as_mut_ptr(), &raw mut length) } == 0
        || length < 2
        || length as usize > path.len()
    {
        return Err(Refusal::Account);
    }
    let end = path
        .iter()
        .position(|unit| *unit == 0)
        .filter(|end| *end > 0)
        .ok_or(Refusal::Account)?;
    let text = String::from_utf16(&path[..end]).map_err(|_| Refusal::Account)?;
    if !std::path::Path::new(&text).is_dir() {
        return Err(Refusal::Account);
    }
    LocalPath::parse(&text).map_err(|_| Refusal::Account)
}

/// A named job owned solely by SYSTEM; closing its final handle kills its workers.
fn new_job(
    identity: &WorkerIdentity,
    generation: CustodianGeneration,
) -> Result<OwnedHandle, Refusal> {
    new_job_named(&identity.job_name(generation))
}

fn new_job_named(name: &str) -> Result<OwnedHandle, Refusal> {
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

fn system_job(job: &OwnedHandle) -> Result<(), Refusal> {
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
fn stop_owned_job(job: &OwnedHandle) -> Result<(), Refusal> {
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

fn process_identity(process: &OwnedHandle) -> Result<ProcessIdentity, Refusal> {
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

fn peer(
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

/// Attribute backing storage and handle list outlive `CreateProcessAsUserW`.
struct JobAttributes {
    storage: Vec<usize>,
    job: Box<HANDLE>,
}

impl JobAttributes {
    fn new(job: &OwnedHandle) -> Result<Self, Refusal> {
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

    fn pointer(&self) -> windows_sys::Win32::System::Threading::LPPROC_THREAD_ATTRIBUTE_LIST {
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

/// A SYSTEM peer handle pins PID/creation and the exact installed executable.
#[derive(Debug)]
pub struct SystemPeer {
    process: OwnedHandle,
    identity: ProcessIdentity,
}

impl SystemPeer {
    pub fn open(pid: u32, executable: &LocalPath) -> Result<Self, Refusal> {
        package_file(executable)?;
        let process = owned(
            // SAFETY: OpenProcess takes only integer arguments and returns a new handle or null.
            unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    0,
                    pid,
                )
            },
            Refusal::Custody,
        )?;
        let identity = process_identity(&process)?;
        let peer = Self { process, identity };
        peer.verify(executable)?;
        Ok(peer)
    }

    pub fn identity(&self) -> ProcessIdentity {
        self.identity
    }

    pub fn verify(&self, executable: &LocalPath) -> Result<(), Refusal> {
        if process_identity(&self.process)? != self.identity
            // SAFETY: the process handle is owned and open; a zero timeout never blocks.
            || unsafe { WaitForSingleObject(raw(&self.process), 0) } != WAIT_TIMEOUT
        {
            return Err(Refusal::Custody);
        }
        let mut token = null_mut();
        // SAFETY: the process handle is owned and open, and `token` is a writable out-pointer.
        if unsafe { OpenProcessToken(raw(&self.process), TOKEN_QUERY, &raw mut token) } == 0 {
            return Err(Refusal::Custody);
        }
        let token = owned(token, Refusal::Custody)?;
        let mut length = 0;
        // SAFETY: a null buffer with zero length only queries the required size into the live `length` local.
        unsafe { GetTokenInformation(raw(&token), TokenUser, null_mut(), 0, &raw mut length) };
        if length == 0 || length > 65536 {
            return Err(Refusal::Custody);
        }
        let mut buffer = vec![0_usize; (length as usize).div_ceil(size_of::<usize>())];
        // SAFETY: `buffer` is a live pointer-aligned writable allocation of at least `length` bytes, and the token handle is owned and open.
        if unsafe {
            GetTokenInformation(
                raw(&token),
                TokenUser,
                buffer.as_mut_ptr().cast(),
                length,
                &raw mut length,
            )
        } == 0
        {
            return Err(Refusal::Custody);
        }
        // SAFETY: GetTokenInformation succeeded into the pointer-aligned `buffer` sized as the kernel requested, so it holds an initialized TOKEN_USER.
        let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
        // SAFETY: the SID points into the live `buffer`, and the temporary SYSTEM SID array lives until the end of this statement.
        if unsafe { EqualSid(user.User.Sid, system_sid().as_ptr().cast_mut().cast()) } == 0 {
            return Err(Refusal::Custody);
        }
        let mut path = [0_u16; 4096];
        let mut length = u32::try_from(path.len()).map_err(|_| Refusal::Custody)?;
        // SAFETY: the process handle is owned and open, and `path` is a live writable buffer whose UTF-16 length is passed in `length`.
        if unsafe {
            QueryFullProcessImageNameW(raw(&self.process), 0, path.as_mut_ptr(), &raw mut length)
        } == 0
            || length as usize >= path.len()
        {
            return Err(Refusal::Custody);
        }
        let path = String::from_utf16(&path[..length as usize]).map_err(|_| Refusal::Custody)?;
        if !path.eq_ignore_ascii_case(executable.as_str()) {
            return Err(Refusal::Custody);
        }
        Ok(())
    }
}

/// Trusted deployment paths, never selected from an incoming editor preface.
#[derive(Debug)]
pub struct Package {
    pub node: LocalPath,
    pub server: LocalPath,
    pub system_root: LocalPath,
    pub worker_path: WorkerPath,
    pub extra_ca_certs: LocalPath,
}

/// Failed drain retains the exact job and its capacity charge until shutdown.
#[derive(Debug)]
pub struct QuarantinedJob {
    _job: OwnedHandle,
}

#[derive(Debug)]
pub struct LaunchFailure {
    pub reason: Refusal,
    pub quarantine: Option<QuarantinedJob>,
}

impl From<Refusal> for LaunchFailure {
    fn from(reason: Refusal) -> Self {
        Self {
            reason,
            quarantine: None,
        }
    }
}

/// A custodian-owned worker. Closing its last job handle kills every descendant.
#[derive(Debug)]
pub struct Worker {
    process: OwnedHandle,
    job: OwnedHandle,
    identity: WorkerIdentity,
    generation: CustodianGeneration,
    logon: LogonSession,
    executable: LocalPath,
    process_identity: ProcessIdentity,
    suspended_thread: Option<OwnedHandle>,
}

impl Worker {
    /// @cc [owner:ghuntley,label:security;recovery] windows-editor-suspended-account-launch
    /// Launch MUST verify the current local and S4U token SID, create the exact
    /// configured executable directly with no inherited handles, and assign its
    /// process atomically to a SYSTEM-only kill-on-close job through `JOB_LIST`.
    /// It MUST return suspended, without inherited handles, until the custodian
    /// publishes the receipt. Custodian loss at every intermediate point MUST
    /// kill the child; the TCP gateway MUST never hold a worker job handle.
    #[expect(
        clippy::too_many_lines,
        reason = "one atomic launch sequence whose job and handles must be stopped on every failure path"
    )]
    pub fn launch(
        identity: WorkerIdentity,
        generation: CustodianGeneration,
        package: &Package,
    ) -> Result<Self, LaunchFailure> {
        package_file(&package.node)?;
        package_file(&package.server)?;
        package_file(&package.extra_ca_certs)?;
        for directory in package.worker_path.directories() {
            package_directory(directory)?;
        }
        privilege(SE_ASSIGNPRIMARYTOKEN_NAME)?;
        privilege(SE_INCREASE_QUOTA_NAME)?;
        privilege(SE_TCB_NAME)?;
        let token = account_token(&identity)?;
        // Recorded before launch so a later custodian can prove quiescence of
        // exactly this worker's processes without its job handle.
        let logon = token_logon(raw(&token))?;
        let home = profile_directory(raw(&token))?;
        let mut command = command_line(&[
            package.node.as_str().to_owned(),
            package.server.as_str().to_owned(),
            "--without-connection-token".to_owned(),
            "--socket-path".to_owned(),
            identity.pipe_name(generation),
            "--server-data-dir".to_owned(),
            format!(r"{}\.overalls-code-server", home.as_str()),
            "--enable-remote-auto-shutdown".to_owned(),
            "--reconnection-grace-time".to_owned(),
            "1500".to_owned(),
            "--disable-telemetry".to_owned(),
            "--disable-workspace-trust".to_owned(),
            "--default-folder".to_owned(),
            r"C:\workspace".to_owned(),
        ])?;
        let mut pairs = vec![
            ("HOME", home.as_str().to_owned()),
            ("USERPROFILE", home.as_str().to_owned()),
            ("USERNAME", identity.username().to_owned()),
            ("SystemRoot", package.system_root.as_str().to_owned()),
            ("WINDIR", package.system_root.as_str().to_owned()),
            ("PATH", package.worker_path.as_str().to_owned()),
            ("APPDATA", format!(r"{}\AppData\Roaming", home.as_str())),
            ("LOCALAPPDATA", format!(r"{}\AppData\Local", home.as_str())),
            (
                "COMSPEC",
                format!(r"{}\System32\cmd.exe", package.system_root.as_str()),
            ),
            ("PATHEXT", ".COM;.EXE;.BAT;.CMD".to_owned()),
            (
                "NODE_EXTRA_CA_CERTS",
                package.extra_ca_certs.as_str().to_owned(),
            ),
            ("TEMP", format!(r"{}\AppData\Local\Temp", home.as_str())),
            ("TMP", format!(r"{}\AppData\Local\Temp", home.as_str())),
            ("OVERALLS_EDITOR_ORIGIN", identity.origin().to_owned()),
            (
                "OVERALLS_WEBVIEW_ENDPOINT_TEMPLATE",
                identity.webview_template().to_owned(),
            ),
        ];
        pairs.sort_by_key(|(key, _)| key.to_ascii_uppercase());
        let environment: Vec<u16> = pairs
            .into_iter()
            .flat_map(|(key, value)| wide(&format!("{key}={value}")))
            .chain([0])
            .collect();
        let job = new_job(&identity, generation)?;
        let attributes = JobAttributes::new(&job)?;
        // SAFETY: STARTUPINFOEXW is a plain C struct for which all-zero bytes are a valid value.
        let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
        startup.StartupInfo.cb =
            u32::try_from(size_of::<STARTUPINFOEXW>()).map_err(|_| Refusal::Startup)?;
        startup.lpAttributeList = attributes.pointer();
        let mut desktop = wide("");
        startup.StartupInfo.lpDesktop = desktop.as_mut_ptr();
        let application = wide(package.node.as_str());
        let directory = wide(home.as_str());
        // SAFETY: PROCESS_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
        let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
        // SAFETY: the token is an owned primary token; application, command, environment, directory and desktop are live NUL-terminated UTF-16 buffers; `startup` and its attribute list outlive the call, and `information` is a live writable local.
        if unsafe {
            CreateProcessAsUserW(
                raw(&token),
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_SUSPENDED
                    | CREATE_UNICODE_ENVIRONMENT
                    | CREATE_NO_WINDOW
                    | CREATE_BREAKAWAY_FROM_JOB
                    | EXTENDED_STARTUPINFO_PRESENT,
                environment.as_ptr().cast(),
                directory.as_ptr(),
                &raw const startup.StartupInfo,
                &raw mut information,
            )
        } == 0
        {
            return Err(Refusal::Startup.into());
        }
        let process = owned(information.hProcess, Refusal::Startup);
        let thread = owned(information.hThread, Refusal::Startup);
        let (process, thread) = match (process, thread) {
            (Ok(process), Ok(thread)) => (process, thread),
            partial => {
                // Any opened handle stays open until the owned job is stopped.
                let stopped = stop_owned_job(&job);
                drop(partial);
                if let Err(reason) = stopped {
                    return Err(LaunchFailure {
                        reason,
                        quarantine: Some(QuarantinedJob { _job: job }),
                    });
                }
                return Err(Refusal::Startup.into());
            }
        };
        let launched: Result<ProcessIdentity, Refusal> = (|| {
            let process_identity = process_identity(&process)?;
            verify_peer(
                &identity,
                process_identity,
                &peer(&process, &job, &package.node)?,
            )?;
            Ok(process_identity)
        })();
        match launched {
            Ok(process_identity) => Ok(Self {
                process,
                job,
                identity,
                generation,
                logon,
                executable: package.node.clone(),
                process_identity,
                suspended_thread: Some(thread),
            }),
            Err(error) => {
                if let Err(reason) = stop_owned_job(&job) {
                    return Err(LaunchFailure {
                        reason,
                        quarantine: Some(QuarantinedJob { _job: job }),
                    });
                }
                Err(error.into())
            }
        }
    }

    pub fn process_identity(&self) -> ProcessIdentity {
        self.process_identity
    }

    pub fn matches(&self, identity: &WorkerIdentity, generation: CustodianGeneration) -> bool {
        &self.identity == identity && self.generation == generation
    }

    pub fn logon_session(&self) -> LogonSession {
        self.logon
    }

    /// Resume only after the complete private receipt has been published.
    pub fn resume(&mut self) -> Result<(), Refusal> {
        let thread = self.suspended_thread.as_ref().ok_or(Refusal::Custody)?;
        // SAFETY: the suspended thread handle is owned and open.
        if unsafe { ResumeThread(raw(thread)) } != 1 {
            return Err(Refusal::Startup);
        }
        self.suspended_thread = None;
        Ok(())
    }

    /// A retained process is live only when its PID and creation time remain
    /// exact and the process is still in the verified named job.
    pub fn is_running(&self) -> Result<bool, Refusal> {
        let observed = process_identity(&self.process)?;
        if observed != self.process_identity {
            return Err(Refusal::Custody);
        }
        // SAFETY: the process handle is owned and open; a zero timeout never blocks.
        match unsafe { WaitForSingleObject(raw(&self.process), 0) } {
            WAIT_OBJECT_0 => return Ok(false),
            WAIT_TIMEOUT => {}
            _ => return Err(Refusal::Custody),
        }
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        Ok(true)
    }

    /// @cc [owner:ghuntley,label:security] windows-editor-connected-pipe-custody
    /// A returned pipe MUST be connected to the exact retained worker process
    /// after kernel PID, creation-time, token-SID, executable and job checks.
    /// The open MUST permit identification only, so a foreign pipe
    /// server cannot impersonate the `LocalSystem` broker. Failure closes the
    /// connection without killing or deleting the possible server.
    pub fn connect(&self) -> Result<Pipe, Refusal> {
        let reservation = Pipe::reserve().map_err(|_| Refusal::Capacity)?;
        let pipe_name = wide(&self.identity.pipe_name(self.generation));
        // SAFETY: `pipe_name` is a live NUL-terminated UTF-16 pipe name.
        if unsafe { WaitNamedPipeW(pipe_name.as_ptr(), 2_000) } == 0 {
            return Err(Refusal::Readiness);
        }
        let pipe = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION | FILE_FLAG_OVERLAPPED)
            .open(self.identity.pipe_name(self.generation))
            .map_err(|_| Refusal::Readiness)?;
        let mut pid = 0;
        // SAFETY: the pipe handle is open for the borrow of `pipe` and `pid` is a live writable local.
        if unsafe { GetNamedPipeServerProcessId(pipe.as_raw_handle(), &raw mut pid) } == 0
            || pid != self.process_identity.pid
        {
            return Err(Refusal::Custody);
        }
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        Pipe::from_file(pipe, reservation).map_err(|_| Refusal::Readiness)
    }

    /// End only the verified job; personal profile/workspace files are untouched.
    pub fn terminate(&self) -> Result<(), Refusal> {
        system_job(&self.job)?;
        if process_identity(&self.process)? != self.process_identity {
            return Err(Refusal::Custody);
        }
        // SAFETY: the process handle is owned and open; a zero timeout never blocks.
        match unsafe { WaitForSingleObject(raw(&self.process), 0) } {
            WAIT_TIMEOUT => {
                verify_peer(
                    &self.identity,
                    self.process_identity,
                    &peer(&self.process, &self.job, &self.executable)?,
                )?;
            }
            // Both retained handles were verified when this Worker was built;
            // a dead root cannot erase custody of its remaining descendants.
            WAIT_OBJECT_0 => {}
            _ => return Err(Refusal::Custody),
        }
        stop_owned_job(&self.job)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// SYSTEM-only native check of the two recovery observations. It does not
    /// launch a personal worker, kill a straggler or crash a custodian.
    #[test]
    fn native_closed_job_name_vanishes_and_snapshot_reports_system_tokens() {
        require_system().expect("native custody tests require SYSTEM");
        let name = format!(r"Global\overalls-editor-prior-test-{}", std::process::id());
        assert_eq!(job_name_present(&name), Ok(false));
        let job = new_job_named(&name).unwrap();
        assert_eq!(job_name_present(&name), Ok(true));
        drop(job);
        assert_eq!(job_name_present(&name), Ok(false));
        let observations = observe_processes().unwrap();
        let own = std::process::id();
        assert!(observations.iter().any(|observation| matches!(
            observation,
            ProcessObservation::Opened {
                process,
                token: TokenObservation::NonAccount,
            } if process.pid == own
        )));
    }

    /// This requires an explicitly SYSTEM-run native test executable. Cross
    /// compilation does not exercise atomic launch or kill-on-close timing.
    #[test]
    fn native_atomic_job_assignment_closes_suspended_orphan_window() {
        use windows_sys::Win32::System::Threading::CreateProcessW;
        require_system().expect("native custody tests require SYSTEM");
        let name = format!(r"Global\overalls-editor-atomic-test-{}", std::process::id());
        let job = new_job_named(&name).unwrap();
        let attributes = JobAttributes::new(&job).unwrap();
        // SAFETY: STARTUPINFOEXW is a plain C struct for which all-zero bytes are a valid value.
        let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
        startup.StartupInfo.cb = u32::try_from(size_of::<STARTUPINFOEXW>()).unwrap();
        startup.lpAttributeList = attributes.pointer();
        let application = wide(r"C:\Windows\System32\cmd.exe");
        let mut command = command_line(&[
            r"C:\Windows\System32\cmd.exe".to_owned(),
            "/c".to_owned(),
            "exit 0".to_owned(),
        ])
        .unwrap();
        // SAFETY: PROCESS_INFORMATION is a plain C struct for which all-zero bytes are a valid value.
        let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
        assert_ne!(
            // SAFETY: application and command are live NUL-terminated UTF-16 buffers, `startup` and its attribute list outlive the call, and `information` is a live writable local.
            unsafe {
                CreateProcessW(
                    application.as_ptr(),
                    command.as_mut_ptr(),
                    null(),
                    null(),
                    0,
                    CREATE_SUSPENDED
                        | CREATE_NO_WINDOW
                        | CREATE_BREAKAWAY_FROM_JOB
                        | EXTENDED_STARTUPINFO_PRESENT,
                    null(),
                    null(),
                    &raw const startup.StartupInfo,
                    &raw mut information,
                )
            },
            0
        );
        let process = owned(information.hProcess, Refusal::Startup).unwrap();
        let _thread = owned(information.hThread, Refusal::Startup).unwrap();
        let identity = process_identity(&process).unwrap();
        let mut member = 0;
        assert_ne!(
            // SAFETY: both handles are owned and open, and `member` is a live writable local.
            unsafe { IsProcessInJob(raw(&process), raw(&job), &raw mut member) },
            0
        );
        assert_ne!(member, 0);
        assert_eq!(
            // SAFETY: the process handle is owned and open; a zero timeout never blocks.
            unsafe { WaitForSingleObject(raw(&process), 0) },
            WAIT_TIMEOUT
        );
        drop(attributes);
        drop(job);
        assert_eq!(
            // SAFETY: the process handle is owned and open, and the wait is bounded to five seconds.
            unsafe { WaitForSingleObject(raw(&process), 5000) },
            WAIT_OBJECT_0
        );
        assert_eq!(process_identity(&process).unwrap(), identity);
    }

    const TRUSTED_INSTALLER: &str =
        "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

    fn check_descriptor(sddl: &str, authority: FileAuthority) -> Result<(), Refusal> {
        let mut descriptor = null_mut();
        assert_ne!(
            // SAFETY: the temporary SDDL is a NUL-terminated UTF-16 string that lives until the end of the statement, and `descriptor` is a writable out-pointer.
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    wide(sddl).as_ptr(),
                    1,
                    &raw mut descriptor,
                    null_mut(),
                )
            },
            0
        );
        // SAFETY: this descriptor is owned by this fixture and retained until
        // the same production validator has finished reading its owner/DACL.
        let result = unsafe { descriptor_acl(descriptor, authority) };
        // SAFETY: `descriptor` was allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW and is freed exactly once after its last use.
        unsafe {
            LocalFree(descriptor);
        }
        result
    }

    #[test]
    fn native_platform_authority_is_scoped_to_directories_and_ancestors() {
        let platform = format!(
            "O:{TRUSTED_INSTALLER}G:SYD:P(A;;FA;;;SY)(A;;FA;;;{TRUSTED_INSTALLER})(A;;GR;;;BU)"
        );
        for authority in [FileAuthority::Ancestor, FileAuthority::WorkerDirectory] {
            assert_eq!(check_descriptor(&platform, authority), Ok(()));
        }
        for authority in [FileAuthority::Package, FileAuthority::SystemOnly] {
            assert_eq!(
                check_descriptor(&platform, authority),
                Err(Refusal::Custody)
            );
        }
        let inherited_platform =
            format!("O:BAG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;{TRUSTED_INSTALLER})(A;;GR;;;BU)");
        assert_eq!(
            check_descriptor(&inherited_platform, FileAuthority::WorkerDirectory),
            Ok(())
        );
        assert_eq!(
            check_descriptor(&inherited_platform, FileAuthority::Package),
            Err(Refusal::Custody)
        );
        let foreign_service = platform.replace("-2271478464", "-2271478465");
        for authority in [FileAuthority::Ancestor, FileAuthority::WorkerDirectory] {
            assert_eq!(
                check_descriptor(&foreign_service, authority),
                Err(Refusal::Custody)
            );
        }
    }

    #[test]
    fn native_directory_custody_refuses_foreign_owners_and_write_authority() {
        for authority in [FileAuthority::Ancestor, FileAuthority::WorkerDirectory] {
            for descriptor in [
                "O:LSG:SYD:P(A;;FA;;;SY)",
                "O:SYG:SYD:P(A;;FA;;;SY)(A;;GW;;;BU)",
                "O:SYG:SYD:P(A;;FA;;;SY)(A;;WD;;;BU)",
                "O:SYG:SYD:P(A;;FA;;;SY)(A;;0x00000040;;;BU)",
                "O:SYG:SY",
                "O:SYG:SYD:P",
            ] {
                assert_eq!(
                    check_descriptor(descriptor, authority),
                    Err(Refusal::Custody),
                    "{descriptor}"
                );
            }
        }
        let unrelated_children = "O:SYG:SYD:P(A;;FA;;;SY)(A;;0x00000006;;;BU)";
        assert_eq!(
            check_descriptor(unrelated_children, FileAuthority::Ancestor),
            Ok(())
        );
        assert_eq!(
            check_descriptor(unrelated_children, FileAuthority::WorkerDirectory),
            Err(Refusal::Custody)
        );
        assert_eq!(
            check_descriptor("O:SYG:SYD:P(A;;FA;;;SY)", FileAuthority::SystemOnly),
            Ok(())
        );
    }
}
