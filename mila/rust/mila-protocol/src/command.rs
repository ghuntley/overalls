use crate::grammar::{allowed_option, command_name, insert_option, mutation, validate_command};
use crate::lex::{lex, quote};
use crate::{ProtocolError, MAX_COMMAND_BYTES, MAX_TOKENS};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A value in a Porsche command option map.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OptionValue {
    Bool(bool),
    String(String),
    Values(Vec<String>),
}

impl OptionValue {
    pub(crate) fn as_strings(&self) -> Vec<String> {
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
                let option = token.get(2..).ok_or(ProtocolError::InvalidCommand)?;
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
