//! Terminal sessions on Windows guests through ConPTY (ADR-0171).
//!
//! The session engine treats a `Master` like a Linux PTY master: a bounded
//! readiness wait, reads of raw output, input writes, resize, kill and
//! retirement. ConPTY renders through conhost, which re-encodes the screen as
//! VT sequences; the engine still never drops, reorders or interprets the
//! bytes it receives (`fidelity-passthrough`), but byte-for-byte fidelity with
//! the program's own output is not possible on Windows and is recorded.
//!
//! Identities: `root` keeps its Linux meaning, the host-admin session, and
//! runs as the daemon's own LocalSystem token. Any other name must be an
//! enabled local account (the roster agent creates, enables and disables
//! them) and runs under an S4U logon of that account, as Win32-OpenSSH does
//! for key logins. Every session's processes live in a kill-on-close job.
use std::io;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, ERROR_BROKEN_PIPE, HANDLE, LUID, WAIT_OBJECT_0,
};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NetApiBufferFree, NetUserEnum, NetUserGetInfo, FILTER_NORMAL_ACCOUNT, MAX_PREFERRED_LENGTH,
    UF_ACCOUNTDISABLE, USER_INFO_1,
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
    InitializeProcThreadAttributeList, OpenProcessToken, ResumeThread, UpdateProcThreadAttribute,
    WaitForSingleObject, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
    EXTENDED_STARTUPINFO_PRESENT, LPPROC_THREAD_ATTRIBUTE_LIST, PROCESS_INFORMATION,
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, STARTUPINFOEXW,
};
use windows_sys::Win32::UI::Shell::{LoadUserProfileW, UnloadUserProfile, PROFILEINFOW};

const SHELL: &str = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
const ROOT: &str = "root";
const NAME_MAX: usize = 20;

fn last_error() -> io::Error {
    io::Error::from_raw_os_error(unsafe { GetLastError() } as i32)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn from_wide(pointer: *const u16) -> String {
    if pointer.is_null() {
        return String::new();
    }
    // SAFETY: the caller passes a NUL-terminated UTF-16 string owned by a live
    // NetApi buffer; we stop at the terminator.
    let length = (0..)
        .take_while(|&index| unsafe { *pointer.add(index) } != 0)
        .count();
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(pointer, length) })
}

/// A resolved session identity.
pub struct UserInfo {
    pub name: String,
    system: bool,
}

/// Roster account names: what the roster agent creates (`u<uid>` and the
/// like), bounded by the SAM limit; never a path, domain or quoted form.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= NAME_MAX
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn enabled_local_account(name: &str) -> bool {
    let user = wide(name);
    let mut buffer: *mut u8 = null_mut();
    // SAFETY: level 1 fills one USER_INFO_1 that we free with NetApiBufferFree.
    let status = unsafe { NetUserGetInfo(null(), user.as_ptr(), 1, &mut buffer) };
    if status != 0 || buffer.is_null() {
        return false;
    }
    // SAFETY: a successful level-1 call returns a USER_INFO_1.
    let flags = unsafe { (*(buffer as *const USER_INFO_1)).usri1_flags };
    unsafe { NetApiBufferFree(buffer.cast()) };
    flags & UF_ACCOUNTDISABLE == 0
}

/// @cc [owner:ghuntley,label:security;capacity] windows-terminal-user-inventory
/// The inventory MUST list `root` first and then only enabled normal local
/// accounts with valid roster names, at most 64 entries; it MUST NOT create
/// accounts or expose any password field.
pub fn users() -> io::Result<Vec<String>> {
    let mut users = vec![ROOT.to_owned()];
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
            &mut buffer,
            MAX_PREFERRED_LENGTH,
            &mut read,
            &mut total,
            null_mut(),
        )
    };
    if status != 0 {
        if !buffer.is_null() {
            unsafe { NetApiBufferFree(buffer.cast()) };
        }
        return Err(io::Error::other("account inventory unavailable"));
    }
    if !buffer.is_null() {
        // SAFETY: `read` entries of USER_INFO_1 follow `buffer`.
        let entries =
            unsafe { std::slice::from_raw_parts(buffer as *const USER_INFO_1, read as usize) };
        for entry in entries {
            let name = from_wide(entry.usri1_name);
            if entry.usri1_flags & UF_ACCOUNTDISABLE == 0 && valid_name(&name) && name != ROOT {
                users.push(name);
            }
        }
        unsafe { NetApiBufferFree(buffer.cast()) };
    }
    users[1..].sort();
    users.dedup();
    users.truncate(64);
    Ok(users)
}

/// @cc [owner:ghuntley,label:security] windows-terminal-roster-accounts
/// `resolve` MUST return the LocalSystem identity only for `root` and
/// otherwise only an existing, enabled local account with a valid roster name;
/// disabled, missing or malformed names MUST resolve to nothing, and no
/// account is created or enabled here (the roster agent owns that).
pub fn resolve(name: &str) -> Option<UserInfo> {
    if name == ROOT {
        return Some(UserInfo {
            name: ROOT.to_owned(),
            system: true,
        });
    }
    (valid_name(name) && enabled_local_account(name)).then(|| UserInfo {
        name: name.to_owned(),
        system: false,
    })
}

/// Shared ConPTY state for one session.
pub struct Console {
    /// The pseudo console until it is closed; resize and close serialize here.
    pseudo: Mutex<Option<HPCON>>,
    closing: AtomicBool,
    output: usize,
    input: usize,
    process: usize,
    job: usize,
    token: usize,
    profile: usize,
}

impl Console {
    fn handle(value: usize) -> HANDLE {
        value as HANDLE
    }

    fn close_pseudo(&self) {
        if let Some(pseudo) = self.pseudo.lock().unwrap().take() {
            // SAFETY: the pseudo console is closed exactly once (taken from the slot).
            unsafe { ClosePseudoConsole(pseudo) };
        }
    }

    /// Once the shell has exited, close the pseudo console off the pump thread:
    /// conhost then flushes and closes its output pipe, so the pump drains the
    /// final bytes and reads end of stream. Closing on the pump thread could
    /// deadlock against conhost blocked on a full output pipe.
    fn begin_close(self: &Arc<Self>) {
        if self.closing.swap(true, Ordering::SeqCst) {
            return;
        }
        let console = self.clone();
        if std::thread::Builder::new()
            .spawn(move || console.close_pseudo())
            .is_err()
        {
            self.closing.store(false, Ordering::SeqCst);
        }
    }
}

/// The session's ConPTY master.
pub type Master = Arc<Console>;

pub struct Spawned {
    pub master: Master,
    pub pid: i32,
}

/// Outcome of a bounded master readiness wait.
#[allow(dead_code)]
pub enum Ready {
    Data,
    Timeout,
    Interrupted,
    Failed,
}

/// Outcome of one master read.
#[allow(dead_code)]
pub enum Read {
    Data(usize),
    Eof,
    Interrupted,
    WouldBlock,
    SlaveClosed,
    Failed,
}

/// Wait up to `millis` for ConPTY output, or for end of stream.
pub fn wait_readable(master: &Master, millis: i32) -> Ready {
    let deadline = Instant::now() + Duration::from_millis(u64::try_from(millis).unwrap_or(0));
    loop {
        let mut available = 0u32;
        // SAFETY: peeking an anonymous pipe read handle we own; only the count is written.
        let peeked = unsafe {
            PeekNamedPipe(
                Console::handle(master.output),
                null_mut(),
                0,
                null_mut(),
                &mut available,
                null_mut(),
            )
        };
        if peeked == 0 {
            return if unsafe { GetLastError() } == ERROR_BROKEN_PIPE {
                Ready::Data
            } else {
                Ready::Failed
            };
        }
        if available > 0 {
            return Ready::Data;
        }
        // SAFETY: a zero-timeout wait on our process handle.
        if unsafe { WaitForSingleObject(Console::handle(master.process), 0) } == WAIT_OBJECT_0 {
            master.begin_close();
        }
        if Instant::now() >= deadline {
            return Ready::Timeout;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// One read of ConPTY output; a closed pipe is end of stream.
pub fn read(master: &Master, buf: &mut [u8]) -> Read {
    let mut read = 0u32;
    let length = u32::try_from(buf.len()).unwrap_or(u32::MAX);
    // SAFETY: `buf` is writable for `length` bytes; synchronous read.
    let ok = unsafe {
        ReadFile(
            Console::handle(master.output),
            buf.as_mut_ptr(),
            length,
            &mut read,
            null_mut(),
        )
    };
    if ok == 0 {
        return if unsafe { GetLastError() } == ERROR_BROKEN_PIPE {
            Read::Eof
        } else {
            Read::Failed
        };
    }
    if read == 0 {
        Read::Eof
    } else {
        Read::Data(read as usize)
    }
}

/// Write all input bytes to the pseudo console.
pub fn write_input(master: &Master, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        let mut written = 0u32;
        let length = u32::try_from(data.len()).unwrap_or(u32::MAX);
        // SAFETY: `data` is readable for `length` bytes; synchronous write.
        if unsafe {
            WriteFile(
                Console::handle(master.input),
                data.as_ptr(),
                length,
                &mut written,
                null_mut(),
            )
        } == 0
        {
            return Err(last_error());
        }
        if written == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        data = &data[written as usize..];
    }
    Ok(())
}

pub fn set_winsize(master: &Master, cols: u16, rows: u16) -> io::Result<()> {
    let size = coord(cols, rows)?;
    let guard = master.pseudo.lock().unwrap();
    let Some(pseudo) = *guard else {
        return Err(io::ErrorKind::BrokenPipe.into());
    };
    // SAFETY: the pseudo console is live while its slot holds it under the lock.
    if unsafe { ResizePseudoConsole(pseudo, size) } < 0 {
        return Err(io::Error::other("resize refused"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:recovery;security] windows-terminal-kill-job
/// Explicit kill MUST terminate every process in the session's job, which
/// also ends descendants that detached from the console, and MUST NOT wait
/// for viewer credit.
pub fn kill(master: &Master, _pid: i32) {
    // SAFETY: terminating our own job handle.
    unsafe { TerminateJobObject(Console::handle(master.job), 1) };
}

/// Retirement: end the job, release conhost (closing our read end first so a
/// blocked conhost write fails instead of deadlocking the close), and release
/// every handle and the loaded profile exactly once.
pub fn retire(master: &Master, _pid: i32) {
    unsafe {
        TerminateJobObject(Console::handle(master.job), 1);
        WaitForSingleObject(Console::handle(master.process), 5000);
        CloseHandle(Console::handle(master.output));
    }
    if !master.closing.swap(true, Ordering::SeqCst) {
        master.close_pseudo();
    }
    unsafe {
        CloseHandle(Console::handle(master.input));
        CloseHandle(Console::handle(master.process));
        CloseHandle(Console::handle(master.job));
        if master.token != 0 {
            if master.profile != 0 {
                UnloadUserProfile(
                    Console::handle(master.token),
                    Console::handle(master.profile),
                );
            }
            CloseHandle(Console::handle(master.token));
        }
    }
}

fn coord(cols: u16, rows: u16) -> io::Result<COORD> {
    Ok(COORD {
        X: i16::try_from(cols).map_err(|_| io::Error::other("columns out of range"))?,
        Y: i16::try_from(rows).map_err(|_| io::Error::other("rows out of range"))?,
    })
}

fn enable_privilege(name: *const u16) -> io::Result<()> {
    let mut token: HANDLE = null_mut();
    // SAFETY: opening our own process token for privilege adjustment.
    if unsafe {
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )
    } == 0
    {
        return Err(last_error());
    }
    let mut luid: LUID = unsafe { zeroed() };
    let result = (|| {
        // SAFETY: `name` is a static privilege name; `luid` is writable.
        if unsafe { LookupPrivilegeValueW(null(), name, &mut luid) } == 0 {
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
        if unsafe { AdjustTokenPrivileges(token, 0, &privileges, 0, null_mut(), null_mut()) } == 0 {
            return Err(last_error());
        }
        Ok(())
    })();
    unsafe { CloseHandle(token) };
    result
}

/// An S4U logon of an enabled local account, as Win32-OpenSSH performs for
/// key logins: no password exists or is needed, and the daemon's LocalSystem
/// token supplies the trusted-computing-base privilege LSA requires.
fn s4u_token(name: &str) -> io::Result<HANDLE> {
    let mut process_name = *b"overalls-terminald";
    let process = LSA_STRING {
        Length: process_name.len() as u16,
        MaximumLength: process_name.len() as u16,
        Buffer: process_name.as_mut_ptr(),
    };
    let mut lsa: HANDLE = null_mut();
    let mut mode = 0u32;
    // SAFETY: registers this process as a logon process (requires SeTcbPrivilege).
    if unsafe { LsaRegisterLogonProcess(&process, &mut lsa, &mut mode) } != 0 {
        return Err(io::Error::other("logon process registration refused"));
    }
    let result = (|| {
        let mut package_name = *b"MICROSOFT_AUTHENTICATION_PACKAGE_V1_0";
        let package = LSA_STRING {
            Length: package_name.len() as u16,
            MaximumLength: package_name.len() as u16,
            Buffer: package_name.as_mut_ptr(),
        };
        let mut package_id = 0u32;
        // SAFETY: `package` names the MSV1_0 package; the id is written.
        if unsafe { LsaLookupAuthenticationPackage(lsa, &package, &mut package_id) } != 0 {
            return Err(io::Error::other("authentication package unavailable"));
        }
        let user: Vec<u16> = name.encode_utf16().collect();
        let domain: Vec<u16> = ".".encode_utf16().collect();
        let header = size_of::<MSV1_0_S4U_LOGON>();
        let total = header + (user.len() + domain.len()) * 2;
        // u64 storage keeps the struct aligned; strings follow it in one buffer.
        let mut storage = vec![0u64; total.div_ceil(8)];
        let base = storage.as_mut_ptr() as *mut u8;
        // SAFETY: `storage` has `total` bytes; the struct is written at offset 0
        // and the two UTF-16 strings after it, each within bounds.
        unsafe {
            let user_at = base.add(header) as *mut u16;
            std::ptr::copy_nonoverlapping(user.as_ptr(), user_at, user.len());
            let domain_at = user_at.add(user.len());
            std::ptr::copy_nonoverlapping(domain.as_ptr(), domain_at, domain.len());
            *(base as *mut MSV1_0_S4U_LOGON) = MSV1_0_S4U_LOGON {
                MessageType: MsV1_0S4ULogon,
                Flags: 0,
                UserPrincipalName: LSA_UNICODE_STRING {
                    Length: (user.len() * 2) as u16,
                    MaximumLength: (user.len() * 2) as u16,
                    Buffer: user_at,
                },
                DomainName: LSA_UNICODE_STRING {
                    Length: (domain.len() * 2) as u16,
                    MaximumLength: (domain.len() * 2) as u16,
                    Buffer: domain_at,
                },
            };
        }
        let mut source: TOKEN_SOURCE = unsafe { zeroed() };
        for (slot, byte) in source.SourceName.iter_mut().zip(b"overalls\0") {
            *slot = *byte as i8;
        }
        // SAFETY: writes one LUID.
        unsafe { AllocateLocallyUniqueId(&mut source.SourceIdentifier) };
        let mut profile: *mut core::ffi::c_void = null_mut();
        let mut profile_length = 0u32;
        let mut logon_id: LUID = unsafe { zeroed() };
        let mut token: HANDLE = null_mut();
        let mut quotas: QUOTA_LIMITS = unsafe { zeroed() };
        let mut substatus = 0i32;
        // SAFETY: every pointer is valid for the call; `storage` holds the
        // self-relative S4U request of `total` bytes.
        let status = unsafe {
            LsaLogonUser(
                lsa,
                &process,
                SECURITY_LOGON_TYPE::Network,
                package_id,
                storage.as_ptr().cast(),
                total as u32,
                null(),
                &source,
                &mut profile,
                &mut profile_length,
                &mut logon_id,
                &mut token,
                &mut quotas,
                &mut substatus,
            )
        };
        if !profile.is_null() {
            unsafe { LsaFreeReturnBuffer(profile) };
        }
        if status != 0 || token.is_null() {
            return Err(io::Error::other("S4U logon refused"));
        }
        Ok(token)
    })();
    unsafe { LsaDeregisterLogonProcess(lsa) };
    result
}

/// The child's environment: the account's own block (or the daemon's for
/// root) with TERM from the client and COLORTERM=truecolor, UTF-16 encoded.
fn environment(token: HANDLE, term: &str) -> io::Result<(Vec<u16>, String)> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    if token.is_null() {
        pairs.extend(std::env::vars());
    } else {
        let mut block: *mut core::ffi::c_void = null_mut();
        // SAFETY: builds the account's environment; destroyed below.
        if unsafe { CreateEnvironmentBlock(&mut block, token, 0) } == 0 {
            return Err(last_error());
        }
        let mut cursor = block as *const u16;
        loop {
            let entry = from_wide(cursor);
            if entry.is_empty() {
                break;
            }
            // SAFETY: advance past this entry and its terminator inside the block.
            cursor = unsafe { cursor.add(entry.encode_utf16().count() + 1) };
            if let Some((key, value)) = entry.split_once('=').filter(|(key, _)| !key.is_empty()) {
                pairs.push((key.to_owned(), value.to_owned()));
            }
        }
        unsafe { DestroyEnvironmentBlock(block) };
    }
    pairs.retain(|(key, _)| {
        !key.eq_ignore_ascii_case("TERM") && !key.eq_ignore_ascii_case("COLORTERM")
    });
    pairs.push(("TERM".to_owned(), term.to_owned()));
    pairs.push(("COLORTERM".to_owned(), "truecolor".to_owned()));
    let home = pairs
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("USERPROFILE"))
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| r"C:\".to_owned());
    let mut block: Vec<u16> = Vec::new();
    for (key, value) in pairs {
        block.extend(format!("{key}={value}").encode_utf16());
        block.push(0);
    }
    block.push(0);
    Ok((block, home))
}

struct Handles(Vec<HANDLE>);

impl Drop for Handles {
    fn drop(&mut self) {
        for handle in &self.0 {
            if !handle.is_null() {
                unsafe { CloseHandle(*handle) };
            }
        }
    }
}

/// @cc [owner:ghuntley,label:security] windows-terminal-session-identity
/// A session MUST run its shell under the resolved identity only: LocalSystem
/// for `root`, otherwise an S4U token of that enabled account with its profile
/// loaded and its own window station; the shell MUST be attached to a fresh
/// pseudo console, assigned to a kill-on-close job before it runs, and given
/// TERM from the client and COLORTERM=truecolor. Any failed step MUST release
/// what it created and return an error without starting the shell.
pub fn spawn(user: &UserInfo, term: &str, cols: u16, rows: u16) -> io::Result<Spawned> {
    let size = coord(cols, rows)?;
    let mut owned = Handles(Vec::new());
    let (mut input_read, mut input_write, mut output_read, mut output_write) =
        (null_mut(), null_mut(), null_mut(), null_mut());
    // SAFETY: anonymous pipes without inheritance; handles recorded for cleanup.
    if unsafe { CreatePipe(&mut input_read, &mut input_write, null(), 0) } == 0 {
        return Err(last_error());
    }
    owned.0.extend([input_read, input_write]);
    if unsafe { CreatePipe(&mut output_read, &mut output_write, null(), 0) } == 0 {
        return Err(last_error());
    }
    owned.0.extend([output_read, output_write]);
    let mut pseudo: HPCON = 0;
    // SAFETY: conhost duplicates the pipe ends it needs.
    if unsafe { CreatePseudoConsole(size, input_read, output_write, 0, &mut pseudo) } < 0 {
        return Err(io::Error::other("pseudo console unavailable"));
    }
    let pseudo_guard = PseudoGuard(Some(pseudo));
    let token = if user.system {
        null_mut()
    } else {
        enable_privilege(SE_ASSIGNPRIMARYTOKEN_NAME)?;
        enable_privilege(SE_INCREASE_QUOTA_NAME)?;
        s4u_token(&user.name)?
    };
    let mut token_guard = Handles(if token.is_null() {
        Vec::new()
    } else {
        vec![token]
    });
    let mut profile: HANDLE = null_mut();
    if !token.is_null() {
        let mut name = wide(&user.name);
        let mut info: PROFILEINFOW = unsafe { zeroed() };
        info.dwSize = size_of::<PROFILEINFOW>() as u32;
        info.dwFlags = 1; // PI_NOUI
        info.lpUserName = name.as_mut_ptr();
        // SAFETY: `info` and `name` live across the call.
        if unsafe { LoadUserProfileW(token, &mut info) } == 0 {
            return Err(last_error());
        }
        profile = info.hProfile;
    }
    let unload = |profile: HANDLE| {
        if !profile.is_null() {
            unsafe { UnloadUserProfile(token, profile) };
        }
    };
    let (mut environment, home) = match environment(token, term) {
        Ok(value) => value,
        Err(error) => {
            unload(profile);
            return Err(error);
        }
    };
    let job = unsafe { CreateJobObjectW(null(), null()) };
    if job.is_null() {
        unload(profile);
        return Err(last_error());
    }
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: the extended limit structure is passed with its exact size.
    if unsafe {
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        let error = last_error();
        unsafe { CloseHandle(job) };
        unload(profile);
        return Err(error);
    }
    let spawned = launch(token, pseudo, &mut environment, &home, user.system);
    let (process, thread, pid) = match spawned {
        Ok(value) => value,
        Err(error) => {
            unsafe { CloseHandle(job) };
            unload(profile);
            return Err(error);
        }
    };
    // SAFETY: the suspended process joins the job before its first instruction.
    if unsafe { AssignProcessToJobObject(job, process) } == 0
        || unsafe { ResumeThread(thread) } == u32::MAX
    {
        let error = last_error();
        unsafe {
            TerminateJobObject(job, 1);
            windows_sys::Win32::System::Threading::TerminateProcess(process, 1);
            CloseHandle(thread);
            CloseHandle(process);
            CloseHandle(job);
        }
        unload(profile);
        return Err(error);
    }
    unsafe { CloseHandle(thread) };
    // conhost holds its own copies of the console-side pipe ends.
    owned.0.clear();
    unsafe {
        CloseHandle(input_read);
        CloseHandle(output_write);
    }
    token_guard.0.clear();
    let console = Arc::new(Console {
        pseudo: Mutex::new(pseudo_guard.release()),
        closing: AtomicBool::new(false),
        output: output_read as usize,
        input: input_write as usize,
        process: process as usize,
        job: job as usize,
        token: token as usize,
        profile: profile as usize,
    });
    Ok(Spawned {
        master: console,
        pid: i32::try_from(pid).unwrap_or(i32::MAX),
    })
}

struct PseudoGuard(Option<HPCON>);

impl PseudoGuard {
    fn release(mut self) -> Option<HPCON> {
        self.0.take()
    }
}

impl Drop for PseudoGuard {
    fn drop(&mut self) {
        if let Some(pseudo) = self.0.take() {
            unsafe { ClosePseudoConsole(pseudo) };
        }
    }
}

fn launch(
    token: HANDLE,
    pseudo: HPCON,
    environment: &mut [u16],
    home: &str,
    system: bool,
) -> io::Result<(HANDLE, HANDLE, u32)> {
    let mut size = 0usize;
    // SAFETY: a null list asks for the required size (expected to "fail").
    unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut size) };
    let mut storage = vec![0u64; size.div_ceil(8)];
    let list = storage.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
    // SAFETY: `storage` holds `size` bytes for one attribute.
    if unsafe { InitializeProcThreadAttributeList(list, 1, 0, &mut size) } == 0 {
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
        let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.lpAttributeList = list;
        // A different account gets the window station of its own logon session
        // (an empty desktop name); root keeps the daemon's.
        let mut desktop = wide("");
        if !system {
            startup.StartupInfo.lpDesktop = desktop.as_mut_ptr();
        }
        let mut command = wide(&format!("\"{SHELL}\" -NoLogo"));
        let directory = wide(home);
        let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
        let flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED;
        // SAFETY: every buffer lives across the call; no handles are inherited.
        let created = unsafe {
            if system {
                CreateProcessW(
                    null(),
                    command.as_mut_ptr(),
                    null(),
                    null(),
                    0,
                    flags,
                    environment.as_mut_ptr().cast(),
                    directory.as_ptr(),
                    &startup.StartupInfo,
                    &mut information,
                )
            } else {
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
                    &startup.StartupInfo,
                    &mut information,
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
    unsafe { DeleteProcThreadAttributeList(list) };
    result
}

#[cfg(test)]
mod tests {
    use super::valid_name;

    #[test]
    fn roster_names_are_bounded_and_plain() {
        assert!(valid_name("u200000"));
        assert!(!valid_name(""));
        assert!(!valid_name("a".repeat(21).as_str()));
        assert!(!valid_name(r"DOMAIN\u1"));
        assert!(!valid_name("u1@host"));
    }
}
