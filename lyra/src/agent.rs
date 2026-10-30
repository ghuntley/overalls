//! Guest agent tool executor shared by Linux, Windows and native Unix guests.
//!
//! The control loop, fencing, the closed wire shapes and the tools live here;
//! the operating system supplies only what differs through [`Host`] (the
//! running binary's digest, diagnostics, stop and ready markers) and the
//! `cfg`-selected command runner and path rule below.
use crate::http;
use reqwest::Method;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, Read};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

mod artifact_stage;
mod attachment;
mod context;
pub mod maintenance;
mod managed_skills;
#[cfg(all(
    unix,
    any(
        target_os = "freebsd",
        target_os = "illumos",
        target_os = "solaris",
        test
    )
))]
mod native_command;
mod web_fetch;

const ORIGIN: &str = "https://llm.internal/agent/v1/";
const OUTPUT_LIMIT: usize = 4096;
/// Seconds an `exec_command` may run before its process tree is killed.
const COMMAND_SECONDS: u64 = 20;
/// Largest serialized control RPC body; only `attachment/transfer` and
/// `artifact_chunk` may exceed it.
const RPC_BODY_LIMIT: usize = 12_288;
/// Largest `attachment/transfer` request and response body.
const ATTACHMENT_TRANSFER_BODY_LIMIT: usize = 360_448;
/// Largest serialized `artifact_chunk` body: one base64 196_608-byte chunk
/// (`262_144` bytes) plus the fixed identity fields, within Ziggy's route limit.
const ARTIFACT_CHUNK_BODY_LIMIT: usize = 270_336;

#[derive(Debug)]
pub struct AgentError;

/// Closed web-fetch diagnostics; URLs, bodies and errors have no field.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FetchEvent {
    Started,
    Completed,
    Failed,
}

/// What the executor needs from the guest operating system.
pub trait Host {
    /// Digest of the running executor binary, registered with each fence.
    fn digest(&self) -> io::Result<String>;
    /// Record one tool result (identifier, outcome and duration only).
    fn tool_result(&self, command_id: &str, completed: bool, duration: Duration);
    /// Record one closed web-fetch event.
    fn fetch_event(&self, event: FetchEvent);
    /// Whether the supervisor asked the executor to stop.
    fn stop_requested(&self) -> bool;
    /// Publish that this binary registered a fence.
    fn ready(&self, digest: &str);
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    executor_id: String,
    fence_epoch: u64,
    expires_at_ms: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Claim {
    command: Option<AgentCommand>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentCommand {
    id: String,
    call_id: String,
    tool: String,
    arguments: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExecArguments {
    cmd: String,
    workdir: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadArguments {
    path: String,
}

#[derive(Serialize)]
struct LeaseRequest<'a> {
    executor_id: &'a str,
    fence_epoch: u64,
}

#[derive(Serialize)]
struct TransitionRequest<'a> {
    executor_id: &'a str,
    fence_epoch: u64,
    command_id: &'a str,
    status: &'a str,
    result: Value,
}

// @cc [owner:ghuntley,label:security;recovery] lyra-agent-fenced-execution
// The guest MUST receive commands only from the private TLS endpoint and MUST
// report started before any tool side effect. Failed transition or lease RPCs
// MUST stop execution; a restarted executor registers a new fence. Never log
// command text, tool output or response bodies.
pub fn run(host: &impl Host) -> Result<i32, AgentError> {
    loop {
        if host.stop_requested() {
            return Ok(0);
        }
        let digest = host.digest().map_err(|_| AgentError)?;
        match rpc::<Registration, _>(
            "register",
            &json!({"digest": digest, "capabilities": ["context-v1", "skills-v1", "github-tools-v1", "attachments-v1", "artifacts-v1"]}),
        ) {
            Ok(registration)
                if registration.fence_epoch > 0 && !registration.executor_id.is_empty() =>
            {
                host.ready(&digest);
                let _ = session(host, &registration);
            }
            _ => {}
        }
        thread::sleep(Duration::from_secs(5));
    }
}

fn session(host: &impl Host, registration: &Registration) -> Result<(), AgentError> {
    // @cc [owner:ghuntley,label:security;recovery] lyra-agent-claim-failure-closed
    // Claim, heartbeat and registration RPC failures are deliberately
    // indistinguishable from transport outage: the executor carries no user
    // credential and revocations surface only as lease/RPC failures, so it
    // MUST NOT branch on error kinds. The outer run loop retries registration
    // every 5 seconds until the stop marker; a revoked authority therefore
    // yields a bounded closed-refusal cadence instead of unbounded silent work.
    let _ = registration.expires_at_ms;
    let lease = LeaseRequest {
        executor_id: &registration.executor_id,
        fence_epoch: registration.fence_epoch,
    };
    let mut last_heartbeat = Instant::now();
    maintenance::reconcile().map_err(|_| AgentError)?;

    loop {
        if host.stop_requested() {
            return Err(AgentError);
        }
        if last_heartbeat.elapsed() >= Duration::from_secs(10) {
            let _: Value = rpc("heartbeat", &lease)?;
            last_heartbeat = Instant::now();
        }

        if maintenance::poll(host, &lease)? {
            last_heartbeat = Instant::now();
            continue;
        }
        let claimed: Claim = rpc("claim", &lease)?;
        match claimed.command {
            Some(command) => {
                let _: Value = rpc("heartbeat", &lease)?;
                last_heartbeat = Instant::now();
                execute(host, &lease, &command)?;
            }
            None => thread::sleep(Duration::from_secs(1)),
        }
    }
}

fn execute(
    host: &impl Host,
    lease: &LeaseRequest<'_>,
    command: &AgentCommand,
) -> Result<(), AgentError> {
    if !valid_identifier(&command.id) || command.call_id.is_empty() {
        return Err(AgentError);
    }

    let _: Value = rpc(
        "transition",
        &TransitionRequest {
            executor_id: lease.executor_id,
            fence_epoch: lease.fence_epoch,
            command_id: &command.id,
            status: "started",
            result: json!({}),
        },
    )?;

    let started = Instant::now();
    let mut heartbeat_at = Instant::now();
    let mut lease_valid = true;
    let mut heartbeat = || {
        if host.stop_requested() || !lease_valid {
            lease_valid = false;
            return false;
        }
        if heartbeat_at.elapsed() >= Duration::from_secs(5) {
            lease_valid = rpc::<Value, _>("heartbeat", lease).is_ok();
            heartbeat_at = Instant::now();
        }
        lease_valid
    };
    let (status, result) = match command.tool.as_str() {
        "exec_command" => run_command(&command.arguments, &mut heartbeat),
        "read_file" => read_file(&command.arguments),
        "attachment" => attachment::run(lease, &command.id, &command.arguments, &mut heartbeat)?,
        "web_fetch" => web_fetch::run(host, &command.arguments),
        "context_inventory" => {
            context_result(context::run_inventory(&command.arguments, &mut heartbeat))
        }
        "context_read" => context_result(context::run_read(&command.arguments)),
        "skill_install" => skill_result(managed_skills::run_install(
            &command.arguments,
            &mut heartbeat,
        )),
        "skill_status" => skill_result(managed_skills::run_status(&command.arguments)),
        "artifact_stage" => artifact_result(artifact_stage::run(
            &command.arguments,
            &artifact_stage::Identity {
                executor_id: lease.executor_id,
                fence_epoch: lease.fence_epoch,
                command_id: &command.id,
            },
            &mut heartbeat,
            &mut |request| artifact_chunk(request),
        )),
        _ => ("failed", json!({"reason": "unsupported_tool"})),
    };
    if !lease_valid {
        return Err(AgentError);
    }

    let _: Value = rpc(
        "transition",
        &TransitionRequest {
            executor_id: lease.executor_id,
            fence_epoch: lease.fence_epoch,
            command_id: &command.id,
            status,
            result,
        },
    )?;
    host.tool_result(&command.id, status == "completed", started.elapsed());
    Ok(())
}

fn context_result(result: Result<Value, context::Failure>) -> (&'static str, Value) {
    match result {
        Ok(value) => ("completed", value),
        Err(error) => ("failed", json!({"reason": error.code()})),
    }
}

fn skill_result(result: Result<Value, managed_skills::Failure>) -> (&'static str, Value) {
    match result {
        Ok(value) => ("completed", value),
        Err(error) => ("failed", json!({"reason": error.code()})),
    }
}

fn artifact_result(result: Result<Value, artifact_stage::Failure>) -> (&'static str, Value) {
    match result {
        Ok(value) => ("completed", value),
        Err(error) => ("failed", json!({"reason": error.code()})),
    }
}

/// @cc [owner:ghuntley,label:security] agent-absolute-guest-paths
/// Tool paths and working directories MUST be absolute for the guest's own
/// operating system (`/…` on Linux, a drive-rooted or UNC path on Windows) and
/// at most 4096 bytes; anything else is refused before any file access.
fn absolute_guest_path(path: &str) -> bool {
    path.len() <= 4096 && platform_absolute(path)
}

#[cfg(unix)]
fn platform_absolute(path: &str) -> bool {
    path.starts_with('/')
}

#[cfg(windows)]
fn platform_absolute(path: &str) -> bool {
    std::path::Path::new(path).is_absolute()
}

/// Linux uses coreutils `timeout`; native Unix uses a bounded process group
/// and nonblocking pipes. Windows uses a kill-on-close Job Object.
#[cfg(all(
    unix,
    not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))
))]
fn shell(text: &str) -> Command {
    let mut command = Command::new("timeout");
    command.args([
        "--kill-after=2",
        &COMMAND_SECONDS.to_string(),
        "/bin/sh",
        "-lc",
        text,
    ]);
    command
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn shell(text: &str) -> Command {
    let mut command = Command::new("/bin/sh");
    command.args(["-lc", text]);
    command
}

#[cfg(windows)]
fn shell(text: &str) -> Command {
    let mut command =
        Command::new("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    command.args([
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        text,
    ]);
    command
}

#[cfg(all(
    unix,
    not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))
))]
fn wait_bounded(child: &mut std::process::Child) -> io::Result<std::process::ExitStatus> {
    // coreutils `timeout` enforces the deadline inside the child.
    child.wait()
}

#[cfg(windows)]
fn wait_bounded(child: &mut std::process::Child) -> io::Result<std::process::ExitStatus> {
    let job = crate::platform::windows::job::Job::attach(child)?;
    let deadline = Instant::now() + Duration::from_secs(COMMAND_SECONDS);
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            job.terminate();
            return child.wait();
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn run_command(arguments: &Value, heartbeat: &mut impl FnMut() -> bool) -> (&'static str, Value) {
    let Ok(arguments) = serde_json::from_value::<ExecArguments>(arguments.clone()) else {
        return ("failed", json!({"reason": "invalid_arguments"}));
    };
    if arguments.cmd.is_empty() || arguments.cmd.len() > 8192 {
        return ("failed", json!({"reason": "invalid_arguments"}));
    }

    let mut command = shell(&arguments.cmd);
    if let Some(workdir) = arguments.workdir {
        if !absolute_guest_path(&workdir) {
            return ("failed", json!({"reason": "invalid_arguments"}));
        }
        command.current_dir(workdir);
    }
    command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null());

    execute_command(command, heartbeat)
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn execute_command(
    mut command: Command,
    heartbeat: &mut impl FnMut() -> bool,
) -> (&'static str, Value) {
    let Ok(output) = native_command::run(
        &mut command,
        OUTPUT_LIMIT,
        Duration::from_secs(COMMAND_SECONDS),
        heartbeat,
    ) else {
        return ("failed", json!({"reason": "spawn_failed"}));
    };
    let code = output.status.code().unwrap_or(-1);
    (
        if code == 0 { "completed" } else { "failed" },
        json!({
            "exit_code": code,
            "stdout": String::from_utf8_lossy(&output.stdout),
            "stderr": String::from_utf8_lossy(&output.stderr),
        }),
    )
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn execute_command(
    mut command: Command,
    _heartbeat: &mut impl FnMut() -> bool,
) -> (&'static str, Value) {
    let Ok(mut child) = command.spawn() else {
        return ("failed", json!({"reason": "spawn_failed"}));
    };
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        return ("failed", json!({"reason": "spawn_failed"}));
    };
    let Some(stderr) = child.stderr.take() else {
        let _ = child.kill();
        return ("failed", json!({"reason": "spawn_failed"}));
    };
    let out = thread::spawn(move || read_limited(stdout));
    let err = thread::spawn(move || read_limited(stderr));
    let result = wait_bounded(&mut child);
    let stdout = out.join().unwrap_or_default();
    let stderr = err.join().unwrap_or_default();
    let code = result.ok().and_then(|status| status.code()).unwrap_or(-1);
    let state = if code == 0 { "completed" } else { "failed" };
    (
        state,
        json!({"exit_code": code, "stdout": stdout, "stderr": stderr}),
    )
}

fn read_file(arguments: &Value) -> (&'static str, Value) {
    let Ok(arguments) = serde_json::from_value::<ReadArguments>(arguments.clone()) else {
        return ("failed", json!({"reason": "invalid_arguments"}));
    };
    if !absolute_guest_path(&arguments.path) {
        return ("failed", json!({"reason": "invalid_arguments"}));
    }
    match std::fs::File::open(arguments.path) {
        Ok(file) => (
            "completed",
            json!({"contents": read_limited(file.take(OUTPUT_LIMIT as u64))}),
        ),
        Err(_) => ("failed", json!({"reason": "read_failed"})),
    }
}

fn read_limited(mut input: impl Read) -> String {
    let mut bytes = Vec::with_capacity(OUTPUT_LIMIT);
    let mut chunk = [0_u8; 4096];
    loop {
        match input.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(count) => {
                let remaining = OUTPUT_LIMIT.saturating_sub(bytes.len());
                bytes.extend_from_slice(&chunk[..count.min(remaining)]);
            }
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn valid_identifier(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RpcFailure {
    Encode,
    Request(http::RequestFailure),
    Decode,
}

impl RpcFailure {
    fn diagnostic_code(self) -> i32 {
        match self {
            Self::Encode => 110,
            Self::Decode => 111,
            Self::Request(failure) => failure.diagnostic_code(),
        }
    }
}

fn rpc<Response: DeserializeOwned, Body: Serialize>(
    route: &str,
    body: &Body,
) -> Result<Response, AgentError> {
    rpc_observed(route, body, &mut |_| {})
}

fn rpc_observed<Response: DeserializeOwned, Body: Serialize>(
    route: &str,
    body: &Body,
    failed: &mut impl FnMut(RpcFailure),
) -> Result<Response, AgentError> {
    let payload = serde_json::to_vec(body).map_err(|_| {
        failed(RpcFailure::Encode);
        AgentError
    })?;
    let maximum = if route == "attachment/transfer" {
        ATTACHMENT_TRANSFER_BODY_LIMIT
    } else {
        RPC_BODY_LIMIT
    };
    if payload.len() > maximum {
        failed(RpcFailure::Encode);
        return Err(AgentError);
    }
    post(route, &payload, Duration::from_secs(10), failed)
}

/// @cc [owner:ghuntley,label:security] lyra-artifact-chunk-rpc-bound
/// Only `artifact_chunk` MAY send a body above the 12 KiB control RPC limit, and
/// never above `270_336` bytes; an oversized body is refused before any network
/// effect. Only `{"accepted": true}` acknowledges a chunk.
fn artifact_chunk(request: &artifact_stage::ChunkRequest<'_>) -> bool {
    let Ok(payload) = serde_json::to_vec(request) else {
        return false;
    };
    if !artifact_chunk_fits(&payload) {
        return false;
    }
    matches!(
        post::<artifact_stage::ChunkResponse>(
            "artifact_chunk",
            &payload,
            Duration::from_secs(30),
            &mut |_| {},
        ),
        Ok(artifact_stage::ChunkResponse { accepted: true })
    )
}

fn artifact_chunk_fits(payload: &[u8]) -> bool {
    payload.len() <= ARTIFACT_CHUNK_BODY_LIMIT
}

fn post<Response: DeserializeOwned>(
    route: &str,
    payload: &[u8],
    timeout: Duration,
    failed: &mut impl FnMut(RpcFailure),
) -> Result<Response, AgentError> {
    let bytes = http::request_observed(
        &format!("{ORIGIN}{route}"),
        Method::POST,
        Some(payload),
        None,
        if route == "attachment/transfer" {
            ATTACHMENT_TRANSFER_BODY_LIMIT
        } else {
            16_384
        },
        timeout,
        &mut |failure| failed(RpcFailure::Request(failure)),
    )
    .map_err(|_| AgentError)?;
    serde_json::from_slice(&bytes).map_err(|_| {
        failed(RpcFailure::Decode);
        AgentError
    })
}

#[cfg(test)]
mod tests {
    use super::{
        absolute_guest_path, artifact_chunk_fits, artifact_stage, read_limited, valid_identifier,
        Claim, Registration, ARTIFACT_CHUNK_BODY_LIMIT, OUTPUT_LIMIT,
    };
    use base64::{engine::general_purpose::STANDARD, Engine};

    // Pin: a full chunk with maximal identity fields fits the dedicated bound,
    // and a body one byte larger is refused before any network effect.
    #[test]
    fn artifact_chunk_body_bound() {
        let id = "11111111-1111-4111-8111-111111111111";
        let request = artifact_stage::ChunkRequest {
            executor_id: id,
            fence_epoch: u64::MAX,
            command_id: id,
            publish_request_id: id,
            file_index: u32::MAX,
            chunk_index: u32::MAX,
            sha256: "f".repeat(64),
            data: STANDARD.encode(vec![0_u8; artifact_stage::CHUNK_BYTES]),
        };
        let payload = serde_json::to_vec(&request).expect("encode");
        assert!(payload.len() > super::RPC_BODY_LIMIT);
        assert!(artifact_chunk_fits(&payload));
        assert!(artifact_chunk_fits(&vec![b' '; ARTIFACT_CHUNK_BODY_LIMIT]));
        assert!(!artifact_chunk_fits(&vec![
            b' ';
            ARTIFACT_CHUNK_BODY_LIMIT + 1
        ]));
    }

    #[test]
    fn guest_paths_are_absolute_for_this_platform() {
        #[cfg(unix)]
        {
            assert!(absolute_guest_path("/workspace/demo"));
            assert!(!absolute_guest_path("workspace"));
            assert!(!absolute_guest_path("C:\\workspace"));
        }
        #[cfg(windows)]
        {
            assert!(absolute_guest_path("C:\\workspace\\demo"));
            assert!(!absolute_guest_path("workspace"));
            assert!(!absolute_guest_path("\\workspace"));
        }
        assert!(!absolute_guest_path(&format!("/{}", "a".repeat(4096))));
    }

    #[test]
    fn bounded_tool_output_and_strict_ids() {
        assert_eq!(
            read_limited(vec![b'x'; OUTPUT_LIMIT + 4096].as_slice()).len(),
            OUTPUT_LIMIT
        );
        assert!(valid_identifier("11111111-1111-4111-8111-111111111111"));
        assert!(!valid_identifier("../escape"));
    }

    // Pin: revocation reaches the executor only as a closed registration or
    // lease RPC failure. The wire shapes it trusts MUST stay closed so a
    // changed or enriched control payload fails deserialization instead of
    // acquiring authority fields the fencing model does not define.
    #[test]
    fn executor_control_shapes_stay_closed() {
        assert!(serde_json::from_str::<Claim>("{\"command\":null}").is_ok());
        assert!(serde_json::from_str::<Claim>("{\"command\":null,\"extra\":1}").is_err());
        assert!(serde_json::from_str::<Registration>(
            "{\"executor_id\":\"11111111-1111-4111-8111-111111111111\",\"fence_epoch\":1,\"expires_at_ms\":0}"
        )
        .is_ok());
        assert!(serde_json::from_str::<Registration>(
            "{\"executor_id\":\"11111111-1111-4111-8111-111111111111\",\"fence_epoch\":1,\"expires_at_ms\":0,\"debug\":\"x\"}"
        )
        .is_err());
        assert!(serde_json::from_str::<Registration>(
            "{\"executor_id\":\"11111111-1111-4111-8111-111111111111\",\"expires_at_ms\":0}"
        )
        .is_err());
    }
}
