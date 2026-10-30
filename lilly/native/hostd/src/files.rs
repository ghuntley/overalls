//! Native file effects (ADR-0176 decision 4): hostd performs `chmod`, `chown`,
//! `mv`, `rm`, `truncate`, `mkfifo` and `sync` itself, on descriptors resolved
//! beneath configured roots, instead of running the utility with Lilly's argv.
//!
//! Lilly keeps calling these utilities by name with the few argument shapes
//! it has always used; anything else is refused. Every path is resolved with
//! `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)`
//! from an open root, and the final component is never followed, so a
//! directory the caller controls cannot redirect an effect elsewhere.

use crate::protocol::{valid_directory, Status};
use crate::utilities::Utility;
use rustix::fs::{
    fchmod, fstat, fsync, ftruncate, mknodat, openat, openat2, renameat, renameat_with, statat,
    unlinkat, AtFlags, Dir, FileType, Mode, OFlags, RenameFlags, ResolveFlags,
};
use rustix::io::Errno;
use rustix::process::{Gid, Uid};
use std::ffi::{CStr, CString, OsStr};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Modes Lilly sets on files and directories it publishes.
const MODES: [u32; 4] = [0o400, 0o444, 0o600, 0o700];
/// Largest size `truncate` may set (sparse disks up to 16 TiB).
const MAX_SIZE: u64 = 16 << 40;

/// Ownership policy for `chown`.
#[derive(Debug)]
pub struct Owners {
    /// The uid Lilly's state belongs to (its service user).
    pub service: u32,
}

/// Whether hostd performs this utility natively.
pub fn native(utility: Utility) -> bool {
    matches!(
        utility,
        Utility::Chmod
            | Utility::Chown
            | Utility::Mv
            | Utility::Rm
            | Utility::Truncate
            | Utility::Mkfifo
            | Utility::Sync
    )
}

fn arguments(arguments: &[CString]) -> Vec<&[u8]> {
    arguments.iter().map(CString::as_bytes).collect()
}

/// @cc [owner:ghuntley,label:security] native-file-effects-beneath-roots
/// perform MUST accept only these argument shapes, every path a normalised
/// absolute path beneath one of `roots`, and MUST otherwise return Setup
/// without touching the file system:
/// `chmod MODE -- P` (MODE one of 0400, 0444, 0600, 0700),
/// `chown [--no-dereference] U:G -- P` (U equal to G, in the VM range or the service uid),
/// `mv [--no-clobber] --no-target-directory -- A B`,
/// `rm [--force] -- P`, `rm -rf --one-file-system -- P`,
/// `truncate --size N -- P`, `mkfifo --mode=0600 -- P`, `sync -- P...`
/// (sync, which only flushes, accepts any normalised absolute path).
/// Every path is resolved from an open root with `RESOLVE_BENEATH` and
/// `RESOLVE_NO_SYMLINKS`, and the final component is never followed.
/// Success is Succeeded with empty output; a refused or failed effect is
/// Failed, matching the utility's nonzero exit.
pub fn perform(utility: Utility, argv: &[CString], roots: &[PathBuf], owners: &Owners) -> Status {
    let argv = arguments(argv);
    let result = match (utility, argv.as_slice()) {
        (Utility::Chmod, [mode, b"--", path]) => {
            match std::str::from_utf8(mode)
                .ok()
                .and_then(|m| u32::from_str_radix(m, 8).ok())
            {
                Some(mode) if MODES.contains(&mode) => chmod(roots, path, mode),
                _ => return Status::Setup,
            }
        }
        (Utility::Chown, [owner, b"--", path] | [b"--no-dereference", owner, b"--", path]) => {
            match owner_ids(owner, owners) {
                Some(id) => chown(roots, path, id),
                None => return Status::Setup,
            }
        }
        (Utility::Mv, [b"--no-target-directory", b"--", from, to]) => {
            rename(roots, from, to, false)
        }
        (Utility::Mv, [b"--no-clobber", b"--no-target-directory", b"--", from, to]) => {
            rename(roots, from, to, true)
        }
        (Utility::Rm, [b"--", path]) => remove(roots, path, false),
        (Utility::Rm, [b"--force", b"--", path]) => remove(roots, path, true),
        (Utility::Rm, [b"-rf", b"--one-file-system", b"--", path]) => remove_tree(roots, path),
        (Utility::Truncate, [b"--size", size, b"--", path]) => {
            match std::str::from_utf8(size)
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
            {
                Some(size) if size <= MAX_SIZE => truncate(roots, path, size),
                _ => return Status::Setup,
            }
        }
        (Utility::Mkfifo, [b"--mode=0600", b"--", path]) => mkfifo(roots, path),
        // sync only flushes; Lilly syncs private state wherever it keeps it,
        // so any normalised absolute path is accepted (still never followed).
        (Utility::Sync, [b"--", paths @ ..]) if !paths.is_empty() && paths.len() <= 8 => {
            let everywhere = [PathBuf::from("/")];
            paths.iter().try_for_each(|path| sync(&everywhere, path))
        }
        _ => return Status::Setup,
    };
    match result {
        Ok(()) => Status::Succeeded,
        Err(Failure::Policy) => Status::Setup,
        Err(Failure::Effect) => Status::Failed,
    }
}

enum Failure {
    /// The request is outside policy (path, shape).
    Policy,
    /// The effect itself failed.
    Effect,
}

impl From<Errno> for Failure {
    fn from(_: Errno) -> Failure {
        Failure::Effect
    }
}

type Outcome = Result<(), Failure>;

fn owner_ids(owner: &[u8], owners: &Owners) -> Option<u32> {
    let text = std::str::from_utf8(owner).ok()?;
    let (uid, gid) = text.split_once(':')?;
    let (uid, gid): (u32, u32) = (uid.parse().ok()?, gid.parse().ok()?);
    (uid == gid && (crate::vm_launch::JAIL_UIDS.contains(&uid) || uid == owners.service))
        .then_some(uid)
}

/// The root containing `path` (the longest matching one) and the path
/// relative to it; None outside every root or for a non-normalised path.
fn locate<'a>(roots: &[PathBuf], path: &'a [u8]) -> Option<(PathBuf, &'a Path)> {
    if !valid_directory(path) {
        return None;
    }
    let path = Path::new(OsStr::from_bytes(path));
    let root = roots
        .iter()
        .filter(|root| path.starts_with(root))
        .max_by_key(|root| root.as_os_str().len())?;
    Some((root.clone(), path.strip_prefix(root).ok()?))
}

fn open_root(root: &Path) -> Result<OwnedFd, Failure> {
    rustix::fs::open(
        root,
        OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| Failure::Effect)
}

fn beneath(base: &OwnedFd, relative: &Path, flags: OFlags) -> Result<OwnedFd, Failure> {
    let relative = if relative.as_os_str().is_empty() {
        Path::new(".")
    } else {
        relative
    };
    openat2(
        base,
        relative,
        flags | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
        ResolveFlags::BENEATH | ResolveFlags::NO_SYMLINKS | ResolveFlags::NO_MAGICLINKS,
    )
    .map_err(Failure::from)
}

/// The directory holding `path`'s final component, and that component.
fn parent(roots: &[PathBuf], path: &[u8]) -> Result<(OwnedFd, CString), Failure> {
    let (root, relative) = locate(roots, path).ok_or(Failure::Policy)?;
    let name = relative.file_name().ok_or(Failure::Policy)?;
    let base = open_root(&root)?;
    let directory = beneath(
        &base,
        relative.parent().unwrap_or(Path::new("")),
        OFlags::PATH | OFlags::DIRECTORY,
    )?;
    Ok((
        directory,
        CString::new(name.as_bytes()).map_err(|_| Failure::Policy)?,
    ))
}

/// Open `path` itself (never following its final component).
fn open(roots: &[PathBuf], path: &[u8], flags: OFlags) -> Result<OwnedFd, Failure> {
    let (root, relative) = locate(roots, path).ok_or(Failure::Policy)?;
    let base = open_root(&root)?;
    beneath(&base, relative, flags)
}

fn chmod(roots: &[PathBuf], path: &[u8], mode: u32) -> Outcome {
    let file = open(roots, path, OFlags::RDONLY | OFlags::NONBLOCK)?;
    fchmod(&file, Mode::from_raw_mode(mode))?;
    Ok(())
}

fn chown(roots: &[PathBuf], path: &[u8], id: u32) -> Outcome {
    let (directory, name) = parent(roots, path)?;
    // Never follow the final component: a symlink is changed itself.
    rustix::fs::chownat(
        &directory,
        name.as_c_str(),
        Some(Uid::from_raw(id)),
        Some(Gid::from_raw(id)),
        AtFlags::SYMLINK_NOFOLLOW,
    )?;
    Ok(())
}

fn rename(roots: &[PathBuf], from: &[u8], to: &[u8], no_clobber: bool) -> Outcome {
    let (source, source_name) = parent(roots, from)?;
    let (target, target_name) = parent(roots, to)?;
    if no_clobber {
        match renameat_with(
            &source,
            source_name.as_c_str(),
            &target,
            target_name.as_c_str(),
            RenameFlags::NOREPLACE,
        ) {
            // GNU mv --no-clobber skips an existing target and succeeds.
            Ok(()) | Err(Errno::EXIST) => Ok(()),
            Err(error) => Err(error.into()),
        }
    } else {
        renameat(
            &source,
            source_name.as_c_str(),
            &target,
            target_name.as_c_str(),
        )?;
        Ok(())
    }
}

fn remove(roots: &[PathBuf], path: &[u8], force: bool) -> Outcome {
    let (directory, name) = parent(roots, path)?;
    match statat(&directory, name.as_c_str(), AtFlags::SYMLINK_NOFOLLOW) {
        Err(Errno::NOENT) if force => Ok(()),
        Err(error) => Err(error.into()),
        Ok(stat) if FileType::from_raw_mode(stat.st_mode) == FileType::Directory => {
            Err(Failure::Effect)
        }
        Ok(_) => {
            unlinkat(&directory, name.as_c_str(), AtFlags::empty())?;
            Ok(())
        }
    }
}

fn remove_tree(roots: &[PathBuf], path: &[u8]) -> Outcome {
    let (directory, name) = parent(roots, path)?;
    let stat = match statat(&directory, name.as_c_str(), AtFlags::SYMLINK_NOFOLLOW) {
        Err(Errno::NOENT) => return Ok(()),
        stat => stat?,
    };
    if FileType::from_raw_mode(stat.st_mode) != FileType::Directory {
        unlinkat(&directory, name.as_c_str(), AtFlags::empty())?;
        return Ok(());
    }
    let mut complete = true;
    empty(&directory, &name, stat.st_dev, &mut complete)?;
    if !complete {
        return Err(Failure::Effect);
    }
    unlinkat(&directory, name.as_c_str(), AtFlags::REMOVEDIR)?;
    Ok(())
}

/// Remove everything inside `parent/name` without leaving its file system;
/// a mount point (or anything that cannot be removed) clears `complete`.
fn empty(parent: &OwnedFd, name: &CStr, device: u64, complete: &mut bool) -> Outcome {
    let directory = openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    if fstat(&directory)?.st_dev != device {
        *complete = false;
        return Ok(());
    }
    let mut entries = Vec::new();
    for entry in Dir::read_from(&directory)? {
        let entry = entry?;
        let name = entry.file_name();
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            entries.push(name.to_owned());
        }
    }
    for entry in entries {
        match statat(&directory, entry.as_c_str(), AtFlags::SYMLINK_NOFOLLOW) {
            Ok(stat) if FileType::from_raw_mode(stat.st_mode) == FileType::Directory => {
                if stat.st_dev != device {
                    *complete = false;
                    continue;
                }
                empty(&directory, &entry, device, complete)?;
                if unlinkat(&directory, entry.as_c_str(), AtFlags::REMOVEDIR).is_err() {
                    *complete = false;
                }
            }
            Ok(_) => {
                if unlinkat(&directory, entry.as_c_str(), AtFlags::empty()).is_err() {
                    *complete = false;
                }
            }
            Err(_) => *complete = false,
        }
    }
    Ok(())
}

fn truncate(roots: &[PathBuf], path: &[u8], size: u64) -> Outcome {
    let (directory, name) = parent(roots, path)?;
    let file = openat(
        &directory,
        name.as_c_str(),
        OFlags::WRONLY | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::from_raw_mode(0o600),
    )?;
    if FileType::from_raw_mode(fstat(&file)?.st_mode) != FileType::RegularFile {
        return Err(Failure::Effect);
    }
    ftruncate(&file, size)?;
    Ok(())
}

fn mkfifo(roots: &[PathBuf], path: &[u8]) -> Outcome {
    let (directory, name) = parent(roots, path)?;
    mknodat(
        &directory,
        name.as_c_str(),
        FileType::Fifo,
        Mode::from_raw_mode(0o600),
        0,
    )?;
    Ok(())
}

fn sync(roots: &[PathBuf], path: &[u8]) -> Outcome {
    let file = open(roots, path, OFlags::RDONLY | OFlags::NONBLOCK)?;
    fsync(file.as_fd())?;
    Ok(())
}
