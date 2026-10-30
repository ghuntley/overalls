//! Machine action policy projection from a validated snapshot.

use crate::MilaFfiStatus;
use mila_runtime::MachineSnapshot;
use std::ffi::{c_char, CStr};

/// Bit flags describing actions permitted for one cached machine.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MilaMachineActions {
    pub bits: u16,
}

/// Projects the closed action policy for a machine in a validated snapshot.
///
/// # Safety
/// `bytes` and `host` must be valid for the supplied length and NUL-terminated respectively; `out_actions` must be writable.
#[no_mangle]
pub unsafe extern "C" fn mila_snapshot_machine_actions(
    bytes: *const u8,
    length: usize,
    host: *const c_char,
    port: u16,
    has_port: u8,
    index: u32,
    out_actions: *mut MilaMachineActions,
) -> MilaFfiStatus {
    if bytes.is_null() || host.is_null() || out_actions.is_null() || has_port > 1 {
        return MilaFfiStatus::NullInput;
    }
    let host = match CStr::from_ptr(host).to_str() {
        Ok(v) => v,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let snapshot = match MachineSnapshot::decode(
        std::slice::from_raw_parts(bytes, length),
        host,
        (has_port == 1).then_some(port),
    ) {
        Ok(v) => v,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let Some(machine) = snapshot.machines.get(index as usize) else {
        return MilaFfiStatus::InvalidRequest;
    };
    let bits = machine
        .available_actions()
        .into_iter()
        .fold(0u16, |bits, action| bits | (1 << action as u16));
    *out_actions = MilaMachineActions { bits };
    MilaFfiStatus::Ok
}
