//! Boot-bound public CA delivery (vsock port 1030), shared by the Windows trust
//! daemon (ADR-0171; the Linux `overalls-trustd` keeps its own copy of the
//! validation until it is folded in).
//!
//! Lilly frames one JSON request (4-byte big-endian length, at most 1 MiB)
//! naming this boot and carrying up to 32 PEM roots with their sorted
//! fingerprint digest; the guest installs exactly that set and answers with an
//! `installed` receipt bound to the same boot, nonce and digest. A failed or
//! partial installation never acknowledges.

use rustls_pki_types::pem::PemObject;
use rustls_pki_types::CertificateDer;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};

/// Vsock port Lilly dials with the trust request.
pub const PORT: u32 = 1030;
pub const MAX_FRAME: usize = 1_048_576;
pub const MAX_ROOTS: usize = 32;
pub const MAX_CERT: usize = 16_384;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u8,
    pub placement_id: String,
    pub execution_epoch: u64,
    pub boot_challenge: String,
    pub nonce: String,
    pub bundle_digest: String,
    pub roots: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Receipt<'a> {
    pub version: u8,
    pub state: &'static str,
    pub placement_id: &'a str,
    pub execution_epoch: u64,
    pub boot_challenge: &'a str,
    pub boot_id: &'a str,
    pub nonce: &'a str,
    pub bundle_digest: &'a str,
}

/// This boot's identity, as the readiness module knows it.
pub use crate::guest::readiness::Boot;

fn valid_hex(value: &str, size: usize) -> bool {
    value.len() == size && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// One PEM certificate body as DER.
pub fn der(pem: &str) -> io::Result<Vec<u8>> {
    CertificateDer::from_pem_slice(pem.as_bytes())
        .map(|certificate| certificate.to_vec())
        .map_err(|_| io::Error::other("invalid trust certificate"))
}

/// @cc [owner:ghuntley,label:security;recovery] guest-trust-exact-boot-shared
/// validate MUST accept only a version-1 request naming this exact boot, with a
/// 64-hex nonce and bundle digest, one to 32 unique PEM certificates of at most
/// 16 KiB each that parse as certificates and contain no private key, whose
/// sorted SHA-256 fingerprint concatenation hashes to the digest. It returns the
/// DER of every root in request order.
pub fn validate(request: &Request, boot: &Boot) -> io::Result<Vec<Vec<u8>>> {
    if request.version != 1
        || request.placement_id != boot.placement_id
        || request.execution_epoch != boot.execution_epoch
        || request.boot_challenge != boot.boot_challenge
        || !valid_hex(&request.nonce, 64)
        || !valid_hex(&request.bundle_digest, 64)
        || request.roots.is_empty()
        || request.roots.len() > MAX_ROOTS
    {
        return Err(io::Error::other("invalid trust request"));
    }
    let mut fingerprints = Vec::with_capacity(request.roots.len());
    let mut ders = Vec::with_capacity(request.roots.len());
    for pem in &request.roots {
        if pem.len() > MAX_CERT
            || !pem.starts_with("-----BEGIN CERTIFICATE-----\n")
            || !pem.trim_end().ends_with("-----END CERTIFICATE-----")
            || pem.matches("-----BEGIN CERTIFICATE-----").count() != 1
            || pem.matches("-----END CERTIFICATE-----").count() != 1
            || pem.contains("PRIVATE KEY")
        {
            return Err(io::Error::other("invalid trust certificate"));
        }
        ders.push(der(pem)?);
        fingerprints.push(Sha256::digest(pem.as_bytes()).to_vec());
    }
    fingerprints.sort();
    if fingerprints.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(io::Error::other("duplicate trust certificate"));
    }
    let digest = hex::encode(Sha256::digest(fingerprints.concat()));
    if digest != request.bundle_digest {
        return Err(io::Error::other("trust digest mismatch"));
    }
    Ok(ders)
}

/// @cc [owner:ghuntley,label:security;recovery] guest-trust-canonical-bundle
/// Effective trust MUST contain the vendor base followed by exactly the current
/// roots in canonical order. Permuting a validated root set with the same digest
/// MUST produce identical bytes; each root MUST end with a newline.
pub fn bundle(base: &[u8], roots: &[String]) -> io::Result<Vec<u8>> {
    if base.len() > MAX_FRAME {
        return Err(io::Error::other("system trust unavailable"));
    }
    let mut bytes = base.to_vec();
    if !bytes.ends_with(b"\n") {
        bytes.push(b'\n');
    }
    let mut ordered: Vec<&String> = roots.iter().collect();
    ordered.sort_unstable();
    for root in ordered {
        bytes.extend_from_slice(root.as_bytes());
        if !root.ends_with('\n') {
            bytes.push(b'\n');
        }
    }
    Ok(bytes)
}

/// Read one length-prefixed request frame.
pub fn read_frame(stream: &mut impl Read) -> io::Result<Request> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME {
        return Err(io::Error::other("invalid frame"));
    }
    let mut body = vec![0; length];
    stream.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(|_| io::Error::other("invalid frame"))
}

/// Write one length-prefixed receipt frame.
pub fn write_frame(stream: &mut impl Write, receipt: &Receipt<'_>) -> io::Result<()> {
    let body = serde_json::to_vec(receipt)?;
    let length = u32::try_from(body.len()).map_err(|_| io::Error::other("invalid frame"))?;
    stream.write_all(&length.to_be_bytes())?;
    stream.write_all(&body)
}

/// The `installed` receipt for a validated request.
pub fn receipt<'a>(request: &'a Request, boot: &'a Boot) -> Receipt<'a> {
    Receipt {
        version: 1,
        state: "installed",
        placement_id: &boot.placement_id,
        execution_epoch: boot.execution_epoch,
        boot_challenge: &boot.boot_challenge,
        boot_id: &boot.boot_id,
        nonce: &request.nonce,
        bundle_digest: &request.bundle_digest,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A self-signed test certificate (RSA 2048, "overalls trust fixture").
    const ROOT: &str = "-----BEGIN CERTIFICATE-----\nMIIBhTCCASsCFHTNYy7Zrt1xYj0q6ir7R5mIl0U7MAoGCCqGSM49BAMCMBwxGjAY\nBgNVBAMMEWtpdHRlbnMtZml4dHVyZS1jYTAeFw0yNDAxMDEwMDAwMDBaFw0zNDAx\nMDEwMDAwMDBaMBwxGjAYBgNVBAMMEWtpdHRlbnMtZml4dHVyZS1jYTBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABEvI4qYwOCtPYwgM9hEnl0mVsE8ia1EO2qa5bYvX\nBP6nZKtq5Q9HcGm4wzA0Yu9jCmHfC6BAfxvZ6T1C1Vrv2WqjUzBRMB0GA1UdDgQW\nBBS6GpFyMGMrXoE1Y0p0bUIuSwZ4qTAfBgNVHSMEGDAWgBS6GpFyMGMrXoE1Y0p0\nbUIuSwZ4qTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDgnzqS\nL3S1KQrkqiVhgKWxnSLpV5oAAJ5a7n6tKqGT3gIgTdoi7kXfQ3g0ZJm2Pq1W3Zm3\nmYQZd4vYwUe2vO5JGRQ=\n-----END CERTIFICATE-----\n";

    fn boot() -> Boot {
        Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap()
    }

    fn request(roots: Vec<String>) -> Request {
        let mut fingerprints: Vec<Vec<u8>> = roots
            .iter()
            .map(|pem| Sha256::digest(pem.as_bytes()).to_vec())
            .collect();
        fingerprints.sort();
        Request {
            version: 1,
            placement_id: "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            execution_epoch: 7,
            boot_challenge: "b".repeat(64),
            nonce: "c".repeat(64),
            bundle_digest: hex::encode(Sha256::digest(fingerprints.concat())),
            roots,
        }
    }

    #[test]
    fn frames_round_trip_and_bound() {
        let request = request(vec![ROOT.to_string()]);
        let body = serde_json::to_vec(&serde_json::json!({
            "version": 1, "placement_id": request.placement_id, "execution_epoch": 7,
            "boot_challenge": request.boot_challenge, "nonce": request.nonce,
            "bundle_digest": request.bundle_digest, "roots": request.roots
        }))
        .unwrap();
        let mut framed = u32::try_from(body.len()).unwrap().to_be_bytes().to_vec();
        framed.extend_from_slice(&body);
        let parsed = read_frame(&mut framed.as_slice()).unwrap();
        assert_eq!(parsed.roots.len(), 1);
        assert!(read_frame(&mut [0u8, 0, 0, 0].as_slice()).is_err());
        assert!(read_frame(
            &mut (u32::try_from(MAX_FRAME).unwrap() + 1)
                .to_be_bytes()
                .as_slice()
        )
        .is_err());
        let boot = boot();
        let mut out = Vec::new();
        write_frame(&mut out, &receipt(&parsed, &boot)).unwrap();
        let length = u32::from_be_bytes(out[..4].try_into().unwrap()) as usize;
        let value: serde_json::Value = serde_json::from_slice(&out[4..4 + length]).unwrap();
        assert_eq!(value["state"], "installed");
        assert_eq!(value["boot_id"], "0f0e0d0c-0b0a-4908-8706-050403020100");
        assert_eq!(value["nonce"], "c".repeat(64));
    }

    #[test]
    fn validation_binds_boot_digest_and_certificate_shape() {
        let boot = boot();
        let good = request(vec![ROOT.to_string()]);
        let ders = validate(&good, &boot).unwrap();
        assert_eq!(ders.len(), 1);
        assert_eq!(ders[0][0], 0x30);
        let mut other_boot = boot.clone();
        other_boot.execution_epoch = 8;
        assert!(validate(&good, &other_boot).is_err());
        let mut wrong_digest = request(vec![ROOT.to_string()]);
        wrong_digest.bundle_digest = "0".repeat(64);
        assert!(validate(&wrong_digest, &boot).is_err());
        assert!(validate(&request(vec![ROOT.to_string(), ROOT.to_string()]), &boot).is_err());
        assert!(validate(&request(vec![]), &boot).is_err());
        assert!(validate(
            &request(vec![
                ROOT.replace("CERTIFICATE-----\nMIIB", "CERTIFICATE-----\n!!IB")
            ]),
            &boot
        )
        .is_err());
        assert!(validate(
            &request(vec![format!("{ROOT}-----BEGIN PRIVATE KEY-----\n")]),
            &boot
        )
        .is_err());
        let bundle = bundle(
            b"-----BEGIN CERTIFICATE-----\nbase\n-----END CERTIFICATE-----",
            &good.roots,
        )
        .unwrap();
        assert!(bundle.starts_with(
            b"-----BEGIN CERTIFICATE-----\nbase\n-----END CERTIFICATE-----\n-----BEGIN"
        ));
        assert!(bundle.ends_with(b"-----END CERTIFICATE-----\n"));
    }

    #[cfg(unix)]
    #[test]
    fn native_filesystem_reinstall_uses_vendor_base_and_replaces_previous_roots() {
        use crate::native_guest::install_trust;
        use std::fs;

        const REPLACEMENT: &str = "-----BEGIN CERTIFICATE-----\nMIIBrTCCAVOgAwIBAgIUerYIAlEw75EY8TgN78vx2f5NUnMwCgYIKoZIzj0EAwIw\nLDEqMCgGA1UEAwwhb3ZlcmFsbHMtbmF0aXZlLXRydXN0LXJlcGxhY2VtZW50MB4X\nDTI2MTAxNzE1NTkzMFoXDTM2MTAxNDE1NTkzMFowLDEqMCgGA1UEAwwhb3ZlcmFs\nbHMtbmF0aXZlLXRydXN0LXJlcGxhY2VtZW50MFkwEwYHKoZIzj0CAQYIKoZIzj0D\nAQcDQgAEGoAEe+5E8YuFshovO+IiKcSJtr1C5ntY5vaAxwHK9nnO4QgfD59RGICK\n+U2kxcFhCmijYNkfx1Z0TNlq0biYDqNTMFEwHQYDVR0OBBYEFMirqB/DiwBB/mAh\njIzInjicVsoFMB8GA1UdIwQYMBaAFMirqB/DiwBB/mAhjIzInjicVsoFMA8GA1Ud\nEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhALq3jIwd/NcLOLnpHi+C7BnY\nZoEMEa0j/CxAp1/7TlCIAiAjKLIR46Ik+AnXT6gqyq1cdZbT4bLP5wEJXNv89bhW\nlA==\n-----END CERTIFICATE-----\n";
        let root = tempfile::tempdir().unwrap();
        let base = root.path().join("vendor.pem");
        let destination = root.path().join("ssl/cert.pem");
        let state = root.path().join("state");
        let vendor = b"pinned distribution trust\n";
        fs::write(&base, vendor).unwrap();
        let first = request(vec![ROOT.to_string(), REPLACEMENT.to_string()]);
        install_trust(&base, &destination, &state, &first, &boot()).unwrap();
        let expected = bundle(vendor, &first.roots).unwrap();
        assert_eq!(fs::read(&destination).unwrap(), expected);
        assert!(fs::symlink_metadata(&destination)
            .unwrap()
            .file_type()
            .is_symlink());

        let mut next_boot = boot();
        next_boot.execution_epoch += 1;
        next_boot.boot_challenge = "d".repeat(64);
        next_boot.boot_id = "11111111-2222-4333-8444-555555555555".into();
        let mut repeated = request(vec![REPLACEMENT.to_string(), ROOT.to_string()]);
        assert_eq!(first.bundle_digest, repeated.bundle_digest);
        repeated.execution_epoch = next_boot.execution_epoch;
        repeated.boot_challenge = next_boot.boot_challenge.clone();
        install_trust(&base, &destination, &state, &repeated, &next_boot).unwrap();
        assert_eq!(fs::read(&destination).unwrap(), expected);
        assert_eq!(fs::read_dir(&state).unwrap().count(), 1);
        assert_eq!(fs::read(&base).unwrap(), vendor);

        let mut replacement = request(vec![REPLACEMENT.to_string()]);
        replacement.execution_epoch = next_boot.execution_epoch;
        replacement.boot_challenge = next_boot.boot_challenge.clone();
        install_trust(&base, &destination, &state, &replacement, &next_boot).unwrap();
        assert_eq!(
            fs::read(&destination).unwrap(),
            bundle(vendor, &replacement.roots).unwrap()
        );
        assert!(!fs::read_to_string(&destination).unwrap().contains(ROOT));
        install_trust(&base, &destination, &state, &repeated, &next_boot).unwrap();
        assert_eq!(fs::read(&destination).unwrap(), expected);

        assert!(install_trust(&base, &destination, &state, &first, &next_boot).is_err());
        fs::write(
            state.join(format!("bundle-{}.pem", repeated.bundle_digest)),
            b"corrupted",
        )
        .unwrap();
        let prior_link = fs::read_link(&destination).unwrap();
        assert!(install_trust(&base, &destination, &state, &repeated, &next_boot).is_err());
        assert_eq!(fs::read_link(&destination).unwrap(), prior_link);
        fs::remove_file(&base).unwrap();
        assert!(install_trust(&base, &destination, &state, &replacement, &next_boot).is_err());
        assert_eq!(fs::read_link(&destination).unwrap(), prior_link);
        assert!(!state.join(".overalls-ca.next").exists());
    }
}
