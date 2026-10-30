//! Root-only, mounted-root-bound native disk expansion before boot identity.

mod gpt;

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const RUN: &str = "/var/run/overalls";
const RECEIPT: &str = "/var/run/overalls/root-growth.json";
const POOL: &str = "overalls_native_candidate";
const DATASET: &str = "overalls_native_candidate/ROOT/overalls-native-candidate";

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Os {
    FreeBsd,
    Illumos,
}

impl Os {
    fn root_index(self) -> usize {
        match self {
            Self::FreeBsd => 5,
            Self::Illumos => 2,
        }
    }
}

fn invalid() -> io::Error {
    io::Error::other("native root growth refused")
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Outcome {
    Grown,
    Unchanged,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    version: u8,
    os: Os,
    outcome: Outcome,
    disk_bytes: u64,
    root_start: u64,
    root_end_before: u64,
    root_end_after: u64,
    backup_before: u64,
    backup_after: u64,
    native_admission: bool,
}

impl Receipt {
    fn validate(&self, os: Os) -> io::Result<()> {
        if self.version != 1
            || self.os != os
            || self.native_admission
            || !(1_u64 << 30..=1_u64 << 50).contains(&self.disk_bytes)
            || !self.disk_bytes.is_multiple_of(512)
            || self.root_start
                != match os {
                    Os::FreeBsd => 2_165_940,
                    Os::Illumos => 524_544,
                }
            || self.root_end_before < self.root_start
            || self.root_end_after < self.root_end_before
            || self.backup_before < 34
            || self.root_end_before >= self.backup_before
            || self.root_end_after >= self.backup_after
            || self.backup_before > self.backup_after
            || self.backup_after != self.disk_bytes / 512 - 1
            || (self.root_end_after
                != self.backup_after
                    - match os {
                        Os::FreeBsd => 33,
                        Os::Illumos => 16417,
                    }
                && (os != Os::FreeBsd
                    || self.root_end_after
                        != self.backup_after - 33 - (self.backup_after - 32) % 8))
            || (self.outcome == Outcome::Grown) != (self.root_end_after > self.root_end_before)
        {
            return Err(invalid());
        }
        Ok(())
    }
}

fn directory(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err(invalid());
    }
    Ok(())
}

fn runtime_directory() -> io::Result<()> {
    for path in ["/", "/var", "/var/run"] {
        directory(Path::new(path))?;
    }
    match fs::create_dir(RUN) {
        Ok(()) => fs::set_permissions(RUN, fs::Permissions::from_mode(0o700))?,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    directory(Path::new(RUN))
}

fn root_file(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
        || metadata.len() > limit
    {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    (&mut file).take(limit + 1).read_to_end(&mut bytes)?;
    if u64::try_from(bytes.len()).map_err(|_| invalid())? > limit {
        return Err(invalid());
    }
    Ok(bytes)
}

/// @cc [owner:ghuntley,label:security;recovery] native-growth-bootstrap-prerequisite
/// Bootstrap MUST require the root-owned, bounded, typed success receipt from
/// the every-boot growth service before configuring network or boot identity.
/// The runtime filesystem MUST be cleared by cleanvar (FreeBSD) or mounted
/// volatile (`OmniOS`) before growth runs; prior-boot receipts grant no authority.
pub fn require_success(os: Os) -> io::Result<()> {
    runtime_directory()?;
    let receipt: Receipt =
        serde_json::from_slice(&root_file(Path::new(RECEIPT), 4096)?).map_err(|_| invalid())?;
    receipt.validate(os)
}

/// Run only fixed native programs with bounded output, time and no diagnostics.
fn command(program: &str, arguments: &[&str], capture: bool) -> io::Result<String> {
    let mut child = Command::new(program)
        .args(arguments)
        .env_clear()
        .env("LC_ALL", "C")
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .stdin(Stdio::null())
        .stdout(if capture {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stderr(Stdio::null())
        .spawn()?;
    let result = (|| {
        let mut pipe = child.stdout.take();
        if let Some(pipe) = &pipe {
            // SAFETY: pipe owns its descriptor; these calls only set its status flags.
            let flags = unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL) };
            if flags < 0 {
                return Err(invalid());
            }
            // SAFETY: as above; F_SETFL only adds O_NONBLOCK to the owned pipe.
            if unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
            {
                return Err(invalid());
            }
        }
        let mut bytes = Vec::new();
        let mut eof = !capture;
        let mut buffer = [0_u8; 4096];
        let started = Instant::now();
        loop {
            if started.elapsed() > Duration::from_mins(2) {
                return Err(invalid());
            }
            if !eof {
                match pipe.as_mut().ok_or_else(invalid)?.read(&mut buffer) {
                    Ok(0) => eof = true,
                    Ok(count) => {
                        bytes.extend_from_slice(&buffer[..count]);
                        if bytes.len() > 65536 {
                            return Err(invalid());
                        }
                        continue;
                    }
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => return Err(error),
                }
            }
            if let Some(status) = child.try_wait()? {
                if !status.success() {
                    return Err(invalid());
                }
                if eof {
                    return String::from_utf8(bytes).map_err(|_| invalid());
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    })();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

fn mounted_root(value: &str, os: Os) -> io::Result<()> {
    let mut roots = 0;
    for row in value.lines() {
        let fields: Vec<&str> = row.split_whitespace().collect();
        let (mountpoint, fstype, source) = match os {
            Os::FreeBsd if fields.len() == 6 => (fields[1], fields[2], fields[0]),
            Os::Illumos if (6..=7).contains(&fields.len()) => (fields[2], fields[3], fields[0]),
            _ => return Err(invalid()),
        };
        if mountpoint == "/" {
            if (os == Os::FreeBsd && (source != "/dev/gpt/rootfs" || fstype != "ufs"))
                || (os == Os::Illumos && (source != DATASET || fstype != "zfs"))
            {
                return Err(invalid());
            }
            roots += 1;
        }
    }
    if roots != 1 {
        return Err(invalid());
    }
    Ok(())
}

fn freebsd_disk(value: &str) -> io::Result<String> {
    let mut found = None;
    for line in value.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first() != Some(&"gpt/rootfs") {
            continue;
        }
        if fields.len() != 3 || fields[1] != "N/A" || found.is_some() {
            return Err(invalid());
        }
        let disk = fields[2].strip_suffix("p5").ok_or_else(invalid)?;
        let unit = disk.strip_prefix("vtbd").ok_or_else(invalid)?;
        if unit.is_empty()
            || unit.len() > 3
            || !unit.bytes().all(|byte| byte.is_ascii_digit())
            || unit.parse::<u16>().map_err(|_| invalid())? > 255
        {
            return Err(invalid());
        }
        found = Some(disk.to_owned());
    }
    found.ok_or_else(invalid)
}

#[derive(Deserialize)]
struct Assembly {
    version: u8,
    os: Os,
    dataset: String,
    pool_guid: String,
    native_admission: bool,
}

fn pool_guid(value: &str) -> io::Result<u64> {
    if value.is_empty() || value.len() > 20 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid());
    }
    let guid = value.parse::<u64>().map_err(|_| invalid())?;
    if guid == 0 {
        return Err(invalid());
    }
    Ok(guid)
}

fn assembly(value: &[u8], actual_guid: &str) -> io::Result<()> {
    let receipt: Assembly = serde_json::from_slice(value).map_err(|_| invalid())?;
    if receipt.version != 1
        || receipt.os != Os::Illumos
        || receipt.dataset != DATASET
        || receipt.native_admission
        || pool_guid(&receipt.pool_guid)? != pool_guid(actual_guid.trim())?
    {
        return Err(invalid());
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct IllumosDisk {
    raw: String,
    whole: String,
}

/// @cc [owner:ghuntley,label:security;recovery] illumos-growth-disk-operands
/// An assembly-bound, single whole-disk vdev MUST retain its validated s1
/// partition identity for authority checks, read GPT through the physical p0
/// device, and expand using the unsliced whole-disk operand. The pinned ZFS
/// lookup deliberately hides the s1 suffix for whole-disk vdevs.
fn illumos_device(path: &str) -> io::Result<IllumosDisk> {
    let name = path
        .strip_prefix("/dev/dsk/c")
        .and_then(|name| name.strip_suffix("s1"))
        .ok_or_else(invalid)?;
    let (controller, rest) = name.split_once('t').ok_or_else(invalid)?;
    let (target, disk) = rest.split_once('d').ok_or_else(invalid)?;
    if [controller, target, disk].iter().any(|part| {
        part.is_empty() || part.len() > 8 || !part.bytes().all(|byte| byte.is_ascii_digit())
    }) {
        return Err(invalid());
    }
    Ok(IllumosDisk {
        raw: format!("/dev/rdsk/c{name}p0"),
        whole: format!("/dev/dsk/c{name}"),
    })
}

fn illumos_vdev(value: &str, expected_guid: u64) -> io::Result<String> {
    let mut types = Vec::new();
    let mut path = None;
    let mut whole = false;
    let mut children = 0;
    let mut pools = 0;
    let mut child_count = 0;
    for line in value.lines() {
        let Some((key, value)) = line.trim().split_once(':') else {
            continue;
        };
        let value = value.trim();
        match key {
            "name" if value != format!("'{POOL}'") => return Err(invalid()),
            "pool_guid" => {
                if pool_guid(value)? != expected_guid {
                    return Err(invalid());
                }
                pools += 1;
            }
            "type" => types.push(value),
            "path" => {
                if path.is_some() || types != ["'root'", "'disk'"] {
                    return Err(invalid());
                }
                let current = value
                    .strip_prefix('\'')
                    .and_then(|value| value.strip_suffix('\''))
                    .ok_or_else(invalid)?;
                illumos_device(current)?;
                path = Some(current.to_owned());
            }
            "whole_disk" => {
                if whole || value != "1" {
                    return Err(invalid());
                }
                whole = true;
            }
            "vdev_children" => {
                if value != "1" {
                    return Err(invalid());
                }
                child_count += 1;
            }
            "children[0]" => children += 1,
            key if key.starts_with("children[")
                || ["spares", "l2cache", "is_spare"].contains(&key) =>
            {
                return Err(invalid())
            }
            "is_log" if value != "0" => return Err(invalid()),
            _ => {}
        }
    }
    if types != ["'root'", "'disk'"] || children != 1 || !whole || pools != 1 || child_count != 1 {
        return Err(invalid());
    }
    path.ok_or_else(invalid)
}

#[cfg(target_os = "freebsd")]
fn capacity(file: &File) -> io::Result<u64> {
    let mut bytes: libc::off_t = 0;
    let mut sector: libc::c_uint = 0;
    // SAFETY: pinned FreeBSD disk.h defines these read-only ioctls with the
    // exact off_t/u_int output objects supplied here; no disk bytes are written.
    if unsafe { libc::ioctl(file.as_raw_fd(), 0x4008_6481, &mut bytes) } < 0 {
        return Err(invalid());
    }
    // SAFETY: as above; DIOCGSECTORSIZE writes only the supplied u_int.
    if unsafe { libc::ioctl(file.as_raw_fd(), 0x4004_6480, &mut sector) } < 0
        || sector != 512
        || bytes <= 0
    {
        return Err(invalid());
    }
    u64::try_from(bytes).map_err(|_| invalid())
}

#[cfg(any(target_os = "illumos", target_os = "solaris"))]
fn capacity(file: &File) -> io::Result<u64> {
    #[repr(C)]
    #[expect(
        clippy::struct_field_names,
        reason = "mirrors the dkio.h dk_minfo field layout"
    )]
    struct Media {
        media_type: u32,
        sector_bytes: u32,
        sectors: u64,
    }
    let mut media = Media {
        media_type: 0,
        sector_bytes: 0,
        sectors: 0,
    };
    // SAFETY: pinned dkio.h defines DKIOCGMEDIAINFO and this C-layout output;
    // the read-only ioctl receives a live device descriptor and writable object.
    if unsafe { libc::ioctl(file.as_raw_fd(), 0x42a, &mut media) } < 0 || media.sector_bytes != 512
    {
        return Err(invalid());
    }
    media
        .sectors
        .checked_mul(u64::from(media.sector_bytes))
        .ok_or_else(invalid)
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn capacity(_file: &File) -> io::Result<u64> {
    Err(invalid())
}

fn disk(path: &str) -> io::Result<File> {
    let file = File::open(path)?;
    if !file.metadata()?.file_type().is_char_device() {
        return Err(invalid());
    }
    Ok(file)
}

/// @cc [owner:ghuntley,label:security;recovery] native-root-growth-authority
/// Growth MUST run as root against only the actual mounted pinned root, with
/// no caller-selected target. A complete read-only GPT/capacity preflight MUST
/// precede native mutation. FreeBSD MUST preserve the root UUID/start and every
/// nonroot entry; `OmniOS` MUST additionally match the assembly pool GUID and a
/// single whole-disk ZFS vdev, preserving loader and reserved-tail identity.
/// `OmniOS` pool discovery MUST NOT depend on a persisted zpool cache, and MUST
/// create disk links before label discovery on a first boot at a new path.
/// Failure MUST withhold a success receipt and MUST NOT emit native output.
#[expect(
    clippy::too_many_lines,
    reason = "one ordered grow sequence whose receipt depends on every step"
)]
pub fn run(os: Os) -> io::Result<()> {
    // SAFETY: geteuid reads the process credential without modifying state.
    if unsafe { libc::geteuid() } != 0 {
        return Err(invalid());
    }
    runtime_directory()?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(Path::new(RUN).join("root-growth.lock"))?;
    let metadata = lock.metadata()?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o777 != 0o600 {
        return Err(invalid());
    }
    lock.try_lock_exclusive()?;
    match fs::remove_file(RECEIPT) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let (mount, tool) = match os {
        Os::FreeBsd => ("/sbin/mount", "/sbin/glabel"),
        Os::Illumos => ("/usr/sbin/mount", "/usr/sbin/zpool"),
    };
    mounted_root(&command(mount, &["-p"], true)?, os)?;
    let (path, target) = match os {
        Os::FreeBsd => {
            let target = freebsd_disk(&command(tool, &["status"], true)?)?;
            (format!("/dev/{target}"), target)
        }
        Os::Illumos => {
            for path in ["/etc", "/etc/overalls", "/etc/overalls/native-image"] {
                directory(Path::new(path))?;
            }
            let actual = command(tool, &["get", "-H", "-o", "value", "guid", POOL], true)?;
            assembly(
                &root_file(
                    Path::new("/etc/overalls/native-image/assembly-receipt.json"),
                    8 * 1024 * 1024,
                )?,
                &actual,
            )?;
            // The kernel keeps the assembly vdev path after opening the root
            // through an alternate /devices path, so label discovery resolves
            // the vdev only through /dev/dsk. On a first boot at a new device
            // path those links can still be missing; create them synchronously.
            command("/usr/sbin/devfsadm", &["-c", "disk"], false)?;
            // Early boot may not have a persisted pool cache. zdb has its own
            // read-only userland namespace: exclude cached pools before label
            // discovery so an existing cached entry cannot collide with -e.
            let target = illumos_vdev(
                &command(
                    "/usr/sbin/zdb",
                    &["-C", "-e", "-U", "/dev/null", "-p", "/dev/dsk", POOL],
                    true,
                )?,
                pool_guid(actual.trim())?,
            )?;
            let disk = illumos_device(&target)?;
            (disk.raw, disk.whole)
        }
    };
    let mut device = disk(&path)?;
    let bytes = capacity(&device)?;
    let before = gpt::read(&mut device, bytes, os)?;
    // gpart acquires exclusive access to the parent GEOM consumer. A separate
    // GEOM_DEV raw reader must not remain open while the native tools resize
    // it. Reopen only the already derived path and validate its full pinned
    // identity and unchanged physical capacity after native completion.
    drop(device);
    match os {
        Os::FreeBsd => {
            let mut last = before.last;
            if before.backup != before.disk_bytes / 512 - 1 {
                command("/sbin/gpart", &["recover", &target], false)?;
                // Pinned gpart recover may round the usable end down to a
                // 4096-byte boundary. Read its actual validated geometry,
                // preserving every partition, before choosing whether to grow.
                let mut recovered_device = disk(&path)?;
                let recovered_bytes = capacity(&recovered_device)?;
                let recovered = gpt::read(&mut recovered_device, recovered_bytes, os)?;
                before.verify_recovery(&recovered)?;
                last = recovered.last;
            }
            if before.root.end < last {
                command("/sbin/gpart", &["resize", "-i", "5", &target], false)?;
            }
            // Re-run even after an unchanged partition to recover an interrupted
            // previous resize. Pinned growfs returns zero for an equal size.
            command("/sbin/growfs", &["-y", "/dev/gpt/rootfs"], false)?;
        }
        Os::Illumos => {
            command(tool, &["online", "-e", POOL, &target], false)?;
        }
    }
    let mut device = disk(&path)?;
    let bytes = capacity(&device)?;
    let after = gpt::read(&mut device, bytes, os)?;
    before.verify_growth(&after, os)?;
    let receipt = Receipt {
        version: 1,
        os,
        outcome: if after.root.end > before.root.end {
            Outcome::Grown
        } else {
            Outcome::Unchanged
        },
        disk_bytes: after.disk_bytes,
        root_start: after.root.start,
        root_end_before: before.root.end,
        root_end_after: after.root.end,
        backup_before: before.backup,
        backup_after: after.backup,
        native_admission: false,
    };
    receipt.validate(os)?;
    let mut temporary = tempfile::Builder::new()
        .prefix(".root-growth-")
        .tempfile_in(RUN)?;
    serde_json::to_writer(&mut temporary, &receipt).map_err(|_| invalid())?;
    temporary.write_all(b"\n")?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o644))?;
    temporary.as_file().sync_all()?;
    temporary.persist(RECEIPT).map_err(|_| invalid())?;
    File::open(RUN)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mounted_root_must_be_unique_and_exact() {
        assert!(mounted_root("/dev/gpt/rootfs / ufs rw 1 1\n", Os::FreeBsd).is_ok());
        assert!(mounted_root(&format!("{DATASET} - / zfs - no rw\n"), Os::Illumos).is_ok());
        assert!(mounted_root(
            &format!("{DATASET} - / zfs - no \n/var/run - /var/run tmpfs - no xattr\n"),
            Os::Illumos
        )
        .is_ok());
        for value in [
            "/dev/vtbd1p5 / ufs rw 1 1",
            "/dev/gpt/rootfs / zfs rw 1 1",
            "",
            "/dev/gpt/rootfs / ufs rw 1 1\n/dev/gpt/rootfs / ufs rw 1 1",
        ] {
            assert!(mounted_root(value, Os::FreeBsd).is_err());
        }
        assert!(mounted_root("foreign/ROOT/x - / zfs - no rw", Os::Illumos).is_err());
    }

    #[test]
    fn freebsd_target_is_derived_without_arguments_or_other_partitions() {
        assert_eq!(
            freebsd_disk("Name Status Components\ngpt/rootfs N/A vtbd0p5").unwrap(),
            "vtbd0"
        );
        for target in [
            "vtbd0p4",
            "ada0p5",
            "../vtbd0p5",
            "vtbd256p5",
            "vtbd-1p5",
            "vtbd0p5 arg",
        ] {
            assert!(freebsd_disk(&format!("gpt/rootfs N/A {target}")).is_err());
        }
        assert!(freebsd_disk("gpt/rootfs N/A vtbd0p5\ngpt/rootfs N/A vtbd1p5").is_err());
    }

    fn config() -> String {
        format!("name: '{POOL}'\npool_guid: 42\nvdev_children: 1\nvdev_tree:\n type: 'root'\n children[0]:\n  type: 'disk'\n  path: '/dev/dsk/c2t0d0s1'\n  whole_disk: 1\n  is_log: 0\n")
    }

    #[test]
    fn illumos_requires_one_bound_whole_disk_without_extra_vdevs() {
        let config = config();
        assert_eq!(illumos_vdev(&config, 42).unwrap(), "/dev/dsk/c2t0d0s1");
        assert_eq!(
            illumos_device("/dev/dsk/c2t0d0s1").unwrap(),
            IllumosDisk {
                raw: "/dev/rdsk/c2t0d0p0".to_owned(),
                whole: "/dev/dsk/c2t0d0".to_owned(),
            }
        );
        assert!(illumos_vdev(&config, 43).is_err());
        for (from, to) in [
            ("whole_disk: 1", "whole_disk: 0"),
            ("'disk'", "'mirror'"),
            ("children[0]", "children[1]"),
            ("c2t0d0s1", "c2t0d0s0"),
            (
                "/dev/dsk/c2t0d0s1",
                "/mnt/overalls-native-assembly/devices/scratch",
            ),
            ("/dev/dsk/c2t0d0s1", "/dev/dsk/../c2t0d0s1"),
            ("vdev_children: 1", "vdev_children: 2"),
            ("is_log: 0", "is_log: 1"),
        ] {
            assert!(illumos_vdev(&config.replace(from, to), 42).is_err());
        }
        for suffix in [
            "children[1]:\n type: 'disk'\n",
            "spares:\n",
            "l2cache:\n",
            "path: '/dev/dsk/c3t0d0s1'\n",
            "whole_disk: 1\n",
        ] {
            assert!(illumos_vdev(&(config.clone() + suffix), 42).is_err());
        }
    }

    #[test]
    fn assembly_pool_and_dataset_cannot_be_substituted() {
        let valid = format!(
            r#"{{"version":1,"os":"illumos","dataset":"{DATASET}","pool_guid":"42","native_admission":false,"other":"reviewed assembly fields"}}"#
        );
        assert!(assembly(valid.as_bytes(), "42\n").is_ok());
        assert!(assembly(valid.as_bytes(), "43\n").is_err());
        for (from, to) in [
            ("illumos", "freebsd"),
            ("\"42\"", "\"0\""),
            ("false", "true"),
            (DATASET, "foreign/ROOT/x"),
        ] {
            assert!(assembly(valid.replace(from, to).as_bytes(), "42").is_err());
        }
        for value in ["", "0", "-1", "1 2", "18446744073709551616"] {
            assert!(pool_guid(value).is_err());
        }
    }

    #[test]
    fn receipt_rejects_shrink_wrong_os_and_incomplete_expansion() {
        let mut receipt = Receipt {
            version: 1,
            os: Os::FreeBsd,
            outcome: Outcome::Unchanged,
            disk_bytes: 6_477_687_296,
            root_start: 2_165_940,
            root_end_before: 12_651_699,
            root_end_after: 12_651_699,
            backup_before: 12_651_732,
            backup_after: 12_651_732,
            native_admission: false,
        };
        receipt.validate(Os::FreeBsd).unwrap();
        assert!(receipt.validate(Os::Illumos).is_err());
        receipt.root_end_after -= 1;
        assert!(receipt.validate(Os::FreeBsd).is_err());
        receipt.root_end_after += 1;
        receipt.outcome = Outcome::Grown;
        assert!(receipt.validate(Os::FreeBsd).is_err());
        receipt.outcome = Outcome::Unchanged;
        receipt.native_admission = true;
        assert!(receipt.validate(Os::FreeBsd).is_err());
        receipt.native_admission = false;
        receipt.outcome = Outcome::Grown;
        receipt.disk_bytes += 2 << 30;
        receipt.backup_after = receipt.disk_bytes / 512 - 1;
        let maximum = receipt.backup_after - 33;
        let aligned = maximum - (maximum + 1) % 8;
        for offset in 0..=8 {
            receipt.root_end_after = maximum - offset;
            assert_eq!(
                receipt.validate(Os::FreeBsd).is_ok(),
                receipt.root_end_after == maximum || receipt.root_end_after == aligned,
                "offset {offset}"
            );
        }
    }
}
