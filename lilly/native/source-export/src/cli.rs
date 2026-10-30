use crate::{ARGV_TOTAL_LIMIT, MAX_ARGV};
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

/// A validated invocation: private lock path, bounded lease, trusted sender argv.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub lock: PathBuf,
    pub lease_ms: u32,
    pub sender: PathBuf,
    pub arguments: Vec<OsString>,
}

fn duration(text: &OsStr) -> Option<u32> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes[0] == b'0' || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let value: u32 = text.parse().ok()?;
    (1..=300_000).contains(&value).then_some(value)
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [lock, lease_text, sender, rest @ ..] = arguments else {
        return None;
    };
    if arguments.len() > MAX_ARGV + 2 {
        return None;
    }
    for absolute in [lock, sender] {
        if !absolute.as_os_str().as_bytes().starts_with(b"/") {
            return None;
        }
    }
    // The C byte span covers the sender and its arguments only.
    let total: usize = arguments[2..]
        .iter()
        .map(|arg| arg.as_os_str().as_bytes().len() + 1)
        .sum();
    if total > ARGV_TOTAL_LIMIT {
        return None;
    }
    Some(Request {
        lock: PathBuf::from(lock),
        lease_ms: duration(lease_text)?,
        sender: PathBuf::from(sender),
        arguments: rest.to_vec(),
    })
}

/// One received control frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Control {
    Renew(u32),
    Revoke,
}

/// Parse a main-loop frame: `L<millis>` renews, `X` (and any other content)
/// revokes per the wire contract.
pub fn parse_control(frame: &[u8]) -> Option<Control> {
    match frame {
        [b'L', rest @ ..] => {
            let text = std::str::from_utf8(rest).ok()?;
            let value = duration(OsStr::new(text))?;
            Some(Control::Renew(value))
        }
        _ => None,
    }
}
