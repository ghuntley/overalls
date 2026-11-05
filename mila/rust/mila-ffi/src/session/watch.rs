//! Typed, bounded native watch capabilities belonging to a parent session.
use super::{entry, guarded, output, revoked, runtime, SessionStatus};
use mila_transport::{WatchEvent, WatchRead, WatchRequest, WatchSession};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

pub const MILA_WATCH_READ_CAPACITY: usize = 8192;
#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WatchReadEvent {
    Event = 0,
    Idle = 1,
    Closed = 2,
    AuthorityLost = 3,
    TransportLost = 4,
}

struct WatchEntry {
    owner: u64,
    stream: WatchSession,
    resync: bool,
}
#[derive(Default)]
struct Watches {
    next: u64,
    entries: HashMap<u64, Arc<Mutex<Option<WatchEntry>>>>,
}
static WATCHES: OnceLock<Mutex<Watches>> = OnceLock::new();
fn watches() -> &'static Mutex<Watches> {
    WATCHES.get_or_init(Mutex::default)
}
fn watch_entry(handle: u64) -> Result<Arc<Mutex<Option<WatchEntry>>>, SessionStatus> {
    watches()
        .lock()
        .map_err(|_| SessionStatus::Internal)?
        .entries
        .get(&handle)
        .cloned()
        .ok_or(SessionStatus::InvalidHandle)
}
fn insert(owner: u64, stream: WatchSession, resync: bool) -> Result<u64, SessionStatus> {
    let mut table = watches().lock().map_err(|_| SessionStatus::Internal)?;
    if table.entries.len() >= 64 {
        return Err(SessionStatus::Busy);
    }
    let handle = table.next.checked_add(1).ok_or(SessionStatus::Internal)?;
    table.next = handle;
    table.entries.insert(
        handle,
        Arc::new(Mutex::new(Some(WatchEntry {
            owner,
            stream,
            resync,
        }))),
    );
    Ok(handle)
}

pub(super) fn take_owned_watches(owner: u64) -> Result<Vec<WatchSession>, SessionStatus> {
    let candidates = watches()
        .lock()
        .map_err(|_| SessionStatus::Internal)?
        .entries
        .iter()
        .map(|(handle, value)| (*handle, value.clone()))
        .collect::<Vec<_>>();
    let mut collected = Vec::new();
    // One lock at a time: concurrent parent closes cannot invert child locks.
    for (handle, value) in candidates {
        let mut guard = value.lock().map_err(|_| SessionStatus::Internal)?;
        if guard.as_ref().is_some_and(|value| value.owner == owner) {
            if let Some(value) = guard.take() {
                collected.push(value.stream);
            }
            watches()
                .lock()
                .map_err(|_| SessionStatus::Internal)?
                .entries
                .remove(&handle);
        }
    }
    Ok(collected)
}

fn filters(bytes: &[u8]) -> Result<WatchRequest, SessionStatus> {
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| SessionStatus::Invalid)?;
    let object = value.as_object().ok_or(SessionStatus::Invalid)?;
    if object.len() != 2 {
        return Err(SessionStatus::Invalid);
    }
    let ids = |key| -> Result<Vec<uuid::Uuid>, SessionStatus> {
        let values = object
            .get(key)
            .and_then(serde_json::Value::as_array)
            .ok_or(SessionStatus::Invalid)?;
        if values.len() > WatchRequest::MAX_FILTERS {
            return Err(SessionStatus::Invalid);
        }
        values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .and_then(|id| uuid::Uuid::parse_str(id).ok())
                    .ok_or(SessionStatus::Invalid)
            })
            .collect()
    };
    WatchRequest::new(ids("machines")?, ids("threads")?).map_err(|_| SessionStatus::Invalid)
}

fn projection(event: WatchEvent) -> Result<Vec<u8>, SessionStatus> {
    let value = match event {
        WatchEvent::Watching {
            session_id,
            machines,
            threads,
        } => {
            serde_json::json!({"version":1,"event":"watching","session_id":session_id,"machines":machines,"threads":threads})
        }
        WatchEvent::Heartbeat => serde_json::json!({"version":1,"event":"heartbeat"}),
        WatchEvent::MachineChanged(id) => {
            serde_json::json!({"version":1,"event":"machine","id":id})
        }
        WatchEvent::TerminalSessionsChanged(id) => {
            serde_json::json!({"version":1,"event":"terminal_session","machine_id":id})
        }
        WatchEvent::ThreadChanged(id) => serde_json::json!({"version":1,"event":"thread","id":id}),
        WatchEvent::Resync => serde_json::json!({"version":1,"event":"resync"}),
        WatchEvent::Session { id, authenticated } => {
            serde_json::json!({"version":1,"event":"session","id":id,"status":if authenticated {"authenticated"} else {"pending"}})
        }
        WatchEvent::SessionChanged(id) => {
            serde_json::json!({"version":1,"event":"session","id":id})
        }
        WatchEvent::Unknown => serde_json::json!({"version":1,"event":"unknown"}),
    };
    serde_json::to_vec(&value).map_err(|_| SessionStatus::Internal)
}

/// Open `watch --session` plus at most 64 canonical UUID filters. Filters are
/// exactly `{"machines":[UUID],"threads":[UUID]}`. The parent owns this handle.
/// # Safety
/// `filters` references `length` readable bytes; `out_handle` is writable.
#[no_mangle]
pub unsafe extern "C" fn mila_session_watch_open(
    session_handle: u64,
    filter_bytes: *const u8,
    length: usize,
    out_handle: *mut u64,
) -> SessionStatus {
    guarded(|| {
        if out_handle.is_null() {
            return Err(SessionStatus::Invalid);
        }
        // SAFETY: caller provides the stated readable byte extent.
        let request =
            filters(unsafe { super::bytes(filter_bytes, length, MILA_WATCH_READ_CAPACITY) }?)?;
        let parent = entry(session_handle)?;
        let guard = parent.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &guard.as_ref().ok_or(SessionStatus::InvalidHandle)?.session;
        let stream = runtime()?
            .block_on(session.watch(request))
            .map_err(|_| SessionStatus::Transport)?;
        let handle = insert(session_handle, stream, false)?;
        // SAFETY: non-null checked above; caller guarantees writable storage.
        unsafe {
            *out_handle = handle;
        }
        Ok(())
    })
}

/// @cc [owner:ghuntley,label:security;recovery] mila-watch-ffi-authority-fencing
/// Watch reads MUST bound waits to one second, refuse undersized buffers before
/// consuming events, and never write stale handles. Authority loss MUST fence
/// the parent and all child capabilities before returning. Reconnect uses a
/// fresh monotonically allocated handle and emits resync before further hints.
/// # Safety
/// `out` is writable for `capacity`; `written` and `event` are writable.
#[no_mangle]
pub unsafe extern "C" fn mila_session_watch_read_within(
    handle: u64,
    wait_ms: u32,
    out: *mut u8,
    capacity: usize,
    written: *mut usize,
    event: *mut WatchReadEvent,
) -> SessionStatus {
    guarded(|| {
        if out.is_null()
            || written.is_null()
            || event.is_null()
            || capacity < MILA_WATCH_READ_CAPACITY
            || wait_ms > 1000
        {
            return Err(SessionStatus::Invalid);
        }
        let value = watch_entry(handle)?;
        // Validate the parent before taking the child lock. Parent close takes
        // the inverse locks while fencing; this order prevents a close/read
        // deadlock and still rejects a stale child before consuming data.
        let owner = value
            .lock()
            .map_err(|_| SessionStatus::Internal)?
            .as_ref()
            .ok_or(SessionStatus::InvalidHandle)?
            .owner;
        let _parent = entry(owner)?;
        let mut guard = value.try_lock().map_err(|_| SessionStatus::Busy)?;
        let value = guard.as_mut().ok_or(SessionStatus::InvalidHandle)?;
        let read = runtime()?.block_on(
            value
                .stream
                .read_within(Duration::from_millis(wait_ms.into())),
        );
        let (data, kind) = match read {
            WatchRead::Event(WatchEvent::Watching { .. }) if value.resync => {
                value.resync = false;
                (projection(WatchEvent::Resync)?, WatchReadEvent::Event)
            }
            WatchRead::Event(event) => (projection(event)?, WatchReadEvent::Event),
            WatchRead::Idle => (Vec::new(), WatchReadEvent::Idle),
            WatchRead::Closed => (Vec::new(), WatchReadEvent::Closed),
            WatchRead::TransportLost => (Vec::new(), WatchReadEvent::TransportLost),
            WatchRead::AuthorityLost => {
                revoked()
                    .lock()
                    .map_err(|_| SessionStatus::Internal)?
                    .insert(value.owner);
                (Vec::new(), WatchReadEvent::AuthorityLost)
            }
        };
        if kind != WatchReadEvent::AuthorityLost {
            let _live_parent = entry(value.owner)?;
        }
        // SAFETY: validated pointers/capacity above and caller provides writable extents.
        // SAFETY: output bounds were validated above and the ABI call borrows the buffer.
        unsafe {
            output(&data, out, capacity, written)?;
        }
        // SAFETY: event is non-null and writable for one tag.
        unsafe {
            *event = kind;
        }
        Ok(())
    })
}

/// Reopen only this read-only subscription on its existing authenticated
/// connection. No mutation is retried. The old handle is irrevocably stale.
/// # Safety
/// `out_handle` references writable storage.
#[no_mangle]
pub unsafe extern "C" fn mila_session_watch_reconnect(
    handle: u64,
    out_handle: *mut u64,
) -> SessionStatus {
    guarded(|| {
        if out_handle.is_null() {
            return Err(SessionStatus::Invalid);
        }
        let value = watch_entry(handle)?;
        // Read the owner without retaining the child lock. Parent close takes
        // the parent lock first and then fences children, so reconnect must
        // acquire locks in that same order to avoid a close/reconnect cycle.
        let owner = value
            .try_lock()
            .map_err(|_| SessionStatus::Busy)?
            .as_ref()
            .ok_or(SessionStatus::InvalidHandle)?
            .owner;
        let parent = entry(owner)?;
        let parent = parent.try_lock().map_err(|_| SessionStatus::Busy)?;
        let session = &parent.as_ref().ok_or(SessionStatus::InvalidHandle)?.session;
        let mut guard = value.try_lock().map_err(|_| SessionStatus::Busy)?;
        let old = guard.as_mut().ok_or(SessionStatus::InvalidHandle)?;
        let runtime = runtime()?;
        let stream = runtime
            .block_on(session.watch(old.stream.request().clone()))
            .map_err(|_| SessionStatus::Transport)?;
        let next = insert(old.owner, stream, true)?;
        runtime.block_on(old.stream.close());
        *guard = None;
        watches()
            .lock()
            .map_err(|_| SessionStatus::Internal)?
            .entries
            .remove(&handle);
        // SAFETY: checked non-null; caller provides writable storage.
        unsafe {
            *out_handle = next;
        }
        Ok(())
    })
}

/// Close and irrevocably remove a child watch capability before network I/O.
#[no_mangle]
pub extern "C" fn mila_session_watch_close(handle: u64) -> SessionStatus {
    guarded(|| {
        let value = watch_entry(handle)?;
        let mut guard = value.try_lock().map_err(|_| SessionStatus::Busy)?;
        let mut value = guard.take().ok_or(SessionStatus::InvalidHandle)?;
        watches()
            .lock()
            .map_err(|_| SessionStatus::Internal)?
            .entries
            .remove(&handle);
        runtime()?.block_on(value.stream.close());
        Ok(())
    })
}
