//! Owner-checked directories and files, the installation lock, receipts and
//! durable moves.

use super::validate::{checkpoint, sha256};
use super::{Failure, Receipt, Result, MAX_FILES, MAX_RECEIPT};
use fs2::FileExt;
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

pub(super) fn secure_directory(path: &Path) -> Result<()> {
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
pub(super) fn check_ancestors(path: &Path) -> Result<()> {
    for part in path.ancestors() {
        let metadata = fs::symlink_metadata(part).map_err(|_| Failure("storage_failed"))?;
        if linked(&metadata) {
            return Err(Failure("unsafe_path"));
        }
    }
    Ok(())
}
pub(super) fn linked(metadata: &fs::Metadata) -> bool {
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
pub(super) fn regular_file(path: &Path, max: u64) -> Result<File> {
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
pub(super) fn create_file(path: &Path) -> Result<File> {
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
pub(super) struct InstallationLock(pub(super) File);
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
pub(super) fn lock_installation(path: &Path) -> Result<InstallationLock> {
    let target = path.join("lock");
    if !target.try_exists().map_err(|_| Failure("storage_failed"))? {
        drop(create_file(&target)?);
    }
    let file = regular_file(&target, 0)?;
    file.try_lock_exclusive()
        .map_err(|_| Failure("operation_in_progress"))?;
    Ok(InstallationLock(file))
}
pub(super) fn read_receipt(path: &Path) -> Result<Receipt> {
    let reader = regular_file(path, MAX_RECEIPT)?.take(MAX_RECEIPT + 1);
    let receipt: Receipt =
        serde_json::from_reader(reader).map_err(|_| Failure("invalid_receipt"))?;
    if receipt.version != 1 || !sha256(&receipt.request_digest) {
        return Err(Failure("invalid_receipt"));
    }
    Ok(receipt)
}
pub(super) fn write_receipt(
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
pub(super) fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|_| Failure("storage_failed"))
}
#[cfg(windows)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Windows has no directory fsync; the Unix variant shares the signature"
)]
pub(super) fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
pub(super) fn move_path(source: &Path, target: &Path, _replace: bool) -> Result<()> {
    fs::rename(source, target).map_err(|_| Failure("storage_failed"))
}
#[cfg(windows)]
pub(super) fn move_path(source: &Path, target: &Path, replace: bool) -> Result<()> {
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let flags = MOVEFILE_WRITE_THROUGH
        | if replace {
            MOVEFILE_REPLACE_EXISTING
        } else {
            0
        };
    // Both paths are validated native paths; no caller-controlled flags are
    // accepted.
    if crate::sys::windows::fs::move_file(source, target, flags) {
        Ok(())
    } else {
        Err(Failure("storage_failed"))
    }
}
pub(super) fn sync_tree_directories(root: &Path) -> Result<()> {
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

pub(super) fn verify_revision_path(installation: &Path, path: &Path) -> Result<()> {
    let relative = path
        .strip_prefix(installation.join("revisions"))
        .map_err(|_| Failure("unsafe_path"))?;
    if relative.components().count() != 1 || !relative.to_str().is_some_and(sha256) {
        return Err(Failure("unsafe_path"));
    }
    check_ancestors(path)
}
