//! Offline machine snapshot validation.

use crate::MilaFfiStatus;
use mila_runtime::MachineSnapshot;
use std::ffi::{c_char, CStr};

/// Non-sensitive metadata extracted from a validated offline machine snapshot.
/// The machine records themselves remain in the native/runtime layer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MilaSnapshotSummary {
    pub machine_count: u32,
    pub saved_at: u64,
}

/// Validates a bounded snapshot and returns only its count and timestamp.
/// `host` and `port` identify the deployment the native client is currently
/// connected to; snapshots for another deployment are rejected.
///
/// # Safety
/// `bytes` must reference `length` readable bytes and `host` a NUL-terminated
/// UTF-8 string. `out_summary` must point to writable summary storage.
#[no_mangle]
pub unsafe extern "C" fn mila_snapshot_validate(
    bytes: *const u8,
    length: usize,
    host: *const c_char,
    port: u16,
    has_port: u8,
    out_summary: *mut MilaSnapshotSummary,
) -> MilaFfiStatus {
    if bytes.is_null() || host.is_null() || out_summary.is_null() {
        return MilaFfiStatus::NullInput;
    }
    if has_port > 1 {
        return MilaFfiStatus::InvalidRequest;
    }
    let host = match CStr::from_ptr(host).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let input = std::slice::from_raw_parts(bytes, length);
    let snapshot = match MachineSnapshot::decode(input, host, (has_port == 1).then_some(port)) {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    *out_summary = MilaSnapshotSummary {
        machine_count: snapshot.machines.len() as u32,
        saved_at: snapshot.saved_at,
    };
    MilaFfiStatus::Ok
}
