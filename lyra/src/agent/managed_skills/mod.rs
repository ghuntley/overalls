//! Guest-owned, immutable skill materialization and content-free operation receipts.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

mod git;
mod materialize;
mod storage;
#[cfg(test)]
mod tests;
mod validate;
use materialize::{directory_digest, materialize, read_bounded, skill_header};
use storage::{
    check_ancestors, lock_installation, read_receipt, secure_directory, verify_revision_path,
    write_receipt,
};
use validate::{checkpoint, full_commit, installation_path, sha256, uuid, validate, wire_path};

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
