#![deny(unsafe_code)]
#![doc = "Non-setuid generation fence, invoked inside the systemd service immediately"]
#![doc = "before jailer. Hold a shared lock across exec: jailer closes inherited FDs"]
#![doc = "only once its process already belongs to the service's killable cgroup."]
#![doc = "No shell, environment lookup, logging or remote command interpretation."]

use rustix::fs::{flock, open, FlockOperation, Mode as FileMode, OFlags};
use rustix::io::Errno;
use std::ffi::{OsStr, OsString};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_EXEC: u8 = 71;
pub const EXIT_CUSTODY: u8 = 74;
pub const EXIT_STALE_INTENT: u8 = 75;

/// Intent record size: 36-byte placement UUID, two big-endian u64 counters and
/// the running-state byte.
pub const INTENT_BYTES: usize = 53;
/// The intent state byte that authorizes launching jailer.
pub const RUNNING_STATE: u8 = 1;

/// Validated, custody-authorized request.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub lock: PathBuf,
    pub intent: PathBuf,
    pub placement: String,
    pub epoch: u64,
    pub generation: u64,
    pub program: PathBuf,
    pub arguments: Vec<OsString>,
    /// A second uid allowed to own the lock and intent files (an unprivileged
    /// Lilly's service uid); None accepts only the guard's own uid.
    pub owner: Option<u32>,
}

/// A structurally framed intent payload.
#[derive(Debug, Eq, PartialEq)]
pub struct Intent {
    pub placement: [u8; 36],
    pub epoch: u64,
    pub generation: u64,
    pub state: u8,
}

fn parse_placement(unparsed: &OsStr) -> Option<String> {
    let bytes = unparsed.as_bytes();
    if bytes.len() != 36 {
        return None;
    }
    for (index, byte) in bytes.iter().enumerate() {
        let dash = matches!(index, 8 | 13 | 18 | 23);
        if dash != (*byte == b'-') {
            return None;
        }
        // Exact lowercase wire form; the C predecessor never normalized case.
        if !dash && !matches!(byte, b'0'..=b'9' | b'a'..=b'f') {
            return None;
        }
    }
    // Every byte was checked to be ASCII hex or a dash above, so the UTF-8
    // conversion cannot refuse; `.ok()` keeps the parser total regardless.
    String::from_utf8(bytes.to_vec()).ok()
}

fn counter(unparsed: &OsStr) -> Option<u64> {
    let bytes = unparsed.as_bytes();
    if bytes.is_empty() || bytes[0] == b'0' || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let value: u64 = text.parse().ok()?;
    (1..=i64::MAX.unsigned_abs())
        .contains(&value)
        .then_some(value)
}

/// Validate the command line: an optional `--owner-uid N` (N a nonzero uid),
/// absolute lock and intent paths, exact placement UUID, two affirmative
/// decimal counters and an absolute executable.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let (owner, arguments) = match arguments {
        [flag, uid_bytes, rest @ ..] if flag.as_bytes() == b"--owner-uid" => {
            let uid: u32 = std::str::from_utf8(uid_bytes.as_bytes())
                .ok()?
                .parse()
                .ok()?;
            // Canonical decimal only: no sign, no leading zero, never root.
            if uid == 0 || uid.to_string().as_bytes() != uid_bytes.as_bytes() {
                return None;
            }
            (Some(uid), rest)
        }
        _ => (None, arguments),
    };
    let [lock, intent, placement_text, epoch, generation, program, rest @ ..] = arguments else {
        return None;
    };
    for absolute in [lock, intent, program] {
        if !absolute.as_os_str().as_bytes().starts_with(b"/") {
            return None;
        }
    }
    Some(Request {
        lock: PathBuf::from(lock),
        intent: PathBuf::from(intent),
        placement: parse_placement(placement_text)?,
        epoch: counter(epoch)?,
        generation: counter(generation)?,
        program: PathBuf::from(program),
        arguments: rest.to_vec(),
        owner,
    })
}

/// The descriptor must be a private, single-link, owner-exclusive regular file
/// of exactly `expected_size`, never a symlink resolution, and never one of the
/// process standard descriptors.
fn acquire_fd(
    path: &Path,
    expected_size: u64,
    cloexec: bool,
    owner: Option<u32>,
) -> Result<OwnedFd, ()> {
    let mut flags = OFlags::RDONLY | OFlags::NOFOLLOW;
    if cloexec {
        flags |= OFlags::CLOEXEC;
    }
    let fd = open(path, flags, FileMode::empty()).map_err(|_| ())?;
    if fd.as_raw_fd() < 3 {
        return Err(());
    }
    let file: std::fs::File = fd.into();
    let metadata = file.metadata().map_err(|_| ())?;
    let fd: OwnedFd = file.into();
    let private = metadata.is_file()
        && metadata.nlink() == 1
        && (metadata.uid() == rustix::process::geteuid().as_raw() || Some(metadata.uid()) == owner)
        && metadata.mode() & 0o777 == 0o600
        && metadata.len() == expected_size;
    if private {
        Ok(fd)
    } else {
        Err(())
    }
}

/// Why intent bytes are not a frame: closed category, nothing to classify.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IntentError {
    Framing,
}

/// Read exactly `INTENT_BYTES`; anything else is a framing failure.
pub fn read_intent(intent: &OwnedFd) -> Result<Intent, IntentError> {
    let mut bytes = [0_u8; INTENT_BYTES];
    let mut used = 0;
    while used < INTENT_BYTES {
        match rustix::io::read(intent, &mut bytes[used..]) {
            Err(Errno::INTR) => {}
            Err(_) | Ok(0) => return Err(IntentError::Framing),
            Ok(count) => used += count,
        }
    }
    decode_intent(&bytes)
}

/// Decode one intent frame: exactly `INTENT_BYTES`, laid out as the 36-byte
/// placement, big-endian epoch, big-endian generation and the state byte.
/// Any other length is a framing failure. Pure, so the frame layout can be
/// checked without a descriptor.
pub fn decode_intent(bytes: &[u8]) -> Result<Intent, IntentError> {
    let bytes: &[u8; INTENT_BYTES] = bytes.try_into().map_err(|_| IntentError::Framing)?;
    Ok(Intent {
        placement: bytes[0..36].try_into().map_err(|_| IntentError::Framing)?,
        epoch: u64::from_be_bytes(bytes[36..44].try_into().map_err(|_| IntentError::Framing)?),
        generation: u64::from_be_bytes(bytes[44..52].try_into().map_err(|_| IntentError::Framing)?),
        state: bytes[52],
    })
}

/// @cc [owner:ghuntley,label:recovery] launch-only-current-running-generation
/// The intent payload MUST contain exactly the requested placement, epoch,
/// generation and running state before jailer exec; missing, corrupt, stale,
/// stopped, failed or deleted intent fails without launching a VM.
pub fn current(intent: &Intent, request: &Request) -> bool {
    intent.placement[..] == request.placement.as_bytes()[..]
        && intent.epoch == request.epoch
        && intent.generation == request.generation
        && intent.state == RUNNING_STATE
}

/// @cc [owner:ghuntley,label:recovery] launch-lock-crosses-exec
/// Guarded custody sequence; on success this call replaces the process image.
/// The shared intent lock MUST remain acquired across exec; do not close it or
/// mark it CLOEXEC. A stopped or fenced intent must never race the generation
/// check against entering the owned jailer.
pub fn run(request: &Request) -> u8 {
    let Ok(lock) = acquire_fd(&request.lock, 0, false, request.owner) else {
        return EXIT_CUSTODY;
    };
    let acquired = loop {
        match flock(&lock, FlockOperation::LockShared) {
            Err(Errno::INTR) => {}
            result => break result,
        }
    };
    if acquired.is_err() {
        return EXIT_CUSTODY;
    }
    let valid = match acquire_fd(&request.intent, INTENT_BYTES as u64, true, request.owner) {
        Err(()) => return EXIT_CUSTODY,
        Ok(intent) => read_intent(&intent),
    };
    match valid {
        Err(IntentError::Framing) => EXIT_CUSTODY,
        Ok(intent) if !current(&intent, request) => EXIT_STALE_INTENT,
        Ok(_) => {
            let error = std::process::Command::new(&request.program)
                .args(&request.arguments)
                .exec();
            let _ = error;
            EXIT_EXEC
        }
    }
}

#[cfg(test)]
mod tests;
