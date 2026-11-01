//! Revision materialization from a fetched tree, and content digests.

use super::git::{git_program, Git};
use super::storage::{
    check_ancestors, create_file, linked, move_path, regular_file, secure_directory,
    sync_directory, sync_tree_directories,
};
use super::validate::{checkpoint, full_commit, safe_relative, wire_path};
use super::{
    Failure, Install, Installed, Result, MAX_CONTENT, MAX_FILE, MAX_FILES, MAX_HEADER, MAX_SKILL,
    TIMEOUT,
};
use crate::workspace_source::{Revision, WorkspaceSource};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{Read, Write};
use std::path::Path;
use std::time::Instant;

pub(super) fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    regular_file(path, limit)?
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure("storage_failed"))?;
    if bytes.len() as u64 > limit {
        return Err(Failure("content_too_large"));
    }
    Ok(bytes)
}
pub(super) fn skill_header(bytes: &[u8]) -> Result<String> {
    let text = std::str::from_utf8(bytes).map_err(|_| Failure("invalid_skill"))?;
    let mut lines = text.split_inclusive('\n');
    if lines
        .next()
        .is_none_or(|line| line.trim_end_matches(['\r', '\n']) != "---")
    {
        return Err(Failure("invalid_skill"));
    }
    let mut end = text
        .find('\n')
        .map(|position| position + 1)
        .ok_or(Failure("invalid_skill"))?;
    for line in lines {
        end += line.len();
        if end > MAX_HEADER {
            return Err(Failure("invalid_skill"));
        }
        if line.trim_end_matches(['\r', '\n']) == "---" {
            let header = text.get(..end).ok_or(Failure("invalid_skill"))?;
            if serde_json::to_vec(header)
                .map_err(|_| Failure("invalid_skill"))?
                .len()
                > 8 * 1024
            {
                return Err(Failure("invalid_skill"));
            }
            return Ok(header.to_owned());
        }
    }
    Err(Failure("invalid_skill"))
}

#[expect(
    clippy::too_many_lines,
    reason = "one linear, audited install sequence; splitting would scatter its rollback"
)]
pub(super) fn materialize(
    installation: &Path,
    args: &Install,
    source: &WorkspaceSource,
    heartbeat: &mut impl FnMut() -> bool,
) -> Result<Installed> {
    let scratch = tempfile::Builder::new()
        .prefix("fetch-")
        .tempdir_in(installation)
        .map_err(|_| Failure("storage_failed"))?;
    let repo = scratch.path().join("repository");
    let home = scratch.path().join("home");
    secure_directory(&home)?;
    let mut git = Git {
        program: git_program()?,
        root: scratch.path(),
        home: &home,
        started: Instant::now(),
        heartbeat,
    };
    let advertised = git.run(&["ls-remote", "--", &source.clone_url()], 1024 * 1024)?;
    let (commit, format) = resolve_commit(source, &advertised)?;
    let repo_arg = repo.to_str().ok_or(Failure("unsafe_path"))?;
    git.run(
        &[
            "init",
            "--bare",
            "--template=",
            &format!("--object-format={format}"),
            repo_arg,
        ],
        4096,
    )?;
    git.run(
        &[
            "--git-dir",
            repo_arg,
            "fetch",
            "--depth=1",
            "--no-tags",
            "--no-write-fetch-head",
            "--no-recurse-submodules",
            "--",
            &source.clone_url(),
            &commit,
        ],
        4096,
    )?;
    let resolved = git.run(
        &[
            "--git-dir",
            repo_arg,
            "rev-parse",
            "--verify",
            &format!("{commit}^{{commit}}"),
        ],
        128,
    )?;
    let commit = std::str::from_utf8(&resolved)
        .map_err(|_| Failure("invalid_revision"))?
        .trim()
        .to_owned();
    if !full_commit(&commit) {
        return Err(Failure("invalid_revision"));
    }
    let treeish = if args.subdirectory.is_empty() {
        commit.clone()
    } else {
        format!("{commit}:{}", args.subdirectory)
    };
    let content = scratch.path().join("content");
    extract_tree(&mut git, repo_arg, &treeish, &content)?;
    let bytes =
        read_bounded(&content.join("SKILL.md"), MAX_SKILL).map_err(|_| Failure("missing_skill"))?;
    skill_header(&bytes)?;
    checkpoint(git.heartbeat)?;
    let digest = directory_digest(&content)?;
    if args
        .expected_digest
        .as_ref()
        .is_some_and(|expected| *expected != digest)
    {
        return Err(Failure("digest_mismatch"));
    }
    let revisions = installation.join("revisions");
    secure_directory(&revisions)?;
    let final_path = revisions.join(&digest);
    checkpoint(git.heartbeat)?;
    if git.started.elapsed() >= TIMEOUT {
        return Err(Failure("operation_timeout"));
    }
    if final_path
        .try_exists()
        .map_err(|_| Failure("storage_failed"))?
    {
        if directory_digest(&final_path)? != digest {
            return Err(Failure("local_changes"));
        }
    } else {
        sync_tree_directories(&content)?;
        checkpoint(git.heartbeat)?;
        move_path(&content, &final_path, false)?;
        sync_directory(&revisions)?;
    }
    Ok(Installed {
        full_commit: commit,
        content_digest: digest,
        path: wire_path(&final_path)?,
        skill_digest: hex::encode(Sha256::digest(&bytes)),
        skill_bytes: bytes.len() as u64,
    })
}

pub(super) fn extract_tree<H: FnMut() -> bool>(
    git: &mut Git<'_, H>,
    repo_arg: &str,
    treeish: &str,
    content: &Path,
) -> Result<()> {
    let tree = git.run(
        &[
            "--git-dir",
            repo_arg,
            "ls-tree",
            "-rz",
            "--full-tree",
            treeish,
        ],
        1024 * 1024,
    )?;
    let entries = parse_tree(&tree)?;
    secure_directory(content)?;
    let mut size = 0_u64;
    for (path, object) in &entries {
        let length = git.run(&["--git-dir", repo_arg, "cat-file", "-s", object], 128)?;
        let length: u64 = std::str::from_utf8(&length)
            .ok()
            .and_then(|value| value.trim().parse().ok())
            .ok_or(Failure("invalid_tree"))?;
        size = size
            .checked_add(length)
            .ok_or(Failure("content_too_large"))?;
        if length > MAX_FILE || size > MAX_CONTENT {
            return Err(Failure("content_too_large"));
        }
        let bytes = git.run(
            &["--git-dir", repo_arg, "cat-file", "blob", object],
            usize::try_from(length).map_err(|_| Failure("content_too_large"))?,
        )?;
        if bytes.len() as u64 != length {
            return Err(Failure("invalid_tree"));
        }
        let target = content.join(path);
        secure_directory(target.parent().ok_or(Failure("unsafe_path"))?)?;
        let mut file = create_file(&target)?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Failure("storage_failed"))?;
    }
    Ok(())
}

pub(super) fn resolve_commit(
    source: &WorkspaceSource,
    advertised: &[u8],
) -> Result<(String, &'static str)> {
    let text = std::str::from_utf8(advertised).map_err(|_| Failure("invalid_revision"))?;
    let wanted = match source.revision() {
        Revision::Default => "HEAD".to_owned(),
        Revision::Commit { value } => {
            return Ok((
                value.clone(),
                if value.len() == 64 { "sha256" } else { "sha1" },
            ))
        }
        Revision::Ref { value } | Revision::Tag { value } => {
            crate::workspace_checkout::select_ref(
                value,
                matches!(source.revision(), Revision::Tag { .. }),
                advertised,
            )
            .map_err(|_| Failure("invalid_revision"))?
            .0
        }
        Revision::Change { .. } => return Err(Failure("unsupported_revision")),
    };
    let peeled = format!("{wanted}^{{}}");
    let lines: Vec<(&str, &str)> = text
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .collect();
    let (object, _) = lines
        .iter()
        .find(|(_, reference)| *reference == peeled)
        .or_else(|| lines.iter().find(|(_, reference)| *reference == wanted))
        .ok_or(Failure("invalid_revision"))?;
    if !full_commit(object) {
        return Err(Failure("invalid_revision"));
    }
    Ok((
        (*object).to_owned(),
        if object.len() == 64 { "sha256" } else { "sha1" },
    ))
}
pub(super) fn parse_tree(bytes: &[u8]) -> Result<BTreeMap<String, String>> {
    let mut entries = BTreeMap::new();
    let mut spelling: BTreeMap<String, String> = BTreeMap::new();
    for item in bytes
        .split(|byte| *byte == 0)
        .filter(|item| !item.is_empty())
    {
        let text = std::str::from_utf8(item).map_err(|_| Failure("invalid_tree"))?;
        let (metadata, path) = text.split_once('\t').ok_or(Failure("invalid_tree"))?;
        let fields: Vec<&str> = metadata.split(' ').collect();
        let [mode, "blob", object] = fields.as_slice() else {
            return Err(Failure("invalid_tree"));
        };
        if !matches!(*mode, "100644" | "100755") || !full_commit(object) || !safe_relative(path) {
            return Err(Failure("invalid_tree"));
        }
        let mut prefix = String::new();
        for component in path.split('/') {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(component);
            let key = prefix.to_lowercase();
            if spelling.get(&key).is_some_and(|old| old != &prefix) {
                return Err(Failure("invalid_tree"));
            }
            spelling.insert(key, prefix.clone());
        }
        if entries
            .insert(path.to_owned(), (*object).to_owned())
            .is_some()
            || entries.len() > MAX_FILES
        {
            return Err(Failure("content_too_large"));
        }
    }
    if !entries.contains_key("SKILL.md") {
        return Err(Failure("missing_skill"));
    }
    Ok(entries)
}
pub(super) fn directory_digest(root: &Path) -> Result<String> {
    check_ancestors(root)?;
    let mut paths = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    let mut seen = BTreeSet::new();
    let mut nodes = 0;
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).map_err(|_| Failure("storage_failed"))? {
            let path = entry.map_err(|_| Failure("storage_failed"))?.path();
            nodes += 1;
            if nodes > MAX_FILES * 32 {
                return Err(Failure("content_too_large"));
            }
            let metadata = fs::symlink_metadata(&path).map_err(|_| Failure("storage_failed"))?;
            if linked(&metadata) {
                return Err(Failure("unsafe_path"));
            }
            let relative = path
                .strip_prefix(root)
                .map_err(|_| Failure("unsafe_path"))?
                .to_str()
                .ok_or(Failure("unsafe_path"))?
                .replace('\\', "/");
            if !safe_relative(&relative) || !seen.insert(relative.to_lowercase()) {
                return Err(Failure("unsafe_path"));
            }
            if metadata.is_dir() {
                pending.push(path);
            } else if metadata.is_file() {
                paths.push((relative, path));
            } else {
                return Err(Failure("unsafe_path"));
            }
            if paths.len() > MAX_FILES {
                return Err(Failure("content_too_large"));
            }
        }
    }
    paths.sort_by(|left, right| left.0.cmp(&right.0));
    let mut digest = Sha256::new();
    let mut size = 0_u64;
    for (relative, path) in paths {
        let bytes = read_bounded(&path, MAX_FILE)?;
        size += bytes.len() as u64;
        if size > MAX_CONTENT {
            return Err(Failure("content_too_large"));
        }
        digest.update(relative.as_bytes());
        digest.update([0]);
        digest.update((bytes.len() as u64).to_be_bytes());
        digest.update(&bytes);
    }
    Ok(hex::encode(digest.finalize()))
}
