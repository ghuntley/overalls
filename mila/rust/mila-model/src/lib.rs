//! Typed values shared by Mila's protocol, runtime and platform bindings.
//! The model deliberately has no retired client or transport dependency.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fmt;
use thiserror::Error;
use uuid::Uuid;

const MAX_ROUTE_BYTES: usize = 2_048;
const REQUEST_PREFIX: &str = "porsche-";

/// A canonical UUID used by a route or protocol identifier.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Identifier(Uuid);

impl Identifier {
    /// @cc [owner:ghuntley,label:protocol;security] mila-model-canonical-identifier
    /// Parses only the lowercase, hyphenated UUID representation used on the wire.
    ///
    /// Identifiers accepted from a route or command MUST be canonical lowercase UUIDs;
    /// accepting another representation would make route formatting ambiguous.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        let uuid = Uuid::parse_str(value).map_err(|_| ModelError::InvalidIdentifier)?;
        if uuid.to_string() != value {
            return Err(ModelError::InvalidIdentifier);
        }
        Ok(Self(uuid))
    }

    /// Returns the underlying UUID.
    pub const fn uuid(self) -> Uuid {
        self.0
    }
}

impl fmt::Display for Identifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

/// The client platforms accepted by Porsche's device registration command.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DevicePlatform {
    Ios,
    Android,
    Macos,
    Windows,
}

impl DevicePlatform {
    /// Returns the exact protocol spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ios => "ios",
            Self::Android => "android",
            Self::Macos => "macos",
            Self::Windows => "windows",
        }
    }
}

/// A trusted repository source used by the launch route.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceSource {
    pub owner: String,
    pub repository: String,
    pub pull_request: Option<u32>,
}

impl WorkspaceSource {
    /// Parses the public GitHub URL forms shared by Marshall and Mila.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        let prefix = "https://github.com/";
        let rest = value
            .strip_prefix(prefix)
            .ok_or(ModelError::InvalidSource)?;
        if rest.contains(['?', '#', '%', '@', '\\']) {
            return Err(ModelError::InvalidSource);
        }
        let parts: Vec<&str> = rest.trim_end_matches(".git").split('/').collect();
        if parts.len() != 2 && parts.len() != 4 {
            return Err(ModelError::InvalidSource);
        }
        if parts.iter().take(2).any(|part| !valid_label(part)) {
            return Err(ModelError::InvalidSource);
        }
        let pull_request = if parts.len() == 4 && parts[2] == "pull" {
            let number = parts[3]
                .parse::<u32>()
                .map_err(|_| ModelError::InvalidSource)?;
            if number == 0 || parts[3].starts_with('0') {
                return Err(ModelError::InvalidSource);
            }
            Some(number)
        } else if parts.len() == 4 {
            return Err(ModelError::InvalidSource);
        } else {
            None
        };
        Ok(Self {
            owner: parts[0].to_owned(),
            repository: parts[1].to_owned(),
            pull_request,
        })
    }

    /// Returns the canonical source URL.
    pub fn to_url(&self) -> String {
        match self.pull_request {
            Some(number) => format!(
                "https://github.com/{}/{}/pull/{number}",
                self.owner, self.repository
            ),
            None => format!("https://github.com/{}/{}", self.owner, self.repository),
        }
    }
}

fn valid_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && value
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value
            .as_bytes()
            .last()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' || byte == b'.'
        })
        && value != "."
        && value != ".."
}

/// The closed page table for `overalls://` routes.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub enum MilaPage {
    Machines,
    Threads,
    Settings,
    Machine {
        id: Identifier,
    },
    MachineInfo {
        id: Identifier,
    },
    MachineWeb {
        id: Identifier,
    },
    MachineTerminals {
        id: Identifier,
    },
    MachineTerminal {
        machine_id: Identifier,
        session_id: Identifier,
    },
    MachineThreads {
        id: Identifier,
    },
    MachineThread {
        machine_id: Identifier,
        thread_id: Identifier,
    },
    Thread {
        id: Identifier,
    },
    Launch {
        source: WorkspaceSource,
    },
    SshApproved {
        session_id: Identifier,
    },
}

impl MilaPage {
    fn path(&self) -> String {
        match self {
            Self::Machines => "/machines".into(),
            Self::Threads => "/threads".into(),
            Self::Settings => "/settings".into(),
            Self::Machine { id } => format!("/machines/{id}"),
            Self::MachineInfo { id } => format!("/machines/{id}/info"),
            Self::MachineWeb { id } => format!("/machines/{id}/web"),
            Self::MachineTerminals { id } => format!("/machines/{id}/terminals"),
            Self::MachineTerminal {
                machine_id,
                session_id,
            } => {
                format!("/machines/{machine_id}/terminals/{session_id}")
            }
            Self::MachineThreads { id } => format!("/machines/{id}/threads"),
            Self::MachineThread {
                machine_id,
                thread_id,
            } => {
                format!("/machines/{machine_id}/threads/{thread_id}")
            }
            Self::Thread { id } => format!("/threads/{id}"),
            Self::Launch { source } => {
                format!("/launch?source={}", encode_component(&source.to_url()))
            }
            Self::SshApproved { session_id } => format!("/ssh/approved?session={session_id}"),
        }
    }

    fn describe(&self) -> Map<String, Value> {
        let mut map = Map::new();
        let (page, ids) = match self {
            Self::Machines => ("machines", vec![]),
            Self::Threads => ("threads", vec![]),
            Self::Settings => ("settings", vec![]),
            Self::Machine { id } => ("machine", vec![("machine_id", id.to_string())]),
            Self::MachineInfo { id } => ("machine_info", vec![("machine_id", id.to_string())]),
            Self::MachineWeb { id } => ("machine_web", vec![("machine_id", id.to_string())]),
            Self::MachineTerminals { id } => {
                ("machine_terminals", vec![("machine_id", id.to_string())])
            }
            Self::MachineTerminal {
                machine_id,
                session_id,
            } => (
                "machine_terminal",
                vec![
                    ("machine_id", machine_id.to_string()),
                    ("session_id", session_id.to_string()),
                ],
            ),
            Self::MachineThreads { id } => {
                ("machine_threads", vec![("machine_id", id.to_string())])
            }
            Self::MachineThread {
                machine_id,
                thread_id,
            } => (
                "machine_thread",
                vec![
                    ("machine_id", machine_id.to_string()),
                    ("thread_id", thread_id.to_string()),
                ],
            ),
            Self::Thread { id } => ("thread", vec![("thread_id", id.to_string())]),
            Self::Launch { source } => ("launch", vec![("source", source.to_url())]),
            Self::SshApproved { session_id } => {
                ("ssh_approved", vec![("session_id", session_id.to_string())])
            }
        };
        map.insert("page".into(), Value::String(page.into()));
        for (key, value) in ids {
            map.insert(key.into(), Value::String(value));
        }
        map
    }
}

/// A canonical application route.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct MilaRoute {
    pub host: String,
    pub port: Option<u16>,
    pub page: MilaPage,
}

impl MilaRoute {
    /// @cc [owner:ghuntley,label:security;protocol] mila-model-route-closed-table
    /// Parses the bounded, closed `overalls://` grammar without panicking.
    ///
    /// Route parsing MUST reject fragments, userinfo, encoded path segments, unknown
    /// query keys and non-canonical identifiers; accepted routes MUST format canonically.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        if value.len() > MAX_ROUTE_BYTES
            || value.contains('#')
            || value.chars().any(|c| c.is_control() || c == ' ')
        {
            return Err(ModelError::InvalidRoute);
        }
        let rest = value
            .strip_prefix("overalls://")
            .ok_or(ModelError::InvalidRoute)?;
        let (location, query) = match rest.split_once('?') {
            Some((location, query)) if !query.contains('?') => (location, Some(query)),
            Some(_) => return Err(ModelError::InvalidRoute),
            None => (rest, None),
        };
        if location.contains(['%', '@']) {
            return Err(ModelError::InvalidRoute);
        }
        let mut pieces = location.split('/');
        let authority = pieces.next().ok_or(ModelError::InvalidRoute)?;
        let segments: Vec<&str> = pieces.collect();
        if authority.is_empty() || segments.iter().any(|segment| segment.is_empty()) {
            return Err(ModelError::InvalidRoute);
        }
        let (host, port) = parse_authority(authority)?;
        let page = parse_page(&segments, query)?;
        Ok(Self { host, port, page })
    }

    /// Formats the route in the canonical representation accepted by the parser.
    pub fn format(&self) -> String {
        format!(
            "overalls://{}{}",
            match self.port {
                Some(port) => format!("{}:{port}", self.host),
                None => self.host.clone(),
            },
            self.page.path()
        )
    }

    /// Returns the fixture-compatible route description.
    pub fn describe(&self) -> Value {
        let mut map = Map::new();
        map.insert("host".into(), Value::String(self.host.clone()));
        map.insert(
            "port".into(),
            self.port
                .map_or(Value::Null, |port| Value::Number(port.into())),
        );
        map.extend(self.page.describe());
        Value::Object(map)
    }
}

fn parse_authority(value: &str) -> Result<(String, Option<u16>), ModelError> {
    let (host, port) = match value.split_once(':') {
        Some((host, port)) if !port.is_empty() && !port.contains(':') => {
            let value = port.parse::<u16>().map_err(|_| ModelError::InvalidRoute)?;
            if port.starts_with('0') || value == 0 {
                return Err(ModelError::InvalidRoute);
            }
            (host, Some(value))
        }
        Some(_) => return Err(ModelError::InvalidRoute),
        None => (value, None),
    };
    if !valid_hostname(host) {
        return Err(ModelError::InvalidRoute);
    }
    Ok((host.into(), port))
}

fn valid_hostname(value: &str) -> bool {
    value.len() <= 253
        && !value.is_empty()
        && value.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
                && !label.starts_with('-')
                && !label.ends_with('-')
        })
}

fn parse_page(segments: &[&str], query: Option<&str>) -> Result<MilaPage, ModelError> {
    let no_query = query.is_none();
    match (segments, query) {
        (["machines"], None) => Ok(MilaPage::Machines),
        (["threads"], None) => Ok(MilaPage::Threads),
        (["settings"], None) => Ok(MilaPage::Settings),
        (["machines", id], None) => Ok(MilaPage::Machine {
            id: Identifier::parse(id)?,
        }),
        (["machines", id, "info"], None) => Ok(MilaPage::MachineInfo {
            id: Identifier::parse(id)?,
        }),
        (["machines", id, "web"], None) => Ok(MilaPage::MachineWeb {
            id: Identifier::parse(id)?,
        }),
        (["machines", id, "terminals"], None) => Ok(MilaPage::MachineTerminals {
            id: Identifier::parse(id)?,
        }),
        (["machines", id, "terminals", session], None) => Ok(MilaPage::MachineTerminal {
            machine_id: Identifier::parse(id)?,
            session_id: Identifier::parse(session)?,
        }),
        (["machines", id, "threads"], None) => Ok(MilaPage::MachineThreads {
            id: Identifier::parse(id)?,
        }),
        (["machines", id, "threads", thread], None) => Ok(MilaPage::MachineThread {
            machine_id: Identifier::parse(id)?,
            thread_id: Identifier::parse(thread)?,
        }),
        (["threads", id], None) => Ok(MilaPage::Thread {
            id: Identifier::parse(id)?,
        }),
        (["launch"], Some(query)) => {
            let value = single_query(query, "source")?;
            Ok(MilaPage::Launch {
                source: WorkspaceSource::parse(&value)?,
            })
        }
        (["ssh", "approved"], Some(query)) => Ok(MilaPage::SshApproved {
            session_id: Identifier::parse(&single_query(query, "session")?)?,
        }),
        _ if !no_query => Err(ModelError::InvalidRoute),
        _ => Err(ModelError::InvalidRoute),
    }
}

fn single_query(query: &str, expected: &str) -> Result<String, ModelError> {
    let (key, encoded) = query.split_once('=').ok_or(ModelError::InvalidRoute)?;
    if key != expected || encoded.is_empty() || encoded.contains(['=', '&']) {
        return Err(ModelError::InvalidRoute);
    }
    decode_component(encoded).ok_or(ModelError::InvalidRoute)
}

fn decode_component(value: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let raw = value.as_bytes();
    let mut index = 0;
    while index < raw.len() {
        if raw[index] == b'%' {
            if index + 2 >= raw.len() {
                return None;
            }
            let high = (raw[index + 1] as char).to_digit(16)? as u8;
            let low = (raw[index + 2] as char).to_digit(16)? as u8;
            bytes.push(high * 16 + low);
            index += 3;
        } else {
            bytes.push(if raw[index] == b'+' { b' ' } else { raw[index] });
            index += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn encode_component(value: &str) -> String {
    value.bytes().fold(String::new(), |mut output, byte| {
        if byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte) {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(char::from(b"0123456789ABCDEF"[(byte >> 4) as usize]));
            output.push(char::from(b"0123456789ABCDEF"[(byte & 0xf) as usize]));
        }
        output
    })
}

/// Typed errors shared by model constructors and parsers.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ModelError {
    #[error("invalid identifier")]
    InvalidIdentifier,
    #[error("invalid application route")]
    InvalidRoute,
    #[error("invalid workspace source")]
    InvalidSource,
    #[error("invalid request id")]
    InvalidRequestId,
}

/// The client allocated mutation request identifier.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct RequestId(String);

impl RequestId {
    /// @cc [owner:ghuntley,label:protocol] mila-model-request-id
    /// Constructs an id from its canonical wire representation.
    ///
    /// Mutation request ids MUST have exactly `porsche-` plus 32 lowercase hexadecimal
    /// characters, preventing accidental retries under a different identity.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        let suffix = value
            .strip_prefix(REQUEST_PREFIX)
            .ok_or(ModelError::InvalidRequestId)?;
        if suffix.len() != 32
            || !suffix
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(ModelError::InvalidRequestId);
        }
        Ok(Self(value.into()))
    }

    /// Returns the wire representation.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for RequestId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests;
