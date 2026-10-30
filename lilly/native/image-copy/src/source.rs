use crate::{read_only_filesystem, Error, Identity, Method, SourcePolicy};
use rustix::fs::{flock, open, FlockOperation, Mode as FileMode, OFlags};
use rustix::io::Errno;
use std::fs::{File, Metadata};
use std::os::fd::OwnedFd;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

fn source(path: &Path) -> Result<(File, Metadata), Error> {
    checked_source(path, SourcePolicy::Image, read_only_filesystem)
}

pub(crate) fn checked_source(
    path: &Path,
    policy: SourcePolicy,
    read_only: impl FnOnce(&File) -> Result<bool, Errno>,
) -> Result<(File, Metadata), Error> {
    let descriptor = open(
        path,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        FileMode::empty(),
    )
    .map_err(|_| Error::Source)?;
    let file = File::from(descriptor);
    let metadata = file.metadata().map_err(|_| Error::Source)?;
    let acceptable = match policy {
        SourcePolicy::Image => {
            metadata.uid() == rustix::process::geteuid().as_raw() && metadata.mode() & 0o222 == 0
        }
        SourcePolicy::Snapshot { uid } => {
            metadata.uid() == uid
                && metadata.nlink() == 1
                && read_only(&file).map_err(|_| Error::Source)?
        }
    };
    if !metadata.is_file() || !acceptable {
        return Err(Error::Source);
    }
    Ok((file, metadata))
}

pub fn identity(path: &Path) -> Result<Identity, Error> {
    let (_file, metadata) = source(path)?;
    if metadata.nlink() != 1 {
        return Err(Error::Source);
    }
    Identity::read(&metadata)
}

pub(crate) fn with_source_lease(
    lease: &Path,
    copy: impl FnOnce() -> Result<Method, Error>,
) -> Result<Method, Error> {
    let _lease = source_lease(lease)?;
    copy()
}

pub(crate) fn source_lease(path: &Path) -> Result<OwnedFd, Error> {
    let descriptor = open(
        path,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        FileMode::empty(),
    )
    .map_err(|_| Error::Lease)?;
    let file = File::from(descriptor);
    let metadata = file.metadata().map_err(|_| Error::Lease)?;
    // A private lock: this process's uid, or the owner of the directory that
    // holds it (Lilly's service uid when it runs unprivileged, ADR-0182).
    let directory_owner = path
        .parent()
        .and_then(|parent| std::fs::symlink_metadata(parent).ok())
        .filter(std::fs::Metadata::is_dir)
        .map(|parent| parent.uid());
    let owner = metadata.uid();
    if !metadata.is_file()
        || (owner != rustix::process::geteuid().as_raw() && Some(owner) != directory_owner)
        || metadata.mode() & 0o777 != 0o600
        || metadata.nlink() != 1
    {
        return Err(Error::Lease);
    }
    flock(&file, FlockOperation::NonBlockingLockShared).map_err(|_| Error::Lease)?;
    Ok(file.into())
}
