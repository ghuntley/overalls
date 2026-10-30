//! Headless live-journey driver for the Linux client.
//!
//! `mila-linux-journey --descriptor <path>` runs the same GTK-independent
//! modules the GTK window uses (deployment list, sign-in coordinator pieces,
//! authenticated session, terminal surface, SSH-key view and deep-link
//! presentation) against a deployment described by the hermetic journey
//! fixture's descriptor. It prints a JSON report of typed step outcomes only:
//! no credentials, tokens, terminal bytes or server payloads are reported.

use crate::adapter::{decode_listing, new_request_id, RuntimeError};
use crate::deep_link::{present, Page};
use crate::deployments::{DeploymentHost, DeploymentStore};
use crate::machine_view::project_listing;
use crate::route::{share_inbound, share_route, ActivationBatch, MachinePage, Target};
use crate::session::{
    ApprovalInfo, DeviceSigner, FileDeviceSigner, LiveSession, SessionBinding,
    SessionConnectConfig, TrustEnrollment, TrustFetcher, TrustStore, WhoamiOutcome,
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
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct SeedSpec {
    pub machine_name: String,
    pub share_principal: String,
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
        if DeploymentHost::parse(&descriptor.tls.server_name)
            .map(|name| name.as_str() != descriptor.tls.server_name || name.as_str().contains(':'))
            .unwrap_or(true)
        {
            return Err(DescriptorError::InvalidField("tls.server_name"));
        }
        if !valid_approver_url(&descriptor.approver.url) {
            return Err(DescriptorError::InvalidField("approver.url"));
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
    fn new() -> Self {
        Self {
            version: 1,
            ok: true,
            steps: Vec::new(),
        }
    }

    fn record(&mut self, name: &'static str, ok: bool, outcome: &'static str) -> bool {
        self.ok &= ok;
        self.steps.push(StepReport { name, ok, outcome });
        ok
    }
}

/// In-memory trust pin for one journey run.
#[derive(Default)]
pub struct MemoryTrustStore(RefCell<Option<Vec<u8>>>);

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
pub struct FixtureTrustFetcher {
    pub ca_path: PathBuf,
    pub server_name: String,
    pub host: String,
    pub https_port: u16,
}

impl FixtureTrustFetcher {
    /// curl arguments; contains no credential.
    pub fn arguments(&self) -> Vec<String> {
        let port = self.https_port;
        let mut arguments = vec![
            "--fail".to_owned(),
            "--silent".to_owned(),
            "--show-error".to_owned(),
            "--proto".to_owned(),
            "=https".to_owned(),
            "--max-redirs".to_owned(),
            "0".to_owned(),
            "--max-time".to_owned(),
            "20".to_owned(),
            "--cacert".to_owned(),
            self.ca_path.display().to_string(),
        ];
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

impl TrustFetcher for FixtureTrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError> {
        if host != self.host {
            return Err(RuntimeError::InvalidInput);
        }
        let output = std::process::Command::new("curl")
            .args(self.arguments())
            .output()
            .map_err(|_| RuntimeError::Unavailable)?;
        if !output.status.success() {
            return Err(RuntimeError::Unavailable);
        }
        if output.stdout.is_empty() || output.stdout.len() > 8192 {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(output.stdout)
    }
}

/// curl config carrying the approver credential. Written to an owner-only
/// file so the token never appears in a process argument list.
pub fn approver_config(descriptor: &JourneyDescriptor, ca_path: &Path) -> String {
    format!(
        "url = \"{}\"\nrequest = \"POST\"\nheader = \"Authorization: Bearer {}\"\nheader = \"Content-Type: application/json\"\ncacert = \"{}\"\nfail\nsilent\nmax-time = 20\nmax-redirs = 0\n",
        descriptor.approver.url,
        descriptor.approver.bearer_token.0,
        ca_path.display()
    )
}

/// OpenSSH `ecdsa-sha2-nistp256` public key line and `SHA256:` fingerprint.
pub fn openssh_identity(key: &p256::ecdsa::SigningKey) -> (String, String) {
    use base64::Engine;
    use sha2::Digest;
    let point = key.verifying_key().to_encoded_point(false);
    let mut blob = Vec::new();
    for field in [
        b"ecdsa-sha2-nistp256".as_slice(),
        b"nistp256",
        point.as_bytes(),
    ] {
        blob.extend_from_slice(&u32::try_from(field.len()).expect("small").to_be_bytes());
        blob.extend_from_slice(field);
    }
    let public = format!(
        "ecdsa-sha2-nistp256 {}",
        base64::engine::general_purpose::STANDARD.encode(&blob)
    );
    let fingerprint = format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(sha2::Sha256::digest(&blob))
    );
    (public, fingerprint)
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn generate_device_key(path: &Path) -> Option<(FileDeviceSigner, String)> {
    use std::io::Read;
    let mut source = std::fs::File::open("/dev/urandom").ok()?;
    for _ in 0..8 {
        let mut bytes = [0_u8; 32];
        source.read_exact(&mut bytes).ok()?;
        let Ok(key) = p256::ecdsa::SigningKey::from_slice(&bytes) else {
            continue;
        };
        write_private(path, &bytes).ok()?;
        let (public, fingerprint) = openssh_identity(&key);
        let signer = FileDeviceSigner::load(path, public).ok()?;
        return Some((signer, fingerprint));
    }
    None
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

fn approve(descriptor: &JourneyDescriptor, workdir: &Path, ca: &Path, info: &ApprovalInfo) -> bool {
    let config = workdir.join("approver.curlrc");
    if write_private(&config, approver_config(descriptor, ca).as_bytes()).is_err() {
        return false;
    }
    let body = serde_json::json!({
        "approval_url": info.url,
        "fingerprint": info.fingerprint,
    });
    let result = (|| {
        use std::io::Write;
        let mut child = std::process::Command::new("curl")
            .arg("--config")
            .arg(&config)
            .arg("--data-binary")
            .arg("@-")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .ok()?;
        child
            .stdin
            .take()?
            .write_all(body.to_string().as_bytes())
            .ok()?;
        child.wait().ok().map(|status| status.success())
    })();
    let _ = std::fs::remove_file(&config);
    result.unwrap_or(false)
}

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
            ca_path: ca_path.clone(),
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
    let Some((signer, fingerprint)) = generate_device_key(&workdir.join("device-key")) else {
        report.record("device_key", false, "unavailable");
        return report;
    };
    report.record("device_key", true, "generated");

    // 5. Certificate-authenticated session and browser-approval completion.
    let (live, outcome) = sign_in(descriptor, workdir, &ca_path, &trust, &signer);
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
            .and_then(|bytes| decode_listing(&bytes).ok())
            .and_then(|listing| project_listing(&listing).ok())
            .and_then(|rows| {
                rows.into_iter()
                    .find(|row| row.name == descriptor.seed.machine_name)
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

        // 8. Machine sharing with the seeded principal, added then removed.
        let shared = {
            let mut session = binding.borrow_mut();
            session.session_mut().is_some_and(|live| {
                let add = new_request_id().is_some_and(|request| {
                    live.share_mutation(
                        id,
                        &descriptor.seed.share_principal,
                        Some("viewer"),
                        true,
                        &request,
                    )
                    .is_ok()
                });
                let remove = new_request_id().is_some_and(|request| {
                    live.share_mutation(id, &descriptor.seed.share_principal, None, false, &request)
                        .is_ok()
                });
                add && remove
            })
        };
        report.record(
            "sharing",
            shared,
            if shared { "added_removed" } else { "refused" },
        );
    }

    // 9. Terminal stream through HostPtyTransport and the GTK surface model.
    let terminal_outcome = run_terminal(&binding);
    report.record(
        "terminal",
        terminal_outcome == "marker_seen",
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
                .map(|live| live as &mut dyn SshKeySource),
        )
    };
    let revoke = |keys: &mut SshKeysView, id: &str| {
        let mut session = binding.borrow_mut();
        keys.revoke(
            session
                .session_mut()
                .map(|live| live as &mut dyn SshKeySource),
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
    let second = generate_device_key(&workdir.join("second-device-key"));
    let (second_session, second_outcome) = match second.as_ref() {
        Some((signer, _)) => sign_in(descriptor, workdir, &ca_path, &trust, signer),
        None => (None, "device_key_unavailable"),
    };
    if let (Some(mut second_session), Some((second_signer, second_fingerprint))) =
        (second_session, second.as_ref())
    {
        let _ = second_session.close();
        refresh(&mut keys);
        let target = keys.rows().into_iter().find(|row| {
            row.fingerprint == *second_fingerprint || row.fingerprint == second_fingerprint[7..]
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

/// Connects and completes browser approval through the fixture approver.
/// Returns the authenticated session or a fixed failure code.
fn sign_in<S: DeviceSigner>(
    descriptor: &JourneyDescriptor,
    workdir: &Path,
    ca_path: &Path,
    trust: &[u8],
    signer: &S,
) -> (Option<LiveSession>, &'static str) {
    let Some(mut live) = connect(descriptor, trust, signer) else {
        return (None, "connect_refused");
    };
    let mut approval_sent = false;
    for attempt in 0..APPROVAL_POLLS {
        match live.whoami() {
            Ok(WhoamiOutcome::Authenticated { .. }) => {
                return (
                    Some(live),
                    if approval_sent { "approved" } else { "already" },
                );
            }
            Ok(WhoamiOutcome::Approval { url, fingerprint }) => {
                let Ok(info) = ApprovalInfo::validate_for_host(
                    &url,
                    &fingerprint,
                    now(),
                    &descriptor.https_authority(),
                ) else {
                    return (None, "approval_origin_refused");
                };
                if !approval_sent {
                    if !approve(descriptor, workdir, ca_path, &info) {
                        return (None, "approver_failed");
                    }
                    approval_sent = true;
                } else if attempt % 15 == 0 {
                    // A deployment may bind approval to a fresh connection.
                    match connect(descriptor, trust, signer) {
                        Some(fresh) => live = fresh,
                        None => return (None, "reconnect_refused"),
                    }
                }
            }
            Ok(_) => return (None, "refused"),
            Err(_) => {}
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    (None, "approval_timeout")
}

fn run_terminal(binding: &Rc<RefCell<SessionBinding>>) -> &'static str {
    let backend = crate::session::SessionPtyBackend::new(binding.clone(), 100);
    let Ok(mut surface) =
        TerminalSurface::new(binding.clone(), HostPtyTransport::new(backend), 80, 24)
    else {
        return "renderer_refused";
    };
    if surface.attach("mila-linux-journey", 80, 24).is_err() {
        return "attach_refused";
    }
    let Some(marker) = new_request_id().map(|id| format!("mila-journey-{}", &id[8..20])) else {
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
        ];
        for (pointer, value) in cases {
            let mut candidate = descriptor();
            *candidate.pointer_mut(pointer).unwrap() = value.clone();
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
            ca_path: PathBuf::from("/private/ca.pem"),
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
    fn openssh_identity_matches_wire_format() {
        let key = p256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
        let (public, fingerprint) = openssh_identity(&key);
        assert!(public.starts_with("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY"));
        assert!(fingerprint.starts_with("SHA256:"));
        assert_eq!(fingerprint.len(), 7 + 43);
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
