//! Route and session command formatting and command-kind projection.

use crate::{MilaFfiStatus, MilaRouteOutput};
use mila_model::MilaRoute;
use std::ffi::{c_char, CStr};

/// @cc [owner:ghuntley,label:security;protocol] mila-ffi-bounded-output
/// Parses an `overalls://` route and writes its canonical spelling to `output`.
///
/// FFI parsing MUST validate UTF-8 and the closed route grammar before writing;
/// output writes MUST be bounded by the caller-provided capacity.
///
/// # Safety
/// `input` must point to a NUL-terminated UTF-8 C string. `output.bytes` must
/// reference `capacity` writable bytes and `output.written` one writable `usize`.
#[no_mangle]
pub unsafe extern "C" fn mila_route_format(
    input: *const c_char,
    output: MilaRouteOutput,
) -> MilaFfiStatus {
    if input.is_null() || output.bytes.is_null() || output.written.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: `input` is non-null and the caller guarantees a NUL-terminated string.
    let Ok(input) = unsafe { CStr::from_ptr(input) }.to_str() else {
        return MilaFfiStatus::InvalidRoute;
    };
    let Ok(route) = MilaRoute::parse(input) else {
        return MilaFfiStatus::InvalidRoute;
    };
    let canonical = route.format();
    let bytes = canonical.as_bytes();
    if bytes.len() > output.capacity {
        return MilaFfiStatus::OutputTooSmall;
    }
    // SAFETY: `output.bytes` is non-null with `capacity` writable bytes and
    // `bytes.len() <= capacity`; Rust-owned `bytes` cannot overlap caller storage.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.bytes, bytes.len()) };
    if output.capacity > bytes.len() {
        // SAFETY: `bytes.len() < capacity`, so the offset stays inside the caller's buffer.
        let terminator = unsafe { output.bytes.add(bytes.len()) };
        // SAFETY: `terminator` addresses a writable byte inside the caller's buffer.
        unsafe { *terminator = 0 };
    }
    // SAFETY: the caller supplied a valid writable `written` pointer.
    unsafe { *output.written = bytes.len() };
    MilaFfiStatus::Ok
}

/// @cc [owner:ghuntley,label:security;protocol] mila-session-command-bounded
/// Formats a catalogued machine action with bounded, canonical output.
/// Native callers MUST receive only catalogued commands; credentials and arbitrary payloads MUST NOT cross this ABI.
///
/// # Safety
/// Pointers must be valid NUL-terminated strings and `output` must reference writable storage.
#[no_mangle]
pub unsafe extern "C" fn mila_session_command_format(
    action: *const c_char,
    machine_id: *const c_char,
    request_id: *const c_char,
    output: MilaRouteOutput,
) -> MilaFfiStatus {
    if action.is_null()
        || machine_id.is_null()
        || output.bytes.is_null()
        || output.written.is_null()
    {
        return MilaFfiStatus::NullInput;
    }
    let text = |ptr: *const c_char| {
        // SAFETY: only non-null pointers reach this closure, and the caller
        // guarantees each is a NUL-terminated string.
        unsafe { CStr::from_ptr(ptr) }
            .to_str()
            .map(str::to_owned)
            .map_err(|_| MilaFfiStatus::InvalidRequest)
    };
    let action = match text(action) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let machine = match text(machine_id) {
        Ok(v) => v,
        Err(e) => return e,
    };
    if mila_model::Identifier::parse(&machine).is_err() {
        return MilaFfiStatus::InvalidRequest;
    }
    let mutation = match action.as_str() {
        "show" => false,
        "start" | "stop" | "pause" | "resume" | "unpause" | "pin" | "unpin" | "rm" => true,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    let mut line = format!("{action} {machine} --json");
    if mutation {
        if request_id.is_null() {
            return MilaFfiStatus::InvalidRequest;
        }
        let id = match text(request_id) {
            Ok(v) => v,
            Err(e) => return e,
        };
        if mila_model::RequestId::parse(&id).is_err() {
            return MilaFfiStatus::InvalidRequest;
        }
        line.push_str(" --request-id=");
        line.push_str(&id);
    }
    let Ok(command) = mila_protocol::Command::parse(&line).and_then(|c| c.format()) else {
        return MilaFfiStatus::InvalidRequest;
    };
    let bytes = command.as_bytes();
    if bytes.len() > output.capacity {
        return MilaFfiStatus::OutputTooSmall;
    }
    // SAFETY: `output.bytes` is non-null with `capacity` writable bytes and
    // `bytes.len() <= capacity`; Rust-owned `bytes` cannot overlap caller storage.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.bytes, bytes.len()) };
    if output.capacity > bytes.len() {
        // SAFETY: `bytes.len() < capacity`, so the offset stays inside the caller's buffer.
        let terminator = unsafe { output.bytes.add(bytes.len()) };
        // SAFETY: `terminator` addresses a writable byte inside the caller's buffer.
        unsafe { *terminator = 0 };
    }
    // SAFETY: `output.written` is non-null and the caller guarantees one writable `usize`.
    unsafe { *output.written = bytes.len() };
    MilaFfiStatus::Ok
}

/// Closed thread command tags. Arguments and payloads are never returned across the ABI.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaThreadCommandKind {
    Unknown = 0,
    List = 1,
    Show = 2,
    Turns = 3,
    Prompt = 4,
    Answer = 5,
    PlanApprove = 6,
    PlanRevise = 7,
    Mode = 8,
    Read = 9,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaMachineCommandKind {
    Unknown = 0,
    List = 1,
    Show = 2,
    New = 3,
    Resize = 4,
    Start = 5,
    Stop = 6,
    Pause = 7,
    Resume = 8,
    Delete = 9,
    ShareAdd = 10,
    ShareRemove = 11,
    WebShow = 12,
    WebSet = 13,
}

/// Projects a parsed machine-management command to a closed operation tag.
///
/// # Safety
/// `line` and `out_kind` must be valid non-null pointers; `line` must be a
/// NUL-terminated UTF-8 string and `out_kind` writable for one value.
#[no_mangle]
pub unsafe extern "C" fn mila_machine_command_kind(
    line: *const c_char,
    out_kind: *mut MilaMachineCommandKind,
) -> MilaFfiStatus {
    if line.is_null() || out_kind.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: `line` is non-null and the caller guarantees a NUL-terminated string.
    let Ok(line) = unsafe { CStr::from_ptr(line) }.to_str() else {
        return MilaFfiStatus::InvalidRequest;
    };
    let command = match mila_protocol::Command::parse(line) {
        Ok(command) => command.command,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let kind = match command.as_str() {
        "ls" => MilaMachineCommandKind::List,
        "show" => MilaMachineCommandKind::Show,
        "new" => MilaMachineCommandKind::New,
        "resize" => MilaMachineCommandKind::Resize,
        "start" => MilaMachineCommandKind::Start,
        "stop" => MilaMachineCommandKind::Stop,
        "pause" => MilaMachineCommandKind::Pause,
        "resume" | "unpause" => MilaMachineCommandKind::Resume,
        "rm" => MilaMachineCommandKind::Delete,
        "share add" => MilaMachineCommandKind::ShareAdd,
        "share remove" => MilaMachineCommandKind::ShareRemove,
        "web show" => MilaMachineCommandKind::WebShow,
        "web set" => MilaMachineCommandKind::WebSet,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    // SAFETY: `out_kind` is non-null and the caller guarantees writable storage for one value.
    unsafe { *out_kind = kind };
    MilaFfiStatus::Ok
}

/// Parses a bounded Porsche command and projects only its catalogued thread operation.
/// The caller retains ownership of the command bytes; no argument or payload is returned.
///
/// # Safety
/// `line` and `out_kind` must be valid non-null pointers. `line` must point to a
/// NUL-terminated UTF-8 C string and `out_kind` must be writable for one value.
#[no_mangle]
pub unsafe extern "C" fn mila_thread_command_kind(
    line: *const c_char,
    out_kind: *mut MilaThreadCommandKind,
) -> MilaFfiStatus {
    if line.is_null() || out_kind.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: `line` is non-null and the caller guarantees a NUL-terminated string.
    let Ok(line) = unsafe { CStr::from_ptr(line) }.to_str() else {
        return MilaFfiStatus::InvalidRequest;
    };
    let Ok(command) = mila_protocol::Command::parse(line) else {
        return MilaFfiStatus::InvalidRequest;
    };
    let kind = match command.command.as_str() {
        "thread ls" => MilaThreadCommandKind::List,
        "thread show" => MilaThreadCommandKind::Show,
        "thread turns" => MilaThreadCommandKind::Turns,
        "thread prompt" => MilaThreadCommandKind::Prompt,
        "thread answer" => MilaThreadCommandKind::Answer,
        "thread plan approve" => MilaThreadCommandKind::PlanApprove,
        "thread plan revise" => MilaThreadCommandKind::PlanRevise,
        "thread mode" => MilaThreadCommandKind::Mode,
        "thread read" => MilaThreadCommandKind::Read,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    // SAFETY: `out_kind` is non-null and the caller guarantees writable storage for one value.
    unsafe { *out_kind = kind };
    MilaFfiStatus::Ok
}
