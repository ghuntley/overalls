//! Hegel properties for Porsche's command grammar and reply envelope (ADR-0265).
use hegel::{generators as gs, TestCase};
use mila_model::DevicePlatform;
use mila_protocol::{
    decode_reply, device_public_key_valid, parse_platform, Command, ProtocolError, ReceiptStatus,
    Reply, MAX_COMMAND_BYTES,
};
use serde_json::{json, Map, Value};

const COMMANDS: [&str; 41] = [
    "whoami",
    "images",
    "ls",
    "show",
    "start",
    "pause",
    "resume",
    "unpause",
    "stop",
    "rm",
    "pin",
    "unpin",
    "new",
    "resize",
    "share add",
    "share remove",
    "request show",
    "ssh-key list",
    "ssh-key remove",
    "share show",
    "device ls",
    "device rm",
    "device prefs",
    "device register",
    "team list",
    "thread ls",
    "thread show",
    "thread turns",
    "thread prompt",
    "thread answer",
    "thread plan approve",
    "thread plan revise",
    "thread mode",
    "thread read",
    "terminal ls",
    "terminal new",
    "terminal kill",
    "terminal attach",
    "web show",
    "web set",
    "watch",
];
const OPTIONS: [&str; 26] = [
    "json",
    "no-wait",
    "peer",
    "public",
    "private",
    "session",
    "read-only",
    "after",
    "timeout",
    "request-id",
    "name",
    "image",
    "profile",
    "cpu",
    "memory",
    "disk",
    "team",
    "source",
    "machine",
    "thread",
    "port",
    "revision",
    "cursor",
    "enabled",
    "platform",
    "enc-pubkey",
];
const BASE64URL: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Shell-independent single quoting, written independently of the crate's `quote`.
fn single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

fn token(tc: &TestCase) -> String {
    match tc.draw(gs::integers::<u8>().max_value(7)) {
        0 => tc.draw(gs::uuids()),
        1 => format!(
            "porsche-{}",
            tc.draw(
                gs::text()
                    .alphabet("0123456789abcdef")
                    .min_size(32)
                    .max_size(32)
            )
        ),
        2 => tc.draw(gs::integers::<u32>().max_value(5_000)).to_string(),
        3 => "-".to_owned(),
        4 => tc
            .draw(gs::sampled_from(vec![
                "plan", "work", "viewer", "owner", "true", "false", "ios", "android", "macos",
                "windows",
            ]))
            .to_owned(),
        5 => tc.draw(gs::text().alphabet("abc-_.09").min_size(1).max_size(12)),
        6 => single_quote(&tc.draw(gs::text().max_size(16))),
        _ => tc.draw(gs::text().alphabet("ab '\"\\-=").max_size(12)),
    }
}

fn generated_line(tc: &TestCase) -> String {
    let mut parts = vec![tc.draw(gs::sampled_from(COMMANDS.to_vec())).to_owned()];
    let arguments = tc.draw(gs::integers::<usize>().max_value(4));
    for _ in 0..arguments {
        parts.push(token(tc));
    }
    let options = tc.draw(gs::integers::<usize>().max_value(4));
    for _ in 0..options {
        let key = tc.draw(gs::sampled_from(OPTIONS.to_vec()));
        match tc.draw(gs::integers::<u8>().max_value(2)) {
            0 => parts.push(format!("--{key}")),
            1 => parts.push(format!("--{key}={}", token(tc))),
            _ => {
                parts.push(format!("--{key}"));
                parts.push(token(tc));
            }
        }
    }
    if tc.draw(gs::booleans()) {
        parts.push("--json".to_owned());
    }
    parts.join(" ")
}

/// `format` emits no `--` separator, so an argument that itself begins with `--`
/// (only reachable after a separator) re-lexes as an option and is refused on
/// re-parse. The round-trip is asserted for every other accepted command.
fn assert_canonical(command: &Command) {
    if command
        .arguments
        .iter()
        .any(|argument| argument.starts_with("--"))
    {
        return;
    }
    let formatted = command.format().expect("accepted command formats");
    assert!(formatted.len() <= MAX_COMMAND_BYTES);
    assert_eq!(Command::parse(&formatted).as_ref(), Ok(command));
    assert_eq!(
        Command::parse(&formatted).and_then(|again| again.format()),
        Ok(formatted)
    );
}

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-protocol-command-format-roundtrip
/// Every generated command line the grammar accepts MUST format to a canonical
/// line that parses back to the identical command (excluding arguments that begin
/// with `--`, see `assert_canonical`), and arbitrary input (including
/// over-long lines) MUST be refused with a typed error rather than panicking.
#[hegel::test(test_cases = 512)]
fn command_parse_format_round_trip_and_totality(tc: TestCase) {
    let line = generated_line(&tc);
    if let Ok(command) = Command::parse(&line) {
        assert_canonical(&command);
    }

    let arbitrary = tc.draw(gs::text().max_size(200));
    match Command::parse(&arbitrary) {
        Ok(command) => assert_canonical(&command),
        Err(error) => assert_eq!(error, ProtocolError::InvalidCommand),
    }

    let padding = tc.draw(gs::integers::<usize>().min_value(1).max_value(64));
    let oversized = format!("ls --json{}", " ".repeat(MAX_COMMAND_BYTES - 8 + padding));
    assert_eq!(
        Command::parse(&oversized),
        Err(ProtocolError::InvalidCommand)
    );
    for control in ['\0', '\n', '\r'] {
        assert!(Command::parse(&format!("ls --json{control}")).is_err());
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-protocol-command-accepted-forms
/// Well-formed commands built from free-form arguments, repeated filters and
/// bounded options MUST be accepted and survive `format` then `parse` unchanged.
#[hegel::test(test_cases = 256)]
fn generated_valid_commands_round_trip(tc: TestCase) {
    let free = || {
        tc.draw(
            gs::text()
                .min_size(1)
                .max_size(24)
                .exclude_characters("\0\n\r"),
        )
    };
    let id = || tc.draw(gs::uuids());
    let first = free();
    tc.assume(!first.starts_with("--"));
    let line = match tc.draw(gs::integers::<u8>().max_value(5)) {
        0 => format!("pause --json -- {}", single_quote(&first)),
        1 => format!(
            "share add --json {} {} {}",
            single_quote(&first),
            single_quote(&free()),
            tc.draw(gs::sampled_from(vec!["viewer", "editor", "admin"]))
        ),
        2 => format!(
            "thread read --json {} {}",
            id(),
            tc.draw(gs::integers::<u64>().min_value(1))
        ),
        3 => format!(
            "watch --json --machine={} --machine={} --thread={}",
            single_quote(&first),
            single_quote(&free()),
            id()
        ),
        4 => format!(
            "web set {} --port={} --json",
            single_quote(&first),
            tc.draw(gs::integers::<u16>().min_value(1))
        ),
        _ => format!(
            "device register --json --platform={} --push-key=- --enc-pubkey={}",
            tc.draw(gs::sampled_from(vec!["ios", "android", "macos", "windows"])),
            encode_base64url(&tc.draw(gs::arrays::<_, u8, 32>(gs::default::<u8>())))
        ),
    };
    let command = Command::parse(&line).expect("generated well-formed command");
    assert_canonical(&command);
}

/// Independent unpadded base64url encoder for the property oracle.
fn encode_base64url(bytes: &[u8]) -> String {
    let alphabet = BASE64URL.as_bytes();
    let mut output = String::new();
    for chunk in bytes.chunks(3) {
        let block = chunk.iter().enumerate().fold(0u32, |acc, (index, byte)| {
            acc | u32::from(*byte) << (16 - 8 * index)
        });
        for index in 0..=chunk.len() {
            let sextet = (block >> (18 - 6 * index)) & 0x3f;
            output.push(char::from(alphabet[sextet as usize]));
        }
    }
    output
}

/// Independent oracle: 43 base64url symbols whose last symbol has zero pad bits.
fn canonical_x25519_key(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| BASE64URL.as_bytes().contains(&byte))
        && value
            .bytes()
            .last()
            .and_then(|last| BASE64URL.bytes().position(|symbol| symbol == last))
            .is_some_and(|index| index % 4 == 0)
}

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-protocol-device-key-lattice
/// `device_public_key_valid` MUST accept every canonical unpadded base64url
/// encoding of 32 bytes and agree with an independent alphabet/pad-bit oracle on
/// mutated, truncated, extended and noise inputs.
#[hegel::test(test_cases = 256)]
fn device_public_key_matches_oracle(tc: TestCase) {
    let bytes: [u8; 32] = tc.draw(gs::arrays(gs::default::<u8>()));
    let encoded = encode_base64url(&bytes);
    assert_eq!(encoded.len(), 43);
    assert!(device_public_key_valid(&encoded));

    let mut mutated: Vec<char> = encoded.chars().collect();
    let index = tc.draw(gs::integers::<usize>().max_value(42));
    mutated[index] = tc.draw(gs::sampled_from(
        format!("{BASE64URL}+/=é ").chars().collect::<Vec<_>>(),
    ));
    let mutated: String = mutated.into_iter().collect();
    let truncated = encoded[..tc.draw(gs::integers::<usize>().max_value(42))].to_owned();
    let extended = format!(
        "{encoded}{}",
        tc.draw(gs::text().alphabet("A=").min_size(1).max_size(3))
    );
    let noise = tc.draw(gs::text().alphabet("AQgw-_+/=Bz").min_size(41).max_size(45));
    for candidate in [mutated, truncated, extended, noise] {
        assert_eq!(
            device_public_key_valid(&candidate),
            canonical_x25519_key(&candidate)
        );
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-protocol-platform-lattice
/// `parse_platform` MUST accept exactly the four lowercase registration
/// platforms, returning the variant whose wire spelling is the input, and refuse
/// every other spelling including case and whitespace variants.
#[hegel::test(test_cases = 256)]
fn parse_platform_accepts_only_closed_set(tc: TestCase) {
    let known = [
        DevicePlatform::Ios,
        DevicePlatform::Android,
        DevicePlatform::Macos,
        DevicePlatform::Windows,
    ];
    let platform = tc.draw(gs::sampled_from(known.to_vec()));
    assert_eq!(parse_platform(platform.as_str()), Ok(platform));
    let variant = match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => platform.as_str().to_ascii_uppercase(),
        1 => format!(" {}", platform.as_str()),
        2 => format!("{}\n", platform.as_str()),
        _ => tc.draw(gs::text().alphabet("iosandrmcwlux ").max_size(10)),
    };
    let expected = known
        .into_iter()
        .find(|candidate| candidate.as_str() == variant);
    assert_eq!(parse_platform(&variant).ok(), expected);
    if expected.is_none() {
        assert_eq!(parse_platform(&variant), Err(ProtocolError::InvalidCommand));
    }
}

fn json_value(tc: &TestCase) -> Value {
    match tc.draw(gs::integers::<u8>().max_value(9)) {
        0 => Value::Null,
        1 => json!(tc.draw(gs::booleans())),
        2 => json!(tc.draw(gs::integers::<i64>())),
        3 => json!(tc.draw(gs::text().max_size(12))),
        4 => json!(tc.draw(gs::uuids())),
        5 => json!(format!(
            "porsche-{}",
            tc.draw(
                gs::text()
                    .alphabet("0123456789abcdef")
                    .min_size(32)
                    .max_size(32)
            )
        )),
        6 => json!(tc.draw(gs::sampled_from(vec![
            "accepted",
            "succeeded",
            "failed",
            "superseded",
            "running"
        ]))),
        7 => json!([1, "two"]),
        8 => json!({"nested": tc.draw(gs::integers::<u8>())}),
        _ => json!(tc.draw(gs::integers::<u16>().max_value(300))),
    }
}

fn receipt_status(value: &Value) -> Option<ReceiptStatus> {
    match value.as_str()? {
        "accepted" => Some(ReceiptStatus::Accepted),
        "succeeded" => Some(ReceiptStatus::Succeeded),
        "failed" => Some(ReceiptStatus::Failed),
        "superseded" => Some(ReceiptStatus::Superseded),
        _ => None,
    }
}

fn canonical_operation_id(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => true,
        Some(Value::String(text)) => {
            text.len() == 36
                && text.bytes().enumerate().all(|(index, byte)| {
                    if matches!(index, 8 | 13 | 18 | 23) {
                        byte == b'-'
                    } else {
                        byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                    }
                })
        }
        Some(_) => false,
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-protocol-reply-totality
/// `decode_reply` MUST be total over arbitrary text, refuse non-object JSON, and
/// classify generated envelopes exactly: a string `error` is a refusal, `status`
/// plus `request_id` is a receipt only when version, status and operation id are
/// well formed, and any other object is a read whose unknown fields are kept.
#[hegel::test(test_cases = 512)]
fn decode_reply_is_total_and_classifies_envelopes(tc: TestCase) {
    let arbitrary = tc.draw(gs::text().max_size(256));
    let _ = decode_reply(&arbitrary);

    let keys = [
        "error",
        "message",
        "status",
        "request_id",
        "version",
        "operation_id",
        "result",
        "extra",
    ];
    let mut object = Map::new();
    for key in keys {
        if tc.draw(gs::booleans()) {
            object.insert(key.to_owned(), json_value(&tc));
        }
    }
    let text = Value::Object(object.clone()).to_string();
    let reply = decode_reply(&text);
    if let Some(error) = object.get("error") {
        match error.as_str() {
            Some(error) => assert_eq!(
                reply,
                Ok(Reply::Error {
                    error: error.to_owned(),
                    message: object
                        .get("message")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                })
            ),
            None => assert_eq!(reply, Err(ProtocolError::InvalidJson)),
        }
    } else if object.contains_key("status") && object.contains_key("request_id") {
        let status = receipt_status(&object["status"]);
        let version = object
            .get("version")
            .and_then(Value::as_u64)
            .and_then(|version| u8::try_from(version).ok());
        let well_formed = status.is_some()
            && version.is_some()
            && object["request_id"].is_string()
            && canonical_operation_id(object.get("operation_id"));
        match reply {
            Ok(Reply::Receipt(receipt)) => {
                assert!(well_formed);
                assert_eq!(Some(receipt.status), status);
                assert_eq!(Some(receipt.version), version);
                assert_eq!(
                    Some(receipt.request_id.as_str()),
                    object["request_id"].as_str()
                );
                assert_eq!(
                    receipt.operation_id.map(|id| id.to_string()),
                    object
                        .get("operation_id")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                );
                assert_eq!(
                    &receipt.result,
                    object.get("result").unwrap_or(&Value::Null)
                );
            }
            other => {
                assert!(!well_formed);
                assert_eq!(other, Err(ProtocolError::InvalidJson));
            }
        }
    } else {
        assert_eq!(reply, Ok(Reply::Read(Value::Object(object))));
    }

    let scalar = json_value(&tc);
    if !scalar.is_object() {
        assert_eq!(
            decode_reply(&scalar.to_string()),
            Err(ProtocolError::InvalidJson)
        );
    }
}
