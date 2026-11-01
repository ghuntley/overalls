//! Windows custodian-owned worker custody and atomic launcher.
//!
//! The caller must reconcile the account using the current boot-bound roster
//! authorizer before resolving its SID and constructing an admitted identity.
//! Package paths come from trusted, immutable deployment configuration. The
//! custodian must single-flight startup and retain a SYSTEM-owned launch receipt.

mod account;
mod files;
mod job;
mod processes;
mod worker;

use crate::Refusal;
use crate::windows_model::AccountSid;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::Security::{GetLengthSid, IsValidSid};

pub use account::{require_system, resolve_account};
pub use files::{
    package_file, private_directory, read_private, read_private_optional, write_private,
};
pub use job::system_pipe;
pub use processes::{observe_processes, prior_job_present, terminate_straggler};
pub use worker::{LaunchFailure, Package, QuarantinedJob, SystemPeer, Worker};

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

#[cfg(test)]
mod tests;
