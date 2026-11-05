//! Linux enrollment and authenticated-session ownership.
//!
//! This module is deliberately independent of GTK.  The UI receives only the
//! state and bounded listing projection; the Rust FFI handle remains the sole
//! authority for an authenticated deployment connection.

mod commands;
mod connection;
mod pty;
mod signer;
mod signin;
mod trust;
mod watch;
pub use watch::{WatchHint, WatchSubscription};

use crate::adapter::RuntimeError;
use std::collections::HashSet;

pub use connection::{SessionBinding, SessionConnectConfig, SessionProbe};
pub use pty::{SessionPtyBackend, TerminalChunk};
pub use signer::{DeviceSigner, FileDeviceSigner, SignerError};
pub use signin::{
    ApprovalInfo, ApprovalState, SignInCoordinator, SignInEvent, SignInFailure, SignInFlow,
    SignInPhase, WhoamiOutcome,
};
pub use trust::{
    CurlTrustFetcher, HttpsTrustFetcher, TrustEnrollment, TrustFetcher, TrustStore, XdgTrustStore,
};

const MAX_TRUST_BYTES: usize = 8192;
const MAX_LISTING_BYTES: usize = 1 << 20;

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

impl LiveSession {
    fn handle(&self) -> Result<u64, SessionError> {
        self.handle.ok_or(SessionError::StaleHandle)
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

#[cfg(test)]
mod tests;
