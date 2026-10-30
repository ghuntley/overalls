use crate::source::{checked_source, with_source_lease};
use crate::{
    offload_unsupported, read_only_filesystem, unsupported, Error, Identity, Method, Mode,
    SourcePolicy,
};
use rustix::fs::{copy_file_range, ioctl_ficlone, open, seek, Mode as FileMode, OFlags, SeekFrom};
use rustix::io::Errno;
use std::fs::File;
use std::io;
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::Path;

/// @cc [owner:ghuntley,label:durability;isolation] independent-image-materialization
/// Materialization MUST exclusively create an independent destination and never
/// follow a leaf symlink or overwrite an existing file. Verify source shape,
/// owner and bounded size before creation; recheck its full identity and sync
/// the destination before success. Callers hold native ownership, validate
/// ancestors and publish by rename. Failed temporary files remain caller-owned.
pub fn materialize(
    mode: Mode,
    source_path: &Path,
    destination: &Path,
    size: u64,
) -> Result<Method, Error> {
    materialize_with(
        mode,
        source_path,
        destination,
        size,
        SourcePolicy::Image,
        read_only_filesystem,
        |target, source| ioctl_ficlone(target, source),
        |target, source, offset, length| {
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    )
}

/// @cc [owner:ghuntley,label:recovery;concurrency] copy-child-retains-source-lease
/// A leased copy MUST acquire the existing private, single-link native lease
/// inode without following symlinks or creating files. Its independent shared
/// descriptor MUST remain held through source verification and destination sync,
/// even if the caller's template lease closes. The caller independently delegates
/// the child to its placement lock owner to retain destination fencing.
pub fn materialize_leased(
    mode: Mode,
    source: &Path,
    destination: &Path,
    size: u64,
    lease: &Path,
) -> Result<Method, Error> {
    with_source_lease(lease, || materialize(mode, source, destination, size))
}

/// Materialize a same-pool clone disk from a read-only snapshot mount (ADR-0145):
/// the same exclusive, verified and synced destination rules as images, with the
/// snapshot source policy for the exact expected guest uid.
pub fn materialize_snapshot(
    source_path: &Path,
    destination: &Path,
    size: u64,
    uid: u32,
) -> Result<Method, Error> {
    materialize_with(
        Mode::Auto,
        source_path,
        destination,
        size,
        SourcePolicy::Snapshot { uid },
        read_only_filesystem,
        |target, source| ioctl_ficlone(target, source),
        |target, source, offset, length| {
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn materialize_with(
    mode: Mode,
    source_path: &Path,
    destination: &Path,
    size: u64,
    policy: SourcePolicy,
    read_only: impl FnOnce(&File) -> Result<bool, Errno>,
    clone: impl FnOnce(&File, &File) -> Result<(), Errno>,
    offload: impl FnMut(&File, &File, u64, usize) -> Result<usize, Errno>,
) -> Result<Method, Error> {
    if !(1..=policy.max_bytes()).contains(&size) {
        return Err(Error::Arguments);
    }
    let (source, metadata) = checked_source(source_path, policy, read_only)?;
    if metadata.len() != size {
        return Err(Error::Source);
    }
    let before = Identity::read(&metadata)?;
    let target = File::from(
        open(
            destination,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::CLOEXEC | OFlags::NOFOLLOW,
            FileMode::from_raw_mode(0o600),
        )
        .map_err(|_| Error::Destination)?,
    );
    let method = match mode {
        Mode::Copy => Method::Copy,
        Mode::Auto => match clone(&target, &source) {
            Ok(()) => Method::Reflink,
            Err(error) if unsupported(error) => offload_range(&source, &target, size, offload)?,
            Err(_) => return Err(Error::Clone),
        },
    };
    if method == Method::Copy {
        sparse_copy(&source, &target, size).map_err(|_| Error::Copy)?;
    }
    let after = source.metadata().map_err(|_| Error::Changed)?;
    let target_metadata = target.metadata().map_err(|_| Error::Changed)?;
    if Identity::read(&after)? != before
        || !target_metadata.is_file()
        || target_metadata.len() != size
        || target_metadata.nlink() != 1
    {
        return Err(Error::Changed);
    }
    target.sync_all().map_err(|_| Error::Sync)?;
    Ok(method)
}

/// @cc [owner:ghuntley,label:performance;durability] image-copy-source-extents
/// Copies MUST transfer only the source's data extents as reported by
/// `lseek(SEEK_DATA)`/`lseek(SEEK_HOLE)` and leave every hole a hole: the
/// destination is sized to the source length after the extents are written.
/// A filesystem that cannot report holes (`EINVAL`) is one data extent from 0
/// to the size; extents MUST be ascending, non-empty and inside the size, and
/// any other seek failure fails the copy. A 64 GiB sparse Windows disk with
/// 22 GB of data then moves 22 GB, not 64 GiB (ADR-0173).
pub(crate) fn data_extents(source: &File, size: u64) -> Result<Vec<(u64, u64)>, Error> {
    let mut extents = Vec::new();
    let mut offset = 0_u64;
    while offset < size {
        let start = match seek(source, SeekFrom::Data(offset)) {
            Ok(start) => start,
            Err(Errno::NXIO) => break,
            Err(Errno::INVAL) if offset == 0 => return Ok(vec![(0, size)]),
            Err(_) => return Err(Error::Copy),
        };
        if start >= size {
            break;
        }
        if start < offset {
            return Err(Error::Copy);
        }
        let end = match seek(source, SeekFrom::Hole(start)) {
            Ok(end) => end.min(size),
            Err(_) => return Err(Error::Copy),
        };
        if end <= start {
            return Err(Error::Copy);
        }
        extents.push((start, end));
        offset = end;
    }
    Ok(extents)
}

/// @cc [owner:ghuntley,label:performance;durability] image-copy-kernel-offload
/// When whole-file cloning is unsupported (e.g. FICLONE across mounts), kernel
/// copy offload MUST be attempted before userspace copying so filesystems such
/// as ZFS can share blocks across datasets. Only an unsupported refusal before
/// any byte is transferred may fall back; a partial transfer, short read or
/// repeated interruption or any other error MUST fail without publishing the
/// destination.
fn offload_range(
    source: &File,
    target: &File,
    size: u64,
    mut offload: impl FnMut(&File, &File, u64, usize) -> Result<usize, Errno>,
) -> Result<Method, Error> {
    const WINDOW: u64 = 1 << 30;
    const INTERRUPTS: u32 = 16;
    let mut transferred = 0_u64;
    for (start, end) in data_extents(source, size)? {
        let (mut offset, mut interrupts) = (start, 0_u32);
        while offset < end {
            let length = usize::try_from((end - offset).min(WINDOW)).map_err(|_| Error::Copy)?;
            match offload(target, source, offset, length) {
                Ok(0) => return Err(Error::Copy),
                Ok(count) if count as u64 <= end - offset => {
                    offset += count as u64;
                    transferred += count as u64;
                    interrupts = 0;
                }
                Ok(_) => return Err(Error::Copy),
                Err(Errno::INTR) if interrupts < INTERRUPTS => interrupts += 1,
                Err(error) if transferred == 0 && offload_unsupported(error) => {
                    return Ok(Method::Copy)
                }
                Err(_) => return Err(Error::Copy),
            }
        }
    }
    target.set_len(size).map_err(|_| Error::Copy)?;
    Ok(Method::Offload)
}

fn sparse_copy(source: &File, target: &File, size: u64) -> io::Result<()> {
    let mut buffer = vec![0_u8; 1024 * 1024];
    let extents = data_extents(source, size).map_err(|_| io::Error::other("source extents"))?;
    for (start, end) in extents {
        let mut offset = start;
        while offset < end {
            let count = usize::try_from((end - offset).min(buffer.len() as u64))
                .map_err(|_| io::ErrorKind::InvalidInput)?;
            let count = match source.read_at(&mut buffer[..count], offset) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                other => other?,
            };
            if count == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            if buffer[..count].iter().any(|byte| *byte != 0) {
                target.write_all_at(&buffer[..count], offset)?;
            }
            offset += count as u64;
        }
    }
    target.set_len(size)
}
