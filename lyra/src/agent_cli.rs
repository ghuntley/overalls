use crate::config;
use crate::http;
use reqwest::Method;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{self, IsTerminal, Read, Write};
use std::thread;
use std::time::{Duration, Instant};

const MAX_PROMPT_BYTES: usize = 65_536;
const MAX_RESPONSE_BYTES: usize = 1_100_000;

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum ApprovalState {
    Pending,
    Approved,
}

#[derive(Deserialize)]
struct SessionResponse {
    status: ApprovalState,
}

#[derive(Deserialize)]
struct ThreadsResponse {
    threads: Vec<ThreadInfo>,
}

#[derive(Deserialize)]
struct ThreadInfo {
    id: String,
    parent_thread_id: Option<String>,
}

#[derive(Deserialize)]
struct PromptResponse {
    turn_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum TurnState {
    Queued,
    Running,
    Completed,
    Failed,
    Interrupted,
}

#[derive(Deserialize)]
struct TurnResponse {
    status: TurnState,
    text: Option<String>,
    reason: Option<String>,
}

#[derive(Serialize)]
struct PromptRequest<'a> {
    vm_id: &'a str,
    thread_id: &'a str,
    request_key: &'a str,
    prompt: &'a str,
}

// @cc [owner:ghuntley,label:security] lyra-agent-cli-browser-secret
// The CLI's random bearer MUST stay in memory. Only
// its SHA-256 digest enters the browser approval URL; command arguments and
// persistent diagnostics MUST contain neither bearer nor prompt content.
pub(crate) fn run(machine: &str, thread_id: Option<&str>) -> Result<i32, &'static str> {
    if !valid_uuid(machine) || thread_id.is_some_and(|id| !valid_uuid(id)) {
        return Err("invalid machine or thread ID");
    }
    let prompt = read_prompt().map_err(|_| "prompt unavailable")?;
    let config = config::load().map_err(|_| "CLI configuration unavailable")?;
    let secret = random_bytes::<32>().map_err(|_| "random source unavailable")?;
    let bearer = format!("overalls_agent_{}", hex::encode(secret));
    let digest = Sha256::digest(bearer.as_bytes());
    let code = hex::encode(digest);
    eprintln!(
        "Open {}/agents/cli/approve/{machine}/{code} and approve code {}",
        config.origin,
        hex::encode(&digest[..6])
    );
    let session_path = format!("/api/agents/v1/session?vm_id={machine}");
    let approval_deadline = Instant::now() + Duration::from_mins(10);
    loop {
        let session: SessionResponse = rpc(&config.origin, &bearer, "GET", &session_path, None)?;
        if matches!(session.status, ApprovalState::Approved) {
            break;
        }
        if Instant::now() >= approval_deadline {
            return Err("agent CLI approval timed out");
        }
        thread::sleep(Duration::from_secs(2));
    }

    let selected = if let Some(id) = thread_id {
        id.to_owned()
    } else {
        let response: ThreadsResponse = rpc(
            &config.origin,
            &bearer,
            "GET",
            &format!("/api/agents/v1/threads?vm_id={machine}"),
            None,
        )?;
        response
            .threads
            .into_iter()
            .find(|thread| thread.parent_thread_id.is_none())
            .map(|thread| thread.id)
            .ok_or("agent thread unavailable")?
    };
    if !valid_uuid(&selected) {
        return Err("agent thread unavailable");
    }
    let request_key = random_uuid().map_err(|_| "random source unavailable")?;
    let request_body = serde_json::to_vec(&PromptRequest {
        vm_id: machine,
        thread_id: &selected,
        request_key: &request_key,
        prompt: &prompt,
    })
    .map_err(|_| "agent request unavailable")?;
    let submitted: PromptResponse = rpc(
        &config.origin,
        &bearer,
        "POST",
        "/api/agents/v1/prompt",
        Some(&request_body),
    )?;
    if !valid_uuid(&submitted.turn_id) {
        return Err("agent response unavailable");
    }
    let result_path = format!("/api/agents/v1/turn/{}?vm_id={machine}", submitted.turn_id);
    // @cc [owner:ghuntley,label:security;recovery] lyra-agent-cli-static-exit
    // A revoked or expired approval makes every turn poll fail with 403, which
    // MUST become one static bounded error and process exit, never a retry loop
    // beyond the result deadline nor any credential/prompt in diagnostics. The
    // 3600s deadline mirrors the one-hour approval window, and a completed
    // turn's result remains reachable until the server-side session expires.
    let result_deadline = Instant::now() + Duration::from_hours(1);
    loop {
        let turn: TurnResponse = rpc(&config.origin, &bearer, "GET", &result_path, None)?;
        match turn.status {
            TurnState::Completed => {
                println!("{}", turn.text.ok_or("agent response unavailable")?);
                return Ok(0);
            }
            TurnState::Failed | TurnState::Interrupted => {
                let reason = turn.reason.as_deref().unwrap_or("agent_failed");
                eprintln!("Agent turn failed: {reason}");
                return Ok(1);
            }
            TurnState::Queued | TurnState::Running => {}
        }
        if Instant::now() >= result_deadline {
            return Err("agent session expired before completion");
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn read_prompt() -> io::Result<String> {
    let mut input = String::new();
    if io::stdin().is_terminal() {
        eprint!("Prompt: ");
        io::stderr().flush()?;
        io::stdin().read_line(&mut input)?;
    } else {
        io::stdin()
            .take((MAX_PROMPT_BYTES + 1) as u64)
            .read_to_string(&mut input)?;
    }
    let input = input.trim_end_matches(['\n', '\r']);
    if input.is_empty() || input.len() > MAX_PROMPT_BYTES {
        return Err(io::Error::other("invalid prompt size"));
    }
    Ok(input.to_owned())
}

fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0_u8; N];
    lyra::platform::random_bytes(&mut bytes)?;
    Ok(bytes)
}

fn random_uuid() -> io::Result<String> {
    let mut bytes = random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{}-{}-{}-{}-{}",
        hex::encode(&bytes[..4]),
        hex::encode(&bytes[4..6]),
        hex::encode(&bytes[6..8]),
        hex::encode(&bytes[8..10]),
        hex::encode(&bytes[10..])
    ))
}

fn valid_uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn rpc<Response: DeserializeOwned>(
    origin: &str,
    bearer: &str,
    method: &str,
    path: &str,
    body: Option<&[u8]>,
) -> Result<Response, &'static str> {
    if body.is_some_and(|bytes| bytes.len() > 70_000) {
        return Err("agent request too large");
    }
    let url = format!("{origin}{path}");
    let method = match method {
        "GET" => Method::GET,
        "POST" => Method::POST,
        _ => return Err("invalid agent request"),
    };
    let bytes = http::request(
        &url,
        method,
        body,
        Some(bearer),
        MAX_RESPONSE_BYTES,
        Duration::from_secs(10),
    )
    .map_err(|_| "machine or agent access unavailable")?;
    serde_json::from_slice(&bytes).map_err(|_| "agent response unavailable")
}

#[cfg(test)]
mod tests {
    use super::{random_uuid, valid_uuid, ApprovalState, SessionResponse, TurnResponse, TurnState};

    #[test]
    fn generated_request_keys_are_canonical() {
        let id = random_uuid().expect("random UUID");
        assert!(valid_uuid(&id));
        assert_eq!(id.get(14..15), Some("4"));
        assert!(!valid_uuid("../other-machine"));
    }

    // Pin: expiry or access revocation mid-turn reaches the CLI as a 403 on
    // this polling path; the wire shapes below are the only progress signals
    // the turn loop acts on, and unknown statuses must fail closed to the
    // static agent_cli error instead of being treated as turn progress.
    #[test]
    fn turn_progress_shapes_stay_closed() {
        let queued: TurnResponse =
            serde_json::from_str("{\"status\":\"queued\"}").expect("queued turn");
        assert!(matches!(queued.status, TurnState::Queued));

        let running: TurnResponse =
            serde_json::from_str("{\"status\":\"running\"}").expect("running turn");
        assert!(matches!(running.status, TurnState::Running));

        let completed: TurnResponse =
            serde_json::from_str("{\"status\":\"completed\",\"text\":\"reply\"}")
                .expect("completed turn");
        assert!(matches!(completed.status, TurnState::Completed));

        let failed: TurnResponse =
            serde_json::from_str("{\"status\":\"failed\",\"reason\":\"access_revoked\"}")
                .expect("failed turn");
        assert!(matches!(failed.status, TurnState::Failed));
        assert_eq!(failed.reason.as_deref(), Some("access_revoked"));

        assert!(serde_json::from_str::<TurnResponse>("{\"status\":\"mystery\"}").is_err());
        assert!(serde_json::from_str::<TurnResponse>("{\"status\":403}").is_err());

        let pending: SessionResponse =
            serde_json::from_str("{\"status\":\"pending\"}").expect("pending session");
        assert!(matches!(pending.status, ApprovalState::Pending));
        assert!(serde_json::from_str::<SessionResponse>("{\"status\":\"unknown\"}").is_err());
    }
}
