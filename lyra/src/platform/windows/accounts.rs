//! Local Windows accounts for roster users through the Net API (ADR-0171).
//!
//! Each roster account becomes a local user named exactly as the roster says
//! (Marshall's `u<uid>` names fit the 20-character SAM limit), a member of
//! `Administrators` (the Linux guests grant password-less sudo), with a random
//! password that is never recorded: logins are public-key only through
//! Win32-OpenSSH. Accounts that leave the roster are disabled, never deleted,
//! so their profiles and UIDs are never reused.

use super::{boot_id, wide};
use crate::guest::ssh_roster::{Account, Accounts};
use std::io;
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::{LocalFree, ERROR_MEMBER_IN_ALIAS, MAX_PATH};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NERR_Success, NERR_UserExists, NERR_UserNotFound, NetApiBufferFree, NetLocalGroupAddMembers,
    NetUserAdd, NetUserGetInfo, NetUserSetInfo, LOCALGROUP_MEMBERS_INFO_3, UF_ACCOUNTDISABLE,
    UF_DONT_EXPIRE_PASSWD, UF_NORMAL_ACCOUNT, UF_SCRIPT, USER_INFO_1, USER_INFO_1003,
    USER_INFO_1008, USER_INFO_4, USER_PRIV_USER,
};
use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows_sys::Win32::System::Registry::{
    RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_EXPAND_SZ, RRF_RT_REG_SZ,
};
use windows_sys::Win32::UI::Shell::CreateProfile;

const ADMINISTRATORS: &str = "Administrators";

fn account_sid(name: &str) -> io::Result<String> {
    let name = wide(name);
    let mut buffer: *mut u8 = null_mut();
    // SAFETY: name is terminated and the Net API returns its owned level-4 record.
    let status = unsafe { NetUserGetInfo(null(), name.as_ptr(), 4, &raw mut buffer) };
    if status != NERR_Success || buffer.is_null() {
        return Err(net_error(status));
    }
    // SAFETY: level 4 returned USER_INFO_4 with a valid SID until the buffer is freed.
    let info = unsafe { &*buffer.cast::<USER_INFO_4>() };
    let mut sid_text = null_mut();
    let enabled = info.usri4_flags & UF_ACCOUNTDISABLE == 0;
    // SAFETY: the SID stays valid until the Net API buffer is freed below, and
    // `sid_text` receives a LocalAlloc string freed after the copy.
    let converted =
        enabled && unsafe { ConvertSidToStringSidW(info.usri4_user_sid, &raw mut sid_text) } != 0;
    // SAFETY: release precisely the Net API allocation.
    unsafe {
        NetApiBufferFree(buffer.cast());
    }
    if !converted || sid_text.is_null() {
        return Err(io::Error::other("account profile unavailable"));
    }
    let mut length = 0usize;
    // SAFETY: the SID API returned a terminated string; SID strings are at most 256 units.
    while length < 256 && unsafe { *sid_text.wrapping_add(length) } != 0 {
        length += 1;
    }
    let result = if length < 256 {
        // SAFETY: the preceding scan established this many initialized UTF-16 units.
        String::from_utf16(unsafe { std::slice::from_raw_parts(sid_text, length) }).ok()
    } else {
        None
    };
    // SAFETY: ConvertSidToStringSidW allocates with LocalAlloc.
    unsafe {
        LocalFree(sid_text.cast());
    }
    result.ok_or_else(|| io::Error::other("account profile unavailable"))
}

fn profile_for_sid(sid: &str) -> io::Result<PathBuf> {
    let key = wide(&format!(
        r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{sid}"
    ));
    let field = wide("ProfileImagePath");
    let mut path = vec![0u16; 4096];
    let mut bytes = u32::try_from(path.len() * 2)
        .map_err(|_| io::Error::other("account profile unavailable"))?;
    // SAFETY: the writable UTF-16 buffer has exactly the specified byte capacity.
    // RegGetValue expands REG_EXPAND_SZ, so the resolved value is the SID's
    // registered profile rather than a guess based on the account name.
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            key.as_ptr(),
            field.as_ptr(),
            RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ,
            null_mut(),
            path.as_mut_ptr().cast(),
            &raw mut bytes,
        )
    };
    if status != 0 {
        return Err(net_error(status));
    }
    if bytes < 2 || bytes as usize > path.len() * 2 || !bytes.is_multiple_of(2) {
        return Err(io::Error::other("account profile unavailable"));
    }
    let path = String::from_utf16(&path[..bytes as usize / 2 - 1])
        .map_err(|_| io::Error::other("account profile unavailable"))?;
    let path = PathBuf::from(path);
    if !path.is_absolute() || !path.is_dir() {
        return Err(io::Error::other("account profile unavailable"));
    }
    Ok(path)
}

/// @cc [owner:ghuntley,label:security] windows-configuration-owner-profile
/// Creator configuration MUST use an enabled local account's SID-bound registered
/// profile. SYSTEM's environment and guessed C:\Users paths MUST never select
/// human configuration. Profile creation belongs to account activation, not reads.
pub fn profile_home(name: &str) -> io::Result<PathBuf> {
    profile_for_sid(&account_sid(name)?)
}

/// @cc [owner:ghuntley,label:security;recovery] windows-profile-native-api-bound
/// Profile creation MUST use `CreateProfile`'s MAX_PATH-sized output buffer,
/// then verify the SID-bound registered directory before account activation
/// succeeds. An RPC/API failure MUST leave activation failed and the account
/// disabled; a guessed user-directory path MUST NOT replace registration.
fn ensure_profile(name: &str) -> io::Result<()> {
    let sid = account_sid(name)?;
    match profile_for_sid(&sid) {
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let wide_sid = wide(&sid);
    let wide_name = wide(name);
    // CreateProfile's RPC buffer is bounded by MAX_PATH. Passing 4096 units
    // returns RPC_X_BAD_STUB_DATA before creating the SID-bound profile.
    let mut profile = [0u16; MAX_PATH as usize];
    let units = u32::try_from(profile.len())
        .map_err(|_| io::Error::other("account profile creation failed"))?;
    // SAFETY: SID and username are terminated; profile supplies the declared
    // writable buffer. Windows creates the actual profile and registry binding.
    let status = unsafe {
        CreateProfile(
            wide_sid.as_ptr(),
            wide_name.as_ptr(),
            profile.as_mut_ptr(),
            units,
        )
    };
    if status < 0 {
        return Err(io::Error::other("account profile creation failed"));
    }
    profile_for_sid(&sid)?;
    Ok(())
}

/// Net API status as an `io::Error`.
fn net_error(status: u32) -> io::Error {
    io::Error::from_raw_os_error(status.cast_signed())
}

/// Current account flags, or `None` when the user does not exist.
fn flags(name: &str) -> io::Result<Option<u32>> {
    let wide_name = wide(name);
    let mut buffer: *mut u8 = null_mut();
    // SAFETY: `wide_name` is NUL-terminated UTF-16; `buffer` receives a
    // Net API allocation freed below.
    let status = unsafe { NetUserGetInfo(null(), wide_name.as_ptr(), 1, &raw mut buffer) };
    if status == NERR_UserNotFound {
        return Ok(None);
    }
    if status != NERR_Success || buffer.is_null() {
        return Err(net_error(status));
    }
    #[expect(
        clippy::cast_ptr_alignment,
        reason = "Net API buffers are allocated aligned for the requested USER_INFO level"
    )]
    // SAFETY: level 1 returns a USER_INFO_1 the API allocated.
    let flags = unsafe { (*buffer.cast::<USER_INFO_1>()).usri1_flags };
    // SAFETY: the buffer came from the Net API and is freed exactly once.
    unsafe {
        NetApiBufferFree(buffer.cast());
    }
    Ok(Some(flags))
}

fn set_flags(name: &str, value: u32) -> io::Result<()> {
    let wide_name = wide(name);
    let info = USER_INFO_1008 {
        usri1008_flags: value,
    };
    let mut parameter = 0u32;
    // SAFETY: level 1008 takes a USER_INFO_1008; `parameter` receives the
    // offending parameter index on failure.
    let status = unsafe {
        NetUserSetInfo(
            null(),
            wide_name.as_ptr(),
            1008,
            (&raw const info).cast::<u8>(),
            &raw mut parameter,
        )
    };
    if status != NERR_Success {
        return Err(net_error(status));
    }
    Ok(())
}

/// A 32-character random password from the system RNG, used once and dropped.
fn random_password() -> io::Result<String> {
    // Two UUIDs give 64 hex characters of system randomness; the account is
    // never meant to be entered with this password.
    let first = boot_id::generate()?;
    let second = boot_id::generate()?;
    let first = first.replace('-', "");
    let second = second.replace('-', "");
    let unavailable = || io::Error::other("system RNG unavailable");
    Ok(format!(
        "Kp-{}{}",
        first.get(..16).ok_or_else(unavailable)?,
        second.get(..12).ok_or_else(unavailable)?
    ))
}

fn create(name: &str) -> io::Result<()> {
    let mut wide_name = wide(name);
    let mut password = wide(&random_password()?);
    let mut comment = wide("Overalls roster account (public-key SSH only)");
    let info = USER_INFO_1 {
        usri1_name: wide_name.as_mut_ptr(),
        usri1_password: password.as_mut_ptr(),
        usri1_password_age: 0,
        usri1_priv: USER_PRIV_USER,
        usri1_home_dir: null_mut(),
        usri1_comment: comment.as_mut_ptr(),
        usri1_flags: UF_SCRIPT | UF_NORMAL_ACCOUNT | UF_DONT_EXPIRE_PASSWD,
        usri1_script_path: null_mut(),
    };
    let mut parameter = 0u32;
    // SAFETY: level 1 takes a USER_INFO_1 whose strings outlive the call.
    let status = unsafe {
        NetUserAdd(
            null(),
            1,
            (&raw const info).cast::<u8>(),
            &raw mut parameter,
        )
    };
    password.fill(0);
    if status == NERR_Success || status == NERR_UserExists {
        Ok(())
    } else {
        Err(net_error(status))
    }
}

fn join_administrators(name: &str) -> io::Result<()> {
    let group = wide(ADMINISTRATORS);
    let mut member = wide(name);
    let info = LOCALGROUP_MEMBERS_INFO_3 {
        lgrmi3_domainandname: member.as_mut_ptr(),
    };
    // SAFETY: level 3 takes one LOCALGROUP_MEMBERS_INFO_3 whose string outlives the call.
    let status = unsafe {
        NetLocalGroupAddMembers(null(), group.as_ptr(), 3, (&raw const info).cast::<u8>(), 1)
    };
    if status == NERR_Success || status == ERROR_MEMBER_IN_ALIAS {
        Ok(())
    } else {
        Err(net_error(status))
    }
}

/// @cc [owner:ghuntley,label:security] windows-bootstrap-administrator-rotated
/// Once a roster account is active, the image's bootstrap `Administrator`
/// MUST be given a fresh random password that is never recorded and MUST be
/// disabled, so the documented spike credential and the SAC login stop working;
/// the operation is idempotent and never touches roster accounts.
pub fn retire_bootstrap_administrator() -> io::Result<()> {
    const NAME: &str = "Administrator";
    let Some(current) = flags(NAME)? else {
        return Ok(());
    };
    let wide_name = wide(NAME);
    let mut password = wide(&random_password()?);
    let info = USER_INFO_1003 {
        usri1003_password: password.as_mut_ptr(),
    };
    let mut parameter = 0u32;
    // SAFETY: level 1003 takes a USER_INFO_1003 whose string outlives the call.
    let status = unsafe {
        NetUserSetInfo(
            null(),
            wide_name.as_ptr(),
            1003,
            (&raw const info).cast::<u8>(),
            &raw mut parameter,
        )
    };
    password.fill(0);
    if status != NERR_Success {
        return Err(net_error(status));
    }
    if current & UF_ACCOUNTDISABLE == 0 {
        set_flags(NAME, current | UF_ACCOUNTDISABLE)?;
    }
    Ok(())
}

/// The Net API implementation of the shared roster rules.
#[derive(Debug, Default)]
pub struct NetAccounts;

impl Accounts for NetAccounts {
    /// @cc [owner:ghuntley,label:security] windows-roster-account-shape
    /// activate MUST leave a local user named exactly as the roster says,
    /// enabled, with a never-recorded random password, non-expiring password
    /// and Administrators membership with a registered profile; an existing disabled account is re-enabled
    /// rather than recreated, and failures leave no half-created account enabled.
    fn activate(&mut self, account: &Account) -> io::Result<()> {
        match flags(&account.username)? {
            None => create(&account.username)?,
            Some(current) if current & UF_ACCOUNTDISABLE != 0 => {
                set_flags(&account.username, current & !UF_ACCOUNTDISABLE)?;
            }
            Some(_) => {}
        }
        let result =
            join_administrators(&account.username).and_then(|()| ensure_profile(&account.username));
        if result.is_err() {
            if let Ok(Some(current)) = flags(&account.username) {
                let _ = set_flags(&account.username, current | UF_ACCOUNTDISABLE);
            }
        }
        result
    }

    fn deactivate(&mut self, account: &Account) -> io::Result<()> {
        if let Some(current) = flags(&account.username)? {
            if current & UF_ACCOUNTDISABLE == 0 {
                set_flags(&account.username, current | UF_ACCOUNTDISABLE)?;
            }
        }
        Ok(())
    }
}
