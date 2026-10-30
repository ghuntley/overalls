use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ssh_key::{Algorithm, Certificate, HashAlg, PublicKey};
use std::io;

pub const ALGORITHM: &str = "ssh-ed25519-cert-v01@openssh.com";
pub const RENEWAL_WINDOW: u64 = 30 * 86_400;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Trust {
    pub version: u8,
    pub ca: String,
    pub management_host: String,
    pub zone: String,
    pub retirement: u64,
}

pub fn hostname(value: &str) -> bool {
    (1..=253).contains(&value.len())
        && value.split('.').all(|part| {
            (1..=63).contains(&part.len())
                && !part.starts_with('-')
                && !part.ends_with('-')
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}

pub fn public_key(value: &str) -> io::Result<PublicKey> {
    if value.len() > 4096 || value.contains(['\n', '\r']) {
        return Err(invalid());
    }
    let key = PublicKey::from_openssh(value).map_err(|_| invalid())?;
    if key.algorithm() != Algorithm::Ed25519 || !key.comment().is_empty() {
        return Err(invalid());
    }
    Ok(key)
}

impl Trust {
    pub fn validate(&self, origin_host: &str, zone: &str, now: u64) -> io::Result<()> {
        public_key(&self.ca)?;
        if self.version != 1
            || self.management_host != origin_host
            || self.zone != zone
            || !hostname(&self.management_host)
            || self.management_host.len() > 180
            || !hostname(&self.zone)
            || self.zone.len() > 189
            || self.retirement <= now
        {
            return Err(invalid());
        }
        Ok(())
    }
    pub fn known_hosts(&self) -> String {
        format!(
            "@cert-authority {},*.{},*.ssh.{} {}\n",
            self.management_host, self.zone, self.management_host, self.ca
        )
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Issued {
    pub version: u8,
    pub certificate: String,
    pub principal: String,
    pub ca: String,
}

/// @cc [owner:ghuntley,label:security] ssh-certificate-full-verification
/// Successful validation MUST authenticate the CA signature, exact leaf key,
/// host certificate type, exact principal and validity. Wildcards and unhandled
/// options MUST NOT broaden the server identity or become login authority.
pub fn verify(
    line: &str,
    ca: &str,
    key: &str,
    principal: &str,
    now: u64,
) -> io::Result<Certificate> {
    if line.len() > 16_384 || !hostname(principal) {
        return Err(invalid());
    }
    let cert = Certificate::from_openssh(line.trim()).map_err(|_| invalid())?;
    let issuer = public_key(ca)?;
    let leaf = public_key(key)?;
    if !cert.cert_type().is_host()
        || cert.public_key() != leaf.key_data()
        || cert.signature_key() != issuer.key_data()
        || cert.valid_principals() != [principal]
        || !cert.critical_options().is_empty()
        || !cert.extensions().is_empty()
    {
        return Err(invalid());
    }
    cert.validate_at(now, [&issuer.fingerprint(HashAlg::Sha256)])
        .map_err(|_| invalid())?;
    Ok(cert)
}

pub fn gateway_principal(key: &str, host: &str) -> io::Result<String> {
    let key = public_key(key)?;
    let blob = key.to_bytes().map_err(|_| invalid())?;
    let digest = Sha256::digest(blob);
    // RFC4648 lowercase base32 without padding, matching the protocol library.
    let mut encoded = String::new();
    let mut bits = 0_u32;
    let mut count = 0_u32;
    for byte in digest {
        bits = (bits << 8) | u32::from(byte);
        count += 8;
        while count >= 5 {
            count -= 5;
            encoded
                .push(b"abcdefghijklmnopqrstuvwxyz234567"[((bits >> count) & 31) as usize] as char);
        }
    }
    if count > 0 {
        encoded.push(
            b"abcdefghijklmnopqrstuvwxyz234567"[((bits << (5 - count)) & 31) as usize] as char,
        );
    }
    let result = format!("audi-{encoded}.ssh.{host}");
    if !hostname(&result) {
        return Err(invalid());
    }
    Ok(result)
}

pub fn invalid() -> io::Error {
    io::Error::other("SSH certificate unavailable")
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    use std::{
        fs,
        process::Command,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn openssh_issued_certificates_require_exact_identity_and_validity() {
        let root = tempfile::tempdir().unwrap();
        for name in ["ca", "leaf", "other"] {
            assert!(Command::new("ssh-keygen")
                .args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
                .arg(root.path().join(name))
                .status()
                .unwrap()
                .success());
        }
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-s"])
            .arg(root.path().join("ca"))
            .args([
                "-I",
                "test",
                "-h",
                "-n",
                "vm.example.test",
                "-V",
                "-5m:+3650d"
            ])
            .arg(root.path().join("leaf.pub"))
            .status()
            .unwrap()
            .success());
        let read = |name| {
            fs::read_to_string(root.path().join(name))
                .unwrap()
                .trim()
                .to_owned()
        };
        let (ca, key, other, line) = (
            read("ca.pub"),
            read("leaf.pub"),
            read("other.pub"),
            read("leaf-cert.pub"),
        );
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let cert = verify(&line, &ca, &key, "vm.example.test", now).unwrap();
        assert!(verify(&line, &other, &key, "vm.example.test", now).is_err());
        assert!(verify(&line, &ca, &other, "vm.example.test", now).is_err());
        assert!(verify(&line, &ca, &key, "other.example.test", now).is_err());
        assert!(verify(&line, &ca, &key, "vm.example.test", cert.valid_after() - 1).is_err());
        assert!(verify(&line, &ca, &key, "vm.example.test", cert.valid_before()).is_err());
    }
    #[hegel::test(test_cases = 100)]
    fn arbitrary_names_cannot_add_trust_patterns(tc: TestCase) {
        let name = tc.draw(gs::vecs(gs::integers::<u8>()));
        if let Ok(name) = std::str::from_utf8(&name) {
            if hostname(name) {
                assert!(name.len() <= 253);
                assert!(!name.contains(['*', '?', ',', '\n', '\r', ' ', '@']));
            }
        }
    }
}
