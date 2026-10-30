//! Porsche's bounded JSON and SSH command protocol.

use mila_model::{DevicePlatform, Identifier, MilaRoute, ModelError, RequestId};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use thiserror::Error;

pub use mila_model::{MilaPage, WorkspaceSource};

/// Maximum command-line bytes accepted by Porsche.
pub const MAX_COMMAND_BYTES: usize = 8_192;
/// Maximum token count accepted by Porsche's lexer.
pub const MAX_TOKENS: usize = 32;

/// A value in a Porsche command option map.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OptionValue {
    Bool(bool),
    String(String),
    Values(Vec<String>),
}

impl OptionValue {
    fn as_strings(&self) -> Vec<String> {
        match self {
            Self::Bool(value) => vec![value.to_string()],
            Self::String(value) => vec![value.clone()],
            Self::Values(values) => values.clone(),
        }
    }
}

/// A parsed command line with no shell evaluation.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Command {
    pub command: String,
    pub arguments: Vec<String>,
    pub options: BTreeMap<String, OptionValue>,
}

impl Command {
    /// @cc [owner:ghuntley,label:security;protocol] mila-protocol-command-no-shell
    /// Parses a command using Porsche's shell-independent bounded grammar.
    ///
    /// Parsing MUST never invoke a shell or evaluate substitutions, MUST enforce the
    /// command catalog, and MUST reject unknown options and malformed quoting.
    pub fn parse(line: &str) -> Result<Self, ProtocolError> {
        if line.len() > MAX_COMMAND_BYTES || line.contains(['\0', '\n', '\r']) {
            return Err(ProtocolError::InvalidCommand);
        }
        let tokens = lex(line)?;
        if tokens.is_empty() || tokens.len() > MAX_TOKENS {
            return Err(ProtocolError::InvalidCommand);
        }
        let (command, mut index) = command_name(&tokens)?;
        let mut arguments = Vec::new();
        let mut options = BTreeMap::new();
        let mut after_separator = false;
        while index < tokens.len() {
            let token = &tokens[index];
            if token == "--" {
                if after_separator {
                    return Err(ProtocolError::InvalidCommand);
                }
                after_separator = true;
                index += 1;
                continue;
            }
            if !after_separator && token.starts_with("--") && token.len() > 2 {
                let option = &token[2..];
                let (key, inline) = option
                    .split_once('=')
                    .map_or((option, None), |(key, value)| (key, Some(value)));
                if key.is_empty() || !allowed_option(&command, key) {
                    return Err(ProtocolError::InvalidCommand);
                }
                let boolean = matches!(
                    key,
                    "json" | "no-wait" | "peer" | "public" | "private" | "session" | "read-only"
                );
                let value = if boolean {
                    if inline.is_some() {
                        return Err(ProtocolError::InvalidCommand);
                    }
                    OptionValue::Bool(true)
                } else {
                    let value = match inline {
                        Some(value) if !value.is_empty() => value.to_owned(),
                        Some(_) => return Err(ProtocolError::InvalidCommand),
                        None => {
                            index += 1;
                            tokens
                                .get(index)
                                .cloned()
                                .ok_or(ProtocolError::InvalidCommand)?
                        }
                    };
                    OptionValue::String(value)
                };
                insert_option(&mut options, key, value)?;
            } else {
                arguments.push(token.clone());
            }
            index += 1;
        }
        validate_command(&command, &arguments, &options)?;
        Ok(Self {
            command,
            arguments,
            options,
        })
    }

    /// Formats a validated command into a canonical line that parses back identically.
    pub fn format(&self) -> Result<String, ProtocolError> {
        validate_command(&self.command, &self.arguments, &self.options)?;
        let mut tokens = vec![self.command.clone()];
        tokens.extend(self.arguments.iter().map(|value| quote(value)));
        for (key, value) in &self.options {
            match value {
                OptionValue::Bool(true) => tokens.push(format!("--{key}")),
                OptionValue::Bool(false) => return Err(ProtocolError::InvalidCommand),
                OptionValue::String(value) => tokens.push(format!("--{key}={}", quote(value))),
                OptionValue::Values(values) => {
                    for value in values {
                        tokens.push(format!("--{key}={}", quote(value)));
                    }
                }
            }
        }
        let line = tokens.join(" ");
        if line.len() > MAX_COMMAND_BYTES {
            return Err(ProtocolError::CommandTooLarge);
        }
        Ok(line)
    }

    /// Returns whether this command has mutation semantics.
    pub fn is_mutation(&self) -> bool {
        mutation(&self.command)
    }

    /// Returns the requested stdin payload kind, if any.
    pub fn stdin_kind(&self) -> Option<PayloadKind> {
        match self.command.as_str() {
            "thread prompt" => Some(PayloadKind::Prompt),
            "thread answer" => Some(PayloadKind::Answer),
            "thread plan revise" => Some(PayloadKind::Revision),
            _ => None,
        }
    }
}

/// Payload classes accepted on stdin, bounded separately from command lines.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PayloadKind {
    Prompt,
    Answer,
    Revision,
}

/// The protocol's closed receipt status.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReceiptStatus {
    Accepted,
    Succeeded,
    Failed,
    Superseded,
}

/// A typed mutation receipt.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Receipt {
    pub version: u8,
    pub request_id: RequestId,
    pub status: ReceiptStatus,
    pub operation_id: Option<Identifier>,
    #[serde(default)]
    pub result: Value,
}

/// A command result or refusal returned by Porsche.
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    Receipt(Receipt),
    Read(Value),
    Error {
        error: String,
        message: Option<String>,
    },
}

/// @cc [owner:ghuntley,label:protocol] mila-protocol-strict-envelope
/// Decodes a JSON result while preserving unknown result-body fields.
///
/// Envelope fields MUST be validated before use; result bodies may retain unknown keys
/// so store-distributed clients can read additive server fields safely.
pub fn decode_reply(value: &str) -> Result<Reply, ProtocolError> {
    let object: serde_json::Map<String, Value> =
        serde_json::from_str(value).map_err(|_| ProtocolError::InvalidJson)?;
    if object.get("error").is_some() {
        let error = object
            .get("error")
            .and_then(Value::as_str)
            .ok_or(ProtocolError::InvalidJson)?
            .to_owned();
        let message = object
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_owned);
        return Ok(Reply::Error { error, message });
    }
    if object.get("status").is_some() && object.get("request_id").is_some() {
        let receipt: Receipt = serde_json::from_value(Value::Object(object))
            .map_err(|_| ProtocolError::InvalidJson)?;
        return Ok(Reply::Receipt(receipt));
    }
    Ok(Reply::Read(Value::Object(object)))
}

/// Encodes a route through the shared model parser.
pub fn parse_route(value: &str) -> Result<MilaRoute, ModelError> {
    MilaRoute::parse(value)
}

/// Validates a push platform without allowing a future spelling accidentally.
pub fn parse_platform(value: &str) -> Result<DevicePlatform, ProtocolError> {
    match value {
        "ios" => Ok(DevicePlatform::Ios),
        "android" => Ok(DevicePlatform::Android),
        "macos" => Ok(DevicePlatform::Macos),
        "windows" => Ok(DevicePlatform::Windows),
        _ => Err(ProtocolError::InvalidCommand),
    }
}

fn command_name(tokens: &[String]) -> Result<(String, usize), ProtocolError> {
    let first = tokens.first().ok_or(ProtocolError::InvalidCommand)?;
    if tokens.len() >= 3 {
        let joined = format!("{first} {} {}", tokens[1], tokens[2]);
        if command_known(&joined) {
            return Ok((joined, 3));
        }
    }
    if tokens.len() >= 2 {
        let joined = format!("{first} {}", tokens[1]);
        if command_known(&joined) {
            return Ok((joined, 2));
        }
    }
    if command_known(first) {
        Ok((first.clone(), 1))
    } else {
        Err(ProtocolError::InvalidCommand)
    }
}

fn command_known(command: &str) -> bool {
    matches!(
        command,
        "whoami"
            | "images"
            | "ls"
            | "show"
            | "start"
            | "pause"
            | "resume"
            | "unpause"
            | "stop"
            | "rm"
            | "pin"
            | "unpin"
            | "new"
            | "resize"
            | "share add"
            | "share remove"
            | "request show"
            | "ssh-key list"
            | "ssh-key remove"
            | "share show"
            | "device ls"
            | "device rm"
            | "device prefs"
            | "device register"
            | "team list"
            | "thread ls"
            | "thread show"
            | "thread turns"
            | "thread prompt"
            | "thread answer"
            | "thread plan approve"
            | "thread plan revise"
            | "thread mode"
            | "thread read"
            | "terminal ls"
            | "terminal new"
            | "terminal kill"
            | "terminal attach"
            | "web show"
            | "web set"
            | "watch"
    )
}

fn allowed_option(command: &str, key: &str) -> bool {
    if key == "json" {
        return true;
    }
    match command {
        "ls" | "share show" => key == "after",
        "start" => matches!(key, "timeout" | "no-wait" | "request-id"),
        "new" => matches!(
            key,
            "name"
                | "image"
                | "profile"
                | "cpu"
                | "memory"
                | "disk"
                | "team"
                | "source"
                | "timeout"
                | "no-wait"
                | "request-id"
        ),
        "resize" => matches!(
            key,
            "cpu" | "memory" | "disk" | "timeout" | "no-wait" | "request-id"
        ),
        "thread ls" => matches!(key, "machine" | "after"),
        "thread turns" => key == "after",
        "watch" => matches!(key, "machine" | "thread" | "session"),
        "web set" => matches!(
            key,
            "port" | "public" | "private" | "revision" | "request-id"
        ),
        "terminal attach" => matches!(key, "cursor" | "read-only"),
        "device prefs" => matches!(key, "enabled" | "request-id"),
        "device register" => matches!(
            key,
            "platform" | "push-key" | "enc-pubkey" | "label" | "request-id"
        ),
        "device rm"
        | "ssh-key remove"
        | "share add"
        | "share remove"
        | "terminal new"
        | "terminal kill"
        | "thread prompt"
        | "thread answer"
        | "thread plan approve"
        | "thread plan revise"
        | "thread mode"
        | "thread read"
        | "pin"
        | "unpin" => key == "request-id",
        _ if mutation(command) => matches!(key, "request-id" | "no-wait" | "timeout"),
        _ => false,
    }
}

fn insert_option(
    options: &mut BTreeMap<String, OptionValue>,
    key: &str,
    value: OptionValue,
) -> Result<(), ProtocolError> {
    if matches!(key, "machine" | "thread") {
        match options.remove(key) {
            Some(OptionValue::String(previous)) => {
                options.insert(
                    key.into(),
                    OptionValue::Values(vec![previous, value.as_strings().remove(0)]),
                );
            }
            Some(OptionValue::Values(mut values)) => {
                values.extend(value.as_strings());
                options.insert(key.into(), OptionValue::Values(values));
            }
            Some(_) => return Err(ProtocolError::InvalidCommand),
            None => {
                options.insert(key.into(), value);
            }
        }
    } else if options.insert(key.into(), value).is_some() {
        return Err(ProtocolError::InvalidCommand);
    }
    Ok(())
}

fn validate_command(
    command: &str,
    arguments: &[String],
    options: &BTreeMap<String, OptionValue>,
) -> Result<(), ProtocolError> {
    let (min, max) = match command {
        "whoami" | "images" | "ls" | "team list" | "watch" | "ssh-key list" | "device ls"
        | "device register" => (0, 0),
        "device rm" | "device prefs" | "share show" => (1, 1),
        "terminal attach" => (2, 2),
        "show" | "start" | "resize" | "request show" | "ssh-key remove" | "thread show"
        | "thread turns" | "terminal ls" | "terminal new" | "web show" => (1, 1),
        "pause" | "resume" | "unpause" | "stop" | "rm" | "pin" | "unpin" => (1, 1),
        "new" => (0, 0),
        "share add" => (3, 3),
        "share remove" => (2, 2),
        "thread ls" => (0, 0),
        "thread prompt" => (2, 2),
        "thread answer" => (3, 3),
        "thread plan approve" => (2, 2),
        "thread plan revise" => (3, 3),
        "thread mode" | "thread read" => (2, 2),
        "terminal kill" => (2, 2),
        "web set" => (1, 1),
        _ => return Err(ProtocolError::InvalidCommand),
    };
    if arguments.len() < min || arguments.len() > max || options.len() > 12 {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "watch"
        && !options
            .keys()
            .any(|key| matches!(key.as_str(), "machine" | "thread" | "session"))
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if let Some(value) = options.get("thread") {
        if !value
            .as_strings()
            .iter()
            .all(|item| Identifier::parse(item).is_ok())
        {
            return Err(ProtocolError::InvalidCommand);
        }
    }
    if command == "thread prompt" && arguments.last().is_none_or(|value| value != "-") {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "thread answer" && arguments.last().is_none_or(|value| value != "-") {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "thread plan revise" && arguments.last().is_none_or(|value| value != "-") {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "share add" && arguments.get(2).is_some_and(|role| role == "owner") {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "show"
        && arguments.first().is_some_and(|value| {
            !value.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"-_.".contains(&byte)
            })
        })
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "request show"
        && arguments
            .first()
            .is_none_or(|value| RequestId::parse(value).is_err())
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if matches!(
        command,
        "thread show"
            | "thread turns"
            | "thread prompt"
            | "thread answer"
            | "thread plan approve"
            | "thread plan revise"
            | "thread mode"
            | "thread read"
    ) && arguments
        .first()
        .is_none_or(|value| Identifier::parse(value).is_err())
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if matches!(command, "thread answer" | "thread plan approve")
        && arguments
            .get(1)
            .is_none_or(|value| Identifier::parse(value).is_err())
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "thread read"
        && arguments
            .get(1)
            .is_none_or(|value| value.parse::<u64>().is_err() || value.starts_with('0'))
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "thread ls" && matches!(options.get("machine"), Some(OptionValue::Values(_))) {
        return Err(ProtocolError::InvalidCommand);
    }
    if matches!(command, "device rm" | "device prefs")
        && arguments
            .first()
            .is_none_or(|value| Identifier::parse(value).is_err())
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "device prefs"
        && !matches!(options.get("enabled"), Some(OptionValue::String(value)) if value == "true" || value == "false")
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "device register" && !device_register_options_valid(options) {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "web set" && options.is_empty() {
        return Err(ProtocolError::InvalidCommand);
    }
    if options.contains_key("public") && options.contains_key("private") {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "terminal kill"
        && arguments
            .get(1)
            .is_none_or(|value| Identifier::parse(value).is_err())
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "terminal attach"
        && arguments
            .get(1)
            .is_none_or(|value| Identifier::parse(value).is_err())
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if command == "thread mode"
        && arguments
            .get(1)
            .is_none_or(|value| !matches!(value.as_str(), "plan" | "work"))
    {
        return Err(ProtocolError::InvalidCommand);
    }
    if let Some(OptionValue::String(source)) = options.get("source") {
        if WorkspaceSource::parse(source).is_err() {
            return Err(ProtocolError::InvalidCommand);
        }
    }
    if let Some(OptionValue::String(image)) = options.get("image") {
        if image.starts_with("sha256:") {
            return Err(ProtocolError::InvalidCommand);
        }
    }
    for (key, value) in options {
        if matches!(
            key.as_str(),
            "timeout" | "port" | "cpu" | "memory" | "disk" | "revision" | "after" | "cursor"
        ) {
            let text = match value {
                OptionValue::String(text) => text,
                _ => return Err(ProtocolError::InvalidCommand),
            };
            let valid_cursor = matches!(command, "ls" | "thread ls" | "share show")
                && Identifier::parse(text).is_ok();
            let valid_number = !text.is_empty()
                && !(text.len() > 1 && text.starts_with('0'))
                && text.bytes().all(|byte| byte.is_ascii_digit());
            if !valid_cursor && !valid_number {
                return Err(ProtocolError::InvalidCommand);
            }
            if let Ok(number) = text.parse::<u64>() {
                if key == "timeout" && !(1..=3600).contains(&number) {
                    return Err(ProtocolError::InvalidCommand);
                }
                if key == "port" && !(1..=65535).contains(&number) {
                    return Err(ProtocolError::InvalidCommand);
                }
                if key == "disk" && !(1..=500).contains(&number) {
                    return Err(ProtocolError::InvalidCommand);
                }
                if key == "revision" && number == 0 {
                    return Err(ProtocolError::InvalidCommand);
                }
            }
        }
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:protocol;security] mila-protocol-device-register-options
/// Device registration MUST name a closed platform, read the Susan push key from
/// stdin (`-`) and carry a canonical unpadded base64url 32-byte X25519 public key,
/// matching Porsche's `ssh-device-register-options`. A literal push key is refused
/// so the opaque Susan key never appears on a command line.
fn device_register_options_valid(options: &BTreeMap<String, OptionValue>) -> bool {
    let text = |key: &str| match options.get(key) {
        Some(OptionValue::String(value)) => Some(value.as_str()),
        _ => None,
    };
    let platform_valid = text("platform").is_some_and(|value| parse_platform(value).is_ok());
    let push_key_valid = text("push-key") == Some("-");
    let key_valid = text("enc-pubkey").is_some_and(device_public_key_valid);
    let label_valid = match options.get("label") {
        None => true,
        Some(OptionValue::String(value)) => {
            (1..=64).contains(&value.len()) && !value.chars().any(char::is_control)
        }
        Some(_) => false,
    };
    platform_valid && push_key_valid && key_valid && label_valid
}

/// True for the canonical unpadded base64url encoding of exactly 32 bytes.
pub fn device_public_key_valid(value: &str) -> bool {
    // 32 bytes encode to 43 symbols; the final symbol carries two zero pad bits.
    value.len() == 43
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        && value
            .bytes()
            .last()
            .is_some_and(|b| b"AEIMQUYcgkosw048".contains(&b))
}

fn mutation(command: &str) -> bool {
    matches!(
        command,
        "new"
            | "start"
            | "pause"
            | "resume"
            | "unpause"
            | "stop"
            | "rm"
            | "pin"
            | "unpin"
            | "resize"
            | "share add"
            | "share remove"
            | "ssh-key remove"
            | "device rm"
            | "device prefs"
            | "device register"
            | "thread prompt"
            | "thread answer"
            | "thread plan approve"
            | "thread plan revise"
            | "thread mode"
            | "thread read"
            | "terminal new"
            | "terminal kill"
            | "web set"
    )
}

fn lex(line: &str) -> Result<Vec<String>, ProtocolError> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut mode = 0u8;
    let mut escaped = false;
    for character in line.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if mode == 1 {
            match character {
                '\'' => mode = 0,
                _ => current.push(character),
            }
            continue;
        }
        if mode == 2 {
            match character {
                '"' => mode = 0,
                '\\' => escaped = true,
                _ => current.push(character),
            }
            continue;
        }
        match character {
            '\\' => escaped = true,
            '\'' => mode = 1,
            '"' => mode = 2,
            character if character.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(character),
        }
    }
    if escaped || mode != 0 {
        return Err(ProtocolError::InvalidCommand);
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    Ok(tokens)
}

fn quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._/-".contains(&byte))
    {
        return value.into();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Typed protocol failures.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProtocolError {
    #[error("invalid command")]
    InvalidCommand,
    #[error("command too large")]
    CommandTooLarge,
    #[error("invalid JSON")]
    InvalidJson,
}
