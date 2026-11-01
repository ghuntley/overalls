//! Local Windows accounts for roster users through the Net API (ADR-0171).
//!
//! Each roster account becomes a local user named exactly as the roster says
//! (Marshall's `u<uid>` names fit the 20-character SAM limit), a member of
//! `Administrators` (the Linux guests grant password-less sudo), with a random
//! password that is never recorded: logins are public-key only through
//! Win32-OpenSSH. Accounts that leave the roster are disabled, never deleted,
//! so their profiles and UIDs are never reused.

use super::boot_id;
use crate::guest::ssh_roster::{Account, Accounts};
use crate::sys::windows::{net_api, registry};
use std::io;
use std::path::PathBuf;
use windows_sys::Win32::Foundation::{ERROR_MEMBER_IN_ALIAS, MAX_PATH};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NERR_Success, NERR_UserExists, UF_ACCOUNTDISABLE, UF_DONT_EXPIRE_PASSWD, UF_NORMAL_ACCOUNT,
    UF_SCRIPT,
};

const ADMINISTRATORS: &str = "Administrators";

fn account_sid(name: &str) -> io::Result<String> {
    net_api::enabled_user_sid(name)
        .map_err(net_error)?
        .ok_or_else(|| io::Error::other("account profile unavailable"))
}

fn profile_for_sid(sid: &str) -> io::Result<PathBuf> {
    let key = format!(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{sid}");
    let mut path = vec![0u16; 4096];
    let mut bytes = u32::try_from(path.len() * 2)
        .map_err(|_| io::Error::other("account profile unavailable"))?;
    // RegGetValue expands REG_EXPAND_SZ, so the resolved value is the SID's
    // registered profile rather than a guess based on the account name.
    let status = registry::local_machine_string(&key, "ProfileImagePath", &mut path, &mut bytes);
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
    // CreateProfile's RPC buffer is bounded by MAX_PATH. Passing 4096 units
    // returns RPC_X_BAD_STUB_DATA before creating the SID-bound profile.
    let mut profile = [0u16; MAX_PATH as usize];
    let units = u32::try_from(profile.len())
        .map_err(|_| io::Error::other("account profile creation failed"))?;
    // Windows creates the actual profile and registry binding.
    let status = net_api::create_profile(&sid, name, &mut profile, units);
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
    net_api::user_flags(name).map_err(net_error)
}

fn set_flags(name: &str, value: u32) -> io::Result<()> {
    let status = net_api::set_user_flags(name, value);
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
    let status = net_api::add_user(
        name,
        &random_password()?,
        "Overalls roster account (public-key SSH only)",
        UF_SCRIPT | UF_NORMAL_ACCOUNT | UF_DONT_EXPIRE_PASSWD,
    );
    if status == NERR_Success || status == NERR_UserExists {
        Ok(())
    } else {
        Err(net_error(status))
    }
}

fn join_administrators(name: &str) -> io::Result<()> {
    let status = net_api::add_local_group_member(ADMINISTRATORS, name);
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
    let status = net_api::set_user_password(NAME, &random_password()?);
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
