//! Closed syntax validators for admission identifiers, names and labels.

use crate::{Binding, Descriptor, Refusal};
use std::fmt::Write as _;

pub fn hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

pub fn username(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 32
        && (bytes[0].is_ascii_lowercase() || bytes[0] == b'_')
        && bytes
            .last()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_.-".contains(byte))
        && ![
            "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp",
            "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody", "ubuntu", "sshd",
            "sudo", "postgres",
        ]
        .contains(&value)
        && !value.starts_with("systemd-")
        && !value.starts_with("nixbld")
}

pub(crate) fn dns_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !value.starts_with('-')
        && !value.ends_with('-')
}

pub(crate) fn dns_name(value: &str) -> bool {
    (3..=189).contains(&value.len())
        && value.split('.').count() >= 2
        && value.split('.').all(dns_label)
}

pub(crate) fn base32_uuid(value: &str) -> Option<String> {
    if value.len() != 26 {
        return None;
    }
    let mut bytes = Vec::with_capacity(16);
    let mut accumulator = 0_u16;
    let mut bits = 0_u8;
    for byte in value.bytes() {
        let digit = match byte {
            b'a'..=b'z' => byte - b'a',
            b'2'..=b'7' => byte - b'2' + 26,
            _ => return None,
        };
        accumulator = (accumulator << 5) | u16::from(digit);
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            bytes.push(u8::try_from(accumulator >> bits).ok()?);
            accumulator &= (1 << bits) - 1;
        }
    }
    if bytes.len() != 16 || bits != 2 || accumulator != 0 {
        return None;
    }
    let encoded = bytes
        .iter()
        .fold(String::with_capacity(32), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        });
    Some(format!(
        "{}-{}-{}-{}-{}",
        encoded.get(..8)?,
        encoded.get(8..12)?,
        encoded.get(12..16)?,
        encoded.get(16..20)?,
        encoded.get(20..)?
    ))
}

pub fn label_matches(binding: &Binding) -> bool {
    let bytes = binding.label.as_bytes();
    bytes.len() == 55
        && &bytes[..2] == b"e-"
        && bytes[28] == b'-'
        && std::str::from_utf8(&bytes[2..28])
            .ok()
            .and_then(base32_uuid)
            .as_deref()
            == Some(&binding.vm_id)
        && std::str::from_utf8(&bytes[29..55])
            .ok()
            .and_then(base32_uuid)
            .as_deref()
            == Some(&binding.guest_account_id)
}

impl Descriptor {
    pub fn validate(&self) -> Result<(), Refusal> {
        if self.protocol == 1 && hex(&self.commit, 40) && hex(&self.release, 64) {
            Ok(())
        } else {
            Err(Refusal::Package)
        }
    }
}
