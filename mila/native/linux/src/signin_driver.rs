//! GTK-independent sign-in driver for one deployment.
//!
//! The driver turns the [`SignInFlow`] reducer into a live sequence: trust
//! fetch, device key and certificate-authenticated connect (the
//! [`Connector`]), same-session `whoami` polling while browser approval is
//! pending, a one-time approval browser launch, establishment of the
//! authenticated session, an identity heartbeat while signed in, and bounded
//! reconnect with a fresh generation after a loss. Blocking work (curl, SSH
//! connect, `whoami`) runs as one job at a time, on a worker thread in the
//! GTK client or inline in tests; the GTK main loop only calls [`poll`].
//!
//! [`poll`]: SignInDriver::poll

use crate::adapter::RuntimeError;
use crate::session::{
    ApprovalInfo, LiveSession, SessionError, SessionProbe, SignInEvent, SignInFlow, SignInPhase,
    WhoamiOutcome,
};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc};
use std::time::Duration;

/// Where one sign-in connects: SSH host and port, and the HTTPS port that
/// serves the trust document and the browser approval page.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignInTarget {
    host: String,
    ssh_port: u16,
    https_port: u16,
    ca_file: Option<PathBuf>,
}

impl SignInTarget {
    pub fn new(host: &str, ssh_port: u16, https_port: u16) -> Result<Self, RuntimeError> {
        let valid_host = !host.is_empty()
            && host.len() <= 253
            && host.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'-')
            });
        if !valid_host || ssh_port == 0 || https_port == 0 {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(Self {
            host: host.to_owned(),
            ssh_port,
            https_port,
            ca_file: None,
        })
    }

    /// Verify the trust document's HTTPS origin with this CA bundle instead
    /// of the system trust store. Relative paths are refused.
    pub fn with_ca_file(mut self, ca_file: PathBuf) -> Result<Self, RuntimeError> {
        if !ca_file.is_absolute() {
            return Err(RuntimeError::InvalidInput);
        }
        self.ca_file = Some(ca_file);
        Ok(self)
    }

    pub fn ca_file(&self) -> Option<&Path> {
        self.ca_file.as_deref()
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn ssh_port(&self) -> u16 {
        self.ssh_port
    }

    pub fn https_port(&self) -> u16 {
        self.https_port
    }

    /// `host` or `host:port`, the only origin an approval link may use.
    pub fn https_authority(&self) -> String {
        if self.https_port == 443 {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.https_port)
        }
    }
}

/// The identity read the driver needs from a session.
pub trait SessionLink: Send + 'static {
    fn whoami(&self) -> Result<WhoamiOutcome, SessionError>;
}

impl SessionLink for LiveSession {
    fn whoami(&self) -> Result<WhoamiOutcome, SessionError> {
        LiveSession::whoami(self)
    }
}

impl SessionLink for SessionProbe {
    fn whoami(&self) -> Result<WhoamiOutcome, SessionError> {
        SessionProbe::whoami(self)
    }
}

/// Why a connect attempt failed. Only `Unreachable` is retried.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectError {
    DeviceKey,
    HostUntrusted,
    Unreachable,
    Protocol,
}

/// Opens one certificate-authenticated session: trust, device key, SSH.
pub trait Connector: Send + Sync + 'static {
    type Session: SessionLink;
    fn connect(&self, target: &SignInTarget) -> Result<Self::Session, ConnectError>;
}

/// @cc [owner:ghuntley,label:security] linux-live-connector-order
/// The live connector MUST open the owner-only device key before any network
/// operation, reconcile trust in Rust from an HTTPS fetch of the target's own
/// origin (no redirects, optional private CA), and pass only the reconciled
/// trust bytes and the target's SSH endpoint to session connect.
///
/// The GTK client's connector: device key, trust enrollment, SSH connect.
pub struct LiveConnector {
    key_path: Option<PathBuf>,
    timeout_ms: u32,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for LiveConnector {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LiveConnector")
            .finish_non_exhaustive()
    }
}

impl LiveConnector {
    pub fn new(key_path: Option<PathBuf>, timeout_ms: u32) -> Self {
        Self {
            key_path,
            timeout_ms,
        }
    }

    /// This device's `SHA256:` fingerprint, creating the key on first use.
    pub fn device_fingerprint(&self) -> Option<String> {
        let path = self.key_path.as_deref()?;
        crate::device_key::load_or_create(path)
            .ok()
            .map(|key| key.fingerprint)
    }
}

impl Connector for LiveConnector {
    type Session = LiveSession;

    fn connect(&self, target: &SignInTarget) -> Result<LiveSession, ConnectError> {
        let path = self.key_path.as_deref().ok_or(ConnectError::DeviceKey)?;
        let key = crate::device_key::load_or_create(path).map_err(|_| ConnectError::DeviceKey)?;
        let enrollment = crate::session::TrustEnrollment {
            store: crate::session::XdgTrustStore,
            fetcher: crate::session::HttpsTrustFetcher {
                ca_path: target.ca_file.clone(),
                server_name: target.host.clone(),
                host: target.host.clone(),
                https_port: target.https_port,
            },
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs());
        let trust = enrollment
            .resolve(&target.host, now)
            .map_err(|error| match error {
                RuntimeError::InvalidInput => ConnectError::HostUntrusted,
                RuntimeError::Unavailable => ConnectError::Unreachable,
            })?;
        LiveSession::connect(
            &crate::session::SessionConnectConfig {
                trust_document: trust,
                host: target.host.clone(),
                port: target.ssh_port,
                timeout_ms: self.timeout_ms,
            },
            &key.signer,
        )
        .map_err(|error| match error {
            SessionError::Transport | SessionError::Busy => ConnectError::Unreachable,
            SessionError::InvalidInput => ConnectError::HostUntrusted,
            SessionError::StaleHandle | SessionError::Unavailable => ConnectError::Protocol,
        })
    }
}

/// Opens a validated approval link. A refused launch leaves the link
/// available for a manual open; polling continues either way.
pub trait ApprovalBrowser {
    fn open(&self, approval: &ApprovalInfo) -> bool;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SignInPolicy {
    pub poll_interval: Duration,
    pub reconnect_attempts: u32,
    pub reconnect_backoff: Duration,
    pub heartbeat_interval: Duration,
}

impl Default for SignInPolicy {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_secs(2),
            reconnect_attempts: 3,
            reconnect_backoff: Duration::from_secs(1),
            heartbeat_interval: Duration::from_secs(15),
        }
    }
}

/// How jobs run: inline (tests) or on a worker thread (GTK main loop).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Execution {
    Inline,
    Thread,
}

/// What the host must do after a poll.
#[derive(Debug)]
pub enum DriverEvent<S> {
    /// Bind this authenticated session; every page now uses it.
    Established { session: S, account: String },
    /// The bound session is no longer authenticated: release it and every
    /// projection derived from it. A reconnect may already be under way.
    Lost,
}

enum Output<S> {
    Connected(Result<S, ConnectError>),
    Whoami(S, Result<WhoamiOutcome, SessionError>),
    Heartbeat(Result<WhoamiOutcome, SessionError>),
}

struct Done<S> {
    generation: u64,
    output: Output<S>,
}

/// @cc [owner:ghuntley,label:security;reliability] linux-signin-driver-generations
/// A job result MUST be applied only to the generation that dispatched it;
/// stale results MUST be dropped, closing any session they carry. At most one
/// job per generation is outstanding. An approval link MUST be validated
/// against the target's HTTPS authority and opened at most once per
/// generation. Refusal, expiry and protocol failures MUST drop the session.
/// Only a whoami `authenticated` result for a connecting or approving
/// generation may establish a session. Reconnect after a loss MUST start a
/// fresh generation without reusing the prior approval and MUST stop after
/// the policy's attempts.
pub struct SignInDriver<C: Connector> {
    connector: Arc<C>,
    policy: SignInPolicy,
    execution: Execution,
    flow: SignInFlow,
    target: Option<SignInTarget>,
    sender: mpsc::Sender<Done<C::Session>>,
    receiver: mpsc::Receiver<Done<C::Session>>,
    in_flight: Option<u64>,
    pending: Option<C::Session>,
    due_ms: Option<u64>,
    attempt: u32,
    max_attempts: u32,
    browser_opened: bool,
    next_heartbeat_ms: u64,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl<C: Connector> std::fmt::Debug for SignInDriver<C> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SignInDriver")
            .finish_non_exhaustive()
    }
}

impl<C: Connector> SignInDriver<C> {
    pub fn new(connector: Arc<C>, policy: SignInPolicy, execution: Execution) -> Self {
        let (sender, receiver) = mpsc::channel();
        Self {
            connector,
            policy,
            execution,
            flow: SignInFlow::default(),
            target: None,
            sender,
            receiver,
            in_flight: None,
            pending: None,
            due_ms: None,
            attempt: 1,
            max_attempts: 1,
            browser_opened: false,
            next_heartbeat_ms: 0,
        }
    }

    pub fn flow(&self) -> &SignInFlow {
        &self.flow
    }

    pub fn target(&self) -> Option<&SignInTarget> {
        self.target.as_ref()
    }

    /// True while a job or a scheduled step remains; the host keeps polling.
    pub fn is_active(&self) -> bool {
        matches!(
            self.flow.phase,
            SignInPhase::Connecting | SignInPhase::AwaitingApproval | SignInPhase::SignedIn
        )
    }

    /// Starts a new generation for `target`. Refused while connecting or
    /// signed in; sign out first to switch deployments.
    pub fn start(&mut self, target: SignInTarget) -> bool {
        self.target = Some(target);
        self.restart(1)
    }

    /// Manual reconnect after a failure, expiry or disconnect.
    pub fn reconnect(&mut self) -> bool {
        if self.target.is_none()
            || !matches!(
                self.flow.phase,
                SignInPhase::Disconnected | SignInPhase::Failed | SignInPhase::Expired
            )
        {
            return false;
        }
        self.restart(self.policy.reconnect_attempts.max(1))
    }

    /// Ends the generation. Any outstanding result is dropped when it arrives.
    pub fn sign_out(&mut self) {
        self.flow = self.flow.clone().apply(SignInEvent::SignOut);
        self.target = None;
        self.reset_generation_state();
    }

    /// A page operation on the bound session reported a transport loss.
    /// Returns true when the host must release the bound session.
    pub fn report_loss(&mut self) -> bool {
        if self.flow.phase != SignInPhase::SignedIn {
            return false;
        }
        self.lose();
        true
    }

    pub fn heartbeat_due(&self, now_ms: u64) -> bool {
        self.flow.phase == SignInPhase::SignedIn
            && self.in_flight.is_none()
            && now_ms >= self.next_heartbeat_ms
    }

    /// Checks the bound session's identity off the caller's thread.
    pub fn heartbeat<P: SessionLink>(&mut self, probe: P, now_ms: u64) {
        if !self.heartbeat_due(now_ms) {
            return;
        }
        self.next_heartbeat_ms = now_ms.saturating_add(millis(self.policy.heartbeat_interval));
        self.dispatch(move || Output::Heartbeat(probe.whoami()));
    }

    /// Applies finished jobs and runs any step that is due.
    #[expect(
        clippy::similar_names,
        reason = "`now_s` and `now_ms` are the same instant in seconds and milliseconds"
    )]
    pub fn poll(
        &mut self,
        now_ms: u64,
        browser: &dyn ApprovalBrowser,
    ) -> Vec<DriverEvent<C::Session>> {
        let mut events = Vec::new();
        // Only results finished before this poll; inline jobs dispatched
        // while applying them are seen by the next poll, as threaded ones are.
        let finished: Vec<_> = self.receiver.try_iter().collect();
        for done in finished {
            if done.generation != self.flow.generation || self.in_flight != Some(done.generation) {
                // Stale: dropping the output closes any session it carries.
                continue;
            }
            self.in_flight = None;
            self.apply(done.output, now_ms, browser, &mut events);
        }
        let now_s = now_ms / 1_000;
        if self.flow.phase == SignInPhase::AwaitingApproval {
            self.flow = self.flow.clone().apply(SignInEvent::Tick(now_s));
            if self.flow.phase != SignInPhase::AwaitingApproval {
                self.pending = None;
                self.due_ms = None;
            }
        }
        if self.in_flight.is_none() && self.due_ms.is_some_and(|due| now_ms >= due) {
            self.due_ms = None;
            if let Some(session) = self.pending.take() {
                self.dispatch(move || {
                    let outcome = session.whoami();
                    Output::Whoami(session, outcome)
                });
            } else if self.flow.phase == SignInPhase::Connecting {
                self.dispatch_connect();
            }
        }
        events
    }

    fn apply(
        &mut self,
        output: Output<C::Session>,
        now_ms: u64,
        browser: &dyn ApprovalBrowser,
        events: &mut Vec<DriverEvent<C::Session>>,
    ) {
        let generation = self.flow.generation;
        match output {
            Output::Connected(Ok(session)) => {
                self.flow = self.flow.clone().apply(SignInEvent::Connected(generation));
                if self.flow.phase == SignInPhase::Connecting {
                    self.dispatch(move || {
                        let outcome = session.whoami();
                        Output::Whoami(session, outcome)
                    });
                }
            }
            Output::Connected(Err(ConnectError::Unreachable)) => self.retry_or_fail(now_ms),
            Output::Connected(Err(error)) => {
                let event = match error {
                    ConnectError::DeviceKey => SignInEvent::DeviceKeyUnavailable(generation),
                    ConnectError::HostUntrusted => SignInEvent::HostRejected(generation),
                    ConnectError::Unreachable | ConnectError::Protocol => SignInEvent::Whoami {
                        generation,
                        outcome: WhoamiOutcome::Protocol,
                        at: now_ms / 1_000,
                    },
                };
                self.flow = self.flow.clone().apply(event);
            }
            Output::Whoami(session, outcome) => {
                if matches!(
                    self.flow.phase,
                    SignInPhase::Connecting | SignInPhase::AwaitingApproval
                ) {
                    self.apply_whoami(session, outcome, now_ms, browser, events);
                }
            }
            Output::Heartbeat(outcome) => match outcome {
                Ok(WhoamiOutcome::Authenticated { .. } | WhoamiOutcome::Unavailable)
                | Err(SessionError::Busy) => {}
                Ok(WhoamiOutcome::Refused) => {
                    self.flow = self.flow.clone().apply(SignInEvent::Whoami {
                        generation,
                        outcome: WhoamiOutcome::Refused,
                        at: now_ms / 1_000,
                    });
                    // A refused signed-in session fails without retry.
                    self.reset_generation_state();
                    events.push(DriverEvent::Lost);
                }
                Ok(_) | Err(_) => {
                    self.lose();
                    events.push(DriverEvent::Lost);
                }
            },
        }
    }

    #[expect(
        clippy::similar_names,
        reason = "`now_s` and `now_ms` are the same instant in seconds and milliseconds"
    )]
    fn apply_whoami(
        &mut self,
        session: C::Session,
        outcome: Result<WhoamiOutcome, SessionError>,
        now_ms: u64,
        browser: &dyn ApprovalBrowser,
        events: &mut Vec<DriverEvent<C::Session>>,
    ) {
        let generation = self.flow.generation;
        let now_s = now_ms / 1_000;
        let poll_due = now_ms.saturating_add(millis(self.policy.poll_interval));
        match outcome {
            Ok(WhoamiOutcome::Authenticated { account }) => {
                self.flow = self.flow.clone().apply(SignInEvent::Whoami {
                    generation,
                    outcome: WhoamiOutcome::Authenticated {
                        account: account.clone(),
                    },
                    at: now_s,
                });
                if self.flow.phase == SignInPhase::SignedIn {
                    self.attempt = 1;
                    self.next_heartbeat_ms =
                        now_ms.saturating_add(millis(self.policy.heartbeat_interval));
                    events.push(DriverEvent::Established { session, account });
                }
            }
            Ok(WhoamiOutcome::Approval { url, fingerprint }) => {
                let authority = self
                    .target
                    .as_ref()
                    .map(SignInTarget::https_authority)
                    .unwrap_or_default();
                if ApprovalInfo::validate_for_host(&url, &fingerprint, now_s, &authority).is_err() {
                    self.flow = self.flow.clone().apply(SignInEvent::Whoami {
                        generation,
                        outcome: WhoamiOutcome::Protocol,
                        at: now_s,
                    });
                    return;
                }
                if self.flow.phase == SignInPhase::Connecting {
                    self.flow = self.flow.clone().apply(SignInEvent::Whoami {
                        generation,
                        outcome: WhoamiOutcome::Approval { url, fingerprint },
                        at: now_s,
                    });
                }
                if self.flow.phase != SignInPhase::AwaitingApproval {
                    return;
                }
                if !self.browser_opened {
                    self.browser_opened = true;
                    if let Some(approval) = self.flow.approval.as_ref() {
                        let _ = browser.open(approval);
                    }
                }
                self.pending = Some(session);
                self.due_ms = Some(poll_due);
            }
            Ok(WhoamiOutcome::Unavailable) | Err(SessionError::Busy) => {
                self.pending = Some(session);
                self.due_ms = Some(poll_due);
            }
            Ok(outcome @ (WhoamiOutcome::Refused | WhoamiOutcome::Protocol)) => {
                self.flow = self.flow.clone().apply(SignInEvent::Whoami {
                    generation,
                    outcome,
                    at: now_s,
                });
            }
            Err(SessionError::Transport | SessionError::StaleHandle) => {
                drop(session);
                self.retry_or_fail(now_ms);
            }
            Err(SessionError::InvalidInput | SessionError::Unavailable) => {
                self.flow = self.flow.clone().apply(SignInEvent::Whoami {
                    generation,
                    outcome: WhoamiOutcome::Protocol,
                    at: now_s,
                });
            }
        }
    }

    fn retry_or_fail(&mut self, now_ms: u64) {
        if self.attempt < self.max_attempts {
            let delay =
                millis(self.policy.reconnect_backoff).saturating_mul(u64::from(self.attempt));
            self.attempt += 1;
            self.pending = None;
            self.due_ms = Some(now_ms.saturating_add(delay));
        } else {
            let generation = self.flow.generation;
            self.flow = self
                .flow
                .clone()
                .apply(SignInEvent::Unreachable(generation));
        }
    }

    fn lose(&mut self) {
        let generation = self.flow.generation;
        self.flow = self
            .flow
            .clone()
            .apply(SignInEvent::Disconnected(generation));
        self.restart(self.policy.reconnect_attempts.max(1));
    }

    fn restart(&mut self, attempts: u32) -> bool {
        if self.target.is_none() {
            return false;
        }
        let previous = self.flow.generation;
        self.flow = self.flow.clone().apply(SignInEvent::Start);
        if self.flow.generation == previous {
            return false;
        }
        self.reset_generation_state();
        self.max_attempts = attempts;
        self.dispatch_connect();
        true
    }

    fn reset_generation_state(&mut self) {
        self.in_flight = None;
        self.pending = None;
        self.due_ms = None;
        self.attempt = 1;
        self.max_attempts = 1;
        self.browser_opened = false;
    }

    fn dispatch_connect(&mut self) {
        let Some(target) = self.target.clone() else {
            return;
        };
        let connector = self.connector.clone();
        self.dispatch(move || Output::Connected(connector.connect(&target)));
    }

    fn dispatch<F>(&mut self, job: F)
    where
        F: FnOnce() -> Output<C::Session> + Send + 'static,
    {
        let generation = self.flow.generation;
        self.in_flight = Some(generation);
        match self.execution {
            Execution::Inline => {
                let _ = self.sender.send(Done {
                    generation,
                    output: job(),
                });
            }
            Execution::Thread => {
                let sender = self.sender.clone();
                std::thread::spawn(move || {
                    let _ = sender.send(Done {
                        generation,
                        output: job(),
                    });
                });
            }
        }
    }
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::SignInFailure;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    type Script = Arc<Mutex<VecDeque<Result<WhoamiOutcome, SessionError>>>>;

    #[derive(Default)]
    struct Counters {
        opened: AtomicUsize,
        closed: AtomicUsize,
        connects: AtomicUsize,
    }

    struct FakeSession {
        script: Script,
        counters: Arc<Counters>,
    }

    impl SessionLink for FakeSession {
        fn whoami(&self) -> Result<WhoamiOutcome, SessionError> {
            self.script
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(Ok(WhoamiOutcome::Unavailable))
        }
    }

    impl Drop for FakeSession {
        fn drop(&mut self) {
            self.counters.closed.fetch_add(1, Ordering::SeqCst);
        }
    }

    struct FakeConnector {
        results: Mutex<VecDeque<Result<(), ConnectError>>>,
        script: Script,
        counters: Arc<Counters>,
    }

    impl Connector for FakeConnector {
        type Session = FakeSession;
        fn connect(&self, _: &SignInTarget) -> Result<FakeSession, ConnectError> {
            self.counters.connects.fetch_add(1, Ordering::SeqCst);
            self.results.lock().unwrap().pop_front().unwrap_or(Ok(()))?;
            self.counters.opened.fetch_add(1, Ordering::SeqCst);
            Ok(FakeSession {
                script: self.script.clone(),
                counters: self.counters.clone(),
            })
        }
    }

    #[derive(Default)]
    struct Browser(Mutex<Vec<String>>);

    impl ApprovalBrowser for Browser {
        fn open(&self, approval: &ApprovalInfo) -> bool {
            self.0.lock().unwrap().push(approval.url.clone());
            true
        }
    }

    #[expect(
        clippy::unnecessary_wraps,
        reason = "scripted whoami outcomes are queued as the connector's Result values"
    )]
    fn approval(url: &str) -> Result<WhoamiOutcome, SessionError> {
        Ok(WhoamiOutcome::Approval {
            url: url.to_owned(),
            fingerprint: "SHA256:abc".to_owned(),
        })
    }

    #[expect(
        clippy::unnecessary_wraps,
        reason = "scripted whoami outcomes are queued as the connector's Result values"
    )]
    fn authenticated() -> Result<WhoamiOutcome, SessionError> {
        Ok(WhoamiOutcome::Authenticated {
            account: "ada@example.test".to_owned(),
        })
    }

    struct Harness {
        driver: SignInDriver<FakeConnector>,
        script: Script,
        counters: Arc<Counters>,
        browser: Browser,
        now: u64,
        held: Vec<FakeSession>,
        established: Vec<u64>,
    }

    impl Harness {
        fn new(
            connects: Vec<Result<(), ConnectError>>,
            whoami: Vec<Result<WhoamiOutcome, SessionError>>,
        ) -> Self {
            let script: Script = Arc::new(Mutex::new(whoami.into()));
            let counters = Arc::new(Counters::default());
            let connector = FakeConnector {
                results: Mutex::new(connects.into()),
                script: script.clone(),
                counters: counters.clone(),
            };
            Self {
                driver: SignInDriver::new(
                    Arc::new(connector),
                    SignInPolicy::default(),
                    Execution::Inline,
                ),
                script,
                counters,
                browser: Browser::default(),
                now: 1_000_000,
                held: Vec::new(),
                established: Vec::new(),
            }
        }

        fn target() -> SignInTarget {
            SignInTarget::new("localhost", 2222, 8443).unwrap()
        }

        fn step(&mut self, advance_ms: u64) -> usize {
            self.now += advance_ms;
            let mut lost = 0;
            for event in self.driver.poll(self.now, &self.browser) {
                match event {
                    DriverEvent::Established { session, .. } => {
                        assert_eq!(self.driver.flow().phase, SignInPhase::SignedIn);
                        self.established.push(self.driver.flow().generation);
                        self.held.clear();
                        self.held.push(session);
                    }
                    DriverEvent::Lost => {
                        self.held.clear();
                        lost += 1;
                    }
                }
            }
            lost
        }

        fn run(&mut self, steps: usize) {
            for _ in 0..steps {
                self.step(2_000);
            }
        }

        fn live_sessions(&self) -> usize {
            self.counters.opened.load(Ordering::SeqCst)
                - self.counters.closed.load(Ordering::SeqCst)
        }
    }

    #[test]
    fn approval_opens_once_then_establishes() {
        let mut h = Harness::new(
            vec![],
            vec![
                approval("https://localhost:8443/approve/1"),
                approval("https://localhost:8443/approve/1"),
                Ok(WhoamiOutcome::Unavailable),
                authenticated(),
            ],
        );
        assert!(h.driver.start(Harness::target()));
        assert!(
            !h.driver.start(Harness::target()),
            "refused while connecting"
        );
        h.step(0);
        assert_eq!(h.driver.flow().phase, SignInPhase::Connecting);
        h.step(0);
        assert_eq!(h.driver.flow().phase, SignInPhase::AwaitingApproval);
        assert_eq!(h.browser.0.lock().unwrap().len(), 1);
        h.run(6);
        assert_eq!(h.browser.0.lock().unwrap().len(), 1, "opened once");
        assert_eq!(h.driver.flow().phase, SignInPhase::SignedIn);
        assert_eq!(h.driver.flow().account.as_deref(), Some("ada@example.test"));
        assert_eq!(h.established.len(), 1);
        assert_eq!(h.live_sessions(), 1);
        assert_eq!(h.counters.connects.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn approval_for_another_origin_fails_closed() {
        for url in [
            "https://localhost/approve/1",
            "https://evil.example:8443/approve/1",
        ] {
            let mut h = Harness::new(vec![], vec![approval(url)]);
            h.driver.start(Harness::target());
            h.run(3);
            assert_eq!(h.driver.flow().phase, SignInPhase::Failed);
            assert_eq!(h.driver.flow().failure, Some(SignInFailure::Protocol));
            assert!(h.browser.0.lock().unwrap().is_empty());
            assert_eq!(h.live_sessions(), 0);
        }
    }

    #[test]
    fn stale_results_are_dropped_after_sign_out() {
        let mut h = Harness::new(vec![], vec![authenticated(), authenticated()]);
        h.driver.start(Harness::target());
        h.driver.sign_out();
        h.run(3);
        assert_eq!(h.driver.flow().phase, SignInPhase::SignedOut);
        assert_eq!(h.established, Vec::<u64>::new());
        assert_eq!(h.live_sessions(), 0);
        h.driver.start(Harness::target());
        h.run(3);
        assert_eq!(h.established.len(), 1);
        assert_eq!(h.live_sessions(), 1);
    }

    #[test]
    fn approval_expires_and_drops_the_session() {
        let mut h = Harness::new(vec![], vec![approval("https://localhost:8443/a")]);
        h.driver.start(Harness::target());
        h.run(2);
        assert_eq!(h.driver.flow().phase, SignInPhase::AwaitingApproval);
        h.step(601_000);
        h.run(2);
        assert_eq!(h.driver.flow().phase, SignInPhase::Expired);
        assert_eq!(h.live_sessions(), 0);
        assert!(h.driver.reconnect());
        assert_eq!(h.driver.flow().approval, None);
    }

    #[test]
    fn connect_failures_map_to_typed_phases() {
        for (error, failure) in [
            (ConnectError::DeviceKey, SignInFailure::DeviceKey),
            (ConnectError::HostUntrusted, SignInFailure::HostUntrusted),
            (ConnectError::Protocol, SignInFailure::Protocol),
            (ConnectError::Unreachable, SignInFailure::Unreachable),
        ] {
            let mut h = Harness::new(vec![Err(error)], vec![]);
            h.driver.start(Harness::target());
            h.run(3);
            assert_eq!(h.driver.flow().failure, Some(failure));
            assert_eq!(h.counters.connects.load(Ordering::SeqCst), 1, "{error:?}");
        }
    }

    #[test]
    fn heartbeat_loss_reconnects_with_a_fresh_generation() {
        let mut h = Harness::new(vec![], vec![authenticated()]);
        h.driver.start(Harness::target());
        h.run(2);
        let first = h.driver.flow().generation;
        assert_eq!(h.established, vec![first]);
        assert!(!h.driver.heartbeat_due(h.now));
        h.now += 15_000;
        assert!(h.driver.heartbeat_due(h.now));
        let probe = FakeSession {
            script: Arc::new(Mutex::new(vec![Err(SessionError::StaleHandle)].into())),
            counters: Arc::new(Counters::default()),
        };
        h.driver.heartbeat(probe, h.now);
        h.script.lock().unwrap().push_back(authenticated());
        assert_eq!(h.step(0), 1, "loss reported once");
        assert_eq!(h.driver.flow().phase, SignInPhase::Connecting);
        assert!(h.driver.flow().generation > first);
        h.run(3);
        assert_eq!(h.driver.flow().phase, SignInPhase::SignedIn);
        assert_eq!(h.established.len(), 2);
        assert!(h.established[1] > first);
        assert_eq!(h.counters.connects.load(Ordering::SeqCst), 2);
        assert_eq!(h.live_sessions(), 1);
    }

    #[test]
    fn reconnect_is_bounded() {
        let mut h = Harness::new(
            vec![
                Ok(()),
                Err(ConnectError::Unreachable),
                Err(ConnectError::Unreachable),
                Err(ConnectError::Unreachable),
                Err(ConnectError::Unreachable),
            ],
            vec![authenticated()],
        );
        h.driver.start(Harness::target());
        h.run(2);
        assert!(h.driver.report_loss());
        assert!(
            !h.driver.report_loss(),
            "only a signed-in session can be lost"
        );
        h.run(10);
        assert_eq!(h.driver.flow().phase, SignInPhase::Failed);
        assert_eq!(h.driver.flow().failure, Some(SignInFailure::Unreachable));
        assert_eq!(h.counters.connects.load(Ordering::SeqCst), 1 + 3);
    }

    #[test]
    fn refused_heartbeat_releases_without_retry() {
        let mut h = Harness::new(vec![], vec![authenticated()]);
        h.driver.start(Harness::target());
        h.run(2);
        h.now += 15_000;
        let probe = FakeSession {
            script: Arc::new(Mutex::new(vec![Ok(WhoamiOutcome::Refused)].into())),
            counters: Arc::new(Counters::default()),
        };
        h.driver.heartbeat(probe, h.now);
        assert_eq!(h.step(0), 1);
        h.run(3);
        assert_eq!(h.driver.flow().phase, SignInPhase::Failed);
        assert_eq!(h.driver.flow().failure, Some(SignInFailure::Refused));
        assert_eq!(h.counters.connects.load(Ordering::SeqCst), 1);
        assert_eq!(h.live_sessions(), 0);
    }

    #[test]
    fn thread_execution_reaches_the_same_outcome() {
        let script: Script = Arc::new(Mutex::new(
            vec![approval("https://localhost:8443/a"), authenticated()].into(),
        ));
        let counters = Arc::new(Counters::default());
        let mut driver = SignInDriver::new(
            Arc::new(FakeConnector {
                results: Mutex::new(VecDeque::new()),
                script,
                counters: counters.clone(),
            }),
            SignInPolicy {
                poll_interval: Duration::from_millis(1),
                ..SignInPolicy::default()
            },
            Execution::Thread,
        );
        let browser = Browser::default();
        driver.start(Harness::target());
        let started = std::time::Instant::now();
        let mut session = None;
        while session.is_none() && started.elapsed() < Duration::from_secs(10) {
            let now = u64::try_from(started.elapsed().as_millis()).unwrap();
            for event in driver.poll(now, &browser) {
                if let DriverEvent::Established { session: live, .. } = event {
                    session = Some(live);
                }
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        assert!(session.is_some());
        assert_eq!(browser.0.lock().unwrap().len(), 1);
    }

    /// Random operation sequences: a generation establishes at most once,
    /// only while signed in, and every session opened is either held by the
    /// host, pending in the driver, or closed.
    #[test]
    #[expect(
        clippy::similar_names,
        reason = "`seen` (established generations) and `seed` (PRNG state) are unrelated"
    )]
    fn operation_sequences_keep_generation_invariants() {
        let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
        let mut next = |bound: u64| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed % bound
        };
        for _ in 0..200 {
            let mut h = Harness::new(vec![], vec![]);
            for _ in 0..60 {
                match next(9) {
                    0 => {
                        h.driver.start(Harness::target());
                    }
                    1 => {
                        h.driver.sign_out();
                        h.held.clear();
                    }
                    2 => {
                        if h.driver.report_loss() {
                            h.held.clear();
                        }
                    }
                    3 => {
                        h.driver.reconnect();
                    }
                    4 => {
                        let outcome = match next(4) {
                            0 => authenticated(),
                            1 => Err(SessionError::Transport),
                            2 => Ok(WhoamiOutcome::Refused),
                            _ => Err(SessionError::Busy),
                        };
                        let probe = FakeSession {
                            script: Arc::new(Mutex::new(vec![outcome].into())),
                            counters: Arc::new(Counters::default()),
                        };
                        h.driver.heartbeat(probe, h.now);
                    }
                    _ => {
                        let outcome = match next(6) {
                            0 => authenticated(),
                            1 => approval("https://localhost:8443/a"),
                            2 => approval("https://evil.example/a"),
                            3 => Err(SessionError::Transport),
                            4 => Ok(WhoamiOutcome::Unavailable),
                            _ => Ok(WhoamiOutcome::Protocol),
                        };
                        h.script.lock().unwrap().push_back(outcome);
                        h.step(next(20_000));
                    }
                }
                let mut seen = h.established.clone();
                seen.dedup();
                assert_eq!(
                    seen.len(),
                    h.established.len(),
                    "one establish per generation"
                );
                assert!(h.held.len() <= 1);
                if h.driver.flow().phase != SignInPhase::SignedIn {
                    assert!(h.held.is_empty(), "no authority outside SignedIn");
                }
            }
            h.driver.sign_out();
            h.step(0);
            h.held.clear();
            assert_eq!(h.live_sessions(), 0, "no session leaks");
        }
    }
}
