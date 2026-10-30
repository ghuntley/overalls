//! Typed in-process runtime boundary for the Linux presentation host.

use serde::Deserialize;
use std::ffi::{c_char, CString};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex,
};

/// A server-managed SSH key shown by the Linux settings UI. Private key
/// material never appears in this representation or crosses the boundary.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct SshKey {
    pub id: String,
    pub label: String,
    pub fingerprint: String,
    pub added_at: u64,
}

/// Session-fenced SSH-key projection. Late responses from a prior sign-in or
/// reconnect generation are discarded before reaching GTK.
#[derive(Default)]
pub struct SshKeyProjection {
    generation: u64,
    keys: Vec<SshKey>,
}

impl SshKeyProjection {
    pub fn begin_generation(&mut self) -> u64 {
        self.generation = self.generation.saturating_add(1);
        self.keys.clear();
        self.generation
    }

    pub fn refresh(&mut self, generation: u64, bytes: &[u8]) -> Result<(), RuntimeError> {
        if generation != self.generation {
            return Err(RuntimeError::Unavailable);
        }
        self.keys = decode_ssh_keys(bytes)?;
        Ok(())
    }

    pub fn keys(&self) -> &[SshKey] {
        &self.keys
    }
}

/// Decode a bounded `ssh-key ls --json` response. Unknown fields are ignored,
/// while missing fields and oversized lists fail closed before reaching GTK.
pub fn decode_ssh_keys(bytes: &[u8]) -> Result<Vec<SshKey>, RuntimeError> {
    if bytes.len() > 256 * 1024 {
        return Err(RuntimeError::InvalidInput);
    }
    #[derive(Deserialize)]
    struct Envelope {
        keys: Vec<SshKey>,
    }
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    let mut ids = std::collections::HashSet::with_capacity(envelope.keys.len());
    if envelope.keys.len() > 256
        || envelope.keys.iter().any(|key| {
            if !ids.insert(key.id.as_str()) {
                return true;
            }
            key.id.is_empty()
                || key.id.len() > 128
                || key.label.len() > 256
                || key.fingerprint.len() > 256
                || key.id.chars().any(char::is_control)
                || key.label.chars().any(char::is_control)
                || key
                    .fingerprint
                    .chars()
                    .any(|character| character.is_control() || character.is_whitespace())
        })
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(envelope.keys)
}

/// @cc [owner:ghuntley,label:protocol] linux-request-id-fresh
/// A generated request identifier MUST be `porsche-` followed by 32 lower-case
/// hexadecimal digits from the operating system CSPRNG; when the CSPRNG is
/// unavailable no identifier is produced rather than a predictable one.
pub fn new_request_id() -> Option<String> {
    use std::io::Read;
    let mut bytes = [0_u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut source| source.read_exact(&mut bytes))
        .ok()?;
    let mut id = String::with_capacity(40);
    id.push_str("porsche-");
    for byte in bytes {
        id.push_str(&format!("{byte:02x}"));
    }
    Some(id)
}

/// Format the only destructive SSH-key operation after validating its opaque
/// server key identifier. Request IDs are required for at-most-once mutation.
pub fn format_ssh_key_revoke(key_id: &str, request_id: &str) -> Result<String, RuntimeError> {
    if key_id.is_empty()
        || key_id.len() > 128
        || request_id.len() != 40
        || !request_id.starts_with("porsche-")
        || !request_id[8..].bytes().all(|byte| byte.is_ascii_hexdigit())
        || key_id
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(format!(
        "ssh-key remove --json --request-id={request_id} {key_id}"
    ))
}

/// A bounded machine sharing grant. User identity and role are server metadata;
/// no credentials cross the native presentation boundary.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ShareGrant {
    pub id: String,
    pub user_id: String,
    pub email: String,
    pub role: String,
}

/// Decode a bounded `share show --json` response before it reaches GTK.
pub fn decode_share_listing(bytes: &[u8]) -> Result<(String, Vec<ShareGrant>), RuntimeError> {
    if bytes.len() > 256 * 1024 {
        return Err(RuntimeError::InvalidInput);
    }
    #[derive(Deserialize)]
    struct Owner {
        email: String,
    }
    #[derive(Deserialize)]
    struct Envelope {
        owner: Owner,
        items: Vec<ShareGrant>,
    }
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    let mut grant_ids = std::collections::HashSet::with_capacity(envelope.items.len());
    if envelope.owner.email.len() > 320
        || !valid_email(&envelope.owner.email)
        || envelope.items.len() > 512
        || envelope.items.iter().any(|grant| {
            grant.id.is_empty()
                || grant.id.len() > 128
                || !valid_share_text(&grant.id, 128)
                || grant.user_id.is_empty()
                || grant.user_id.len() > 128
                || !valid_share_text(&grant.user_id, 128)
                || !valid_email(&grant.email)
                || grant.role.len() > 32
                || !matches!(grant.role.as_str(), "viewer" | "operator" | "manager")
                || !grant_ids.insert(grant.id.clone())
        })
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok((envelope.owner.email, envelope.items))
}

fn valid_email(email: &str) -> bool {
    email.len() <= 320
        && email.len() >= 3
        && email.contains('@')
        && !email.bytes().any(|b| b.is_ascii_whitespace() || b == 0)
}

fn valid_share_text(value: &str, max_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= max_bytes
        && !value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
}

/// Format a sharing mutation through the shared Porsche command grammar.
pub fn format_share_command(
    operation: &str,
    machine_id: &str,
    email: &str,
    role: Option<&str>,
    request_id: &str,
) -> Result<String, RuntimeError> {
    if !matches!(operation, "add" | "remove")
        || machine_id.is_empty()
        || machine_id.len() > 128
        || machine_id
            .bytes()
            .any(|b| b.is_ascii_whitespace() || b == 0)
        || !valid_email(email)
        || request_id.len() != 40
        || !request_id.starts_with("porsche-")
        || !request_id[8..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(RuntimeError::InvalidInput);
    }
    let mut line = format!("share {operation} {machine_id} {email}");
    if operation == "add" {
        let role = role
            .filter(|value| matches!(*value, "viewer" | "operator" | "manager"))
            .ok_or(RuntimeError::InvalidInput)?;
        line.push(' ');
        line.push_str(role);
    }
    line.push_str(" --json --request-id=");
    line.push_str(request_id);
    Ok(line)
}

/// Canonicalizes an activation route through the same Rust FFI entry point used by
/// the other native clients. This keeps Linux from maintaining a second route grammar.
/// Resolves a desktop activation route against the active deployment and session.
/// Signed-out or cross-deployment routes are returned as typed decisions so GTK can
/// route them to sign-in without ever opening a target or invoking a command.
pub fn resolve_activation(
    value: &str,
    selected_authority: Option<&str>,
    authenticated: bool,
) -> Result<crate::route::NavigationDecision, RuntimeError> {
    let route =
        crate::route::ActivationRoute::parse(value).map_err(|_| RuntimeError::InvalidInput)?;
    Ok(route.navigation(selected_authority, authenticated))
}

pub fn canonical_route(value: &str) -> Result<String, RuntimeError> {
    let input = CString::new(value).map_err(|_| RuntimeError::InvalidInput)?;
    let mut bytes = vec![0_u8; 2048];
    let mut written = 0_usize;
    let output = mila_ffi::MilaRouteOutput {
        bytes: bytes.as_mut_ptr(),
        capacity: bytes.len(),
        written: &mut written,
    };
    // SAFETY: input is NUL terminated and output points to a writable buffer whose
    // capacity is declared to the bounded C ABI for the duration of this call.
    let status = unsafe { mila_ffi::mila_route_format(input.as_ptr() as *const c_char, output) };
    if status != mila_ffi::MilaFfiStatus::Ok {
        return Err(match status {
            mila_ffi::MilaFfiStatus::InvalidRoute => RuntimeError::InvalidInput,
            _ => RuntimeError::Unavailable,
        });
    }
    bytes.truncate(written);
    String::from_utf8(bytes).map_err(|_| RuntimeError::Unavailable)
}

/// Formats a catalogued machine action through the Rust command policy. The GTK
/// host receives a canonical command string only after Rust validates the
/// machine and request identifiers.
pub fn format_machine_action(
    action: &str,
    machine_id: &str,
    request_id: Option<&str>,
) -> Result<String, RuntimeError> {
    let action = CString::new(action).map_err(|_| RuntimeError::InvalidInput)?;
    let machine = CString::new(machine_id).map_err(|_| RuntimeError::InvalidInput)?;
    let request = request_id
        .map(CString::new)
        .transpose()
        .map_err(|_| RuntimeError::InvalidInput)?;
    let mut bytes = vec![0_u8; 1024];
    let mut written = 0_usize;
    let output = mila_ffi::MilaRouteOutput {
        bytes: bytes.as_mut_ptr(),
        capacity: bytes.len(),
        written: &mut written,
    };
    // SAFETY: all strings are NUL terminated and output is writable for the call.
    let status = unsafe {
        mila_ffi::mila_session_command_format(
            action.as_ptr(),
            machine.as_ptr(),
            request
                .as_ref()
                .map_or(std::ptr::null(), |value| value.as_ptr()),
            output,
        )
    };
    if status != mila_ffi::MilaFfiStatus::Ok {
        return Err(RuntimeError::InvalidInput);
    }
    bytes.truncate(written);
    String::from_utf8(bytes).map_err(|_| RuntimeError::Unavailable)
}

/// Formats bounded thread commands for the GTK session view.
pub fn format_thread_command(
    operation: &str,
    thread_id: Option<&str>,
) -> Result<String, RuntimeError> {
    if !matches!(operation, "ls" | "show") {
        return Err(RuntimeError::InvalidInput);
    }
    let mut line = format!("thread {operation} --json");
    if operation == "show" {
        let id = thread_id.ok_or(RuntimeError::InvalidInput)?;
        if id.is_empty() || id.len() > 128 || id.bytes().any(|b| b.is_ascii_whitespace() || b == 0)
        {
            return Err(RuntimeError::InvalidInput);
        }
        line.push(' ');
        line.push_str(id);
    }
    mila_protocol::Command::parse(&line)
        .and_then(|c| c.format())
        .map_err(|_| RuntimeError::InvalidInput)
}

/// A bounded, presentation-safe thread summary returned by the runtime.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ThreadSummary {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub state: String,
}

/// Decode `thread ls --json` without allowing unbounded server data into GTK.
pub fn decode_thread_list(bytes: &[u8]) -> Result<Vec<ThreadSummary>, RuntimeError> {
    if bytes.len() > 256 * 1024 {
        return Err(RuntimeError::InvalidInput);
    }
    #[derive(Deserialize)]
    struct Envelope {
        threads: Vec<ThreadSummary>,
    }
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    if envelope.threads.len() > 512
        || envelope.threads.iter().any(|thread| {
            thread.id.is_empty()
                || thread.id.len() > 128
                || thread.title.len() > 512
                || thread.state.len() > 64
        })
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(envelope.threads)
}

/// Render a bounded thread response for the GTK status view.  The native host
/// must never interpolate untrusted server bytes directly into a widget: parse
/// JSON first, then cap the compact representation before handing it to GTK.
pub fn format_thread_response(bytes: &[u8]) -> Result<String, RuntimeError> {
    if bytes.is_empty() || bytes.len() > 256 * 1024 {
        return Err(RuntimeError::InvalidInput);
    }
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    let compact = serde_json::to_string(&value).map_err(|_| RuntimeError::Unavailable)?;
    const MAX_DISPLAY: usize = 4096;
    if compact.len() > MAX_DISPLAY {
        let end = compact
            .char_indices()
            .take_while(|(index, _)| *index < MAX_DISPLAY.saturating_sub(1))
            .map(|(index, _)| index)
            .last()
            .unwrap_or(0);
        return Ok(format!("{}…", &compact[..end]));
    }
    Ok(compact)
}

/// Format the read-only turn history operation through the shared protocol parser.
pub fn format_thread_turns(thread_id: &str, after: Option<&str>) -> Result<String, RuntimeError> {
    if thread_id.is_empty()
        || thread_id.len() > 128
        || thread_id.bytes().any(|b| b.is_ascii_whitespace() || b == 0)
    {
        return Err(RuntimeError::InvalidInput);
    }
    let mut line = format!("thread turns {thread_id} --json");
    if let Some(cursor) = after {
        if cursor.is_empty()
            || cursor.len() > 128
            || cursor.bytes().any(|b| b.is_ascii_whitespace() || b == 0)
        {
            return Err(RuntimeError::InvalidInput);
        }
        line.push_str(" --after=");
        line.push_str(cursor);
    }
    mila_protocol::Command::parse(&line)
        .and_then(|c| c.format())
        .map_err(|_| RuntimeError::InvalidInput)
}

#[cfg(test)]
mod thread_tests {
    use super::*;
    #[test]
    fn turns_are_bounded_and_protocol_checked() {
        assert_eq!(
            format_thread_turns("00000000-0000-4000-8000-000000000001", None).unwrap(),
            "thread turns 00000000-0000-4000-8000-000000000001 --json"
        );
        assert!(format_thread_turns("bad id", None).is_err());
        assert!(format_thread_turns("thread-1", Some("bad cursor")).is_err());
    }
    #[test]
    fn list_decoder_rejects_oversized_items() {
        let data = br#"{"threads":[{"id":"t1","title":"A","state":"open"}]}"#;
        assert_eq!(decode_thread_list(data).unwrap()[0].id, "t1");
        let bad = format!(
            r#"{{"threads":[{{"id":"t1","title":"{}"}}]}}"#,
            "x".repeat(513)
        );
        assert!(decode_thread_list(bad.as_bytes()).is_err());
    }

    #[test]
    fn response_renderer_is_json_checked_and_bounded() {
        assert_eq!(
            format_thread_response(br#"{"ok":true}"#).unwrap(),
            r#"{"ok":true}"#
        );
        assert!(format_thread_response(b"not-json").is_err());
        let large = format!(r#"{{"value":"{}"}}"#, "x".repeat(8_000));
        let rendered = format_thread_response(large.as_bytes()).unwrap();
        assert!(rendered.len() <= 4_099);
        assert!(rendered.ends_with('…'));
    }
}

/// Formats web endpoint operations through Porsche's bounded command grammar.
/// The GTK host receives only a canonical command after Rust validates the
/// machine identifier, port, visibility and mutation request id.
pub fn format_web_command(
    operation: &str,
    machine_id: &str,
    port: Option<u16>,
    public: bool,
    request_id: Option<&str>,
) -> Result<String, RuntimeError> {
    if !matches!(operation, "show" | "set") || (public && operation == "show") {
        return Err(RuntimeError::InvalidInput);
    }
    let mut line = format!("web {operation} {machine_id} --json");
    if operation == "set" {
        let port = port.ok_or(RuntimeError::InvalidInput)?;
        if port == 0 {
            return Err(RuntimeError::InvalidInput);
        }
        line.push_str(&format!(" --port={port}"));
        line.push_str(if public { " --public" } else { " --private" });
        let request = request_id.ok_or(RuntimeError::InvalidInput)?;
        if request.len() != 40 || !request.starts_with("porsche-") {
            return Err(RuntimeError::InvalidInput);
        }
        line.push_str(&format!(" --request-id={request}"));
    }
    mila_protocol::Command::parse(&line)
        .and_then(|command| command.format())
        .map_err(|_| RuntimeError::InvalidInput)
}

/// A bounded authenticated web endpoint projection safe for GTK display.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct WebEndpoint {
    pub machine_id: String,
    pub label: String,
    pub port: u16,
    pub visibility: String,
    pub policy_revision: u64,
    pub url: Option<String>,
    pub route: String,
}

/// Decode and validate the authenticated `web show --json` result without
/// retaining the server envelope or accepting non-HTTPS browser destinations.
pub fn decode_web_endpoint(bytes: &[u8]) -> Result<WebEndpoint, RuntimeError> {
    if bytes.len() > 64 * 1024 {
        return Err(RuntimeError::InvalidInput);
    }
    let endpoint: WebEndpoint =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    let route = crate::route::ActivationRoute::parse(&endpoint.route).ok();
    let route_matches_machine = route.as_ref().is_some_and(|route| {
        matches!(
            route.target(),
            crate::route::Target::Machine {
                id,
                page: crate::route::MachinePage::Web
            } if id == &endpoint.machine_id
        )
    });
    if endpoint.machine_id.is_empty()
        || endpoint.machine_id.len() > 128
        || endpoint
            .machine_id
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace() || byte == 0)
        || endpoint.label.is_empty()
        || endpoint.label.len() > 256
        || endpoint.label.chars().any(char::is_control)
        || endpoint.port == 0
        || !matches!(endpoint.visibility.as_str(), "private" | "public")
        || endpoint.route.len() > 2_048
        || endpoint.route.chars().any(char::is_control)
        || !route_matches_machine
        || (endpoint.visibility == "public" && endpoint.url.is_none())
        || endpoint
            .url
            .as_deref()
            .is_some_and(|url| !valid_https_endpoint_url(url, endpoint.port))
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(endpoint)
}

/// Revalidates a browser destination immediately before launching it.
/// Keeping this boundary public lets GTK callers avoid trusting stale UI state.
pub fn valid_https_endpoint_url(url: &str, expected_port: u16) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    if url.len() > 2_048 || rest.is_empty() {
        return false;
    }
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty()
        || authority.starts_with(':')
        || authority.contains(['@', '#', ' ', '\t', '\n', '\r'])
    {
        return false;
    }
    if authority.ends_with(':') {
        return false;
    }
    let (host, explicit) = match authority.rsplit_once(':') {
        Some((host, port)) => {
            let parsed = port.parse::<u16>().ok();
            if parsed.is_none() || host.is_empty() {
                return false;
            }
            (host, parsed)
        }
        None => (authority, None),
    };
    if host.is_empty()
        || host.len() > 253
        || host.starts_with('.')
        || host.ends_with('.')
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return false;
    }
    explicit.is_none_or(|port| port != 0 && port == expected_port)
}

/// Return a browser destination only for an authenticated public endpoint.
/// Keeping this decision in the Rust adapter prevents GTK from accidentally
/// opening a stale or private URL retained in widget state.
pub fn browser_endpoint_url(endpoint: &WebEndpoint) -> Option<&str> {
    (endpoint.visibility == "public")
        .then_some(endpoint.url.as_deref())
        .flatten()
        .filter(|url| valid_https_endpoint_url(url, endpoint.port))
}

/// A presentation-safe notification device projection. Push keys and public
/// encryption material never cross this decoder.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct NotificationDevice {
    pub id: String,
    pub platform: String,
    pub label: Option<String>,
    pub enabled: bool,
    pub state: String,
    pub route: String,
}

pub fn decode_notification_devices(bytes: &[u8]) -> Result<Vec<NotificationDevice>, RuntimeError> {
    if bytes.len() > 256 * 1024 {
        return Err(RuntimeError::InvalidInput);
    }
    #[derive(Deserialize)]
    struct Envelope {
        items: Vec<NotificationDevice>,
    }
    let envelope: Envelope =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    if envelope.items.len() > 256
        || envelope.items.iter().any(|device| {
            device.id.is_empty()
                || device.id.len() > 128
                || device
                    .id
                    .bytes()
                    .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace() || byte == 0)
                || !matches!(
                    device.platform.as_str(),
                    "ios" | "android" | "macos" | "windows"
                )
                || device
                    .label
                    .as_deref()
                    .is_some_and(|label| label.len() > 64 || label.chars().any(char::is_control))
                || !matches!(
                    device.state.as_str(),
                    "pending" | "active" | "invalidated" | "revoked"
                )
                || crate::route::ActivationRoute::parse(&device.route).is_err()
        })
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(envelope.items)
}

pub fn format_notification_device_command(
    operation: &str,
    device_id: Option<&str>,
    enabled: Option<bool>,
) -> Result<String, RuntimeError> {
    let line = match operation {
        "ls" if device_id.is_none() && enabled.is_none() => "device ls".to_owned(),
        "rm" if enabled.is_none() => format!("device rm {}", valid_device_id(device_id)?),
        "prefs" => format!(
            "device prefs {} --enabled {}",
            valid_device_id(device_id)?,
            enabled.ok_or(RuntimeError::InvalidInput)?
        ),
        _ => return Err(RuntimeError::InvalidInput),
    };
    Ok(line)
}

fn valid_device_id(value: Option<&str>) -> Result<&str, RuntimeError> {
    let value = value.ok_or(RuntimeError::InvalidInput)?;
    if value.is_empty()
        || value.len() > 128
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace() || byte == 0)
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(value)
}

/// Validates Linux push registration metadata through the shared Rust policy.
/// Token material is accepted only for the duration of this call and never
/// returned to GTK or retained by the adapter.
pub fn validate_push_registration(
    provider: u8,
    production: bool,
    token: &str,
    app_id: &str,
    deployment: &str,
    endpoint: Option<&str>,
) -> Result<(), RuntimeError> {
    let token = CString::new(token).map_err(|_| RuntimeError::InvalidInput)?;
    let app_id = CString::new(app_id).map_err(|_| RuntimeError::InvalidInput)?;
    let deployment = CString::new(deployment).map_err(|_| RuntimeError::InvalidInput)?;
    let endpoint = endpoint
        .map(CString::new)
        .transpose()
        .map_err(|_| RuntimeError::InvalidInput)?;
    let status = unsafe {
        mila_ffi::mila_push_registration_validate(
            provider,
            u8::from(production),
            token.as_ptr(),
            app_id.as_ptr(),
            deployment.as_ptr(),
            endpoint
                .as_ref()
                .map_or(std::ptr::null(), |value| value.as_ptr()),
        )
    };
    (status == mila_ffi::MilaFfiStatus::Ok)
        .then_some(())
        .ok_or(RuntimeError::InvalidInput)
}

/// Decode a Rust-owned live listing before it reaches GTK. Linux uses the same
/// bounded session decoder as the other native clients, so malformed authority
/// or pagination data cannot become UI state.
pub fn decode_listing(bytes: &[u8]) -> Result<mila_session::MachineListing, RuntimeError> {
    mila_session::decode_listing(bytes).map_err(|_| RuntimeError::InvalidInput)
}

/// Terminal controls exposed to GTK without exposing terminal bytes or pointers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalOperation {
    Attach {
        from: u64,
        columns: u16,
        rows: u16,
        read_write: bool,
    },
    Input {
        length: usize,
        read_write: bool,
    },
    Resize {
        columns: u16,
        rows: u16,
        read_write: bool,
    },
}

pub fn validate_terminal_operation(operation: TerminalOperation) -> Result<(), RuntimeError> {
    let status = match operation {
        TerminalOperation::Attach {
            from,
            columns,
            rows,
            read_write,
        } => mila_ffi::mila_terminal_attach_validate(from, columns, rows, u8::from(read_write)),
        TerminalOperation::Input { length, read_write } => {
            mila_ffi::mila_terminal_input_validate(length, u8::from(read_write))
        }
        TerminalOperation::Resize {
            columns,
            rows,
            read_write,
        } => mila_ffi::mila_terminal_resize_validate(columns, rows, u8::from(read_write)),
    };
    if status == mila_ffi::MilaFfiStatus::Ok {
        Ok(())
    } else {
        Err(RuntimeError::InvalidInput)
    }
}

/// Payload-free PTY lifecycle owned by the Linux host. The stream bytes stay in
/// the GTK transport; this reducer only tracks generation, cursor and authority.
#[derive(Debug)]
pub struct TerminalStream {
    state: mila_runtime::TerminalAttach,
    renderer: crate::terminal::TerminalRenderer,
}

impl TerminalStream {
    pub fn new() -> Self {
        Self {
            state: mila_runtime::TerminalAttach::initial(),
            renderer: crate::terminal::TerminalRenderer::new(80, 24)
                .expect("fixed terminal dimensions are valid"),
        }
    }
    pub fn renderer(&self) -> &crate::terminal::TerminalRenderer {
        &self.renderer
    }
    pub fn render_output(&mut self, generation: u64, text: &str) -> Result<(), RuntimeError> {
        if !self
            .state
            .output(generation, text.chars().count())
            .then_some(())
            .is_some()
        {
            return Err(RuntimeError::InvalidInput);
        }
        self.renderer
            .append_text(text)
            .map_err(|_| RuntimeError::InvalidInput)
    }
    pub fn rendered_text(&self) -> String {
        self.renderer.lines().join("\n")
    }
    pub fn state(&self) -> &mila_runtime::TerminalAttach {
        &self.state
    }
    pub fn attach(&mut self) -> Result<u64, RuntimeError> {
        self.state
            .request()
            .then_some(self.state.generation())
            .ok_or(RuntimeError::Unavailable)
    }
    pub fn connected(
        &mut self,
        generation: u64,
        cursor: u64,
        read_write: bool,
    ) -> Result<(), RuntimeError> {
        let mode = if read_write {
            mila_runtime::AttachMode::ReadWrite
        } else {
            mila_runtime::AttachMode::ReadOnly
        };
        self.state
            .header(
                generation,
                Some(mila_runtime::AttachHeader::Attached { from: cursor, mode }),
            )
            .then_some(())
            .ok_or(RuntimeError::InvalidInput)
    }
    pub fn output(&mut self, generation: u64, length: usize) -> Result<(), RuntimeError> {
        self.state
            .output(generation, length)
            .then_some(())
            .ok_or(RuntimeError::InvalidInput)
    }
    pub fn reconnect(&mut self) -> Result<u64, RuntimeError> {
        // A transport loss leaves the reducer attached until the host reports
        // the channel ended.  Explicit reconnect must fence that generation
        // first, otherwise `attach` correctly rejects a second live channel.
        // The transition is payload-free; terminal bytes never enter state.
        if self.state.phase() == mila_runtime::AttachPhase::Attached {
            let generation = self.state.generation();
            self.state
                .ended(generation, mila_runtime::AttachOutcome::Transport)
                .then_some(())
                .ok_or(RuntimeError::InvalidInput)?;
        }
        self.attach()
    }
    pub fn kill(&mut self, generation: u64) -> Result<(), RuntimeError> {
        self.state
            .ended(generation, mila_runtime::AttachOutcome::Closed)
            .then_some(())
            .ok_or(RuntimeError::InvalidInput)
    }
    pub fn validate_input(&self, length: usize) -> Result<(), RuntimeError> {
        if !self.state.can_send_input() {
            return Err(RuntimeError::Unavailable);
        }
        validate_terminal_operation(TerminalOperation::Input {
            length,
            read_write: true,
        })
    }
    pub fn validate_resize(&self, columns: u16, rows: u16) -> Result<(), RuntimeError> {
        if !self.state.can_resize() {
            return Err(RuntimeError::Unavailable);
        }
        validate_terminal_operation(TerminalOperation::Resize {
            columns,
            rows,
            read_write: true,
        })
    }
}

/// Operations the native UI may request from the generated runtime.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeOperation {
    Bootstrap,
    Refresh,
    ValidateTerminal,
}

/// A request crossing the native UI/runtime boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeRequest {
    operation: RuntimeOperation,
    payload: Vec<u8>,
}

impl RuntimeRequest {
    pub fn new(operation: RuntimeOperation, payload: impl Into<Vec<u8>>) -> Self {
        Self {
            operation,
            payload: payload.into(),
        }
    }

    pub const fn operation(&self) -> RuntimeOperation {
        self.operation
    }

    pub fn payload(&self) -> &[u8] {
        &self.payload
    }
}

/// A response crossing the native UI/runtime boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeResponse {
    payload: Vec<u8>,
}

impl RuntimeResponse {
    pub fn new(payload: impl Into<Vec<u8>>) -> Self {
        Self {
            payload: payload.into(),
        }
    }

    pub fn payload(&self) -> &[u8] {
        &self.payload
    }
}

/// Errors exposed by the typed adapter seam.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeError {
    Unavailable,
    InvalidInput,
}

#[cfg(test)]
mod request_id_tests {
    use super::{format_ssh_key_revoke, new_request_id};

    #[test]
    fn generated_request_ids_are_fresh_and_accepted() {
        let first = new_request_id().expect("CSPRNG");
        let second = new_request_id().expect("CSPRNG");
        assert_ne!(first, second);
        assert_eq!(first.len(), 40);
        assert!(first[8..]
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)));
        assert!(format_ssh_key_revoke("key-1", &first).is_ok());
    }
}

#[cfg(test)]
mod web_tests {
    use super::*;
    const MACHINE: &str = "01234567-89ab-cdef-0123-456789abcdef";
    const REQUEST: &str = "porsche-0123456789abcdef0123456789abcdef";

    #[test]
    fn web_show_is_canonical_and_bounded() {
        assert_eq!(
            format_web_command("show", MACHINE, None, false, None).unwrap(),
            format!("web show {MACHINE} --json")
        );
    }

    #[test]
    fn web_set_requires_port_and_request() {
        assert!(format_web_command("set", MACHINE, None, true, Some(REQUEST)).is_err());
        assert!(format_web_command("set", MACHINE, Some(8080), true, None).is_err());
        assert_eq!(
            format_web_command("set", MACHINE, Some(8080), true, Some(REQUEST)).unwrap(),
            format!("web set {MACHINE} --json --port=8080 --public --request-id={REQUEST}")
        );
    }

    #[test]
    fn authenticated_web_projection_requires_https_and_canonical_route() {
        let value = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":null,"route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        let endpoint = decode_web_endpoint(value).expect("web endpoint");
        assert_eq!(endpoint.policy_revision, 4);
        let bad = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":"http://web-box.example","route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        assert!(decode_web_endpoint(bad).is_err());
        let empty_host = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":"https://","route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        assert!(decode_web_endpoint(empty_host).is_err());
        let mismatched = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":null,"route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdee/web"}"#;
        assert!(decode_web_endpoint(mismatched).is_err());
        let public_without_url = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"public","policy_revision":4,"url":null,"route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        assert!(decode_web_endpoint(public_without_url).is_err());
        let wrong_port = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":"https://web-box.example:8443/path","route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        assert!(decode_web_endpoint(wrong_port).is_err());
        let malformed_port = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":"https://web-box.example:abc/path","route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        assert!(decode_web_endpoint(malformed_port).is_err());
        let malformed_host = br#"{"machine_id":"01234567-89ab-cdef-0123-456789abcdef","label":"web-box","port":8080,"visibility":"private","policy_revision":4,"url":"https://-web-box.example:8080/path","route":"overalls://fleet.example/machines/01234567-89ab-cdef-0123-456789abcdef/web"}"#;
        assert!(decode_web_endpoint(malformed_host).is_err());
    }

    #[test]
    fn browser_destination_requires_public_endpoint_and_matching_https_port() {
        let base = WebEndpoint {
            machine_id: MACHINE.to_owned(),
            label: "web-box".to_owned(),
            port: 8443,
            visibility: "public".to_owned(),
            policy_revision: 1,
            url: Some("https://web-box.example:8443/".to_owned()),
            route: format!("overalls://fleet.example/machines/{MACHINE}/web"),
        };
        assert_eq!(browser_endpoint_url(&base), base.url.as_deref());
        let mut private = base.clone();
        private.visibility = "private".to_owned();
        assert!(browser_endpoint_url(&private).is_none());
        let mut wrong_port = base;
        wrong_port.url = Some("https://web-box.example:9443/".to_owned());
        assert!(browser_endpoint_url(&wrong_port).is_none());
    }

    #[test]
    fn notification_devices_are_bounded_and_commands_are_catalogued() {
        let payload = br#"{"items":[{"id":"01234567-89ab-cdef-0123-456789abcdef","platform":"android","label":"phone","enabled":true,"state":"active","route":"overalls://fleet.example/settings"}]}"#;
        assert_eq!(decode_notification_devices(payload).unwrap().len(), 1);
        assert_eq!(
            format_notification_device_command("ls", None, None).unwrap(),
            "device ls"
        );
        assert_eq!(
            format_notification_device_command("prefs", Some("device-1"), Some(false)).unwrap(),
            "device prefs device-1 --enabled false"
        );
        assert!(format_notification_device_command("rm", Some("bad id"), None).is_err());
    }

    #[test]
    fn push_registration_requires_provider_specific_metadata() {
        assert!(validate_push_registration(
            0,
            false,
            &"ab".repeat(32),
            "app",
            "mila.example",
            None
        )
        .is_ok());
        assert!(validate_push_registration(
            2,
            true,
            "https://push.notify.windows.com:443/channel",
            "app",
            "mila.example",
            None
        )
        .is_err());
        assert!(validate_push_registration(
            2,
            true,
            "https://push.notify.windows.com:443/channel",
            "app",
            "mila.example",
            Some("https://push.notify.windows.com:443/channel")
        )
        .is_ok());
        assert!(validate_push_registration(
            9,
            true,
            "https://push.notify.windows.com:443/channel",
            "app",
            "mila.example",
            None
        )
        .is_err());
    }
}

#[cfg(test)]
mod terminal_stream_tests {
    use super::*;
    use mila_runtime::AttachPhase;

    #[test]
    fn stream_reconnect_and_kill_are_generation_scoped() {
        let mut stream = TerminalStream::new();
        let generation = stream.attach().expect("attach");
        stream.connected(generation, 0, true).expect("connected");
        stream.output(generation, 4).expect("output");
        stream.validate_input(4).expect("input grant");
        stream.kill(generation).expect("kill");
        assert_eq!(stream.state().phase(), AttachPhase::Ended);
        assert!(stream.output(generation, 1).is_err());
        let next = stream.reconnect().expect("reconnect");
        assert_ne!(next, generation);
        assert!(stream.kill(generation).is_err());
    }

    #[test]
    fn reconnect_fences_an_attached_generation_after_transport_loss() {
        let mut stream = TerminalStream::new();
        let first = stream.attach().expect("attach");
        stream.connected(first, 0, true).expect("connected");

        let next = stream.reconnect().expect("reconnect");
        assert_ne!(next, first);
        assert_eq!(stream.state().phase(), AttachPhase::Attaching);
        assert!(stream.kill(first).is_err());
    }

    #[test]
    fn read_only_stream_rejects_input_and_resize() {
        let mut stream = TerminalStream::new();
        let generation = stream.attach().expect("attach");
        stream.connected(generation, 0, false).expect("connected");
        assert!(stream.validate_input(1).is_err());
        assert!(stream.validate_resize(80, 24).is_err());
    }

    #[test]
    fn rendered_output_is_generation_scoped_and_keeps_terminal_state_typed() {
        let mut stream = TerminalStream::new();
        let generation = stream.attach().expect("attach");
        stream.connected(generation, 0, true).expect("connected");
        stream.render_output(generation, "hello\n").expect("output");
        assert!(stream.rendered_text().contains("hello"));
        assert!(stream.render_output(generation + 1, "late").is_err());
    }
}

pub trait RuntimeAdapter {
    fn call(&self, request: RuntimeRequest) -> Result<RuntimeResponse, RuntimeError>;
}

/// In-process adapter used by the Linux presentation host.
///
/// Bootstrap accepts a bounded `overalls://` route and returns its canonical
/// representation. Refresh accepts a Rust-owned machine snapshot, validates it
/// through the shared FFI contract, retains it in memory, and returns the
/// validated bytes. No network or credential operation is exposed by this
/// adapter; unsupported operations remain fail-closed at the enum boundary.
#[derive(Clone, Debug)]
pub struct InProcessRuntimeAdapter {
    host: CString,
    port: Option<u16>,
    snapshot: Arc<Mutex<Option<Vec<u8>>>>,
    generation: Arc<AtomicU64>,
}

impl InProcessRuntimeAdapter {
    pub fn new(host: &str, port: Option<u16>) -> Result<Self, RuntimeError> {
        let host = CString::new(host).map_err(|_| RuntimeError::InvalidInput)?;
        Ok(Self {
            host,
            port,
            snapshot: Arc::new(Mutex::new(None)),
            generation: Arc::new(AtomicU64::new(0)),
        })
    }

    /// Starts a new authenticated presentation generation and clears any
    /// machine projection belonging to the previous session.
    pub fn begin_generation(&self) -> u64 {
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        if let Ok(mut snapshot) = self.snapshot.lock() {
            snapshot.take();
        }
        generation
    }

    /// Store a machine snapshot only when it belongs to the current session.
    /// Late responses from a signed-out or reconnected session are rejected.
    pub fn refresh_generation(
        &self,
        generation: u64,
        payload: &[u8],
    ) -> Result<Vec<u8>, RuntimeError> {
        if self.generation.load(Ordering::Acquire) != generation {
            return Err(RuntimeError::Unavailable);
        }
        let response = self.call(RuntimeRequest::new(RuntimeOperation::Refresh, payload))?;
        Ok(response.payload().to_vec())
    }

    pub fn snapshot(&self) -> Result<Option<Vec<u8>>, RuntimeError> {
        self.snapshot
            .lock()
            .map(|value| value.clone())
            .map_err(|_| RuntimeError::Unavailable)
    }
}

impl RuntimeAdapter for InProcessRuntimeAdapter {
    fn call(&self, request: RuntimeRequest) -> Result<RuntimeResponse, RuntimeError> {
        match request.operation() {
            RuntimeOperation::Bootstrap => {
                let route = std::str::from_utf8(request.payload())
                    .map_err(|_| RuntimeError::InvalidInput)?;
                Ok(RuntimeResponse::new(canonical_route(route)?.into_bytes()))
            }
            RuntimeOperation::Refresh => {
                let payload = request.payload();
                let mut summary = mila_ffi::MilaSnapshotSummary {
                    machine_count: 0,
                    saved_at: 0,
                };
                let status = unsafe {
                    mila_ffi::mila_snapshot_validate(
                        payload.as_ptr(),
                        payload.len(),
                        self.host.as_ptr(),
                        self.port.unwrap_or_default(),
                        u8::from(self.port.is_some()),
                        &mut summary,
                    )
                };
                if status != mila_ffi::MilaFfiStatus::Ok {
                    return Err(RuntimeError::InvalidInput);
                }
                self.snapshot
                    .lock()
                    .map_err(|_| RuntimeError::Unavailable)?
                    .replace(payload.to_vec());
                Ok(RuntimeResponse::new(payload.to_vec()))
            }
            RuntimeOperation::ValidateTerminal => {
                // Terminal attach requests are validated by the shared Rust
                // transport contract before any platform UI is allowed to
                // open a channel. The payload is the compact tuple
                // `[columns:u16 LE, rows:u16 LE, read_write:u8]`.
                if request.payload().len() != 5 {
                    return Err(RuntimeError::InvalidInput);
                }
                let bytes = request.payload();
                let columns = u16::from_le_bytes([bytes[0], bytes[1]]);
                let rows = u16::from_le_bytes([bytes[2], bytes[3]]);
                let status = mila_ffi::mila_terminal_validate(columns, rows, bytes[4]);
                if status != mila_ffi::MilaFfiStatus::Ok {
                    return Err(RuntimeError::InvalidInput);
                }
                Ok(RuntimeResponse::new(Vec::new()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        canonical_route, decode_share_listing, format_machine_action, format_share_command,
        InProcessRuntimeAdapter, RuntimeAdapter, RuntimeError, RuntimeOperation, RuntimeRequest,
    };

    #[test]
    fn bootstrap_canonicalizes_routes() {
        let adapter = InProcessRuntimeAdapter::new("fleet.example", None).unwrap();
        let request = RuntimeRequest::new(
            RuntimeOperation::Bootstrap,
            b"overalls://fleet.example/machines".to_vec(),
        );
        assert_eq!(
            adapter.call(request).unwrap().payload(),
            b"overalls://fleet.example/machines"
        );
    }

    #[test]
    fn refresh_rejects_invalid_snapshot_and_does_not_retain_it() {
        let adapter = InProcessRuntimeAdapter::new("fleet.example", None).unwrap();
        let request = RuntimeRequest::new(RuntimeOperation::Refresh, [1_u8, 2, 3]);
        assert_eq!(adapter.call(request), Err(RuntimeError::InvalidInput));
        assert_eq!(adapter.snapshot().unwrap(), None);
    }

    #[test]
    fn activation_resolution_requires_matching_authenticated_deployment() {
        let route = "overalls://fleet.example/machines";
        assert!(matches!(
            super::resolve_activation(route, Some("fleet.example"), true).unwrap(),
            crate::route::NavigationDecision::Open { .. }
        ));
        assert!(matches!(
            super::resolve_activation(route, Some("fleet.example"), false).unwrap(),
            crate::route::NavigationDecision::SignInRequired { .. }
        ));
        assert!(matches!(
            super::resolve_activation(route, Some("other.example"), true).unwrap(),
            crate::route::NavigationDecision::UnknownDeployment { .. }
        ));
    }

    #[test]
    fn canonical_route_uses_shared_core_grammar() {
        assert_eq!(
            canonical_route("overalls://fleet.example/machines").unwrap(),
            "overalls://fleet.example/machines"
        );
        assert_eq!(
            canonical_route("overalls://fleet.example/#commands"),
            Err(RuntimeError::InvalidInput)
        );
    }

    #[test]
    fn machine_actions_are_formatted_by_rust_policy() {
        let id = "123e4567-e89b-12d3-a456-426614174000";
        let request = "porsche-123e4567e89b12d3a456426614174001";
        assert_eq!(
            format_machine_action("start", id, Some(request)).unwrap(),
            format!("start {id} --json --request-id={request}")
        );
        assert!(format_machine_action("start", "bad", Some(request)).is_err());
        assert!(format_machine_action("start", id, None).is_err());
        assert!(format_machine_action("rm", id, Some(request)).is_ok());
    }

    #[test]
    fn sharing_commands_and_listing_are_bounded() {
        let machine = "123e4567-e89b-12d3-a456-426614174000";
        let request = "porsche-123e4567e89b12d3a456426614174001";
        assert_eq!(
            format_share_command(
                "add",
                machine,
                "teammate@example.test",
                Some("viewer"),
                request
            )
            .unwrap(),
            format!(
                "share add {machine} teammate@example.test viewer --json --request-id={request}"
            )
        );
        assert!(
            format_share_command("add", machine, "bad email", Some("viewer"), request).is_err()
        );
        assert!(
            format_share_command("add", machine, "a@example.test", Some("owner"), request).is_err()
        );
        assert_eq!(
            format_share_command("remove", machine, "a@example.test", None, request).unwrap(),
            format!("share remove {machine} a@example.test --json --request-id={request}")
        );
        let payload = br#"{"owner":{"email":"owner@example.test"},"items":[{"id":"g1","user_id":"u1","email":"a@example.test","role":"operator"}]}"#;
        let (owner, grants) = decode_share_listing(payload).unwrap();
        assert_eq!(owner, "owner@example.test");
        assert_eq!(grants[0].role, "operator");
        assert!(decode_share_listing(br#"{"owner":{"email":"owner@example.test"},"items":[{"id":"g1","user_id":"u1","email":"a@example.test","role":"owner"}]}"#).is_err());
        assert!(decode_share_listing(br#"{"owner":{"email":"owner@example.test"},"items":[{"id":"g1\n","user_id":"u1","email":"a@example.test","role":"viewer"}]}"#).is_err());
        assert!(decode_share_listing(br#"{"owner":{"email":"owner@example.test"},"items":[{"id":"g1","user_id":"u1","email":"a@example.test","role":"viewer"},{"id":"g1","user_id":"u2","email":"b@example.test","role":"viewer"}]}"#).is_err());
    }

    #[test]
    fn terminal_controls_use_shared_ffi_validation() {
        assert!(
            super::validate_terminal_operation(super::TerminalOperation::Attach {
                from: 0,
                columns: 80,
                rows: 24,
                read_write: true
            })
            .is_ok()
        );
        assert!(
            super::validate_terminal_operation(super::TerminalOperation::Resize {
                columns: 0,
                rows: 24,
                read_write: true
            })
            .is_err()
        );
        assert!(
            super::validate_terminal_operation(super::TerminalOperation::Input {
                length: 1,
                read_write: false
            })
            .is_err()
        );
        assert!(
            super::validate_terminal_operation(super::TerminalOperation::Input {
                length: 4,
                read_write: true
            })
            .is_ok()
        );
    }

    #[test]
    fn listing_uses_shared_bounded_decoder() {
        let bytes =
            br#"{"version":1,"status":"succeeded","result":{"items":[],"next_cursor":null}}"#;
        let listing = super::decode_listing(bytes).unwrap();
        assert!(listing.machines().is_empty());
        assert!(!listing.has_more());
        assert!(super::decode_listing(br#"{}"#).is_err());
    }

    #[test]
    fn terminal_requests_use_shared_bounds_and_mode_validation() {
        let adapter = InProcessRuntimeAdapter::new("fleet.example", None).unwrap();
        let valid = RuntimeRequest::new(RuntimeOperation::ValidateTerminal, [120, 0, 40, 0, 1]);
        assert!(adapter.call(valid).is_ok());
        let invalid_mode =
            RuntimeRequest::new(RuntimeOperation::ValidateTerminal, [120, 0, 40, 0, 2]);
        assert_eq!(adapter.call(invalid_mode), Err(RuntimeError::InvalidInput));
        let malformed = RuntimeRequest::new(RuntimeOperation::ValidateTerminal, [120, 0]);
        assert_eq!(adapter.call(malformed), Err(RuntimeError::InvalidInput));
    }

    #[test]
    fn stale_machine_refresh_is_rejected_after_new_generation() {
        let adapter = InProcessRuntimeAdapter::new("fleet.example", None).unwrap();
        let first = adapter.begin_generation();
        let second = adapter.begin_generation();
        let payload =
            br#"{"version":1,"host":"fleet.example","port":null,"saved_at":1,"machines":[]}"#;
        assert!(adapter.refresh_generation(first, payload).is_err());
        assert!(adapter.refresh_generation(second, payload).is_ok());
        assert!(adapter.snapshot().unwrap().is_some());
    }

    #[test]
    fn ssh_key_listing_is_bounded_and_typed() {
        let listing = super::decode_ssh_keys(
            br#"{"keys":[{"id":"k1","label":"laptop","fingerprint":"SHA256:x","added_at":1770000000,"private":"never"}]}"#,
        )
        .unwrap();
        assert_eq!(listing[0].id, "k1");
        assert!(super::decode_ssh_keys(br#"{}"#).is_err());
        assert!(super::decode_ssh_keys(
            br#"{"keys":[{"id":"","label":"x","fingerprint":"y","added_at":1}]}"#
        )
        .is_err());
        assert!(super::decode_ssh_keys(
            br#"{"keys":[{"id":"k\u0001","label":"x","fingerprint":"y","added_at":1}]}"#
        )
        .is_err());
        assert!(super::decode_ssh_keys(
            br#"{"keys":[{"id":"k1","label":"x","fingerprint":"SHA256:bad value","added_at":1}]}"#
        )
        .is_err());
        assert!(super::decode_ssh_keys(
            br#"{"keys":[{"id":"k1","label":"x","fingerprint":"SHA256:x","added_at":1},{"id":"k1","label":"y","fingerprint":"SHA256:y","added_at":2}]}"#
        )
        .is_err());
    }

    #[test]
    fn ssh_key_refresh_rejects_stale_generation_after_reconnect() {
        let payload =
            br#"{"keys":[{"id":"k1","label":"laptop","fingerprint":"SHA256:x","added_at":1}]}"#;
        let mut projection = super::SshKeyProjection::default();
        let first = projection.begin_generation();
        let second = projection.begin_generation();
        assert!(projection.refresh(first, payload).is_err());
        projection
            .refresh(second, payload)
            .expect("current generation");
        assert_eq!(projection.keys().len(), 1);
    }

    #[test]
    fn ssh_key_revoke_requires_canonical_request_id() {
        let request = "porsche-123e4567e89b12d3a456426614174001";
        assert_eq!(
            super::format_ssh_key_revoke("key-1", request).unwrap(),
            format!("ssh-key remove --json --request-id={request} key-1")
        );
        assert!(super::format_ssh_key_revoke("key 1", request).is_err());
        assert!(super::format_ssh_key_revoke("key\n1", request).is_err());
        assert!(super::format_ssh_key_revoke("key-1", "bad").is_err());
    }
}
