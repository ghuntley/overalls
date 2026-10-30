//! The typed VM launch (ADR-0176 decision 4): hostd, not Lilly, builds the
//! `systemd-run` command line that starts a guest's boot-log, launch guard,
//! jailer and Firecracker chain as root.

use crate::protocol::Refusal;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// The dedicated VM UID/GID range (Lilly's `UIDReservation`).
pub const JAIL_UIDS: std::ops::RangeInclusive<u32> = 1_000_002..=1_262_142;
/// Bounds on the unit's memory limit and vCPU count.
pub const MEMORY_BYTES: std::ops::RangeInclusive<u64> =
    64 * 1024 * 1024..=2 * 1024 * 1024 * 1024 * 1024;
pub const VCPUS: std::ops::RangeInclusive<u8> = 1..=64;

/// Executables and directories hostd was configured with (never Lilly's).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Tools {
    pub boot_log: PathBuf,
    pub unshare: PathBuf,
    pub launch_guard: PathBuf,
    pub jailer: PathBuf,
    pub firecracker: PathBuf,
}

/// One decoded launch request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Launch {
    pub placement: [u8; 36],
    pub epoch: u64,
    pub generation: u64,
    pub uid: u32,
    pub memory_bytes: u64,
    pub vcpus: u8,
    pub firmware: bool,
    pub logging: bool,
    /// Start an unconfigured API server for snapshot loading; never cold boot.
    pub restore: bool,
    pub state_dir: Vec<u8>,
    pub namespace: Vec<u8>,
    pub pool: Vec<u8>,
}

/// Whether `bytes` is a lowercase hyphenated UUID.
pub fn uuid(bytes: &[u8]) -> bool {
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
        })
}

fn namespace(bytes: &[u8]) -> bool {
    (1..=32).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
}

fn state_dir(bytes: &[u8], roots: &[PathBuf]) -> bool {
    let path = Path::new(std::ffi::OsStr::from_bytes(bytes));
    bytes.len() <= 45
        && crate::protocol::valid_directory(bytes)
        && roots.iter().any(|root| path.starts_with(root))
}

fn text(value: impl AsRef<[u8]>) -> Result<CString, Refusal> {
    CString::new(value.as_ref()).map_err(|_| Refusal::Malformed)
}

/// @cc [owner:ghuntley,label:security] vm-launch-argv-derived-by-hostd
/// argv MUST return the `systemd-run` arguments for one VM only when the
/// placement is a UUID, epoch and generation are positive, the uid is in
/// the reserved VM range, memory and vCPUs are within bounds, the namespace
/// is a short lowercase name, the pool equals one configured pool root and
/// the state directory is a normalised absolute path of at most 45 bytes
/// beneath one of hostd's lease roots;
/// otherwise Malformed (or Unavailable without configured tools). Every
/// executable and directory comes from `tools` and `pools`, never from the
/// request. A restore launch MUST omit `--config-file` and `--metadata` so
/// Firecracker cannot boot before its snapshot is loaded. Firmware restores
/// retain `--enable-pci`; cold firmware boots append `--enable-pci --metadata
/// /metadata.json` after the Firecracker configuration file. A non-zero
/// service uid MUST be passed as the boot-log writer's `--reader-uid` and
/// the launch guard's `--owner-uid`, and a zero service uid as neither.
#[expect(
    clippy::too_many_lines,
    reason = "the fixed launch command line is built in one auditable sequence"
)]
pub fn argv(
    tools: Option<&Tools>,
    roots: &[PathBuf],
    pools: &[PathBuf],
    launch: &Launch,
    service_uid: u32,
) -> Result<Vec<CString>, Refusal> {
    let tools = tools.ok_or(Refusal::Unavailable)?;
    let placement = std::str::from_utf8(&launch.placement).map_err(|_| Refusal::Malformed)?;
    let pool = pools
        .iter()
        .find(|pool| pool.as_os_str().as_bytes() == launch.pool.as_slice())
        .ok_or(Refusal::Malformed)?;
    if !uuid(&launch.placement)
        || launch.epoch == 0
        || launch.generation == 0
        || !JAIL_UIDS.contains(&launch.uid)
        || !MEMORY_BYTES.contains(&launch.memory_bytes)
        || !VCPUS.contains(&launch.vcpus)
        || !namespace(&launch.namespace)
        || !state_dir(&launch.state_dir, roots)
    {
        return Err(Refusal::Malformed);
    }
    let namespace = std::str::from_utf8(&launch.namespace).map_err(|_| Refusal::Malformed)?;
    let unit = format!("lilly-vm-{placement}.service");
    let directory = Path::new(std::ffi::OsStr::from_bytes(&launch.state_dir)).join(placement);
    let path = |path: &Path| text(path.as_os_str().as_bytes());
    let mut argv = vec![
        text("--quiet")?,
        text("--collect")?,
        text("--service-type=exec")?,
        text("--unit")?,
        text(&unit)?,
        text(format!(
            "--description=Overalls VM v1 placement={placement} epoch={} generation={}",
            launch.epoch, launch.generation
        ))?,
        text("--slice=lilly.slice")?,
        text("--property=UMask=0077")?,
        text("--property=KillMode=control-group")?,
        text("--property=TimeoutStopSec=5s")?,
        text("--property=NoNewPrivileges=yes")?,
        text("--property=TasksMax=64")?,
        text("--property=MemorySwapMax=0")?,
        text(format!("--property=MemoryMax={}", launch.memory_bytes))?,
        text(format!(
            "--property=CPUQuota={}%",
            u32::from(launch.vcpus) * 100
        ))?,
        text("--")?,
        path(&tools.boot_log)?,
    ];
    // The root writer hands an unprivileged Lilly the boot log it reads.
    if service_uid != 0 {
        argv.extend([text("--reader-uid")?, text(service_uid.to_string())?]);
    }
    argv.extend([
        path(&directory.join("boot.log"))?,
        path(&tools.unshare)?,
        text("--fork")?,
        text("--pid")?,
        text("--kill-child=KILL")?,
        // Only the child creates a mount namespace; a waiting parent there
        // would pin every dataset mounted when this VM was launched.
        path(&tools.unshare)?,
        text("--mount-proc")?,
        path(&tools.launch_guard)?,
    ]);
    // An unprivileged Lilly owns intent.bin; the guard then also accepts that
    // one uid (the root command line is unchanged).
    if service_uid != 0 {
        argv.extend([text("--owner-uid")?, text(service_uid.to_string())?]);
    }
    argv.extend([
        path(&directory.join("launch").join("owner.lock"))?,
        path(&directory.join("intent.bin"))?,
        text(placement)?,
        text(launch.epoch.to_string())?,
        text(launch.generation.to_string())?,
        path(&tools.jailer)?,
        text("--id")?,
        text(placement)?,
        text("--exec-file")?,
        path(&tools.firecracker)?,
        text("--uid")?,
        text(launch.uid.to_string())?,
        text("--gid")?,
        text(launch.uid.to_string())?,
        text("--cgroup-version")?,
        text("2")?,
        text("--parent-cgroup")?,
        text(format!("lilly.slice/{unit}"))?,
        text("--chroot-base-dir")?,
        path(&pool.join(".lilly-jails"))?,
        text("--netns")?,
        text(format!("/run/netns/{namespace}"))?,
        text("--resource-limit")?,
        text("no-file=2048")?,
        text("--")?,
        text("--api-sock")?,
        text("/api.sock")?,
    ]);
    if !launch.restore {
        argv.extend([text("--config-file")?, text("/firecracker.json")?]);
    }
    if launch.firmware {
        argv.push(text("--enable-pci")?);
        if !launch.restore {
            argv.extend([text("--metadata")?, text("/metadata.json")?]);
        }
    }
    if launch.logging {
        let suffix = format!("{}-{}.fifo", launch.epoch, launch.generation);
        argv.extend([
            text("--level")?,
            text("Info")?,
            text("--log-path")?,
            text(format!("/log-{suffix}"))?,
            text("--metrics-path")?,
            text(format!("/metrics-{suffix}"))?,
        ]);
    } else {
        argv.extend([text("--level")?, text("Off")?]);
    }
    Ok(argv)
}
