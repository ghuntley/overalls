//! Worker-owned watch subscription. GTK receives coalesced refresh/loss hints only.
use super::{LiveSession, SessionError};
use mila_ffi::session::{SessionStatus, WatchReadEvent};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc,
};
use std::time::Duration;

const MAX_THREAD_FILTER_IDS: usize = 256;
const FILTER_SHARD_SIZE: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WatchHint {
    Refresh,
    AuthorityLost,
    TransportLost,
}

/// @cc [owner:ghuntley,label:security;reliability] linux-watch-filter-sharding
/// Every valid selected machine or thread ID MUST be retained within its
/// bounded window (500 machines, 256 threads) and emitted in requests of at most 64
/// IDs; malformed identifiers MUST be discarded before native serialization.
/// Builds bounded native watch requests. Each kind has its own window,
/// and every request stays within the transport's 64-filter limit.
fn watch_filter_groups(
    machine_ids: &[String],
    thread_ids: &[String],
) -> Result<Vec<Vec<u8>>, serde_json::Error> {
    fn canonical_id(value: &str) -> Option<String> {
        if value.len() != 36
            || !value.bytes().enumerate().all(|(index, byte)| {
                matches!(index, 8 | 13 | 18 | 23) == (byte == b'-')
                    && (matches!(index, 8 | 13 | 18 | 23) || byte.is_ascii_hexdigit())
            })
        {
            return None;
        }
        let mut canonical = value.to_owned();
        canonical.make_ascii_lowercase();
        Some(canonical)
    }
    fn bounded(values: &[String], maximum: usize) -> Vec<String> {
        let mut ids = values
            .iter()
            .filter_map(|value| canonical_id(value))
            .collect::<Vec<_>>();
        ids.sort_unstable();
        ids.dedup();
        ids.truncate(maximum);
        ids
    }
    let machines = bounded(machine_ids, mila_runtime::MAX_SNAPSHOT_MACHINES);
    let threads = bounded(thread_ids, MAX_THREAD_FILTER_IDS);
    let mut groups = Vec::new();
    for shard in machines.chunks(FILTER_SHARD_SIZE) {
        groups.push(serde_json::to_vec(&serde_json::json!({
            "machines": shard,
            "threads": [],
        }))?);
    }
    for shard in threads.chunks(FILTER_SHARD_SIZE) {
        groups.push(serde_json::to_vec(&serde_json::json!({
            "machines": [],
            "threads": shard,
        }))?);
    }
    if groups.is_empty() {
        groups.push(serde_json::to_vec(&serde_json::json!({
            "machines": [],
            "threads": [],
        }))?);
    }
    Ok(groups)
}

/// @cc [owner:ghuntley,label:security;reliability] linux-watch-worker-fence
/// The worker owns every child watch handle, never retries mutations, and emits hints only.
/// Dropping the subscription cancels it; parent session revocation remains authoritative.
#[derive(Debug)]
pub struct WatchSubscription {
    receiver: mpsc::Receiver<WatchHint>,
    cancel: Arc<AtomicBool>,
}
impl WatchSubscription {
    pub fn poll(&self) -> Option<WatchHint> {
        let mut hint = None;
        for next in self.receiver.try_iter().take(16) {
            if hint != Some(WatchHint::AuthorityLost) {
                hint = Some(next);
            }
        }
        hint
    }
}
impl Drop for WatchSubscription {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Release);
    }
}
impl LiveSession {
    #[expect(
        clippy::too_many_lines,
        reason = "The watch worker keeps its bounded subscription, reconnect and event mapping in one audited lifecycle."
    )]
    pub fn subscribe(&self) -> Result<WatchSubscription, SessionError> {
        let parent = self.handle()?;
        let (sender, receiver) = mpsc::sync_channel(16);
        let cancel = Arc::new(AtomicBool::new(false));
        let stop = cancel.clone();
        std::thread::Builder::new()
            .name("mila-watch".into())
            .spawn(move || {
                // Load the currently authorized IDs once. The watches carry
                // only these identifiers; every hint still causes the normal
                // bounded listing read on the GTK side.
                let mut machine_ids = Vec::new();
                let mut thread_ids = Vec::new();
                let mut listing = None;
                for _ in 0..20 {
                    if stop.load(Ordering::Acquire) {
                        return;
                    }
                    if let Ok(bytes) = super::connection::read_complete_machines(parent) {
                        listing = Some(bytes);
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                if let Some(listing) = listing {
                    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&listing) {
                        machine_ids = value
                            .get("machines")
                            .and_then(serde_json::Value::as_array)
                            .into_iter()
                            .flatten()
                            .filter_map(|machine| {
                                machine.get("id").and_then(serde_json::Value::as_str)
                            })
                            .map(str::to_owned)
                            .collect::<Vec<_>>();
                        // A thread listing is a separate authorized read. Each
                        // filter kind is bounded and sharded below, so a large
                        // listing does not silently drop identities.
                        let mut threads = vec![0_u8; 1 << 20];
                        let mut thread_written = 0_usize;
                        let command = b"thread ls --json";
                        // SAFETY: the bounded command and output buffers remain alive for the FFI call.
                        let thread_status = unsafe {
                            mila_ffi::session::mila_session_thread_action(
                                parent,
                                std::ptr::null(),
                                0,
                                command.as_ptr(),
                                command.len(),
                                std::ptr::null(),
                                0,
                                std::ptr::null(),
                                0,
                                std::ptr::null(),
                                0,
                                threads.as_mut_ptr(),
                                threads.len(),
                                &raw mut thread_written,
                            )
                        };
                        thread_ids = (thread_status == SessionStatus::Ok)
                            .then(|| {
                                serde_json::from_slice::<serde_json::Value>(
                                    &threads[..thread_written],
                                )
                                .ok()
                            })
                            .flatten()
                            .and_then(|value| {
                                let body = value.get("result").unwrap_or(&value);
                                body.get("items").cloned()
                            })
                            .and_then(|value| value.as_array().cloned())
                            .into_iter()
                            .flatten()
                            .filter_map(|thread| {
                                thread
                                    .get("id")
                                    .and_then(serde_json::Value::as_str)
                                    .map(str::to_owned)
                            })
                            .collect::<Vec<_>>();
                    }
                }
                let Ok(filters) = watch_filter_groups(&machine_ids, &thread_ids) else {
                    let _ = sender.try_send(WatchHint::TransportLost);
                    return;
                };
                let mut handles = Vec::with_capacity(filters.len());
                for filters in &filters {
                    let mut handle = 0;
                    let mut status = SessionStatus::Busy;
                    for _ in 0..20 {
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                        // SAFETY: filters and output handle live throughout the blocking call.
                        status = unsafe {
                            mila_ffi::session::mila_session_watch_open(
                                parent,
                                filters.as_ptr(),
                                filters.len(),
                                &raw mut handle,
                            )
                        };
                        if status != SessionStatus::Busy {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    if status != SessionStatus::Ok || handle == 0 {
                        for handle in handles {
                            // SAFETY: every handle was returned by the same FFI registry.
                            let _ = mila_ffi::session::mila_session_watch_close(handle);
                        }
                        let _ = sender.try_send(WatchHint::TransportLost);
                        return;
                    }
                    handles.push(handle);
                }
                let mut stopped = false;
                let mut buffer = [0_u8; 8192];
                while !stop.load(Ordering::Acquire) && !stopped {
                    for (index, handle) in handles.iter_mut().enumerate() {
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                        let current = *handle;
                        let mut written = 0;
                        let mut event = WatchReadEvent::Idle;
                        // SAFETY: output pointers cover the declared writable extents.
                        let status = unsafe {
                            mila_ffi::session::mila_session_watch_read_within(
                                current,
                                if index == 0 { 250 } else { 0 },
                                buffer.as_mut_ptr(),
                                buffer.len(),
                                &raw mut written,
                                &raw mut event,
                            )
                        };
                        if status == SessionStatus::Busy {
                            continue;
                        }
                        if status != SessionStatus::Ok {
                            let _ = sender.send(WatchHint::TransportLost);
                            stopped = true;
                            break;
                        }
                        match event {
                            WatchReadEvent::Event => {
                                let refresh =
                                    serde_json::from_slice::<serde_json::Value>(&buffer[..written])
                                        .ok()
                                        .and_then(|value| {
                                            value
                                                .get("event")
                                                .and_then(serde_json::Value::as_str)
                                                .map(str::to_owned)
                                        })
                                        .is_some_and(|kind| {
                                            matches!(
                                                kind.as_str(),
                                                "machine"
                                                    | "thread"
                                                    | "terminal_session"
                                                    | "resync"
                                                    | "session"
                                            )
                                        });
                                if refresh {
                                    let _ = sender.try_send(WatchHint::Refresh);
                                }
                            }
                            WatchReadEvent::Idle => {}
                            WatchReadEvent::AuthorityLost => {
                                let _ = sender.send(WatchHint::AuthorityLost);
                                stopped = true;
                                break;
                            }
                            WatchReadEvent::Closed | WatchReadEvent::TransportLost => {
                                let mut replacement = 0;
                                // SAFETY: replacement is writable; reconnect subscribes only.
                                let status = unsafe {
                                    mila_ffi::session::mila_session_watch_reconnect(
                                        current,
                                        &raw mut replacement,
                                    )
                                };
                                if status != SessionStatus::Ok || replacement == 0 {
                                    let _ = sender.send(WatchHint::TransportLost);
                                    stopped = true;
                                    break;
                                }
                                *handle = replacement;
                                let _ = sender.try_send(WatchHint::Refresh);
                            }
                        }
                    }
                }
                for handle in handles {
                    // SAFETY: every handle was returned by the same FFI registry.
                    let _ = mila_ffi::session::mila_session_watch_close(handle);
                }
            })
            .map_err(|_| SessionError::Unavailable)?;
        Ok(WatchSubscription { receiver, cancel })
    }
}

#[cfg(test)]
mod tests {
    use super::watch_filter_groups;

    fn id(value: usize) -> String {
        format!("00000000-0000-0000-0000-{value:012x}")
    }

    fn fields(bytes: &[u8]) -> (Vec<String>, Vec<String>) {
        let value: serde_json::Value = serde_json::from_slice(bytes).expect("watch filter JSON");
        let values = |name: &str| {
            value[name]
                .as_array()
                .expect("watch filter array")
                .iter()
                .map(|value| value.as_str().expect("watch filter id").to_owned())
                .collect::<Vec<_>>()
        };
        (values("machines"), values("threads"))
    }

    #[test]
    fn groups_are_bounded_deduplicated_and_complete() {
        let machine_ids = (0..510).map(id).collect::<Vec<_>>();
        let mut duplicate_heavy = machine_ids.clone();
        duplicate_heavy.extend_from_slice(&machine_ids[..10]);
        let thread_ids = (0..130).map(id).collect::<Vec<_>>();
        let groups = watch_filter_groups(&duplicate_heavy, &thread_ids).expect("groups");
        assert_eq!(groups.len(), 11);
        let machines = groups
            .iter()
            .flat_map(|bytes| fields(bytes).0)
            .collect::<Vec<_>>();
        let threads = groups
            .iter()
            .flat_map(|bytes| fields(bytes).1)
            .collect::<Vec<_>>();
        assert_eq!(machines.len(), 500);
        assert_eq!(
            machines
                .iter()
                .collect::<std::collections::HashSet<_>>()
                .len(),
            500
        );
        assert_eq!(threads.len(), 130);
        assert_eq!(
            threads
                .iter()
                .collect::<std::collections::HashSet<_>>()
                .len(),
            130
        );
        assert!(groups.iter().all(|bytes| {
            let (machines, threads) = fields(bytes);
            machines.len() <= 64 && threads.len() <= 64 && machines.is_empty() != threads.is_empty()
        }));
    }

    #[test]
    fn groups_drop_malformed_ids_and_keep_empty_subscription() {
        let groups = watch_filter_groups(
            &[
                "BAD".to_owned(),
                "00000000-0000-0000-0000-00000000000A".to_owned(),
            ],
            &[],
        )
        .expect("groups");
        assert_eq!(groups.len(), 1);
        let (machines, threads) = fields(&groups[0]);
        assert_eq!(machines, vec!["00000000-0000-0000-0000-00000000000a"]);
        assert!(threads.is_empty());

        let empty = watch_filter_groups(&[], &[]).expect("groups");
        assert_eq!(empty.len(), 1);
        assert_eq!(fields(&empty[0]), (Vec::new(), Vec::new()));
    }
}
