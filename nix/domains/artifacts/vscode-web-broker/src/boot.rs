//! Bounded preface framing, physical-boot parsing and admission binding.

use crate::validate::{dns_label, dns_name, hex, label_matches, username, uuid};
use crate::{Binding, Boot, Descriptor, MAX_PREFACE, PORT, Preface, Refusal};
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::net::Ipv4Addr;
use url::Url;

/// @cc [owner:ghuntley,label:security] editor-preface-bounded-closed-frame
/// read_preface MUST reject empty, oversized, truncated, malformed, duplicate
/// or additional fields before returning account or execution data.
pub fn read_preface(reader: &mut impl Read) -> Result<Preface, Refusal> {
    let mut length = [0_u8; 4];
    reader.read_exact(&mut length).map_err(|_| Refusal::Frame)?;
    let length = u32::from_be_bytes(length) as usize;
    if !(1..=MAX_PREFACE).contains(&length) {
        return Err(Refusal::Frame);
    }
    let mut bytes = vec![0_u8; length];
    reader.read_exact(&mut bytes).map_err(|_| Refusal::Frame)?;
    serde_json::from_slice(&bytes).map_err(|_| Refusal::Frame)
}

pub fn ready(writer: &mut impl Write) -> io::Result<()> {
    let bytes = br#"{"version":1,"ready":true}"#;
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(bytes)?;
    writer.flush()
}

/// @cc [owner:ghuntley,label:security] editor-guest-physical-boot
/// parse_boot MUST require exactly one current placement, positive execution
/// epoch and nonreserved profile IPv4 address. A logical generation update MUST
/// NOT change physical-boot acceptance.
pub fn parse_boot(cmdline: &str) -> Result<Boot, Refusal> {
    if cmdline.len() > 4096 {
        return Err(Refusal::Boot);
    }
    let mut values = BTreeMap::new();
    for field in cmdline.split_whitespace() {
        if let Some((key, value)) = field.split_once('=')
            && ["lilly.placement", "lilly.execution_epoch", "lilly.ipv4"].contains(&key)
            && values.insert(key, value).is_some()
        {
            return Err(Refusal::Boot);
        }
    }
    let placement_id = values.get("lilly.placement").ok_or(Refusal::Boot)?;
    let epoch = values.get("lilly.execution_epoch").ok_or(Refusal::Boot)?;
    let execution_epoch = epoch.parse::<u64>().map_err(|_| Refusal::Boot)?;
    let address = values
        .get("lilly.ipv4")
        .ok_or(Refusal::Boot)?
        .parse::<Ipv4Addr>()
        .map_err(|_| Refusal::Boot)?;
    let [first, profile, high, low] = address.octets();
    let slot = u16::from(high) * 256 + u16::from(low);
    if !uuid(placement_id)
        || execution_epoch == 0
        || execution_epoch.to_string() != *epoch
        || first != 10
        || ![10, 20, 30, 40].contains(&profile)
        || !(2..=65534).contains(&slot)
    {
        return Err(Refusal::Boot);
    }
    Ok(Boot {
        placement_id: (*placement_id).to_owned(),
        execution_epoch,
        address,
        gateway: Ipv4Addr::new(10, profile, 0, 1),
    })
}

/// @cc [owner:ghuntley,label:security] editor-origin-derived-webview
/// The origin MUST be the canonical HTTPS hostname bound by the exact label.
/// The webview template MUST use only that origin's DNS zone and immutable
/// release; no caller-provided template, path, credentials or redirects enter it.
pub fn webview_template(binding: &Binding) -> Result<String, Refusal> {
    let origin = Url::parse(&binding.editor_origin).map_err(|_| Refusal::Origin)?;
    let host = origin.host_str().ok_or(Refusal::Origin)?;
    let prefix = format!("{}.", binding.label);
    let zone = host.strip_prefix(&prefix).ok_or(Refusal::Origin)?;
    let port = origin
        .port()
        .map_or(String::new(), |port| format!(":{port}"));
    if origin.scheme() != "https"
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.path() != "/"
        || origin.query().is_some()
        || origin.fragment().is_some()
        || !dns_label(&binding.label)
        || !dns_name(zone)
        || binding.editor_origin != format!("https://{host}{port}")
        || !hex(&binding.editor_release, 64)
    {
        return Err(Refusal::Origin);
    }
    Ok(format!(
        "https://{{{{uuid}}}}.{zone}{port}/code-assets/{}/out/vs/workbench/contrib/webview/browser/pre/",
        binding.editor_release
    ))
}

/// @cc [owner:ghuntley,label:security] editor-exact-account-image-binding
/// Admission MUST bind all required UUIDs, the current placement/epoch, the
/// exact installed package tuple and a safe non-system account UID/name. No
/// missing field, another package, service or port may fall back to a worker.
pub fn validate(preface: &Preface, boot: &Boot, package: &Descriptor) -> Result<(), Refusal> {
    let binding = &preface.binding;
    if preface.version != 1
        || ![
            &binding.vm_id,
            &binding.host_id,
            &binding.placement_id,
            &binding.session_id,
            &binding.user_id,
            &binding.guest_account_id,
        ]
        .into_iter()
        .all(|value| uuid(value))
        || binding.service != "editor"
        || binding.port != PORT
        || !(1..=i64::MAX as u64).contains(&binding.generation)
        || !(1..=i64::MAX as u64).contains(&binding.execution_epoch)
        || !label_matches(binding)
        || !(200_000..=999_999).contains(&binding.uid)
        || !username(&binding.username)
    {
        return Err(Refusal::Binding);
    }
    if binding.placement_id != boot.placement_id || binding.execution_epoch != boot.execution_epoch
    {
        return Err(Refusal::Boot);
    }
    package.validate()?;
    if binding.editor_protocol != package.protocol
        || binding.editor_commit != package.commit
        || binding.editor_release != package.release
    {
        return Err(Refusal::Package);
    }
    webview_template(binding)?;
    Ok(())
}
