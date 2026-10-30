//! Headless live-journey driver for the Linux client.
//!
//! `mila-linux-journey --descriptor <path>` runs the same GTK-independent
//! modules the GTK window uses (deployment list, sign-in coordinator pieces,
//! authenticated session, terminal surface, SSH-key view and deep-link
//! presentation) against a deployment described by the hermetic journey
//! fixture's descriptor. It prints a JSON report of typed step outcomes only:
//! no credentials, tokens, terminal bytes or server payloads are reported.

use crate::adapter::{new_request_id, RuntimeError};
use crate::deep_link::{present, Page};
use crate::deployments::{DeploymentHost, DeploymentStore};
use crate::device_key::{load_or_create, write_private};
use crate::journey_checks::{
    action_failed, check_answered, check_created, check_deleted, check_desired,
    check_plan_approved, check_prompted, check_resize_created, check_resized, check_resumed,
    check_share, check_web, first_thread, load_thread_controls, refusal_code, web_endpoint, Check,
    PageContext, CREATE_SIZE, RESIZE_SIZE,
};
use crate::machine_view::project_snapshot;
use crate::route::{share_inbound, share_route, ActivationBatch, MachinePage, Target};
use crate::session::{
    ApprovalInfo, DeviceSigner, FileDeviceSigner, HttpsTrustFetcher, LiveSession, SessionBinding,
    SessionConnectConfig, SessionError, SignInFailure, SignInPhase, TrustEnrollment, TrustStore,
    WhoamiOutcome,
};
use crate::signin_driver::{
    ApprovalBrowser, ConnectError, Connector, DriverEvent, Execution, SignInDriver, SignInPolicy,
    SignInTarget,
};
use crate::ssh_keys_view::{RevokeOutcome, SshKeySource, SshKeysStatus, SshKeysView};
use crate::terminal::HostPtyTransport;
use crate::terminal_surface::{TerminalSurface, TickOutcome};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_DESCRIPTOR_BYTES: usize = 256 * 1024;
const MAX_CA_PEM_BYTES: usize = 64 * 1024;
const SESSION_TIMEOUT_MS: u32 = 20_000;
const APPROVAL_POLLS: u32 = 60;
const TERMINAL_DEADLINE: Duration = Duration::from_secs(30);

/// A bearer credential from the descriptor. It is passed to curl only through
/// an owner-only config file and is never formatted by `Debug` or reported.
#[derive(Clone, Deserialize, Eq, PartialEq)]
#[serde(transparent)]
pub struct BearerToken(String);

impl std::fmt::Debug for BearerToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("BearerToken(<redacted>)")
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct DeploymentSpec {
    pub host: String,
    pub ssh_port: u16,
    pub https_port: u16,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct TlsSpec {
    /// The fixture CA certificate, inline PEM.
    pub ca_pem: String,
    pub server_name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ApproverSpec {
    pub url: String,
    pub bearer_token: BearerToken,
    /// Base of the fixture's action hook (`<fixture_url>/<action>`); derived
    /// from `url` when absent.
    #[serde(default)]
    pub fixture_url: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct SeedSpec {
    pub machine_name: String,
    pub share_principal: String,
    /// The seeded machine's id, when the fixture publishes it.
    #[serde(default)]
    pub machine_id: Option<String>,
    /// The signed-in account's email, when the fixture publishes it.
    #[serde(default)]
    pub account_email: Option<String>,
}

/// Fixture descriptor v1. Unknown fields are ignored so the fixture can add
/// data for other platforms without breaking this driver.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct JourneyDescriptor {
    pub version: u32,
    pub deployment: DeploymentSpec,
    pub tls: TlsSpec,
    pub approver: ApproverSpec,
    pub seed: SeedSpec,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DescriptorError {
    TooLarge,
    Malformed,
    UnsupportedVersion,
    InvalidField(&'static str),
}

impl JourneyDescriptor {
    /// @cc [owner:ghuntley,label:security;protocol] linux-journey-descriptor-validated
    /// The descriptor MUST be bounded, version 1, and every field MUST pass
    /// its grammar (route-grammar host, non-zero ports, PEM CA, DNS server
    /// name, HTTPS approver or loopback HTTP, header-safe token, control-free
    /// seed values) before any file, process or network operation uses it.
    pub fn parse(bytes: &[u8]) -> Result<Self, DescriptorError> {
        if bytes.len() > MAX_DESCRIPTOR_BYTES {
            return Err(DescriptorError::TooLarge);
        }
        let descriptor: Self =
            serde_json::from_slice(bytes).map_err(|_| DescriptorError::Malformed)?;
        if descriptor.version != 1 {
            return Err(DescriptorError::UnsupportedVersion);
        }
        let deployment = &descriptor.deployment;
        let host = DeploymentHost::parse(&deployment.host)
            .map_err(|_| DescriptorError::InvalidField("deployment.host"))?;
        if host.as_str() != deployment.host || deployment.host.contains(':') {
            return Err(DescriptorError::InvalidField("deployment.host"));
        }
        if deployment.ssh_port == 0 {
            return Err(DescriptorError::InvalidField("deployment.ssh_port"));
        }
        if deployment.https_port == 0 {
            return Err(DescriptorError::InvalidField("deployment.https_port"));
        }
        let pem = descriptor.tls.ca_pem.trim();
        if pem.len() > MAX_CA_PEM_BYTES
            || !pem.starts_with("-----BEGIN CERTIFICATE-----")
            || !pem.ends_with("-----END CERTIFICATE-----")
            || pem
                .chars()
                .any(|ch| ch.is_control() && ch != '\n' && ch != '\r')
        {
            return Err(DescriptorError::InvalidField("tls.ca_pem"));
        }
        if DeploymentHost::parse(&descriptor.tls.server_name).map_or(true, |name| {
            name.as_str() != descriptor.tls.server_name || name.as_str().contains(':')
        }) {
            return Err(DescriptorError::InvalidField("tls.server_name"));
        }
        if !valid_approver_url(&descriptor.approver.url) {
            return Err(DescriptorError::InvalidField("approver.url"));
        }
        if descriptor
            .approver
            .fixture_url
            .as_deref()
            .is_some_and(|url| !valid_approver_url(url))
        {
            return Err(DescriptorError::InvalidField("approver.fixture_url"));
        }
        let token = &descriptor.approver.bearer_token.0;
        if token.is_empty()
            || token.len() > 4_096
            || !token
                .bytes()
                .all(|byte| byte.is_ascii_graphic() && byte != b'"' && byte != b'\\')
        {
            return Err(DescriptorError::InvalidField("approver.bearer_token"));
        }
        let seed = &descriptor.seed;
        if seed.machine_name.is_empty()
            || seed.machine_name.len() > 128
            || seed.machine_name.chars().any(char::is_control)
        {
            return Err(DescriptorError::InvalidField("seed.machine_name"));
        }
        if !valid_email(&seed.share_principal) {
            return Err(DescriptorError::InvalidField("seed.share_principal"));
        }
        if seed.machine_id.as_deref().is_some_and(|id| {
            id.is_empty()
                || id.len() > 128
                || !id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        }) {
            return Err(DescriptorError::InvalidField("seed.machine_id"));
        }
        if seed
            .account_email
            .as_deref()
            .is_some_and(|email| !valid_email(email))
        {
            return Err(DescriptorError::InvalidField("seed.account_email"));
        }
        Ok(descriptor)
    }

    /// HTTPS authority of the deployment, `host` or `host:port`.
    pub fn https_authority(&self) -> String {
        if self.deployment.https_port == 443 {
            self.deployment.host.clone()
        } else {
            format!("{}:{}", self.deployment.host, self.deployment.https_port)
        }
    }
}

fn valid_approver_url(url: &str) -> bool {
    let (rest, loopback_only) = if let Some(rest) = url.strip_prefix("https://") {
        (rest, false)
    } else if let Some(rest) = url.strip_prefix("http://") {
        (rest, true)
    } else {
        return false;
    };
    let authority = rest.split(['/', '?']).next().unwrap_or_default();
    let host = authority
        .rsplit_once(':')
        .map_or(authority, |(host, port)| {
            if port.parse::<u16>().is_ok_and(|port| port != 0) {
                host
            } else {
                ""
            }
        });
    url.len() <= 2_048
        && !host.is_empty()
        && host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
        && (!loopback_only || matches!(host, "localhost" | "127.0.0.1"))
        && !url.contains(['@', '#', ' ', '"', '\\', '\n', '\r', '\t'])
}

fn valid_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    value.len() <= 320
        && !local.is_empty()
        && domain.contains('.')
        && !domain.contains('@')
        && !value
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace() || ch == '"' || ch == '\\')
}

/// Typed outcome of one journey step.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StepReport {
    pub name: &'static str,
    pub ok: bool,
    pub outcome: &'static str,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct JourneyReport {
    pub version: u32,
    pub ok: bool,
    pub steps: Vec<StepReport>,
}

impl JourneyReport {
    pub fn new() -> Self {
        Self {
            version: 1,
            ok: true,
            steps: Vec::new(),
        }
    }

    pub fn record(&mut self, name: &'static str, ok: bool, outcome: &'static str) -> bool {
        self.ok &= ok;
        self.steps.push(StepReport { name, ok, outcome });
        ok
    }
}

impl Default for JourneyReport {
    fn default() -> Self {
        Self::new()
    }
}

/// Creates a new owner-only (0700) work directory: `requested`, or a fresh
/// random directory under the system temporary directory.
pub fn create_private_workdir(requested: Option<PathBuf>) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let path = if let Some(path) = requested {
        path
    } else {
        let mut suffix = [0_u8; 8];
        std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut suffix)?;
        std::env::temp_dir().join(format!(
            "mila-linux-journey-{:016x}",
            u64::from_le_bytes(suffix)
        ))
    };
    std::fs::DirBuilder::new().mode(0o700).create(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?;
    Ok(path)
}

/// Reads a descriptor file with the size bound applied before parsing.
pub fn read_descriptor(path: &Path) -> Result<JourneyDescriptor, DescriptorError> {
    let file = std::fs::File::open(path).map_err(|_| DescriptorError::Malformed)?;
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(
        &mut std::io::Read::take(file, MAX_DESCRIPTOR_BYTES as u64 + 1),
        &mut bytes,
    )
    .map_err(|_| DescriptorError::Malformed)?;
    JourneyDescriptor::parse(&bytes)
}

/// The connection profile file for the fixture deployment.
pub fn fixture_connection_profile(descriptor: &JourneyDescriptor, ca_path: &Path) -> String {
    serde_json::json!({
        "version": 1,
        "profiles": [{
            "host": descriptor.deployment.host,
            "ssh_port": descriptor.deployment.ssh_port,
            "https_port": descriptor.deployment.https_port,
            "ca_file": ca_path,
        }]
    })
    .to_string()
}

/// In-memory trust pin for one journey run.
#[derive(Default)]
pub struct MemoryTrustStore(RefCell<Option<Vec<u8>>>);

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for MemoryTrustStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MemoryTrustStore")
            .finish_non_exhaustive()
    }
}

impl TrustStore for MemoryTrustStore {
    fn read(&self, _: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
        Ok(self.0.borrow().clone())
    }

    fn write(&self, _: &str, document: &[u8]) -> Result<(), RuntimeError> {
        *self.0.borrow_mut() = Some(document.to_vec());
        Ok(())
    }
}

/// HTTPS trust fetch against the fixture CA and port. Redirects are refused.
pub type FixtureTrustFetcher = HttpsTrustFetcher;

/// curl config carrying the approver credential. Written to an owner-only
/// file so the token never appears in a process argument list.
pub fn approver_config(descriptor: &JourneyDescriptor, ca_path: &Path) -> String {
    hook_config(descriptor, &descriptor.approver.url, ca_path)
}

fn hook_config(descriptor: &JourneyDescriptor, url: &str, ca_path: &Path) -> String {
    format!(
        "url = \"{}\"\nrequest = \"POST\"\nheader = \"Authorization: Bearer {}\"\nheader = \"Content-Type: application/json\"\ncacert = \"{}\"\nfail\nsilent\nmax-time = 120\nmax-redirs = 0\n",
        url,
        descriptor.approver.bearer_token.0,
        ca_path.display()
    )
}

/// Posts `body` to a bearer-protected fixture hook at `url` and returns the
/// response body (at most 64 KiB) on success. The bearer travels only in an
/// owner-only curl config file that is removed afterwards.
fn post_hook(
    descriptor: &JourneyDescriptor,
    workdir: &Path,
    ca: &Path,
    url: &str,
    body: &serde_json::Value,
) -> Option<Vec<u8>> {
    if !valid_approver_url(url) {
        return None;
    }
    let config = workdir.join("hook.curlrc");
    write_private(&config, hook_config(descriptor, url, ca).as_bytes()).ok()?;
    let result = (|| {
        use std::io::{Read, Write};
        let mut child = std::process::Command::new("curl")
            .arg("--config")
            .arg(&config)
            .arg("--data-binary")
            .arg("@-")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok()?;
        child
            .stdin
            .take()?
            .write_all(body.to_string().as_bytes())
            .ok()?;
        let mut output = Vec::new();
        child
            .stdout
            .take()?
            .take(64 * 1024)
            .read_to_end(&mut output)
            .ok()?;
        child.wait().ok()?.success().then_some(output)
    })();
    let _ = std::fs::remove_file(&config);
    result
}

/// A fresh device key at `path` (which must not exist yet).
fn generate_device_key(path: &Path) -> Option<(FileDeviceSigner, String)> {
    if path.exists() {
        return None;
    }
    load_or_create(path)
        .ok()
        .map(|key| (key.signer, key.fingerprint))
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

fn approve(descriptor: &JourneyDescriptor, workdir: &Path, ca: &Path, info: &ApprovalInfo) -> bool {
    let body = serde_json::json!({
        "approval_url": info.url,
        "fingerprint": info.fingerprint,
    });
    post_hook(descriptor, workdir, ca, &descriptor.approver.url, &body).is_some()
}

/// @cc [owner:ghuntley,label:verification;security] linux-journey-fixture-actions
/// The fixture's stand-ins for the absent provisioner and model (`observe`,
/// `thread-create`, `thread-ready`, `thread-question`, `thread-proposal`) MUST
/// be requested only through the bearer-protected approver origin with the
/// bearer in an owner-only config file; returned identifiers MUST NOT be
/// reported. A missing hook is reported as `fixture_hook_unavailable`.
pub struct FixtureHook {
    descriptor: JourneyDescriptor,
    workdir: PathBuf,
    ca_path: PathBuf,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for FixtureHook {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FixtureHook")
            .finish_non_exhaustive()
    }
}

impl FixtureHook {
    pub fn new(descriptor: &JourneyDescriptor, workdir: &Path, ca_path: &Path) -> Self {
        Self {
            descriptor: descriptor.clone(),
            workdir: workdir.to_owned(),
            ca_path: ca_path.to_owned(),
        }
    }

    fn action(&self, action: &str, body: &serde_json::Value) -> Option<serde_json::Value> {
        let approver = &self.descriptor.approver;
        let url = match approver.fixture_url.as_deref() {
            Some(base) => format!("{}/{action}", base.trim_end_matches('/')),
            None => format!(
                "{}/fixture/{action}",
                approver.url.strip_suffix("/approve")?
            ),
        };
        let bytes = post_hook(&self.descriptor, &self.workdir, &self.ca_path, &url, body)?;
        serde_json::from_slice(&bytes).ok()
    }

    fn identifier(value: &serde_json::Value, field: &str) -> Option<String> {
        value
            .get(field)
            .and_then(serde_json::Value::as_str)
            .filter(|id| {
                !id.is_empty()
                    && id.len() <= 128
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
            })
            .map(str::to_owned)
    }

    /// Completes the machine's open operations and observes its requested
    /// state, as the provisioner would.
    pub fn observe(&self, machine: &str) -> bool {
        self.action("observe", &serde_json::json!({ "machine_id": machine }))
            .is_some()
    }

    /// Creates a thread for the account and waits until it is ready.
    pub fn create_thread(&self) -> Option<String> {
        let created = self.action("thread-create", &serde_json::json!({}))?;
        let thread = Self::identifier(&created, "thread_id")?;
        self.action("thread-ready", &serde_json::json!({ "thread_id": thread }))?;
        Some(thread)
    }

    /// Has the agent ask a question in `thread`; returns its id.
    pub fn question(&self, thread: &str) -> Option<String> {
        let asked = self.action(
            "thread-question",
            &serde_json::json!({ "thread_id": thread }),
        )?;
        Self::identifier(&asked, "question_id")
    }

    /// Has the agent propose a plan in `thread`; returns its id.
    pub fn proposal(&self, thread: &str) -> Option<String> {
        let proposed = self.action(
            "thread-proposal",
            &serde_json::json!({ "thread_id": thread }),
        )?;
        Self::identifier(&proposed, "plan_id")
    }
}

/// The structured answer the fixture's question accepts.
pub const FIXTURE_ANSWER: &str = r#"{"approach":{"selected":"First","text":""}}"#;
/// The prompt the journeys send.
pub const JOURNEY_PROMPT: &str = "Report the hostname please";

fn connect<S: DeviceSigner>(
    descriptor: &JourneyDescriptor,
    trust: &[u8],
    signer: &S,
) -> Option<LiveSession> {
    LiveSession::connect(
        &SessionConnectConfig {
            trust_document: trust.to_vec(),
            host: descriptor.deployment.host.clone(),
            port: descriptor.deployment.ssh_port,
            timeout_ms: SESSION_TIMEOUT_MS,
        },
        signer,
    )
    .ok()
}

/// @cc [owner:ghuntley,label:security;architecture] linux-journey-report-redacted
/// The journey MUST report only step names, booleans and fixed outcome codes;
/// it MUST NOT print the bearer token, CA, approval URL, fingerprints, key
/// material, terminal text or any server response.
///
/// Runs the Linux journey. `workdir` must be an empty owner-only directory.
#[expect(
    clippy::too_many_lines,
    reason = "sequential journey steps sharing one session; ADR-0265 keeps mila-linux lint-only, so splitting is deferred"
)]
pub fn run(descriptor: &JourneyDescriptor, workdir: &Path) -> JourneyReport {
    let mut report = JourneyReport::new();
    let host = descriptor.deployment.host.clone();

    // 1. Deployment list: add, select and reload through the owner-only store.
    let store = DeploymentStore::new(workdir.join("deployment.json"));
    let listed = store
        .update(|list| {
            list.add("unrelated.example")?;
            list.add_and_select(&host)
        })
        .and_then(|_| store.load())
        .is_ok_and(|list| list.selected().map(DeploymentHost::as_str) == Some(host.as_str()));
    report.record(
        "deployment_list",
        listed,
        if listed { "selected" } else { "failed" },
    );

    // 2. Deep links before sign-in only navigate to sign-in or the list.
    let signed_out = ActivationBatch::parse([format!("overalls://{host}/machines").as_str()]);
    let unknown = ActivationBatch::parse(["overalls://unknown.example/machines"]);
    let gated = signed_out
        .decisions(Some(&host), false)
        .first()
        .is_some_and(|decision| present(decision).page == Page::SignIn)
        && unknown
            .decisions(Some(&host), false)
            .first()
            .is_some_and(|decision| present(decision).page == Page::Deployments);
    report.record(
        "deep_link_signed_out",
        gated,
        if gated { "gated" } else { "ungated" },
    );

    // 3. Trust: HTTPS fetch against the fixture CA, reconciled by Rust.
    let ca_path = workdir.join("fixture-ca.pem");
    if write_private(&ca_path, descriptor.tls.ca_pem.as_bytes()).is_err() {
        report.record("trust", false, "ca_unwritable");
        return report;
    }
    let enrollment = TrustEnrollment {
        store: MemoryTrustStore::default(),
        fetcher: FixtureTrustFetcher {
            ca_path: Some(ca_path.clone()),
            server_name: descriptor.tls.server_name.clone(),
            host: host.clone(),
            https_port: descriptor.deployment.https_port,
        },
    };
    let Ok(trust) = enrollment.resolve(&host, now()) else {
        report.record("trust", false, "refused");
        return report;
    };
    report.record("trust", true, "pinned");

    // 4. Owner-only device key.
    let key_path = workdir.join("device-key");
    let Some((_signer, fingerprint)) = generate_device_key(&key_path) else {
        report.record("device_key", false, "unavailable");
        return report;
    };
    report.record("device_key", true, "generated");

    // 5. Certificate-authenticated session and browser-approval completion.
    let (live, outcome) = sign_in(descriptor, workdir, &ca_path, &trust, &key_path);
    let Some(live) = live else {
        report.record("approval", false, outcome);
        return report;
    };
    report.record("approval", true, outcome);
    let binding = Rc::new(RefCell::new(SessionBinding::default()));
    binding.borrow_mut().bind(live);

    // 6. Machine listing and the seeded machine.
    let machine_id = {
        let mut session = binding.borrow_mut();
        session
            .session_mut()
            .and_then(|live| live.refresh().ok())
            .and_then(|bytes| project_snapshot(&bytes).ok())
            .and_then(|rows| {
                rows.into_iter()
                    .find(|row| match descriptor.seed.machine_id.as_deref() {
                        Some(id) => row.id == id,
                        None => row.name == descriptor.seed.machine_name,
                    })
                    .map(|row| row.id)
            })
    };
    report.record(
        "machines",
        machine_id.is_some(),
        if machine_id.is_some() {
            "seed_found"
        } else {
            "seed_missing"
        },
    );

    // 7. Share link out and back in: lands on the machine page, pre-filled.
    if let Some(id) = machine_id.as_deref() {
        let target = Target::Machine {
            id: id.to_owned(),
            page: MachinePage::Overview,
        };
        let opened = share_route(&host, &target)
            .ok()
            .map(|link| share_inbound(&link))
            .and_then(|batch| batch.decisions(Some(&host), true).into_iter().next())
            .map(|decision| present(&decision))
            .is_some_and(|presentation| {
                presentation.page == Page::Machines
                    && presentation.prefill.machine_id.as_deref() == Some(id)
            });
        report.record(
            "deep_link_share",
            opened,
            if opened { "opened" } else { "refused" },
        );
    }

    // 8. Sharing, web, lifecycle and threads, each asserted through a read.
    let hook = FixtureHook::new(descriptor, workdir, &ca_path);
    run_pages(
        &binding,
        descriptor,
        &hook,
        machine_id.as_deref(),
        &mut report,
    );

    // 9. Terminal stream through HostPtyTransport and the GTK surface model.
    let terminal_outcome = run_terminal(&binding, machine_id.as_deref());
    report.record(
        "terminal",
        terminal_passed(terminal_outcome),
        terminal_outcome,
    );

    // 10. SSH keys: this device's key is listed, marked and protected.
    let mut keys = SshKeysView::default();
    keys.set_device_fingerprint(Some(fingerprint.clone()));
    keys.begin_session();
    let refresh = |keys: &mut SshKeysView| {
        let mut session = binding.borrow_mut();
        keys.refresh(
            session
                .session_mut()
                .map(|live| -> &mut dyn SshKeySource { live }),
        )
    };
    let revoke = |keys: &mut SshKeysView, id: &str| {
        let mut session = binding.borrow_mut();
        keys.revoke(
            session
                .session_mut()
                .map(|live| -> &mut dyn SshKeySource { live }),
            id,
            new_request_id,
        )
    };
    let status = refresh(&mut keys);
    let own = keys.rows().into_iter().find(|row| row.this_device);
    let listed = status == SshKeysStatus::Loaded && own.is_some();
    report.record(
        "ssh_keys",
        listed,
        if listed {
            "device_key_listed"
        } else {
            "device_key_missing"
        },
    );
    if let Some(own) = own {
        let protected = revoke(&mut keys, &own.id) == RevokeOutcome::ThisDevice;
        report.record(
            "ssh_key_this_device",
            protected,
            if protected {
                "not_submitted"
            } else {
                "submitted"
            },
        );
    }

    // 11. A second device signs in; the first revokes it once, and the
    // revoked key must be approved again before it can sign in.
    let second_path = workdir.join("second-device-key");
    let second = generate_device_key(&second_path);
    let (second_session, second_outcome) = match second.as_ref() {
        Some(_) => sign_in(descriptor, workdir, &ca_path, &trust, &second_path),
        None => (None, "device_key_unavailable"),
    };
    if let (Some(mut second_session), Some((second_signer, second_fingerprint))) =
        (second_session, second.as_ref())
    {
        let _ = second_session.close();
        refresh(&mut keys);
        let target = keys.rows().into_iter().find(|row| {
            row.fingerprint == *second_fingerprint
                || second_fingerprint.get(7..) == Some(row.fingerprint.as_str())
        });
        let outcome = target.map(|row| revoke(&mut keys, &row.id));
        let reapproval = connect(descriptor, &trust, second_signer)
            .map(|fresh| fresh.whoami())
            .is_none_or(|whoami| !matches!(whoami, Ok(WhoamiOutcome::Authenticated { .. })));
        report.record(
            "ssh_key_revoke",
            matches!(outcome, Some(RevokeOutcome::Revoked)) && reapproval,
            match (outcome, reapproval) {
                (None, _) => "second_key_missing",
                (Some(RevokeOutcome::Revoked), true) => "revoked_reapproval_required",
                (Some(RevokeOutcome::Uncertain), _) => "uncertain",
                (Some(_), false) => "still_authenticated",
                (Some(_), true) => "refused",
            },
        );
    } else {
        report.record("ssh_key_revoke", false, second_outcome);
    }
    binding.borrow_mut().clear();
    report
}

/// The fixture's stand-in for the user's browser: it posts the validated
/// approval link and fingerprint to the descriptor's approver hook, which
/// approves the device as a signed-in user would.
pub struct FixtureApprover {
    descriptor: JourneyDescriptor,
    workdir: PathBuf,
    ca_path: PathBuf,
    opened: std::cell::Cell<u32>,
    failed: std::cell::Cell<bool>,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for FixtureApprover {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FixtureApprover")
            .finish_non_exhaustive()
    }
}

impl FixtureApprover {
    pub fn new(descriptor: &JourneyDescriptor, workdir: &Path, ca_path: &Path) -> Self {
        Self {
            descriptor: descriptor.clone(),
            workdir: workdir.to_owned(),
            ca_path: ca_path.to_owned(),
            opened: std::cell::Cell::new(0),
            failed: std::cell::Cell::new(false),
        }
    }

    /// How many approval links were opened.
    pub fn opened(&self) -> u32 {
        self.opened.get()
    }

    /// True once the approver hook refused or could not be reached.
    pub fn failed(&self) -> bool {
        self.failed.get()
    }
}

impl ApprovalBrowser for FixtureApprover {
    fn open(&self, approval: &ApprovalInfo) -> bool {
        self.opened.set(self.opened.get().saturating_add(1));
        let ok = approve(&self.descriptor, &self.workdir, &self.ca_path, approval);
        if !ok {
            self.failed.set(true);
        }
        ok
    }
}

/// Connects with already reconciled trust and an owner-only device key.
struct JourneyConnector {
    trust: Vec<u8>,
    key_path: PathBuf,
}

impl Connector for JourneyConnector {
    type Session = LiveSession;

    fn connect(&self, target: &SignInTarget) -> Result<LiveSession, ConnectError> {
        let key = load_or_create(&self.key_path).map_err(|_| ConnectError::DeviceKey)?;
        LiveSession::connect(
            &SessionConnectConfig {
                trust_document: self.trust.clone(),
                host: target.host().to_owned(),
                port: target.ssh_port(),
                timeout_ms: SESSION_TIMEOUT_MS,
            },
            &key.signer,
        )
        .map_err(|_| ConnectError::Unreachable)
    }
}

/// Fixed report code for a sign-in that ended without a session.
pub fn sign_in_failure_code(phase: SignInPhase, failure: Option<SignInFailure>) -> &'static str {
    match (phase, failure) {
        (SignInPhase::Expired, _) => "approval_expired",
        (_, Some(SignInFailure::DeviceKey)) => "device_key_unavailable",
        (_, Some(SignInFailure::HostUntrusted)) => "host_untrusted",
        (_, Some(SignInFailure::Refused)) => "refused",
        (_, Some(SignInFailure::Protocol)) => "protocol",
        (_, Some(SignInFailure::Unreachable)) => "unreachable",
        (SignInPhase::Disconnected, _) => "disconnected",
        _ => "approval_timeout",
    }
}

/// Runs the shared [`SignInDriver`] (the same driver the GTK window uses)
/// against the fixture, approving through the fixture approver. Returns the
/// authenticated session or a fixed failure code.
fn sign_in(
    descriptor: &JourneyDescriptor,
    workdir: &Path,
    ca_path: &Path,
    trust: &[u8],
    key_path: &Path,
) -> (Option<LiveSession>, &'static str) {
    let Ok(target) = SignInTarget::new(
        &descriptor.deployment.host,
        descriptor.deployment.ssh_port,
        descriptor.deployment.https_port,
    ) else {
        return (None, "target_invalid");
    };
    let approver = FixtureApprover::new(descriptor, workdir, ca_path);
    let mut driver = SignInDriver::new(
        std::sync::Arc::new(JourneyConnector {
            trust: trust.to_vec(),
            key_path: key_path.to_owned(),
        }),
        SignInPolicy {
            poll_interval: Duration::from_secs(1),
            ..SignInPolicy::default()
        },
        Execution::Inline,
    );
    driver.start(target);
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(u64::from(APPROVAL_POLLS) + 30) {
        let now = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        for event in driver.poll(now, &approver) {
            if let DriverEvent::Established { session, .. } = event {
                let code = if approver.opened() > 0 {
                    "approved"
                } else {
                    "already"
                };
                return (Some(session), code);
            }
        }
        if approver.failed() {
            return (None, "approver_failed");
        }
        if !driver.is_active() {
            let flow = driver.flow();
            return (None, sign_in_failure_code(flow.phase, flow.failure));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    (None, "approval_timeout")
}

const PAGE_STEP_DEADLINE: Duration = Duration::from_secs(60);
const PAGE_POLL: Duration = Duration::from_millis(500);

/// Polls `check` on the bound session until it passes, fails or times out.
fn await_check(
    binding: &Rc<RefCell<SessionBinding>>,
    mut check: impl FnMut(&mut LiveSession) -> Check,
) -> (bool, &'static str) {
    let started = Instant::now();
    loop {
        let outcome = match binding.borrow_mut().session_mut() {
            Some(live) => check(live),
            None => Check::Fail("not_bound"),
        };
        match outcome {
            Check::Pass(code) => return (true, code),
            Check::Fail(code) => return (false, code),
            Check::Wait if started.elapsed() > PAGE_STEP_DEADLINE => return (false, "timeout"),
            Check::Wait => std::thread::sleep(PAGE_POLL),
        }
    }
}

/// Runs one mutation with a fresh request id; returns the id on success.
fn submit(
    binding: &Rc<RefCell<SessionBinding>>,
    op: impl FnOnce(&mut LiveSession, &str) -> Result<(), SessionError>,
) -> Result<String, &'static str> {
    let request = new_request_id().ok_or("csprng_unavailable")?;
    let mut session = binding.borrow_mut();
    let live = session.session_mut().ok_or("not_bound")?;
    op(live, &request).map_err(|error| match error {
        SessionError::InvalidInput => refusal_code(live.last_refusal().as_deref()),
        other => action_failed(other),
    })?;
    Ok(request)
}

/// One step: submit, then await its check; records the outcome.
fn page_step(
    report: &mut JourneyReport,
    binding: &Rc<RefCell<SessionBinding>>,
    name: &'static str,
    op: impl FnOnce(&mut LiveSession, &str) -> Result<(), SessionError>,
    mut check: impl FnMut(&mut LiveSession, Option<&str>) -> Check,
) -> bool {
    match submit(binding, op) {
        Ok(request) => {
            let (ok, code) = await_check(binding, |live| check(live, Some(&request)));
            report.record(name, ok, code)
        }
        Err(code) => report.record(name, false, code),
    }
}

/// Asks the fixture to observe the journey machine; records a missing hook
/// once.
fn observe(
    hook: &FixtureHook,
    context: &PageContext,
    report: &mut JourneyReport,
    hook_missing: &mut bool,
) {
    let Some(machine) = context.machine.as_deref() else {
        return;
    };
    if !hook.observe(machine) && !*hook_missing {
        *hook_missing = true;
        report.record("fixture_observe", false, "fixture_hook_unavailable");
    }
}

/// Best-effort removal of a journey-created machine so repeated runs against
/// one deployment do not exhaust its capacity. The fixture observes the
/// machine first; a pinned resize can keep it busy for a while, so removal is
/// retried until the step deadline. Not a recorded step.
pub fn remove_journey_machine(hook: &FixtureHook, live: &mut LiveSession, machine: &str) -> bool {
    let started = Instant::now();
    while started.elapsed() < PAGE_STEP_DEADLINE {
        hook.observe(machine);
        let Some(request) = new_request_id() else {
            return false;
        };
        match live.machine_action(machine, "rm", &request) {
            Ok(()) => return hook.observe(machine),
            Err(SessionError::Transport | SessionError::StaleHandle) => return false,
            Err(_) => std::thread::sleep(PAGE_POLL),
        }
    }
    false
}

/// Sharing, web, lifecycle and threads against the deployment; every step
/// asserts its effect through a session read.
#[expect(
    clippy::too_many_lines,
    reason = "sequential page journey steps sharing one session; ADR-0265 keeps mila-linux lint-only, so splitting is deferred"
)]
fn run_pages(
    binding: &Rc<RefCell<SessionBinding>>,
    descriptor: &JourneyDescriptor,
    hook: &FixtureHook,
    seed_machine: Option<&str>,
    report: &mut JourneyReport,
) {
    let Some(mut context) = PageContext::new(&descriptor.seed.share_principal) else {
        report.record("lifecycle_create", false, "csprng_unavailable");
        return;
    };
    context.seed_machine = seed_machine.map(str::to_owned);
    let seed = seed_machine.unwrap_or_default().to_owned();
    let principal = descriptor.seed.share_principal.clone();

    // Sharing: add a viewer grant, read it back, remove it, read it gone.
    {
        let context = &context;
        page_step(
            report,
            binding,
            "sharing_add",
            |live, request| live.share_mutation(&seed, &principal, Some("viewer"), true, request),
            |live, _| check_share(live, context, Some("viewer")),
        );
        page_step(
            report,
            binding,
            "sharing_remove",
            |live, request| live.share_mutation(&seed, &principal, None, false, request),
            |live, _| check_share(live, context, None),
        );
    }

    // Web: show, then public and back to private at the current revision.
    let before = binding
        .borrow_mut()
        .session_mut()
        .ok_or(SessionError::StaleHandle)
        .and_then(|live| web_endpoint(live, &seed));
    match before {
        Ok(endpoint) => {
            report.record("web_show", true, "loaded");
            for (name, public) in [("web_public", true), ("web_private", false)] {
                let current = binding
                    .borrow_mut()
                    .session_mut()
                    .ok_or(SessionError::StaleHandle)
                    .and_then(|live| web_endpoint(live, &seed));
                let Ok(current) = current else {
                    report.record(name, false, "read_refused");
                    continue;
                };
                let revision = current.policy_revision;
                let context = &context;
                page_step(
                    report,
                    binding,
                    name,
                    |live, request| live.web_set(&seed, endpoint.port, public, revision, request),
                    |live, _| check_web(live, context, public, revision),
                );
            }
        }
        Err(error) => {
            report.record("web_show", false, action_failed(error));
        }
    }

    // Lifecycle on a machine this run creates. The fixture observes each
    // accepted physical intent, standing in for the provisioner.
    let mut hook_missing = false;
    let (cpu, memory, disk) = CREATE_SIZE;
    let name = context.machine_name.clone();
    let created = match submit(binding, |live, request| {
        live.machine_create(&name, cpu, memory, disk, request)
    }) {
        Ok(_) => await_check(binding, |live| check_created(live, &mut context)),
        Err(code) => (false, code),
    };
    report.record("lifecycle_create", created.0, created.1);
    observe(hook, &context, report, &mut hook_missing);
    let machine = context.machine.clone().unwrap_or_default();
    for (step, action, desired) in [
        ("lifecycle_stop", "stop", "stopped"),
        ("lifecycle_start", "start", "running"),
    ] {
        let context_ref = &context;
        page_step(
            report,
            binding,
            step,
            |live, request| live.machine_action(&machine, action, request),
            |live, _| check_desired(live, context_ref, desired, desired),
        );
        observe(hook, &context, report, &mut hook_missing);
    }
    {
        let context = &context;
        let paused = page_step(
            report,
            binding,
            "lifecycle_pause",
            |live, request| live.machine_action(&machine, "pause", request),
            |live, _| check_desired(live, context, "paused", "paused"),
        );
        page_step(
            report,
            binding,
            "lifecycle_resume",
            |live, request| live.machine_action(&machine, "resume", request),
            |live, request| check_resumed(live, context, request, paused),
        );
        page_step(
            report,
            binding,
            "lifecycle_delete",
            |live, request| live.machine_action(&machine, "rm", request),
            |live, _| check_deleted(live, context),
        );
    }
    // The deletion holds capacity until the provisioner stand-in observes it.
    if let Some(machine) = context.machine.as_deref() {
        hook.observe(machine);
    }
    // Resize a second created machine; its pinned request keeps it busy.
    let name = context.resize_machine_name.clone();
    let created = match submit(binding, |live, request| {
        live.machine_create(&name, cpu, memory, disk, request)
    }) {
        Ok(_) => await_check(binding, |live| check_resize_created(live, &mut context)),
        Err(code) => (false, code),
    };
    report.record("lifecycle_resize_create", created.0, created.1);
    if let Some(resize_machine) = context.resize_machine.clone() {
        if !hook.observe(&resize_machine) && !hook_missing {
            report.record("fixture_observe", false, "fixture_hook_unavailable");
        }
    }
    {
        let (cpu, memory, disk) = RESIZE_SIZE;
        let resize_machine = context.resize_machine.clone().unwrap_or_default();
        let context = &context;
        page_step(
            report,
            binding,
            "lifecycle_resize",
            |live, request| live.machine_resize(&resize_machine, cpu, memory, disk, request),
            |live, request| check_resized(live, context, request),
        );
    }
    if let Some(resize_machine) = context.resize_machine.clone() {
        if let Some(live) = binding.borrow_mut().session_mut() {
            remove_journey_machine(hook, live, &resize_machine);
        }
    }

    // Threads: list, prompt, answer and plan approval.
    context.thread = hook.create_thread();
    if context.thread.is_none() {
        context.thread = binding
            .borrow_mut()
            .session_mut()
            .and_then(|live| first_thread(live, seed_machine).ok().flatten());
    }
    let listed = match context.thread.as_deref() {
        Some(thread) => binding
            .borrow_mut()
            .session_mut()
            .and_then(|live| live.thread_action(None, "thread ls", None, None, None).ok())
            .and_then(|bytes| crate::porsche_results::decode_thread_rows(&bytes).ok())
            .is_some_and(|rows| rows.iter().any(|row| row.id == thread)),
        None => false,
    };
    report.record(
        "threads_list",
        listed,
        match (listed, context.thread.is_some()) {
            (true, _) => "listed",
            (false, true) => "thread_missing",
            (false, false) => "no_thread",
        },
    );
    let Some(thread) = context.thread.clone() else {
        for step in ["threads_prompt", "threads_answer", "threads_plan_approve"] {
            report.record(step, false, "no_thread");
        }
        return;
    };
    let _ = await_check(binding, |live| load_thread_controls(live, &mut context));
    {
        let context = &context;
        page_step(
            report,
            binding,
            "threads_prompt",
            |live, request| {
                live.thread_action(
                    Some(&thread),
                    "thread prompt",
                    None,
                    Some(JOURNEY_PROMPT),
                    Some(request),
                )
                .map(|_| ())
            },
            |live, _| check_prompted(live, context),
        );
    }
    let asked = hook.question(&thread);
    let _ = await_check(binding, |live| load_thread_controls(live, &mut context));
    if asked.is_some() && context.question.is_none() {
        context.question = asked;
    }
    match context.question.clone() {
        Some(question) => {
            let context = &context;
            page_step(
                report,
                binding,
                "threads_answer",
                |live, request| {
                    live.thread_action(
                        Some(&thread),
                        "thread answer",
                        Some(&question),
                        Some(FIXTURE_ANSWER),
                        Some(request),
                    )
                    .map(|_| ())
                },
                |live, _| check_answered(live, context),
            );
        }
        None => {
            report.record("threads_answer", false, "no_pending_question");
        }
    }
    let proposed = hook.proposal(&thread);
    let _ = await_check(binding, |live| load_thread_controls(live, &mut context));
    if proposed.is_some() && context.plan.is_none() {
        context.plan = proposed;
    }
    match context.plan.clone() {
        Some(plan) => {
            let context = &context;
            page_step(
                report,
                binding,
                "threads_plan_approve",
                |live, request| {
                    live.thread_action(
                        Some(&thread),
                        "thread plan approve",
                        Some(&plan),
                        None,
                        Some(request),
                    )
                    .map(|_| ())
                },
                |live, _| check_plan_approved(live, context),
            );
        }
        None => {
            report.record("threads_plan_approve", false, "no_pending_plan");
        }
    }
}

/// The terminal step passes when the marker echoes back, or when Porsche
/// refuses the attach with the closed `terminal_unavailable` reason (the
/// hermetic fixture runs no guest; ADR-0264): the attach then went through
/// `terminal new` and the named attach on the live session and the
/// deployment answered.
pub fn terminal_passed(outcome: &str) -> bool {
    matches!(outcome, "marker_seen" | "terminal_unavailable")
}

fn run_terminal(binding: &Rc<RefCell<SessionBinding>>, machine: Option<&str>) -> &'static str {
    let Some(machine) = machine else {
        return "seed_missing";
    };
    let backend = crate::session::SessionPtyBackend::new(binding.clone(), 100);
    let Ok(mut surface) =
        TerminalSurface::new(binding.clone(), HostPtyTransport::new(backend), 80, 24)
    else {
        return "renderer_refused";
    };
    if surface.attach(machine, "", 80, 24).is_err() {
        let refusal = binding
            .borrow()
            .session()
            .and_then(LiveSession::last_refusal);
        return match refusal.as_deref() {
            Some("terminal_unavailable") => "terminal_unavailable",
            Some(_) => "attach_refused",
            None => "attach_failed",
        };
    }
    let Some(marker) = new_request_id()
        .and_then(|id| id.get(8..20).map(|suffix| format!("mila-journey-{suffix}")))
    else {
        return "marker_unavailable";
    };
    if surface.send(format!("echo {marker}\r").as_bytes()).is_err() {
        let _ = surface.kill();
        return "input_refused";
    }
    let started = Instant::now();
    let outcome = loop {
        match surface.tick() {
            TickOutcome::Updated if surface.text().lines().any(|line| line.trim() == marker) => {
                break "marker_seen";
            }
            TickOutcome::Ended => break "ended_before_marker",
            TickOutcome::Failed(_) | TickOutcome::Detached => break "stream_failed",
            _ if started.elapsed() > TERMINAL_DEADLINE => break "marker_timeout",
            _ => std::thread::sleep(Duration::from_millis(20)),
        }
    };
    if surface.live_generation().is_some() && surface.kill().is_err() {
        return "kill_failed";
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    const CA: &str = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";

    fn descriptor() -> serde_json::Value {
        serde_json::json!({
            "version": 1,
            "deployment": {"host": "localhost", "ssh_port": 2222, "https_port": 8443},
            "tls": {"ca_pem": CA, "server_name": "localhost"},
            "approver": {"url": "https://localhost:8443/test/approve", "bearer_token": "s3cr3t-token"},
            "seed": {"machine_name": "journey-machine", "share_principal": "second@example.test"},
            "extra": {"ignored": true}
        })
    }

    fn parse(value: &serde_json::Value) -> Result<JourneyDescriptor, DescriptorError> {
        JourneyDescriptor::parse(&serde_json::to_vec(value).unwrap())
    }

    #[test]
    fn parses_fixture_descriptor_v1() {
        let parsed = parse(&descriptor()).unwrap();
        assert_eq!(parsed.deployment.ssh_port, 2222);
        assert_eq!(parsed.https_authority(), "localhost:8443");
        assert!(!format!("{parsed:?}").contains("s3cr3t"));
        assert!(parsed.seed.machine_id.is_none());

        // The launcher's descriptor adds the seeded ids and a launcher block.
        let mut launched = descriptor();
        launched["seed"]["machine_id"] = serde_json::json!("019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a");
        launched["seed"]["account_email"] = serde_json::json!("mila-owner@example.test");
        launched["launcher"] = serde_json::json!({"bind": "127.0.0.1"});
        let parsed = parse(&launched).unwrap();
        assert_eq!(
            parsed.seed.machine_id.as_deref(),
            Some("019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a")
        );
    }

    #[test]
    fn terminal_step_accepts_only_echo_or_the_closed_no_guest_refusal() {
        assert!(terminal_passed("marker_seen"));
        assert!(terminal_passed("terminal_unavailable"));
        for code in [
            "attach_refused",
            "attach_failed",
            "marker_timeout",
            "seed_missing",
        ] {
            assert!(!terminal_passed(code));
        }
    }

    #[test]
    fn rejects_invalid_fields_before_use() {
        let cases: &[(&str, serde_json::Value)] = &[
            ("/version", serde_json::json!(2)),
            ("/deployment/host", serde_json::json!("LOCALHOST")),
            ("/deployment/host", serde_json::json!("localhost:2222")),
            ("/deployment/host", serde_json::json!("local host")),
            ("/deployment/ssh_port", serde_json::json!(0)),
            ("/deployment/https_port", serde_json::json!(0)),
            ("/tls/ca_pem", serde_json::json!("not a pem")),
            ("/tls/server_name", serde_json::json!("evil/x")),
            (
                "/approver/url",
                serde_json::json!("http://approver.example/x"),
            ),
            (
                "/approver/url",
                serde_json::json!("https://user@localhost/x"),
            ),
            ("/approver/bearer_token", serde_json::json!("two words")),
            ("/approver/bearer_token", serde_json::json!("quote\"break")),
            ("/approver/bearer_token", serde_json::json!("")),
            ("/seed/machine_name", serde_json::json!("bad\nname")),
            ("/seed/share_principal", serde_json::json!("not-an-email")),
            ("/seed/machine_id", serde_json::json!("bad id")),
            ("/seed/account_email", serde_json::json!("nobody")),
        ];
        for (pointer, value) in cases {
            let mut candidate = descriptor();
            if let Some(slot) = candidate.pointer_mut(pointer) {
                *slot = value.clone();
            } else {
                let (parent, key) = pointer.rsplit_once('/').unwrap();
                candidate.pointer_mut(parent).unwrap()[key] = value.clone();
            }
            assert!(parse(&candidate).is_err(), "{pointer} = {value}");
        }
        let mut loopback = descriptor();
        *loopback.pointer_mut("/approver/url").unwrap() =
            serde_json::json!("http://127.0.0.1:9000/approve");
        assert!(parse(&loopback).is_ok());
        assert_eq!(
            JourneyDescriptor::parse(&vec![b' '; MAX_DESCRIPTOR_BYTES + 1]),
            Err(DescriptorError::TooLarge)
        );
        assert_eq!(
            JourneyDescriptor::parse(b"{"),
            Err(DescriptorError::Malformed)
        );
    }

    #[test]
    fn credentials_stay_out_of_process_arguments() {
        let parsed = parse(&descriptor()).unwrap();
        let fetcher = FixtureTrustFetcher {
            ca_path: Some(PathBuf::from("/private/ca.pem")),
            server_name: "localhost".into(),
            host: "localhost".into(),
            https_port: 8443,
        };
        let arguments = fetcher.arguments();
        assert_eq!(
            arguments.last().unwrap(),
            "https://localhost:8443/bin/ssh-trust.json"
        );
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["--max-redirs", "0"]));
        assert!(!arguments.iter().any(|argument| argument.contains("s3cr3t")));
        let routed = FixtureTrustFetcher {
            server_name: "fixture.test".into(),
            ..fetcher
        };
        assert!(routed
            .arguments()
            .contains(&"fixture.test:8443:localhost:8443".to_owned()));
        let config = approver_config(&parsed, Path::new("/private/ca.pem"));
        assert!(config.contains("Authorization: Bearer s3cr3t-token"));
        assert!(config.contains("max-redirs = 0"));
    }

    #[test]
    fn fixture_profile_is_accepted_by_the_gtk_profile_loader() {
        let parsed = parse(&descriptor()).unwrap();
        let profile = fixture_connection_profile(&parsed, Path::new("/private/ca.pem"));
        assert!(!profile.contains("s3cr3t"));
        let profiles =
            crate::connection_profile::ConnectionProfiles::parse(profile.as_bytes()).unwrap();
        let target = profiles
            .resolve(&DeploymentHost::parse("localhost").unwrap())
            .unwrap();
        assert_eq!(target.ssh_port(), 2222);
        assert_eq!(target.https_authority(), "localhost:8443");
        assert_eq!(target.ca_file(), Some(Path::new("/private/ca.pem")));
    }

    #[test]
    fn report_serializes_codes_only() {
        let mut report = JourneyReport::new();
        report.record("trust", true, "pinned");
        report.record("terminal", false, "marker_timeout");
        assert!(!report.ok);
        assert_eq!(
            serde_json::to_value(&report).unwrap(),
            serde_json::json!({
                "version": 1, "ok": false,
                "steps": [
                    {"name": "trust", "ok": true, "outcome": "pinned"},
                    {"name": "terminal", "ok": false, "outcome": "marker_timeout"}
                ]
            })
        );
    }
}
