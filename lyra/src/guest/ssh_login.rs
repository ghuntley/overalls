//! Login receipts from sshd's own log (ADR-0171, gate 3).
//!
//! Linux guests report a login from a PAM session hook that sees sshd's
//! authentication info. Win32-OpenSSH has no PAM, but with `SyslogFacility
//! LOCAL0` it writes its log to `%ProgramData%\ssh\logs\sshd.log`, one
//! `Accepted publickey for <user> from <address> port <n> ssh2: <type>
//! SHA256:<fingerprint>` line per successful authentication. The roster agent
//! tails that file, maps the fingerprint back to one of the keys it pulled for
//! that account and posts the same `/ssh/v1/login` report the Linux hook sends.
//! Nothing from the log line reaches the authority except the username and the
//! matched public key; unmatched lines are dropped.

use base64::Engine;
use sha2::{Digest, Sha256};

/// One accepted public-key authentication as sshd logged it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Accepted {
    pub username: String,
    pub fingerprint: String,
}

/// @cc [owner:ghuntley,label:security] ssh-login-line-closed-parse
/// `parse_accepted` MUST recognise only sshd's `Accepted publickey for … ssh2:
/// <type> SHA256:<fingerprint>` form with a safe username and a base64
/// fingerprint of 43 characters, wherever the line's prefix (timestamp, pid)
/// places it; every other line yields nothing.
pub fn parse_accepted(line: &str) -> Option<Accepted> {
    let (_, rest) = line.split_once("Accepted publickey for ")?;
    let (username, rest) = rest.split_once(" from ")?;
    if !crate::guest::ssh_roster::valid_name(username) {
        return None;
    }
    let (_, rest) = rest.split_once(" ssh2: ")?;
    let mut fields = rest.split_whitespace();
    let _key_type = fields.next()?;
    let fingerprint = fields.next()?;
    let encoded = fingerprint.strip_prefix("SHA256:")?;
    if encoded.len() != 43
        || !encoded
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'+' || byte == b'/')
    {
        return None;
    }
    Some(Accepted {
        username: username.to_owned(),
        fingerprint: fingerprint.to_owned(),
    })
}

/// The OpenSSH `SHA256:` fingerprint of an authorized key line (`type base64 …`).
pub fn fingerprint(public_key: &str) -> Option<String> {
    let encoded = public_key.split_whitespace().nth(1)?;
    let blob = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    Some(format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(Sha256::digest(blob))
    ))
}

/// The pulled key whose fingerprint sshd reported, if any.
pub fn matching_key<'a>(keys: &'a [String], accepted: &Accepted) -> Option<&'a str> {
    keys.iter()
        .find(|key| fingerprint(key).as_deref() == Some(accepted.fingerprint.as_str()))
        .map(String::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA overalls";

    #[test]
    fn parses_accepted_lines_with_any_prefix() {
        let fingerprint = fingerprint(KEY).unwrap();
        assert!(fingerprint.starts_with("SHA256:") && fingerprint.len() == 50);
        let line = format!(
            "1234 2026-10-14 22:00:00.123 Accepted publickey for u200000 from 10.10.0.1 port 51234 ssh2: ED25519 {fingerprint}"
        );
        let accepted = parse_accepted(&line).unwrap();
        assert_eq!(accepted.username, "u200000");
        assert_eq!(accepted.fingerprint, fingerprint);
        let keys = vec![
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAAQA= other".to_string(),
            KEY.to_string(),
        ];
        assert_eq!(matching_key(&keys, &accepted), Some(KEY));
        assert!(matching_key(&keys[..1], &accepted).is_none());
    }

    #[test]
    fn refuses_other_lines() {
        for line in [
            "Failed publickey for u200000 from 10.10.0.1 port 1 ssh2: ED25519 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "Accepted password for u200000 from 10.10.0.1 port 1 ssh2",
            "Accepted publickey for Administrator from 10.10.0.1 port 1 ssh2: ED25519 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "Accepted publickey for u200000 from 10.10.0.1 port 1 ssh2: ED25519 SHA256:short",
            "Accepted publickey for u200000 from 10.10.0.1 port 1 ssh2: ED25519 MD5:aa:bb",
            "",
        ] {
            assert!(parse_accepted(line).is_none(), "{line}");
        }
        assert!(fingerprint("ssh-ed25519").is_none());
        assert!(fingerprint("ssh-ed25519 !!!").is_none());
    }
}
