use crate::namespace_ops;
use crate::plan::{
    classify_line, plan, MountState, NamespaceObservation, Setup, StepOutcome, SweepPlan,
    SweepResult,
};
use crate::{MAX_DESCRIPTORS, MAX_LINE, MAX_NAMESPACES, MAX_PROCESSES};
use rustix::fs::{openat, Mode, OFlags};
use rustix::io::Errno;
use rustix::mount::{unmount, UnmountFlags};
use std::io::{BufRead, BufReader};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

/// One retained foreign namespace: the open descriptor pins the namespace so a
/// later referent-process exit cannot slip the sweeped state out of scope.
struct Retained {
    fd: std::fs::File,
    observation: NamespaceObservation,
}

pub(crate) fn inspect_path(mountinfo: &Path, dataset: &str, target: &str) -> MountState {
    let Ok(file) = std::fs::File::open(mountinfo) else {
        return MountState::InspectError;
    };
    inspect_file(file, dataset, target)
}

fn inspect_file(file: std::fs::File, dataset: &str, target: &str) -> MountState {
    let reader = BufReader::new(file);
    let mut seen: Option<MountState> = None;
    for line in reader.lines() {
        let Ok(line) = line else {
            return MountState::InspectError;
        };
        if line.len() > MAX_LINE {
            return MountState::InspectError;
        }
        match classify_line(line.as_bytes(), dataset.as_bytes(), target.as_bytes()) {
            MountState::Absent => {}
            MountState::Exact => {
                if seen == Some(MountState::Exact) {
                    return MountState::Unsafe;
                }
                seen = Some(MountState::Exact);
            }
            MountState::Unsafe => return MountState::Unsafe,
            MountState::InspectError => return MountState::InspectError,
        }
    }
    seen.unwrap_or(MountState::Absent)
}

/// @cc [owner:ghuntley,label:security;recovery] namespace-current-inventory-via-host-proc
/// Foreign namespace inventories MUST open self/mountinfo after namespace entry
/// through the pinned host proc directory, even when that namespace hides proc.
/// A pre-opened host mountinfo file MUST NOT substitute for current inventory.
/// Failure to open or classify current inventory MUST remain unconfirmed.
fn inspect_current(proc_root: &std::fs::File, dataset: &str, target: &str) -> MountState {
    match openat(
        proc_root,
        "self/mountinfo",
        OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(file) => inspect_file(std::fs::File::from(file), dataset, target),
        Err(_) => MountState::InspectError,
    }
}

fn namespace_id(path: &str) -> Option<(u64, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.dev(), metadata.ino()))
}

/// Inspect a pinned namespace without requiring a process to inhabit it.
fn inspect_namespace(
    namespace: &std::fs::File,
    host: &std::fs::File,
    proc_root: &std::fs::File,
    dataset: &str,
    path: &str,
) -> Result<MountState, ()> {
    namespace_ops::enter(namespace.as_raw_fd())?;
    let state = inspect_current(proc_root, dataset, path);
    namespace_ops::enter(host.as_raw_fd())?;
    Ok(state)
}

/// Enter a foreign mount namespace, re-inspect and unmount the exact root,
/// then restore the host namespace. EXACT is reconfirmed inside the namespace;
/// ABSENT is already clean; everything else fails closed.
fn sweeper_step(
    retained: &Retained,
    host: &std::fs::File,
    proc_root: &std::fs::File,
    dataset: &str,
    path: &str,
) -> StepOutcome {
    if namespace_ops::enter(retained.fd.as_raw_fd()).is_err() {
        return StepOutcome::Unconfirmed;
    }
    let outcome = match inspect_current(proc_root, dataset, path) {
        MountState::Absent => StepOutcome::Absent,
        MountState::Exact => match unmount(path, UnmountFlags::empty()) {
            Ok(()) => StepOutcome::Unmounted,
            Err(Errno::BUSY) => StepOutcome::Busy,
            Err(_) => StepOutcome::Unconfirmed,
        },
        _ => StepOutcome::Unconfirmed,
    };
    if namespace_ops::enter(host.as_raw_fd()).is_err() {
        // Stranded mid-sweep: refuse to claim anything (failure is recorded by
        // the productive path's exit map).
        return StepOutcome::Unconfirmed;
    }
    outcome
}

/// @cc [owner:ghuntley,label:security;recovery] namespace-unmount-exact-owned-root
/// The caller holds Lilly's host lock and has fenced and GUID-verified the
/// child. The helper MUST run in PID 1's mount namespace; a private caller
/// namespace cannot reinterpret the host mount as a foreign cleanup target.
/// Only ordinary unmounts of its exact ZFS root at the canonical path are
/// allowed. Any alias, nested mount, unreadable inventory, live user or
/// detected race fails closed. Never force, lazily detach, kill a process, or
/// expose path diagnostics.
/// Namespace descriptors held by processes MUST also be inventoried: an empty
/// namespace pinned by a descriptor can retain the dataset after its last
/// inhabitant exits. Descriptor discovery MUST precede every unmount and retain
/// the same exact-root, race, busy and inventory bounds as inhabited namespaces.
#[expect(
    clippy::too_many_lines,
    reason = "one reviewed fail-closed walk: identity, inventory, retention, plan and unmount stay in order"
)]
pub fn sweep(dataset: &str, path: &str) -> Result<SweepResult, Setup> {
    let Some(host_id) = namespace_id("/proc/self/ns/mnt") else {
        return Err(Setup::InventoryUnavailable);
    };
    let Some(initial_id) = namespace_id("/proc/1/ns/mnt") else {
        return Err(Setup::InventoryUnavailable);
    };
    if host_id != initial_id {
        return Err(Setup::WrongCallerNamespace);
    }
    let Ok(host) = std::fs::File::open("/proc/self/ns/mnt") else {
        return Err(Setup::InventoryUnavailable);
    };
    let Ok(proc_root) = std::fs::File::open("/proc") else {
        return Err(Setup::InventoryUnavailable);
    };
    let Ok(listing) = std::fs::read_dir("/proc") else {
        return Err(Setup::InventoryUnavailable);
    };
    let mut retained: Vec<Retained> = Vec::new();
    let mut inspected = 0_usize;
    let mut descriptors = 0_usize;
    let mut observed: Vec<NamespaceObservation> = Vec::new();
    for entry in listing {
        let Ok(entry) = entry else {
            return Ok(SweepResult::Unconfirmed);
        };
        let name_bytes = entry.file_name();
        if !name_bytes
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_digit)
        {
            continue;
        }
        inspected += 1;
        if inspected > MAX_PROCESSES {
            return Ok(SweepResult::Unconfirmed);
        }
        // Nix can retain a build namespace descriptor after the builder exits.
        // /proc/PID/mountinfo then describes the daemon's host namespace, not
        // the retained namespace, so inspect through the pinned descriptor.
        let listing = match std::fs::read_dir(entry.path().join("fd")) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Ok(SweepResult::Unconfirmed),
            Ok(listing) => listing,
        };
        for descriptor in listing {
            descriptors += 1;
            if descriptors > MAX_DESCRIPTORS {
                return Ok(SweepResult::Unconfirmed);
            }
            let Ok(descriptor) = descriptor else {
                return Ok(SweepResult::Unconfirmed);
            };
            let link = match std::fs::read_link(descriptor.path()) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => return Ok(SweepResult::Unconfirmed),
                Ok(link) => link,
            };
            let bytes = link.as_os_str().as_bytes();
            if !bytes.starts_with(b"mnt:[") || !bytes.ends_with(b"]") {
                continue;
            }
            // The descriptor may be reused after read_link. Never block if it
            // races to a FIFO; setns still rejects every non-mount-namespace FD.
            let ns_file = match std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(descriptor.path())
            {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => return Ok(SweepResult::Unconfirmed),
                Ok(file) => file,
            };
            let Ok(metadata) = ns_file.metadata() else {
                return Ok(SweepResult::Unconfirmed);
            };
            let key = (metadata.dev(), metadata.ino());
            if key == host_id || retained.iter().any(|prior| prior.observation.key == key) {
                continue;
            }
            let state = match inspect_namespace(&ns_file, &host, &proc_root, dataset, path) {
                Err(()) => return Ok(SweepResult::Unconfirmed),
                Ok(state) => state,
            };
            match state {
                MountState::Absent => continue,
                MountState::Exact => {}
                _ => return Ok(SweepResult::Unconfirmed),
            }
            if retained.len() == MAX_NAMESPACES {
                return Ok(SweepResult::Unconfirmed);
            }
            let observation = NamespaceObservation { key, state };
            observed.push(observation);
            retained.push(Retained {
                fd: ns_file,
                observation,
            });
        }
        let ns_path = entry.path().join("ns").join("mnt");
        let info_path = entry.path().join("mountinfo");
        let ns_file = match std::fs::File::open(&ns_path) {
            Err(error) if matches!(error.kind(), std::io::ErrorKind::NotFound) => continue,
            Err(_) => return Ok(SweepResult::Unconfirmed),
            Ok(file) => file,
        };
        let Ok(metadata) = ns_file.metadata() else {
            return Ok(SweepResult::Unconfirmed);
        };
        if metadata.dev() == host_id.0 && metadata.ino() == host_id.1 {
            continue;
        }
        if retained
            .iter()
            .any(|prior| prior.observation.key == (metadata.dev(), metadata.ino()))
        {
            continue;
        }
        let state = inspect_path(&info_path, dataset, path);
        match state {
            MountState::InspectError => {
                // A referent exited mid-inspection is skipped, matching the C
                // ENOENT-on-namespace fallback.
                if !ns_path.exists() {
                    continue;
                }
                return Ok(SweepResult::Unconfirmed);
            }
            MountState::Unsafe => return Ok(SweepResult::Unconfirmed),
            MountState::Absent => continue,
            MountState::Exact => {}
        }
        if retained.len() == MAX_NAMESPACES {
            return Ok(SweepResult::Unconfirmed);
        }
        let observation = NamespaceObservation {
            key: (metadata.dev(), metadata.ino()),
            state,
        };
        observed.push(observation);
        retained.push(Retained {
            fd: ns_file,
            observation,
        });
    }
    let SweepPlan::Plan(keys) = plan(&observed) else {
        return Ok(SweepResult::Unconfirmed);
    };
    let mut cleaned = 0_usize;
    for key in keys {
        let Some(retained_ns) = retained.iter().find(|r| r.observation.key == key) else {
            return Ok(SweepResult::Unconfirmed);
        };
        match sweeper_step(retained_ns, &host, &proc_root, dataset, path) {
            StepOutcome::Unmounted => cleaned += 1,
            StepOutcome::Absent => {}
            StepOutcome::Busy => return Ok(SweepResult::Busy),
            StepOutcome::Unconfirmed => return Ok(SweepResult::Unconfirmed),
        }
    }
    Ok(SweepResult::Cleaned(cleaned))
}
