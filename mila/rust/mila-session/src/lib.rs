//! Stateful application I/O composing the pure runtime and certificate-pinned SSH.
//! Native adapters own the async executor and device signer; UI receives projections.

use mila_model::Identifier;
use mila_runtime::{MachineSnapshot, SnapshotMachine, MAX_SNAPSHOT_BYTES, MAX_SNAPSHOT_MACHINES};
use mila_transport::{
    ssh::{DeviceSigner, PtySession, SshError, SshSession},
    TrustDocument,
};
use serde::Deserialize;
use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

/// Errors deliberately exclude server bodies, command text and credentials.
#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("transport failed")]
    Transport(#[from] SshError),
    #[error("server refused the listing")]
    Refused,
    #[error("invalid machine listing")]
    InvalidListing,
    #[error("listing exceeds bounds")]
    Bounds,
    #[error("pagination cursor repeated")]
    RepeatedCursor,
    #[error("no listing has been loaded")]
    NotLoaded,
    #[error("mutation was refused")]
    MutationRefused,
    #[error("invalid thread action")]
    InvalidThreadAction,
}

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

/// One deployment connection and its last successful listing. No automatic retries.
pub struct ApplicationSession {
    ssh: SshSession,
    host: String,
    port: u16,
    listing: Option<MachineListing>,
    seen_cursors: HashSet<Identifier>,
}

/// @cc [owner:ghuntley,label:protocol;security] mila-session-ssh-key-envelope
/// `ssh-key list --json` output MUST be either Porsche's succeeded envelope
/// (`{"version":1,"status":"succeeded","result":{"keys":[...]}}`) or a bare
/// `{"keys":[...]}`; every key needs a canonical id and bounded printable
/// fingerprint and algorithm. Any other status is refused.
fn validate_ssh_keys(bytes: &[u8]) -> Result<(), SessionError> {
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| SessionError::Refused)?;
    let body = match value.get("status") {
        None => &value,
        Some(status)
            if status.as_str() == Some("succeeded")
                && value.get("version").and_then(serde_json::Value::as_u64) == Some(1) =>
        {
            value.get("result").ok_or(SessionError::Refused)?
        }
        Some(_) => return Err(SessionError::Refused),
    };
    let keys = body
        .get("keys")
        .and_then(serde_json::Value::as_array)
        .ok_or(SessionError::Refused)?;
    if keys.len() > 256 {
        return Err(SessionError::Bounds);
    }
    for key in keys {
        let id = key
            .get("id")
            .and_then(serde_json::Value::as_str)
            .ok_or(SessionError::Refused)?;
        Identifier::parse(id).map_err(|_| SessionError::Refused)?;
        for field in ["fingerprint", "algorithm"] {
            let text = key
                .get(field)
                .and_then(serde_json::Value::as_str)
                .ok_or(SessionError::Refused)?;
            if text.is_empty() || text.len() > 256 || text.bytes().any(|b| b.is_ascii_control()) {
                return Err(SessionError::Refused);
            }
        }
    }
    Ok(())
}

impl ApplicationSession {
    /// Opens a bounded interactive terminal on this authenticated deployment.
    /// The returned channel remains owned by the caller while the underlying
    /// certificate-pinned session is borrowed by the transport.
    pub async fn open_pty(&self, columns: u32, rows: u32) -> Result<PtySession, SessionError> {
        Ok(PtySession::open(&self.ssh, columns, rows).await?)
    }
    /// Execute one closed-vocabulary thread operation. Response JSON is bounded and
    /// parsed before crossing a native boundary; stdin is accepted only for commands
    /// whose protocol grammar requires it.
    pub async fn thread_action(
        &mut self,
        thread: Option<&str>,
        command: &str,
        secondary: Option<&str>,
        input: Option<&str>,
        request_id: Option<&str>,
    ) -> Result<Vec<u8>, SessionError> {
        let thread_id = thread
            .map(|v| Identifier::parse(v).map_err(|_| SessionError::InvalidThreadAction))
            .transpose()?;
        let arg = secondary
            .map(|v| Identifier::parse(v).map_err(|_| SessionError::InvalidThreadAction))
            .transpose()?;
        let (line, stdin) = match command {
            "thread ls" if thread_id.is_none() && secondary.is_none() && input.is_none() => {
                ("thread ls --json".to_string(), Vec::new())
            }
            "thread show" | "thread turns"
                if thread_id.is_some() && secondary.is_none() && input.is_none() =>
            {
                (
                    format!("{command} {} --json", thread_id.as_ref().expect("checked")),
                    Vec::new(),
                )
            }
            "thread prompt" if thread_id.is_some() && secondary.is_none() => (
                format!(
                    "thread prompt {} - --json",
                    thread_id.as_ref().expect("checked")
                ),
                input
                    .ok_or(SessionError::InvalidThreadAction)?
                    .as_bytes()
                    .to_vec(),
            ),
            "thread answer" if thread_id.is_some() && arg.is_some() => (
                format!(
                    "thread answer {} {} - --json",
                    thread_id.as_ref().expect("checked"),
                    arg.as_ref().expect("checked")
                ),
                input
                    .ok_or(SessionError::InvalidThreadAction)?
                    .as_bytes()
                    .to_vec(),
            ),
            "thread plan approve" if thread_id.is_some() && arg.is_some() && input.is_none() => (
                format!(
                    "thread plan approve {} {} --json",
                    thread_id.as_ref().expect("checked"),
                    arg.as_ref().expect("checked")
                ),
                Vec::new(),
            ),
            "thread plan revise" if thread_id.is_some() && arg.is_some() => (
                format!(
                    "thread plan revise {} {} - --json",
                    thread_id.as_ref().expect("checked"),
                    arg.as_ref().expect("checked")
                ),
                input
                    .ok_or(SessionError::InvalidThreadAction)?
                    .as_bytes()
                    .to_vec(),
            ),
            _ => return Err(SessionError::InvalidThreadAction),
        };
        if stdin.is_empty()
            && matches!(
                command,
                "thread prompt" | "thread answer" | "thread plan revise"
            )
        {
            return Err(SessionError::InvalidThreadAction);
        }
        if stdin.len() > 64 * 1024 || stdin.contains(&0) {
            return Err(SessionError::Bounds);
        }
        let line = mila_protocol::Command::parse(&line)
            .and_then(|c| c.format())
            .map_err(|_| SessionError::InvalidThreadAction)?;
        let line = if let Some(request) = request_id {
            let request =
                mila_model::RequestId::parse(request).map_err(|_| SessionError::MutationRefused)?;
            format!("{line} --request-id={request}")
        } else {
            line
        };
        let output = self.ssh.exec(&line, &stdin).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::MutationRefused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }
    /// Execute one authenticated machine mutation on this connection. The command is
    /// constructed from closed vocabulary values and a validated request id; callers
    /// cannot inject shell text or reuse an untyped operation.
    pub async fn machine_action(
        &mut self,
        machine: &str,
        action: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let action = match action {
            "start" | "stop" | "pause" | "resume" | "rm" => action,
            _ => return Err(SessionError::MutationRefused),
        };
        let line = format!("{action} {machine} --json --request-id={request_id}");
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute an authenticated machine creation with bounded resource values.
    pub async fn machine_create(
        &mut self,
        name: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        if name.is_empty()
            || name.len() > 128
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || !(1..=256).contains(&cpu)
            || !(256..=4_194_304).contains(&memory)
            || !(1..=500).contains(&disk)
        {
            return Err(SessionError::MutationRefused);
        }
        let line = format!("new --name={name} --cpu={cpu} --memory={memory} --disk={disk} --no-wait --json --request-id={request_id}");
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute an authenticated machine resize with bounded resource values.
    pub async fn machine_resize(
        &mut self,
        machine: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        if !(1..=256).contains(&cpu)
            || !(256..=4_194_304).contains(&memory)
            || !(1..=16_777_216).contains(&disk)
        {
            return Err(SessionError::MutationRefused);
        }
        let line = format!(
            "resize {machine} --cpu={cpu} --memory={memory} --disk={disk} --json --request-id={request_id}"
        );
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute authenticated approved-key listing and return bounded validated JSON.
    pub async fn ssh_keys(&mut self) -> Result<Vec<u8>, SessionError> {
        let output = self.ssh.exec("ssh-key list --json", &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::Refused);
        }
        validate_ssh_keys(&output.stdout)?;
        Ok(output.stdout)
    }

    /// Execute the bounded identity check used by browser approval. Porsche returns
    /// an `approval_required` JSON envelope with a link while the device key is
    /// pending; callers must be able to inspect that envelope even on a non-zero
    /// command exit status.
    pub async fn whoami(&self) -> Result<Vec<u8>, SessionError> {
        let output = self.ssh.exec("whoami --json", &[]).await?;
        if output.stdout.len() > 64 * 1024 {
            return Err(SessionError::Bounds);
        }
        let value: serde_json::Value =
            serde_json::from_slice(&output.stdout).map_err(|_| SessionError::Refused)?;
        if !value.is_object()
            || value.get("version").and_then(serde_json::Value::as_u64) != Some(1)
            || value
                .get("status")
                .and_then(serde_json::Value::as_str)
                .is_none()
        {
            return Err(SessionError::Refused);
        }
        Ok(output.stdout)
    }

    /// Revoke one opaque approved-key identity with an at-most-once request id.
    pub async fn ssh_key_revoke(
        &mut self,
        key_id: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let key_id = Identifier::parse(key_id).map_err(|_| SessionError::MutationRefused)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .ssh
            .exec(
                &format!("ssh-key remove --json --request-id={request_id} {key_id}"),
                &[],
            )
            .await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute authenticated web endpoint inspection and return bounded JSON.
    pub async fn web_show(&mut self, machine: &str) -> Result<Vec<u8>, SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let line = format!("web show {machine} --json");
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            Err(SessionError::MutationRefused)
        } else {
            serde_json::from_slice::<serde_json::Value>(&output.stdout)
                .map_err(|_| SessionError::Refused)?;
            Ok(output.stdout)
        }
    }

    /// Execute authenticated web endpoint mutation with optimistic revision.
    pub async fn web_set(
        &mut self,
        machine: &str,
        port: u16,
        public: bool,
        revision: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let visibility = if public { "--public" } else { "--private" };
        let line = format!("web set {machine} --json --port={port} {visibility} --revision={revision} --request-id={request_id}");
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Read the caller's push notification devices through Porsche.
    pub async fn device_ls(&mut self) -> Result<Vec<u8>, SessionError> {
        let output = self.ssh.exec("device ls --json", &[]).await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            Err(SessionError::MutationRefused)
        } else {
            serde_json::from_slice::<serde_json::Value>(&output.stdout)
                .map_err(|_| SessionError::Refused)?;
            Ok(output.stdout)
        }
    }

    /// @cc [owner:ghuntley,label:security;privacy] mila-session-device-register
    /// The Susan push key MUST travel only on stdin, never on the command line;
    /// the platform, X25519 public key and optional label MUST satisfy the shared
    /// command grammar before any channel is opened. The bounded JSON reply is
    /// returned only on a zero exit status. Registers this device for push
    /// notifications through Porsche.
    pub async fn device_register(
        &mut self,
        platform: mila_model::DevicePlatform,
        push_key: &str,
        enc_pubkey: &str,
        label: Option<&str>,
    ) -> Result<Vec<u8>, SessionError> {
        if !(16..=700).contains(&push_key.len())
            || !push_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(SessionError::MutationRefused);
        }
        let platform = platform.as_str();
        let mut options = std::collections::BTreeMap::new();
        options.insert(
            "platform".to_owned(),
            mila_protocol::OptionValue::String(platform.into()),
        );
        options.insert(
            "push-key".to_owned(),
            mila_protocol::OptionValue::String("-".into()),
        );
        options.insert(
            "enc-pubkey".to_owned(),
            mila_protocol::OptionValue::String(enc_pubkey.into()),
        );
        if let Some(label) = label {
            options.insert(
                "label".to_owned(),
                mila_protocol::OptionValue::String(label.into()),
            );
        }
        options.insert("json".to_owned(), mila_protocol::OptionValue::Bool(true));
        let line = mila_protocol::Command {
            command: "device register".into(),
            arguments: Vec::new(),
            options,
        }
        .format()
        .map_err(|_| SessionError::MutationRefused)?;
        let output = self.ssh.exec(&line, push_key.as_bytes()).await?;
        if output.exit_status != 0 || output.stdout.len() > 64 * 1024 {
            return Err(SessionError::MutationRefused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }

    /// Revoke one caller-owned push notification device.
    pub async fn device_rm(&mut self, device_id: &str) -> Result<(), SessionError> {
        let device_id = Identifier::parse(device_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .ssh
            .exec(&format!("device rm {device_id} --json"), &[])
            .await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Enable or disable one caller-owned push notification device.
    pub async fn device_prefs(
        &mut self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), SessionError> {
        let device_id = Identifier::parse(device_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .ssh
            .exec(
                &format!("device prefs {device_id} --enabled {enabled} --json"),
                &[],
            )
            .await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }

    /// Execute an authenticated machine sharing mutation. The command is parsed by
    /// the shared protocol grammar before it is sent, and request IDs provide the
    /// same at-most-once boundary as lifecycle mutations.
    pub async fn share_mutation(
        &mut self,
        machine: &str,
        email: &str,
        role: Option<&str>,
        add: bool,
        request_id: &str,
    ) -> Result<(), SessionError> {
        let machine = Identifier::parse(machine).map_err(|_| SessionError::InvalidListing)?;
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        if email.is_empty()
            || email.len() > 320
            || email
                .bytes()
                .any(|byte| byte.is_ascii_whitespace() || byte == 0)
        {
            return Err(SessionError::MutationRefused);
        }
        let line = if add {
            let role = role
                .filter(|value| matches!(*value, "viewer" | "operator" | "manager"))
                .ok_or(SessionError::MutationRefused)?;
            format!("share add {machine} {email} {role} --json --request-id={request_id}")
        } else {
            if role.is_some() {
                return Err(SessionError::MutationRefused);
            }
            format!("share remove {machine} {email} --json --request-id={request_id}")
        };
        let line = mila_protocol::Command::parse(&line)
            .and_then(|command| command.format())
            .map_err(|_| SessionError::MutationRefused)?;
        let output = self.ssh.exec(&line, &[]).await?;
        if output.exit_status == 0 {
            Ok(())
        } else {
            Err(SessionError::MutationRefused)
        }
    }
    /// Connects only through the transport's pre-authentication certificate policy.
    pub async fn connect<S: DeviceSigner>(
        trust: TrustDocument,
        port: u16,
        public_key: &str,
        signer: S,
        timeout: Duration,
    ) -> Result<Self, SessionError> {
        let host = trust.management_host.clone();
        let ssh = SshSession::connect(trust, port, public_key, signer, timeout).await?;
        Ok(Self {
            ssh,
            host,
            port,
            listing: None,
            seen_cursors: HashSet::new(),
        })
    }

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
        let output = self.ssh.exec(&command, &[]).await?;
        if output.exit_status != 0 {
            return Err(SessionError::Refused);
        }
        decode_listing(&output.stdout)
    }

    pub async fn close(self) -> Result<(), SessionError> {
        Ok(self.ssh.close().await?)
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

#[cfg(test)]
mod ssh_key_envelope_tests {
    use super::validate_ssh_keys;

    const KEY: &str = r#"{"id":"11111111-1111-4111-8111-111111111111","label":"laptop","algorithm":"ecdsa-sha2-nistp256","fingerprint":"SHA256:abc","inserted_at":"2026-10-01T00:00:00Z"}"#;

    #[test]
    fn accepts_porsche_succeeded_envelope_and_bare_keys() {
        let wrapped =
            format!(r#"{{"version":1,"status":"succeeded","result":{{"keys":[{KEY}]}}}}"#);
        assert!(validate_ssh_keys(wrapped.as_bytes()).is_ok());
        let bare = format!(r#"{{"keys":[{KEY}]}}"#);
        assert!(validate_ssh_keys(bare.as_bytes()).is_ok());
        assert!(
            validate_ssh_keys(br#"{"version":1,"status":"succeeded","result":{"keys":[]}}"#)
                .is_ok()
        );
    }

    #[test]
    fn refuses_error_status_and_malformed_keys() {
        assert!(
            validate_ssh_keys(br#"{"version":1,"status":"error","error":"unauthorized"}"#).is_err()
        );
        assert!(
            validate_ssh_keys(br#"{"version":2,"status":"succeeded","result":{"keys":[]}}"#)
                .is_err()
        );
        assert!(validate_ssh_keys(br#"{"version":1,"status":"succeeded"}"#).is_err());
        let bad_id = r#"{"keys":[{"id":"NOT-A-UUID","algorithm":"a","fingerprint":"f"}]}"#;
        assert!(validate_ssh_keys(bad_id.as_bytes()).is_err());
        let control = "{\"keys\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"algorithm\":\"a\",\"fingerprint\":\"f\\u0001\"}]}";
        assert!(validate_ssh_keys(control.as_bytes()).is_err());
    }
}
