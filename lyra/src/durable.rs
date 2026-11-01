//! Durable replacement by rename, for state that must survive a crash.
//!
//! Unix makes a rename durable by fsyncing the parent directory. Windows cannot
//! flush a directory handle (an `FlushFileBuffers` on a directory opened for
//! reading fails with access denied), so it uses `MoveFileExW` with
//! `MOVEFILE_WRITE_THROUGH`, which returns only after the move is on disk.

use std::io;
use std::path::Path;

/// @cc [owner:ghuntley,label:recovery] durable-rename
/// `rename` MUST move `from` onto `to` (replacing an existing file) and return
/// only once the new name is durable: after the parent directory's fsync on
/// Unix, after a write-through move on Windows. Failure leaves `from` in place.
pub fn rename(from: &Path, to: &Path) -> io::Result<()> {
    platform_rename(from, to)
}

#[cfg(unix)]
fn platform_rename(from: &Path, to: &Path) -> io::Result<()> {
    std::fs::rename(from, to)?;
    let parent = to
        .parent()
        .ok_or_else(|| io::Error::other("rename target has no parent"))?;
    std::fs::File::open(parent)?.sync_all()
}

#[cfg(windows)]
fn platform_rename(from: &Path, to: &Path) -> io::Result<()> {
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    if !crate::sys::windows::fs::move_file(
        from,
        to,
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
    ) {
        return Err(crate::platform::windows::last_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::rename;

    #[test]
    fn replaces_the_target_and_removes_the_source() {
        let directory = tempfile::tempdir().unwrap();
        let from = directory.path().join("next");
        let to = directory.path().join("current");
        std::fs::write(&to, b"old").unwrap();
        std::fs::write(&from, b"new").unwrap();
        rename(&from, &to).unwrap();
        assert_eq!(std::fs::read(&to).unwrap(), b"new");
        assert!(!from.exists());
    }

    #[test]
    fn a_failed_rename_leaves_the_source() {
        let directory = tempfile::tempdir().unwrap();
        let from = directory.path().join("next");
        std::fs::write(&from, b"new").unwrap();
        assert!(rename(&from, &directory.path().join("missing").join("current")).is_err());
        assert!(from.exists());
    }
}
