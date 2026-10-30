//! Closed local producer protocol and kernel process attribution for request SLOs.

use crate::durable_slo::{Outcome, Producer, Source, State, Store, MAX_PENDING};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const FRAME_LIMIT: usize = 512;
const HEARTBEAT_NS: u64 = 15_000_000_000;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub version: u8,
    pub command: Command,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Hello {},
    Admit {},
    Gap {},
    Finish {
        id: u64,
        outcome: Terminal,
        duration_us: u64,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Terminal {
    Success,
    Failure,
    Exclude,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    Version,
    Schema,
    Producer,
    Capacity,
    Accounting,
    Storage,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum Reply {
    Ok {},
    Admitted { id: u64 },
    Refused { reason: Refusal },
}

#[derive(Clone, Debug)]
pub struct Policy {
    pub user: String,
    pub unit: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Liveness {
    Alive,
    Dead,
    Unknown,
}

fn boot_id() -> Result<String, Refusal> {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|value| value.trim().to_owned())
        .map_err(|_| Refusal::Producer)
        .and_then(|value| {
            if value.len() == 36
                && value.bytes().enumerate().all(|(index, byte)| {
                    if [8, 13, 18, 23].contains(&index) {
                        byte == b'-'
                    } else {
                        byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()
                    }
                })
            {
                Ok(value)
            } else {
                Err(Refusal::Producer)
            }
        })
}

fn missing_proc_liveness(pid: u32) -> Liveness {
    match pidfd(pid) {
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Liveness::Dead,
        Ok(descriptor) => match exited(&descriptor) {
            Ok(true) => Liveness::Dead,
            _ => Liveness::Unknown,
        },
        Err(_) => Liveness::Unknown,
    }
}

/// @cc [owner:ghuntley,label:security;recovery] request-process-incarnation
/// Process identity MUST use kernel PID, start ticks and boot ID. Command names
/// containing spaces or parentheses MUST NOT shift the parsed start-time field.
fn process_ticks(pid: u32) -> Result<u64, std::io::Error> {
    let value = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
    parse_ticks(&value, pid).ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidData))
}

fn parse_ticks(value: &str, pid: u32) -> Option<u64> {
    let (identity, fields) = value.rsplit_once(") ")?;
    let (found, _) = identity.split_once(" (")?;
    if found.parse::<u32>().ok()? != pid {
        return None;
    }
    fields.split_whitespace().nth(19)?.parse().ok()
}

fn pidfd(pid: u32) -> Result<OwnedFd, std::io::Error> {
    let descriptor = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if descriptor < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(descriptor as i32) })
    }
}

fn exited(descriptor: &OwnedFd) -> Result<bool, std::io::Error> {
    let mut poll = libc::pollfd {
        fd: descriptor.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    if unsafe { libc::poll(&mut poll, 1, 0) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if poll.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
        return Err(std::io::Error::from(std::io::ErrorKind::Other));
    }
    Ok(poll.revents & (libc::POLLIN | libc::POLLHUP) != 0)
}

/// @cc [owner:ghuntley,label:reliability;recovery] request-death-proof
/// Missing boot identity, unreadable proc state and unavailable pidfds MUST
/// remain unknown. Only changed boot/start identity, confirmed PID absence or
/// readable exited pidfd may prove death; recorder restart alone MUST NOT.
pub fn liveness(producer: &Producer) -> Liveness {
    match boot_id() {
        Ok(current) if current != producer.boot_id => return Liveness::Dead,
        Err(_) => return Liveness::Unknown,
        _ => {}
    }
    match process_ticks(producer.pid) {
        Ok(ticks) if ticks != producer.start_ticks => return Liveness::Dead,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return missing_proc_liveness(producer.pid)
        }
        Err(_) => return Liveness::Unknown,
        _ => {}
    }
    let descriptor = match pidfd(producer.pid) {
        Ok(descriptor) => descriptor,
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => return Liveness::Dead,
        Err(_) => return Liveness::Unknown,
    };
    match process_ticks(producer.pid) {
        Ok(ticks) if ticks == producer.start_ticks => match exited(&descriptor) {
            Ok(true) => Liveness::Dead,
            Ok(false) => Liveness::Alive,
            Err(_) => Liveness::Unknown,
        },
        Ok(_) => Liveness::Dead,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => match exited(&descriptor) {
            Ok(true) => Liveness::Dead,
            _ => Liveness::Unknown,
        },
        Err(_) => Liveness::Unknown,
    }
}

fn user_uid(name: &str) -> Result<u32, Refusal> {
    let name = CString::new(name).map_err(|_| Refusal::Producer)?;
    // The runtime is single-threaded: copy the NSS result before another lookup.
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    if entry.is_null() {
        Err(Refusal::Producer)
    } else {
        Ok(unsafe { (*entry).pw_uid })
    }
}

fn unit_matches(cgroup: &str, unit: &str) -> bool {
    cgroup.lines().any(|line| {
        line.strip_prefix("0::")
            .is_some_and(|path| path.split('/').any(|component| component == unit))
    })
}

/// @cc [owner:ghuntley,label:security] request-producer-kernel-attribution
/// Each connection MUST match its configured Unix peer UID and cgroup v2
/// systemd unit. Payload fields MUST NOT choose PID, UID, unit or source.
/// The process incarnation MUST still match after unit attribution.
pub fn authenticate(stream: &UnixStream, policy: &Policy) -> Result<Producer, Refusal> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut size,
        )
    };
    if result != 0
        || size as usize != std::mem::size_of::<libc::ucred>()
        || credentials.pid <= 0
        || credentials.uid != user_uid(&policy.user)?
    {
        return Err(Refusal::Producer);
    }
    let pid = credentials.pid as u32;
    let producer = Producer {
        pid,
        start_ticks: process_ticks(pid).map_err(|_| Refusal::Producer)?,
        boot_id: boot_id()?,
    };
    let cgroup =
        std::fs::read_to_string(format!("/proc/{pid}/cgroup")).map_err(|_| Refusal::Producer)?;
    if !unit_matches(&cgroup, &policy.unit) || liveness(&producer) != Liveness::Alive {
        return Err(Refusal::Producer);
    }
    Ok(producer)
}

/// @cc [owner:ghuntley,label:security;capacity] request-recorder-bounded-frame
/// Frames MUST have a four-byte length and at most 512 JSON bytes. Unknown
/// fields, operations and versions MUST be refused before accounting changes.
pub fn read_frame(stream: &mut impl Read) -> Result<Envelope, Refusal> {
    let mut header = [0_u8; 4];
    stream
        .read_exact(&mut header)
        .map_err(|_| Refusal::Schema)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > FRAME_LIMIT {
        return Err(Refusal::Schema);
    }
    let mut bytes = vec![0_u8; length];
    stream.read_exact(&mut bytes).map_err(|_| Refusal::Schema)?;
    let envelope: Envelope = serde_json::from_slice(&bytes).map_err(|_| Refusal::Schema)?;
    if envelope.version != 1 {
        return Err(Refusal::Version);
    }
    Ok(envelope)
}

pub fn write_frame(stream: &mut impl Write, reply: &Reply) -> Result<(), Refusal> {
    let bytes = serde_json::to_vec(reply).map_err(|_| Refusal::Schema)?;
    if bytes.len() > FRAME_LIMIT {
        return Err(Refusal::Schema);
    }
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .and_then(|()| stream.write_all(&bytes))
        .map_err(|_| Refusal::Schema)
}

pub struct Runtime {
    pub store: Store,
    pub policy: Policy,
    pub deadline_ns: u64,
    heartbeat: Option<(Producer, u64)>,
}

impl Runtime {
    pub fn new(store: Store, policy: Policy, deadline_ns: u64) -> Result<Self, Refusal> {
        if !(1_000_000_000..=86_400_000_000_000).contains(&deadline_ns)
            || !policy.unit.ends_with(".service")
            || policy.unit.contains('/')
            || policy.unit.len() > 128
            || policy.user.is_empty()
        {
            return Err(Refusal::Schema);
        }
        Ok(Self {
            store,
            policy,
            deadline_ns,
            heartbeat: None,
        })
    }

    pub fn reconcile(&mut self, now_ns: u64) -> Result<(), Refusal> {
        let state = self.store.state().map_err(|_| Refusal::Storage)?;
        let mut dead: Vec<Producer> = Vec::new();
        let mut checked: HashSet<Producer> = HashSet::new();
        for admission in state.pending.values() {
            if checked.insert(admission.producer.clone())
                && liveness(&admission.producer) == Liveness::Dead
            {
                dead.push(admission.producer.clone());
            }
        }
        if !dead.is_empty() || state.pending.values().any(|a| now_ns >= a.deadline_ns) {
            self.store
                .transition(|state| state.reconcile(now_ns, &dead))
                .map_err(|_| Refusal::Storage)?;
        }
        Ok(())
    }

    pub fn apply(&mut self, producer: Producer, command: Command, now_ns: u64) -> Reply {
        let result = match command {
            Command::Hello {} => self.store.state().map(|_| Reply::Ok {}),
            Command::Gap {} => self
                .store
                .transition(|state| state.mark_gap(now_ns))
                .map(|()| Reply::Ok {}),
            Command::Admit {} => {
                let deadline = match now_ns.checked_add(self.deadline_ns) {
                    Some(deadline) => deadline,
                    None => {
                        return Reply::Refused {
                            reason: Refusal::Accounting,
                        }
                    }
                };
                self.store
                    .transition(|state| state.admit(producer.clone(), now_ns, deadline))
                    .map(|id| Reply::Admitted { id })
            }
            Command::Finish {
                id,
                outcome,
                duration_us,
            } => {
                let outcome = match outcome {
                    Terminal::Success => Outcome::Success,
                    Terminal::Failure => Outcome::Failure,
                    Terminal::Exclude => Outcome::Exclude,
                };
                self.store
                    .transition(|state| state.finish(id, &producer, now_ns, outcome, duration_us))
                    .map(|()| Reply::Ok {})
            }
        };
        match result {
            Ok(reply) => {
                self.heartbeat = Some((producer, now_ns));
                reply
            }
            Err(crate::durable_slo::Error::Capacity) => {
                let marked = self.store.transition(|state| state.mark_gap(now_ns));
                Reply::Refused {
                    reason: if marked.is_ok() {
                        Refusal::Capacity
                    } else {
                        Refusal::Storage
                    },
                }
            }
            Err(error) => Reply::Refused {
                reason: match error {
                    crate::durable_slo::Error::Capacity => Refusal::Capacity,
                    crate::durable_slo::Error::Storage | crate::durable_slo::Error::Poisoned => {
                        Refusal::Storage
                    }
                    _ => Refusal::Accounting,
                },
            },
        }
    }

    /// @cc [owner:ghuntley,label:reliability] request-recorder-source-freshness
    /// Fresh snapshots MUST require a recent authenticated live-producer
    /// heartbeat, usable durable state, capacity and no overdue admissions.
    /// Recorder uptime MUST NOT establish application availability.
    pub fn publishable(&self, now_ns: u64) -> bool {
        let Some((producer, heartbeat_ns)) = &self.heartbeat else {
            return false;
        };
        let Ok(state) = self.store.state() else {
            return false;
        };
        now_ns >= *heartbeat_ns
            && now_ns - heartbeat_ns < HEARTBEAT_NS
            && liveness(producer) == Liveness::Alive
            && state.pending.len() < MAX_PENDING
            && state
                .pending
                .values()
                .all(|admission| now_ns < admission.deadline_ns)
    }
}

#[derive(Serialize)]
struct Snapshot<'a> {
    version: u8,
    service: &'a str,
    sampled_at_unix_nano: u64,
    started_at_unix_nano: u64,
    coverage_started_at_unix_nano: u64,
    incarnation: &'a str,
    invocation_id: &'a str,
    requests: u64,
    successes: u64,
    failures: u64,
    duration: SnapshotDuration,
}
#[derive(Serialize)]
struct SnapshotDuration {
    count: u64,
    sum_us: u64,
    explicit_bounds_us: [u64; 7],
    bucket_counts: [u64; 8],
}

pub fn snapshot_bytes(state: &State, now_ns: u64) -> Result<Vec<u8>, Refusal> {
    state.validate().map_err(|_| Refusal::Accounting)?;
    if now_ns < state.started_at_ns || now_ns < state.coverage_started_at_ns {
        return Err(Refusal::Accounting);
    }
    serde_json::to_vec(&Snapshot {
        version: 1,
        service: state.source.name(),
        sampled_at_unix_nano: now_ns,
        started_at_unix_nano: state.started_at_ns,
        coverage_started_at_unix_nano: state.coverage_started_at_ns,
        incarnation: &state.incarnation,
        invocation_id: &state.incarnation,
        requests: state.totals.requests,
        successes: state.totals.successes,
        failures: state.totals.failures,
        duration: SnapshotDuration {
            count: state.totals.duration_count,
            sum_us: state.totals.duration_sum_us,
            explicit_bounds_us: state.source.bounds_us(),
            bucket_counts: state.totals.bucket_counts,
        },
    })
    .map_err(|_| Refusal::Accounting)
}

fn now_ns() -> Result<u64, Refusal> {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| Refusal::Accounting)?
            .as_nanos(),
    )
    .map_err(|_| Refusal::Accounting)
}

fn identity() -> Result<String, Refusal> {
    let mut bytes = [0_u8; 16];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|_| Refusal::Storage)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub struct Config {
    pub source: Source,
    pub state: PathBuf,
    pub socket: PathBuf,
    pub snapshot: PathBuf,
    pub snapshot_mode: u32,
    pub policy: Policy,
    pub deadline_ns: u64,
}

fn publish(path: &Path, bytes: &[u8], mode: u32) -> Result<(), Refusal> {
    let stage = path.with_extension("new");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&stage)
        .map_err(|_| Refusal::Storage)?;
    file.write_all(bytes).map_err(|_| Refusal::Storage)?;
    file.set_permissions(std::fs::Permissions::from_mode(mode))
        .map_err(|_| Refusal::Storage)?;
    std::fs::rename(stage, path).map_err(|_| Refusal::Storage)
}

fn private_parent(path: &Path) -> Result<(), Refusal> {
    let metadata = std::fs::symlink_metadata(path.parent().ok_or(Refusal::Storage)?)
        .map_err(|_| Refusal::Storage)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || !matches!(metadata.mode() & 0o777, 0o700 | 0o750)
    {
        return Err(Refusal::Storage);
    }
    Ok(())
}

fn clear_snapshot_stage(path: &Path) -> Result<(), Refusal> {
    let stage = path.with_extension("new");
    match std::fs::symlink_metadata(&stage) {
        Ok(metadata)
            if metadata.is_file()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.nlink() == 1
                && metadata.mode() & 0o022 == 0 =>
        {
            std::fs::remove_file(stage).map_err(|_| Refusal::Storage)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(Refusal::Storage),
    }
}

/// @cc [owner:ghuntley,label:security;reliability] request-recorder-independent-runtime
/// The recorder MUST use one configured source and unit, bounded framed local
/// requests and durable transitions before replies. It MUST reconcile deaths
/// and deadlines independently of request traffic and never log frame contents.
pub fn run(config: Config) -> Result<(), Refusal> {
    if !matches!(config.snapshot_mode, 0o600 | 0o640) {
        return Err(Refusal::Schema);
    }
    private_parent(&config.socket)?;
    private_parent(&config.snapshot)?;
    if config.socket == config.snapshot || config.snapshot.with_extension("new") == config.socket {
        return Err(Refusal::Schema);
    }
    let mut store =
        Store::open(&config.state, config.source, now_ns()?, identity()?).map_err(|error| {
            match error {
                crate::durable_slo::Error::Version => Refusal::Version,
                _ => Refusal::Storage,
            }
        })?;
    let restarted_at = now_ns()?;
    store
        .transition(|state| state.mark_gap(restarted_at))
        .map_err(|_| Refusal::Storage)?;
    clear_snapshot_stage(&config.snapshot)?;
    let mut runtime = Runtime::new(store, config.policy, config.deadline_ns)?;
    if let Ok(metadata) = std::fs::symlink_metadata(&config.socket) {
        if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(Refusal::Storage);
        }
        std::fs::remove_file(&config.socket).map_err(|_| Refusal::Storage)?;
    }
    let listener = UnixListener::bind(&config.socket).map_err(|_| Refusal::Storage)?;
    std::fs::set_permissions(&config.socket, std::fs::Permissions::from_mode(0o660))
        .map_err(|_| Refusal::Storage)?;
    listener
        .set_nonblocking(true)
        .map_err(|_| Refusal::Storage)?;
    let mut refreshed = Instant::now() - Duration::from_secs(1);
    loop {
        if refreshed.elapsed() >= Duration::from_secs(1) {
            let now = now_ns()?;
            runtime.reconcile(now)?;
            if runtime.publishable(now) {
                publish(
                    &config.snapshot,
                    &snapshot_bytes(runtime.store.state().map_err(|_| Refusal::Storage)?, now)?,
                    config.snapshot_mode,
                )?;
            }
            refreshed = Instant::now();
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                stream
                    .set_read_timeout(Some(Duration::from_millis(250)))
                    .map_err(|_| Refusal::Storage)?;
                stream
                    .set_write_timeout(Some(Duration::from_millis(250)))
                    .map_err(|_| Refusal::Storage)?;
                let reply = match authenticate(&stream, &runtime.policy) {
                    Ok(producer) => match read_frame(&mut stream) {
                        Ok(envelope) => runtime.apply(producer, envelope.command, now_ns()?),
                        Err(reason) => Reply::Refused { reason },
                    },
                    Err(reason) => Reply::Refused { reason },
                };
                let _ = write_frame(&mut stream, &reply);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5))
            }
            Err(_) => return Err(Refusal::Storage),
        }
    }
}

/// Typed client used by the disposable native fixture. Production Elixir hooks
/// implement this same bounded framing and closed version-one command schema.
pub fn request(path: &Path, command: Command) -> Result<Reply, Refusal> {
    let mut stream = UnixStream::connect(path).map_err(|_| Refusal::Storage)?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| Refusal::Storage)?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| Refusal::Storage)?;
    let bytes = serde_json::to_vec(&Envelope {
        version: 1,
        command,
    })
    .map_err(|_| Refusal::Schema)?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .and_then(|()| stream.write_all(&bytes))
        .map_err(|_| Refusal::Storage)?;
    let mut header = [0_u8; 4];
    stream
        .read_exact(&mut header)
        .map_err(|_| Refusal::Schema)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > FRAME_LIMIT {
        return Err(Refusal::Schema);
    }
    let mut bytes = vec![0_u8; length];
    stream.read_exact(&mut bytes).map_err(|_| Refusal::Schema)?;
    serde_json::from_slice(&bytes).map_err(|_| Refusal::Schema)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    fn frame(bytes: &[u8]) -> Vec<u8> {
        let mut output = (bytes.len() as u32).to_be_bytes().to_vec();
        output.extend_from_slice(bytes);
        output
    }

    /// @cc [owner:ghuntley,label:verification;security] otel-receiver-proc-ticks-property
    /// Generated process names containing spaces and parentheses MUST NOT shift
    /// the parsed start-time field, and a foreign pid MUST NOT parse.
    #[hegel::test(test_cases = 256)]
    fn proc_commands_cannot_shift_start_identity(tc: TestCase) {
        let name = tc.draw(
            gs::text()
                .alphabet("abcdefghijklmnopqrstuvwxyz() ")
                .max_size(64),
        );
        let ticks = tc.draw(gs::integers::<u64>().min_value(1).max_value(u64::MAX - 1));
        let fields = ["S".into(), vec!["0"; 18].join(" "), ticks.to_string()].join(" ");
        let value = format!("42 ({name}) {fields} 0 0");
        assert_eq!(parse_ticks(&value, 42), Some(ticks));
        assert_eq!(parse_ticks(&value, 43), None);
    }

    /// @cc [owner:ghuntley,label:verification;capacity] otel-receiver-frame-bound-property
    /// Any declared frame length above 512 bytes MUST refuse before allocation.
    #[hegel::test(test_cases = 256)]
    fn frame_sizes_are_bounded_before_allocation(tc: TestCase) {
        let length = tc.draw(gs::integers::<u32>().min_value(513).max_value(u32::MAX - 1));
        assert!(matches!(
            read_frame(&mut length.to_be_bytes().as_slice()),
            Err(Refusal::Schema)
        ));
    }

    /// @cc [owner:ghuntley,label:verification;security] otel-receiver-unit-match-property
    /// Generated unit-name prefixes and suffixes MUST NOT authenticate as the
    /// expected unit; only the exact unit or its child cgroups match.
    #[hegel::test(test_cases = 256)]
    fn sibling_units_and_name_suffixes_never_authenticate(tc: TestCase) {
        let suffix = tc.draw(
            gs::text()
                .alphabet("abcdefghijklmnopqrstuvwxyz")
                .min_size(1)
                .max_size(20),
        );
        let expected = "audi-private.service";
        assert!(
            !unit_matches(&format!("0::/system.slice/{expected}{suffix}"), expected),
            "unit suffix must refuse"
        );
        assert!(
            !unit_matches(&format!("0::/system.slice/{suffix}{expected}"), expected),
            "unit prefix must refuse"
        );
        assert!(unit_matches(
            "0::/system.slice/audi-private.service/child",
            expected
        ));
        assert!(!unit_matches("0::/system.slice/audi-dns.service", expected));
    }

    #[test]
    fn unknown_fields_operations_versions_and_truncated_frames_refuse() {
        for bytes in [
            b"{\"version\":1,\"command\":{\"op\":\"hello\",\"pid\":42}}".as_slice(),
            b"{\"version\":1,\"command\":{\"op\":\"reset\"}}".as_slice(),
            b"{\"version\":1,\"command\":{\"op\":\"hello\"},\"service\":\"brady\"}".as_slice(),
        ] {
            assert!(matches!(
                read_frame(&mut frame(bytes).as_slice()),
                Err(Refusal::Schema)
            ));
        }
        assert!(matches!(
            read_frame(&mut frame(b"{\"version\":2,\"command\":{\"op\":\"hello\"}}").as_slice()),
            Err(Refusal::Version)
        ));
        assert!(matches!(
            read_frame(&mut [0_u8, 0, 0, 10].as_slice()),
            Err(Refusal::Schema)
        ));
    }

    #[test]
    fn current_kernel_process_is_alive_and_prior_incarnations_are_dead() {
        let producer = Producer {
            pid: std::process::id(),
            start_ticks: process_ticks(std::process::id()).unwrap(),
            boot_id: boot_id().unwrap(),
        };
        assert_eq!(liveness(&producer), Liveness::Alive);
        assert_eq!(missing_proc_liveness(producer.pid), Liveness::Unknown);
        assert_eq!(
            liveness(&Producer {
                start_ticks: producer.start_ticks + 1,
                ..producer.clone()
            }),
            Liveness::Dead
        );
        assert_eq!(
            liveness(&Producer {
                boot_id: "00000000-0000-0000-0000-000000000000".into(),
                ..producer
            }),
            Liveness::Dead
        );
    }
}
