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
    let name = std::ffi::CString::new(username).map_err(|_| Failure::InvalidArguments)?;
    let account = crate::sys::unix::passwd_by_name(&name).ok_or(Failure::AccountUnavailable)?;
    if account.uid != uid {
        return Err(Failure::AccountUnavailable);
    }
    account.home.ok_or(Failure::AccountUnavailable)
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
