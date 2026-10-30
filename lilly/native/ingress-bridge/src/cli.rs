use crate::{FDS, UIDS};
use std::ffi::{OsStr, OsString};
use std::ops::RangeInclusive;
use std::os::unix::ffi::OsStrExt;

/// A validated invocation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Request {
    /// Detached mode (ADR-0187): hostd's end of the start handshake. A
    /// detached bridge outlives hostd, so it sets no parent-death signal.
    pub control: Option<i32>,
    /// The client socket: Lilly's own socket (op 13) or, detached, Audi's
    /// connection to Lilly's ingress socket (op 14).
    pub client: i32,
    /// The guest TCP connection hostd dialled inside the namespace.
    pub guest: i32,
    /// The uid (and equal gid) the bridge drops to; None keeps its own.
    pub uid: Option<u32>,
}

/// Strict decimal: nonempty, no leading zeros, digits only, then bounds.
fn number(text: &OsStr, range: &RangeInclusive<i64>) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let value: i64 = std::str::from_utf8(bytes).ok()?.parse().ok()?;
    range.contains(&value).then_some(value)
}

/// @cc [owner:ghuntley,label:security] bridge-cli-bounded
/// The command line MUST be exactly `[--detached <control fd>] <client fd>
/// <guest fd> [<uid>]`: pairwise distinct strict decimals in 3..=1023 and an
/// optional strict decimal uid in 1..=4294967294. Anything else is refused
/// before any descriptor is used.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let (control, rest) = match arguments {
        [flag, control, rest @ ..] if flag.as_bytes() == b"--detached" => {
            (Some(number(control, &FDS)?), rest)
        }
        rest => (None, rest),
    };
    let (client, guest, uid) = match rest {
        [client, guest] => (client, guest, None),
        [client, guest, uid] => (client, guest, Some(number(uid, &UIDS)?)),
        _ => return None,
    };
    let client = number(client, &FDS)?;
    let guest = number(guest, &FDS)?;
    if client == guest || control.is_some_and(|control| control == client || control == guest) {
        return None;
    }
    Some(Request {
        control: match control {
            Some(control) => Some(i32::try_from(control).ok()?),
            None => None,
        },
        client: i32::try_from(client).ok()?,
        guest: i32::try_from(guest).ok()?,
        uid: match uid {
            Some(uid) => Some(u32::try_from(uid).ok()?),
            None => None,
        },
    })
}
