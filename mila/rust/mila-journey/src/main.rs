//! Headless Mila journey driver.
//!
//! Drives a deployment through the same `extern "C"` session surface the Apple,
//! Linux and Windows shells link (`mila_ffi::session`), with an owner-only P-256
//! file signer standing in for platform key custody. Every step opens a fresh
//! certificate-pinned connection unless it says otherwise, prints exactly one
//! JSON object on stdout and exits non-zero on refusal. Private keys, bearer
//! tokens and terminal bytes never reach stdout; terminal output is reduced to
//! marker booleans.

use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
    Engine,
};
use mila_ffi::session::{self as ffi, SessionStatus};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const OUTPUT: usize = 1 << 20;
const TIMEOUT_MS: u32 = 60_000;

/// Fixture descriptor v1 shared with the platform journey modes.
#[derive(Clone, Debug, Deserialize)]
struct Descriptor {
    version: u8,
    deployment: Deployment,
    tls: Tls,
    approver: Option<Approver>,
}
#[derive(Clone, Debug, Deserialize)]
struct Deployment {
    host: String,
    ssh_port: u16,
    https_port: u16,
}
#[derive(Clone, Debug, Deserialize)]
struct Tls {
    ca_pem: String,
    server_name: Option<String>,
}
#[derive(Clone, Debug, Deserialize)]
struct Approver {
    url: String,
    bearer_token: String,
}

/// A failure carries only a closed stage name and an FFI status or reason.
#[derive(Debug)]
struct Failure {
    stage: &'static str,
    reason: String,
}
type Outcome<T> = Result<T, Failure>;

fn fail<T>(stage: &'static str, reason: impl Into<String>) -> Outcome<T> {
    Err(Failure {
        stage,
        reason: reason.into(),
    })
}
fn status(stage: &'static str, code: SessionStatus) -> Outcome<()> {
    if code == SessionStatus::Ok {
        Ok(())
    } else {
        fail(stage, format!("status {}", code as i32))
    }
}

/// Owner-only private state for one deployment: device key and pinned trust.
struct State {
    root: PathBuf,
}
impl State {
    /// @cc [owner:ghuntley,label:security] mila-journey-owner-only-state
    /// The driver's state directory and device key MUST be owner-only; a key
    /// file readable by group or others MUST be refused, never repaired.
    fn open(root: &Path) -> Outcome<Self> {
        if !root.exists() {
            fs::create_dir_all(root).or_else(|_| fail("state", "create"))?;
            fs::set_permissions(root, fs::Permissions::from_mode(0o700))
                .or_else(|_| fail("state", "chmod"))?;
        }
        let mode = fs::metadata(root)
            .or_else(|_| fail("state", "stat"))?
            .permissions()
            .mode();
        if mode & 0o077 != 0 {
            return fail("state", "state directory is not owner-only");
        }
        Ok(Self { root: root.into() })
    }
    fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }
    fn write_private(&self, name: &str, data: &[u8]) -> Outcome<()> {
        let path = self.path(name);
        let _ = fs::remove_file(&path);
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .or_else(|_| fail("state", "write"))?;
        file.write_all(data).or_else(|_| fail("state", "write"))
    }
    fn key(&self, create: bool) -> Outcome<SigningKey> {
        let path = self.path("device.key");
        if !path.exists() {
            if !create {
                return fail("key", "no device key; run enroll");
            }
            loop {
                let mut seed = [0u8; 32];
                fs::File::open("/dev/urandom")
                    .and_then(|mut random| random.read_exact(&mut seed))
                    .or_else(|_| fail("key", "random"))?;
                if let Ok(key) = SigningKey::from_bytes(&seed.into()) {
                    self.write_private("device.key", hex(&seed).as_bytes())?;
                    return Ok(key);
                }
            }
        }
        let mode = fs::metadata(&path)
            .or_else(|_| fail("key", "stat"))?
            .permissions()
            .mode();
        if mode & 0o077 != 0 {
            return fail("key", "device key is readable by others");
        }
        let text = fs::read_to_string(&path).or_else(|_| fail("key", "read"))?;
        let raw = unhex(text.trim()).ok_or(Failure {
            stage: "key",
            reason: "malformed".into(),
        })?;
        let raw: [u8; 32] = raw.try_into().or_else(|_| fail("key", "malformed"))?;
        SigningKey::from_bytes(&raw.into()).or_else(|_| fail("key", "malformed"))
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

/// OpenSSH `ecdsa-sha2-nistp256` public key line and SHA256 fingerprint.
fn public_key(key: &SigningKey) -> (String, String) {
    let point = key.verifying_key().to_encoded_point(false);
    let mut blob = Vec::new();
    for field in [
        b"ecdsa-sha2-nistp256".as_slice(),
        b"nistp256".as_slice(),
        point.as_bytes(),
    ] {
        blob.extend_from_slice(&(field.len() as u32).to_be_bytes());
        blob.extend_from_slice(field);
    }
    let line = format!("ecdsa-sha2-nistp256 {}", STANDARD.encode(&blob));
    let fingerprint = format!("SHA256:{}", STANDARD_NO_PAD.encode(Sha256::digest(&blob)));
    (line, fingerprint)
}

/// FFI signer: sign SHA-256(message) with the device key, writing r || s.
unsafe extern "C" fn sign(context: usize, message: *const u8, length: usize, out: *mut u8) -> i32 {
    if context == 0 || message.is_null() || out.is_null() {
        return 1;
    }
    // SAFETY: context is the &SigningKey passed to connect, live for its duration.
    let key = unsafe { &*(context as *const SigningKey) };
    // SAFETY: the FFI guarantees `length` readable bytes and 64 writable bytes.
    let message = unsafe { std::slice::from_raw_parts(message, length) };
    let signature: Signature = key.sign(message);
    let bytes = signature.to_bytes();
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, 64) };
    0
}

struct Driver {
    descriptor: Descriptor,
    state: State,
}

/// One authenticated FFI session handle, closed on drop.
struct Session(u64);
impl Drop for Session {
    fn drop(&mut self) {
        let _ = ffi::mila_session_close(self.0);
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn json_bytes(stage: &'static str, data: &[u8]) -> Outcome<Value> {
    serde_json::from_slice(data).or_else(|_| fail(stage, "invalid JSON"))
}

/// Copy one JSON result out of a buffer-filling FFI call.
fn read_json(
    stage: &'static str,
    call: impl FnOnce(*mut u8, usize, *mut usize) -> SessionStatus,
) -> Outcome<Value> {
    let mut buffer = vec![0u8; OUTPUT];
    let mut written = 0usize;
    status(stage, call(buffer.as_mut_ptr(), buffer.len(), &mut written))?;
    json_bytes(stage, &buffer[..written.min(buffer.len())])
}

/// A fresh canonical Mila request id (`porsche-` + 32 lowercase hex).
fn request_id() -> String {
    format!("porsche-{}", uuid::Uuid::new_v4().simple())
}

impl Driver {
    fn server_name(&self) -> &str {
        self.descriptor
            .tls
            .server_name
            .as_deref()
            .unwrap_or(&self.descriptor.deployment.host)
    }

    /// @cc [owner:ghuntley,label:security] mila-journey-https-trust-fetch
    /// Trust enrollment MUST fetch over HTTPS verified by the descriptor CA with
    /// redirects refused and an 8 KiB bound, then decode and reconcile the
    /// document in the Rust core; a changed authority MUST be refused.
    fn fetch_trust(&self) -> Outcome<Vec<u8>> {
        self.state
            .write_private("ca.pem", self.descriptor.tls.ca_pem.as_bytes())?;
        let deployment = &self.descriptor.deployment;
        let server = self.server_name().to_owned();
        let url = format!(
            "https://{server}:{}/bin/ssh-trust.json",
            deployment.https_port
        );
        let mut command = Command::new("curl");
        command.args([
            "--silent",
            "--fail",
            "--proto",
            "=https",
            "--max-redirs",
            "0",
            "--max-filesize",
            "8192",
            "--max-time",
            "30",
            "--cacert",
        ]);
        command.arg(self.state.path("ca.pem"));
        if server != deployment.host {
            command.arg("--connect-to").arg(format!(
                "{server}:{port}:{host}:{port}",
                port = deployment.https_port,
                host = deployment.host
            ));
        }
        command.arg(url);
        let output = command.output().or_else(|_| fail("trust", "curl"))?;
        if !output.status.success() || output.stdout.len() > 8192 {
            return fail("trust", "HTTPS trust fetch refused");
        }
        let fetched =
            mila_transport::decode_trust_document(&output.stdout, &deployment.host, now())
                .or_else(|e| fail("trust", e.to_string()))?;
        let pinned_path = self.state.path("trust.json");
        let pinned = if pinned_path.exists() {
            let bytes = fs::read(&pinned_path).or_else(|_| fail("trust", "pin read"))?;
            Some(
                mila_transport::decode_trust_document(&bytes, &deployment.host, now())
                    .or_else(|e| fail("trust", e.to_string()))?,
            )
        } else {
            None
        };
        let chosen = mila_transport::reconcile_trust(pinned.as_ref(), fetched)
            .or_else(|e| fail("trust", e.to_string()))?;
        let bytes = serde_json::to_vec(&chosen).or_else(|_| fail("trust", "encode"))?;
        self.state.write_private("trust.json", &bytes)?;
        Ok(bytes)
    }

    fn connect(&self, key: &SigningKey) -> Outcome<Session> {
        let trust = fs::read(self.state.path("trust.json"))
            .or_else(|_| fail("connect", "no pinned trust; run enroll"))?;
        let host = &self.descriptor.deployment.host;
        let (line, _) = public_key(key);
        let mut handle = 0u64;
        // SAFETY: all buffers live for the call; the key outlives the connect.
        let code = unsafe {
            ffi::mila_session_connect(
                trust.as_ptr(),
                trust.len(),
                host.as_ptr(),
                host.len(),
                line.as_ptr(),
                line.len(),
                self.descriptor.deployment.ssh_port,
                TIMEOUT_MS,
                Some(sign),
                key as *const SigningKey as usize,
                &mut handle,
            )
        };
        status("connect", code)?;
        Ok(Session(handle))
    }

    fn whoami(&self, session: &Session) -> Outcome<Value> {
        read_json("whoami", |out, capacity, written| unsafe {
            ffi::mila_session_whoami(session.0, out, capacity, written)
        })
    }

    fn approve(&self, approval_url: &str, fingerprint: &str, public_key: &str) -> Outcome<()> {
        let approver = self.descriptor.approver.clone().ok_or(Failure {
            stage: "approval",
            reason: "descriptor has no approver".into(),
        })?;
        self.state.write_private(
            "approver.header",
            format!("Authorization: Bearer {}\n", approver.bearer_token).as_bytes(),
        )?;
        let body = json!({"approval_url": approval_url, "fingerprint": fingerprint});
        // @cc [owner:ghuntley,label:verification;security] mila-journey-file-approver
        // A `file://` approver hands the pending approval to an out-of-process
        // browser as one owner-only, newly created file (the fleet harness's
        // pending.json contract). It MUST NOT overwrite an existing file.
        if let Some(path) = approver.url.strip_prefix("file://") {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .or_else(|_| fail("approval", "pending approval file unavailable"))?;
            // The out-of-process approver derives the fingerprint it compares
            // from this public key line itself.
            let pending = json!({
                "approval_url": approval_url,
                "fingerprint": fingerprint,
                "public_key": public_key,
            });
            file.write_all(pending.to_string().as_bytes())
                .or_else(|_| fail("approval", "pending approval write"))?;
            return Ok(());
        }
        self.state
            .write_private("approval.json", body.to_string().as_bytes())?;
        let output = Command::new("curl")
            .args([
                "--silent",
                "--fail",
                "--proto",
                "=https",
                "--max-redirs",
                "0",
                "--max-time",
                "300",
                "--cacert",
            ])
            .arg(self.state.path("ca.pem"))
            .arg("--header")
            .arg(format!("@{}", self.state.path("approver.header").display()))
            .args([
                "--header",
                "content-type: application/json",
                "--data-binary",
            ])
            .arg(format!("@{}", self.state.path("approval.json").display()))
            .arg("--output")
            .arg("/dev/null")
            .arg(&approver.url)
            .output()
            .or_else(|_| fail("approval", "curl"))?;
        let _ = fs::remove_file(self.state.path("approver.header"));
        let _ = fs::remove_file(self.state.path("approval.json"));
        if output.status.success() {
            Ok(())
        } else {
            fail("approval", "approver refused")
        }
    }

    /// Enrollment: trust fetch, device key, approval on one live session, then
    /// same-session whoami polling until Porsche reports the approved account.
    fn enroll(&self) -> Outcome<Value> {
        self.fetch_trust()?;
        let key = self.state.key(true)?;
        let (line, fingerprint) = public_key(&key);
        let session = self.connect(&key)?;
        let first = self.whoami(&session)?;
        let mut approved_by_browser = false;
        if first["status"] == "approval_required" {
            if first["fingerprint"] != fingerprint.as_str() {
                return fail("approval", "server fingerprint differs from device key");
            }
            let url = first["approval_url"].as_str().ok_or(Failure {
                stage: "approval",
                reason: "no approval link".into(),
            })?;
            let origin = match self.descriptor.deployment.https_port {
                443 => format!("https://{}/ssh/approve/", self.server_name()),
                port => format!("https://{}:{port}/ssh/approve/", self.server_name()),
            };
            if !url.starts_with(&origin) {
                return fail("approval", "approval link is not on the deployment origin");
            }
            self.approve(url, &fingerprint, &line)?;
            approved_by_browser = true;
        }
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            let current = self.whoami(&session)?;
            if current["status"] == "succeeded" {
                let result = &current["result"];
                return Ok(json!({
                    "step": "enroll",
                    "approved_by_browser": approved_by_browser,
                    "fingerprint": fingerprint,
                    "email": result["email"],
                    "account_id": result["id"],
                    "public_key_matches": result["public_key"] == line.as_str(),
                }));
            }
            if Instant::now() > deadline {
                return fail("approval", "approval did not complete");
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    }

    fn receipt(&self, session: &Session, id: &str) -> Outcome<Value> {
        read_json("request show", |out, capacity, written| unsafe {
            ffi::mila_session_request_show(session.0, id.as_ptr(), id.len(), out, capacity, written)
        })
    }

    fn listing(&self, session: &Session) -> Outcome<Value> {
        status("ls", ffi::mila_session_read_machines(session.0, 0))?;
        read_json("ls", |out, capacity, written| unsafe {
            ffi::mila_session_listing(session.0, out, capacity, written)
        })
    }

    /// Attach the session's closed refusal code to a failed step.
    fn refused(session: &Session, failure: Failure) -> Failure {
        let code = read_json("refusal", |out, capacity, written| unsafe {
            ffi::mila_session_last_refusal(session.0, out, capacity, written)
        })
        .ok()
        .and_then(|value| value["error"].as_str().map(str::to_owned));
        match code {
            Some(code) => Failure {
                stage: failure.stage,
                reason: format!("{} ({code})", failure.reason),
            },
            None => failure,
        }
    }

    fn run(&self, step: &str, args: &[String]) -> Outcome<Value> {
        if step == "enroll" {
            return self.enroll();
        }
        if step == "forget" {
            // Deployment forget is local: drop the pin and the device key.
            for name in ["trust.json", "device.key", "ca.pem"] {
                let _ = fs::remove_file(self.state.path(name));
            }
            return Ok(
                json!({"step": "forget", "forgotten": !self.state.path("device.key").exists() && !self.state.path("trust.json").exists()}),
            );
        }
        if step == "trust" {
            let bytes = self.fetch_trust()?;
            return Ok(json!({"step": "trust", "pinned": json_bytes("trust", &bytes)?}));
        }
        let key = self.state.key(false)?;
        let session = self.connect(&key)?;
        self.authenticated(&session, step, args)
            .map_err(|failure| Self::refused(&session, failure))
    }

    fn authenticated(&self, session: &Session, step: &str, args: &[String]) -> Outcome<Value> {
        let arg = |index: usize| -> Outcome<&str> {
            args.get(index).map(String::as_str).ok_or(Failure {
                stage: "arguments",
                reason: format!("{step} needs argument {index}"),
            })
        };
        let rid = request_id();
        match step {
            "whoami" => Ok(json!({"step": step, "whoami": self.whoami(session)?})),
            "ls" => Ok(json!({"step": step, "listing": self.listing(session)?})),
            "snapshot" => {
                self.listing(session)?;
                let snapshot = read_json("snapshot", |out, capacity, written| unsafe {
                    ffi::mila_session_snapshot(session.0, now(), out, capacity, written)
                })?;
                Ok(json!({"step": step, "snapshot": snapshot}))
            }
            "create" => {
                let name = arg(0)?;
                let cpu: u32 = arg(1)?.parse().or_else(|_| fail("create", "cpu"))?;
                let memory: u64 = arg(2)?.parse().or_else(|_| fail("create", "memory"))?;
                let disk: u64 = arg(3)?.parse().or_else(|_| fail("create", "disk"))?;
                status("create", unsafe {
                    ffi::mila_session_machine_create(
                        session.0,
                        name.as_ptr(),
                        name.len(),
                        cpu,
                        memory,
                        disk,
                        rid.as_ptr(),
                        rid.len(),
                    )
                })?;
                Ok(
                    json!({"step": step, "request_id": rid, "receipt": self.receipt(session, &rid)?}),
                )
            }
            "resize" => {
                let machine = arg(0)?;
                let cpu: u32 = arg(1)?.parse().or_else(|_| fail("resize", "cpu"))?;
                let memory: u64 = arg(2)?.parse().or_else(|_| fail("resize", "memory"))?;
                let disk: u64 = arg(3)?.parse().or_else(|_| fail("resize", "disk"))?;
                status("resize", unsafe {
                    ffi::mila_session_machine_resize(
                        session.0,
                        machine.as_ptr(),
                        machine.len(),
                        cpu,
                        memory,
                        disk,
                        rid.as_ptr(),
                        rid.len(),
                    )
                })?;
                Ok(
                    json!({"step": step, "request_id": rid, "receipt": self.receipt(session, &rid)?}),
                )
            }
            "action" => {
                let machine = arg(0)?;
                let action = arg(1)?;
                status("action", unsafe {
                    ffi::mila_session_machine_action(
                        session.0,
                        machine.as_ptr(),
                        machine.len(),
                        action.as_ptr(),
                        action.len(),
                        rid.as_ptr(),
                        rid.len(),
                    )
                })?;
                Ok(
                    json!({"step": step, "action": action, "request_id": rid, "receipt": self.receipt(session, &rid)?}),
                )
            }
            "share-add" | "share-remove" => {
                let machine = arg(0)?;
                let email = arg(1)?;
                let role = if step == "share-add" { arg(2)? } else { "" };
                status("share", unsafe {
                    ffi::mila_session_share_mutation(
                        session.0,
                        machine.as_ptr(),
                        machine.len(),
                        email.as_ptr(),
                        email.len(),
                        role.as_ptr(),
                        role.len(),
                        u8::from(step == "share-add"),
                        rid.as_ptr(),
                        rid.len(),
                    )
                })?;
                Ok(
                    json!({"step": step, "request_id": rid, "receipt": self.receipt(session, &rid)?}),
                )
            }
            "thread" => {
                // thread COMMAND [THREAD] [SECONDARY] [STDIN]
                let command = arg(0)?;
                let thread = args.get(1).map(String::as_str).unwrap_or("");
                let secondary = args.get(2).map(String::as_str).unwrap_or("");
                let input = args.get(3).map(String::as_str).unwrap_or("");
                let mutation = matches!(
                    command,
                    "thread prompt"
                        | "thread answer"
                        | "thread plan approve"
                        | "thread plan revise"
                );
                let request = if mutation { rid.as_str() } else { "" };
                let value = read_json("thread", |out, capacity, written| unsafe {
                    ffi::mila_session_thread_action(
                        session.0,
                        thread.as_ptr(),
                        thread.len(),
                        command.as_ptr(),
                        command.len(),
                        secondary.as_ptr(),
                        secondary.len(),
                        input.as_ptr(),
                        input.len(),
                        request.as_ptr(),
                        request.len(),
                        out,
                        capacity,
                        written,
                    )
                })?;
                Ok(
                    json!({"step": step, "command": command, "request_id": if mutation { Value::from(rid) } else { Value::Null }, "result": value}),
                )
            }
            "web-show" => {
                let machine = arg(0)?;
                let value = read_json("web show", |out, capacity, written| unsafe {
                    ffi::mila_session_web_show(
                        session.0,
                        machine.as_ptr(),
                        machine.len(),
                        out,
                        capacity,
                        written,
                    )
                })?;
                Ok(json!({"step": step, "web": value}))
            }
            "web-set" => {
                let machine = arg(0)?;
                let port: u16 = arg(1)?.parse().or_else(|_| fail("web set", "port"))?;
                let public = arg(2)? == "public";
                let revision: u64 = arg(3)?.parse().or_else(|_| fail("web set", "revision"))?;
                status("web set", unsafe {
                    ffi::mila_session_web_set(
                        session.0,
                        machine.as_ptr(),
                        machine.len(),
                        port,
                        u8::from(public),
                        revision,
                        rid.as_ptr(),
                        rid.len(),
                    )
                })?;
                Ok(
                    json!({"step": step, "request_id": rid, "receipt": self.receipt(session, &rid)?}),
                )
            }
            "ssh-keys" => {
                let value = read_json("ssh-key list", |out, capacity, written| unsafe {
                    ffi::mila_session_ssh_keys(session.0, out, capacity, written)
                })?;
                Ok(json!({"step": step, "keys": value}))
            }
            "ssh-key-revoke" => {
                let id = arg(0)?;
                status("ssh-key remove", unsafe {
                    ffi::mila_session_ssh_key_revoke(
                        session.0,
                        id.as_ptr(),
                        id.len(),
                        rid.as_ptr(),
                        rid.len(),
                    )
                })?;
                Ok(json!({"step": step, "request_id": rid}))
            }
            "device-register" => {
                let platform: u8 = match arg(0)? {
                    "ios" => 0,
                    "android" => 1,
                    "macos" => 2,
                    "windows" => 3,
                    _ => return fail("device register", "platform"),
                };
                // The fixture has no Susan; stand in for its key-issuance reply
                // so the core's own Susan validation and stdin path still run.
                let reply = json!({
                    "push_key": arg(1)?,
                    "key_id": "mila-journey",
                    "expires_at": "2099-01-01T00:00:00Z",
                })
                .to_string();
                let enc = arg(2)?;
                let value = read_json("device register", |out, capacity, written| unsafe {
                    ffi::mila_session_device_register(
                        session.0,
                        platform,
                        reply.as_ptr(),
                        reply.len(),
                        enc.as_ptr(),
                        enc.len(),
                        std::ptr::null(),
                        0,
                        now(),
                        out,
                        capacity,
                        written,
                    )
                })?;
                Ok(json!({"step": step, "receipt": value}))
            }
            "device-ls" => {
                let value = read_json("device ls", |out, capacity, written| unsafe {
                    ffi::mila_session_device_ls(session.0, out, capacity, written)
                })?;
                Ok(json!({"step": step, "devices": value}))
            }
            "device-rm" => {
                let id = arg(0)?;
                status("device rm", unsafe {
                    ffi::mila_session_device_rm(session.0, id.as_ptr(), id.len())
                })?;
                Ok(json!({"step": step}))
            }
            "device-prefs" => {
                let id = arg(0)?;
                let enabled = arg(1)? == "true";
                status("device prefs", unsafe {
                    ffi::mila_session_device_prefs(
                        session.0,
                        id.as_ptr(),
                        id.len(),
                        u8::from(enabled),
                    )
                })?;
                Ok(json!({"step": step, "enabled": enabled}))
            }
            "terminal" => self.terminal(session, arg(0)?),
            _ => fail("arguments", "unknown step"),
        }
    }

    fn poll_until(&self, terminal: u64, marker: &str, seconds: u64) -> Outcome<bool> {
        let deadline = Instant::now() + Duration::from_secs(seconds);
        let mut seen = Vec::new();
        while Instant::now() < deadline {
            let mut buffer = vec![0u8; OUTPUT];
            let mut written = 0usize;
            let code = unsafe {
                ffi::mila_session_terminal_poll(
                    terminal,
                    buffer.as_mut_ptr(),
                    buffer.len(),
                    &mut written,
                )
            };
            if code != SessionStatus::Ok {
                // A bounded read timeout is not a failure while waiting.
                continue;
            }
            seen.extend_from_slice(&buffer[..written]);
            if seen.len() > 4 * OUTPUT {
                seen.drain(..seen.len() - OUTPUT);
            }
            if String::from_utf8_lossy(&seen).contains(marker) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Terminal: open personal session, attach a PTY, type a marker command,
    /// resize, detach, reattach and see the replayed marker, then kill it.
    fn terminal(&self, session: &Session, machine: &str) -> Outcome<Value> {
        let rid = request_id();
        let created = read_json("terminal new", |out, capacity, written| unsafe {
            ffi::mila_session_terminal_new(
                session.0,
                machine.as_ptr(),
                machine.len(),
                rid.as_ptr(),
                rid.len(),
                out,
                capacity,
                written,
            )
        })?;
        let terminal_id = created["result"]["session_id"]
            .as_str()
            .ok_or(Failure {
                stage: "terminal new",
                reason: "no session id".into(),
            })?
            .to_owned();
        let attach = |columns: u32, rows: u32| -> Outcome<u64> {
            let mut handle = 0u64;
            status("terminal attach", unsafe {
                ffi::mila_session_terminal_attach_session(
                    session.0,
                    machine.as_ptr(),
                    machine.len(),
                    terminal_id.as_ptr(),
                    terminal_id.len(),
                    columns,
                    rows,
                    &mut handle,
                )
            })?;
            Ok(handle)
        };
        let marker = format!("mila-{}", &uuid::Uuid::new_v4().simple().to_string()[..12]);
        let first = attach(100, 30)?;
        let typed = format!("echo {marker}-$((6*7))\r");
        status("terminal input", unsafe {
            ffi::mila_session_terminal_input(first, typed.as_ptr(), typed.len())
        })?;
        let output_seen = self.poll_until(first, &format!("{marker}-42"), 60)?;
        status(
            "terminal resize",
            ffi::mila_session_terminal_resize(first, 132, 40),
        )?;
        let probe = "stty size\r";
        status("terminal input", unsafe {
            ffi::mila_session_terminal_input(first, probe.as_ptr(), probe.len())
        })?;
        let resized = self.poll_until(first, "40 132", 30)?;
        status("terminal detach", ffi::mila_session_terminal_kill(first))?;
        let second = attach(132, 40)?;
        let replayed = self.poll_until(second, &format!("{marker}-42"), 60)?;
        status("terminal detach", ffi::mila_session_terminal_kill(second))?;
        let kill_id = request_id();
        let killed = read_json("terminal kill", |out, capacity, written| unsafe {
            ffi::mila_session_terminal_end(
                session.0,
                machine.as_ptr(),
                machine.len(),
                terminal_id.as_ptr(),
                terminal_id.len(),
                kill_id.as_ptr(),
                kill_id.len(),
                out,
                capacity,
                written,
            )
        })?;
        Ok(json!({
            "step": "terminal",
            "session_id": terminal_id,
            "output_seen": output_seen,
            "resized": resized,
            "replayed_after_reconnect": replayed,
            "killed": killed["result"]["closed"] == true,
        }))
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut descriptor_path = None;
    let mut state_path = None;
    let mut rest = Vec::new();
    let mut iter = args.into_iter();
    while let Some(value) = iter.next() {
        match value.as_str() {
            "--descriptor" => descriptor_path = iter.next(),
            "--state" => state_path = iter.next(),
            _ => rest.push(value),
        }
    }
    let result = (|| -> Outcome<Value> {
        let descriptor_path = descriptor_path.ok_or(Failure {
            stage: "arguments",
            reason: "--descriptor is required".into(),
        })?;
        let state_path = state_path.ok_or(Failure {
            stage: "arguments",
            reason: "--state is required".into(),
        })?;
        let bytes = fs::read(&descriptor_path).or_else(|_| fail("descriptor", "read"))?;
        let descriptor: Descriptor =
            serde_json::from_slice(&bytes).or_else(|_| fail("descriptor", "invalid"))?;
        if descriptor.version != 1 {
            return fail("descriptor", "unsupported version");
        }
        let driver = Driver {
            descriptor,
            state: State::open(Path::new(&state_path))?,
        };
        let (step, args) = rest.split_first().ok_or(Failure {
            stage: "arguments",
            reason: "a step is required".into(),
        })?;
        driver.run(step, args)
    })();
    match result {
        Ok(value) => {
            println!("{}", json!({"ok": true, "value": value}));
        }
        Err(failure) => {
            println!(
                "{}",
                json!({"ok": false, "stage": failure.stage, "reason": failure.reason})
            );
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{hex, unhex};
    use hegel::{generators as gs, TestCase};

    /// @cc [owner:ghuntley,label:verification;security] mila-journey-key-hex-codec
    /// The device-key file codec MUST round-trip arbitrary bytes through
    /// lowercase hex, and `unhex` MUST refuse odd-length and non-ASCII text,
    /// accept every even-length hex string and decode to half the input length.
    #[hegel::test(test_cases = 128)]
    fn device_key_hex_round_trips_and_refuses_malformed_text(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(64));
        let encoded = hex(&bytes);
        assert_eq!(encoded.len(), bytes.len() * 2);
        assert!(encoded
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)));
        assert_eq!(unhex(&encoded), Some(bytes));
        assert_eq!(unhex(&encoded.to_ascii_uppercase()), unhex(&encoded));

        let text = if tc.draw(gs::booleans()) {
            tc.draw(gs::text().max_size(66))
        } else {
            let alphabet: Vec<char> = "0123456789abcdefABCDEFg+- \u{e9}".chars().collect();
            tc.draw(gs::vecs(gs::sampled_from(alphabet)).max_size(66))
                .into_iter()
                .collect()
        };
        match unhex(&text) {
            Some(decoded) => {
                assert!(text.is_ascii());
                assert_eq!(decoded.len() * 2, text.len());
            }
            None => {
                assert!(text.len() % 2 == 1 || !text.bytes().all(|byte| byte.is_ascii_hexdigit()))
            }
        }
    }
}
