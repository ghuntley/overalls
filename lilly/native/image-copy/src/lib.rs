#![forbid(unsafe_code)]

mod materialize;
mod source;

pub use materialize::{materialize, materialize_leased, materialize_snapshot};
pub use source::identity;

use rustix::fs::{fstatvfs, StatVfsMountFlags};
use rustix::io::Errno;
use std::fs::{File, Metadata};
use std::os::unix::fs::MetadataExt;

pub const MAX_BYTES: u64 = 137_438_953_472;
/// Largest guest disk (OverallsProtocol.VmShape.maximum_disk_bytes).
pub const SNAPSHOT_MAX_BYTES: u64 = 536_870_912_000;

/// @cc [owner:ghuntley,label:security;isolation] image-helper-snapshot-source
/// Image sources MUST be root-owned and unwritable. Snapshot sources (same-pool
/// clone copies, ADR-0145) MUST be single-link regular files owned by the exact
/// expected guest uid on a filesystem that reports itself read-only, bounded by
/// the maximum guest disk size. No other source shape is accepted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourcePolicy {
    Image,
    Snapshot { uid: u32 },
}

impl SourcePolicy {
    fn max_bytes(self) -> u64 {
        match self {
            Self::Image => MAX_BYTES,
            Self::Snapshot { .. } => SNAPSHOT_MAX_BYTES,
        }
    }
}

fn read_only_filesystem(file: &File) -> Result<bool, Errno> {
    Ok(fstatvfs(file)?.f_flag.contains(StatVfsMountFlags::RDONLY))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Mode {
    Auto,
    Copy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Method {
    Reflink,
    Offload,
    Copy,
}

impl Method {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Reflink => "reflink",
            Self::Offload => "offload",
            Self::Copy => "copy",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Arguments,
    Source,
    Destination,
    Clone,
    Copy,
    Changed,
    Sync,
    Lease,
}

/// @cc [owner:ghuntley,label:security] native-artifact-nanosecond-identity
/// Identity MUST include file descriptor device, inode, size, mode, owner, links
/// and nanosecond modification/change timestamps. Access time MUST be excluded.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Identity(pub [u64; 11]);

impl Identity {
    fn read(metadata: &Metadata) -> Result<Self, Error> {
        let nonnegative = |value: i64| u64::try_from(value).map_err(|_| Error::Source);
        Ok(Self([
            metadata.dev(),
            metadata.ino(),
            metadata.size(),
            u64::from(metadata.mode()),
            u64::from(metadata.uid()),
            u64::from(metadata.gid()),
            metadata.nlink(),
            nonnegative(metadata.mtime())?,
            nonnegative(metadata.mtime_nsec())?,
            nonnegative(metadata.ctime())?,
            nonnegative(metadata.ctime_nsec())?,
        ]))
    }
}

pub fn parse_snapshot_size(value: &str) -> Result<u64, Error> {
    parse_bounded(value, SNAPSHOT_MAX_BYTES)
}

pub fn parse_size(value: &str) -> Result<u64, Error> {
    parse_bounded(value, MAX_BYTES)
}

fn parse_bounded(value: &str, max: u64) -> Result<u64, Error> {
    if value.is_empty() || value.starts_with('0') || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::Arguments);
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|size| (1..=max).contains(size))
        .ok_or(Error::Arguments)
}

/// @cc [owner:ghuntley,label:security;recovery] image-copy-fallback-allowlist
/// Only EXDEV, ENOTTY and EOPNOTSUPP permit the next copy strategy (ENOSYS
/// additionally for kernel copy offload). I/O, permissions, space/quota
/// exhaustion, malformed requests and unknown errors MUST fail.
pub fn unsupported(error: Errno) -> bool {
    matches!(error, Errno::XDEV | Errno::NOTTY | Errno::OPNOTSUPP)
}

fn offload_unsupported(error: Errno) -> bool {
    unsupported(error) || error == Errno::NOSYS
}

#[cfg(test)]
mod tests;
