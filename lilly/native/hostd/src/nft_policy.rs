//! Host-namespace nftables rule files are confined to Lilly's own tables
//! (ADR-0176 decision 4).
//!
//! A rule file Lilly writes for the host namespace may only add, delete and
//! define tables named `lilly_<12 hex>_filter` or `lilly_<12 hex>_nat`. hostd
//! reads the file beneath its roots, checks it, and gives `nft` its own copy
//! of the checked bytes, so the file cannot change between check and load.

use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Largest rule file accepted.
const MAX_BYTES: u64 = 1 << 20;

fn hex(value: &str) -> bool {
    value.len() == 12
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `lilly_<12 hex>_filter` or `lilly_<12 hex>_nat`.
fn lilly_table(name: &str) -> bool {
    name.strip_prefix("lilly_").is_some_and(|rest| {
        rest.strip_suffix("_filter")
            .or_else(|| rest.strip_suffix("_nat"))
            .is_some_and(hex)
    })
}

/// @cc [owner:ghuntley,label:security] host-nft-own-tables-only
/// `host_rules` MUST accept a host-namespace rule file only when every top-level
/// statement is `add table FAMILY NAME`, `delete table FAMILY NAME` or a
/// `table FAMILY NAME { ... }` block (braces balanced, content not
/// interpreted), with FAMILY `inet` or `ip` and NAME one of Lilly's tables,
/// and the text contains no `include` or `ruleset`. Comments and blank lines
/// are ignored. Anything else is refused.
#[expect(
    clippy::match_same_arms,
    reason = "one arm per accepted table declaration form keeps the grammar reviewable"
)]
pub fn host_rules(text: &str) -> bool {
    if text.contains("include") || text.contains("ruleset") {
        return false;
    }
    let mut depth = 0_usize;
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if depth == 0 {
            let words: Vec<&str> = line.split_whitespace().collect();
            let table = match words.as_slice() {
                ["add" | "delete", "table", family, name] => Some((*family, *name)),
                ["table", family, name, "{", ..] => Some((*family, *name)),
                _ => None,
            };
            let Some((family, name)) = table else {
                return false;
            };
            if !matches!(family, "inet" | "ip") || !lilly_table(name.trim_end_matches(';')) {
                return false;
            }
        }
        for character in line.chars() {
            match character {
                '{' => depth += 1,
                '}' => match depth.checked_sub(1) {
                    Some(next) => depth = next,
                    None => return false,
                },
                _ => {}
            }
        }
    }
    depth == 0
}

/// Read a rule file beneath `roots` (never following symlinks), check it and
/// write the checked bytes to a private copy in `private`, returning the copy.
pub fn checked_copy(
    path: &[u8],
    roots: &[PathBuf],
    private: &Path,
    request: u64,
) -> Option<PathBuf> {
    if !crate::protocol::valid_directory(path) {
        return None;
    }
    let path = Path::new(std::ffi::OsStr::from_bytes(path));
    let root = roots
        .iter()
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.as_os_str().len())?;
    let base = rustix::fs::open(
        root,
        rustix::fs::OFlags::PATH | rustix::fs::OFlags::DIRECTORY | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .ok()?;
    let file = rustix::fs::openat2(
        &base,
        path.strip_prefix(root).ok()?,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
        rustix::fs::ResolveFlags::BENEATH
            | rustix::fs::ResolveFlags::NO_SYMLINKS
            | rustix::fs::ResolveFlags::NO_MAGICLINKS,
    )
    .ok()?;
    let mut text = String::new();
    std::fs::File::from(file)
        .take(MAX_BYTES + 1)
        .read_to_string(&mut text)
        .ok()?;
    if text.len() as u64 > MAX_BYTES || !host_rules(&text) {
        return None;
    }
    let copy = private.join(format!("nft-{request}.nft"));
    std::fs::write(&copy, text).ok()?;
    Some(copy)
}
