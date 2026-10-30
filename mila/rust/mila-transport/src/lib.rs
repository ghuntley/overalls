//! Strict Porsche SSH host certificate validation.

mod cert;
mod session;
mod trust;
mod watch;

pub use cert::{
    parse_host_certificate_blob, parse_host_certificate_line, verify_host_certificate,
    HostCertificate, HostRefusal,
};
pub use session::{PorscheSession, SessionReply, SessionRequest, TransportError};
pub use trust::{decode_trust_document, reconcile_trust, TrustDocument, TrustRefusal};
pub use watch::{
    decode_watch_line, RequestRefusal, TerminalAttachRequest, WatchEvent, WatchFormat,
    WatchRequest, MAX_WATCH_LINE_BYTES,
};

pub mod ssh;

/// Bounded state and framing policy shared by native PTY adapters.
///
/// This type deliberately owns no SSH channel. Platform bindings must attach
/// it to an authenticated `russh` channel and perform I/O through that
/// channel; the policy prevents stale generations and unbounded payloads from
/// crossing the UI boundary.
pub mod pty;
