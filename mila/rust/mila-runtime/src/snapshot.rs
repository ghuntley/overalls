use crate::{
    validate_host, RuntimeError, SnapshotMachine, MAX_SNAPSHOT_BYTES, MAX_SNAPSHOT_MACHINES,
};
use serde::{Deserialize, Serialize};

/// Owner-only persistence boundary. Implementations must enforce platform ACLs.
pub trait SnapshotStore {
    fn read(&self, deployment: &str) -> Result<Option<Vec<u8>>, RuntimeError>;
    fn write(&self, deployment: &str, bytes: &[u8]) -> Result<(), RuntimeError>;
}

/// Loads the newest valid snapshot for a deployment from a platform store.
///
/// Native clients use this boundary so persistence remains outside the UI and
/// malformed or cross-deployment bytes never become visible to callers.
pub fn load_snapshot<S: SnapshotStore>(
    store: &S,
    host: &str,
    port: Option<u16>,
) -> Result<Option<MachineSnapshot>, RuntimeError> {
    let Some(bytes) = store.read(host)? else {
        return Ok(None);
    };
    MachineSnapshot::decode(&bytes, host, port).map(Some)
}

/// Persists a fresh snapshot only when it is at least as new as the cached one.
///
/// The comparison happens after decoding the existing bytes, so a stale native
/// response cannot overwrite newer offline data and invalid data is rejected
/// before a write occurs.
pub fn save_snapshot_if_newer<S: SnapshotStore>(
    store: &S,
    current: Option<&MachineSnapshot>,
    fresh: MachineSnapshot,
) -> Result<MachineSnapshot, RuntimeError> {
    let existing = load_snapshot(store, &fresh.host, fresh.port)?;
    let baseline = match (current, existing.as_ref()) {
        (Some(explicit), Some(stored)) => Some(if explicit.saved_at >= stored.saved_at {
            explicit
        } else {
            stored
        }),
        (Some(explicit), None) => Some(explicit),
        (None, Some(stored)) => Some(stored),
        (None, None) => None,
    };
    let selected = MachineSnapshot::merge(baseline.cloned(), fresh)?;
    if baseline.is_none_or(|snapshot| snapshot != &selected) {
        let bytes = selected.encode()?;
        store.write(&selected.host, &bytes)?;
    }
    Ok(selected)
}

/// A complete machine listing for one deployment.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineSnapshot {
    pub version: u8,
    pub host: String,
    pub port: Option<u16>,
    pub saved_at: u64,
    pub machines: Vec<SnapshotMachine>,
}

impl MachineSnapshot {
    pub const VERSION: u8 = 1;

    /// Constructs a bounded snapshot, retaining deterministic machine order.
    pub fn new(
        host: String,
        port: Option<u16>,
        saved_at: u64,
        mut machines: Vec<SnapshotMachine>,
    ) -> Result<Self, RuntimeError> {
        validate_host(&host)?;
        machines.sort_by(|a, b| {
            (std::cmp::Reverse(a.pinned), a.name.as_str(), a.id.as_str()).cmp(&(
                std::cmp::Reverse(b.pinned),
                b.name.as_str(),
                b.id.as_str(),
            ))
        });
        machines.truncate(MAX_SNAPSHOT_MACHINES);
        Ok(Self {
            version: Self::VERSION,
            host,
            port,
            saved_at,
            machines,
        })
    }

    /// Encodes only the closed snapshot schema.
    pub fn encode(&self) -> Result<Vec<u8>, RuntimeError> {
        if self.version != Self::VERSION || self.machines.len() > MAX_SNAPSHOT_MACHINES {
            return Err(RuntimeError::InvalidSnapshot);
        }
        let bytes = serde_json::to_vec(self).map_err(|_| RuntimeError::InvalidSnapshot)?;
        if bytes.len() > MAX_SNAPSHOT_BYTES {
            return Err(RuntimeError::SnapshotTooLarge);
        }
        Ok(bytes)
    }

    /// Decodes a snapshot for exactly one deployment; unknown fields are refused.
    pub fn decode(bytes: &[u8], host: &str, port: Option<u16>) -> Result<Self, RuntimeError> {
        if bytes.len() > MAX_SNAPSHOT_BYTES {
            return Err(RuntimeError::SnapshotTooLarge);
        }
        let value: serde_json::Value =
            serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidSnapshot)?;
        let object = value.as_object().ok_or(RuntimeError::InvalidSnapshot)?;
        let allowed = ["version", "host", "port", "saved_at", "machines"];
        if object.keys().any(|key| !allowed.contains(&key.as_str()))
            || object.len() != allowed.len()
        {
            return Err(RuntimeError::InvalidSnapshot);
        }
        let snapshot: Self =
            serde_json::from_value(value).map_err(|_| RuntimeError::InvalidSnapshot)?;
        if snapshot.version != Self::VERSION
            || snapshot.host != host
            || snapshot.port != port
            || snapshot.machines.len() > MAX_SNAPSHOT_MACHINES
        {
            return Err(RuntimeError::InvalidSnapshot);
        }
        validate_host(host)?;
        Ok(snapshot)
    }

    /// Merges complete listings without allowing stale responses to overwrite fresh data.
    pub fn merge(current: Option<Self>, fresh: Self) -> Result<Self, RuntimeError> {
        if let Some(current) = current {
            if current.host != fresh.host || current.port != fresh.port {
                return Err(RuntimeError::SnapshotDeploymentMismatch);
            }
            if current.saved_at > fresh.saved_at {
                return Ok(current);
            }
        }
        Ok(fresh)
    }
}
