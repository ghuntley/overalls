//! Local accounts through the Net API, SID strings and user profiles.
//!
//! Functions return the raw Net API status (`NERR_Success` is zero) so the
//! caller keeps its own error policy.

use super::wide;
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NERR_Success, NERR_UserNotFound, NetApiBufferFree, NetLocalGroupAddMembers, NetUserAdd,
    NetUserGetInfo, NetUserSetInfo, LOCALGROUP_MEMBERS_INFO_3, UF_ACCOUNTDISABLE, USER_INFO_1,
    USER_INFO_1003, USER_INFO_1008, USER_INFO_4, USER_PRIV_USER,
};
use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows_sys::Win32::UI::Shell::CreateProfile;

/// The string SID of the local user `name` when the account is enabled.
/// `Err(status)` when the lookup fails; `Ok(None)` when the account is
/// disabled, its SID does not convert or the SID string is malformed.
pub fn enabled_user_sid(name: &str) -> Result<Option<String>, u32> {
    let name = wide(name);
    let mut buffer: *mut u8 = null_mut();
    // SAFETY: name is terminated and the Net API returns its owned level-4 record.
    let status = unsafe { NetUserGetInfo(null(), name.as_ptr(), 4, &raw mut buffer) };
    if status != NERR_Success || buffer.is_null() {
        return Err(status);
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
        return Ok(None);
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
    Ok(result)
}

/// Create the profile of the account `name` with SID `sid`, writing its path
/// into `profile` (whose length is the declared capacity, clamped to `units`).
/// Returns the `HRESULT`; negative on failure.
pub fn create_profile(sid: &str, name: &str, profile: &mut [u16], units: u32) -> i32 {
    let wide_sid = wide(sid);
    let wide_name = wide(name);
    let units = units.min(u32::try_from(profile.len()).unwrap_or(u32::MAX));
    // SAFETY: SID and username are terminated; profile supplies at least
    // `units` writable units (clamped above). Windows creates the actual
    // profile and registry binding.
    unsafe {
        CreateProfile(
            wide_sid.as_ptr(),
            wide_name.as_ptr(),
            profile.as_mut_ptr(),
            units,
        )
    }
}

/// The account flags of the local user `name`: `Ok(None)` when the user does
/// not exist, `Err(status)` when the lookup fails.
pub fn user_flags(name: &str) -> Result<Option<u32>, u32> {
    let wide_name = wide(name);
    let mut buffer: *mut u8 = null_mut();
    // SAFETY: `wide_name` is NUL-terminated UTF-16; `buffer` receives a
    // Net API allocation freed below.
    let status = unsafe { NetUserGetInfo(null(), wide_name.as_ptr(), 1, &raw mut buffer) };
    if status == NERR_UserNotFound {
        return Ok(None);
    }
    if status != NERR_Success || buffer.is_null() {
        return Err(status);
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

/// Replace the account flags of the local user `name`; returns the status.
pub fn set_user_flags(name: &str, value: u32) -> u32 {
    let wide_name = wide(name);
    let info = USER_INFO_1008 {
        usri1008_flags: value,
    };
    let mut parameter = 0u32;
    // SAFETY: level 1008 takes a USER_INFO_1008; `parameter` receives the
    // offending parameter index on failure.
    unsafe {
        NetUserSetInfo(
            null(),
            wide_name.as_ptr(),
            1008,
            (&raw const info).cast::<u8>(),
            &raw mut parameter,
        )
    }
}

/// Set the password of the local user `name`; the UTF-16 copy of the password
/// is zeroed after the call. Returns the status.
pub fn set_user_password(name: &str, password: &str) -> u32 {
    let wide_name = wide(name);
    let mut password = wide(password);
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
    status
}

/// Add an ordinary-privilege local user with `flags`; the UTF-16 copy of the
/// password is zeroed after the call. Returns the status.
pub fn add_user(name: &str, password: &str, comment: &str, flags: u32) -> u32 {
    let mut wide_name = wide(name);
    let mut password = wide(password);
    let mut comment = wide(comment);
    let info = USER_INFO_1 {
        usri1_name: wide_name.as_mut_ptr(),
        usri1_password: password.as_mut_ptr(),
        usri1_password_age: 0,
        usri1_priv: USER_PRIV_USER,
        usri1_home_dir: null_mut(),
        usri1_comment: comment.as_mut_ptr(),
        usri1_flags: flags,
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
    status
}

/// Add `member` to the local group `group`; returns the status.
pub fn add_local_group_member(group: &str, member: &str) -> u32 {
    let group = wide(group);
    let mut member = wide(member);
    let info = LOCALGROUP_MEMBERS_INFO_3 {
        lgrmi3_domainandname: member.as_mut_ptr(),
    };
    // SAFETY: level 3 takes one LOCALGROUP_MEMBERS_INFO_3 whose string outlives the call.
    unsafe { NetLocalGroupAddMembers(null(), group.as_ptr(), 3, (&raw const info).cast::<u8>(), 1) }
}
