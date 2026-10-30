//! Pure runtime state machines for idempotent Mila mutations.

use mila_model::RequestId;
use mila_protocol::{ReceiptStatus, Reply};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

mod terminal;
pub use terminal::*;

/// The externally observable phase of one mutation request.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum MutationPhase {
    Submitted,
    Uncertain,
    Accepted,
    Succeeded,
    Failed,
    Refused,
}

impl MutationPhase {
    pub const fn terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Refused)
    }
}

/// Immutable state for a mutation submitted at most once.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MutationTracker {
    pub request_id: RequestId,
    pub phase: MutationPhase,
    pub polls: u32,
    pub operation_id: Option<String>,
    pub error: Option<String>,
    pub result: Value,
}

impl MutationTracker {
    /// @cc [owner:ghuntley,label:protocol;security] mila-runtime-mutation-once
    /// Allocates a tracker before any network submission.
    ///
    /// A tracker MUST retain one request id for its lifetime; uncertainty transitions
    /// to polling and MUST never create a second submission id.
    pub fn submitted(request_id: RequestId) -> Self {
        Self {
            request_id,
            phase: MutationPhase::Submitted,
            polls: 0,
            operation_id: None,
            error: None,
            result: Value::Object(Default::default()),
        }
    }

    /// Records a poll issued against the original request id.
    pub fn polled(&mut self) -> Result<(), RuntimeError> {
        if self.phase.terminal() {
            return Ok(());
        }
        self.polls = self.polls.saturating_add(1);
        Ok(())
    }

    /// Marks the submission outcome unknown without permitting resubmission.
    pub fn uncertain(&mut self) {
        if !self.phase.terminal() {
            self.phase = MutationPhase::Uncertain;
        }
    }

    /// Applies a receipt or refusal; terminal states absorb late replies.
    pub fn observe(&mut self, reply: Reply) -> Result<(), RuntimeError> {
        if self.phase.terminal() {
            return Ok(());
        }
        match reply {
            Reply::Receipt(receipt) => {
                if receipt.request_id != self.request_id {
                    return Err(RuntimeError::RequestMismatch);
                }
                if let (Some(previous), Some(current)) = (&self.operation_id, receipt.operation_id)
                {
                    if previous != &current.to_string() {
                        return Err(RuntimeError::OperationMismatch);
                    }
                }
                self.operation_id = receipt.operation_id.map(|value| value.to_string());
                self.result = receipt.result;
                self.phase = match receipt.status {
                    ReceiptStatus::Accepted => MutationPhase::Accepted,
                    ReceiptStatus::Succeeded => MutationPhase::Succeeded,
                    ReceiptStatus::Failed | ReceiptStatus::Superseded => MutationPhase::Failed,
                };
            }
            Reply::Error { error, .. } => {
                self.error = Some(error);
                self.phase = MutationPhase::Refused;
            }
            Reply::Read(_) => self.uncertain(),
        }
        Ok(())
    }

    /// Returns the command the caller may issue next.
    pub const fn next_action(&self) -> NextAction {
        if self.phase.terminal() {
            NextAction::Done
        } else {
            NextAction::Poll
        }
    }
}

/// Runtime work required after observing a tracker.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NextAction {
    Poll,
    Done,
}

/// Runtime state machine failures.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RuntimeError {
    #[error("receipt request id does not match the tracker")]
    RequestMismatch,
    #[error("receipt operation id changed")]
    OperationMismatch,
    #[error("invalid snapshot")]
    InvalidSnapshot,
    #[error("snapshot is too large")]
    SnapshotTooLarge,
    #[error("snapshot belongs to another deployment")]
    SnapshotDeploymentMismatch,
    #[error("invalid push registration")]
    InvalidPushRegistration,
    #[error("invalid push poke")]
    InvalidPoke,
    #[error("command is invalid or exceeds bounds")]
    InvalidCommand,
    #[error("mutation was already submitted")]
    AlreadySubmitted,
    #[error("mutation has not been submitted")]
    NotSubmitted,
    #[error("session backend failed")]
    Backend,
    #[error("storage backend failed")]
    Storage,
}

/// Availability of the platform authentication mechanism used by app lock.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockAvailability {
    Unknown,
    Available,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockDelay {
    Immediate,
    OneMinute,
    FiveMinutes,
}
impl LockDelay {
    pub const fn millis(self) -> u64 {
        match self {
            Self::Immediate => 0,
            Self::OneMinute => 60_000,
            Self::FiveMinutes => 300_000,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum LockPhase {
    Unlocked,
    Locked,
    Authenticating,
}

/// Events supplied by a native lifecycle/authentication adapter.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LockEvent {
    Availability(LockAvailability),
    Enable,
    Disable,
    Delay(LockDelay),
    Backgrounded(u64),
    Foregrounded(u64),
    UnlockRequested,
    UnlockFinished { attempt: u32, success: bool },
}

/// Pure, fail-closed app lock state machine. It contains no platform handles.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AppLock {
    pub enabled: bool,
    pub delay: LockDelay,
    pub availability: LockAvailability,
    pub phase: LockPhase,
    pub attempt: u32,
    pub backgrounded_at: Option<u64>,
    pub last_failed: bool,
}
impl AppLock {
    pub const fn start(enabled: bool, delay: LockDelay) -> Self {
        Self {
            enabled,
            delay,
            availability: LockAvailability::Unknown,
            phase: if enabled {
                LockPhase::Locked
            } else {
                LockPhase::Unlocked
            },
            attempt: 0,
            backgrounded_at: None,
            last_failed: false,
        }
    }
    pub const fn effective(self) -> bool {
        self.enabled && !matches!(self.availability, LockAvailability::Unavailable)
    }
    pub const fn obscured(self) -> bool {
        !matches!(self.phase, LockPhase::Unlocked)
    }
    /// Applies one event; stale authentication results never unlock content.
    pub fn apply(mut self, event: LockEvent) -> Self {
        match event {
            LockEvent::Availability(a) => {
                self.availability = a;
                if matches!(a, LockAvailability::Unavailable) {
                    self.phase = LockPhase::Unlocked;
                    self.last_failed = false;
                }
            }
            LockEvent::Enable
                if matches!(self.phase, LockPhase::Unlocked)
                    && matches!(self.availability, LockAvailability::Available) =>
            {
                self.enabled = true
            }
            LockEvent::Disable if matches!(self.phase, LockPhase::Unlocked) => self.enabled = false,
            LockEvent::Delay(d) if matches!(self.phase, LockPhase::Unlocked) => self.delay = d,
            LockEvent::Backgrounded(at) if !matches!(self.phase, LockPhase::Authenticating) => {
                self.backgrounded_at = Some(at);
                if self.effective() && matches!(self.delay, LockDelay::Immediate) {
                    self.phase = LockPhase::Locked;
                }
            }
            LockEvent::Foregrounded(at) if !matches!(self.phase, LockPhase::Authenticating) => {
                if self.effective()
                    && self.backgrounded_at.is_some_and(|from| {
                        at < from || at.saturating_sub(from) >= self.delay.millis()
                    })
                {
                    self.phase = LockPhase::Locked;
                }
                self.backgrounded_at = None;
            }
            LockEvent::UnlockRequested
                if matches!(self.phase, LockPhase::Locked)
                    && matches!(self.availability, LockAvailability::Available) =>
            {
                self.phase = LockPhase::Authenticating;
                self.attempt = self.attempt.saturating_add(1);
            }
            LockEvent::UnlockFinished { attempt, success }
                if attempt == self.attempt && matches!(self.phase, LockPhase::Authenticating) =>
            {
                if success {
                    self.phase = LockPhase::Unlocked;
                    self.backgrounded_at = None;
                    self.last_failed = false;
                } else {
                    self.phase = LockPhase::Locked;
                    self.last_failed = true;
                }
            }
            _ => {}
        }
        self
    }
}

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

/// Platform custody selected by the native wrapper; private key bytes never
/// cross this boundary. The associated handle is intentionally opaque.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyCustody {
    SecureEnclave,
    StrongBox,
    PlatformKeystore,
    OwnerOnlyFile,
}
pub trait DeviceKeyProvider {
    type Handle;
    fn custody(&self) -> KeyCustody;
    fn key_for(&self, deployment: &str) -> Result<Self::Handle, RuntimeError>;
}

/// Maximum number of machines retained by an offline snapshot.
pub const MAX_SNAPSHOT_MACHINES: usize = 500;
/// Maximum encoded snapshot size accepted from disk.
pub const MAX_SNAPSHOT_BYTES: usize = 1 << 20;

/// A closed, privacy-preserving machine representation suitable for caching.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotMachine {
    pub id: String,
    pub name: String,
    pub desired_state: String,
    pub observed_state: Option<String>,
    pub pinned: bool,
    pub owner: Option<String>,
    pub read: bool,
    pub write: bool,
    pub manage: bool,
}

/// Mutations the native clients may present for a cached machine.
///
/// This keeps action visibility identical across Swift, Kotlin, GTK and WinUI;
/// clients must not reimplement permission or state rules in each UI toolkit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum MachineAction {
    Start,
    Stop,
    Pause,
    Resume,
    Pin,
    Unpin,
    Delete,
}

impl SnapshotMachine {
    /// @cc [owner:ghuntley,label:protocol;security] mila-runtime-machine-actions
    /// Returns actions in the stable order used by the native clients.
    pub fn available_actions(&self) -> Vec<MachineAction> {
        let mut actions = Vec::with_capacity(3);
        if self.write {
            match self.observed_state.as_deref() {
                Some("stopped") => actions.push(MachineAction::Start),
                Some("paused") => actions.push(MachineAction::Resume),
                Some("running") => {
                    actions.push(MachineAction::Pause);
                    actions.push(MachineAction::Stop);
                }
                _ => {}
            }
        }
        actions.push(if self.pinned {
            MachineAction::Unpin
        } else {
            MachineAction::Pin
        });
        if self.manage && self.owner.is_some() && !self.pinned {
            actions.push(MachineAction::Delete);
        }
        actions
    }
}

#[cfg(test)]
mod machine_action_tests {
    use super::{MachineAction, SnapshotMachine};

    fn machine(
        state: Option<&str>,
        pinned: bool,
        owner: bool,
        write: bool,
        manage: bool,
    ) -> SnapshotMachine {
        SnapshotMachine {
            id: "id".into(),
            name: "name".into(),
            desired_state: "running".into(),
            observed_state: state.map(str::to_owned),
            pinned,
            owner: owner.then(|| "me".into()),
            read: true,
            write,
            manage,
        }
    }

    #[test]
    fn action_visibility_matches_client_policy() {
        assert_eq!(
            machine(Some("running"), false, true, true, true).available_actions(),
            vec![
                MachineAction::Pause,
                MachineAction::Stop,
                MachineAction::Pin,
                MachineAction::Delete
            ]
        );
        assert_eq!(
            machine(Some("stopped"), true, true, true, true).available_actions(),
            vec![MachineAction::Start, MachineAction::Unpin]
        );
        assert_eq!(
            machine(Some("paused"), false, false, false, true).available_actions(),
            vec![MachineAction::Pin]
        );
    }

    #[test]
    fn unknown_state_fails_closed_to_pin_only() {
        assert_eq!(
            machine(Some("migrating"), false, true, true, true).available_actions(),
            vec![MachineAction::Pin, MachineAction::Delete]
        );
    }
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

/// Push registration data kept in memory while a platform token is exchanged.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PushRegistration {
    pub platform: mila_model::DevicePlatform,
    pub push_key: String,
    pub key_id: String,
    pub expires_at: u64,
}

/// Push provider accepted by Susan's closed registration API.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PushProvider {
    Apns,
    Fcm,
    Wns,
}

impl PushProvider {
    pub const fn origin(self) -> &'static str {
        match self {
            Self::Apns => "https://api.push.apple.com",
            Self::Fcm => "https://fcm.googleapis.com",
            Self::Wns => "https://notify.windows.com",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PushEnvironment {
    Production,
    Development,
}

/// Secret provider token. Formatting deliberately never exposes its contents.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderToken(String);
impl std::fmt::Debug for ProviderToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ProviderToken(REDACTED)")
    }
}
impl ProviderToken {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Closed request sent from a native client to Susan for key issuance.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRegistrationRequest {
    pub provider: PushProvider,
    pub token: ProviderToken,
    pub app_id: String,
    pub environment: PushEnvironment,
    pub deployment: String,
    /// WNS channel URI; absent for APNs and FCM, whose origins are fixed.
    pub endpoint: Option<String>,
}

impl PushRegistrationRequest {
    pub fn new(
        provider: PushProvider,
        token: String,
        app_id: String,
        environment: PushEnvironment,
        deployment: String,
        endpoint: Option<String>,
    ) -> Result<Self, RuntimeError> {
        if app_id.is_empty()
            || app_id.len() > 256
            || !app_id.bytes().all(|b| b.is_ascii_graphic() && b != b'"')
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        validate_host(&deployment).map_err(|_| RuntimeError::InvalidPushRegistration)?;
        if provider != PushProvider::Apns && environment == PushEnvironment::Development {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        if !provider_token_valid(provider, &token) {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        match provider {
            PushProvider::Wns => {
                let value = endpoint
                    .as_deref()
                    .ok_or(RuntimeError::InvalidPushRegistration)?;
                if value != token || !wns_channel_valid(value) {
                    return Err(RuntimeError::InvalidPushRegistration);
                }
            }
            PushProvider::Apns | PushProvider::Fcm if endpoint.is_some() => {
                return Err(RuntimeError::InvalidPushRegistration)
            }
            _ => {}
        }
        Ok(Self {
            provider,
            token: ProviderToken(token),
            app_id,
            environment,
            deployment,
            endpoint,
        })
    }
}

impl PushRegistrationRequest {
    /// @cc [owner:ghuntley,label:protocol;privacy] mila-susan-key-request-body
    /// The Susan key-issuance body MUST contain exactly Susan's closed members
    /// `provider`, `token`, `app_id`, `environment` and `deployment`; the WNS
    /// `endpoint` duplicate is a client-side check and MUST NOT be sent.
    pub fn susan_body(&self) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "provider": self.provider,
            "token": self.token.as_str(),
            "app_id": self.app_id,
            "environment": self.environment,
            "deployment": self.deployment,
        }))
        .unwrap_or_default()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRegistrationReply {
    pub push_key: String,
    pub key_id: String,
    pub expires_at: u64,
}

impl PushRegistrationReply {
    pub fn new(
        push_key: String,
        key_id: String,
        expires_at: u64,
        now: u64,
    ) -> Result<Self, RuntimeError> {
        if !(16..=700).contains(&push_key.len())
            || !base64url(&push_key)
            || key_id.is_empty()
            || key_id.len() > 128
            || expires_at <= now
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Ok(Self {
            push_key,
            key_id,
            expires_at,
        })
    }
}

impl PushRegistrationReply {
    /// Decodes Susan's `201` key-issuance reply
    /// `{"push_key","key_id","expires_at"}` where `expires_at` is an ISO-8601
    /// UTC timestamp. Unknown members, non-UTC offsets and expired keys refuse.
    pub fn decode_susan(bytes: &[u8], now: u64) -> Result<Self, RuntimeError> {
        if bytes.len() > 4096 {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            push_key: String,
            key_id: String,
            expires_at: String,
        }
        let wire: Wire =
            serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidPushRegistration)?;
        let expires_at =
            parse_utc_timestamp(&wire.expires_at).ok_or(RuntimeError::InvalidPushRegistration)?;
        if wire.key_id.chars().any(char::is_control) {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Self::new(wire.push_key, wire.key_id, expires_at, now)
    }
}

/// Parses `YYYY-MM-DDTHH:MM:SS[.fraction]Z` into Unix seconds.
fn parse_utc_timestamp(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if !value.is_ascii() || bytes.len() < 20 || bytes.len() > 32 || *bytes.last()? != b'Z' {
        return None;
    }
    let digits = |range: std::ops::Range<usize>| -> Option<u64> {
        let part = value.get(range)?;
        if part.bytes().all(|b| b.is_ascii_digit()) {
            part.parse().ok()
        } else {
            None
        }
    };
    if bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    let fraction = &value[19..value.len() - 1];
    if !(fraction.is_empty()
        || (fraction.len() >= 2
            && fraction.starts_with('.')
            && fraction[1..].bytes().all(|b| b.is_ascii_digit())))
    {
        return None;
    }
    let (year, month, day) = (digits(0..4)?, digits(5..7)?, digits(8..10)?);
    let (hour, minute, second) = (digits(11..13)?, digits(14..16)?, digits(17..19)?);
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if !(1970..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || day == 0
        || day > month_days[(month - 1) as usize]
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    // Days from civil (Howard Hinnant), restricted to post-epoch dates.
    let (y, m) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3600 + minute * 60 + second)
}

fn provider_token_valid(provider: PushProvider, token: &str) -> bool {
    match provider {
        PushProvider::Apns => {
            (32..=200).contains(&token.len())
                && token
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        }
        PushProvider::Fcm => {
            (32..=512).contains(&token.len())
                && token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_:-".contains(&b))
        }
        PushProvider::Wns => wns_channel_valid(token),
    }
}

/// @cc [owner:ghuntley,label:security;privacy] mila-wns-channel-shape
/// A WNS channel MUST match Susan's `susan-wns-channel-shape`: HTTPS with the
/// implicit default port, a lower-case DNS host under `.notify.windows.com`, a
/// non-empty path, no userinfo or fragment, no backslash, space or `%00`, and
/// at most 1024 bytes. Percent escapes in the channel token are permitted.
fn wns_channel_valid(value: &str) -> bool {
    if value.len() > 1024
        || !value.starts_with("https://")
        || value.contains([' ', '\\', '#', '@'])
        || value.contains("%00")
        || value.bytes().any(|b| b.is_ascii_control() || !b.is_ascii())
    {
        return false;
    }
    let Some((host, path)) = value[8..].split_once('/') else {
        return false;
    };
    let Some(prefix) = host.strip_suffix(".notify.windows.com") else {
        return false;
    };
    !path.is_empty()
        && !prefix.is_empty()
        && host.split('.').all(|label| {
            (1..=63).contains(&label.len())
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}
impl PushRegistration {
    pub fn new(
        platform: mila_model::DevicePlatform,
        push_key: String,
        key_id: String,
        expires_at: u64,
        now: u64,
    ) -> Result<Self, RuntimeError> {
        if !(16..=700).contains(&push_key.len())
            || !push_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || key_id.is_empty()
            || key_id.len() > 128
            || expires_at <= now
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Ok(Self {
            platform,
            push_key,
            key_id,
            expires_at,
        })
    }
}

/// Metadata for a Susan poke; ciphertext remains opaque to the core.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PokeEnvelope {
    pub deployment: String,
    pub push_key: String,
    pub delivery_id: String,
    pub collapse_id: String,
    pub kind: String,
    pub issued_at: u64,
    pub nonce: String,
    pub ciphertext: String,
}
impl PokeEnvelope {
    pub fn validate(&self, now: u64) -> Result<(), RuntimeError> {
        validate_host(&self.deployment)?;
        if self.push_key.is_empty()
            || self.push_key.len() > 700
            || !base64url(&self.push_key)
            || self.delivery_id.is_empty()
            || self.delivery_id.len() > 128
            || self.collapse_id.is_empty()
            || self.collapse_id.len() > 128
            || self.kind.is_empty()
            || self.kind.len() > 64
            || self.nonce.is_empty()
            || self.nonce.len() > 128
            || self.ciphertext.is_empty()
            || self.ciphertext.len() > 4096
            || !base64url(&self.ciphertext)
            || self.issued_at > now.saturating_add(300)
            || now.saturating_sub(self.issued_at) > 86_400
        {
            return Err(RuntimeError::InvalidPoke);
        }
        Ok(())
    }
}
fn base64url(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

// (Variants are kept stable for FFI consumers.)

/// A transport-independent operation submitted through a single mutation identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MutationRequest {
    pub request_id: RequestId,
    pub command: String,
}

/// I/O supplied by each platform adapter. The core controls retries and polling.
pub trait SessionBackend {
    type Error;
    fn submit(&mut self, request: &MutationRequest) -> Result<Reply, Self::Error>;
    fn poll(&mut self, request_id: &RequestId) -> Result<Reply, Self::Error>;
}

/// Owns one mutation tracker and prevents accidental duplicate submissions.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionRuntime {
    tracker: MutationTracker,
    command: String,
    submitted: bool,
}
impl SessionRuntime {
    pub fn new(request_id: RequestId, command: String) -> Result<Self, RuntimeError> {
        if command.is_empty() || command.len() > mila_protocol::MAX_COMMAND_BYTES {
            return Err(RuntimeError::InvalidCommand);
        }
        Ok(Self {
            tracker: MutationTracker::submitted(request_id),
            command,
            submitted: false,
        })
    }
    pub fn tracker(&self) -> &MutationTracker {
        &self.tracker
    }
    pub fn submit<B: SessionBackend>(&mut self, backend: &mut B) -> Result<(), RuntimeError> {
        if self.submitted {
            return Err(RuntimeError::AlreadySubmitted);
        }
        self.submitted = true;
        let request = MutationRequest {
            request_id: self.tracker.request_id.clone(),
            command: self.command.clone(),
        };
        let reply = backend
            .submit(&request)
            .map_err(|_| RuntimeError::Backend)?;
        self.tracker.observe(reply)
    }
    pub fn poll<B: SessionBackend>(&mut self, backend: &mut B) -> Result<NextAction, RuntimeError> {
        if !self.submitted {
            return Err(RuntimeError::NotSubmitted);
        }
        if self.tracker.next_action() == NextAction::Done {
            return Ok(NextAction::Done);
        }
        self.tracker.polled()?;
        let reply = backend
            .poll(&self.tracker.request_id)
            .map_err(|_| RuntimeError::Backend)?;
        self.tracker.observe(reply)?;
        Ok(self.tracker.next_action())
    }
}
