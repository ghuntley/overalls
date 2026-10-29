#![deny(unsafe_code)]
#![doc = "lilly-hostd: the host-effects engine. Holds every Lilly lease and runs every host utility."]

pub mod descriptors;
pub mod exec;
pub mod files;
pub mod ingress;
pub mod leases;
pub mod mounts;
pub mod nft_policy;
pub mod policy;
pub mod protocol;
pub mod session;
pub mod transfer;
pub mod utilities;
pub mod vm_launch;
pub mod zfs_policy;

use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

/// Parsed command line.
#[derive(Debug, Eq, PartialEq)]
pub struct Options {
    pub socket: PathBuf,
    pub roots: Vec<PathBuf>,
    /// `Some(None)` means "the cgroup hostd was started in".
    pub cgroup: Option<Option<PathBuf>>,
    pub peer_uid: Option<u32>,
    /// The uid Lilly's state belongs to; the peer uid when absent.
    pub service_uid: Option<u32>,
    pub peer_cgroups: Vec<Vec<u8>>,
    /// Exit when stdin reaches EOF (test harnesses that own the daemon).
    pub stdin_lifetime: bool,
    /// Roots for Firecracker API and vsock sockets (jails).
    pub socket_roots: Vec<PathBuf>,
    /// Pool datasets ZFS mutations must stay beneath; none disables the grammar
    /// (a private daemon runs with its owner's privilege anyway).
    pub pool_datasets: Vec<Vec<u8>>,
    /// Roots for native file effects; the lease roots when none are given.
    pub file_roots: Vec<PathBuf>,
    /// Executables and the VM state directory for typed VM launches.
    pub vm_tools: Option<vm_launch::Tools>,
    /// Detached ingress bridges: Audi's user name and the slice their scopes
    /// run in (ADR-0187); both or neither.
    pub ingress: Option<(String, String)>,
}

/// @cc [owner:ghuntley,label:security] hostd-options-absolute
/// parse_options MUST accept only absolute socket, root and cgroup paths,
/// at least one root, numeric peer and service uids, absolute peer cgroup paths and the
/// bare `--stdin-lifetime` flag, and either all five absolute `--vm-*`
/// paths or none of them, and either no `--pool-dataset` or exactly one per
/// `--socket-root` (paired in order), and either both or neither of
/// `--ingress-peer-user` (a system user name) and `--ingress-slice` (a
/// top-level slice, ingress-slice-name), and
/// return None for any unknown, repeated singular or malformed argument.
pub fn parse_options(arguments: &[OsString]) -> Option<Options> {
    let mut socket = None;
    let mut roots = Vec::new();
    let mut cgroup = None;
    let mut peer_uid = None;
    let mut service_uid = None;
    let mut peer_cgroups = Vec::new();
    let mut stdin_lifetime = false;
    let mut socket_roots = Vec::new();
    let mut file_roots = Vec::new();
    let mut pool_datasets = Vec::new();
    let mut vm: [Option<PathBuf>; 5] = Default::default();
    let mut ingress_user: Option<String> = None;
    let mut ingress_slice: Option<String> = None;
    let mut iterator = arguments.iter();
    while let Some(flag) = iterator.next() {
        if flag.as_bytes() == b"--stdin-lifetime" && !stdin_lifetime {
            stdin_lifetime = true;
            continue;
        }
        let value = iterator.next()?;
        let absolute = value.as_bytes().starts_with(b"/");
        match flag.as_bytes() {
            b"--socket" if socket.is_none() && absolute => socket = Some(PathBuf::from(value)),
            b"--root" if absolute => roots.push(PathBuf::from(value)),
            b"--cgroup" if cgroup.is_none() && value.as_bytes() == b"self" => cgroup = Some(None),
            b"--cgroup" if cgroup.is_none() && absolute => {
                cgroup = Some(Some(PathBuf::from(value)))
            }
            b"--peer-uid" if peer_uid.is_none() => {
                peer_uid = Some(std::str::from_utf8(value.as_bytes()).ok()?.parse().ok()?)
            }
            b"--service-uid" if service_uid.is_none() => {
                service_uid = Some(std::str::from_utf8(value.as_bytes()).ok()?.parse().ok()?)
            }
            b"--peer-cgroup" if absolute => peer_cgroups.push(value.as_bytes().to_vec()),
            b"--socket-root" if absolute => socket_roots.push(PathBuf::from(value)),
            b"--file-root" if absolute => file_roots.push(PathBuf::from(value)),
            b"--pool-dataset" if !absolute && !value.is_empty() => {
                pool_datasets.push(value.as_bytes().to_vec())
            }
            b"--ingress-peer-user" if ingress_user.is_none() => {
                let name = value.to_str()?;
                if !valid_user(name) {
                    return None;
                }
                ingress_user = Some(name.to_owned());
            }
            b"--ingress-slice" if ingress_slice.is_none() => {
                let name = value.to_str()?;
                if !ingress::valid_slice(name) {
                    return None;
                }
                ingress_slice = Some(name.to_owned());
            }
            flag if absolute && VM_FLAGS.contains(&flag) => {
                let slot = &mut vm[VM_FLAGS.iter().position(|known| *known == flag)?];
                if slot.replace(PathBuf::from(value)).is_some() {
                    return None;
                }
            }
            _ => return None,
        }
    }
    // Each pool dataset pairs, in order, with its pool directory.
    if roots.is_empty() || (!pool_datasets.is_empty() && pool_datasets.len() != socket_roots.len())
    {
        return None;
    }
    let vm_tools = match vm {
        [None, None, None, None, None] => None,
        [Some(boot_log), Some(unshare), Some(launch_guard), Some(jailer), Some(firecracker)] => {
            Some(vm_launch::Tools {
                boot_log,
                unshare,
                launch_guard,
                jailer,
                firecracker,
            })
        }
        _ => return None,
    };
    let ingress = match (ingress_user, ingress_slice) {
        (None, None) => None,
        (Some(user), Some(slice)) => Some((user, slice)),
        _ => return None,
    };
    Some(Options {
        socket: socket?,
        roots,
        cgroup,
        peer_uid,
        service_uid,
        peer_cgroups,
        stdin_lifetime,
        socket_roots,
        file_roots,
        pool_datasets,
        vm_tools,
        ingress,
    })
}

/// A system user name: 1 to 32 lowercase letters, digits, `_` or `-`,
/// starting with a letter or `_`.
fn valid_user(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 32
        && (bytes[0].is_ascii_lowercase() || bytes[0] == b'_')
        && bytes.iter().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_' || *byte == b'-'
        })
}

/// @cc [owner:ghuntley,label:security] ingress-peer-uid-from-passwd
/// passwd_uid MUST return the uid of exactly the line whose first field is
/// `name` in passwd(5) text, and None when no line or more than one line
/// names it, or the uid field is not a decimal u32. hostd resolves Audi's
/// dynamic uid this way once at startup.
pub fn passwd_uid(passwd: &[u8], name: &str) -> Option<u32> {
    let mut found = None;
    for line in passwd.split(|byte| *byte == b'\n') {
        let mut fields = line.split(|byte| *byte == b':');
        if fields.next() != Some(name.as_bytes()) {
            continue;
        }
        let uid = fields.nth(1)?;
        if found.is_some() || uid.is_empty() || !uid.iter().all(u8::is_ascii_digit) {
            return None;
        }
        found = Some(std::str::from_utf8(uid).ok()?.parse().ok()?);
    }
    found
}

impl Options {
    /// Configured pools: each `--pool-dataset` with the `--socket-root` at
    /// the same position (parse_options requires equal counts).
    pub fn pools(&self) -> Vec<(Vec<u8>, PathBuf)> {
        self.pool_datasets
            .iter()
            .cloned()
            .zip(self.socket_roots.iter().cloned())
            .collect()
    }
}

/// The `--vm-*` flags, in `vm_launch::Tools` field order.
const VM_FLAGS: [&[u8]; 5] = [
    b"--vm-boot-log",
    b"--vm-unshare",
    b"--vm-launch-guard",
    b"--vm-jailer",
    b"--vm-firecracker",
];

/// The cgroup v2 directory of this process.
pub fn own_cgroup() -> Option<PathBuf> {
    let contents = std::fs::read("/proc/self/cgroup").ok()?;
    let path = contents
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"0::"))?;
    let mut directory = PathBuf::from("/sys/fs/cgroup");
    directory.push(std::ffi::OsStr::from_bytes(path.strip_prefix(b"/")?));
    Some(directory)
}

#[cfg(test)]
mod descriptor_resolution;
#[cfg(test)]
mod descriptor_tests;
#[cfg(test)]
mod files_tests;
#[cfg(test)]
mod ingress_tests;
#[cfg(test)]
mod policy_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod transfer_tests;
#[cfg(test)]
mod zfs_policy_tests;
