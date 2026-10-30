//! Resolve the configuration owner from the guest account database, never executor HOME.
use super::{directory, Failure};
use std::path::PathBuf;

pub(super) fn resolve(username: &str) -> Result<PathBuf, Failure> {
    let uid = username
        .strip_prefix('u')
        .and_then(|v| v.parse::<u32>().ok())
        .ok_or(Failure::InvalidArguments)?;
    if !crate::guest::ssh_roster::UID_RANGE.contains(&uid) || username != format!("u{uid}") {
        return Err(Failure::InvalidArguments);
    }
    let home = lookup(username, uid)?;
    directory(&home).map_err(|_| Failure::AccountUnavailable)
}

#[cfg(unix)]
fn lookup(username: &str, uid: u32) -> Result<PathBuf, Failure> {
    use std::ffi::{CStr, CString};
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;
    let name = CString::new(username).map_err(|_| Failure::InvalidArguments)?;
    let mut account = MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0u8; 65_536];
    let mut result = std::ptr::null_mut();
    // SAFETY: name is NUL-terminated; account, result and the fixed-size buffer
    // remain alive for the call. Fields are read only after a successful lookup.
    let status = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            account.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &raw mut result,
        )
    };
    if status != 0 || result.is_null() {
        return Err(Failure::AccountUnavailable);
    }
    // SAFETY: getpwnam_r initialized account and its pointers reference buffer.
    let account = unsafe { account.assume_init() };
    if account.pw_uid != uid || account.pw_dir.is_null() {
        return Err(Failure::AccountUnavailable);
    }
    // SAFETY: pw_dir is a NUL-terminated field in the successful passwd record.
    let bytes = unsafe { CStr::from_ptr(account.pw_dir) }.to_bytes();
    Ok(PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
}

#[cfg(windows)]
fn lookup(username: &str, _uid: u32) -> Result<PathBuf, Failure> {
    crate::platform::windows::accounts::profile_home(username)
        .map_err(|_| Failure::AccountUnavailable)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn system_and_unmanaged_accounts_are_never_configuration_owners() {
        for username in [
            "root",
            "SYSTEM",
            "Administrator",
            "u0",
            "u199999",
            "u1000000",
            "u0200000",
            "../u200000",
        ] {
            assert_eq!(resolve(username).unwrap_err(), Failure::InvalidArguments);
        }
    }
}
