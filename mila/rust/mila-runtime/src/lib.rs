//! Pure runtime state machines for idempotent Mila mutations.

mod backend;
mod custody;
mod error;
mod lock;
mod machine;
mod mutation;
mod push;
mod snapshot;
mod terminal;

pub use backend::{MutationRequest, SessionBackend, SessionRuntime};
pub use custody::{DeviceKeyProvider, KeyCustody};
pub use error::RuntimeError;
pub use lock::{AppLock, LockAvailability, LockDelay, LockEvent, LockPhase};
pub use machine::{MachineAction, SnapshotMachine};
pub use mutation::{MutationPhase, MutationTracker, NextAction};
pub use push::{
    PokeEnvelope, ProviderToken, PushEnvironment, PushProvider, PushRegistration,
    PushRegistrationReply, PushRegistrationRequest,
};
pub use snapshot::{load_snapshot, save_snapshot_if_newer, MachineSnapshot, SnapshotStore};
pub use terminal::*;

/// Maximum number of machines retained by an offline snapshot.
pub const MAX_SNAPSHOT_MACHINES: usize = 500;
/// Maximum encoded snapshot size accepted from disk.
pub const MAX_SNAPSHOT_BYTES: usize = 1 << 20;

fn validate_host(host: &str) -> Result<(), RuntimeError> {
    if host.is_empty()
        || host.len() > 253
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
    {
        return Err(RuntimeError::InvalidSnapshot);
    }
    Ok(())
}

#[cfg(test)]
mod machine_action_tests;
