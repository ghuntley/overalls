//! Rust-owned sign-in planning, approval and flow state.

use super::{
    validate_session_endpoint, DeviceSigner, LiveSession, SessionConnectConfig, SessionError,
    TrustEnrollment, TrustFetcher, TrustStore,
};
use crate::adapter::RuntimeError;

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
