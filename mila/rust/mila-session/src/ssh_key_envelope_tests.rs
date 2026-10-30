use super::{validate_ssh_keys, SessionError};
use hegel::{generators as gs, TestCase};
use serde_json::{json, Value};

const KEY: &str = r#"{"id":"11111111-1111-4111-8111-111111111111","label":"laptop","algorithm":"ecdsa-sha2-nistp256","fingerprint":"SHA256:abc","inserted_at":"2026-10-01T00:00:00Z"}"#;

#[test]
fn accepts_porsche_succeeded_envelope_and_bare_keys() {
    let wrapped = format!(r#"{{"version":1,"status":"succeeded","result":{{"keys":[{KEY}]}}}}"#);
    assert!(validate_ssh_keys(wrapped.as_bytes()).is_ok());
    let bare = format!(r#"{{"keys":[{KEY}]}}"#);
    assert!(validate_ssh_keys(bare.as_bytes()).is_ok());
    assert!(
        validate_ssh_keys(br#"{"version":1,"status":"succeeded","result":{"keys":[]}}"#).is_ok()
    );
}

#[test]
fn refuses_error_status_and_malformed_keys() {
    assert!(
        validate_ssh_keys(br#"{"version":1,"status":"error","error":"unauthorized"}"#).is_err()
    );
    assert!(
        validate_ssh_keys(br#"{"version":2,"status":"succeeded","result":{"keys":[]}}"#).is_err()
    );
    assert!(validate_ssh_keys(br#"{"version":1,"status":"succeeded"}"#).is_err());
    let bad_id = r#"{"keys":[{"id":"NOT-A-UUID","algorithm":"a","fingerprint":"f"}]}"#;
    assert!(validate_ssh_keys(bad_id.as_bytes()).is_err());
    let control = "{\"keys\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"algorithm\":\"a\",\"fingerprint\":\"f\\u0001\"}]}";
    assert!(validate_ssh_keys(control.as_bytes()).is_err());
}

/// One generated key. Only the `broken` field (0 id, 1 fingerprint,
/// 2 algorithm) may be missing, mistyped or out of bounds; the rest are valid.
fn key(tc: &TestCase, broken: Option<u8>) -> (Value, bool) {
    let mut valid = true;
    let mut key = serde_json::Map::new();
    let id = if broken == Some(0) {
        match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => None,
            1 => Some(json!("NOT-A-UUID")),
            2 => Some(json!("11111111-1111-4111-8111-11111111111A")),
            _ => Some(json!(7)),
        }
    } else {
        Some(json!("11111111-1111-4111-8111-111111111111"))
    };
    valid &= id.as_ref().and_then(Value::as_str) == Some("11111111-1111-4111-8111-111111111111");
    if let Some(id) = id {
        key.insert("id".into(), id);
    }
    for (index, field) in [(1, "fingerprint"), (2, "algorithm")] {
        let value = if broken == Some(index) {
            match tc.draw(gs::integers::<u8>().max_value(4)) {
                0 => None,
                1 => Some(json!("")),
                2 => Some(json!("a\u{1}b")),
                3 => Some(json!("x".repeat(257))),
                _ => Some(json!(256)),
            }
        } else if tc.draw(gs::booleans()) {
            Some(json!(tc.draw(gs::sampled_from(vec!["x", &"x".repeat(256)]))))
        } else {
            let text = tc.draw(
                gs::text()
                    .alphabet("SHA256:abc+/= -")
                    .min_size(1)
                    .max_size(32),
            );
            Some(json!(text))
        };
        valid &= value.as_ref().and_then(Value::as_str).is_some_and(|text| {
            (1..=256).contains(&text.len()) && !text.chars().any(|c| c.is_ascii_control())
        });
        if let Some(value) = value {
            key.insert(field.into(), value);
        }
    }
    if tc.draw(gs::booleans()) {
        key.insert("label".into(), json!("descriptive fields are ignored"));
    }
    (Value::Object(key), valid)
}

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-session-ssh-key-envelope-lattice
/// `validate_ssh_keys` MUST accept exactly a bare `keys` body or a version-1
/// succeeded envelope with a `result.keys` array of at most 256 keys, each with
/// a canonical id and a non-empty printable fingerprint and algorithm of at
/// most 256 bytes; an over-long list MUST refuse as `Bounds` and anything
/// else as `Refused`.
#[hegel::test(test_cases = 256)]
fn ssh_key_envelopes_follow_the_lattice(tc: TestCase) {
    let count = tc.draw(gs::integers::<usize>().max_value(3));
    // At most one key has one broken field, so accepted lists stay frequent.
    let broken_key = tc.draw(gs::integers::<usize>().max_value(5));
    let broken_field = tc.draw(gs::integers::<u8>().max_value(2));
    let generated: Vec<(Value, bool)> = (0..count)
        .map(|index| key(&tc, (index == broken_key).then_some(broken_field)))
        .collect();
    let mut keys: Vec<Value> = generated.iter().map(|(key, _)| key.clone()).collect();
    let keys_valid = generated.iter().all(|(_, valid)| *valid);
    let oversized = tc.draw(gs::booleans()) && tc.draw(gs::booleans());
    if oversized {
        let filler = json!({"id": "11111111-1111-4111-8111-111111111111",
            "fingerprint": "SHA256:abc", "algorithm": "ecdsa-sha2-nistp256"});
        let total = tc.draw(gs::sampled_from(vec![256_usize, 257]));
        keys.resize(total.max(keys.len()), filler);
    }
    let list = json!({ "keys": keys });
    let (body, envelope_valid) = match tc.draw(gs::integers::<u8>().max_value(11)) {
        0 => (json!({"version": 1, "status": "succeeded"}), false),
        1 => (
            json!({"version": 2, "status": "succeeded", "result": list}),
            false,
        ),
        2 => (
            json!({"version": 1, "status": "error", "error": "unauthorized"}),
            false,
        ),
        3 => (json!({"version": 1, "status": 1, "result": list}), false),
        4 => (
            json!({"version": 1, "status": "succeeded", "result": {"keys": {}}}),
            false,
        ),
        5..=8 => (
            json!({"version": 1, "status": "succeeded", "result": list}),
            true,
        ),
        _ => (list, true),
    };
    let result = validate_ssh_keys(&serde_json::to_vec(&body).unwrap());
    let length = body
        .pointer("/result/keys")
        .or_else(|| body.get("keys"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    if !envelope_valid {
        assert!(matches!(result, Err(SessionError::Refused)), "{result:?}");
    } else if length > 256 {
        assert!(matches!(result, Err(SessionError::Bounds)), "{result:?}");
    } else if keys_valid {
        assert!(result.is_ok(), "{result:?}");
    } else {
        assert!(matches!(result, Err(SessionError::Refused)), "{result:?}");
    }
}
