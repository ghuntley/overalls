use rustix::fs::{open, Mode as FileMode, OFlags};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// @cc [owner:ghuntley,label:security] boot-log-private-to-its-reader
/// `open_log` MUST write only through a descriptor opened without following a
/// final symlink onto a single-link regular file of mode 0600 owned by the
/// writer's euid or by `reader`; any other inode is refused. With a reader,
/// the file MUST then belong to that uid, changed through the same descriptor
/// and re-verified, so no other user can read console bytes and the writer
/// never writes into a file it has not proven private.
pub(crate) fn open_log(path: &Path, reader: Option<u32>) -> Result<std::fs::File, ()> {
    let fd = open(
        path,
        OFlags::WRONLY | OFlags::CREATE | OFlags::TRUNC | OFlags::NOFOLLOW,
        FileMode::from_raw_mode(0o600),
    )
    .map_err(|_| ())?;
    let file: std::fs::File = fd.into();
    let euid = rustix::process::geteuid().as_raw();
    let private = |metadata: &std::fs::Metadata, owners: &[Option<u32>]| {
        metadata.is_file()
            && metadata.nlink() == 1
            && owners.contains(&Some(metadata.uid()))
            && metadata.mode() & 0o777 == 0o600
    };
    let metadata = file.metadata().map_err(|_| ())?;
    if !private(&metadata, &[Some(euid), reader]) {
        return Err(());
    }
    match reader {
        Some(uid) if metadata.uid() != uid => {
            std::os::unix::fs::fchown(&file, Some(uid), None).map_err(|_| ())?;
            let handed = file.metadata().map_err(|_| ())?;
            if private(&handed, &[reader]) {
                Ok(file)
            } else {
                Err(())
            }
        }
        _ => Ok(file),
    }
}
