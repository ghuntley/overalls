//! Linux enrollment and authenticated-session ownership.
//!
//! This module is deliberately independent of GTK.  The UI receives only the
//! state and bounded listing projection; the Rust FFI handle remains the sole
//! authority for an authenticated deployment connection.

use crate::adapter::RuntimeError;
use mila_ffi::session::TerminalReadEvent;
use mila_ffi::{MilaFfiStatus, MilaRouteOutput};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use std::collections::HashSet;
use std::fmt::Write as _;

const MAX_TRUST_BYTES: usize = 8192;
const MAX_LISTING_BYTES: usize = 1 << 20;

/// A signer supplied by the Linux host. Private key bytes never enter this API.
pub trait DeviceSigner: Send + Sync {
    fn public_key(&self) -> &str;
    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError>;
}

/// @cc [owner:ghuntley,label:security] linux-file-signer-custody
/// A file-backed Linux signer MUST reject symlinks and any group/world
/// permission bits before reading key material, and MUST expose only signatures
/// and the configured public key to the session boundary.
///
/// A Linux software signer backed by an owner-only raw P-256 key file.
/// Hardware-backed desktop signers can implement [`DeviceSigner`] directly;
/// this adapter exists for the Linux development and release bundle where the
/// key is provisioned outside the GTK process.
pub struct FileDeviceSigner {
    key: SigningKey,
    public_key: String,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for FileDeviceSigner {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FileDeviceSigner")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignerError {
    Unavailable,
    InsecurePermissions,
    InvalidKey,
}

impl FileDeviceSigner {
    /// Loads exactly 32 raw key bytes and refuses symlinks or group/world access.
    pub fn load(path: &std::path::Path, public_key: String) -> Result<Self, SignerError> {
        use std::{fs, os::unix::fs::PermissionsExt};
        let metadata = fs::symlink_metadata(path).map_err(|_| SignerError::Unavailable)?;
        if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(SignerError::InsecurePermissions);
        }
        if public_key.is_empty() || public_key.len() > 1024 {
            return Err(SignerError::InvalidKey);
        }
        let bytes = fs::read(path).map_err(|_| SignerError::Unavailable)?;
        let key = SigningKey::from_slice(&bytes).map_err(|_| SignerError::InvalidKey)?;
        Ok(Self { key, public_key })
    }
}

impl DeviceSigner for FileDeviceSigner {
    fn public_key(&self) -> &str {
        &self.public_key
    }

    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError> {
        let signature: Signature = self.key.sign(message);
        let mut output = [0_u8; 64];
        output.copy_from_slice(&signature.to_bytes());
        Ok(output)
    }
}

unsafe extern "C" fn sign_trampoline<S: DeviceSigner>(
    context: usize,
    message: *const u8,
    length: usize,
    signature: *mut u8,
) -> i32 {
    if context == 0 || message.is_null() || signature.is_null() || length == 0 || length > 65_536 {
        return -1;
    }
    // SAFETY: `mila_session_connect` invokes this callback synchronously with
    // the non-zero context it was given, which is a live `&S` borrowed for the
    // whole connect call.
    let signer = unsafe { &*(context as *const S) };
    // SAFETY: the caller promises `message` is non-null (checked above) and
    // valid for `length` readable bytes for the duration of the callback.
    let message = unsafe { std::slice::from_raw_parts(message, length) };
    let Ok(value) = signer.sign(message) else {
        return -1;
    };
    // SAFETY: the caller promises `signature` is non-null (checked above) and
    // points to a writable 64-byte buffer that does not alias `message`.
    unsafe { std::slice::from_raw_parts_mut(signature, 64) }.copy_from_slice(&value);
    0
}

/// Material needed to open one certificate-authenticated session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionConnectConfig {
    pub trust_document: Vec<u8>,
    pub host: String,
    pub port: u16,
    pub timeout_ms: u32,
}

impl SessionConnectConfig {
    pub fn validate(&self) -> Result<(), RuntimeError> {
        if self.trust_document.is_empty() || self.trust_document.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        validate_session_endpoint(&self.host, self.port, self.timeout_ms)?;
        Ok(())
    }
}

fn validate_session_endpoint(host: &str, port: u16, timeout_ms: u32) -> Result<(), RuntimeError> {
    if host.is_empty()
        || host.len() > 180
        || host.bytes().any(|b| b.is_ascii_control() || b == b' ')
        || port == 0
        || !(1..=120_000).contains(&timeout_ms)
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(())
}

/// Stable errors for the GTK host; no remote response or credential is exposed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionError {
    InvalidInput,
    Transport,
    Busy,
    StaleHandle,
    Unavailable,
}

impl From<mila_ffi::session::SessionStatus> for SessionError {
    fn from(value: mila_ffi::session::SessionStatus) -> Self {
        use mila_ffi::session::SessionStatus as S;
        match value {
            S::Invalid => Self::InvalidInput,
            S::InvalidHandle => Self::StaleHandle,
            S::Busy => Self::Busy,
            S::NotLoaded | S::Ok | S::SmallBuffer => Self::Unavailable,
            S::Transport | S::Internal => Self::Transport,
        }
    }
}

/// One owned FFI session. Closing removes the remote authority exactly once.
pub struct LiveSession {
    handle: Option<u64>,
    terminal: Option<u64>,
    submitted_mutations: HashSet<String>,
    read_buffer: Vec<u8>,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for LiveSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LiveSession")
            .finish_non_exhaustive()
    }
}

/// One bounded terminal read. Bytes stay inside the host transport; the GTK
/// surface only receives text decoded by `PtyTextDecoder`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalChunk {
    Data(Vec<u8>),
    Idle,
    Closed,
}

impl LiveSession {
    /// Opens a Rust session. The signer reference is used only during the
    /// synchronous FFI call and is never retained by the C ABI.
    pub fn connect<S: DeviceSigner>(
        config: &SessionConnectConfig,
        signer: &S,
    ) -> Result<Self, SessionError> {
        config.validate().map_err(|_| SessionError::InvalidInput)?;
        let public_key = signer.public_key();
        if public_key.is_empty() || public_key.len() > 1024 {
            return Err(SessionError::InvalidInput);
        }
        let mut handle = 0_u64;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call and `handle` is a writable local. The callback context
        // is `signer`, borrowed for the whole call; `mila_session_connect` invokes
        // `sign_trampoline::<S>` only synchronously and retains neither.
        let status = unsafe {
            mila_ffi::session::mila_session_connect(
                config.trust_document.as_ptr(),
                config.trust_document.len(),
                config.host.as_bytes().as_ptr(),
                config.host.len(),
                public_key.as_bytes().as_ptr(),
                public_key.len(),
                config.port,
                config.timeout_ms,
                Some(sign_trampoline::<S>),
                std::ptr::from_ref::<S>(signer) as usize,
                &raw mut handle,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || handle == 0 {
            return Err(status.into());
        }
        Ok(Self {
            handle: Some(handle),
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        })
    }

    pub fn refresh(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        let status = mila_ffi::session::mila_session_read_machines(handle, 0);
        if status != mila_ffi::session::SessionStatus::Ok {
            return Err(status.into());
        }
        self.listing()
    }

    pub fn listing(&self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_listing(handle, out, capacity, written)
        })
    }

    /// Read the authenticated account SSH-key inventory. The FFI layer keeps
    /// the response bounded; callers must decode it with `decode_ssh_keys`.
    pub fn ssh_keys(&self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_ssh_keys(handle, out, capacity, written)
        })
    }

    /// Revoke one server-managed SSH key, once per request identifier.
    pub fn ssh_key_revoke(&mut self, key_id: &str, request_id: &str) -> Result<(), SessionError> {
        let command = crate::adapter::format_ssh_key_revoke(key_id, request_id)
            .map_err(|_| SessionError::InvalidInput)?;
        if !self.submitted_mutations.insert(request_id.to_owned()) {
            return Err(SessionError::Busy);
        }
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_ssh_key_revoke(
                handle,
                key_id.as_bytes().as_ptr(),
                key_id.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        let _ = command;
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Poll the authenticated deployment for its bounded identity/approval
    /// envelope.  The response is decoded in Rust so GTK never interprets
    /// untrusted JSON or decides whether approval is required.
    pub fn whoami(&self) -> Result<WhoamiOutcome, SessionError> {
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_whoami(handle, out, capacity, written)
        })?;
        parse_whoami(&bytes).ok_or(SessionError::InvalidInput)
    }

    pub fn read_more(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        let status = mila_ffi::session::mila_session_read_machines(handle, 1);
        if status != mila_ffi::session::SessionStatus::Ok {
            return Err(status.into());
        }
        self.listing()
    }

    /// Execute one authenticated machine mutation through Porsche's closed
    /// command vocabulary. The request id is validated before crossing FFI.
    pub fn machine_action(
        &mut self,
        machine_id: &str,
        action: &str,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if !matches!(action, "start" | "stop" | "pause" | "resume" | "rm")
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(SessionError::InvalidInput);
        }
        if !self.submitted_mutations.insert(request_id.to_owned()) {
            return Err(SessionError::Busy);
        }
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_machine_action(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                action.as_bytes().as_ptr(),
                action.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Create a machine using the authenticated Porsche session.
    pub fn machine_create(
        &mut self,
        name: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        if name.is_empty()
            || name.len() > 128
            || name
                .bytes()
                .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
            || !(1..=256).contains(&cpu)
            || !(128..=4_194_304).contains(&memory)
            || !(1..=16_777_216).contains(&disk)
            || !valid_request_id(request_id)
        {
            return Err(SessionError::InvalidInput);
        }
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_machine_create(
                self.handle()?,
                name.as_bytes().as_ptr(),
                name.len(),
                cpu,
                memory,
                disk,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Resize a machine using the authenticated Porsche session.
    pub fn machine_resize(
        &mut self,
        machine_id: &str,
        cpu: u32,
        memory: u64,
        disk: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if !(1..=256).contains(&cpu)
            || !(128..=4_194_304).contains(&memory)
            || !(1..=16_777_216).contains(&disk)
            || !valid_request_id(request_id)
        {
            return Err(SessionError::InvalidInput);
        }
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_machine_resize(
                self.handle()?,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                cpu,
                memory,
                disk,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Execute an authenticated sharing add/remove mutation with typed role and
    /// request-id validation before crossing the native boundary.
    pub fn share_mutation(
        &mut self,
        machine_id: &str,
        email: &str,
        role: Option<&str>,
        add: bool,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if email.is_empty()
            || email.len() > 320
            || email
                .bytes()
                .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
            || (add && !matches!(role, Some("viewer" | "operator" | "manager")))
            || (!add && role.is_some())
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        let role_bytes = role.map(str::as_bytes).unwrap_or_default();
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_share_mutation(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                email.as_bytes().as_ptr(),
                email.len(),
                role_bytes.as_ptr(),
                role_bytes.len(),
                u8::from(add),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    /// Read or mutate a thread through the authenticated, closed command set.
    /// Response bytes remain bounded inside the Rust session boundary.
    pub fn thread_action(
        &mut self,
        thread: Option<&str>,
        command: &str,
        secondary: Option<&str>,
        input: Option<&str>,
        request_id: Option<&str>,
    ) -> Result<Vec<u8>, SessionError> {
        const ALLOWED_THREAD_COMMANDS: &[&str] = &[
            "thread ls",
            "thread show",
            "thread turns",
            "thread prompt",
            "thread answer",
            "thread plan approve",
            "thread plan revise",
        ];
        if !ALLOWED_THREAD_COMMANDS.contains(&command) {
            return Err(SessionError::InvalidInput);
        }
        for value in [thread, secondary].into_iter().flatten() {
            validate_session_identifier(value)?;
        }
        if let Some(input) = input {
            if input.len() > 64 * 1024 || input.bytes().any(|byte| byte == 0) {
                return Err(SessionError::InvalidInput);
            }
        }
        Self::validate_thread_plan_input(command, input)?;
        if matches!(
            command,
            "thread prompt" | "thread answer" | "thread plan approve" | "thread plan revise"
        ) && thread.is_none()
        {
            return Err(SessionError::InvalidInput);
        }
        if matches!(command, "thread answer") && secondary.is_none() {
            return Err(SessionError::InvalidInput);
        }
        if let Some(request_id) = request_id {
            if request_id.len() != 40
                || !request_id.starts_with("porsche-")
                || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
            {
                return Err(SessionError::InvalidInput);
            }
        }
        if matches!(
            command,
            "thread prompt" | "thread answer" | "thread plan approve" | "thread plan revise"
        ) && request_id.is_none()
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        let empty = std::ptr::null();
        let (thread_ptr, thread_len) =
            thread.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        let (secondary_ptr, secondary_len) =
            secondary.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        let (input_ptr, input_len) =
            input.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        let (request_ptr, request_len) =
            request_id.map_or((empty, 0), |value| (value.as_bytes().as_ptr(), value.len()));
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_thread_action(
                handle,
                thread_ptr,
                thread_len,
                command.as_bytes().as_ptr(),
                command.len(),
                secondary_ptr,
                secondary_len,
                input_ptr,
                input_len,
                request_ptr,
                request_len,
                out,
                capacity,
                written,
            )
        })
    }

    /// Enforce the closed input contract for plan approval commands before FFI.
    fn validate_thread_plan_input(command: &str, input: Option<&str>) -> Result<(), SessionError> {
        match command {
            "thread plan approve" if input.is_some() => Err(SessionError::InvalidInput),
            "thread plan revise" if input.is_none_or(str::is_empty) => {
                Err(SessionError::InvalidInput)
            }
            _ => Ok(()),
        }
    }

    /// Read one machine (`show MACHINE --json`) as bounded JSON.
    pub fn machine_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        self.machine_read(machine_id, mila_ffi::session::mila_session_machine_show)
    }

    /// Read a machine's owner and grants (`share show MACHINE --json`).
    pub fn share_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        self.machine_read(machine_id, mila_ffi::session::mila_session_share_show)
    }

    fn machine_read(
        &mut self,
        machine_id: &str,
        read: unsafe extern "C" fn(
            u64,
            *const u8,
            usize,
            *mut u8,
            usize,
            *mut usize,
        ) -> mila_ffi::session::SessionStatus,
    ) -> Result<Vec<u8>, SessionError> {
        validate_session_identifier(machine_id)?;
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            read(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Read one mutation receipt by its request id (`request show`).
    pub fn request_show(&mut self, request_id: &str) -> Result<Vec<u8>, SessionError> {
        if !valid_request_id(request_id) {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_request_show(
                handle,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Read a machine-bound web endpoint through the authenticated session.
    /// The response remains bounded and owned by the Rust adapter.
    pub fn web_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        validate_session_identifier(machine_id)?;
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_web_show(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Change a machine web endpoint using its optimistic policy revision.
    pub fn web_set(
        &mut self,
        machine_id: &str,
        port: u16,
        public: bool,
        revision: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if port == 0
            || revision == 0
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_web_set(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                port,
                u8::from(public),
                revision,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        if status == mila_ffi::session::SessionStatus::Ok {
            Ok(())
        } else {
            Err(status.into())
        }
    }

    /// Read authenticated push notification devices. Provider registration is
    /// intentionally host-owned; this method covers list and preference CRUD.
    pub fn device_list(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_device_ls(handle, out, capacity, written)
        })
    }

    pub fn device_remove(&mut self, device_id: &str) -> Result<(), SessionError> {
        validate_session_identifier(device_id)?;
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_device_rm(
                handle,
                device_id.as_bytes().as_ptr(),
                device_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn device_preference(
        &mut self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), SessionError> {
        validate_session_identifier(device_id)?;
        let handle = self.handle()?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_device_prefs(
                handle,
                device_id.as_bytes().as_ptr(),
                device_id.len(),
                u8::from(enabled),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn close(&mut self) -> Result<(), SessionError> {
        if let Some(terminal) = self.terminal.take() {
            let _ = mila_ffi::session::mila_session_terminal_kill(terminal);
        }
        let Some(handle) = self.handle.take() else {
            return Ok(());
        };
        let status = mila_ffi::session::mila_session_close(handle);
        if status == mila_ffi::session::SessionStatus::Ok {
            Ok(())
        } else {
            Err(status.into())
        }
    }

    pub fn is_open(&self) -> bool {
        self.handle.is_some()
    }

    /// A `Send` identity probe for this session's handle, used by the sign-in
    /// driver's heartbeat off the GTK main thread. It carries no authority
    /// beyond `whoami`: a closed or replaced session makes it fail stale.
    pub fn probe(&self) -> Option<SessionProbe> {
        self.handle.map(SessionProbe)
    }

    /// Open one authenticated PTY on a named terminal session of `machine_id`.
    /// Without `session_id`, `terminal new` first opens or rejoins the
    /// caller's personal session; Porsche refuses an unnamed attach.
    pub fn terminal_attach(
        &mut self,
        machine_id: &str,
        session_id: Option<&str>,
        columns: u16,
        rows: u16,
    ) -> Result<u64, SessionError> {
        validate_session_identifier(machine_id)?;
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return Err(SessionError::InvalidInput);
        }
        if self.terminal.is_some() {
            return Err(SessionError::Busy);
        }
        let session_id = match session_id {
            Some(session_id) => {
                validate_session_identifier(session_id)?;
                session_id.to_owned()
            }
            None => self.terminal_new(machine_id)?,
        };
        let handle = self.handle()?;
        let mut terminal = 0_u64;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call, each out-pointer is a writable local (or owned buffer
        // of the declared length) that outlives it, and the C ABI retains none.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_attach_session(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                session_id.as_bytes().as_ptr(),
                session_id.len(),
                u32::from(columns),
                u32::from(rows),
                &raw mut terminal,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || terminal == 0 {
            return Err(status.into());
        }
        self.terminal = Some(terminal);
        Ok(terminal)
    }

    /// `terminal new MACHINE`: the id of the caller's personal session,
    /// opened or rejoined.
    pub fn terminal_new(&mut self, machine_id: &str) -> Result<String, SessionError> {
        validate_session_identifier(machine_id)?;
        let request_id = crate::adapter::new_request_id().ok_or(SessionError::Unavailable)?;
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_terminal_new(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
                out,
                capacity,
                written,
            )
        })?;
        let result =
            crate::porsche_results::result_value(&bytes).map_err(|_| SessionError::InvalidInput)?;
        let session_id = result
            .get("session_id")
            .and_then(serde_json::Value::as_str)
            .ok_or(SessionError::InvalidInput)?;
        validate_session_identifier(session_id)?;
        Ok(session_id.to_owned())
    }

    /// @cc [owner:ghuntley,label:security;protocol] linux-session-terminal-end
    /// `terminal kill MACHINE SESSION`: Marshall closes the named server
    /// session for everyone attached and ends its programs. Returns `true`
    /// only when Marshall reports that exact session closed. Any local PTY
    /// on this session is closed first, so no stale channel outlives it.
    pub fn terminal_end(
        &mut self,
        machine_id: &str,
        session_id: &str,
        request_id: &str,
    ) -> Result<bool, SessionError> {
        validate_session_identifier(machine_id)?;
        validate_session_identifier(session_id)?;
        if !valid_request_id(request_id) {
            return Err(SessionError::InvalidInput);
        }
        if !self.submitted_mutations.insert(request_id.to_owned()) {
            return Err(SessionError::Busy);
        }
        let _ = self.terminal_kill();
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_terminal_end(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                session_id.as_bytes().as_ptr(),
                session_id.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
                out,
                capacity,
                written,
            )
        })?;
        Ok(terminal_closed(&bytes, session_id))
    }

    /// @cc [owner:ghuntley,label:security;protocol] linux-session-last-refusal
    /// The most recent closed refusal code Porsche returned on this session.
    /// Only a short lower-case identifier is returned; anything else is `None`.
    pub fn last_refusal(&self) -> Option<String> {
        let handle = self.handle().ok()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_last_refusal(handle, out, capacity, written)
        })
        .ok()?;
        let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
        let code = value.get("error")?.as_str()?;
        (!code.is_empty()
            && code.len() <= 64
            && code
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'))
        .then(|| code.to_owned())
    }

    /// Poll a bounded output chunk from the authenticated PTY.
    pub fn terminal_poll(&mut self) -> Result<Vec<u8>, SessionError> {
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        let mut output = vec![0_u8; 65_536];
        let mut written = 0_usize;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call, each out-pointer is a writable local (or owned buffer
        // of the declared length) that outlives it, and the C ABI retains none.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_poll(
                terminal,
                output.as_mut_ptr(),
                output.len(),
                &raw mut written,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || written > output.len() {
            return Err(status.into());
        }
        output.truncate(written);
        Ok(output)
    }

    /// The PTY handle opened by [`Self::terminal_attach`], if still open.
    pub const fn terminal_handle(&self) -> Option<u64> {
        self.terminal
    }

    /// Reads at most one chunk, waiting no longer than `wait_ms` (at most
    /// 1000). A closed channel releases its handle so a new attach can follow.
    pub fn terminal_read(&mut self, wait_ms: u32) -> Result<TerminalChunk, SessionError> {
        if wait_ms > 1_000 {
            return Err(SessionError::InvalidInput);
        }
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        let capacity = mila_ffi::session::MILA_TERMINAL_READ_CAPACITY;
        if self.read_buffer.len() != capacity {
            self.read_buffer = vec![0_u8; capacity];
        }
        let mut written = 0_usize;
        let mut event = TerminalReadEvent::Idle;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call, each out-pointer is a writable local (or owned buffer
        // of the declared length) that outlives it, and the C ABI retains none.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_read_within(
                terminal,
                wait_ms,
                self.read_buffer.as_mut_ptr(),
                self.read_buffer.len(),
                &raw mut written,
                &raw mut event,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || written > capacity {
            return Err(status.into());
        }
        match event {
            TerminalReadEvent::Data if written > 0 => {
                Ok(TerminalChunk::Data(self.read_buffer[..written].to_vec()))
            }
            TerminalReadEvent::Data | TerminalReadEvent::Idle => Ok(TerminalChunk::Idle),
            TerminalReadEvent::Closed => {
                let _ = self.terminal_kill();
                Ok(TerminalChunk::Closed)
            }
        }
    }

    pub fn terminal_input(&mut self, input: &[u8]) -> Result<(), SessionError> {
        if input.len() > (1 << 20) {
            return Err(SessionError::InvalidInput);
        }
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_input(terminal, input.as_ptr(), input.len())
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn terminal_resize(&mut self, columns: u16, rows: u16) -> Result<(), SessionError> {
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return Err(SessionError::InvalidInput);
        }
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        let status = mila_ffi::session::mila_session_terminal_resize(
            terminal,
            u32::from(columns),
            u32::from(rows),
        );
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn terminal_kill(&mut self) -> Result<(), SessionError> {
        let Some(terminal) = self.terminal.take() else {
            return Ok(());
        };
        let status = mila_ffi::session::mila_session_terminal_kill(terminal);
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    fn handle(&self) -> Result<u64, SessionError> {
        self.handle.ok_or(SessionError::StaleHandle)
    }
}

/// @cc [owner:ghuntley,label:security;reliability] linux-session-probe-identity-only
/// A probe MUST expose only the bounded `whoami` read of the handle it was
/// taken from and MUST report a stale handle once that session closes; it
/// MUST NOT open, mutate or extend the session it observes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SessionProbe(u64);

impl SessionProbe {
    pub fn whoami(&self) -> Result<WhoamiOutcome, SessionError> {
        let handle = self.0;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_whoami(handle, out, capacity, written)
        })?;
        parse_whoami(&bytes).ok_or(SessionError::InvalidInput)
    }

    /// Closes the observed FFI session as a transport loss would, leaving the
    /// owning [`LiveSession`] to discover a stale handle. Used by recovery
    /// tests and the GTK journey to exercise reconnect without a network
    /// fault.
    pub fn sever(self) {
        let _ = mila_ffi::session::mila_session_close(self.0);
    }
}

fn parse_whoami(bytes: &[u8]) -> Option<WhoamiOutcome> {
    let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    if value.get("version").and_then(serde_json::Value::as_u64) != Some(1) {
        return None;
    }
    // Porsche reports an approved key as the `succeeded` envelope with the
    // account in `result.email`, and a pending key as `approval_required`
    // with `approval_url`. The older `authenticated`/`account` and `url`
    // spellings are still accepted.
    match value.get("status").and_then(serde_json::Value::as_str)? {
        "succeeded" | "authenticated" => {
            let account = value
                .pointer("/result/email")
                .or_else(|| value.get("account"))
                .and_then(serde_json::Value::as_str)?;
            (!account.is_empty() && account.len() <= 320).then(|| WhoamiOutcome::Authenticated {
                account: account.to_owned(),
            })
        }
        "approval_required" => {
            let url = value
                .get("approval_url")
                .or_else(|| value.get("url"))
                .and_then(serde_json::Value::as_str)?;
            let fingerprint = value
                .get("fingerprint")
                .and_then(serde_json::Value::as_str)?;
            ApprovalInfo::validate(url, fingerprint, 0)
                .ok()
                .map(|_| WhoamiOutcome::Approval {
                    url: url.to_owned(),
                    fingerprint: fingerprint.to_owned(),
                })
        }
        "refused" => Some(WhoamiOutcome::Refused),
        "unavailable" => Some(WhoamiOutcome::Unavailable),
        _ => Some(WhoamiOutcome::Protocol),
    }
}

impl Drop for LiveSession {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

/// @cc [owner:ghuntley,label:protocol;reliability] linux-session-single-call-output
/// Many session FFI calls run their remote command on every invocation, so
/// output MUST be copied with exactly one call into a buffer of the maximum
/// bounded size; a size probe followed by a read would run a read twice and
/// submit a mutation twice. A response larger than the bound fails.
fn copy_output(
    call: impl FnOnce(*mut u8, usize, *mut usize) -> mila_ffi::session::SessionStatus,
) -> Result<Vec<u8>, SessionError> {
    let mut bytes = vec![0_u8; MAX_LISTING_BYTES];
    let mut size = 0_usize;
    let status = call(bytes.as_mut_ptr(), bytes.len(), &raw mut size);
    if status != mila_ffi::session::SessionStatus::Ok || size == 0 || size > bytes.len() {
        return Err(status.into());
    }
    bytes.truncate(size);
    Ok(bytes)
}

/// Whether a `terminal kill` result reports `session_id` closed.
fn terminal_closed(bytes: &[u8], session_id: &str) -> bool {
    crate::porsche_results::result_value(bytes).is_ok_and(|result| {
        result.get("closed") == Some(&serde_json::Value::Bool(true))
            && result.get("session_id").and_then(serde_json::Value::as_str) == Some(session_id)
    })
}

fn validate_session_identifier(value: &str) -> Result<(), SessionError> {
    if value.is_empty()
        || value.len() > 128
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace() || byte == 0)
    {
        return Err(SessionError::InvalidInput);
    }
    Ok(())
}

fn valid_request_id(value: &str) -> bool {
    value.len() == 40
        && value.starts_with("porsche-")
        && value.as_bytes()[8..].iter().all(u8::is_ascii_hexdigit)
}

/// @cc [owner:ghuntley,label:security;terminal] linux-session-pty-backend
/// The backend MUST operate only on the PTY handle it opened through the
/// currently bound authenticated session, MUST refuse every channel operation
/// when no session is bound or the handle differs, and MUST decode PTY bytes
/// into display text before they leave the backend.
///
/// [`HostPtyBackend`](crate::terminal::HostPtyBackend) over the authenticated
/// FFI session held by the GTK window or the headless journey driver.
pub struct SessionPtyBackend {
    binding: std::rc::Rc<std::cell::RefCell<SessionBinding>>,
    decoder: crate::terminal_text::PtyTextDecoder,
    wait_ms: u32,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for SessionPtyBackend {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionPtyBackend")
            .finish_non_exhaustive()
    }
}

impl SessionPtyBackend {
    /// `wait_ms` bounds how long one read may block the caller (at most 1000).
    pub fn new(binding: std::rc::Rc<std::cell::RefCell<SessionBinding>>, wait_ms: u32) -> Self {
        Self {
            binding,
            decoder: crate::terminal_text::PtyTextDecoder::new(),
            wait_ms: wait_ms.min(1_000),
        }
    }

    fn with_channel<R>(
        &mut self,
        channel: u64,
        operation: impl FnOnce(&mut LiveSession) -> Result<R, SessionError>,
    ) -> Result<R, crate::terminal::PtyError> {
        use crate::terminal::PtyError;
        let mut binding = self
            .binding
            .try_borrow_mut()
            .map_err(|_| PtyError::Transport)?;
        let live = binding.session_mut().ok_or(PtyError::Unauthenticated)?;
        if live.terminal_handle() != Some(channel) {
            return Err(PtyError::InvalidRequest);
        }
        operation(live).map_err(|error| match error {
            SessionError::InvalidInput => PtyError::InvalidRequest,
            SessionError::StaleHandle => PtyError::Unauthenticated,
            _ => PtyError::Transport,
        })
    }
}

impl crate::terminal::HostPtyBackend for SessionPtyBackend {
    fn attach(
        &mut self,
        request: &crate::terminal::PtyAttachRequest,
    ) -> Result<u64, crate::terminal::PtyError> {
        use crate::terminal::PtyError;
        let mut binding = self
            .binding
            .try_borrow_mut()
            .map_err(|_| PtyError::Transport)?;
        let live = binding.session_mut().ok_or(PtyError::Unauthenticated)?;
        if !live.is_open() {
            return Err(PtyError::Unauthenticated);
        }
        let session = (!request.session_id.is_empty()).then_some(request.session_id.as_str());
        let channel = live
            .terminal_attach(&request.machine_id, session, request.columns, request.rows)
            .map_err(|error| match error {
                SessionError::InvalidInput => PtyError::InvalidRequest,
                _ => PtyError::Transport,
            })?;
        self.decoder = crate::terminal_text::PtyTextDecoder::new();
        Ok(channel)
    }

    fn read_output(
        &mut self,
        channel: u64,
    ) -> Result<crate::terminal::PtyRead, crate::terminal::PtyError> {
        use crate::terminal::PtyRead;
        let wait_ms = self.wait_ms;
        match self.with_channel(channel, |live| live.terminal_read(wait_ms))? {
            TerminalChunk::Data(bytes) => Ok(PtyRead::Text(self.decoder.decode(&bytes))),
            TerminalChunk::Idle => Ok(PtyRead::Idle),
            TerminalChunk::Closed => Ok(PtyRead::Eof),
        }
    }

    fn send_input(&mut self, channel: u64, input: &[u8]) -> Result<(), crate::terminal::PtyError> {
        self.with_channel(channel, |live| live.terminal_input(input))
    }

    fn resize(
        &mut self,
        channel: u64,
        columns: u16,
        rows: u16,
    ) -> Result<(), crate::terminal::PtyError> {
        self.with_channel(channel, |live| live.terminal_resize(columns, rows))
    }

    fn kill(&mut self, channel: u64) -> Result<(), crate::terminal::PtyError> {
        self.with_channel(channel, LiveSession::terminal_kill)
    }
}

/// The one session authority presented to the rest of the native UI.
#[derive(Default)]
pub struct SessionBinding {
    session: Option<LiveSession>,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for SessionBinding {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionBinding")
            .finish_non_exhaustive()
    }
}

impl SessionBinding {
    pub fn bind(&mut self, session: LiveSession) {
        self.clear();
        self.session = Some(session);
    }
    pub fn clear(&mut self) {
        if let Some(mut session) = self.session.take() {
            let _ = session.close();
        }
    }
    pub fn session(&self) -> Option<&LiveSession> {
        self.session.as_ref()
    }
    pub fn session_mut(&mut self) -> Option<&mut LiveSession> {
        self.session.as_mut()
    }
    pub fn is_authenticated(&self) -> bool {
        self.session.as_ref().is_some_and(LiveSession::is_open)
    }
}

/// Storage used by enrollment. Implementations must use owner-only, atomic files.
pub trait TrustStore {
    fn read(&self, host: &str) -> Result<Option<Vec<u8>>, RuntimeError>;
    fn write(&self, host: &str, document: &[u8]) -> Result<(), RuntimeError>;
}

/// Owner-only trust store used by the GTK host. Files are keyed by a reversible
/// hexadecimal encoding of the authority, so deployment input can never become
/// a path component or traversal sequence.
#[derive(Clone, Debug, Default)]
pub struct XdgTrustStore;

impl XdgTrustStore {
    fn path(host: &str) -> Result<std::path::PathBuf, RuntimeError> {
        validate_session_endpoint(host, 443, 1_000)?;
        let root = std::env::var_os("XDG_CONFIG_HOME")
            .map(std::path::PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(".config"))
            })
            .ok_or(RuntimeError::Unavailable)?;
        let mut key = String::with_capacity(host.len() * 2);
        for byte in host.bytes() {
            write!(key, "{byte:02x}").map_err(|_| RuntimeError::Unavailable)?;
        }
        Ok(root.join("mila").join("trust").join(key))
    }
}

impl TrustStore for XdgTrustStore {
    fn read(&self, host: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
        let path = Self::path(host)?;
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(RuntimeError::Unavailable),
        };
        if !metadata.file_type().is_file() {
            return Err(RuntimeError::InvalidInput);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if metadata.permissions().mode() & 0o077 != 0 {
                return Err(RuntimeError::InvalidInput);
            }
        }
        let bytes = std::fs::read(path).map_err(|_| RuntimeError::Unavailable)?;
        if bytes.is_empty() || bytes.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(Some(bytes))
    }

    fn write(&self, host: &str, document: &[u8]) -> Result<(), RuntimeError> {
        if document.is_empty() || document.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        let path = Self::path(host)?;
        let parent = path.parent().ok_or(RuntimeError::Unavailable)?;
        std::fs::create_dir_all(parent).map_err(|_| RuntimeError::Unavailable)?;
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, document).map_err(|_| RuntimeError::Unavailable)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| RuntimeError::Unavailable)?;
        }
        std::fs::rename(temporary, path).map_err(|_| RuntimeError::Unavailable)
    }
}

/// Fetches `/bin/ssh-trust.json` over HTTPS with redirects refused.
pub trait TrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError>;
}

/// Production Linux HTTPS trust fetcher.  `curl` is used from the host image so
/// certificate validation, proxy policy, and CA updates remain owned by the
/// distribution.  Redirects are explicitly disabled: a deployment authority
/// may only serve its trust document from its own HTTPS origin.
#[derive(Clone, Copy, Debug, Default)]
pub struct CurlTrustFetcher {
    pub timeout_seconds: u32,
}

impl TrustFetcher for CurlTrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError> {
        if host.contains(['/', '?', '#', ':']) {
            return Err(RuntimeError::InvalidInput);
        }
        validate_session_endpoint(
            host,
            443,
            self.timeout_seconds.saturating_mul(1_000).max(1_000),
        )?;
        let timeout = self.timeout_seconds.clamp(1, 120);
        let url = format!("https://{host}/bin/ssh-trust.json");
        let output = std::process::Command::new("curl")
            .args([
                "--fail",
                "--silent",
                "--show-error",
                "--proto",
                "=https",
                "--max-redirs",
                "0",
                "--max-time",
                &timeout.to_string(),
                &url,
            ])
            .output()
            .map_err(|_| RuntimeError::Unavailable)?;
        if !output.status.success() {
            return Err(RuntimeError::Unavailable);
        }
        if output.stdout.is_empty() || output.stdout.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(output.stdout)
    }
}

/// HTTPS trust fetch for a deployment on an explicit port, optionally with a
/// private CA bundle (connection profiles and the hermetic fixture).
/// Redirects are refused and only `https` is allowed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpsTrustFetcher {
    pub ca_path: Option<std::path::PathBuf>,
    pub server_name: String,
    pub host: String,
    pub https_port: u16,
}

impl HttpsTrustFetcher {
    /// curl arguments; contains no credential.
    pub fn arguments(&self) -> Vec<String> {
        let port = self.https_port;
        let mut arguments = [
            "--fail",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--max-redirs",
            "0",
            "--max-time",
            "20",
        ]
        .map(str::to_owned)
        .to_vec();
        if let Some(ca_path) = &self.ca_path {
            arguments.push("--cacert".to_owned());
            arguments.push(ca_path.display().to_string());
        }
        if self.server_name != self.host {
            arguments.push("--connect-to".to_owned());
            arguments.push(format!("{}:{port}:{}:{port}", self.server_name, self.host));
        }
        arguments.push(format!(
            "https://{}:{port}/bin/ssh-trust.json",
            self.server_name
        ));
        arguments
    }
}

impl TrustFetcher for HttpsTrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError> {
        if host != self.host || self.https_port == 0 {
            return Err(RuntimeError::InvalidInput);
        }
        let output = std::process::Command::new("curl")
            .args(self.arguments())
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|_| RuntimeError::Unavailable)?;
        if !output.status.success() {
            return Err(RuntimeError::Unavailable);
        }
        if output.stdout.is_empty() || output.stdout.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(output.stdout)
    }
}

/// Rust-owned trust enrollment. Only canonical bytes selected by the FFI are persisted.
pub struct TrustEnrollment<S, F> {
    pub store: S,
    pub fetcher: F,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl<S, F> std::fmt::Debug for TrustEnrollment<S, F> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TrustEnrollment")
            .finish_non_exhaustive()
    }
}

impl<S: TrustStore, F: TrustFetcher> TrustEnrollment<S, F> {
    /// @cc [owner:ghuntley,label:security] linux-trust-enrollment-order
    /// Enrollment MUST reconcile fetched and pinned documents in Rust and persist
    /// only the canonical result. A failed fetch may use a current pin; malformed
    /// or conflicting fetched bytes MUST fail closed. Only an unavailable HTTPS
    /// transport may fall back to a current pin; fetch validation errors MUST
    /// be returned.
    pub fn resolve(&self, host: &str, now: u64) -> Result<Vec<u8>, RuntimeError> {
        let pinned = self.store.read(host)?;
        let fetched = match self.fetcher.fetch(host) {
            Ok(document) => Some(document),
            Err(RuntimeError::Unavailable) => None,
            Err(RuntimeError::InvalidInput) => return Err(RuntimeError::InvalidInput),
        };
        let mut output = vec![0_u8; MAX_TRUST_BYTES];
        let mut written = 0_usize;
        let origin = std::ffi::CString::new(host).map_err(|_| RuntimeError::InvalidInput)?;
        // SAFETY: the optional documents are live Rust slices or null with length
        // zero, `origin` is NUL-terminated, and `output`/`written` are writable
        // locals of the declared capacity that outlive this synchronous call.
        let status = unsafe {
            mila_ffi::mila_trust_document_reconcile(
                pinned.as_deref().map_or(std::ptr::null(), <[u8]>::as_ptr),
                pinned.as_ref().map_or(0, Vec::len),
                fetched.as_deref().map_or(std::ptr::null(), <[u8]>::as_ptr),
                fetched.as_ref().map_or(0, Vec::len),
                origin.as_ptr(),
                now,
                MilaRouteOutput {
                    bytes: output.as_mut_ptr(),
                    capacity: output.len(),
                    written: &raw mut written,
                },
            )
        };
        if status != MilaFfiStatus::Ok || written == 0 || written > output.len() {
            return Err(RuntimeError::InvalidInput);
        }
        output.truncate(written);
        if pinned.as_deref() != Some(output.as_slice()) {
            self.store.write(host, &output)?;
        }
        Ok(output)
    }
}

/// Rust-owned sign-in planning and connection orchestration for the Linux host.
/// The host supplies only the signer and I/O traits; trust selection and the
/// session configuration remain inside this module.
pub struct SignInCoordinator<S, T, F> {
    signer: S,
    enrollment: TrustEnrollment<T, F>,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl<S, T, F> std::fmt::Debug for SignInCoordinator<S, T, F> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SignInCoordinator")
            .finish_non_exhaustive()
    }
}

impl<S: DeviceSigner, T: TrustStore, F: TrustFetcher> SignInCoordinator<S, T, F> {
    pub fn new(signer: S, store: T, fetcher: F) -> Self {
        Self {
            signer,
            enrollment: TrustEnrollment { store, fetcher },
        }
    }

    /// @cc [owner:ghuntley,label:security] linux-signin-coordinator-order
    /// Sign-in MUST validate the endpoint before invoking host storage or HTTPS,
    /// reconcile trust entirely in Rust, and pass only the selected trust bytes
    /// to session connection. A failed plan MUST NOT invoke the device signer.
    pub fn prepare_connect(
        &self,
        host: &str,
        port: u16,
        timeout_ms: u32,
        now: u64,
    ) -> Result<SessionConnectConfig, RuntimeError> {
        validate_session_endpoint(host, port, timeout_ms)?;
        let trust_document = self.enrollment.resolve(host, now)?;
        let config = SessionConnectConfig {
            trust_document,
            host: host.to_owned(),
            port,
            timeout_ms,
        };
        config.validate()?;
        Ok(config)
    }

    pub fn connect(
        &self,
        host: &str,
        port: u16,
        timeout_ms: u32,
        now: u64,
    ) -> Result<LiveSession, SessionError> {
        let config =
            self.prepare_connect(host, port, timeout_ms, now)
                .map_err(|error| match error {
                    RuntimeError::InvalidInput => SessionError::InvalidInput,
                    RuntimeError::Unavailable => SessionError::Transport,
                })?;
        LiveSession::connect(&config, &self.signer)
    }
}

/// Browser approval state retained without persisting URLs, tokens or fingerprints.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ApprovalState {
    #[default]
    NotRequired,
    Pending,
    Approved,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignInPhase {
    SignedOut,
    Connecting,
    AwaitingApproval,
    SignedIn,
    Disconnected,
    Expired,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignInFailure {
    DeviceKey,
    HostUntrusted,
    Refused,
    Protocol,
    Unreachable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalInfo {
    pub url: String,
    pub fingerprint: String,
    pub issued_at: u64,
}

impl ApprovalInfo {
    /// @cc [owner:ghuntley,label:security;navigation] linux-approval-url-authority
    /// An approval URL MUST be HTTPS with a DNS host and an optional canonical
    /// non-zero port, and MUST NOT carry userinfo, a fragment or whitespace.
    /// `validate_for_host` MUST compare the full authority, treating an
    /// explicit `:443` as the default port, so a different host or port fails.
    pub fn validate(url: &str, fingerprint: &str, issued_at: u64) -> Result<Self, RuntimeError> {
        let valid_url = url.len() <= 2048
            && approval_authority(url).is_some()
            && url
                .get(8..)
                .is_some_and(|rest| !rest.contains(['@', '#', ' ', '\t', '\n', '\r']));
        if !valid_url
            || fingerprint.is_empty()
            || fingerprint.len() > 256
            || fingerprint
                .bytes()
                .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
        {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(Self {
            url: url.to_owned(),
            fingerprint: fingerprint.to_owned(),
            issued_at,
        })
    }

    /// Validate that a browser approval remains on the selected deployment
    /// authority.  The URL is untrusted input even after the envelope parser
    /// accepts it; opening a different HTTPS origin would let a copied link
    /// steer the native client to another deployment. `expected_authority` is
    /// `host` or `host:port`.
    pub fn validate_for_host(
        url: &str,
        fingerprint: &str,
        issued_at: u64,
        expected_authority: &str,
    ) -> Result<Self, RuntimeError> {
        let info = Self::validate(url, fingerprint, issued_at)?;
        let actual = approval_authority(&info.url).ok_or(RuntimeError::InvalidInput)?;
        let expected =
            parse_https_authority(expected_authority).ok_or(RuntimeError::InvalidInput)?;
        if actual != expected {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(info)
    }
}

/// `(host, port)` of an `https://` URL, with the default port made explicit.
fn approval_authority(url: &str) -> Option<(String, u16)> {
    let authority = url.strip_prefix("https://")?.split(['/', '?']).next()?;
    parse_https_authority(authority)
}

fn parse_https_authority(authority: &str) -> Option<(String, u16)> {
    let (host, port) = match authority.split_once(':') {
        Some((host, port)) => {
            let parsed = port.parse::<u16>().ok()?;
            (parsed != 0 && parsed.to_string() == port).then_some((host, parsed))?
        }
        None => (authority, 443),
    };
    let valid_host = !host.is_empty()
        && host.len() <= 253
        && host
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-'));
    valid_host.then(|| (host.to_ascii_lowercase(), port))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignInFlow {
    pub phase: SignInPhase,
    pub generation: u64,
    pub approval: Option<ApprovalInfo>,
    pub account: Option<String>,
    pub failure: Option<SignInFailure>,
}

impl Default for SignInFlow {
    fn default() -> Self {
        Self {
            phase: SignInPhase::SignedOut,
            generation: 0,
            approval: None,
            account: None,
            failure: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WhoamiOutcome {
    Authenticated { account: String },
    Approval { url: String, fingerprint: String },
    Refused,
    Unavailable,
    Protocol,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SignInEvent {
    Start,
    Connected(u64),
    HostRejected(u64),
    Whoami {
        generation: u64,
        outcome: WhoamiOutcome,
        at: u64,
    },
    Unreachable(u64),
    DeviceKeyUnavailable(u64),
    Disconnected(u64),
    SignOut,
    Tick(u64),
}

impl SignInFlow {
    #[must_use]
    pub fn apply(mut self, event: SignInEvent) -> Self {
        match event {
            SignInEvent::Start
                if !matches!(self.phase, SignInPhase::SignedIn | SignInPhase::Connecting) =>
            {
                self.generation = self.generation.saturating_add(1);
                self.phase = SignInPhase::Connecting;
                self.approval = None;
                self.failure = None;
            }
            SignInEvent::Connected(g) if g == self.generation => {}
            SignInEvent::HostRejected(g) if g == self.generation => {
                self.fail(SignInFailure::HostUntrusted);
            }
            SignInEvent::Unreachable(g)
                if g == self.generation
                    && matches!(
                        self.phase,
                        SignInPhase::Connecting | SignInPhase::AwaitingApproval
                    ) =>
            {
                self.fail(SignInFailure::Unreachable);
            }
            SignInEvent::DeviceKeyUnavailable(g)
                if g == self.generation && self.phase == SignInPhase::Connecting =>
            {
                self.fail(SignInFailure::DeviceKey);
            }
            SignInEvent::Disconnected(g) if g == self.generation => match self.phase {
                SignInPhase::AwaitingApproval | SignInPhase::Connecting => {
                    self.phase = SignInPhase::Expired;
                    self.approval = None;
                }
                SignInPhase::SignedIn => self.phase = SignInPhase::Disconnected,
                _ => {}
            },
            SignInEvent::Whoami {
                generation,
                outcome,
                at,
            } if generation == self.generation => match outcome {
                WhoamiOutcome::Authenticated { account }
                    if matches!(
                        self.phase,
                        SignInPhase::Connecting | SignInPhase::AwaitingApproval
                    ) =>
                {
                    self.phase = SignInPhase::SignedIn;
                    self.account = Some(account);
                    self.approval = None;
                }
                WhoamiOutcome::Approval { url, fingerprint }
                    if self.phase != SignInPhase::AwaitingApproval =>
                {
                    match ApprovalInfo::validate(&url, &fingerprint, at) {
                        Ok(info) => {
                            self.phase = SignInPhase::AwaitingApproval;
                            self.approval = Some(info);
                        }
                        Err(_) => self.fail(SignInFailure::Protocol),
                    }
                }
                WhoamiOutcome::Refused => self.fail(SignInFailure::Refused),
                WhoamiOutcome::Protocol => self.fail(SignInFailure::Protocol),
                _ => {}
            },
            SignInEvent::Tick(now)
                if self.phase == SignInPhase::AwaitingApproval
                    && self
                        .approval
                        .as_ref()
                        .is_some_and(|a| now.saturating_sub(a.issued_at) >= 600) =>
            {
                self.phase = SignInPhase::Expired;
                self.approval = None;
            }
            SignInEvent::SignOut => {
                self.generation = self.generation.saturating_add(1);
                self.phase = SignInPhase::SignedOut;
                self.approval = None;
                self.account = None;
                self.failure = None;
            }
            _ => {}
        }
        self
    }
    fn fail(&mut self, failure: SignInFailure) {
        self.phase = SignInPhase::Failed;
        self.failure = Some(failure);
        self.approval = None;
    }
}

#[cfg(test)]
mod tests {
    // See the `linux-session-terminal-end` contract.
    #[test]
    fn terminal_end_requires_marshall_to_close_that_exact_session() {
        let closed = br#"{"version":1,"status":"succeeded","result":{"machine_id":"m","session_id":"s-1","closed":true}}"#;
        assert!(terminal_closed(closed, "s-1"));
        assert!(!terminal_closed(closed, "s-2"));
        let open =
            br#"{"version":1,"status":"succeeded","result":{"session_id":"s-1","closed":false}}"#;
        assert!(!terminal_closed(open, "s-1"));
        let refused = br#"{"version":1,"status":"refused","error":"forbidden"}"#;
        assert!(!terminal_closed(refused, "s-1"));
        assert!(!terminal_closed(b"", "s-1"));
    }

    #[test]
    fn output_is_copied_with_exactly_one_ffi_call() {
        use mila_ffi::session::SessionStatus;
        let mut calls = 0;
        let bytes = copy_output(|out, capacity, written| {
            calls += 1;
            let data = b"{\"ok\":true}";
            assert!(capacity >= data.len());
            // SAFETY: `copy_output` passes `out` writable for `capacity` bytes,
            // checked above to hold `data`, which is a distinct static buffer.
            unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), out, data.len()) };
            // SAFETY: `copy_output` passes a writable `written` local.
            unsafe { *written = data.len() };
            SessionStatus::Ok
        })
        .unwrap();
        assert_eq!(calls, 1);
        assert_eq!(bytes, b"{\"ok\":true}");
        // A response over the bound fails without a second (re-executing) call.
        let mut calls = 0;
        let refused = copy_output(|_, capacity, written| {
            calls += 1;
            // SAFETY: `copy_output` passes a writable `written` local.
            unsafe { *written = capacity + 1 };
            SessionStatus::SmallBuffer
        });
        assert!(refused.is_err());
        assert_eq!(calls, 1);
    }

    use super::*;
    use std::cell::RefCell;
    use std::fs;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct MemoryStore {
        pinned: Option<Vec<u8>>,
        reads: Rc<RefCell<usize>>,
        writes: Rc<RefCell<Vec<Vec<u8>>>>,
    }

    impl TrustStore for MemoryStore {
        fn read(&self, _host: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
            *self.reads.borrow_mut() += 1;
            Ok(self.pinned.clone())
        }

        fn write(&self, _host: &str, document: &[u8]) -> Result<(), RuntimeError> {
            self.writes.borrow_mut().push(document.to_vec());
            Ok(())
        }
    }

    struct StaticFetcher {
        response: Result<Vec<u8>, RuntimeError>,
        calls: Rc<RefCell<usize>>,
    }

    impl TrustFetcher for StaticFetcher {
        fn fetch(&self, _host: &str) -> Result<Vec<u8>, RuntimeError> {
            *self.calls.borrow_mut() += 1;
            self.response.clone()
        }
    }

    struct CountingSigner {
        calls: Arc<AtomicUsize>,
    }

    #[test]
    fn file_signer_requires_owner_only_key_and_verifies_signature() {
        use p256::ecdsa::signature::Verifier;
        use std::os::unix::fs::PermissionsExt;

        let path = std::env::temp_dir().join(format!(
            "mila-signer-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        fs::write(&path, [7_u8; 32]).expect("key");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("permissions");
        let signer = FileDeviceSigner::load(&path, "ssh-test-public-key".to_owned()).unwrap();
        let message = b"certificate challenge";
        let signature = signer.sign(message).unwrap();
        let parsed = Signature::from_slice(&signature).unwrap();
        signer.key.verifying_key().verify(message, &parsed).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).expect("permissions");
        assert!(matches!(
            FileDeviceSigner::load(&path, "ssh-test-public-key".to_owned()),
            Err(SignerError::InsecurePermissions)
        ));
        fs::remove_file(path).expect("cleanup");
    }

    impl DeviceSigner for CountingSigner {
        fn public_key(&self) -> &'static str {
            "ssh-test-public-key"
        }

        fn sign(&self, _message: &[u8]) -> Result<[u8; 64], RuntimeError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok([0; 64])
        }
    }

    fn ca(index: usize) -> String {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../rust/mila-transport/tests/fixtures/ssh_host_certificates.json"
        ))
        .expect("certificate fixture");
        fixture["certificates"][index]["ca"]
            .as_str()
            .expect("certificate CA")
            .to_owned()
    }

    fn trust(ca: &str, retirement: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "ca": ca,
            "management_host": "overalls.example",
            "zone": "apps.overalls.example",
            "retirement": retirement,
        }))
        .expect("trust document")
    }

    /// The coordinator under test plus its read, write and signer counters.
    type CoordinatorHarness = (
        SignInCoordinator<CountingSigner, MemoryStore, StaticFetcher>,
        Rc<RefCell<usize>>,
        Rc<RefCell<Vec<Vec<u8>>>>,
        Arc<AtomicUsize>,
    );

    fn coordinator(
        pinned: Option<Vec<u8>>,
        response: Result<Vec<u8>, RuntimeError>,
    ) -> CoordinatorHarness {
        let reads = Rc::new(RefCell::new(0));
        let writes = Rc::new(RefCell::new(Vec::new()));
        let calls = Rc::new(RefCell::new(0));
        let signer_calls = Arc::new(AtomicUsize::new(0));
        (
            SignInCoordinator::new(
                CountingSigner {
                    calls: signer_calls.clone(),
                },
                MemoryStore {
                    pinned,
                    reads,
                    writes: writes.clone(),
                },
                StaticFetcher {
                    response,
                    calls: calls.clone(),
                },
            ),
            calls,
            writes,
            signer_calls,
        )
    }

    #[test]
    fn coordinator_reconciles_fetched_trust_and_persists_canonical_bytes() {
        let pinned = trust(&ca(0), 2_000);
        let fetched = trust(&ca(0), 3_000);
        let (coordinator, fetch_calls, writes, _) = coordinator(Some(pinned), Ok(fetched));
        let config = coordinator
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .expect("trust should reconcile");
        let selected: serde_json::Value =
            serde_json::from_slice(&config.trust_document).expect("canonical trust");
        assert_eq!(selected["retirement"], 3_000);
        assert_eq!(*fetch_calls.borrow(), 1);
        assert_eq!(writes.borrow().len(), 1);
        assert_eq!(writes.borrow()[0], config.trust_document);
    }

    #[test]
    fn coordinator_uses_a_current_pin_when_fetch_is_unavailable() {
        let pinned = trust(&ca(0), 2_000);
        let (coordinator, fetch_calls, writes, _) =
            coordinator(Some(pinned.clone()), Err(RuntimeError::Unavailable));
        let config = coordinator
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .expect("current pin should be usable");
        let selected: serde_json::Value =
            serde_json::from_slice(&config.trust_document).expect("canonical trust");
        assert_eq!(selected["retirement"], 2_000);
        assert_eq!(
            selected["ca"],
            serde_json::from_slice::<serde_json::Value>(&pinned).unwrap()["ca"]
        );
        assert_eq!(*fetch_calls.borrow(), 1);
        assert_eq!(writes.borrow().len(), 1);
        assert_eq!(writes.borrow()[0], config.trust_document);
    }

    #[test]
    fn coordinator_refuses_malformed_or_conflicting_fetched_trust() {
        let malformed = coordinator(None, Ok(br#"{"version":1,"ca":"bad"}"#.to_vec())).0;
        assert_eq!(
            malformed
                .prepare_connect("overalls.example", 443, 30_000, 1_000)
                .unwrap_err(),
            RuntimeError::InvalidInput
        );

        let conflicting = coordinator(Some(trust(&ca(0), 2_000)), Ok(trust(&ca(5), 3_000))).0;
        assert_eq!(
            conflicting
                .prepare_connect("overalls.example", 443, 30_000, 1_000)
                .unwrap_err(),
            RuntimeError::InvalidInput
        );

        let malformed_fetch =
            coordinator(Some(trust(&ca(0), 2_000)), Err(RuntimeError::InvalidInput)).0;
        assert_eq!(
            malformed_fetch
                .prepare_connect("overalls.example", 443, 30_000, 1_000)
                .unwrap_err(),
            RuntimeError::InvalidInput
        );
    }

    #[test]
    fn invalid_endpoint_is_rejected_before_storage_fetch_or_signer() {
        let (coordinator, fetch_calls, writes, signer_calls) =
            coordinator(None, Err(RuntimeError::Unavailable));
        assert!(matches!(
            coordinator.connect("bad host", 443, 30_000, 1_000),
            Err(SessionError::InvalidInput)
        ));
        assert_eq!(*fetch_calls.borrow(), 0);
        assert!(writes.borrow().is_empty());
        assert_eq!(signer_calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn web_set_requires_positive_policy_revision() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        assert_eq!(
            session.web_set(
                "01234567-89ab-cdef-0123-456789abcdef",
                8080,
                true,
                0,
                "porsche-0123456789abcdef0123456789abcdef",
            ),
            Err(SessionError::InvalidInput)
        );
    }

    #[test]
    fn web_controls_require_an_authenticated_handle_and_bounded_request() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        assert_eq!(
            session.web_show("bad machine"),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.web_set(
                "01234567-89ab-cdef-0123-456789abcdef",
                8080,
                true,
                7,
                "request-without-porsche-id"
            ),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.web_set(
                "01234567-89ab-cdef-0123-456789abcdef",
                8080,
                true,
                7,
                "porsche-0123456789abcdef0123456789abcdef"
            ),
            Err(SessionError::StaleHandle)
        );
    }

    #[test]
    fn notification_device_controls_require_authenticated_session() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        assert_eq!(session.device_list(), Err(SessionError::StaleHandle));
        assert_eq!(
            session.device_remove("bad device"),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.device_preference("device-id", false),
            Err(SessionError::StaleHandle)
        );
    }

    #[test]
    fn machine_actions_require_authenticated_session_and_canonical_request() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        assert_eq!(
            session.machine_action(
                "01234567-89ab-cdef-0123-456789abcdef",
                "start",
                "porsche-00000000000000000000000000000000"
            ),
            Err(SessionError::StaleHandle)
        );
        assert_eq!(
            session.machine_action(
                "01234567-89ab-cdef-0123-456789abcdef",
                "start",
                "porsche-00000000000000000000000000000000"
            ),
            Err(SessionError::Busy)
        );
        assert_eq!(
            session.machine_action(
                "01234567-89ab-cdef-0123-456789abcdef",
                "shell",
                "porsche-00000000000000000000000000000000"
            ),
            Err(SessionError::InvalidInput)
        );
    }

    #[test]
    fn machine_create_rejects_unsafe_display_names_before_authentication() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        let request = "porsche-00000000000000000000000000000000";
        assert_eq!(
            session.machine_create("Builder\nEast", 2, 1024, 10, request),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.machine_create("Builder East", 2, 1024, 10, request),
            Err(SessionError::InvalidInput)
        );
    }

    #[test]
    fn sharing_requires_authenticated_session_and_typed_role() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        let request = "porsche-00000000000000000000000000000000";
        assert_eq!(
            session.share_mutation(
                "01234567-89ab-cdef-0123-456789abcdef",
                "user@example.com",
                Some("viewer"),
                true,
                request,
            ),
            Err(SessionError::StaleHandle)
        );
        assert_eq!(
            session.share_mutation(
                "01234567-89ab-cdef-0123-456789abcdef",
                "user@example.com",
                Some("owner"),
                true,
                request,
            ),
            Err(SessionError::InvalidInput)
        );
    }

    #[test]
    fn thread_actions_require_authenticated_session_and_bounded_input() {
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        assert_eq!(
            session.thread_action(None, "thread ls", None, None, None),
            Err(SessionError::StaleHandle)
        );
        assert_eq!(
            session.thread_action(None, "thread arbitrary", None, None, None),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.thread_action(
                None,
                "thread ls",
                None,
                Some(&"x".repeat(64 * 1024 + 1)),
                None
            ),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.thread_action(
                Some("01234567-89ab-cdef-0123-456789abcdef"),
                "thread plan approve",
                None,
                None,
                None,
            ),
            Err(SessionError::InvalidInput)
        );

        // Native mutations must carry both the proposal/question identity and
        // a canonical Porsche request id before they can reach the FFI handle.
        let thread = "01234567-89ab-cdef-0123-456789abcdef";
        let plan = "fedcba98-7654-3210-fedc-ba9876543210";
        let request = "porsche-0123456789abcdef0123456789abcdef";
        assert_eq!(
            session.thread_action(
                Some(thread),
                "thread plan approve",
                Some(plan),
                None,
                Some("bad")
            ),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.thread_action(
                Some(thread),
                "thread answer",
                Some(plan),
                Some("{}"),
                Some(request)
            ),
            Err(SessionError::StaleHandle)
        );
        assert_eq!(
            session.thread_action(
                Some(thread),
                "thread answer",
                Some(plan),
                Some(&"x".repeat(64 * 1024 + 1)),
                Some(request)
            ),
            Err(SessionError::InvalidInput)
        );
    }

    #[test]
    fn plan_commands_have_explicit_input_contract() {
        assert_eq!(
            LiveSession::validate_thread_plan_input("thread plan approve", None),
            Ok(())
        );
        assert_eq!(
            LiveSession::validate_thread_plan_input("thread plan approve", Some("unexpected")),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            LiveSession::validate_thread_plan_input("thread plan revise", Some("updated plan")),
            Ok(())
        );
        assert_eq!(
            LiveSession::validate_thread_plan_input("thread plan revise", Some("")),
            Err(SessionError::InvalidInput)
        );
        let request = "porsche-0123456789abcdef0123456789abcdef";
        assert_eq!(
            LiveSession::validate_thread_plan_input("thread plan approve", None),
            Ok(())
        );
        let mut session = LiveSession {
            handle: None,
            terminal: None,
            submitted_mutations: HashSet::new(),
            read_buffer: Vec::new(),
        };
        assert_eq!(
            session.thread_action(None, "thread prompt", None, Some("q"), Some(request)),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.thread_action(
                Some("thread"),
                "thread answer",
                None,
                Some("a"),
                Some(request)
            ),
            Err(SessionError::InvalidInput)
        );
    }

    #[test]
    fn approval_is_generation_bound_and_expires() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let flow = flow.apply(SignInEvent::Whoami {
            generation: generation + 1,
            outcome: WhoamiOutcome::Approval {
                url: "https://example.test/approve".into(),
                fingerprint: "SHA256:test".into(),
            },
            at: 1,
        });
        assert_eq!(flow.phase, SignInPhase::Connecting);
        let flow = flow.apply(SignInEvent::Whoami {
            generation,
            outcome: WhoamiOutcome::Approval {
                url: "https://example.test/approve".into(),
                fingerprint: "SHA256:test".into(),
            },
            at: 1,
        });
        assert_eq!(flow.phase, SignInPhase::AwaitingApproval);
        assert_eq!(
            flow.apply(SignInEvent::Tick(601)).phase,
            SignInPhase::Expired
        );
    }
    #[test]
    fn sign_out_fences_late_approval_from_previous_generation() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let signed_out = flow.apply(SignInEvent::SignOut);
        let late = signed_out.apply(SignInEvent::Whoami {
            generation,
            outcome: WhoamiOutcome::Authenticated {
                account: "late@example.test".into(),
            },
            at: 1,
        });
        assert_eq!(late.phase, SignInPhase::SignedOut);
        assert_eq!(late.account, None);
        assert_eq!(late.generation, generation + 1);
    }

    #[test]
    fn reconnect_after_disconnect_starts_fresh_generation() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let flow = flow
            .apply(SignInEvent::Whoami {
                generation,
                outcome: WhoamiOutcome::Authenticated {
                    account: "operator@example.test".into(),
                },
                at: 1,
            })
            .apply(SignInEvent::Disconnected(generation));
        assert_eq!(flow.phase, SignInPhase::Disconnected);
        let flow = flow.apply(SignInEvent::Start);
        assert_eq!(
            (flow.phase, flow.generation),
            (SignInPhase::Connecting, generation + 1)
        );
    }
    #[test]
    fn approval_url_validation_rejects_userinfo_and_non_https() {
        assert!(ApprovalInfo::validate("http://example.test/a", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://user@example.test/a", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://?approval", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://:443/a", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://example.test/a", "fp", 0).is_ok());
    }

    #[test]
    fn approval_url_must_remain_on_selected_deployment() {
        assert!(ApprovalInfo::validate_for_host(
            "https://example.test/ssh/approve/a",
            "fp",
            0,
            "example.test"
        )
        .is_ok());
        assert!(ApprovalInfo::validate_for_host(
            "https://evil.example/ssh/approve/a",
            "fp",
            0,
            "example.test"
        )
        .is_err());
        assert!(ApprovalInfo::validate_for_host(
            "https://example.test.evil/ssh/approve/a",
            "fp",
            0,
            "example.test"
        )
        .is_err());
    }

    #[test]
    fn approval_url_authority_includes_canonical_port() {
        let url = "https://localhost:8443/ssh/approve/a";
        assert!(ApprovalInfo::validate(url, "fp", 0).is_ok());
        assert!(ApprovalInfo::validate_for_host(url, "fp", 0, "localhost:8443").is_ok());
        assert!(ApprovalInfo::validate_for_host(url, "fp", 0, "localhost").is_err());
        assert!(ApprovalInfo::validate_for_host(url, "fp", 0, "localhost:9443").is_err());
        assert!(ApprovalInfo::validate_for_host(
            "https://example.test:443/a",
            "fp",
            0,
            "example.test"
        )
        .is_ok());
        for invalid in [
            "https://localhost:0/a",
            "https://localhost:08443/a",
            "https://localhost:65536/a",
            "https://localhost:/a",
            "https://localhost:8443:1/a",
        ] {
            assert!(
                ApprovalInfo::validate(invalid, "fp", 0).is_err(),
                "{invalid}"
            );
        }
    }

    #[test]
    fn invalid_approval_payload_fails_closed_as_protocol_error() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let flow = flow.apply(SignInEvent::Whoami {
            generation,
            outcome: WhoamiOutcome::Approval {
                url: "http://example.test/approval".into(),
                fingerprint: "fp".into(),
            },
            at: 1,
        });
        assert_eq!(flow.phase, SignInPhase::Failed);
        assert_eq!(flow.failure, Some(SignInFailure::Protocol));
        assert!(flow.approval.is_none());
    }

    #[test]
    fn unreachable_during_approval_fails_closed() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let flow = flow.apply(SignInEvent::Whoami {
            generation,
            outcome: WhoamiOutcome::Approval {
                url: "https://example.test/approval".into(),
                fingerprint: "SHA256:test".into(),
            },
            at: 1,
        });
        assert_eq!(flow.phase, SignInPhase::AwaitingApproval);
        let flow = flow.apply(SignInEvent::Unreachable(generation));
        assert_eq!(flow.phase, SignInPhase::Failed);
        assert_eq!(flow.failure, Some(SignInFailure::Unreachable));
        assert!(flow.approval.is_none());
    }

    #[test]
    fn approval_fingerprint_rejects_control_and_whitespace() {
        assert!(ApprovalInfo::validate("https://example.test/a", "fp\n", 0).is_err());
        assert!(ApprovalInfo::validate("https://example.test/a", "fp value", 0).is_err());
        assert!(ApprovalInfo::validate("https://example.test/a", "SHA256:abc", 0).is_ok());
    }

    #[test]
    fn session_identifier_rejects_every_ascii_control_and_whitespace_byte() {
        for byte in 0_u8..=0x20 {
            let value = format!("machine{}id", char::from(byte));
            assert!(validate_session_identifier(&value).is_err(), "byte {byte}");
        }
        assert!(validate_session_identifier(&"x".repeat(128)).is_ok());
        assert!(validate_session_identifier(&"x".repeat(129)).is_err());
    }

    #[test]
    fn whoami_envelope_is_decoded_with_bounded_approval_fields() {
        let authenticated = parse_whoami(
            br#"{"version":1,"status":"authenticated","account":"alice@example.test"}"#,
        )
        .expect("authenticated envelope");
        assert_eq!(
            authenticated,
            WhoamiOutcome::Authenticated {
                account: "alice@example.test".into()
            }
        );
        let approval = parse_whoami(
            br#"{"version":1,"status":"approval_required","url":"https://example.test/approve","fingerprint":"SHA256:test"}"#,
        )
        .expect("approval envelope");
        assert!(matches!(approval, WhoamiOutcome::Approval { .. }));
        // Porsche's own envelope: `succeeded` with the account in `result`,
        // and `approval_url` while the key is pending.
        assert_eq!(
            parse_whoami(
                br#"{"version":1,"status":"succeeded","result":{"id":"u1","email":"alice@example.test","public_key":"ecdsa-sha2-nistp256 AAAA"}}"#,
            ),
            Some(WhoamiOutcome::Authenticated {
                account: "alice@example.test".into()
            })
        );
        assert!(matches!(
            parse_whoami(
                br#"{"version":1,"status":"approval_required","approval_url":"https://example.test/ssh/approve/abc","fingerprint":"SHA256:test"}"#,
            ),
            Some(WhoamiOutcome::Approval { .. })
        ));
        assert!(parse_whoami(br#"{"version":1,"status":"succeeded","result":{}}"#).is_none());
        assert!(parse_whoami(br#"{"version":2,"status":"authenticated","account":"x"}"#).is_none());
        assert!(parse_whoami(br#"{"version":1,"status":"approval_required","url":"http://example.test","fingerprint":"x"}"#).is_none());
    }

    #[test]
    fn curl_fetcher_rejects_invalid_authority_before_spawning_transport() {
        let fetcher = CurlTrustFetcher { timeout_seconds: 5 };
        assert_eq!(fetcher.fetch("bad host"), Err(RuntimeError::InvalidInput));
        assert_eq!(
            fetcher.fetch("example.test/path"),
            Err(RuntimeError::InvalidInput)
        );
    }
}
