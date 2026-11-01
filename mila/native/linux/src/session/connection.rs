//! Opening, reading and closing the owned FFI session, and the session binding.

use super::signer::sign_trampoline;
use super::{
    copy_output, validate_session_endpoint, ApprovalInfo, DeviceSigner, LiveSession, SessionError,
    WhoamiOutcome, MAX_TRUST_BYTES,
};
use crate::adapter::RuntimeError;
use std::collections::HashSet;

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

pub(super) fn parse_whoami(bytes: &[u8]) -> Option<WhoamiOutcome> {
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
