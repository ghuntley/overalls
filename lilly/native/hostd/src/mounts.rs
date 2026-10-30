//! Native bind mounts and unmounts for jails, and the one accepted shape of a
//! read-only ZFS snapshot mount (ADR-0176 decision 4).
//!
//! Paths are opened beneath the file roots with `openat2(RESOLVE_BENEATH |
//! RESOLVE_NO_SYMLINKS)`; the mount system calls then name the opened file as
//! `/proc/self/fd/N`, so a path the caller controls cannot be swapped for a
//! symlink between the check and the effect.

use crate::protocol::{valid_directory, Status};
use crate::utilities::Utility;
use rustix::fs::{openat2, Mode, OFlags, ResolveFlags};
use rustix::mount::{mount, mount_bind, mount_remount, unmount, MountFlags, UnmountFlags};
use std::ffi::{CString, OsStr};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Whether hostd performs this mount request natively (bind, remount, umount).
pub fn native(utility: Utility, argv: &[CString]) -> bool {
    match utility {
        Utility::Umount => true,
        Utility::Mount => !argv.is_empty(),
        _ => false,
    }
}

fn open(roots: &[PathBuf], path: &[u8]) -> Option<OwnedFd> {
    open_beneath(roots, path, false)
}

/// A directory beneath (or equal to) one of the roots.
fn open_directory(roots: &[PathBuf], path: &[u8]) -> Option<OwnedFd> {
    open_beneath(roots, path, true)
}

fn open_beneath(roots: &[PathBuf], path: &[u8], allow_root: bool) -> Option<OwnedFd> {
    if !valid_directory(path) {
        return None;
    }
    let path = Path::new(OsStr::from_bytes(path));
    let root = roots
        .iter()
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.as_os_str().len())?;
    let relative = path.strip_prefix(root).ok()?;
    if relative.as_os_str().is_empty() && !allow_root {
        return None;
    }
    let relative = if relative.as_os_str().is_empty() {
        Path::new(".")
    } else {
        relative
    };
    let base = rustix::fs::open(
        root,
        OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    openat2(
        &base,
        relative,
        OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
        ResolveFlags::BENEATH | ResolveFlags::NO_SYMLINKS | ResolveFlags::NO_MAGICLINKS,
    )
    .ok()
}

fn proc_path(file: &OwnedFd) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

/// @cc [owner:ghuntley,label:security] native-jail-mounts-beneath-roots
/// perform MUST accept only `mount --bind -- SRC TGT`,
/// `mount -o remount,bind,nosuid,nodev,noexec,(ro|rw) -- TGT`,
/// `mount -t zfs -o ro,nodev,nosuid,noexec DATASET@SNAPSHOT TGT` and
/// `umount -- TGT`, with every path a normalised absolute path strictly
/// beneath one of `roots`, opened without following symlinks; the mount
/// calls name the opened descriptors, never the caller's path. Anything else
/// is Setup with no effect; a failed system call is Failed.
pub fn perform(utility: Utility, argv: &[CString], roots: &[PathBuf]) -> Status {
    let argv: Vec<&[u8]> = argv.iter().map(CString::as_bytes).collect();
    let result = match (utility, argv.as_slice()) {
        (Utility::Mount, [b"--bind", b"--", source, target]) => {
            let (Some(source), Some(target)) = (open(roots, source), open(roots, target)) else {
                return Status::Setup;
            };
            mount_bind(proc_path(&source), proc_path(&target))
        }
        (Utility::Mount, [b"-o", options, b"--", target]) => {
            let flags = match *options {
                b"remount,bind,nosuid,nodev,noexec,ro" => MountFlags::RDONLY,
                b"remount,bind,nosuid,nodev,noexec,rw" => MountFlags::empty(),
                _ => return Status::Setup,
            };
            let Some(target) = open(roots, target) else {
                return Status::Setup;
            };
            mount_remount(
                proc_path(&target),
                MountFlags::BIND
                    | MountFlags::NOSUID
                    | MountFlags::NODEV
                    | MountFlags::NOEXEC
                    | flags,
                "",
            )
        }
        (Utility::Mount, [b"-t", b"zfs", b"-o", b"ro,nodev,nosuid,noexec", snapshot, target]) => {
            if !snapshot_name(snapshot) {
                return Status::Setup;
            }
            let Some(target) = open(roots, target) else {
                return Status::Setup;
            };
            let Ok(source) = std::str::from_utf8(snapshot) else {
                return Status::Setup;
            };
            mount(
                source,
                proc_path(&target),
                "zfs",
                MountFlags::RDONLY | MountFlags::NODEV | MountFlags::NOSUID | MountFlags::NOEXEC,
                None,
            )
        }
        (Utility::Umount, [b"--", target]) => {
            // Open the mount point's parent, not the mount point: a descriptor
            // on the mounted file would keep it busy (EBUSY).
            let target_path = Path::new(OsStr::from_bytes(target));
            let (Some(parent), Some(name)) = (
                target_path
                    .parent()
                    .and_then(|parent| open_directory(roots, parent.as_os_str().as_bytes())),
                target_path.file_name(),
            ) else {
                return Status::Setup;
            };
            unmount(proc_path(&parent).join(name), UnmountFlags::NOFOLLOW)
        }
        _ => return Status::Setup,
    };
    match result {
        Ok(()) => Status::Succeeded,
        Err(_) => Status::Failed,
    }
}

/// @cc [owner:ghuntley,label:security] snapshot-mount-shape
/// A `mount -t zfs` request MUST be exactly
/// `-t zfs -o ro,nodev,nosuid,noexec DATASET@SNAPSHOT TARGET`, with a ZFS
/// snapshot name and a normalised absolute target strictly beneath one of
/// `roots`. hostd performs the mount itself on the target's descriptor
/// (`perform`); this predicate states the accepted shape.
pub fn snapshot_mount_allowed(argv: &[CString], roots: &[PathBuf]) -> bool {
    let argv: Vec<&[u8]> = argv.iter().map(CString::as_bytes).collect();
    match argv.as_slice() {
        [b"-t", b"zfs", b"-o", b"ro,nodev,nosuid,noexec", snapshot, target] => {
            snapshot_name(snapshot) && valid_directory(target) && {
                let target = Path::new(OsStr::from_bytes(target));
                roots
                    .iter()
                    .any(|root| target.starts_with(root) && target != root)
            }
        }
        _ => false,
    }
}

fn snapshot_name(name: &[u8]) -> bool {
    let Some(at) = name.iter().position(|byte| *byte == b'@') else {
        return false;
    };
    let (dataset, snapshot) = (&name[..at], &name[at + 1..]);
    let component = |part: &[u8]| {
        !part.is_empty()
            && part
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_.:-".contains(byte))
    };
    name.len() <= 255
        && dataset.split(|byte| *byte == b'/').count() >= 2
        && dataset.split(|byte| *byte == b'/').all(component)
        && component(snapshot)
}
