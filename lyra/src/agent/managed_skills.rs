//! Guest-owned, immutable skill materialization and content-free operation receipts.

use crate::workspace_source::{self, Revision, WorkspaceSource};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const MAX_FILES: usize = 512;
const MAX_CONTENT: u64 = 16 * 1024 * 1024;
const MAX_FILE: u64 = 8 * 1024 * 1024;
const MAX_FETCH: u64 = 64 * 1024 * 1024;
const MAX_HEADER: usize = 4 * 1024;
const MAX_SKILL: u64 = 1024 * 1024;
const MAX_RECEIPT: u64 = 16 * 1024;
const TIMEOUT: Duration = Duration::from_mins(2);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Failure(&'static str);
impl Failure {
    pub(super) fn code(&self) -> &'static str {
        self.0
    }
}
type Result<T> = std::result::Result<T, Failure>;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Install {
    version: u8,
    operation_id: String,
    thread_id: String,
    installation_id: String,
    source: Value,
    #[serde(default)]
    subdirectory: String,
    previous_path: Option<String>,
    previous_digest: Option<String>,
    expected_digest: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Status {
    version: u8,
    operation_id: String,
    thread_id: String,
    installation_id: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Installed {
    full_commit: String,
    content_digest: String,
    path: String,
    skill_digest: String,
    skill_bytes: u64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
enum Outcome {
    Pending,
    Installed(Installed),
    Failed { code: String },
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    version: u8,
    request_digest: String,
    outcome: Outcome,
}

#[cfg(unix)]
fn managed_root() -> PathBuf {
    PathBuf::from("/workspace/.overalls/skills")
}
#[cfg(windows)]
fn managed_root() -> PathBuf {
    PathBuf::from(r"C:\workspace\.overalls\skills")
}

/// @cc [owner:ghuntley,label:security;recovery] managed-skills-install-fenced
/// Installation MUST check its lease before network, publication and receipt writes,
/// use only validated public sources, and never execute repository code. Reusing an
/// operation ID with different inputs MUST refuse; pending receipts MUST NOT replay
/// an ambiguous installation. Existing edited revisions MUST never be overwritten.
pub(super) fn run_install(
    arguments: &Value,
    heartbeat: &mut impl FnMut() -> bool,
) -> Result<Value> {
    install_at(&managed_root(), arguments, heartbeat)
}

fn install_at(
    root: &Path,
    arguments: &Value,
    heartbeat: &mut impl FnMut() -> bool,
) -> Result<Value> {
    let args: Install =
        serde_json::from_value(arguments.clone()).map_err(|_| Failure("invalid_arguments"))?;
    let source = validate(&args)?;
    checkpoint(heartbeat)?;
    let installation = installation_path(root, &args.thread_id, &args.installation_id)?;
    let operations = installation.join("operations");
    secure_directory(&operations)?;
    let lock = lock_installation(&installation)?;
    let receipt_path = operations.join(format!("{}.json", args.operation_id));
    let fingerprint = hex::encode(Sha256::digest(
        serde_json::to_vec(&args).map_err(|_| Failure("invalid_arguments"))?,
    ));
    if receipt_path
        .try_exists()
        .map_err(|_| Failure("storage_failed"))?
    {
        let receipt = read_receipt(&receipt_path)?;
        if receipt.request_digest != fingerprint {
            return Err(Failure("operation_conflict"));
        }
        // Do not hold the installation lock while validating the retained
        // receipt. Replay is read-only, and releasing it before returning
        // keeps a subsequent reconciliation request from observing a stale
        // process-local lock.
        drop(lock);
        return receipt_response(&args.operation_id, receipt, &installation);
    }
    if let (Some(path), Some(digest)) = (&args.previous_path, &args.previous_digest) {
        verify_revision_path(&installation, Path::new(path))?;
        if directory_digest(Path::new(path))? != *digest {
            return Err(Failure("local_changes"));
        }
    }
    write_receipt(
        &receipt_path,
        &Receipt {
            version: 1,
            request_digest: fingerprint.clone(),
            outcome: Outcome::Pending,
        },
        heartbeat,
    )?;
    let outcome = materialize(&installation, &args, &source, heartbeat);
    match outcome {
        Ok(installed) => {
            let receipt = Receipt {
                version: 1,
                request_digest: fingerprint,
                outcome: Outcome::Installed(installed),
            };
            checkpoint(heartbeat)?;
            let response = receipt_response(&args.operation_id, receipt.clone(), &installation)?;
            write_receipt(&receipt_path, &receipt, heartbeat)?;
            Ok(response)
        }
        Err(error) => {
            if error.code() != "lease_lost" {
                write_receipt(
                    &receipt_path,
                    &Receipt {
                        version: 1,
                        request_digest: fingerprint,
                        outcome: Outcome::Failed {
                            code: error.code().to_owned(),
                        },
                    },
                    heartbeat,
                )?;
            }
            Err(error)
        }
    }
}

/// @cc [owner:ghuntley,label:recovery] managed-skills-status-read-only
/// Status MUST NOT fetch, install or recover a pending operation. Installed status
/// MUST verify the retained revision before returning its descriptor; pending work
/// is uncertain, and missing receipts are explicitly absent.
pub(super) fn run_status(arguments: &Value) -> Result<Value> {
    status_at(&managed_root(), arguments)
}
fn status_at(root: &Path, arguments: &Value) -> Result<Value> {
    let args: Status =
        serde_json::from_value(arguments.clone()).map_err(|_| Failure("invalid_arguments"))?;
    if args.version != 1
        || !uuid(&args.operation_id)
        || !uuid(&args.thread_id)
        || !uuid(&args.installation_id)
    {
        return Err(Failure("invalid_arguments"));
    }
    let installation = installation_path(root, &args.thread_id, &args.installation_id)?;
    let receipt_path = installation
        .join("operations")
        .join(format!("{}.json", args.operation_id));
    if !receipt_path
        .try_exists()
        .map_err(|_| Failure("storage_failed"))?
    {
        return Ok(json!({"version":1,"operation_id":args.operation_id,"status":"missing"}));
    }
    check_ancestors(&receipt_path)?;
    receipt_response(
        &args.operation_id,
        read_receipt(&receipt_path)?,
        &installation,
    )
}

fn validate(args: &Install) -> Result<WorkspaceSource> {
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
fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_digit() || (b'a'..=b'f').contains(&c)
            }
        })
}
fn full_commit(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn wire_path(path: &Path) -> Result<String> {
    Ok(path
        .to_str()
        .ok_or(Failure("unsafe_path"))?
        .replace('\\', "/"))
}
fn sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn safe_relative(value: &str) -> bool {
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
fn installation_path(root: &Path, thread: &str, installation: &str) -> Result<PathBuf> {
    if !uuid(thread) || !uuid(installation) {
        return Err(Failure("invalid_arguments"));
    }
    Ok(root.join(thread).join(installation))
}
fn checkpoint(heartbeat: &mut impl FnMut() -> bool) -> Result<()> {
    if heartbeat() {
        Ok(())
    } else {
        Err(Failure("lease_lost"))
    }
}

fn secure_directory(path: &Path) -> Result<()> {
    let mut built = PathBuf::new();
    for component in path.components() {
        if matches!(component, Component::ParentDir | Component::CurDir) {
            return Err(Failure("unsafe_path"));
        }
        built.push(component);
        match fs::symlink_metadata(&built) {
            Ok(meta) if meta.is_dir() && !linked(&meta) => (),
            Ok(_) => return Err(Failure("unsafe_path")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&built).map_err(|_| Failure("storage_failed"))?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&built, fs::Permissions::from_mode(0o700))
                        .map_err(|_| Failure("storage_failed"))?;
                }
            }
            Err(_) => return Err(Failure("storage_failed")),
        }
    }
    Ok(())
}
fn check_ancestors(path: &Path) -> Result<()> {
    for part in path.ancestors() {
        let metadata = fs::symlink_metadata(part).map_err(|_| Failure("storage_failed"))?;
        if linked(&metadata) {
            return Err(Failure("unsafe_path"));
        }
    }
    Ok(())
}
fn linked(metadata: &fs::Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        metadata.file_type().is_symlink() || metadata.is_file() && metadata.nlink() != 1
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
}
fn regular_file(path: &Path, max: u64) -> Result<File> {
    check_ancestors(path)?;
    let metadata = fs::symlink_metadata(path).map_err(|_| Failure("storage_failed"))?;
    if !metadata.is_file() || linked(&metadata) || metadata.len() > max {
        return Err(Failure("unsafe_path"));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).map_err(|_| Failure("storage_failed"))?;
    let opened = file.metadata().map_err(|_| Failure("storage_failed"))?;
    if !opened.is_file() || linked(&opened) || opened.len() > max {
        return Err(Failure("unsafe_path"));
    }
    Ok(file)
}
fn create_file(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path).map_err(|_| Failure("storage_failed"))
}
/// Exclusive installation lock that releases its flock explicitly on drop.
#[derive(Debug)]
struct InstallationLock(File);
impl Drop for InstallationLock {
    fn drop(&mut self) {
        // Closing this descriptor alone would not release the lock while a
        // fork-inherited duplicate of its open file description survives.
        // LOCK_UN acts on the shared description, so it releases every copy.
        let _ = FileExt::unlock(&self.0);
    }
}

// @cc [owner:ghuntley,label:recovery] managed-skills-lock-released-explicitly
// lock_installation MUST stay non-blocking: a held installation lock refuses with
// operation_in_progress, and only one holder may proceed. Release MUST unlock the
// flock (LOCK_UN) before closing, on every path including errors and replay. The
// flock belongs to the open file description, which a process spawned by another
// thread duplicates until exec despite O_CLOEXEC; relying on close would let that
// copy keep the lock and make a later caller see a false operation_in_progress.
fn lock_installation(path: &Path) -> Result<InstallationLock> {
    let target = path.join("lock");
    if !target.try_exists().map_err(|_| Failure("storage_failed"))? {
        drop(create_file(&target)?);
    }
    let file = regular_file(&target, 0)?;
    file.try_lock_exclusive()
        .map_err(|_| Failure("operation_in_progress"))?;
    Ok(InstallationLock(file))
}
fn read_receipt(path: &Path) -> Result<Receipt> {
    let reader = regular_file(path, MAX_RECEIPT)?.take(MAX_RECEIPT + 1);
    let receipt: Receipt =
        serde_json::from_reader(reader).map_err(|_| Failure("invalid_receipt"))?;
    if receipt.version != 1 || !sha256(&receipt.request_digest) {
        return Err(Failure("invalid_receipt"));
    }
    Ok(receipt)
}
fn write_receipt(
    path: &Path,
    receipt: &Receipt,
    heartbeat: &mut impl FnMut() -> bool,
) -> Result<()> {
    checkpoint(heartbeat)?;
    let parent = path.parent().ok_or(Failure("unsafe_path"))?;
    check_ancestors(parent)?;
    let mut file =
        tempfile::NamedTempFile::new_in(parent).map_err(|_| Failure("storage_failed"))?;
    serde_json::to_writer(&mut file, receipt).map_err(|_| Failure("storage_failed"))?;
    file.as_file()
        .sync_all()
        .map_err(|_| Failure("storage_failed"))?;
    checkpoint(heartbeat)?;
    #[cfg(unix)]
    file.persist(path).map_err(|_| Failure("storage_failed"))?;
    #[cfg(windows)]
    {
        let (file, temporary_path) = file.keep().map_err(|_| Failure("storage_failed"))?;
        drop(file);
        if let Err(error) = move_path(&temporary_path, path, true) {
            let _ = fs::remove_file(&temporary_path);
            return Err(error);
        }
    }
    sync_directory(parent)
}
#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|_| Failure("storage_failed"))
}
#[cfg(windows)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Windows has no directory fsync; the Unix variant shares the signature"
)]
fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn move_path(source: &Path, target: &Path, _replace: bool) -> Result<()> {
    fs::rename(source, target).map_err(|_| Failure("storage_failed"))
}
#[cfg(windows)]
fn move_path(source: &Path, target: &Path, replace: bool) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let target: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    let flags = MOVEFILE_WRITE_THROUGH
        | if replace {
            MOVEFILE_REPLACE_EXISTING
        } else {
            0
        };
    // SAFETY: both paths are validated native paths terminated with a NUL; buffers
    // remain live throughout the call. No caller-controlled flags are accepted.
    if unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), flags) } == 0 {
        Err(Failure("storage_failed"))
    } else {
        Ok(())
    }
}
fn sync_tree_directories(root: &Path) -> Result<()> {
    let mut paths = vec![root.to_path_buf()];
    let mut offset = 0;
    while offset < paths.len() {
        let directory = paths[offset].clone();
        for entry in fs::read_dir(directory).map_err(|_| Failure("storage_failed"))? {
            let entry = entry.map_err(|_| Failure("storage_failed"))?;
            let metadata =
                fs::symlink_metadata(entry.path()).map_err(|_| Failure("storage_failed"))?;
            if linked(&metadata) {
                return Err(Failure("unsafe_path"));
            }
            if metadata.is_dir() {
                paths.push(entry.path());
            }
            if paths.len() > MAX_FILES * 32 {
                return Err(Failure("content_too_large"));
            }
        }
        offset += 1;
    }
    for path in paths.into_iter().rev() {
        sync_directory(&path)?;
    }
    Ok(())
}

fn verify_revision_path(installation: &Path, path: &Path) -> Result<()> {
    let relative = path
        .strip_prefix(installation.join("revisions"))
        .map_err(|_| Failure("unsafe_path"))?;
    if relative.components().count() != 1 || !relative.to_str().is_some_and(sha256) {
        return Err(Failure("unsafe_path"));
    }
    check_ancestors(path)
}
fn receipt_response(operation_id: &str, receipt: Receipt, installation: &Path) -> Result<Value> {
    match receipt.outcome {
        Outcome::Pending => {
            Ok(json!({"version":1,"operation_id":operation_id,"status":"uncertain"}))
        }
        Outcome::Failed { code } => {
            // Receipt tampering must not create arbitrary diagnostics or error names.
            let code = match code.as_str() {
                "fetch_failed"
                | "fetch_too_large"
                | "operation_timeout"
                | "unsafe_path"
                | "invalid_tree"
                | "content_too_large"
                | "missing_skill"
                | "invalid_skill"
                | "digest_mismatch"
                | "storage_failed"
                | "local_changes"
                | "invalid_revision"
                | "unsupported_revision"
                | "git_unavailable" => code,
                _ => return Err(Failure("invalid_receipt")),
            };
            Ok(json!({"version":1,"operation_id":operation_id,"status":"failed","code":code}))
        }
        Outcome::Installed(installed) => {
            let path = Path::new(&installed.path);
            verify_revision_path(installation, path)?;
            if !full_commit(&installed.full_commit)
                || !sha256(&installed.content_digest)
                || directory_digest(path)? != installed.content_digest
            {
                return Err(Failure("local_changes"));
            }
            let skill_path = path.join("SKILL.md");
            let bytes = read_bounded(&skill_path, MAX_SKILL)?;
            if hex::encode(Sha256::digest(&bytes)) != installed.skill_digest
                || bytes.len() as u64 != installed.skill_bytes
            {
                return Err(Failure("local_changes"));
            }
            let header = skill_header(&bytes)?;
            let response = json!({"version":1,"operation_id":operation_id,"status":"installed",
                "full_commit":installed.full_commit,"content_digest":installed.content_digest,"path":installed.path,
                "skill_file":{"path":wire_path(&skill_path)?,"digest":installed.skill_digest,"bytes":installed.skill_bytes,"header":header}});
            if serde_json::to_vec(&response)
                .map_err(|_| Failure("invalid_skill"))?
                .len()
                > 10 * 1024
            {
                return Err(Failure("invalid_skill"));
            }
            Ok(response)
        }
    }
}
fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>> {
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
fn skill_header(bytes: &[u8]) -> Result<String> {
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
fn materialize(
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

fn extract_tree<H: FnMut() -> bool>(
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

fn resolve_commit(source: &WorkspaceSource, advertised: &[u8]) -> Result<(String, &'static str)> {
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
fn parse_tree(bytes: &[u8]) -> Result<BTreeMap<String, String>> {
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
fn directory_digest(root: &Path) -> Result<String> {
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

#[cfg(unix)]
fn ca_bundle() -> Result<PathBuf> {
    #[cfg(test)]
    if let Some(path) = option_env!("OVERALLS_TEST_CA_BUNDLE") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
    }
    let path = PathBuf::from(crate::private_http::SYSTEM_CA_BUNDLE);
    if path.is_file() {
        Ok(path)
    } else {
        Err(Failure("git_unavailable"))
    }
}
#[cfg(windows)]
fn ca_bundle() -> Result<PathBuf> {
    let root = PathBuf::from(r"C:\overalls\trust");
    let pointer = read_bounded(&root.join("current"), 128)?;
    let name = std::str::from_utf8(&pointer)
        .map_err(|_| Failure("git_unavailable"))?
        .trim();
    if !name.strip_prefix("bundle-").is_some_and(sha256) {
        return Err(Failure("git_unavailable"));
    }
    let path = root.join(name).join("ca-bundle.pem");
    regular_file(&path, 4 * 1024 * 1024)?;
    Ok(path)
}
#[cfg(unix)]
fn git_program() -> Result<PathBuf> {
    #[cfg(test)]
    if let Some(path) = option_env!("OVERALLS_TEST_GIT") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
    }
    let candidates: &[&str] = if cfg!(target_os = "freebsd") {
        &["/usr/local/bin/git"]
    } else {
        &["/run/current-system/sw/bin/git", "/usr/bin/git", "/bin/git"]
    };
    candidates
        .iter()
        .map(PathBuf::from)
        .find(|path| path.is_file())
        .ok_or(Failure("git_unavailable"))
}
#[cfg(windows)]
fn git_program() -> Result<PathBuf> {
    let path = PathBuf::from(r"C:\Program Files\Git\cmd\git.exe");
    if path.is_file() {
        Ok(path)
    } else {
        Err(Failure("git_unavailable"))
    }
}
struct Git<'a, H: FnMut() -> bool> {
    program: PathBuf,
    root: &'a Path,
    home: &'a Path,
    started: Instant,
    heartbeat: &'a mut H,
}
impl<H: FnMut() -> bool> Git<'_, H> {
    fn command(&self, arguments: &[&str]) -> Result<Command> {
        let bundle = ca_bundle()?;
        let mut command = Command::new(&self.program);
        command
            .env_clear()
            .current_dir(self.root)
            .env("HOME", self.home)
            .env("LANG", "C")
            .env("GIT_SSL_CAINFO", &bundle)
            .env("SSL_CERT_FILE", &bundle)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_LFS_SKIP_SMUDGE", "1")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .args([
                "-c",
                "credential.helper=",
                "-c",
                "credential.interactive=false",
                "-c",
                "protocol.allow=never",
                "-c",
                "protocol.https.allow=always",
                "-c",
                "http.followRedirects=false",
                "-c",
                "http.sslVerify=true",
                "-c",
                "http.lowSpeedLimit=1024",
                "-c",
                "http.lowSpeedTime=15",
                "-c",
                "fetch.fsckObjects=true",
                "-c",
                "transfer.fsckObjects=true",
                "-c",
                "fetch.recurseSubmodules=false",
                "-c",
                "submodule.recurse=false",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "gc.auto=0",
            ])
            .arg("-c")
            .arg(format!("core.hooksPath={}", self.home.display()))
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            let mut path = std::ffi::OsString::new();
            #[cfg(test)]
            if let Some(extra) = option_env!("OVERALLS_TEST_PATH") {
                path.push(extra);
                path.push(":");
            }
            path.push("/run/current-system/sw/bin:/usr/bin:/bin");
            command
                .process_group(0)
                .env("PATH", path)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("TMPDIR", self.home);
        }
        #[cfg(windows)]
        {
            command
                .env("SystemRoot", r"C:\Windows")
                .env(
                    "PATH",
                    r"C:\Program Files\Git\cmd;C:\Windows\System32;C:\Windows",
                )
                .env("GIT_CONFIG_GLOBAL", "NUL")
                .env("GIT_CONFIG_COUNT", "1")
                .env("GIT_CONFIG_KEY_0", "http.sslBackend")
                .env("GIT_CONFIG_VALUE_0", "openssl")
                .env("TEMP", self.home)
                .env("TMP", self.home);
        }
        Ok(command)
    }
    fn run(&mut self, arguments: &[&str], limit: usize) -> Result<Vec<u8>> {
        checkpoint(self.heartbeat)?;
        if self.started.elapsed() >= TIMEOUT {
            return Err(Failure("operation_timeout"));
        }
        let mut child = self
            .command(arguments)?
            .spawn()
            .map_err(|_| Failure("git_unavailable"))?;
        let group = match ProcessGroup::attach(&child) {
            Ok(group) => group,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let stdout = child.stdout.take().ok_or(Failure("fetch_failed"))?;
        let (sender, receiver) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = stdout
                .take(limit as u64 + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = sender.send(result);
        });
        let mut captured = None;
        let result = loop {
            if let Err(error) = checkpoint(self.heartbeat) {
                break Err(error);
            }
            if self.started.elapsed() >= TIMEOUT {
                break Err(Failure("operation_timeout"));
            }
            if !scratch_within_limit(self.root) {
                break Err(Failure("fetch_too_large"));
            }
            if captured.is_none() {
                match receiver.try_recv() {
                    Ok(Ok(bytes)) if bytes.len() <= limit => captured = Some(bytes),
                    Ok(_) => break Err(Failure("fetch_too_large")),
                    Err(std::sync::mpsc::TryRecvError::Empty) => (),
                    Err(_) => break Err(Failure("fetch_failed")),
                }
            }
            match child.try_wait() {
                Ok(Some(status)) if !status.success() => break Err(Failure("fetch_failed")),
                Ok(Some(_)) if captured.is_some() => break Ok(captured.take().unwrap_or_default()),
                Ok(_) => (),
                Err(_) => break Err(Failure("fetch_failed")),
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        group.kill();
        let _ = child.wait();
        let _ = reader.join();
        result
    }
}
fn scratch_within_limit(root: &Path) -> bool {
    let mut pending = vec![root.to_path_buf()];
    let mut bytes = 0_u64;
    let mut count = 0_usize;
    while let Some(path) = pending.pop() {
        let Ok(entries) = fs::read_dir(path) else {
            return false;
        };
        for entry in entries {
            let Ok(entry) = entry else {
                return false;
            };
            let Ok(metadata) = fs::symlink_metadata(entry.path()) else {
                continue;
            };
            if linked(&metadata) {
                return false;
            }
            count += 1;
            if count > 20000 {
                return false;
            }
            if metadata.is_dir() {
                pending.push(entry.path());
            } else if metadata.is_file() {
                bytes = bytes.saturating_add(metadata.len());
            } else {
                return false;
            }
            if bytes > MAX_FETCH {
                return false;
            }
        }
    }
    true
}
#[cfg(unix)]
struct ProcessGroup(i32);
#[cfg(unix)]
impl ProcessGroup {
    fn attach(child: &std::process::Child) -> Result<Self> {
        i32::try_from(child.id())
            .map(Self)
            .map_err(|_| Failure("fetch_failed"))
    }
    fn kill(&self) {
        // SAFETY: the child starts in its own group; the validated PID belongs
        // only to this invocation, including its HTTPS helper descendants.
        unsafe {
            libc::killpg(self.0, libc::SIGKILL);
        }
    }
}
#[cfg(windows)]
struct ProcessGroup(crate::platform::windows::job::Job);
#[cfg(windows)]
impl ProcessGroup {
    fn attach(child: &std::process::Child) -> Result<Self> {
        crate::platform::windows::job::Job::attach(child)
            .map(Self)
            .map_err(|_| Failure("fetch_failed"))
    }
    fn kill(&self) {
        self.0.terminate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const THREAD: &str = "00000000-0000-7000-8000-000000000001";
    const INSTALLATION: &str = "00000000-0000-7000-8000-000000000002";
    const OPERATION: &str = "00000000-0000-7000-8000-000000000003";
    fn arguments() -> Value {
        json!({"version":1,"thread_id":THREAD,"installation_id":INSTALLATION,"operation_id":OPERATION,"source":workspace_source::parse_url("https://github.com/example/skills").unwrap().encode(),"subdirectory":"review"})
    }
    #[test]
    fn rejects_untrusted_arguments_and_cross_platform_path_escapes() {
        for path in [
            "../outside",
            "/absolute",
            "a/../b",
            "a\\b",
            "a/CON",
            "file:stream",
            "a/",
            "a/.git",
            "a/space ",
            "a/.",
            "a/CONIN$",
            "a/COM¹",
            "a/日本語",
        ] {
            let mut value = arguments();
            value["subdirectory"] = json!(path);
            assert!(
                validate(&serde_json::from_value(value).unwrap()).is_err(),
                "{path}"
            );
        }
        for path in ["review", "skills/review", ".agents/skills/review"] {
            assert!(safe_relative(path));
        }
        let mut value = arguments();
        value["source"]["provider"] = json!("untrusted");
        assert_eq!(
            validate(&serde_json::from_value(value).unwrap())
                .unwrap_err()
                .code(),
            "invalid_source"
        );
    }
    #[test]
    fn tree_rejects_links_submodules_and_case_collisions() {
        let hash = "a".repeat(40);
        for bad in [
            format!("120000 blob {hash}\tlink\0"),
            format!("160000 commit {hash}\tmodule\0"),
            format!("100644 blob {hash}\tDir/a\0"),
            format!("100644 blob {hash}\t../escape\0"),
        ] {
            let tree = format!("100644 blob {hash}\tSKILL.md\0100644 blob {hash}\tdir/b\0{bad}");
            assert!(parse_tree(tree.as_bytes()).is_err());
        }
        assert_eq!(
            parse_tree(format!("100644 blob {hash}\tSKILL.md\0").as_bytes())
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn header_is_complete_and_bounded() {
        assert_eq!(
            skill_header(b"---\nname: review\ndescription: Review code\n---\nBody").unwrap(),
            "---\nname: review\ndescription: Review code\n---\n"
        );
        assert!(skill_header(b"---\nname: unfinished").is_err());
        assert!(
            skill_header(format!("---\n{}\n---\n", "x".repeat(MAX_HEADER)).as_bytes()).is_err()
        );
    }
    #[test]
    fn ambiguous_receipt_is_status_only_and_request_conflicts_refuse() {
        let tmp = tempfile::tempdir().unwrap();
        let args = arguments();
        let request: Install = serde_json::from_value(args.clone()).unwrap();
        let path = installation_path(tmp.path(), THREAD, INSTALLATION)
            .unwrap()
            .join("operations");
        secure_directory(&path).unwrap();
        let receipt = Receipt {
            version: 1,
            request_digest: hex::encode(Sha256::digest(serde_json::to_vec(&request).unwrap())),
            outcome: Outcome::Pending,
        };
        write_receipt(
            &path.join(format!("{OPERATION}.json")),
            &receipt,
            &mut || true,
        )
        .unwrap();
        assert_eq!(
            install_at(tmp.path(), &args, &mut || true).unwrap()["status"],
            "uncertain"
        );
        let mut changed = args.clone();
        changed["subdirectory"] = json!("other");
        assert_eq!(
            install_at(tmp.path(), &changed, &mut || true)
                .unwrap_err()
                .code(),
            "operation_conflict"
        );
        assert_eq!(status_at(tmp.path(), &json!({"version":1,"thread_id":THREAD,"installation_id":INSTALLATION,"operation_id":OPERATION})).unwrap()["status"], "uncertain");
    }
    #[test]
    fn released_lock_ignores_fork_inherited_descriptor_copies() {
        let tmp = tempfile::tempdir().unwrap();
        let installation = installation_path(tmp.path(), THREAD, INSTALLATION).unwrap();
        secure_directory(&installation).unwrap();
        let held = lock_installation(&installation).unwrap();
        // A duplicate shares the open file description exactly as a child
        // forked by another thread does between fork and exec.
        let inherited = held.0.try_clone().unwrap();
        assert_eq!(
            lock_installation(&installation).unwrap_err().code(),
            "operation_in_progress",
            "a real holder still excludes other installers"
        );
        drop(held);
        // The surviving copy must not keep the installation locked.
        let next = lock_installation(&installation)
            .expect("released lock must not report operation_in_progress");
        assert_eq!(
            lock_installation(&installation).unwrap_err().code(),
            "operation_in_progress"
        );
        drop(next);
        drop(inherited);
        drop(lock_installation(&installation).unwrap());
    }
    #[test]
    fn failed_lease_cannot_create_a_receipt() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(
            install_at(tmp.path(), &arguments(), &mut || false)
                .unwrap_err()
                .code(),
            "lease_lost"
        );
        assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 0);
    }
    #[test]
    fn digest_detects_local_changes_and_is_order_independent() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a");
        let b = tmp.path().join("b");
        secure_directory(&a).unwrap();
        secure_directory(&b).unwrap();
        fs::write(a.join("SKILL.md"), b"---\nname: x\ndescription: x\n---\n").unwrap();
        fs::write(a.join("helper"), b"first").unwrap();
        fs::write(b.join("helper"), b"first").unwrap();
        fs::write(b.join("SKILL.md"), b"---\nname: x\ndescription: x\n---\n").unwrap();
        let digest = directory_digest(&a).unwrap();
        assert_eq!(digest, directory_digest(&b).unwrap());
        fs::write(b.join("helper"), b"edited").unwrap();
        assert_ne!(digest, directory_digest(&b).unwrap());
    }
    #[cfg(unix)]
    #[test]
    fn linked_managed_paths_and_content_are_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), tmp.path().join("linked")).unwrap();
        assert_eq!(
            secure_directory(&tmp.path().join("linked/child"))
                .unwrap_err()
                .code(),
            "unsafe_path"
        );
        assert_eq!(
            directory_digest(tmp.path()).unwrap_err().code(),
            "unsafe_path"
        );
    }
    #[test]
    fn annotated_tags_pin_the_peeled_commit() {
        let source =
            workspace_source::parse_url("https://github.com/example/skills/releases/tag/v1")
                .unwrap();
        let tag = "a".repeat(40);
        let commit = "b".repeat(40);
        let advertised = format!("{tag}\trefs/tags/v1\n{commit}\trefs/tags/v1^{{}}\n");
        assert_eq!(
            resolve_commit(&source, advertised.as_bytes()).unwrap(),
            (commit, "sha1")
        );
    }
    #[cfg(unix)]
    #[test]
    fn extracts_real_blobs_without_running_attributes_filters_or_hooks() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        secure_directory(&home).unwrap();
        let mut alive = || true;
        let mut git = Git {
            program: git_program().unwrap(),
            root: tmp.path(),
            home: &home,
            started: Instant::now(),
            heartbeat: &mut alive,
        };
        let repo = tmp.path().join("repo");
        let repo_arg = repo.to_str().unwrap();
        git.run(&["init", "--bare", "--template=", repo_arg], 4096)
            .unwrap();
        let skill = b"---\nname: local\ndescription: Synthetic local skill\n---\nRun explicit instructions.\n";
        let attributes = b"* filter=should-not-run\n";
        for (name, bytes) in [
            ("SKILL.md", skill.as_slice()),
            (".gitattributes", attributes.as_slice()),
        ] {
            let fixture = tmp.path().join("fixture");
            fs::write(&fixture, bytes).unwrap();
            let object = git
                .run(
                    &[
                        "--git-dir",
                        repo_arg,
                        "hash-object",
                        "-w",
                        fixture.to_str().unwrap(),
                    ],
                    128,
                )
                .unwrap();
            let object = std::str::from_utf8(&object).unwrap().trim();
            git.run(
                &[
                    "--git-dir",
                    repo_arg,
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    &format!("100644,{object},{name}"),
                ],
                128,
            )
            .unwrap();
        }
        // This deliberately dangerous local filter must remain inert: the extractor
        // reads blobs, never checkout/smudge or repository scripts.
        git.run(
            &[
                "--git-dir",
                repo_arg,
                "config",
                "filter.should-not-run.smudge",
                "touch SHOULD_NOT_EXIST",
            ],
            128,
        )
        .unwrap();
        let tree = git
            .run(&["--git-dir", repo_arg, "write-tree"], 128)
            .unwrap();
        let tree = std::str::from_utf8(&tree).unwrap().trim();
        let output = tmp.path().join("output");
        extract_tree(&mut git, repo_arg, tree, &output).unwrap();
        assert_eq!(fs::read(output.join("SKILL.md")).unwrap(), skill);
        assert_eq!(fs::read(output.join(".gitattributes")).unwrap(), attributes);
        assert!(!tmp.path().join("SHOULD_NOT_EXIST").exists());
    }
    #[cfg(unix)]
    #[test]
    fn lease_loss_kills_git_process_tree_promptly() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        secure_directory(&home).unwrap();
        let started = Instant::now();
        let mut checks = 0_u32;
        let mut alive = || {
            checks += 1;
            checks < 4
        };
        let mut git = Git {
            program: git_program().unwrap(),
            root: tmp.path(),
            home: &home,
            started,
            heartbeat: &mut alive,
        };
        assert_eq!(
            git.run(&["-c", "alias.slow=!sleep 20", "slow"], 128)
                .unwrap_err()
                .code(),
            "lease_lost"
        );
        assert!(started.elapsed() < Duration::from_secs(3));
    }
    #[test]
    fn status_reports_missing_and_preserves_edited_revisions() {
        let tmp = tempfile::tempdir().unwrap();
        let query = json!({"version":1,"thread_id":THREAD,"installation_id":INSTALLATION,"operation_id":OPERATION});
        assert_eq!(status_at(tmp.path(), &query).unwrap()["status"], "missing");
        assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 0);
        let installation = installation_path(tmp.path(), THREAD, INSTALLATION).unwrap();
        let scratch = tmp.path().join("content");
        secure_directory(&scratch).unwrap();
        let bytes = b"---\nname: local\ndescription: A local skill\n---\nbody\n";
        fs::write(scratch.join("SKILL.md"), bytes).unwrap();
        let digest = directory_digest(&scratch).unwrap();
        let path = installation.join("revisions").join(&digest);
        secure_directory(path.parent().unwrap()).unwrap();
        fs::rename(&scratch, &path).unwrap();
        let operations = installation.join("operations");
        secure_directory(&operations).unwrap();
        let receipt = Receipt {
            version: 1,
            request_digest: "a".repeat(64),
            outcome: Outcome::Installed(Installed {
                full_commit: "b".repeat(40),
                content_digest: digest,
                path: wire_path(&path).unwrap(),
                skill_digest: hex::encode(Sha256::digest(bytes)),
                skill_bytes: bytes.len() as u64,
            }),
        };
        write_receipt(
            &operations.join(format!("{OPERATION}.json")),
            &receipt,
            &mut || true,
        )
        .unwrap();
        let result = status_at(tmp.path(), &query).unwrap();
        assert_eq!(result["status"], "installed");
        assert!(serde_json::to_vec(&result).unwrap().len() < 10 * 1024);
        fs::write(path.join("SKILL.md"), "local edit").unwrap();
        assert_eq!(
            status_at(tmp.path(), &query).unwrap_err().code(),
            "local_changes"
        );
        assert_eq!(
            fs::read_to_string(path.join("SKILL.md")).unwrap(),
            "local edit"
        );
    }
}
