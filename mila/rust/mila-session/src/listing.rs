use crate::{ApplicationSession, SessionError};
use mila_model::Identifier;
use mila_runtime::{MachineSnapshot, SnapshotMachine, MAX_SNAPSHOT_BYTES, MAX_SNAPSHOT_MACHINES};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};

/// Validated display rows. Permissions describe presentation, never server authority.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MachineListing {
    machines: Vec<SnapshotMachine>,
    next_cursor: Option<Identifier>,
}
impl MachineListing {
    pub fn machines(&self) -> &[SnapshotMachine] {
        &self.machines
    }
    pub fn has_more(&self) -> bool {
        self.next_cursor.is_some()
    }
}

impl ApplicationSession {
    pub fn listing(&self) -> Option<&MachineListing> {
        self.listing.as_ref()
    }

    /// @cc [owner:ghuntley,label:security;protocol] mila-session-refresh-atomic
    /// A refused, malformed, oversized or interrupted refresh MUST preserve the
    /// last successful listing. Only a validated zero-exit read replaces it.
    pub async fn refresh_machines(&mut self) -> Result<&MachineListing, SessionError> {
        let page = self.page(None).await?;
        self.seen_cursors.clear();
        if let Some(cursor) = page.next_cursor {
            self.seen_cursors.insert(cursor);
        }
        Ok(self.listing.insert(page))
    }

    /// @cc [owner:ghuntley,label:protocol] mila-session-pagination-bounds
    /// Pagination MUST use validated canonical UUID cursors on the same SSH
    /// connection, refuse cursor cycles and more than 500 distinct machines or cursors,
    /// and commit rows and cursor together only after validation succeeds.
    pub async fn more_machines(&mut self) -> Result<&MachineListing, SessionError> {
        let current = self.listing.as_ref().ok_or(SessionError::NotLoaded)?;
        if let Some(cursor) = current.next_cursor {
            if self.seen_cursors.len() >= MAX_SNAPSHOT_MACHINES {
                return Err(SessionError::Bounds);
            }
            let page = self.page(Some(cursor)).await?;
            if page
                .next_cursor
                .is_some_and(|next| self.seen_cursors.contains(&next))
            {
                return Err(SessionError::RepeatedCursor);
            }
            let mut machines: HashMap<String, SnapshotMachine> = current
                .machines
                .iter()
                .chain(page.machines.iter())
                .map(|m| (m.id.clone(), m.clone()))
                .collect();
            if machines.len() > MAX_SNAPSHOT_MACHINES {
                return Err(SessionError::Bounds);
            }
            let mut combined = MachineListing {
                machines: machines.drain().map(|(_, m)| m).collect(),
                next_cursor: page.next_cursor,
            };
            sort(&mut combined.machines);
            if let Some(next) = combined.next_cursor {
                self.seen_cursors.insert(next);
            }
            self.listing = Some(combined);
        }
        self.listing.as_ref().ok_or(SessionError::NotLoaded)
    }

    /// @cc [owner:ghuntley,label:security] mila-session-complete-snapshot
    /// An offline snapshot MUST be derived only from a complete validated listing
    /// and MUST remain bound to this connection's management host and port.
    pub fn snapshot(&self, saved_at: u64) -> Result<Option<MachineSnapshot>, SessionError> {
        let Some(listing) = self.listing.as_ref().filter(|l| !l.has_more()) else {
            return Ok(None);
        };
        let snapshot = MachineSnapshot::new(
            self.host.clone(),
            Some(self.port),
            saved_at,
            listing.machines.clone(),
        )
        .map_err(|_| SessionError::InvalidListing)?;
        snapshot.encode().map_err(|_| SessionError::Bounds)?;
        Ok(Some(snapshot))
    }

    async fn page(&self, cursor: Option<Identifier>) -> Result<MachineListing, SessionError> {
        let command = cursor.map_or_else(
            || "ls --json".to_owned(),
            |cursor| format!("ls --json --after {cursor}"),
        );
        let output = self.exec(&command, &[]).await?;
        if output.exit_status != 0 {
            return Err(SessionError::Refused);
        }
        decode_listing(&output.stdout)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u8,
    status: String,
    result: WireListing,
}
#[derive(Deserialize)]
struct WireListing {
    items: Vec<WireMachine>,
    next_cursor: Option<String>,
}
#[derive(Deserialize)]
struct WireMachine {
    id: String,
    name: String,
    desired_state: String,
    observed_state: Option<String>,
    pinned: bool,
    owner: bool,
    permissions: Permissions,
}
#[derive(Deserialize)]
struct Permissions {
    read: bool,
    write: bool,
    manage: bool,
}

/// @cc [owner:ghuntley,label:security;protocol] mila-session-typed-machine-read
/// Listing decoding MUST reject invalid identity, authority, version or cursor
/// fields and duplicate IDs. Unknown descriptive fields may be ignored; unknown
/// observed states MUST project as unavailable and never enable lifecycle actions.
pub fn decode_listing(bytes: &[u8]) -> Result<MachineListing, SessionError> {
    if bytes.len() > MAX_SNAPSHOT_BYTES {
        return Err(SessionError::Bounds);
    }
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|_| SessionError::InvalidListing)?;
    if envelope.version != 1 || envelope.status != "succeeded" {
        return Err(SessionError::InvalidListing);
    }
    if envelope.result.items.len() > MAX_SNAPSHOT_MACHINES {
        return Err(SessionError::Bounds);
    }
    let next_cursor = envelope
        .result
        .next_cursor
        .map(|c| Identifier::parse(&c))
        .transpose()
        .map_err(|_| SessionError::InvalidListing)?;
    let mut ids = HashSet::new();
    let mut machines = Vec::with_capacity(envelope.result.items.len());
    for m in envelope.result.items {
        let id = Identifier::parse(&m.id).map_err(|_| SessionError::InvalidListing)?;
        if !ids.insert(id)
            || m.name.is_empty()
            || m.name.len() > 4096
            || !matches!(
                m.desired_state.as_str(),
                "running" | "stopped" | "paused" | "deleted"
            )
        {
            return Err(SessionError::InvalidListing);
        }
        machines.push(SnapshotMachine {
            id: m.id,
            name: m.name,
            desired_state: m.desired_state,
            observed_state: m.observed_state.filter(|s| {
                matches!(
                    s.as_str(),
                    "pending" | "running" | "stopped" | "paused" | "unknown" | "failed" | "deleted"
                )
            }),
            pinned: m.pinned,
            // The snapshot's optional owner is a presence marker, never account identity.
            owner: m.owner.then(|| "self".to_owned()),
            read: m.permissions.read,
            write: m.permissions.write,
            manage: m.permissions.manage,
        });
    }
    sort(&mut machines);
    Ok(MachineListing {
        machines,
        next_cursor,
    })
}

fn sort(machines: &mut [SnapshotMachine]) {
    machines.sort_by(|a, b| {
        (std::cmp::Reverse(a.pinned), &a.name, &a.id).cmp(&(
            std::cmp::Reverse(b.pinned),
            &b.name,
            &b.id,
        ))
    });
}
