use crate::bounded;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;

pub(crate) fn decimal(text: &OsStr) -> Option<u64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    text.parse::<u64>().ok()
}

/// Validated invocation: snapshot name (with '@'), nonzero to GUID, token text.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub name: String,
    pub to: u64,
    pub token: String,
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [name, to, token] = arguments else {
        return None;
    };
    let name = name.to_str()?;
    let token = token
        .to_str()
        .and_then(|token| token.is_ascii().then_some(token))?;
    if name.len() > 255 || !name.contains('@') {
        return None;
    }
    let to = decimal(to)?;
    if to == 0 {
        return None;
    }
    // Token envelopes are selector failures in the C lattice (usage, exit 64),
    // before any library contact.
    if !bounded(token) {
        return None;
    }
    Some(Request {
        name: name.to_string(),
        to,
        token: token.to_string(),
    })
}
