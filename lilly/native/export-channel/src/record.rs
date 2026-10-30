use crate::{COMMAND_BYTES, KEY_BYTES, MAGIC, WIRE_BYTES};

/// The wire-visible export request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Request {
    pub key: String,
    pub command: String,
}

pub(crate) fn key_bytes_ok(bytes: &[u8]) -> bool {
    bytes
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(b))
}

fn command_ok(bytes: &[u8]) -> bool {
    !bytes.is_empty() && bytes.len() < COMMAND_BYTES && bytes.iter().all(|b| (32..=126).contains(b))
}

/// @cc [owner:ghuntley,label:protocol] export-record-exact-fields
/// Records MUST have exactly one 68-byte charset key, one nonempty bounded
/// printable command, and zero-filled padding; anything else MUST be rejected
/// before the worker environment is prepared.
pub fn build(key: &str, command: &str) -> Option<Request> {
    if key.len() != 68 || !key_bytes_ok(key.as_bytes()) {
        return None;
    }
    if !command_ok(command.as_bytes()) {
        return None;
    }
    Some(Request {
        key: key.to_string(),
        command: command.to_string(),
    })
}

pub fn encode(request: &Request) -> [u8; WIRE_BYTES] {
    debug_assert_eq!(request.key.len(), 68);
    let mut wire = [0_u8; WIRE_BYTES];
    wire[0..4].copy_from_slice(MAGIC);
    wire[4..6].copy_from_slice(&68_u16.to_be_bytes());
    wire[6..8].copy_from_slice(&(request.command.len() as u16).to_be_bytes());
    wire[8..8 + 68].copy_from_slice(request.key.as_bytes());
    let start = 8 + KEY_BYTES;
    wire[start..start + request.command.len()].copy_from_slice(request.command.as_bytes());
    wire
}

pub fn decode(wire: &[u8]) -> Option<Request> {
    if wire.len() != WIRE_BYTES {
        return None;
    }
    if &wire[0..4] != MAGIC {
        return None;
    }
    let key_size = u16::from_be_bytes([wire[4], wire[5]]);
    let command_size = u16::from_be_bytes([wire[6], wire[7]]);
    if key_size as usize != 68 || command_size == 0 || command_size as usize >= COMMAND_BYTES {
        return None;
    }
    let key = &wire[8..8 + KEY_BYTES];
    let command = &wire[8 + KEY_BYTES..];
    if !key[..key_size as usize]
        .iter()
        .all(|b| key_bytes_ok([*b].as_slice()) && *b != 0)
    {
        return None;
    }
    if !command[..command_size as usize]
        .iter()
        .all(|byte| (32..=126).contains(byte))
    {
        return None;
    }
    if key[key_size as usize..].iter().any(|b| *b != 0)
        || command[command_size as usize..].iter().any(|b| *b != 0)
    {
        return None;
    }
    Some(Request {
        key: String::from_utf8(key[..68].to_vec()).expect("charset is ASCII-safe"),
        command: String::from_utf8(command[..command_size as usize].to_vec())
            .expect("printable ASCII"),
    })
}
