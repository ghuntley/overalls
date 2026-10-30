use crate::cert::Reader;
use base64::{engine::general_purpose::STANDARD, Engine};
use thiserror::Error;

/// A deployment's published SSH trust policy.
#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TrustDocument {
    pub version: u8,
    pub ca: String,
    pub management_host: String,
    pub zone: String,
    pub retirement: u64,
}
impl TrustDocument {
    pub fn same_authority(&self, other: &Self) -> bool {
        self.ca == other.ca
            && self.management_host == other.management_host
            && self.zone == other.zone
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub enum TrustRefusal {
    #[error("malformed")]
    Malformed,
    #[error("wrong host")]
    WrongHost,
    #[error("retired")]
    Retired,
    #[error("conflicts")]
    Conflicts,
}
const MAX_TRUST_BYTES: usize = 8192;
fn valid_hostname(s: &str, max: usize) -> bool {
    if s.is_empty() || s.len() > max {
        return false;
    }
    s.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-')
    })
}
fn canonical_ca(s: &str) -> bool {
    let Some(raw) = s.strip_prefix("ssh-ed25519 ") else {
        return false;
    };
    let Ok(b) = STANDARD.decode(raw) else {
        return false;
    };
    let mut r = Reader { b: &b, o: 0 };
    r.field() == Some(b"ssh-ed25519") && r.field().is_some_and(|k| k.len() == 32) && r.done()
}
pub fn decode_trust_document(
    bytes: &[u8],
    origin_host: &str,
    now: u64,
) -> Result<TrustDocument, TrustRefusal> {
    if bytes.len() > MAX_TRUST_BYTES {
        return Err(TrustRefusal::Malformed);
    }
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| TrustRefusal::Malformed)?;
    let obj = value.as_object().ok_or(TrustRefusal::Malformed)?;
    const KEYS: [&str; 5] = ["version", "ca", "management_host", "zone", "retirement"];
    if obj.len() != KEYS.len() || KEYS.iter().any(|k| !obj.contains_key(*k)) {
        return Err(TrustRefusal::Malformed);
    }
    let version = obj["version"]
        .as_u64()
        .filter(|v| *v == 1)
        .ok_or(TrustRefusal::Malformed)? as u8;
    let ca = obj["ca"]
        .as_str()
        .filter(|v| canonical_ca(v))
        .ok_or(TrustRefusal::Malformed)?
        .to_owned();
    let host = obj["management_host"]
        .as_str()
        .filter(|v| valid_hostname(v, 180))
        .ok_or(TrustRefusal::Malformed)?
        .to_owned();
    let zone = obj["zone"]
        .as_str()
        .filter(|v| valid_hostname(v, 189))
        .ok_or(TrustRefusal::Malformed)?
        .to_owned();
    let retirement = obj["retirement"].as_u64().ok_or(TrustRefusal::Malformed)?;
    if host != origin_host {
        return Err(TrustRefusal::WrongHost);
    }
    if retirement <= now {
        return Err(TrustRefusal::Retired);
    }
    Ok(TrustDocument {
        version,
        ca,
        management_host: host,
        zone,
        retirement,
    })
}
pub fn reconcile_trust(
    pinned: Option<&TrustDocument>,
    fetched: TrustDocument,
) -> Result<TrustDocument, TrustRefusal> {
    let Some(old) = pinned else {
        return Ok(fetched);
    };
    if !old.same_authority(&fetched) {
        return Err(TrustRefusal::Conflicts);
    }
    Ok(if fetched.retirement >= old.retirement {
        fetched
    } else {
        old.clone()
    })
}
