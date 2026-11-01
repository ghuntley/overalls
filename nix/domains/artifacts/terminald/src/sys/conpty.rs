//! `ConPTY`, account, logon, profile, job and process calls for Windows
//! terminal sessions (ADR-0171). `crate::pty` keeps the session policy and
//! the acquire-and-release order; this module holds only the calls that need
//! `unsafe`. Handle arguments are plain values, as in `sys::windows`.
use super::windows::{last_error as last_error_code, wide};
use std::io;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use windows_sys::core::BOOL;
use windows_sys::Win32::Foundation::{HANDLE, LUID};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NetApiBufferFree, NetUserEnum, NetUserGetInfo, FILTER_NORMAL_ACCOUNT, MAX_PREFERRED_LENGTH,
    USER_INFO_1,
};
use windows_sys::Win32::Security::Authentication::Identity::{
    LsaDeregisterLogonProcess, LsaFreeReturnBuffer, LsaLogonUser, LsaLookupAuthenticationPackage,
    LsaRegisterLogonProcess, MsV1_0S4ULogon, LSA_STRING, LSA_UNICODE_STRING, MSV1_0_S4U_LOGON,
    SECURITY_LOGON_TYPE,
};
use windows_sys::Win32::Security::{
    AdjustTokenPrivileges, AllocateLocallyUniqueId, LookupPrivilegeValueW, LUID_AND_ATTRIBUTES,
    QUOTA_LIMITS, SE_ASSIGNPRIMARYTOKEN_NAME, SE_INCREASE_QUOTA_NAME, SE_PRIVILEGE_ENABLED,
    TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES, TOKEN_QUERY, TOKEN_SOURCE,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows_sys::Win32::System::Console::{
    ClosePseudoConsole, CreatePseudoConsole, ResizePseudoConsole, COORD, HPCON,
};
use windows_sys::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::Pipes::{CreatePipe, PeekNamedPipe};
use windows_sys::Win32::System::Threading::{
    CreateProcessAsUserW, CreateProcessW, DeleteProcThreadAttributeList, GetCurrentProcess,
    InitializeProcThreadAttributeList, OpenProcessToken, ResumeThread, TerminateProcess,
    UpdateProcThreadAttribute, WaitForSingleObject, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
    EXTENDED_STARTUPINFO_PRESENT, LPPROC_THREAD_ATTRIBUTE_LIST, PROCESS_INFORMATION,
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, STARTUPINFOEXW,
};
use windows_sys::Win32::UI::Shell::{LoadUserProfileW, UnloadUserProfile, PROFILEINFOW};

const SHELL: &str = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";

fn last_error() -> io::Error {
    io::Error::from_raw_os_error(last_error_code().cast_signed())
}

/// # Safety
///
/// `pointer` is null or a NUL-terminated UTF-16 string in a live buffer.
unsafe fn from_wide(pointer: *const u16) -> String {
    if pointer.is_null() {
        return String::new();
    }
    #[expect(
        clippy::maybe_infinite_iter,
        reason = "the caller's string is NUL-terminated, so take_while stops at the terminator"
    )]
    let length = (0..)
        .take_while(|&index| {
            // SAFETY: the caller passes a NUL-terminated UTF-16 string owned by
            // a live buffer, and no index past its terminator is reached.
            let unit = unsafe { pointer.add(index) };
            // SAFETY: `unit` lies within that string, at or before its terminator.
            unsafe { *unit != 0 }
        })
        .count();
    // SAFETY: the `length` units before the terminator were just read through
    // `pointer`, so they are initialized and live for this call.
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(pointer, length) })
}

/// The `usri1_flags` of local account `name`, or `None` when it cannot be read.
pub(crate) fn local_account_flags(name: &str) -> Option<u32> {
    let user = wide(name);
    let mut buffer: *mut u8 = null_mut();
    // SAFETY: level 1 fills one USER_INFO_1 that we free with NetApiBufferFree.
    let status = unsafe { NetUserGetInfo(null(), user.as_ptr(), 1, &raw mut buffer) };
    if status != 0 || buffer.is_null() {
        return None;
    }
    #[expect(
        clippy::cast_ptr_alignment,
        reason = "NetApiBufferAllocate returns allocator-aligned memory holding a USER_INFO_1"
    )]
    let info = buffer as *const USER_INFO_1;
    // SAFETY: a successful level-1 call returns a USER_INFO_1.
    let flags = unsafe { (*info).usri1_flags };
    // SAFETY: `buffer` came from NetUserGetInfo and is freed exactly once.
    unsafe { NetApiBufferFree(buffer.cast()) };
    Some(flags)
}

/// Every normal local account as `(name, usri1_flags)`, or `None` when the
/// inventory is unavailable.
pub(crate) fn local_accounts() -> Option<Vec<(String, u32)>> {
    let mut accounts = Vec::new();
    let mut buffer: *mut u8 = null_mut();
    let mut read = 0u32;
    let mut total = 0u32;
    // SAFETY: level 1 with MAX_PREFERRED_LENGTH returns one buffer of
    // `read` USER_INFO_1 entries that we free once.
    let status = unsafe {
        NetUserEnum(
            null(),
            1,
            FILTER_NORMAL_ACCOUNT,
            &raw mut buffer,
            MAX_PREFERRED_LENGTH,
            &raw mut read,
            &raw mut total,
            null_mut(),
        )
    };
    if status != 0 {
        if !buffer.is_null() {
            // SAFETY: `buffer` came from NetUserEnum and is freed exactly once.
            unsafe { NetApiBufferFree(buffer.cast()) };
        }
        return None;
    }
    if !buffer.is_null() {
        #[expect(
            clippy::cast_ptr_alignment,
            reason = "NetApiBufferAllocate returns allocator-aligned memory holding \
                      USER_INFO_1 entries"
        )]
        let first = buffer as *const USER_INFO_1;
        // SAFETY: `read` entries of USER_INFO_1 follow `buffer`.
        let entries = unsafe { std::slice::from_raw_parts(first, read as usize) };
        for entry in entries {
            // SAFETY: each entry's name is a NUL-terminated string inside the
            // NetUserEnum buffer, which is still alive.
            let name = unsafe { from_wide(entry.usri1_name) };
            accounts.push((name, entry.usri1_flags));
        }
        // SAFETY: `buffer` came from NetUserEnum and is freed exactly once,
        // after the last read of `entries`.
        unsafe { NetApiBufferFree(buffer.cast()) };
    }
    Some(accounts)
}

/// `PeekNamedPipe` for the byte count available on a pipe read handle.
pub(crate) fn peek_available(handle: HANDLE, available: &mut u32) -> BOOL {
    // SAFETY: only the count is written, to `available`, a live exclusive u32.
    unsafe {
        PeekNamedPipe(
            handle,
            null_mut(),
            0,
            null_mut(),
            std::ptr::from_mut(available),
            null_mut(),
        )
    }
}

/// `WaitForSingleObject`.
pub(crate) fn wait_for(handle: HANDLE, millis: u32) -> u32 {
    // SAFETY: waits on a handle value and touches no caller memory.
    unsafe { WaitForSingleObject(handle, millis) }
}

/// One synchronous `ReadFile` into `buf`.
pub(crate) fn read_file(handle: HANDLE, buf: &mut [u8], read: &mut u32) -> BOOL {
    let length = u32::try_from(buf.len()).unwrap_or(u32::MAX);
    // SAFETY: `buf` is writable for `length` bytes and `read` is a live
    // exclusive u32; synchronous read.
    unsafe {
        ReadFile(
            handle,
            buf.as_mut_ptr(),
            length,
            std::ptr::from_mut(read),
            null_mut(),
        )
    }
}

/// One synchronous `WriteFile` of `data`.
pub(crate) fn write_file(handle: HANDLE, data: &[u8], written: &mut u32) -> BOOL {
    let length = u32::try_from(data.len()).unwrap_or(u32::MAX);
    // SAFETY: `data` is readable for `length` bytes and `written` is a live
    // exclusive u32; synchronous write.
    unsafe {
        WriteFile(
            handle,
            data.as_ptr(),
            length,
            std::ptr::from_mut(written),
            null_mut(),
        )
    }
}

/// `CreatePipe` without inheritance.
pub(crate) fn create_pipe(read: &mut HANDLE, write: &mut HANDLE) -> BOOL {
    // SAFETY: anonymous pipes without inheritance; both ends are written to
    // live exclusive references.
    unsafe {
        CreatePipe(
            std::ptr::from_mut(read),
            std::ptr::from_mut(write),
            null(),
            0,
        )
    }
}

/// `CreatePseudoConsole` over the console-side pipe ends.
pub(crate) fn create_pseudo_console(
    size: COORD,
    input: HANDLE,
    output: HANDLE,
    pseudo: &mut HPCON,
) -> i32 {
    // SAFETY: conhost duplicates the pipe ends it needs; the console is
    // written to `pseudo`, a live exclusive reference.
    unsafe { CreatePseudoConsole(size, input, output, 0, std::ptr::from_mut(pseudo)) }
}

/// `ResizePseudoConsole`.
pub(crate) fn resize_pseudo_console(pseudo: HPCON, size: COORD) -> i32 {
    // SAFETY: takes the console value and a size by value; no caller memory.
    unsafe { ResizePseudoConsole(pseudo, size) }
}

/// `ClosePseudoConsole`. Callers close each pseudo console exactly once.
pub(crate) fn close_pseudo_console(pseudo: HPCON) {
    // SAFETY: takes the console value only; no caller memory.
    unsafe { ClosePseudoConsole(pseudo) };
}

/// `CreateJobObjectW`: an anonymous job with default security.
pub(crate) fn create_job() -> HANDLE {
    // SAFETY: an anonymous job with default security; no pointers are read.
    unsafe { CreateJobObjectW(null(), null()) }
}

/// Make `job` kill every process it holds when its last handle closes.
pub(crate) fn set_kill_on_close(job: HANDLE) -> BOOL {
    // SAFETY: the limit structure is plain integer data; all-zero is valid.
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the extended limit structure is under 200 bytes"
    )]
    let limits_size = size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32;
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: the extended limit structure is passed with its exact size.
    unsafe {
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            limits_size,
        )
    }
}

/// `AssignProcessToJobObject`.
pub(crate) fn assign_to_job(job: HANDLE, process: HANDLE) -> BOOL {
    // SAFETY: takes two handle values; no caller memory.
    unsafe { AssignProcessToJobObject(job, process) }
}

/// `TerminateJobObject`.
pub(crate) fn terminate_job(job: HANDLE, code: u32) -> BOOL {
    // SAFETY: takes a handle value and an exit code; no caller memory.
    unsafe { TerminateJobObject(job, code) }
}

/// `TerminateProcess`.
pub(crate) fn terminate_process(process: HANDLE, code: u32) -> BOOL {
    // SAFETY: takes a handle value and an exit code; no caller memory.
    unsafe { TerminateProcess(process, code) }
}

/// `ResumeThread`.
pub(crate) fn resume_thread(thread: HANDLE) -> u32 {
    // SAFETY: takes a thread handle value; no caller memory.
    unsafe { ResumeThread(thread) }
}

/// `LoadUserProfileW` for account `name` under `token`, without UI.
pub(crate) fn load_user_profile(token: HANDLE, name: &str) -> io::Result<HANDLE> {
    let mut name = wide(name);
    // SAFETY: PROFILEINFOW is plain data; all-zero (null pointers) is valid.
    let mut info: PROFILEINFOW = unsafe { zeroed() };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "PROFILEINFOW is a few dozen bytes"
    )]
    let info_size = size_of::<PROFILEINFOW>() as u32;
    info.dwSize = info_size;
    info.dwFlags = 1; // PI_NOUI
    info.lpUserName = name.as_mut_ptr();
    // SAFETY: `info` and `name` live across the call.
    if unsafe { LoadUserProfileW(token, &raw mut info) } == 0 {
        return Err(last_error());
    }
    Ok(info.hProfile)
}

/// `UnloadUserProfile`.
pub(crate) fn unload_user_profile(token: HANDLE, profile: HANDLE) -> BOOL {
    // SAFETY: takes two handle values; no caller memory.
    unsafe { UnloadUserProfile(token, profile) }
}

/// A token privilege terminald enables on its own process token.
pub(crate) enum Privilege {
    AssignPrimaryToken,
    IncreaseQuota,
}

pub(crate) fn enable_privilege(privilege: &Privilege) -> io::Result<()> {
    let name = match privilege {
        Privilege::AssignPrimaryToken => SE_ASSIGNPRIMARYTOKEN_NAME,
        Privilege::IncreaseQuota => SE_INCREASE_QUOTA_NAME,
    };
    let mut token: HANDLE = null_mut();
    // SAFETY: GetCurrentProcess returns a pseudo-handle and has no preconditions.
    let process = unsafe { GetCurrentProcess() };
    // SAFETY: opening our own process token for privilege adjustment; `token`
    // is a live local the call writes.
    if unsafe {
        OpenProcessToken(
            process,
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &raw mut token,
        )
    } == 0
    {
        return Err(last_error());
    }
    // SAFETY: LUID is plain integer data; all-zero is a valid value.
    let mut luid: LUID = unsafe { zeroed() };
    let result = (|| {
        // SAFETY: `name` is a static privilege name; `luid` is writable.
        if unsafe { LookupPrivilegeValueW(null(), name, &raw mut luid) } == 0 {
            return Err(last_error());
        }
        let privileges = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES {
                Luid: luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };
        // SAFETY: one privilege entry; no previous state requested.
        if unsafe {
            AdjustTokenPrivileges(token, 0, &raw const privileges, 0, null_mut(), null_mut())
        } == 0
        {
            return Err(last_error());
        }
        Ok(())
    })();
    // SAFETY: `token` was opened above and is closed exactly once.
    unsafe { windows_sys::Win32::Foundation::CloseHandle(token) };
    result
}

/// An S4U logon of an enabled local account, as Win32-OpenSSH performs for
/// key logins: no password exists or is needed, and the daemon's `LocalSystem`
/// token supplies the trusted-computing-base privilege LSA requires.
#[expect(
    clippy::too_many_lines,
    reason = "the S4U request layout and its register-logon-deregister sequence stay together"
)]
pub(crate) fn s4u_token(name: &str) -> io::Result<HANDLE> {
    let mut process_name = *b"overalls-terminald";
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the logon process name is an 18-byte literal"
    )]
    let process_length = process_name.len() as u16;
    let process = LSA_STRING {
        Length: process_length,
        MaximumLength: process_length,
        Buffer: process_name.as_mut_ptr(),
    };
    let mut lsa: HANDLE = null_mut();
    let mut mode = 0u32;
    // SAFETY: registers this process as a logon process (requires SeTcbPrivilege).
    if unsafe { LsaRegisterLogonProcess(&raw const process, &raw mut lsa, &raw mut mode) } != 0 {
        return Err(io::Error::other("logon process registration refused"));
    }
    let result = (|| {
        let mut package_name = *b"MICROSOFT_AUTHENTICATION_PACKAGE_V1_0";
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the package name is a 37-byte literal"
        )]
        let package_length = package_name.len() as u16;
        let package = LSA_STRING {
            Length: package_length,
            MaximumLength: package_length,
            Buffer: package_name.as_mut_ptr(),
        };
        let mut package_id = 0u32;
        // SAFETY: `package` names the MSV1_0 package; the id is written.
        if unsafe { LsaLookupAuthenticationPackage(lsa, &raw const package, &raw mut package_id) }
            != 0
        {
            return Err(io::Error::other("authentication package unavailable"));
        }
        let user: Vec<u16> = name.encode_utf16().collect();
        let domain: Vec<u16> = ".".encode_utf16().collect();
        let header = size_of::<MSV1_0_S4U_LOGON>();
        let total = header + (user.len() + domain.len()) * 2;
        // u64 storage keeps the struct aligned; strings follow it in one buffer.
        let mut storage = vec![0u64; total.div_ceil(8)];
        let base = storage.as_mut_ptr().cast::<u8>();
        // `storage` has `total` bytes; the struct is written at offset 0 and
        // the two UTF-16 strings after it, each within bounds.
        // SAFETY: `header` is at most `total` bytes into `storage`.
        let after_header = unsafe { base.add(header) };
        #[expect(
            clippy::cast_ptr_alignment,
            reason = "`storage` is u64-aligned and `header`, a struct size with 8-byte \
                      alignment, keeps the offset u16-aligned"
        )]
        let user_at = after_header.cast::<u16>();
        // SAFETY: `user.len()` UTF-16 units fit between `header` and `total`,
        // and the local `user` vector does not overlap `storage`.
        unsafe { std::ptr::copy_nonoverlapping(user.as_ptr(), user_at, user.len()) };
        // SAFETY: the domain follows the user name inside the `total` bytes.
        let domain_at = unsafe { user_at.add(user.len()) };
        // SAFETY: `domain.len()` UTF-16 units end exactly at `total`, and the
        // local `domain` vector does not overlap `storage`.
        unsafe { std::ptr::copy_nonoverlapping(domain.as_ptr(), domain_at, domain.len()) };
        // Roster names are at most NAME_MAX (20) units and the domain is ".",
        // so both byte lengths fit u16.
        #[expect(
            clippy::cast_possible_truncation,
            reason = "valid_name bounds the user to 20 UTF-16 units"
        )]
        let user_bytes = (user.len() * 2) as u16;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the domain is the one-unit string \".\""
        )]
        let domain_bytes = (domain.len() * 2) as u16;
        #[expect(
            clippy::cast_ptr_alignment,
            reason = "`storage` is a Vec<u64>, so offset 0 is 8-byte aligned"
        )]
        let request = base.cast::<MSV1_0_S4U_LOGON>();
        // SAFETY: `request` is the aligned start of `storage`, which holds at
        // least `header` bytes for the struct.
        unsafe {
            *request = MSV1_0_S4U_LOGON {
                MessageType: MsV1_0S4ULogon,
                Flags: 0,
                UserPrincipalName: LSA_UNICODE_STRING {
                    Length: user_bytes,
                    MaximumLength: user_bytes,
                    Buffer: user_at,
                },
                DomainName: LSA_UNICODE_STRING {
                    Length: domain_bytes,
                    MaximumLength: domain_bytes,
                    Buffer: domain_at,
                },
            };
        }
        // SAFETY: TOKEN_SOURCE is plain integer data; all-zero is valid.
        let mut source: TOKEN_SOURCE = unsafe { zeroed() };
        for (slot, byte) in source.SourceName.iter_mut().zip(b"overalls\0") {
            *slot = byte.cast_signed();
        }
        // SAFETY: writes one LUID.
        unsafe { AllocateLocallyUniqueId(&raw mut source.SourceIdentifier) };
        let mut profile: *mut core::ffi::c_void = null_mut();
        let mut profile_length = 0u32;
        // SAFETY: LUID is plain integer data; all-zero is valid.
        let mut logon_id: LUID = unsafe { zeroed() };
        let mut token: HANDLE = null_mut();
        // SAFETY: QUOTA_LIMITS is plain integer data; all-zero is valid.
        let mut quotas: QUOTA_LIMITS = unsafe { zeroed() };
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the request is one struct plus at most 22 UTF-16 units"
        )]
        let total_length = total as u32;
        let mut substatus = 0i32;
        // SAFETY: every pointer is valid for the call; `storage` holds the
        // self-relative S4U request of `total` bytes.
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
                &raw mut logon_id,
                &raw mut token,
                &raw mut quotas,
                &raw mut substatus,
            )
        };
        if !profile.is_null() {
            // SAFETY: `profile` was returned by LsaLogonUser and is freed once.
            unsafe { LsaFreeReturnBuffer(profile) };
        }
        if status != 0 || token.is_null() {
            return Err(io::Error::other("S4U logon refused"));
        }
        Ok(token)
    })();
    // SAFETY: `lsa` was registered above and is deregistered exactly once.
    unsafe { LsaDeregisterLogonProcess(lsa) };
    result
}

/// The account environment of `token` as `(key, value)` pairs, skipping
/// entries without a key.
pub(crate) fn token_environment(token: HANDLE) -> io::Result<Vec<(String, String)>> {
    let mut pairs = Vec::new();
    let mut block: *mut core::ffi::c_void = null_mut();
    // SAFETY: builds the account's environment; destroyed below.
    if unsafe { CreateEnvironmentBlock(&raw mut block, token, 0) } == 0 {
        return Err(last_error());
    }
    let mut cursor = block as *const u16;
    loop {
        // SAFETY: `cursor` points at the next NUL-terminated entry inside the
        // live environment block, which ends with an empty entry.
        let entry = unsafe { from_wide(cursor) };
        if entry.is_empty() {
            break;
        }
        // SAFETY: advance past this entry and its terminator inside the block.
        cursor = unsafe { cursor.add(entry.encode_utf16().count() + 1) };
        if let Some((key, value)) = entry.split_once('=').filter(|(key, _)| !key.is_empty()) {
            pairs.push((key.to_owned(), value.to_owned()));
        }
    }
    // SAFETY: `block` came from CreateEnvironmentBlock and is destroyed
    // once, after the last read through `cursor`.
    unsafe { DestroyEnvironmentBlock(block) };
    Ok(pairs)
}

/// A UTF-16 `KEY=value` environment block, double-NUL terminated.
pub(crate) struct EnvironmentBlock(Vec<u16>);

impl EnvironmentBlock {
    pub(crate) fn new(pairs: Vec<(String, String)>) -> Self {
        let mut block: Vec<u16> = Vec::new();
        for (key, value) in pairs {
            block.extend(format!("{key}={value}").encode_utf16());
            block.push(0);
        }
        block.push(0);
        Self(block)
    }
}

/// Create the session shell suspended on `pseudo`, as `LocalSystem` when
/// `system` or under `token` otherwise: its process and thread handles and
/// process ID.
pub(crate) fn launch(
    token: HANDLE,
    pseudo: HPCON,
    environment: &mut EnvironmentBlock,
    home: &str,
    system: bool,
) -> io::Result<(HANDLE, HANDLE, u32)> {
    let environment = &mut environment.0;
    let mut size = 0usize;
    // SAFETY: a null list asks for the required size (expected to "fail").
    unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &raw mut size) };
    let mut storage = vec![0u64; size.div_ceil(8)];
    let list = storage.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
    // SAFETY: `storage` holds `size` bytes for one attribute.
    if unsafe { InitializeProcThreadAttributeList(list, 1, 0, &raw mut size) } == 0 {
        return Err(last_error());
    }
    let result = (|| {
        // SAFETY: the attribute value is the HPCON itself, passed by value as
        // ConPTY requires, and outlives process creation.
        if unsafe {
            UpdateProcThreadAttribute(
                list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                pseudo as *const _,
                size_of::<HPCON>(),
                null_mut(),
                null(),
            )
        } == 0
        {
            return Err(last_error());
        }
        // SAFETY: STARTUPINFOEXW is plain data; all-zero (null pointers) is valid.
        let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
        #[expect(
            clippy::cast_possible_truncation,
            reason = "STARTUPINFOEXW is about a hundred bytes"
        )]
        let startup_size = size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.cb = startup_size;
        startup.lpAttributeList = list;
        // A different account gets the window station of its own logon session
        // (an empty desktop name); root keeps the daemon's.
        let mut desktop = wide("");
        if !system {
            startup.StartupInfo.lpDesktop = desktop.as_mut_ptr();
        }
        let mut command = wide(&format!("\"{SHELL}\" -NoLogo"));
        let directory = wide(home);
        // SAFETY: PROCESS_INFORMATION is plain data; all-zero is valid.
        let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
        let flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED;
        let created = if system {
            // SAFETY: every buffer lives across the call; no handles are inherited.
            unsafe {
                CreateProcessW(
                    null(),
                    command.as_mut_ptr(),
                    null(),
                    null(),
                    0,
                    flags,
                    environment.as_mut_ptr().cast(),
                    directory.as_ptr(),
                    &raw const startup.StartupInfo,
                    &raw mut information,
                )
            }
        } else {
            // SAFETY: every buffer lives across the call; no handles are
            // inherited; `token` is the open S4U primary token.
            unsafe {
                CreateProcessAsUserW(
                    token,
                    null(),
                    command.as_mut_ptr(),
                    null(),
                    null(),
                    0,
                    flags,
                    environment.as_mut_ptr().cast(),
                    directory.as_ptr(),
                    &raw const startup.StartupInfo,
                    &raw mut information,
                )
            }
        };
        if created == 0 {
            return Err(last_error());
        }
        Ok((
            information.hProcess,
            information.hThread,
            information.dwProcessId,
        ))
    })();
    // SAFETY: `list` was initialized above and is deleted exactly once, while
    // `storage` is still alive.
    unsafe { DeleteProcThreadAttributeList(list) };
    result
}
