//! Lilly-derived outer identity binding carried in the guest request header.

use base64::Engine;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub host_id: String,
    pub vm_id: String,
    pub placement_id: String,
    pub execution_epoch: u64,
}

pub(crate) fn canonical_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(byte)
            }
        })
}

pub fn parse_binding(header: &str) -> Result<Binding, &'static str> {
    if header.len() > 512 || header.contains('=') {
        return Err("binding_size");
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(header)
        .map_err(|_| "binding_encoding")?;
    let binding: Binding = serde_json::from_slice(&bytes).map_err(|_| "binding_json")?;
    if !canonical_uuid(&binding.host_id)
        || !canonical_uuid(&binding.vm_id)
        || !canonical_uuid(&binding.placement_id)
        || binding.execution_epoch == 0
    {
        return Err("binding_identity");
    }
    Ok(binding)
}
