//! Watch subscription and watch-line validation.

use crate::MilaFfiStatus;
use mila_transport::{decode_watch_line, WatchEvent};

/// Checks a bounded watch subscription filter count. UUID values themselves
/// remain in the native/runtime layer and never cross this ABI.
#[no_mangle]
pub extern "C" fn mila_watch_validate_filters(
    machine_count: u16,
    thread_count: u16,
) -> MilaFfiStatus {
    if (machine_count as usize) + (thread_count as usize)
        > mila_transport::WatchRequest::MAX_FILTERS
    {
        MilaFfiStatus::InvalidRequest
    } else {
        MilaFfiStatus::Ok
    }
}

/// Stable event tags returned by [`mila_watch_event_kind`].
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaWatchEventKind {
    Unknown = 0,
    Watching = 1,
    Heartbeat = 2,
    MachineChanged = 3,
    TerminalSessionsChanged = 4,
    ThreadChanged = 5,
    Resync = 6,
    Session = 7,
}

/// Decodes one bounded Porsche watch line and returns only its non-sensitive tag.
///
/// # Safety
/// `line` must be either null with `length == 0`, or point to `length` readable
/// bytes. No NUL termination is required.
#[no_mangle]
pub unsafe extern "C" fn mila_watch_event_kind(
    line: *const u8,
    length: usize,
    out_kind: *mut MilaWatchEventKind,
) -> MilaFfiStatus {
    if line.is_null() || out_kind.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: caller guarantees a readable byte slice of the supplied length.
    let bytes = std::slice::from_raw_parts(line, length);
    let event = match decode_watch_line(bytes) {
        Ok(event) => event,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let kind = match event {
        WatchEvent::Unknown => MilaWatchEventKind::Unknown,
        WatchEvent::Watching { .. } => MilaWatchEventKind::Watching,
        WatchEvent::Heartbeat => MilaWatchEventKind::Heartbeat,
        WatchEvent::MachineChanged(_) => MilaWatchEventKind::MachineChanged,
        WatchEvent::TerminalSessionsChanged(_) => MilaWatchEventKind::TerminalSessionsChanged,
        WatchEvent::ThreadChanged(_) => MilaWatchEventKind::ThreadChanged,
        WatchEvent::Resync => MilaWatchEventKind::Resync,
        WatchEvent::Session { .. } => MilaWatchEventKind::Session,
    };
    // SAFETY: caller guarantees writable storage for one event tag.
    *out_kind = kind;
    MilaFfiStatus::Ok
}
