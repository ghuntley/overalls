//! Stateful application I/O composing the pure runtime and certificate-pinned SSH.
//! Native adapters own the async executor and device signer; UI receives projections.

use mila_model::Identifier;
use mila_transport::{
    ssh::{DeviceSigner, ExecOutput, SshError, SshSession},
    TrustDocument,
};
use std::{collections::HashSet, time::Duration};

mod devices;
mod error;
mod listing;
mod machines;
mod shares;
mod ssh_keys;
mod terminal;
mod threads;
mod web;

pub use error::SessionError;
pub use listing::{decode_listing, MachineListing};

/// One deployment connection and its last successful listing. No automatic retries.
pub struct ApplicationSession {
    ssh: SshSession,
    host: String,
    port: u16,
    listing: Option<MachineListing>,
    seen_cursors: HashSet<Identifier>,
    last_refusal: std::sync::Mutex<Option<String>>,
}

impl std::fmt::Debug for ApplicationSession {
    /// Shows only the deployment endpoint; listings, refusals and the SSH
    /// session stay out of diagnostics.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApplicationSession")
            .field("host", &self.host)
            .field("port", &self.port)
            .finish_non_exhaustive()
    }
}

/// @cc [owner:ghuntley,label:security;protocol] mila-session-closed-refusal
/// Only a closed server refusal code (`[a-z][a-z0-9_]{0,63}` from a v1
/// `status: error` envelope) may be retained for presentation; server
/// messages, command text and payloads MUST NOT be retained.
fn refusal_code(stdout: &[u8]) -> Option<String> {
    let value: serde_json::Value = serde_json::from_slice(stdout).ok()?;
    if value.get("status")?.as_str()? != "error" {
        return None;
    }
    let code = value.get("error")?.as_str()?;
    let mut bytes = code.bytes();
    let first = bytes.next()?;
    (code.len() <= 64
        && first.is_ascii_lowercase()
        && bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'))
    .then(|| code.to_owned())
}

/// @cc [owner:ghuntley,label:protocol;security] mila-session-ssh-key-envelope
/// `ssh-key list --json` output MUST be either Porsche's succeeded envelope
/// (`{"version":1,"status":"succeeded","result":{"keys":[...]}}`) or a bare
/// `{"keys":[...]}`; every key needs a canonical id and bounded printable
/// fingerprint and algorithm. Any other status is refused.
fn validate_ssh_keys(bytes: &[u8]) -> Result<(), SessionError> {
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| SessionError::Refused)?;
    let body = match value.get("status") {
        None => &value,
        Some(status)
            if status.as_str() == Some("succeeded")
                && value.get("version").and_then(serde_json::Value::as_u64) == Some(1) =>
        {
            value.get("result").ok_or(SessionError::Refused)?
        }
        Some(_) => return Err(SessionError::Refused),
    };
    let keys = body
        .get("keys")
        .and_then(serde_json::Value::as_array)
        .ok_or(SessionError::Refused)?;
    if keys.len() > 256 {
        return Err(SessionError::Bounds);
    }
    for key in keys {
        let id = key
            .get("id")
            .and_then(serde_json::Value::as_str)
            .ok_or(SessionError::Refused)?;
        Identifier::parse(id).map_err(|_| SessionError::Refused)?;
        for field in ["fingerprint", "algorithm"] {
            let text = key
                .get(field)
                .and_then(serde_json::Value::as_str)
                .ok_or(SessionError::Refused)?;
            if text.is_empty() || text.len() > 256 || text.bytes().any(|b| b.is_ascii_control()) {
                return Err(SessionError::Refused);
            }
        }
    }
    Ok(())
}

impl ApplicationSession {
    /// Submit one command once and remember a closed refusal code, if any.
    async fn exec(&self, line: &str, stdin: &[u8]) -> Result<ExecOutput, SshError> {
        let output = self.ssh.exec(line, stdin).await?;
        let code = (output.exit_status != 0)
            .then(|| refusal_code(&output.stdout))
            .flatten();
        if let Ok(mut last) = self.last_refusal.lock() {
            *last = code;
        }
        Ok(output)
    }

    /// The closed refusal code of this session's most recent command, if it was refused.
    pub fn last_refusal(&self) -> Option<String> {
        self.last_refusal.lock().ok().and_then(|last| last.clone())
    }

    /// @cc [owner:ghuntley,label:protocol] mila-session-request-show-resolves
    /// Uncertain or accepted mutations MUST be resolved by reading their receipt
    /// with `request show`, never by resubmitting the mutation.
    pub async fn request_show(&mut self, request_id: &str) -> Result<Vec<u8>, SessionError> {
        let request_id =
            mila_model::RequestId::parse(request_id).map_err(|_| SessionError::MutationRefused)?;
        let output = self
            .exec(&format!("request show {request_id} --json"), &[])
            .await?;
        if output.exit_status != 0 || output.stdout.len() > 256 * 1024 {
            return Err(SessionError::Refused);
        }
        serde_json::from_slice::<serde_json::Value>(&output.stdout)
            .map_err(|_| SessionError::Refused)?;
        Ok(output.stdout)
    }

    /// Connects only through the transport's pre-authentication certificate policy.
    pub async fn connect<S: DeviceSigner>(
        trust: TrustDocument,
        port: u16,
        public_key: &str,
        signer: S,
        timeout: Duration,
    ) -> Result<Self, SessionError> {
        let host = trust.management_host.clone();
        let ssh = SshSession::connect(trust, port, public_key, signer, timeout).await?;
        Ok(Self {
            ssh,
            host,
            port,
            listing: None,
            seen_cursors: HashSet::new(),
            last_refusal: std::sync::Mutex::new(None),
        })
    }

    pub async fn close(self) -> Result<(), SessionError> {
        Ok(self.ssh.close().await?)
    }
}

#[cfg(test)]
mod ssh_key_envelope_tests;

#[cfg(test)]
mod refusal_tests {
    use super::refusal_code;
    use hegel::{generators as gs, TestCase};
    use serde_json::json;

    #[test]
    fn refusal_code_keeps_only_closed_error_names() {
        assert_eq!(
            refusal_code(br#"{"version":1,"status":"error","error":"vm_busy"}"#).as_deref(),
            Some("vm_busy")
        );
        for refused in [
            &br#"{"version":1,"status":"succeeded","error":"vm_busy"}"#[..],
            br#"{"version":1,"status":"error","error":"Token abc"}"#,
            br#"{"version":1,"status":"error","error":"9lives"}"#,
            br#"{"version":1,"status":"error","error":7}"#,
            b"not json",
        ] {
            assert_eq!(refusal_code(refused), None);
        }
        let long = format!(r#"{{"status":"error","error":"{}"}}"#, "a".repeat(65));
        assert_eq!(refusal_code(long.as_bytes()), None);
    }

    /// The closed refusal-code grammar `[a-z][a-z0-9_]{0,63}`, checked per byte.
    fn closed(code: &str) -> bool {
        let bytes = code.as_bytes();
        (1..=64).contains(&bytes.len())
            && bytes[0].is_ascii_lowercase()
            && bytes[1..]
                .iter()
                .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'_'))
    }

    /// @cc [owner:ghuntley,label:verification;security] mila-session-refusal-code-closed-set
    /// `refusal_code` MUST return exactly the `error` string of a `status: error`
    /// object when it matches `[a-z][a-z0-9_]{0,63}`, and `None` for every other
    /// code, status, shape or byte string.
    #[hegel::test(test_cases = 512)]
    fn refusal_code_retains_only_the_closed_set(tc: TestCase) {
        let length = if tc.draw(gs::booleans()) {
            tc.draw(gs::sampled_from(vec![0_usize, 1, 63, 64, 65]))
        } else {
            tc.draw(gs::integers::<usize>().max_value(70))
        };
        let mut code: Vec<char> = tc
            .draw(
                gs::text()
                    .alphabet("az09_")
                    .min_size(length)
                    .max_size(length),
            )
            .chars()
            .collect();
        if let Some(first) = code.first_mut() {
            *first = tc.draw(gs::sampled_from(vec!['a', 'q', 'z', 'a', '9', '_']));
        }
        if !code.is_empty() && tc.draw(gs::integers::<u8>().max_value(3)) == 0 {
            let index = tc.draw(gs::integers::<usize>().max_value(code.len() - 1));
            code[index] = tc.draw(gs::sampled_from(vec!['A', '-', '.', ' ', '\u{e9}', '\n']));
        }
        let code: String = code.into_iter().collect();
        let status = tc.draw(gs::sampled_from(vec![
            "error",
            "error",
            "error",
            "succeeded",
            "Error",
            "",
        ]));
        let body = match tc.draw(gs::integers::<u8>().max_value(8)) {
            0 => json!({"status": status, "error": 7}),
            1 => json!({"error": code}),
            2 => json!([status, code]),
            _ => json!({"version": 1, "status": status, "error": code, "message": "server text"}),
        };
        let shaped = body.get("status").is_some() && body["error"].is_string();
        let expected = (shaped && status == "error" && closed(&code)).then(|| code.clone());
        assert_eq!(refusal_code(&serde_json::to_vec(&body).unwrap()), expected);
        let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(256));
        if let Some(retained) = refusal_code(&bytes) {
            assert!(closed(&retained));
        }
    }
}
