//! Typed projections of Porsche `--json` results used by the GTK pages and
//! the live journeys.
//!
//! Porsche prints reads as `{"version":1,"status":"succeeded","result":{..}}`
//! and mutations with an additional `request_id` and `operation_id`. Every
//! decoder here accepts that envelope (or the bare result the fixtures use),
//! bounds the input, and copies only the fields a page displays or a journey
//! asserts. Unknown fields are ignored; malformed or oversized input fails.

use crate::adapter::RuntimeError;
use serde::Deserialize;

const MAX_RESULT_BYTES: usize = 256 * 1024;

/// @cc [owner:ghuntley,label:security;protocol] linux-porsche-result-envelope
/// A Porsche result MUST be bounded and either a bare JSON object or the
/// version-1 envelope whose status is `succeeded` or `accepted` and whose
/// `result` is an object; any other status, version or shape MUST fail.
pub fn result_value(bytes: &[u8]) -> Result<serde_json::Value, RuntimeError> {
    if bytes.is_empty() || bytes.len() > MAX_RESULT_BYTES {
        return Err(RuntimeError::InvalidInput);
    }
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidInput)?;
    let object = value.as_object().ok_or(RuntimeError::InvalidInput)?;
    if object.contains_key("version") && object.contains_key("status") {
        let version = object.get("version").and_then(serde_json::Value::as_u64);
        let status = object.get("status").and_then(serde_json::Value::as_str);
        let result = object.get("result").filter(|result| result.is_object());
        return match (version, status, result) {
            (Some(1), Some("succeeded" | "accepted"), Some(result)) => Ok(result.clone()),
            _ => Err(RuntimeError::InvalidInput),
        };
    }
    Ok(value)
}

/// The bare result bytes, for decoders that deserialize directly.
pub fn result_bytes(bytes: &[u8]) -> Result<Vec<u8>, RuntimeError> {
    serde_json::to_vec(&result_value(bytes)?).map_err(|_| RuntimeError::InvalidInput)
}

fn decode<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, RuntimeError> {
    serde_json::from_value(result_value(bytes)?).map_err(|_| RuntimeError::InvalidInput)
}

fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn display(value: &str, max: usize) -> bool {
    value.len() <= max && !value.chars().any(char::is_control)
}

/// `show MACHINE --json`: identity, requested and observed state, and size.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct MachineDetail {
    pub id: String,
    pub name: String,
    pub desired_state: String,
    #[serde(default)]
    pub observed_state: Option<String>,
    #[serde(default)]
    pub vcpu: Option<u32>,
    #[serde(default)]
    pub memory_bytes: Option<u64>,
    #[serde(default)]
    pub disk_bytes: Option<u64>,
}

impl MachineDetail {
    pub fn memory_mib(&self) -> Option<u64> {
        self.memory_bytes.map(|bytes| bytes / (1024 * 1024))
    }

    pub fn disk_gib(&self) -> Option<u64> {
        self.disk_bytes.map(|bytes| bytes / (1024 * 1024 * 1024))
    }
}

pub fn decode_machine_detail(bytes: &[u8]) -> Result<MachineDetail, RuntimeError> {
    let detail: MachineDetail = decode(bytes)?;
    if !identifier(&detail.id)
        || detail.name.is_empty()
        || !display(&detail.name, 256)
        || !identifier(&detail.desired_state)
        || detail
            .observed_state
            .as_deref()
            .is_some_and(|state| !identifier(state))
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(detail)
}

/// One `thread ls` row.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ThreadRow {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub machine_id: Option<String>,
}

pub fn decode_thread_rows(bytes: &[u8]) -> Result<Vec<ThreadRow>, RuntimeError> {
    #[derive(Deserialize)]
    struct Page {
        items: Vec<ThreadRow>,
    }
    let page: Page = decode(bytes)?;
    if page.items.len() > 512
        || page.items.iter().any(|row| {
            !identifier(&row.id)
                || row
                    .title
                    .as_deref()
                    .is_some_and(|title| !display(title, 512))
                || row
                    .status
                    .as_deref()
                    .is_some_and(|status| !identifier(status))
        })
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(page.items)
}

/// The pending question or latest plan of a thread, by identifier.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ThreadControl {
    pub id: String,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub implemented: Option<bool>,
}

/// `thread show THREAD --json`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ThreadDetail {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub collaboration_mode: Option<String>,
    #[serde(default)]
    pub busy: bool,
    #[serde(default)]
    pub last_sequence: Option<u64>,
    #[serde(default)]
    pub pending_question: Option<ThreadControl>,
    #[serde(default)]
    pub latest_plan: Option<ThreadControl>,
}

impl ThreadDetail {
    /// The latest plan when it has not been implemented yet.
    pub fn open_plan(&self) -> Option<&ThreadControl> {
        self.latest_plan
            .as_ref()
            .filter(|plan| plan.implemented != Some(true))
    }
}

pub fn decode_thread_detail(bytes: &[u8]) -> Result<ThreadDetail, RuntimeError> {
    let detail: ThreadDetail = decode(bytes)?;
    let control_ok = |control: &Option<ThreadControl>| {
        control.as_ref().is_none_or(|control| {
            identifier(&control.id)
                && control
                    .text
                    .as_deref()
                    .is_none_or(|text| text.len() <= 64 * 1024)
        })
    };
    if !identifier(&detail.id)
        || detail
            .title
            .as_deref()
            .is_some_and(|title| !display(title, 512))
        || detail
            .status
            .as_deref()
            .is_some_and(|status| !identifier(status))
        || detail
            .collaboration_mode
            .as_deref()
            .is_some_and(|mode| !identifier(mode))
        || !control_ok(&detail.pending_question)
        || !control_ok(&detail.latest_plan)
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(detail)
}

/// One `thread turns` event: its sequence, kind and owning turn.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ThreadEvent {
    pub sequence: u64,
    pub kind: String,
    #[serde(default)]
    pub turn_id: Option<String>,
}

pub fn decode_thread_events(bytes: &[u8]) -> Result<Vec<ThreadEvent>, RuntimeError> {
    #[derive(Deserialize)]
    struct Page {
        items: Vec<ThreadEvent>,
    }
    let page: Page = decode(bytes)?;
    if page.items.len() > 1024
        || page.items.iter().any(|event| {
            !identifier(&event.kind)
                || event
                    .turn_id
                    .as_deref()
                    .is_some_and(|turn| !identifier(turn))
        })
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(page.items)
}

/// The identifiers a thread mutation reports (`thread prompt`, `answer`,
/// `plan approve`).
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ThreadMutation {
    pub thread_id: String,
    #[serde(default)]
    pub turn_id: Option<String>,
    #[serde(default)]
    pub question_id: Option<String>,
    #[serde(default)]
    pub plan_id: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub collaboration_mode: Option<String>,
}

pub fn decode_thread_mutation(bytes: &[u8]) -> Result<ThreadMutation, RuntimeError> {
    let mutation: ThreadMutation = decode(bytes)?;
    let optional = |value: &Option<String>| value.as_deref().is_none_or(identifier);
    if !identifier(&mutation.thread_id)
        || !optional(&mutation.turn_id)
        || !optional(&mutation.question_id)
        || !optional(&mutation.plan_id)
        || !optional(&mutation.status)
        || !optional(&mutation.collaboration_mode)
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(mutation)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(command: &str) -> Vec<u8> {
        let raw = include_str!("../../../../protocol/test/fixtures/porsche_client_results.json");
        let value: serde_json::Value = serde_json::from_str(raw).unwrap();
        serde_json::to_vec(&value["results"][command]).unwrap()
    }

    fn envelope(result: &[u8]) -> Vec<u8> {
        let result: serde_json::Value = serde_json::from_slice(result).unwrap();
        serde_json::to_vec(
            &serde_json::json!({"version": 1, "status": "succeeded", "result": result}),
        )
        .unwrap()
    }

    #[test]
    fn envelope_is_unwrapped_and_other_statuses_fail() {
        let bare = br#"{"a":1}"#;
        assert_eq!(result_value(bare).unwrap()["a"], 1);
        assert_eq!(result_value(&envelope(bare)).unwrap()["a"], 1);
        let accepted = br#"{"version":1,"request_id":"porsche-00","status":"accepted","operation_id":"x","result":{"a":2}}"#;
        assert_eq!(result_value(accepted).unwrap()["a"], 2);
        for bad in [
            br#"{"version":1,"status":"failed","result":{}}"#.as_slice(),
            br#"{"version":2,"status":"succeeded","result":{}}"#,
            br#"{"version":1,"status":"succeeded","result":[]}"#,
            br#"[1]"#,
            b"",
            b"{",
        ] {
            assert!(
                result_value(bad).is_err(),
                "{}",
                String::from_utf8_lossy(bad)
            );
        }
        assert!(result_value(&vec![b' '; MAX_RESULT_BYTES + 1]).is_err());
    }

    #[test]
    fn thread_fixtures_decode_bare_and_enveloped() {
        for bytes in [fixture("thread ls"), envelope(&fixture("thread ls"))] {
            let rows = decode_thread_rows(&bytes).unwrap();
            assert_eq!(rows[0].id, "0d9cc041-9db2-4e4c-b28b-1e41d7f472c1");
            assert_eq!(rows[0].status.as_deref(), Some("ready"));
        }
        let detail = decode_thread_detail(&fixture("thread show")).unwrap();
        assert_eq!(detail.collaboration_mode.as_deref(), Some("plan"));
        assert!(detail.pending_question.is_none() && detail.open_plan().is_none());
        let events = decode_thread_events(&fixture("thread turns")).unwrap();
        assert_eq!(events[0].kind, "assistant");
        let prompt = decode_thread_mutation(&fixture("thread prompt")).unwrap();
        assert!(prompt.turn_id.is_some());
        let answer = decode_thread_mutation(&fixture("thread answer")).unwrap();
        assert_eq!(answer.status.as_deref(), Some("answered"));
        let approve = decode_thread_mutation(&fixture("thread plan approve")).unwrap();
        assert_eq!(approve.collaboration_mode.as_deref(), Some("work"));
    }

    #[test]
    fn thread_controls_and_plans_are_typed() {
        let shown = br#"{"id":"t1","pending_question":{"id":"q1","questions":[]},"latest_plan":{"id":"p1","text":"do it","implemented":false}}"#;
        let detail = decode_thread_detail(shown).unwrap();
        assert_eq!(detail.pending_question.as_ref().unwrap().id, "q1");
        assert_eq!(detail.open_plan().unwrap().id, "p1");
        let done = br#"{"id":"t1","latest_plan":{"id":"p1","implemented":true}}"#;
        assert!(decode_thread_detail(done).unwrap().open_plan().is_none());
        assert!(decode_thread_detail(br#"{"id":"t 1"}"#).is_err());
        assert!(decode_thread_detail(br#"{"id":"t1","pending_question":{"id":"q/1"}}"#).is_err());
    }

    #[test]
    fn machine_detail_is_bounded_and_sized() {
        let shown = br#"{"id":"019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a","name":"box","desired_state":"running","observed_state":"pending","vcpu":2,"memory_bytes":2147483648,"disk_bytes":10737418240,"route":"x"}"#;
        let detail = decode_machine_detail(&envelope(shown)).unwrap();
        assert_eq!(detail.vcpu, Some(2));
        assert_eq!(detail.memory_mib(), Some(2048));
        assert_eq!(detail.disk_gib(), Some(10));
        assert!(
            decode_machine_detail(br#"{"id":"m1","name":"a\nb","desired_state":"running"}"#)
                .is_err()
        );
        assert!(
            decode_machine_detail(br#"{"id":"m1","name":"a","desired_state":"run ning"}"#).is_err()
        );
    }
}
