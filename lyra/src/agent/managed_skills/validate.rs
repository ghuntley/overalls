//! Install-argument, identifier and path validation.

use super::{Failure, Install, Result};
use crate::workspace_source::{self, Revision, WorkspaceSource};
use std::path::{Path, PathBuf};

pub(super) fn validate(args: &Install) -> Result<WorkspaceSource> {
    if args.version != 1
        || !uuid(&args.operation_id)
        || !uuid(&args.thread_id)
        || !uuid(&args.installation_id)
        || (!args.subdirectory.is_empty() && !safe_relative(&args.subdirectory))
        || args.previous_path.is_some() != args.previous_digest.is_some()
        || args
            .previous_digest
            .as_ref()
            .is_some_and(|digest| !sha256(digest))
        || args
            .expected_digest
            .as_ref()
            .is_some_and(|digest| !sha256(digest))
    {
        return Err(Failure("invalid_arguments"));
    }
    let source = workspace_source::decode(&args.source).map_err(|_| Failure("invalid_source"))?;
    if matches!(source.revision(), Revision::Commit { value } if !full_commit(value)) {
        return Err(Failure("invalid_revision"));
    }
    if matches!(source.revision(), Revision::Change { .. }) {
        return Err(Failure("unsupported_revision"));
    }
    Ok(source)
}
pub(super) fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_digit() || (b'a'..=b'f').contains(&c)
            }
        })
}
pub(super) fn full_commit(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
pub(super) fn wire_path(path: &Path) -> Result<String> {
    Ok(path
        .to_str()
        .ok_or(Failure("unsafe_path"))?
        .replace('\\', "/"))
}
pub(super) fn sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
pub(super) fn safe_relative(value: &str) -> bool {
    !value.is_empty()
        && value.is_ascii()
        && value.len() <= 2048
        && value.split('/').all(|part| {
            !part.is_empty()
                && part.len() <= 128
                && ![".", ".."].contains(&part)
                && !part.eq_ignore_ascii_case(".git")
                && !part.ends_with(['.', ' '])
                && !part
                    .chars()
                    .any(|c| c.is_control() || "\\:*?\"<>|".contains(c))
                && !windows_reserved(part)
        })
}
fn windows_reserved(part: &str) -> bool {
    let name = part.split('.').next().unwrap_or("").to_ascii_uppercase();
    matches!(
        name.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || (name.len() == 4
        && (name.starts_with("COM") || name.starts_with("LPT"))
        && matches!(name.as_bytes()[3], b'1'..=b'9'))
}
pub(super) fn installation_path(root: &Path, thread: &str, installation: &str) -> Result<PathBuf> {
    if !uuid(thread) || !uuid(installation) {
        return Err(Failure("invalid_arguments"));
    }
    Ok(root.join(thread).join(installation))
}
pub(super) fn checkpoint(heartbeat: &mut impl FnMut() -> bool) -> Result<()> {
    if heartbeat() {
        Ok(())
    } else {
        Err(Failure("lease_lost"))
    }
}
