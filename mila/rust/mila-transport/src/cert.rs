use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use thiserror::Error;

const ALG: &[u8] = b"ssh-ed25519-cert-v01@openssh.com";
const MAX: usize = 16_384;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostCertificate {
    pub public_key: [u8; 32],
    pub ca: String,
    pub principals: Vec<String>,
    pub valid_after: u64,
    pub valid_before: u64,
    signed: Vec<u8>,
    signature: [u8; 64],
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub enum HostRefusal {
    #[error("malformed")]
    Malformed,
    #[error("wrong authority")]
    WrongAuthority,
    #[error("wrong principal")]
    WrongPrincipal,
    #[error("not yet valid")]
    NotYetValid,
    #[error("expired")]
    Expired,
    #[error("bad signature")]
    BadSignature,
}

pub(crate) struct Reader<'a> {
    pub(crate) b: &'a [u8],
    pub(crate) o: usize,
}
impl<'a> Reader<'a> {
    pub(crate) fn field(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        let e = self.o.checked_add(n)?;
        let v = self.b.get(self.o..e)?;
        self.o = e;
        Some(v)
    }
    fn u32(&mut self) -> Option<u32> {
        let x = self.b.get(self.o..self.o + 4)?;
        self.o += 4;
        Some(u32::from_be_bytes(x.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        let x = self.b.get(self.o..self.o + 8)?;
        self.o += 8;
        Some(u64::from_be_bytes(x.try_into().ok()?))
    }
    pub(crate) fn done(&self) -> bool {
        self.o == self.b.len()
    }
}
fn host(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 253
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-')
        && !s.starts_with('.')
        && !s.ends_with('.')
}
fn key_line(raw: &[u8]) -> Option<String> {
    if raw.len() != 32 {
        return None;
    }
    let mut b = Vec::new();
    b.extend((11u32).to_be_bytes());
    b.extend(b"ssh-ed25519");
    b.extend((32u32).to_be_bytes());
    b.extend(raw);
    Some(format!("ssh-ed25519 {}", STANDARD.encode(b)))
}
pub fn parse_host_certificate_blob(blob: &[u8]) -> Option<HostCertificate> {
    if blob.len() > MAX {
        return None;
    }
    let mut r = Reader { b: blob, o: 0 };
    if r.field() != Some(ALG) {
        return None;
    }
    let nonce = r.field()?;
    if !(16..=64).contains(&nonce.len()) {
        return None;
    }
    let k = r.field()?;
    let public_key: [u8; 32] = k.try_into().ok()?;
    let _serial = r.u64()?;
    if r.u32() != Some(2) {
        return None;
    }
    let id = r.field()?;
    if id.is_empty() || id.len() > 128 || std::str::from_utf8(id).is_err() {
        return None;
    }
    let names = r.field()?;
    let mut nr = Reader { b: names, o: 0 };
    let mut principals = Vec::new();
    while !nr.done() {
        let n = std::str::from_utf8(nr.field()?).ok()?.to_owned();
        if !host(&n) || principals.contains(&n) || principals.len() >= 8 {
            return None;
        }
        principals.push(n);
    }
    let after = r.u64()?;
    let before = r.u64()?;
    if after >= before {
        return None;
    }
    for _ in 0..3 {
        if !r.field()?.is_empty() {
            return None;
        }
    }
    let ca_blob = r.field()?;
    let mut ca_reader = Reader { b: ca_blob, o: 0 };
    if ca_reader.field()? != b"ssh-ed25519" {
        return None;
    }
    let ca = key_line(ca_reader.field()?)?;
    if !ca_reader.done() {
        return None;
    }
    let signed_len = r.o;
    let sf = r.field()?;
    if !r.done() {
        return None;
    }
    let mut sr = Reader { b: sf, o: 0 };
    if sr.field() != Some(b"ssh-ed25519") {
        return None;
    }
    let sig: [u8; 64] = sr.field()?.try_into().ok()?;
    if !sr.done() {
        return None;
    }
    Some(HostCertificate {
        public_key,
        ca,
        principals,
        valid_after: after,
        valid_before: before,
        signed: blob[..signed_len].to_vec(),
        signature: sig,
    })
}
pub fn parse_host_certificate_line(line: &str) -> Option<HostCertificate> {
    if line.len() > MAX {
        return None;
    }
    let mut p = line.split_whitespace();
    if p.next()? != "ssh-ed25519-cert-v01@openssh.com" {
        return None;
    }
    let raw = p.next()?;
    if p.next().is_some() {
        return None;
    }
    let b = STANDARD.decode(raw).ok()?;
    parse_host_certificate_blob(&b)
}
pub fn verify_host_certificate(
    cert: &HostCertificate,
    ca: &str,
    principal: &str,
    now: u64,
) -> Result<(), HostRefusal> {
    let raw = ca
        .strip_prefix("ssh-ed25519 ")
        .and_then(|x| STANDARD.decode(x).ok())
        .and_then(|b| {
            let mut r = Reader { b: &b, o: 0 };
            if r.field()? != b"ssh-ed25519" {
                return None;
            }
            let k = r.field()?;
            if !r.done() {
                return None;
            }
            Some(k.to_vec())
        })
        .ok_or(HostRefusal::Malformed)?;
    if cert.ca != ca {
        return Err(HostRefusal::WrongAuthority);
    }
    if !cert.principals.iter().any(|p| p == principal) {
        return Err(HostRefusal::WrongPrincipal);
    }
    if now < cert.valid_after {
        return Err(HostRefusal::NotYetValid);
    }
    if now >= cert.valid_before {
        return Err(HostRefusal::Expired);
    }
    let key = VerifyingKey::from_bytes(
        raw.as_slice()
            .try_into()
            .map_err(|_| HostRefusal::Malformed)?,
    )
    .map_err(|_| HostRefusal::Malformed)?;
    key.verify(&cert.signed, &Signature::from_bytes(&cert.signature))
        .map_err(|_| HostRefusal::BadSignature)
}
