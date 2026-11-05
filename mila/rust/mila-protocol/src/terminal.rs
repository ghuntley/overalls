//! Closed, bounded Porsche terminal attach headers and exit outcomes.

use serde::Deserialize;

pub const MAX_ATTACH_HEADER_BYTES: usize = 512;
pub const MAX_TERMINAL_CURSOR: u64 = i64::MAX as u64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachOutcome {
    Closed,
    Refused,
    Invalid,
    Authority,
    Transport,
}
impl AttachOutcome {
    pub const fn from_status(status: Option<i32>) -> Self {
        match status {
            Some(0) => Self::Closed,
            Some(1) => Self::Refused,
            Some(2) => Self::Invalid,
            Some(3) => Self::Authority,
            _ => Self::Transport,
        }
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachMode {
    ReadWrite,
    ReadOnly,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachError {
    InvalidCommand,
    AttachRequiresPty,
    ApprovalRequired,
    Unauthorized,
    AuthorityCredential,
    Forbidden,
    NotFound,
    TerminalUnavailable,
    Conflict,
    TemporarilyUnavailable,
    TransportError,
}
impl AttachError {
    pub const fn outcome(self) -> AttachOutcome {
        match self {
            Self::InvalidCommand | Self::AttachRequiresPty => AttachOutcome::Invalid,
            Self::ApprovalRequired | Self::Unauthorized | Self::AuthorityCredential => {
                AttachOutcome::Authority
            }
            Self::Forbidden | Self::NotFound | Self::TerminalUnavailable | Self::Conflict => {
                AttachOutcome::Refused
            }
            Self::TemporarilyUnavailable | Self::TransportError => AttachOutcome::Transport,
        }
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachHeader {
    Attached { from: u64, mode: AttachMode },
    Refused(AttachError),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AttachAcceptedHeader {
    version: u8,
    attached: bool,
    from: u64,
    replay_bytes: u64,
    mode: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AttachRefusedHeader {
    version: u8,
    attached: bool,
    error: String,
}

/// @cc [owner:ghuntley,label:protocol;security] terminal-header-closed-schema
/// A header MUST be at most 512 bytes and match exactly one version-1 schema.
/// Unknown fields, modes, errors, negative/overflowing cursors and multiple lines
/// MUST be refused before any terminal output or write grant is exposed.
pub fn decode_attach_header(bytes: &[u8]) -> Option<AttachHeader> {
    if bytes.len() > MAX_ATTACH_HEADER_BYTES {
        return None;
    }
    let line = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    if line.contains(&b'\n') || line.contains(&b'\r') {
        return None;
    }
    if let Ok(value) = serde_json::from_slice::<AttachAcceptedHeader>(line) {
        if value.version != 1 || !value.attached || value.from > MAX_TERMINAL_CURSOR {
            return None;
        }
        let _ = value.replay_bytes;
        let mode = match value.mode.as_str() {
            "rw" => AttachMode::ReadWrite,
            "ro" => AttachMode::ReadOnly,
            _ => return None,
        };
        return Some(AttachHeader::Attached {
            from: value.from,
            mode,
        });
    }
    let value = serde_json::from_slice::<AttachRefusedHeader>(line).ok()?;
    if value.version != 1 || value.attached {
        return None;
    }
    let error = match value.error.as_str() {
        "invalid_command" => AttachError::InvalidCommand,
        "attach_requires_pty" => AttachError::AttachRequiresPty,
        "approval_required" => AttachError::ApprovalRequired,
        "unauthorized" => AttachError::Unauthorized,
        "authority_credential" => AttachError::AuthorityCredential,
        "forbidden" => AttachError::Forbidden,
        "not_found" => AttachError::NotFound,
        "terminal_unavailable" => AttachError::TerminalUnavailable,
        "conflict" => AttachError::Conflict,
        "temporarily_unavailable" => AttachError::TemporarilyUnavailable,
        "transport_error" => AttachError::TransportError,
        _ => return None,
    };
    Some(AttachHeader::Refused(error))
}
