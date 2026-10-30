use std::ffi::{OsStr, OsString};

/// Canonical dotted-quad IPv4 with exact parse/render round-trip: the C
/// predecessor compared the input with its own canonical form byte for byte.
/// The value keeps inet_pton's in-memory layout (network byte order), which
/// nfct_set_attr_u32 and the kernel record use; a host-order integer would
/// query a byte-reversed address and never match a live flow.
pub fn address(text: &OsStr) -> Option<u32> {
    let text = text.to_str()?;
    let addr: std::net::Ipv4Addr = text.parse().ok()?;
    if addr.to_string() == text {
        Some(u32::from_ne_bytes(addr.octets()))
    } else {
        None
    }
}

/// Decimal port: nonempty, ≤5 digits, no leading zero, 1..=65535, stored in
/// network byte order so direct comparison against the kernel record works.
pub fn port(text: &OsStr) -> Option<u16> {
    let text = text.to_str()?;
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes.len() > 5 || bytes[0] == b'0' {
        return None;
    }
    if !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let value: u16 = text.parse().ok()?;
    if value == 0 {
        return None;
    }
    Some(value.to_be())
}

/// @cc [owner:ghuntley,label:security;capacity] native-flow-read-only-bounded
/// The helper MUST issue only a single exact conntrack GET in its inherited
/// namespace, with canonical tuple arguments and a two-second process
/// deadline. It MUST NOT dump, create, update or delete conntrack entries or
/// change namespace.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Query {
    pub source: u32,
    pub destination: u32,
    pub sport: u16,
    pub dport: u16,
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Query> {
    let [source, sport, destination, dport] = arguments else {
        return None;
    };
    Some(Query {
        source: address(source)?,
        sport: port(sport)?,
        destination: address(destination)?,
        dport: port(dport)?,
    })
}
