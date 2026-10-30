//! Native FreeBSD and illumos guest boot and filesystem probes.

use crate::guest::{mmds, readiness::Boot, trust};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const REQUIRED_SERVICES: &[&str] = &[
    "overalls-native-kernel-probed",
    "overalls-native-agentd",
    "overalls-native-flushd",
    "overalls-native-readinessd",
    "overalls-native-trustd",
    "overalls-native-workspaced",
    "lilly-terminald",
    "sshd",
    "overalls-native-ssh-refresh",
];

/// Fetch the current MMDS identity and bind it to a volatile boot UUID.
pub fn identity() -> io::Result<(Boot, Ipv4Addr, Ipv4Addr)> {
    let started = Instant::now();
    let document = loop {
        match mmds::fetch(Duration::from_secs(5)) {
            Ok(document) => break document,
            Err(error) if started.elapsed() < Duration::from_mins(10) => {
                let _ = error;
                std::thread::sleep(Duration::from_secs(2));
            }
            Err(error) => return Err(error),
        }
    };
    let address = document
        .ipv4
        .parse()
        .map_err(|_| io::Error::other("invalid guest address"))?;
    let gateway = document
        .gateway
        .parse()
        .map_err(|_| io::Error::other("invalid guest gateway"))?;
    let boot = Boot::new(
        document.placement,
        document.execution_epoch,
        document.boot_challenge,
        boot_id()?,
    )?;
    Ok((boot, address, gateway))
}

/// Read or atomically create the per-boot UUID in volatile storage.
pub fn boot_id() -> io::Result<String> {
    let path = std::env::var_os("OVERALLS_BOOT_ID")
        .map_or_else(|| PathBuf::from("/var/run/overalls/boot-id"), PathBuf::from);
    if let Ok(value) = fs::read_to_string(&path) {
        let value = value.trim().to_owned();
        if valid_uuid(&value) {
            return Ok(value);
        }
        return Err(io::Error::other("invalid native boot id"));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let value = format_uuid(bytes);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    match options.open(&path) {
        Ok(mut file) => {
            file.write_all(value.as_bytes())?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            Ok(value)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => boot_id(),
        Err(error) => Err(error),
    }
}

/// Confirm the MMDS-delivered /32 and host route without persisting command
/// output or exposing network details to diagnostics.
pub fn network_ready(address: Ipv4Addr, gateway: Ipv4Addr) -> io::Result<bool> {
    let os = if cfg!(target_os = "freebsd") {
        crate::native_bootstrap::Os::FreeBsd
    } else {
        crate::native_bootstrap::Os::Illumos
    };
    crate::native_bootstrap::configured(os, address, gateway)
}

/// A synced write proves that the guest root is writable before readiness.
pub fn writable_root() -> io::Result<()> {
    let directory = std::env::var_os("OVERALLS_RUN_DIR")
        .map_or_else(|| PathBuf::from("/var/run/overalls"), PathBuf::from);
    fs::create_dir_all(&directory)?;
    let path = directory.join(format!(".readiness-{}", std::process::id()));
    let mut file = File::create(&path)?;
    file.write_all(b"ready\n")?;
    file.sync_all()?;
    drop(file);
    fs::remove_file(path)
}

/// @cc [owner:ghuntley,label:recovery;verification] native-flush-blocking-root
/// A native flush receipt MUST follow completion of filesystem writes, rather
/// than their asynchronous scheduling. FreeBSD MUST flush and immediately
/// resume only the fixed writable UFS root through UFSSUSPEND/UFSRESUME, then
/// flush the disk's volatile write cache; a failed suspend, resume or cache
/// flush MUST refuse the receipt, and descriptor closure MUST invoke the
/// kernel's resume cleanup. The pinned illumos ZFS sync MUST wait for dirty
/// pool commits.
pub fn flush_root() -> io::Result<()> {
    #[cfg(target_os = "freebsd")]
    {
        use std::mem::{size_of, MaybeUninit};
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};

        // FreeBSD14.3 sys/ufs/ffs/fs.h: _IOW('U', 1, fsid_t), _IO('U', 2).
        // Stock growfs uses the same root-fsid suspension. Its kernel path
        // waits for VFS_SYNC(MNT_SUSPEND), including UFS softdep dependencies.
        const SUSPEND: libc::c_ulong =
            0x8000_5501 | ((size_of::<libc::fsid_t>() as libc::c_ulong) << 16);
        const RESUME: libc::c_ulong = 0x2000_5502;

        let mut root = MaybeUninit::<libc::statfs>::uninit();
        // SAFETY: the fixed NUL-terminated path and writable statfs storage are
        // valid for the call; the output is read only after success.
        if unsafe { libc::statfs(c"/".as_ptr(), root.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful statfs initialized this structure.
        let root = unsafe { root.assume_init() };
        let kind: Vec<u8> = root
            .f_fstypename
            .iter()
            .map(|value| u8::from_ne_bytes(value.to_ne_bytes()))
            .collect();
        let source: Vec<u8> = root
            .f_mntfromname
            .iter()
            .map(|value| u8::from_ne_bytes(value.to_ne_bytes()))
            .collect();
        validate_ufs_root(&kind, &source, root.f_flags & libc::MNT_RDONLY as u64 != 0)?;
        let device = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open("/dev/ufssuspend")?;
        if !device.metadata()?.file_type().is_char_device() {
            return Err(io::Error::other("invalid native flush device"));
        }
        let mut identity = root.f_fsid;
        // SAFETY: the ioctl receives the exact statfs fsid and its correct
        // native size. Closing the owned descriptor invokes kernel resume
        // cleanup, including errors or process death; no filesystem write occurs here.
        if unsafe { libc::ioctl(device.as_raw_fd(), SUSPEND, &mut identity) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: this descriptor owns the successful suspension; UFSRESUME
        // consumes it before a receipt can be returned.
        if unsafe { libc::ioctl(device.as_raw_fd(), RESUME) } != 0 {
            return Err(io::Error::last_os_error());
        }
        drop(device);
        flush_disk_cache()
    }
    #[cfg(any(target_os = "illumos", target_os = "solaris"))]
    {
        // SAFETY: sync takes no input. The pinned ZFS zfs_sync(NULL, 0)
        // calls spa_sync_allpools(), which waits for dirty pool commits.
        unsafe { libc::sync() };
        Ok(())
    }
    #[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
    Err(io::Error::other("unsupported native filesystem flush"))
}

/// @cc [owner:ghuntley,label:recovery] native-freebsd-device-cache-flush
/// Pinned FreeBSD UFS never sends `BIO_FLUSH` on suspension or fsync
/// (`softdep_flushcache` defaults to off), so completed writes may still sit in
/// the virtio device's volatile cache. After resume the agent MUST send one
/// DIOCGFLUSH through the image's fixed `gpt/swapfs` partition provider, which
/// shares the root's disk and is never exclusively held, and MUST refuse the
/// receipt unless the flush succeeds. The descriptor MUST NOT write data.
#[cfg(target_os = "freebsd")]
fn flush_disk_cache() -> io::Result<()> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};

    // FreeBSD14.3 sys/sys/disk.h: DIOCGFLUSH _IO('d', 135); checked by the
    // native-growth ABI gate.
    const DIOCGFLUSH: libc::c_ulong = 0x2000_6487;

    // GEOM refuses BIO_FLUSH on a consumer without write access, and the
    // mounted root holds its provider exclusively; the swap partition does not.
    let disk = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/dev/gpt/swapfs")?;
    if !disk.metadata()?.file_type().is_char_device() {
        return Err(io::Error::other("invalid native flush disk"));
    }
    // SAFETY: DIOCGFLUSH takes no argument and only issues BIO_FLUSH to the
    // provider's disk; the owned descriptor stays open for the call.
    if unsafe { libc::ioctl(disk.as_raw_fd(), DIOCGFLUSH) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(any(target_os = "freebsd", test))]
fn validate_ufs_root(kind: &[u8], source: &[u8], readonly: bool) -> io::Result<()> {
    let kind = kind.split(|value| *value == 0).next().unwrap_or_default();
    let source = source.split(|value| *value == 0).next().unwrap_or_default();
    if readonly || kind != b"ufs" || source != b"/dev/gpt/rootfs" {
        return Err(io::Error::other("unsupported native flush root"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:recovery] native-readiness-live-services
/// Native readiness MUST be withheld when any required daemon's supervisor
/// marker is missing, malformed, oversized or names a process that has exited,
/// or when the current roster/certificate refresh has withheld `ssh-ready`.
pub fn services_ready() -> io::Result<bool> {
    let directory = std::env::var_os("OVERALLS_RUN_DIR")
        .map_or_else(|| PathBuf::from("/var/run/overalls"), PathBuf::from);
    services_ready_in(&directory)
}

fn services_ready_in(directory: &Path) -> io::Result<bool> {
    use std::os::unix::fs::OpenOptionsExt;
    let ready = match fs::symlink_metadata(directory.join("ssh-ready")) {
        Ok(metadata) => metadata.is_file() && !metadata.file_type().is_symlink(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => return Err(error),
    };
    if !ready {
        return Ok(false);
    }
    for service in REQUIRED_SERVICES {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(directory.join(format!("{service}.pid")))
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error),
        };
        if !file.metadata()?.is_file() {
            return Ok(false);
        }
        let mut value = String::new();
        file.take(13).read_to_string(&mut value)?;
        if value.len() > 12 {
            return Ok(false);
        }
        let pid = match value.trim_end_matches('\n').parse::<i32>() {
            Ok(pid) if pid > 1 && value == format!("{pid}\n") => pid,
            _ => return Ok(false),
        };
        // SAFETY: signal zero only checks the process's existence/permission.
        if unsafe { libc::kill(pid, 0) } != 0
            && io::Error::last_os_error().kind() != io::ErrorKind::PermissionDenied
        {
            return Ok(false);
        }
    }
    Ok(true)
}

/// @cc [owner:ghuntley,label:security;recovery] native-trust-vendor-base
/// Native trust MUST use the image's pinned regular vendor CA snapshot as its
/// base, independently of the managed system destination. Reinstallation MUST
/// NOT use previously delivered platform roots as distribution roots.
pub fn trust_paths(os: &str) -> io::Result<(&'static str, &'static str)> {
    match os {
        "freebsd" => Ok(("/etc/overalls/system-ca.pem", "/etc/ssl/cert.pem")),
        "illumos" | "solaris" => Ok(("/etc/overalls/system-ca.pem", "/etc/ssl/cacert.pem")),
        _ => Err(io::Error::other("unsupported native trust layout")),
    }
}

/// @cc [owner:ghuntley,label:security;recovery] native-trust-install-replacement
/// Installation MUST validate the current boot before writes, compose only the
/// separate regular vendor base and current roots, and publish the managed link
/// only after the exact staged bundle is synced. Repeated delivery across boots
/// MUST be idempotent; missing vendor trust or conflicting retained bytes MUST
/// refuse without changing the effective bundle. Old platform roots MUST NOT
/// accumulate in the effective bundle when the requested set changes.
pub fn install_trust(
    base: &Path,
    destination: &Path,
    state: &Path,
    request: &trust::Request,
    boot: &Boot,
) -> io::Result<()> {
    use std::os::unix::fs::{symlink, OpenOptionsExt};

    trust::validate(request, boot)?;
    if base == destination || !fs::symlink_metadata(base)?.file_type().is_file() {
        return Err(io::Error::other("invalid native vendor trust"));
    }
    let mut original = Vec::new();
    File::open(base)?
        .take(trust::MAX_FRAME as u64 + 1)
        .read_to_end(&mut original)?;
    if original.is_empty() {
        return Err(io::Error::other("missing native vendor trust"));
    }
    let bundle = trust::bundle(&original, &request.roots)?;
    fs::create_dir_all(state)?;
    let staged = state.join(format!("bundle-{}.pem", request.bundle_digest));
    match fs::symlink_metadata(&staged) {
        Ok(metadata) => {
            if !metadata.file_type().is_file() || fs::read(&staged)? != bundle {
                return Err(io::Error::other("conflicting native trust bundle"));
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let next = state.join(".overalls-ca.next");
            let _ = fs::remove_file(&next);
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o644)
                .open(&next)?;
            file.write_all(&bundle)?;
            file.sync_all()?;
            fs::rename(next, &staged)?;
            File::open(state)?.sync_all()?;
        }
        Err(error) => return Err(error),
    }
    let parent = destination
        .parent()
        .ok_or_else(|| io::Error::other("invalid native trust destination"))?;
    fs::create_dir_all(parent)?;
    let next = parent.join(".overalls-ca-link.next");
    let _ = fs::remove_file(&next);
    symlink(&staged, &next)?;
    fs::rename(next, destination)?;
    File::open(parent)?.sync_all()
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn format_uuid(bytes: [u8; 16]) -> String {
    format!(
        "{}-{}-{}-{}-{}",
        hex::encode(&bytes[..4]),
        hex::encode(&bytes[4..6]),
        hex::encode(&bytes[6..8]),
        hex::encode(&bytes[8..10]),
        hex::encode(&bytes[10..])
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_layouts_are_closed() {
        assert_eq!(
            trust_paths("freebsd").unwrap(),
            ("/etc/overalls/system-ca.pem", "/etc/ssl/cert.pem")
        );
        assert_eq!(
            trust_paths("illumos").unwrap(),
            ("/etc/overalls/system-ca.pem", "/etc/ssl/cacert.pem")
        );
        assert!(trust_paths("linux").is_err());
    }

    #[test]
    fn ufs_flush_refuses_readonly_foreign_and_partial_mount_names() {
        validate_ufs_root(b"ufs\0unused", b"/dev/gpt/rootfs\0unused", false).unwrap();
        for (kind, source, readonly) in [
            (b"ufs".as_slice(), b"/dev/gpt/rootfs".as_slice(), true),
            (b"zfs", b"/dev/gpt/rootfs", false),
            (b"ufs", b"/dev/gpt/foreign", false),
            (b"ufs", b"/dev/gpt/rootfs-foreign", false),
            (b"ufs-partial", b"/dev/gpt/rootfs", false),
            (b"", b"", false),
        ] {
            assert!(validate_ufs_root(kind, source, readonly).is_err());
        }
    }

    #[test]
    fn service_markers_require_every_current_process() {
        let directory = tempfile::tempdir().unwrap();
        assert!(!services_ready_in(directory.path()).unwrap());
        for service in REQUIRED_SERVICES {
            fs::write(
                directory.path().join(format!("{service}.pid")),
                format!("{}\n", std::process::id()),
            )
            .unwrap();
        }
        assert!(!services_ready_in(directory.path()).unwrap());
        fs::write(directory.path().join("ssh-ready"), b"").unwrap();
        assert!(services_ready_in(directory.path()).unwrap());
        let marker = directory.path().join("sshd.pid");
        for invalid in ["0\n", "1\n", "-2\n", " 2\n", "2\n\n", "a", "2222222222222"] {
            fs::write(&marker, invalid).unwrap();
            assert!(!services_ready_in(directory.path()).unwrap());
        }
        fs::write(&marker, format!("{}\n", i32::MAX)).unwrap();
        assert!(!services_ready_in(directory.path()).unwrap());
    }
}
