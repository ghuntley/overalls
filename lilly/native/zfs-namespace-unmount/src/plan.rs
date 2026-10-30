use crate::{MAX_LINE, MAX_NAMESPACES, MAX_PROCESSES};

/// Classification of one mountinfo inventory against the requested pair.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MountState {
    Absent,
    Exact,
    Unsafe,
    InspectError,
}

/// What one sweep step reports per entered namespace.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StepOutcome {
    Unmounted,
    Busy,
    Absent,
    Unconfirmed,
}

/// Aggregate sweep result: the wire-visible contract to Lilly.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SweepResult {
    Cleaned(usize),
    Busy,
    Unconfirmed,
}

/// Identity/namespace setup diverged before any evidence could be produced.
/// These paths exit silently with 1, never a printed "unconfirmed".
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Setup {
    WrongCallerNamespace,
    InventoryUnavailable,
}

/// Character class both validators accept; names are pool-local identifiers.
pub(crate) fn clean(bytes: &[u8]) -> bool {
    bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_-/.:@".contains(byte))
}

/// @cc [owner:ghuntley,label:security] namespace-dataset-shape
/// A dataset name is 1..=255 bytes of the fixed character class with no
/// leading/trailing slash, no "//" run and no ".." substring.
pub fn valid_dataset(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes.len() > 255 || value.starts_with('/') || value.ends_with('/') {
        return false;
    }
    clean(bytes) && !value.contains("//") && !value.contains("..")
}

/// @cc [owner:ghuntley,label:security] namespace-path-shape
/// An absolute canonical path: 2..=4096 bytes of the fixed class, leading
/// slash, no trailing slash, no "//", "/./" or "/../" segments and no "/." or
/// "/.." terminal.
pub fn valid_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() < 2 || bytes.len() > 4096 || !value.starts_with('/') || value.ends_with('/') {
        return false;
    }
    clean(bytes)
        && !value.contains("//")
        && !value.contains("/../")
        && !value.contains("/./")
        && !value.ends_with("/..")
        && !value.ends_with("/.")
}

/// In-place octal escape decode ("\040" → ' '). False on malformed escapes.
pub(crate) fn decode_mount_field(field: &mut Vec<u8>) -> bool {
    let mut output = Vec::with_capacity(field.len());
    let mut index = 0;
    while index < field.len() {
        match field[index] {
            b'\\'
                if index + 3 < field.len()
                    && field[index + 1..=index + 3]
                        .iter()
                        .all(|byte| byte.is_ascii_digit() && *byte <= b'7') =>
            {
                let value = (field[index + 1] - b'0') * 64
                    + (field[index + 2] - b'0') * 8
                    + (field[index + 3] - b'0');
                output.push(value);
                index += 4;
            }
            b'\\' => return false,
            byte => {
                output.push(byte);
                index += 1;
            }
        }
    }
    *field = output;
    true
}

/// @cc [owner:ghuntley,label:verification] mount-inventory-rejects-ambiguous-roots
/// Classification MUST accept only one exact ZFS root and reject aliases,
/// descendants, duplicate roots and malformed inventories.
pub fn classify_line(line: &[u8], dataset: &[u8], target: &[u8]) -> MountState {
    if line.len() > MAX_LINE {
        return MountState::InspectError;
    }
    let fields: Vec<Vec<u8>> = line
        .split(|byte| *byte == b' ' || *byte == b'\n')
        .filter(|field| !field.is_empty())
        .map(<[u8]>::to_vec)
        .collect();
    if fields.len() > 256 || fields.len() < 10 {
        return MountState::InspectError;
    }
    let separator = fields[6..]
        .iter()
        .position(|field| field == b"-")
        .map(|position| position + 6);
    let Some(separator) = separator else {
        return MountState::InspectError;
    };
    if separator + 3 >= fields.len() {
        return MountState::InspectError;
    }
    let mut owned: Vec<Vec<u8>> = fields;
    for index in [3, 4, separator + 2] {
        if !decode_mount_field(&mut owned[index]) {
            return MountState::InspectError;
        }
    }
    let (root, mountpoint, fstype, source) = (
        &owned[3],
        &owned[4],
        &owned[separator + 1],
        &owned[separator + 2],
    );
    let related_source = source[..] == *dataset
        || (source.starts_with(dataset) && source.get(dataset.len()) == Some(&b'['));
    let related_target = mountpoint[..] == *target
        || (mountpoint.starts_with(target) && mountpoint.get(target.len()) == Some(&b'/'));
    if !related_source && !related_target {
        return MountState::Absent;
    }
    let exact = root[..] == *b"/"
        && mountpoint[..] == *target
        && source[..] == *dataset
        && fstype[..] == *b"zfs";
    if exact {
        MountState::Exact
    } else {
        MountState::Unsafe
    }
}

/// Classified namespace entry used in sweep planning.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NamespaceObservation {
    pub key: (u64, u64),
    pub state: MountState,
}

/// The sweep decision.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SweepPlan {
    /// Every host scan succeeded; unmount these foreign namespaces in order.
    Plan(Vec<(u64, u64)>),
    /// A scan error, violation or capacity overflow makes the sweep unsafe.
    Unconfirmed,
}

pub fn plan(observations: &[NamespaceObservation]) -> SweepPlan {
    let mut retained: Vec<(u64, u64)> = Vec::new();
    let mut inspected = 0_usize;
    for observation in observations {
        inspected += 1;
        if inspected > MAX_PROCESSES {
            return SweepPlan::Unconfirmed;
        }
        match observation.state {
            MountState::Unsafe | MountState::InspectError => return SweepPlan::Unconfirmed,
            MountState::Absent => {}
            MountState::Exact => {
                if retained.contains(&observation.key) {
                    continue;
                }
                if retained.len() == MAX_NAMESPACES {
                    return SweepPlan::Unconfirmed;
                }
                retained.push(observation.key);
            }
        }
    }
    SweepPlan::Plan(retained)
}
