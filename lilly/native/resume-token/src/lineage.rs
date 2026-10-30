use crate::{TOKEN_MAX_BYTES, UNPACKED_MAX_BYTES};

/// @cc [owner:ghuntley,label:security] resume-token-bounded-decoding
/// Before calling `OpenZFS`, tokens MUST have the version-1 envelope, at most
/// 8192 ASCII bytes, even lowercase hexadecimal payload and a declared unpacked
/// size of 1..16384 bytes. The library MUST verify checksum, decompression and
/// nvlist encoding. Failures MUST NOT print the token, arguments or library
/// diagnostics.
/// One lowercase-hex field terminated by '-'. The C field reader limits each
/// to sixteen digits and keeps the value for the caller's bounds policy.
fn field(rest: &[u8]) -> Option<(u64, &[u8])> {
    let dash = rest.iter().position(|b| *b == b'-')?;
    let head = &rest[..dash];
    if head.is_empty() || head.len() > 16 {
        return None;
    }
    if !head
        .iter()
        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    let value = u64::from_str_radix(std::str::from_utf8(head).ok()?, 16).ok()?;
    Some((value, &rest[dash + 1..]))
}

pub fn bounded(token: &str) -> bool {
    if !token.is_ascii() || token.len() > TOKEN_MAX_BYTES || !token.starts_with("1-") {
        return false;
    }
    let Some((_checksum, rest)) = field(&token.as_bytes()[2..]) else {
        return false;
    };
    let Some((unpacked, payload)) = field(rest) else {
        return false;
    };
    if unpacked == 0 || unpacked > UNPACKED_MAX_BYTES {
        return false;
    }
    !payload.is_empty()
        && payload.len().is_multiple_of(2)
        && payload
            .iter()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Envelope {
    pub checksum: u64,
    pub unpacked: u64,
}

/// One decoded nvlist pair.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Pair {
    Str(String, String),
    Uint(String, u64),
    Bool(String),
    Other(String, u32),
}

/// @cc [owner:ghuntley,label:security] resume-token-exact-lineage
/// Validation MUST require one toname/object/offset/bytes/toguid, no duplicate
/// or unknown fields, the exact trusted snapshot name and to GUID, and a zero
/// or absent fromguid: every transfer is one full stream (ADR-0155), so a
/// token naming any parent snapshot fails. Only ordinary large-block, embedded
/// and compressed stream capability booleans are permitted; raw, saved and
/// redacted tokens fail. Successful validation grants neither transfer nor
/// execution authority.
pub fn matches(pairs: &[Pair], name: &str, to: u64) -> bool {
    const KEYS: [&str; 9] = [
        "toname",
        "object",
        "offset",
        "bytes",
        "toguid",
        "fromguid",
        "largeblockok",
        "embedok",
        "compressok",
    ];
    let mut seen: u32 = 0;
    let mut actual_to = 0_u64;
    let mut actual_from = 0_u64;
    for pair in pairs {
        let pair_name = match pair {
            Pair::Str(n, _) | Pair::Uint(n, _) | Pair::Bool(n) | Pair::Other(n, _) => n.as_str(),
        };
        let Some(index) = KEYS.iter().position(|key| *key == pair_name) else {
            return false;
        };
        if seen & (1 << index) != 0 {
            return false;
        }
        seen |= 1 << index;
        #[expect(
            clippy::match_same_arms,
            reason = "the accepted arms carry different patterns and a guard, so they cannot merge"
        )]
        match (index, pair) {
            (0, Pair::Str(_, value)) if value.as_str() == name => {}
            (0, _) => return false,
            (1..=5, Pair::Uint(_, value)) => {
                if index == 4 {
                    actual_to = *value;
                }
                if index == 5 {
                    actual_from = *value;
                }
            }
            (1..=5, _) => return false,
            (6..=8, Pair::Bool(_)) => {}
            (6..=8, _) => return false,
            _ => unreachable!(),
        }
    }
    seen & 31 == 31 && actual_to == to && actual_from == 0
}
