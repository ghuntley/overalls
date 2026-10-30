//! Scalar terminal attach, input and resize validation.

use crate::MilaFfiStatus;
use mila_transport::TerminalAttachRequest;

/// Validates terminal dimensions before a native UI opens a PTY.
///
/// The bridge deliberately accepts only scalar values, so no platform pointer or
/// session secret crosses the ABI. `read_write` is reserved for the permission
/// boundary and is currently accepted as either 0 or 1.
#[no_mangle]
pub extern "C" fn mila_terminal_validate(columns: u16, rows: u16, read_write: u8) -> MilaFfiStatus {
    if read_write > 1 {
        return MilaFfiStatus::InvalidRequest;
    }
    let request = TerminalAttachRequest {
        machine_id: uuid::Uuid::nil(),
        session_id: uuid::Uuid::nil(),
        from: 0,
        columns,
        rows,
        read_write: read_write == 1,
    };
    request
        .validate()
        .map_or(MilaFfiStatus::InvalidRequest, |_| MilaFfiStatus::Ok)
}

/// Maximum terminal input accepted by the native boundary (bytes remain owned by the host).
pub const MILA_TERMINAL_MAX_INPUT: usize = 1 << 20;

/// Validates a terminal attach request without crossing machine or terminal identifiers.
#[no_mangle]
pub extern "C" fn mila_terminal_attach_validate(
    from: u64,
    columns: u16,
    rows: u16,
    read_write: u8,
) -> MilaFfiStatus {
    if read_write > 1 {
        return MilaFfiStatus::InvalidRequest;
    }
    let request = TerminalAttachRequest {
        machine_id: uuid::Uuid::nil(),
        session_id: uuid::Uuid::nil(),
        from,
        columns,
        rows,
        read_write: read_write == 1,
    };
    request
        .validate()
        .map_or(MilaFfiStatus::InvalidRequest, |_| MilaFfiStatus::Ok)
}

/// Validates a terminal input length and permission bit. Input bytes never cross this ABI.
#[no_mangle]
pub extern "C" fn mila_terminal_input_validate(length: usize, read_write: u8) -> MilaFfiStatus {
    if read_write > 1 || length > MILA_TERMINAL_MAX_INPUT || (read_write == 0 && length != 0) {
        MilaFfiStatus::InvalidRequest
    } else {
        MilaFfiStatus::Ok
    }
}

/// Validates a terminal resize request.
#[no_mangle]
pub extern "C" fn mila_terminal_resize_validate(
    columns: u16,
    rows: u16,
    read_write: u8,
) -> MilaFfiStatus {
    mila_terminal_attach_validate(0, columns, rows, read_write)
}
