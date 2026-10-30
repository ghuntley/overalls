//! Guest-owned, bounded instruction and skill discovery. No file contents enter diagnostics.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

mod account_home;

const FILE_LIMIT: usize = 1_048_576;
const INVENTORY_LIMIT: usize = 256;
const PAGE_LIMIT: usize = 8_192;
const DIRECTORY_LIMIT: usize = 2_000;
const ENTRY_LIMIT: usize = 20_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Failure {
    InvalidArguments,
    InvalidConfiguration,
    AccountUnavailable,
    WorkspaceUnavailable,
    ContextChanged,
    UnsafePath,
    ReadFailed,
    ContextLimit,
    LeaseLost,
}

impl Failure {
    pub(super) fn code(self) -> &'static str {
        match self {
            Self::InvalidArguments => "invalid_arguments",
            Self::InvalidConfiguration => "invalid_configuration",
            Self::AccountUnavailable => "account_unavailable",
            Self::WorkspaceUnavailable => "workspace_unavailable",
            Self::ContextChanged => "context_changed",
            Self::UnsafePath => "unsafe_path",
            Self::ReadFailed => "read_failed",
            Self::ContextLimit => "context_limit",
            Self::LeaseLost => "lease_lost",
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InventoryArguments {
    version: u8,
    creator_username: String,
    working_directory: Option<String>,
    #[serde(default)]
    fallback_filenames: Vec<String>,
    #[serde(default)]
    managed_skill_paths: Vec<String>,
    cursor: Option<Cursor>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Cursor {
    digest: String,
    offset: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadArguments {
    version: u8,
    path: String,
    digest: String,
    offset: usize,
    limit: usize,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    #[serde(default)]
    project_instruction_fallback_filenames: Vec<String>,
}

#[derive(Clone, Serialize)]
struct Entry {
    position: usize,
    kind: &'static str,
    path: String,
    digest: String,
    bytes: usize,
    scope: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    skill_path: Option<String>,
}

#[derive(Serialize)]
struct Inventory {
    working_directory: String,
    creator_home: String,
    project_root: Option<String>,
    entries: Vec<Entry>,
    warnings: BTreeSet<&'static str>,
    source_digest: Option<String>,
}

struct Scan<'a, F: FnMut() -> bool> {
    inventory: Inventory,
    seen: BTreeSet<PathBuf>,
    directory_count: usize,
    entry_count: usize,
    deadline: Instant,
    heartbeat: &'a mut F,
}

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !matches!(value, "." | "..")
        && !value.chars().any(|c| c.is_control() || "/\\:".contains(c))
}

fn path_string(path: &Path) -> Result<String, Failure> {
    let value = path.to_str().ok_or(Failure::UnsafePath)?;
    if value.len() > 4096 || value.chars().any(char::is_control) {
        return Err(Failure::UnsafePath);
    }
    Ok(value.to_owned())
}

fn is_link(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

/// @cc [owner:ghuntley,label:security] guest-context-path-components
/// Automatic context collection MUST reject symbolic links, reparse points,
/// parent components and nonabsolute paths. Every component is inspected before
/// and after reads; a changed path or content MUST never be accepted under an
/// earlier inventory digest. This is consistency validation, not a filesystem
/// isolation boundary against a guest writer who already has administrator access.
fn inspect_path(path: &Path) -> Result<(), Failure> {
    if !path.is_absolute() {
        return Err(Failure::UnsafePath);
    }
    path_string(path)?;
    let mut current = PathBuf::new();
    for component in path.components() {
        if matches!(component, Component::ParentDir | Component::CurDir) {
            return Err(Failure::UnsafePath);
        }
        current.push(component);
        let metadata = fs::symlink_metadata(&current).map_err(|_| Failure::ReadFailed)?;
        if is_link(&metadata) {
            return Err(Failure::UnsafePath);
        }
    }
    Ok(())
}

fn directory(path: &Path) -> Result<PathBuf, Failure> {
    inspect_path(path)?;
    if !fs::metadata(path)
        .map_err(|_| Failure::ReadFailed)?
        .is_dir()
    {
        return Err(Failure::UnsafePath);
    }
    Ok(path.to_owned())
}

fn read(path: &Path) -> Result<Vec<u8>, Failure> {
    inspect_path(path)?;
    if fs::metadata(path).map_err(|_| Failure::ReadFailed)?.len() > FILE_LIMIT as u64 {
        return Err(Failure::ContextLimit);
    }
    let bytes = crate::ssh_files::read(path, FILE_LIMIT).map_err(|_| Failure::ReadFailed)?;
    inspect_path(path)?;
    Ok(bytes)
}

fn optional_file(path: &Path) -> Result<Option<Vec<u8>>, Failure> {
    match fs::symlink_metadata(path) {
        Ok(_) => read(path).map(Some),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(Failure::ReadFailed),
    }
}

#[cfg(unix)]
fn guest_paths() -> crate::workspace_receiver::Paths {
    crate::workspace_receiver::Paths::guest()
}
#[cfg(windows)]
fn guest_paths() -> crate::workspace_receiver::Paths {
    crate::workspace_receiver::Paths::windows()
}
#[cfg(unix)]
fn machine_config() -> PathBuf {
    PathBuf::from("/etc/overalls")
}
#[cfg(windows)]
fn machine_config() -> PathBuf {
    PathBuf::from(r"C:\ProgramData\Overalls")
}

fn default_working_directory(paths: &crate::workspace_receiver::Paths) -> Result<PathBuf, Failure> {
    if let Some(bytes) = optional_file(&paths.source())? {
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| Failure::ContextChanged)?;
        let source =
            crate::workspace_source::decode(&value).map_err(|_| Failure::ContextChanged)?;
        if optional_file(&paths.done())?.is_some() {
            let path = directory(&paths.checkout(&source))?;
            if repository_root(&path)?.as_deref() == Some(path.as_path()) {
                return Ok(path);
            }
            return Err(Failure::WorkspaceUnavailable);
        }
    }
    directory(&paths.workspace).map_err(|_| Failure::WorkspaceUnavailable)
}

fn repository_root(cwd: &Path) -> Result<Option<PathBuf>, Failure> {
    for directory in cwd.ancestors() {
        let git = directory.join(".git");
        match fs::symlink_metadata(&git) {
            Ok(meta) if meta.is_dir() && !is_link(&meta) => return Ok(Some(directory.to_owned())),
            Ok(meta) if meta.is_file() && !is_link(&meta) => {
                let bytes = read(&git)?;
                let text = std::str::from_utf8(&bytes).map_err(|_| Failure::ContextChanged)?;
                let target = text
                    .trim()
                    .strip_prefix("gitdir: ")
                    .ok_or(Failure::ContextChanged)?;
                // Git worktrees legitimately point outside the working directory.
                // Canonicalization here validates that the administrative target exists;
                // no guidance is read from that target.
                let target = directory.join(target);
                let canonical = fs::canonicalize(target).map_err(|_| Failure::ContextChanged)?;
                if !canonical.is_dir() {
                    return Err(Failure::ContextChanged);
                }
                return Ok(Some(directory.to_owned()));
            }
            Ok(_) => return Err(Failure::UnsafePath),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Failure::ReadFailed),
        }
    }
    Ok(None)
}

impl<F: FnMut() -> bool> Scan<'_, F> {
    fn checkpoint(&mut self) -> Result<(), Failure> {
        if Instant::now() >= self.deadline {
            return Err(Failure::ContextLimit);
        }
        if !(self.heartbeat)() {
            return Err(Failure::LeaseLost);
        }
        Ok(())
    }

    fn add(
        &mut self,
        path: &Path,
        kind: &'static str,
        scope: &'static str,
        skill: Option<String>,
    ) -> Result<(), Failure> {
        self.checkpoint()?;
        if !self.seen.insert(path.to_owned()) {
            return Ok(());
        }
        if self.inventory.entries.len() >= INVENTORY_LIMIT {
            return Err(Failure::ContextLimit);
        }
        let bytes = read(path)?;
        if self
            .inventory
            .entries
            .iter()
            .map(|entry| entry.bytes)
            .sum::<usize>()
            + bytes.len()
            > 2_097_152
        {
            return Err(Failure::ContextLimit);
        }
        self.inventory.entries.push(Entry {
            position: self.inventory.entries.len(),
            kind,
            path: path_string(path)?,
            digest: digest(&bytes),
            bytes: bytes.len(),
            scope,
            skill_path: skill,
        });
        Ok(())
    }

    fn instructions(
        &mut self,
        root: &Path,
        scope: &'static str,
        fallback: &[String],
        empty_suppresses: bool,
    ) -> Result<(), Failure> {
        let names = ["AGENTS.override.md", "AGENTS.md"];
        for name in names.into_iter().chain(fallback.iter().map(String::as_str)) {
            let path = root.join(name);
            if let Some(bytes) = optional_file(&path)? {
                if !bytes.iter().all(u8::is_ascii_whitespace) || empty_suppresses {
                    self.add(&path, "instruction", scope, None)?;
                    break;
                }
            }
        }
        Ok(())
    }

    fn skills(&mut self, root: &Path, scope: &'static str) -> Result<(), Failure> {
        match fs::symlink_metadata(root) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(_) => return Err(Failure::ReadFailed),
            Ok(meta) if is_link(&meta) => {
                self.inventory.warnings.insert("skill_link_skipped");
                return Ok(());
            }
            Ok(_) => {}
        }
        let mut pending = vec![(directory(root)?, 0usize)];
        while let Some((current, depth)) = pending.pop() {
            self.checkpoint()?;
            self.directory_count += 1;
            if self.directory_count > DIRECTORY_LIMIT || depth > 16 {
                return Err(Failure::ContextLimit);
            }
            let skill = current.join("SKILL.md");
            if optional_file(&skill)?.is_some() {
                self.add(&skill, "skill", scope, None)?;
                let metadata = current.join("agents/overalls.yaml");
                if optional_file(&metadata)?.is_some() {
                    self.add(
                        &metadata,
                        "skill_metadata",
                        scope,
                        Some(path_string(&skill)?),
                    )?;
                }
                // Resources below a skill are not separate implicit skills.
                continue;
            }
            let mut children = Vec::new();
            for child in fs::read_dir(&current).map_err(|_| Failure::ReadFailed)? {
                self.entry_count += 1;
                if self.entry_count > ENTRY_LIMIT {
                    return Err(Failure::ContextLimit);
                }
                children.push(child.map_err(|_| Failure::ReadFailed)?);
            }
            children.sort_by_key(fs::DirEntry::file_name);
            for child in children.into_iter().rev() {
                let metadata =
                    fs::symlink_metadata(child.path()).map_err(|_| Failure::ContextChanged)?;
                if is_link(&metadata) {
                    self.inventory.warnings.insert("skill_link_skipped");
                } else if metadata.is_dir() && child.file_name() != ".git" {
                    pending.push((child.path(), depth + 1));
                }
            }
        }
        Ok(())
    }
}

fn collect<F: FnMut() -> bool>(
    args: &InventoryArguments,
    home: &Path,
    cwd: &Path,
    machine: &Path,
    heartbeat: &mut F,
) -> Result<Inventory, Failure> {
    let root = repository_root(cwd)?;
    let mut scan = Scan {
        inventory: Inventory {
            working_directory: path_string(cwd)?,
            creator_home: path_string(home)?,
            project_root: root.as_deref().map(path_string).transpose()?,
            entries: Vec::new(),
            warnings: BTreeSet::new(),
            source_digest: None,
        },
        seen: BTreeSet::new(),
        directory_count: 0,
        entry_count: 0,
        deadline: Instant::now() + Duration::from_mins(1),
        heartbeat,
    };
    let configuration_path = home.join(".overalls/config.json");
    let (configuration, configuration_digest) = configuration(&configuration_path)?;
    if let Some(expected) = configuration_digest {
        scan.add(&configuration_path, "configuration", "creator", None)?;
        if scan
            .inventory
            .entries
            .last()
            .is_none_or(|entry| entry.digest != expected)
        {
            return Err(Failure::ContextChanged);
        }
    }
    let fallback = if args.fallback_filenames.is_empty() {
        &configuration.project_instruction_fallback_filenames
    } else {
        &args.fallback_filenames
    };
    scan.instructions(machine, "machine", &[], false)?;
    scan.instructions(&home.join(".overalls"), "creator", &[], false)?;
    let mut directories = vec![cwd.to_owned()];
    if let Some(root) = root {
        directories = cwd
            .ancestors()
            .take_while(|path| path.starts_with(&root))
            .map(Path::to_owned)
            .collect();
        directories.reverse();
    }
    for path in &directories {
        scan.instructions(path, "project", fallback, true)?;
    }
    scan.skills(&machine.join("skills"), "machine")?;
    scan.skills(&home.join(".agents/skills"), "creator")?;
    scan.skills(&home.join(".overalls/skills"), "creator")?;
    for path in directories {
        scan.skills(&path.join(".agents/skills"), "project")?;
    }
    for path in &args.managed_skill_paths {
        scan.skills(Path::new(path), "managed")?;
    }
    // Re-read every selected file before accepting a manifest, catching changes
    // during traversal. Subsequent pages repeat collection and compare its digest.
    for entry in scan.inventory.entries.clone() {
        scan.checkpoint()?;
        if digest(&read(Path::new(&entry.path))?) != entry.digest {
            return Err(Failure::ContextChanged);
        }
    }
    if scan
        .inventory
        .entries
        .iter()
        .map(|entry| entry.bytes)
        .sum::<usize>()
        > 2_097_152
    {
        return Err(Failure::ContextLimit);
    }
    Ok(scan.inventory)
}

fn configuration(path: &Path) -> Result<(Configuration, Option<String>), Failure> {
    let bytes = optional_file(path).map_err(|_| Failure::InvalidConfiguration)?;
    let Some(bytes) = bytes else {
        return Ok((Configuration::default(), None));
    };
    if bytes.len() > 16_384 {
        return Err(Failure::InvalidConfiguration);
    }
    let config: Configuration =
        serde_json::from_slice(&bytes).map_err(|_| Failure::InvalidConfiguration)?;
    let names = &config.project_instruction_fallback_filenames;
    if names.len() > 16 || names.iter().any(|value| !valid_name(value)) {
        return Err(Failure::InvalidConfiguration);
    }
    Ok((config, Some(digest(&bytes))))
}

fn page(inventory: &Inventory, cursor: Option<&Cursor>) -> Result<Value, Failure> {
    let serialized = serde_json::to_vec(&inventory).map_err(|_| Failure::ContextLimit)?;
    let inventory_digest = digest(&serialized);
    let offset = cursor.map_or(0, |c| c.offset);
    if cursor.is_some_and(|c| c.digest != inventory_digest) || offset > inventory.entries.len() {
        return Err(Failure::ContextChanged);
    }
    let mut selected = Vec::new();
    let mut next = offset;
    while next < inventory.entries.len() {
        let entry = &inventory.entries[next];
        selected.push(entry.clone());
        if serde_json::to_vec(&selected)
            .map_err(|_| Failure::ContextLimit)?
            .len()
            > PAGE_LIMIT
        {
            selected.pop();
            break;
        }
        next += 1;
    }
    if selected.is_empty() && next < inventory.entries.len() {
        return Err(Failure::ContextLimit);
    }
    let next_cursor = (next < inventory.entries.len()).then_some(Cursor {
        digest: inventory_digest.clone(),
        offset: next,
    });
    let response = json!({"version":1,"working_directory":inventory.working_directory,"creator_home":inventory.creator_home,"project_root":inventory.project_root,"inventory_digest":inventory_digest,"entries":selected,"next_cursor":next_cursor,"warnings":inventory.warnings});
    if serde_json::to_vec(&response)
        .map_err(|_| Failure::ContextLimit)?
        .len()
        > 10_240
    {
        return Err(Failure::ContextLimit);
    }
    Ok(response)
}

pub(super) fn run_inventory(
    arguments: &Value,
    heartbeat: &mut impl FnMut() -> bool,
) -> Result<Value, Failure> {
    let args: InventoryArguments =
        serde_json::from_value(arguments.clone()).map_err(|_| Failure::InvalidArguments)?;
    if args.version != 1
        || args.fallback_filenames.len() > 16
        || args.fallback_filenames.iter().any(|v| !valid_name(v))
        || args.managed_skill_paths.len() > 64
    {
        return Err(Failure::InvalidArguments);
    }
    if args
        .cursor
        .as_ref()
        .is_some_and(|cursor| !valid_digest(&cursor.digest))
    {
        return Err(Failure::InvalidArguments);
    }
    let home = account_home::resolve(&args.creator_username)?;
    let paths = guest_paths();
    let source_digest = source_digest(&paths)?;
    let cwd = match &args.working_directory {
        Some(path) => directory(Path::new(path))?,
        None => default_working_directory(&paths)?,
    };
    let mut inventory = collect(&args, &home, &cwd, &machine_config(), heartbeat)?;
    if source_digest != self::source_digest(&paths)? {
        return Err(Failure::ContextChanged);
    }
    inventory.source_digest = Some(source_digest);
    page(&inventory, args.cursor.as_ref())
}

fn source_digest(paths: &crate::workspace_receiver::Paths) -> Result<String, Failure> {
    let source = optional_file(&paths.source())?;
    let done = optional_file(&paths.done())?;
    let bytes = serde_json::to_vec(&(source, done)).map_err(|_| Failure::ContextLimit)?;
    Ok(digest(&bytes))
}

/// @cc [owner:ghuntley,label:protocol;recovery] guest-context-digest-chunks
/// A file chunk MUST be bound to the whole-file SHA256 from inventory and an
/// explicit byte offset. No truncation, lossy text conversion or replacement
/// content may be represented as the requested version. Base64 preserves UTF-8
/// split boundaries and keeps a 4096-byte chunk within the executor RPC envelope.
pub(super) fn run_read(arguments: &Value) -> Result<Value, Failure> {
    let args: ReadArguments =
        serde_json::from_value(arguments.clone()).map_err(|_| Failure::InvalidArguments)?;
    if args.version != 1 || !valid_digest(&args.digest) || !(1..=4096).contains(&args.limit) {
        return Err(Failure::InvalidArguments);
    }
    let bytes = read(Path::new(&args.path))?;
    if digest(&bytes) != args.digest || args.offset > bytes.len() {
        return Err(Failure::ContextChanged);
    }
    let end = bytes.len().min(args.offset.saturating_add(args.limit));
    let next_offset = (end < bytes.len()).then_some(end);
    Ok(
        json!({"version":1,"path":args.path,"digest":args.digest,"offset":args.offset,"data_base64":STANDARD.encode(&bytes[args.offset..end]),"next_offset":next_offset,"eof":end==bytes.len()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args() -> InventoryArguments {
        InventoryArguments {
            version: 1,
            creator_username: "u200000".into(),
            working_directory: None,
            fallback_filenames: vec!["PROJECT.md".into()],
            managed_skill_paths: vec![],
            cursor: None,
        }
    }

    #[test]
    fn precedence_empty_override_and_scope_are_explicit() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let machine = temp.path().join("machine");
        let project = temp.path().join("repo");
        let cwd = project.join("nested");
        for path in [
            &home.join(".overalls"),
            &machine,
            &project.join(".git"),
            &cwd,
        ] {
            fs::create_dir_all(path).unwrap();
        }
        fs::write(machine.join("AGENTS.md"), "machine").unwrap();
        fs::write(home.join(".overalls/AGENTS.override.md"), "").unwrap();
        fs::write(home.join(".overalls/AGENTS.md"), "creator").unwrap();
        fs::write(project.join("AGENTS.override.md"), "").unwrap();
        fs::write(project.join("AGENTS.md"), "must be suppressed").unwrap();
        fs::write(cwd.join("PROJECT.md"), "nested").unwrap();
        let inventory = collect(&args(), &home, &cwd, &machine, &mut || true).unwrap();
        assert_eq!(inventory.entries.len(), 4);
        assert_eq!(
            inventory
                .entries
                .iter()
                .map(|entry| entry.scope)
                .collect::<Vec<_>>(),
            ["machine", "creator", "project", "project"]
        );
        assert_eq!(inventory.entries[2].bytes, 0);
        assert!(inventory.entries[3].path.ends_with("PROJECT.md"));
    }

    #[test]
    fn chunks_preserve_bytes_and_refuse_changed_files() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("SKILL.md");
        let bytes = "é".repeat(5000).into_bytes();
        fs::write(&file, &bytes).unwrap();
        let arguments =
            json!({"version":1,"path":file,"digest":digest(&bytes),"offset":4095,"limit":4096});
        let result = run_read(&arguments).unwrap();
        assert_eq!(
            STANDARD
                .decode(result["data_base64"].as_str().unwrap())
                .unwrap(),
            bytes[4095..8191]
        );
        assert_eq!(result["next_offset"], 8191);
        assert_eq!(result["eof"], false);
        assert!(serde_json::to_vec(&result).unwrap().len() < 8192);
        let mut final_arguments = arguments.clone();
        final_arguments["offset"] = json!(8191);
        let final_result = run_read(&final_arguments).unwrap();
        assert_eq!(final_result["eof"], true);
        assert_eq!(final_result["next_offset"], Value::Null);
        fs::write(&file, "changed").unwrap();
        assert_eq!(run_read(&arguments).unwrap_err(), Failure::ContextChanged);
    }

    #[test]
    fn inventory_cursor_detects_changes_and_pages() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let skills = home.join(".agents/skills");
        let cwd = temp.path().join("workspace");
        fs::create_dir_all(&cwd).unwrap();
        for index in 0..60 {
            let skill = skills.join(format!("skill{index:03}"));
            fs::create_dir_all(&skill).unwrap();
            fs::write(skill.join("SKILL.md"), format!("skill {index}")).unwrap();
        }
        let machine = temp.path().join("machine");
        let first = page(
            &collect(&args(), &home, &cwd, &machine, &mut || true).unwrap(),
            None,
        )
        .unwrap();
        let cursor: Cursor = serde_json::from_value(first["next_cursor"].clone()).unwrap();
        assert!(cursor.offset > 0 && cursor.offset < 60);
        let second = page(
            &collect(&args(), &home, &cwd, &machine, &mut || true).unwrap(),
            Some(&cursor),
        )
        .unwrap();
        assert_eq!(second["entries"][0]["position"], cursor.offset);
        fs::write(skills.join("skill000/SKILL.md"), "changed").unwrap();
        assert_eq!(
            page(
                &collect(&args(), &home, &cwd, &machine, &mut || true).unwrap(),
                Some(&cursor)
            )
            .unwrap_err(),
            Failure::ContextChanged
        );
    }

    #[test]
    fn worktree_root_and_lease_loss_are_verified() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("checkout");
        let admin = temp.path().join("admin");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&admin).unwrap();
        fs::write(root.join(".git"), "gitdir: ../admin\n").unwrap();
        assert_eq!(repository_root(&root).unwrap(), Some(root.clone()));
        fs::write(root.join("AGENTS.md"), "guidance").unwrap();
        assert!(matches!(
            collect(&args(), temp.path(), &root, temp.path(), &mut || false),
            Err(Failure::LeaseLost)
        ));
    }

    #[test]
    fn native_configuration_is_bounded_bound_and_drives_fallbacks() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let config = home.join(".overalls/config.json");
        fs::create_dir_all(config.parent().unwrap()).unwrap();
        let cwd = temp.path().join("workspace");
        fs::create_dir_all(&cwd).unwrap();
        fs::write(
            &config,
            r#"{"project_instruction_fallback_filenames":["GUIDANCE.md"]}"#,
        )
        .unwrap();
        fs::write(cwd.join("GUIDANCE.md"), "configured guidance").unwrap();
        let mut request = args();
        request.fallback_filenames.clear();
        let result = collect(
            &request,
            &home,
            &cwd,
            &temp.path().join("machine"),
            &mut || true,
        )
        .unwrap();
        assert_eq!(result.entries[0].kind, "configuration");
        assert!(result.entries[1].path.ends_with("GUIDANCE.md"));
        request.fallback_filenames.push("PROJECT.md".into());
        assert_eq!(
            collect(
                &request,
                &home,
                &cwd,
                &temp.path().join("machine"),
                &mut || true
            )
            .unwrap()
            .entries
            .len(),
            1
        );
        for malformed in [
            r#"{"project_instruction_fallback_filenames":["../outside"]}"#,
            r#"{"unknown":true}"#,
            "not JSON",
        ] {
            fs::write(&config, malformed).unwrap();
            assert!(matches!(
                configuration(&config),
                Err(Failure::InvalidConfiguration)
            ));
        }
        fs::write(&config, " ".repeat(16_385)).unwrap();
        assert!(matches!(
            configuration(&config),
            Err(Failure::InvalidConfiguration)
        ));
    }

    #[test]
    fn default_directory_requires_completed_source_and_tracks_source_identity() {
        let temp = tempfile::tempdir().unwrap();
        let paths = crate::workspace_receiver::Paths::under(temp.path());
        fs::create_dir_all(&paths.workspace).unwrap();
        fs::create_dir_all(&paths.state).unwrap();
        let source =
            crate::workspace_source::parse_url("https://github.com/example/project").unwrap();
        fs::write(
            paths.source(),
            serde_json::to_vec(&source.encode()).unwrap(),
        )
        .unwrap();
        assert_eq!(default_working_directory(&paths).unwrap(), paths.workspace);
        let old_digest = source_digest(&paths).unwrap();
        fs::create_dir_all(paths.checkout(&source).join(".git")).unwrap();
        fs::write(paths.done(), "done\n").unwrap();
        assert_eq!(
            default_working_directory(&paths).unwrap(),
            paths.checkout(&source)
        );
        assert_ne!(source_digest(&paths).unwrap(), old_digest);
        fs::remove_dir_all(paths.checkout(&source)).unwrap();
        assert!(default_working_directory(&paths).is_err());
    }

    #[test]
    fn context_wire_and_file_limits_refuse_incomplete_collection() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("large");
        fs::write(&file, vec![b'x'; FILE_LIMIT + 1]).unwrap();
        assert_eq!(read(&file).unwrap_err(), Failure::ContextLimit);
        for arguments in [
            json!({"version":2,"path":file,"digest":"a".repeat(64),"offset":0,"limit":4096}),
            json!({"version":1,"path":file,"digest":"a".repeat(64),"offset":0,"limit":4097}),
            json!({"version":1,"path":file,"digest":"a".repeat(64),"offset":0,"limit":4096,"extra":true}),
        ] {
            assert_eq!(run_read(&arguments).unwrap_err(), Failure::InvalidArguments);
        }
    }

    #[cfg(unix)]
    #[test]
    fn linked_files_and_cycles_are_not_followed() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("target");
        fs::write(&target, "secret").unwrap();
        let linked = temp.path().join("link");
        std::os::unix::fs::symlink(&target, &linked).unwrap();
        assert_eq!(read(&linked).unwrap_err(), Failure::UnsafePath);
        let home = temp.path().join("home");
        fs::create_dir_all(home.join(".agents/skills")).unwrap();
        std::os::unix::fs::symlink(
            home.join(".agents/skills"),
            home.join(".agents/skills/cycle"),
        )
        .unwrap();
        let inventory = collect(
            &args(),
            &home,
            temp.path(),
            &temp.path().join("machine"),
            &mut || true,
        )
        .unwrap();
        assert!(inventory.warnings.contains("skill_link_skipped"));
    }
}
