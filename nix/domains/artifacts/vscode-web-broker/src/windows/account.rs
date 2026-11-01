//! SYSTEM checks, account SIDs, tokens, privileges and profiles.

use super::{copy_sid, owned, raw, system_sid, wide};
use crate::Refusal;
use crate::windows_model::{
    AccountSid, LocalPath, LogonSession, TokenObservation, TokenOwner, WorkerIdentity,
};
use std::mem::{size_of, zeroed};
use std::os::windows::io::OwnedHandle;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_NOT_ALL_ASSIGNED, GetLastError, HANDLE, LUID, SetLastError,
};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NetApiBufferFree, NetUserGetInfo, UF_ACCOUNTDISABLE, USER_INFO_4,
};
use windows_sys::Win32::Security::Authentication::Identity::{
    LSA_STRING, LSA_UNICODE_STRING, LsaDeregisterLogonProcess, LsaFreeReturnBuffer, LsaLogonUser,
    LsaLookupAuthenticationPackage, LsaRegisterLogonProcess, MSV1_0_S4U_LOGON, MsV1_0S4ULogon,
    SECURITY_LOGON_TYPE,
};
use windows_sys::Win32::Security::{
    AdjustTokenPrivileges, AllocateLocallyUniqueId, DuplicateTokenEx, EqualSid,
    GetTokenInformation, IsValidSid, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW, QUOTA_LIMITS,
    SE_PRIVILEGE_ENABLED, SecurityImpersonation, TOKEN_ADJUST_PRIVILEGES, TOKEN_ALL_ACCESS,
    TOKEN_PRIVILEGES, TOKEN_QUERY, TOKEN_SOURCE, TOKEN_STATISTICS, TOKEN_USER, TokenPrimary,
    TokenStatistics, TokenUser,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::UI::Shell::GetUserProfileDirectoryW;

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

pub(super) fn token_sid(token: HANDLE) -> Result<AccountSid, Refusal> {
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
pub(super) fn token_logon(token: HANDLE) -> Result<LogonSession, Refusal> {
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
pub(super) fn process_token(process: &OwnedHandle) -> TokenObservation {
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

pub(super) fn privilege(name: *const u16) -> Result<(), Refusal> {
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
pub(super) fn account_token(identity: &WorkerIdentity) -> Result<OwnedHandle, Refusal> {
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

pub(super) fn profile_directory(token: HANDLE) -> Result<LocalPath, Refusal> {
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
