//! One authenticated client session over a `SOCK_SEQPACKET` connection.

use crate::exec::{self, Custody, Spec};
use crate::leases::Leases;
use crate::protocol::{
    carries_descriptor, decode, encode_reply, valid_directory, Refusal, Reply, Request, Status,
    CHUNK_SIZE, JOB_KEY, PROTOCOL_VERSION, REQUEST_LIMIT,
};
use crate::utilities::Table;
use rustix::net::{
    recvmsg, send, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags, ReturnFlags, SendFlags,
};
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Requests one session may have in flight at once.
pub const MAX_IN_FLIGHT: usize = 1024;
/// How long a finished durable job's result stays attachable.
pub const JOB_RETENTION: Duration = Duration::from_mins(10);
/// Most finished job results retained.
pub const MAX_FINISHED_JOBS: usize = 256;
/// How long an ingress bridge may run: its lifetime is bounded by its peers'
/// end of stream and by the session, this only by a month.
pub const BRIDGE_LIFETIME: Duration = Duration::from_hours(720);

/// A durable job's state.
enum Job {
    Running,
    Done {
        status: Status,
        bytes: Vec<u8>,
        at: Instant,
    },
}

/// Shared daemon state.
pub struct Daemon {
    pub leases: Leases,
    pub utilities: Table,
    pub custody: Custody,
    pub peer_uid: u32,
    /// The uid Lilly's state belongs to (chown target, lock inode and VM
    /// state owner); the peer uid unless configured.
    pub service_uid: u32,
    pub peer_cgroups: Vec<Vec<u8>>,
    /// Roots beneath which Firecracker sockets may be opened for Lilly.
    pub socket_roots: Vec<std::path::PathBuf>,
    /// hostd's private directory (the control socket's parent).
    pub private_dir: Option<std::path::PathBuf>,
    /// Pool datasets for the ZFS grammar; empty disables it (private daemons).
    pub pool_datasets: Vec<Vec<u8>>,
    /// Configured pools as (dataset, directory) pairs for transfer streams;
    /// empty for a private daemon.
    pub pools: Vec<(Vec<u8>, std::path::PathBuf)>,
    /// Roots beneath which native file effects may act.
    pub file_roots: Vec<std::path::PathBuf>,
    /// Lease roots, beneath which a VM state directory must lie.
    pub roots: Vec<std::path::PathBuf>,
    /// Executables for typed VM launches; None refuses `LaunchVm`.
    pub vm_tools: Option<crate::vm_launch::Tools>,
    /// Detached ingress bridges (ADR-0187); None refuses `BridgeIngress` and
    /// lists no bridges.
    pub ingress: Option<crate::ingress::Config>,
    next_session: AtomicU64,
    jobs: Mutex<HashMap<[u8; JOB_KEY], Job>>,
    jobs_changed: Condvar,
}

impl std::fmt::Debug for Daemon {
    /// Daemon state stays opaque: it holds the lease and job tables.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Daemon").finish_non_exhaustive()
    }
}

impl Daemon {
    pub fn new(
        leases: Leases,
        utilities: Table,
        custody: Custody,
        peer_uid: u32,
        peer_cgroups: Vec<Vec<u8>>,
    ) -> Daemon {
        Daemon {
            leases,
            utilities,
            custody,
            peer_uid,
            service_uid: peer_uid,
            peer_cgroups,
            socket_roots: Vec::new(),
            private_dir: None,
            pool_datasets: Vec::new(),
            pools: Vec::new(),
            file_roots: Vec::new(),
            roots: Vec::new(),
            vm_tools: None,
            ingress: None,
            next_session: AtomicU64::new(1),
            jobs: Mutex::new(HashMap::new()),
            jobs_changed: Condvar::new(),
        }
    }
}

struct Run {
    lease: u64,
    cancelled: Arc<AtomicBool>,
}

#[derive(Default)]
struct Book {
    runs: HashMap<u64, Run>,
    busy: HashSet<u64>,
    releasing: HashSet<u64>,
    /// Leases a durable job is using; the job, not session close, frees them.
    durable: HashSet<u64>,
    in_flight: usize,
}

struct Session {
    id: u64,
    socket: OwnedFd,
    daemon: Arc<Daemon>,
    closed: AtomicBool,
    book: Mutex<Book>,
    idle: Condvar,
    writer: Mutex<()>,
}

/// @cc [owner:ghuntley,label:security] hostd-peer-authenticated
/// A session MUST be refused unless the peer's `SO_PEERCRED` uid equals the
/// configured uid and, when peer cgroups are configured, the peer's cgroup
/// (from `/proc/<pid>/cgroup`) is one of them. The first datagram MUST be a
/// Hello with this protocol version; anything else closes the session
/// before any lease or command.
pub fn serve(daemon: Arc<Daemon>, socket: OwnedFd) {
    if !authenticated(&daemon, &socket) {
        return;
    }
    let session = Arc::new(Session {
        id: daemon.next_session.fetch_add(1, Ordering::SeqCst),
        socket,
        daemon,
        closed: AtomicBool::new(false),
        book: Mutex::new(Book::default()),
        idle: Condvar::new(),
        writer: Mutex::new(()),
    });
    let mut buffer = vec![0_u8; REQUEST_LIMIT + 1];
    let Some((first, None)) = receive(&session.socket, &mut buffer) else {
        return;
    };
    match decode(first) {
        Some(envelope) => match envelope.request {
            Request::Hello { version } if version == PROTOCOL_VERSION => {
                session.reply(
                    envelope.id,
                    &Reply::Hello {
                        version: PROTOCOL_VERSION,
                    },
                );
            }
            _ => {
                session.reply(
                    envelope.id,
                    &Reply::Refused {
                        reason: Refusal::Version,
                    },
                );
                return;
            }
        },
        None => return,
    }
    while let Some((datagram, descriptor)) = receive(&session.socket, &mut buffer) {
        let Some(envelope) = decode(datagram) else {
            // A malformed datagram ends the session: a confused client must
            // not keep authority.
            break;
        };
        if carries_descriptor(&envelope.request) != descriptor.is_some() {
            // A descriptor where none belongs, or a missing one, is just as
            // malformed; dropping it closes hostd's copy.
            break;
        }
        if !session.admit() {
            session.reply(
                envelope.id,
                &Reply::Refused {
                    reason: Refusal::Malformed,
                },
            );
            continue;
        }
        let worker = Arc::clone(&session);
        std::thread::spawn(move || {
            worker.handle(envelope.id, envelope.request, descriptor);
            worker.done();
        });
    }
    session.close();
}

fn authenticated(daemon: &Daemon, socket: &OwnedFd) -> bool {
    let Ok(credentials) = rustix::net::sockopt::socket_peercred(socket) else {
        return false;
    };
    if credentials.uid.as_raw() != daemon.peer_uid {
        return false;
    }
    if daemon.peer_cgroups.is_empty() {
        return true;
    }
    let Ok(cgroup) = std::fs::read(format!("/proc/{}/cgroup", credentials.pid.as_raw_nonzero()))
    else {
        return false;
    };
    // cgroup v2: a single "0::<path>" line.
    let path = cgroup
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"0::"));
    path.is_some_and(|path| daemon.peer_cgroups.iter().any(|allowed| allowed == path))
}

/// @cc [owner:ghuntley,label:security] hostd-receives-at-most-one-descriptor
/// receive MUST return a datagram with at most one received descriptor and
/// end the session (None) on end of stream, an oversized or truncated
/// datagram, truncated or foreign ancillary data, or more than one
/// descriptor. Every received descriptor is owned at once, so each one is
/// closed on every path.
fn receive<'a>(socket: &OwnedFd, buffer: &'a mut [u8]) -> Option<(&'a [u8], Option<OwnedFd>)> {
    let mut space = [std::mem::MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(2))];
    loop {
        let mut ancillary = RecvAncillaryBuffer::new(&mut space);
        let outcome = match recvmsg(
            socket,
            &mut [std::io::IoSliceMut::new(&mut *buffer)],
            &mut ancillary,
            RecvFlags::CMSG_CLOEXEC,
        ) {
            Ok(outcome) => outcome,
            Err(rustix::io::Errno::INTR) => continue,
            Err(_) => return None,
        };
        let mut received: Vec<OwnedFd> = Vec::new();
        let mut foreign = false;
        for message in ancillary.drain() {
            match message {
                RecvAncillaryMessage::ScmRights(fds) => received.extend(fds),
                _ => foreign = true,
            }
        }
        if outcome.bytes == 0
            || outcome.bytes > REQUEST_LIMIT
            || outcome
                .flags
                .intersects(ReturnFlags::TRUNC | ReturnFlags::CTRUNC)
            || foreign
            || received.len() > 1
        {
            return None;
        }
        let size = outcome.bytes;
        return Some((&buffer[..size], received.pop()));
    }
}

impl Session {
    fn admit(&self) -> bool {
        let mut book = crate::lock(&self.book, "session book");
        if book.in_flight >= MAX_IN_FLIGHT {
            return false;
        }
        book.in_flight += 1;
        true
    }

    fn done(&self) {
        let mut book = crate::lock(&self.book, "session book");
        book.in_flight -= 1;
        self.idle.notify_all();
    }

    fn reply(&self, id: u64, reply: &Reply) {
        let datagram = encode_reply(id, reply);
        let _guard = crate::lock(&self.writer, "session writer");
        // A failed send means the peer is gone; the reader observes EOF.
        let _ = send(&self.socket, &datagram, SendFlags::NOSIGNAL);
    }

    fn refuse(&self, id: u64, reason: Refusal) {
        self.reply(id, &Reply::Refused { reason });
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the request dispatcher keeps one arm per request kind in one reviewable match"
    )]
    fn handle(self: &Arc<Self>, id: u64, request: Request, descriptor: Option<OwnedFd>) {
        match request {
            Request::Hello { .. } => self.refuse(id, Refusal::Malformed),
            Request::Acquire {
                mode,
                wait_ms,
                directory,
            } => {
                if !valid_directory(&directory) {
                    return self.refuse(id, Refusal::Malformed);
                }
                let path = Path::new(OsStr::from_bytes(&directory));
                match self.daemon.leases.acquire(
                    self.id,
                    mode,
                    path,
                    Duration::from_millis(u64::from(wait_ms)),
                    &self.closed,
                ) {
                    Ok((lease, _)) => {
                        if self.closed.load(Ordering::SeqCst) {
                            self.daemon.leases.release(self.id, lease);
                        } else {
                            self.reply(id, &Reply::Granted { lease });
                        }
                    }
                    Err(reason) => self.refuse(id, reason),
                }
            }
            Request::Release { lease } => {
                if self.daemon.leases.holder(lease) != Some(self.id) {
                    return self.refuse(id, Refusal::UnknownLease);
                }
                self.release(lease);
                self.reply(id, &Reply::Released);
            }
            Request::Cancel { target } => {
                let book = crate::lock(&self.book, "session book");
                if let Some(run) = book.runs.get(&target) {
                    run.cancelled.store(true, Ordering::SeqCst);
                }
            }
            Request::Run {
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            } => self.run(id, lease, timeout_ms, output_limit, utility, arguments),
            Request::RunDurable {
                key,
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            } => self.run_durable(id, key, lease, timeout_ms, output_limit, utility, arguments),
            Request::Attach { key, wait_ms } => self.attach(id, key, wait_ms),
            Request::LaunchVm { lease, launch } => {
                if lease == 0 {
                    return self.refuse(id, Refusal::LeaseRequired);
                }
                match crate::vm_launch::argv(
                    self.daemon.vm_tools.as_ref(),
                    &self.daemon.roots,
                    &self.daemon.socket_roots,
                    &launch,
                    self.daemon.service_uid,
                ) {
                    Ok(arguments) => self.run(
                        id,
                        lease,
                        10_000,
                        crate::protocol::DEFAULT_OUTPUT_LIMIT,
                        crate::utilities::Utility::SystemdRun,
                        arguments,
                    ),
                    Err(reason) => self.refuse(id, reason),
                }
            }
            Request::TransferStream {
                lease,
                timeout_ms,
                rate,
                stream,
            } => self.transfer_stream(id, lease, timeout_ms, rate, &stream),
            Request::ConnectUnix { timeout_ms, path } => {
                let Some(socket) = descriptor else {
                    return self.refuse(id, Refusal::Malformed);
                };
                match crate::descriptors::connect_unix(
                    &socket,
                    Path::new(OsStr::from_bytes(&path)),
                    &self.daemon.socket_roots,
                    Duration::from_millis(u64::from(timeout_ms)),
                ) {
                    Ok(()) => self.reply(id, &Reply::Connected),
                    Err(reason) => self.refuse(id, reason),
                }
            }
            Request::BridgeNetnsTcp {
                mark,
                destination,
                port,
                source,
                timeout_ms,
                namespace,
                device,
            } => {
                let Some(socket) = descriptor else {
                    return self.refuse(id, Refusal::Malformed);
                };
                let text = |bytes: Vec<u8>| String::from_utf8(bytes).unwrap_or_default();
                let request = crate::descriptors::NetnsTcp {
                    namespace: text(namespace),
                    device: text(device),
                    mark,
                    destination: std::net::Ipv4Addr::from(destination),
                    port,
                    source: (source != [0, 0, 0, 0]).then(|| std::net::Ipv4Addr::from(source)),
                    timeout: Duration::from_millis(u64::from(timeout_ms)),
                };
                self.bridge(id, socket, request);
            }
            Request::BridgeIngress {
                key,
                greeting,
                preface,
                expect,
                ready_ms,
                mark,
                destination,
                port,
                source,
                timeout_ms,
                namespace,
                device,
            } => {
                let Some(socket) = descriptor else {
                    return self.refuse(id, Refusal::Malformed);
                };
                let text = |bytes: Vec<u8>| String::from_utf8(bytes).unwrap_or_default();
                let request = crate::descriptors::NetnsTcp {
                    namespace: text(namespace),
                    device: text(device),
                    mark,
                    destination: std::net::Ipv4Addr::from(destination),
                    port,
                    source: (source != [0, 0, 0, 0]).then(|| std::net::Ipv4Addr::from(source)),
                    timeout: Duration::from_millis(u64::from(timeout_ms)),
                };
                let stage = crate::ingress::Stage {
                    preface: &preface,
                    expect: &expect,
                    ready: Duration::from_millis(u64::from(ready_ms)),
                };
                match self.bridge_ingress(&key, &greeting, &stage, socket, request) {
                    Ok(()) => self.reply(id, &Reply::Connected),
                    Err(reason) => self.refuse(id, reason),
                }
            }
            Request::ListIngressBridges => {
                let keys = self
                    .daemon
                    .ingress
                    .as_ref()
                    .map(crate::ingress::live)
                    .unwrap_or_default();
                self.reply(
                    id,
                    &Reply::Result {
                        status: Status::Succeeded,
                        bytes: keys.concat(),
                    },
                );
            }
            Request::EndIngressBridge { key } => {
                let Some(config) = self.daemon.ingress.as_ref() else {
                    return self.refuse(id, Refusal::Unavailable);
                };
                match crate::ingress::end(config, &key) {
                    Ok(()) => self.reply(
                        id,
                        &Reply::Result {
                            status: Status::Succeeded,
                            bytes: Vec::new(),
                        },
                    ),
                    Err(reason) => self.refuse(id, reason),
                }
            }
        }
    }

    /// @cc [owner:ghuntley,label:security;isolation;recovery] hostd-detached-ingress-bridge
    /// A detached bridge MUST be refused (Unavailable) without ingress
    /// configuration or a resolved helper; its received descriptor MUST pass
    /// ingress-client-is-audi (else Malformed) before anything else; there
    /// MUST be fewer than `MAX_BRIDGES` live bridges and none with this key.
    /// hostd then dials the guest exactly as hostd-netns-connect, stages the
    /// guest connection through ingress-guest-stage (the preface written
    /// whole, the expected frame read exactly, else Unavailable with no
    /// bridge started), and starts
    /// `[systemd-run --scope --unit=lilly-ingress-<key>.scope --slice=<slice>
    /// --property=RuntimeMaxSec=<30 days> --] lilly-ingress-bridge --detached
    /// 5 3 4 [<service uid>]` (the uid whenever hostd is root) through
    /// hostd-detached-spawn, with Audi's connection at 3, the guest at 4 and
    /// the bridge's end of a fresh control socket at 5, keeping no copy of
    /// any. Connected is sent only after the bridge sent READY, the greeting
    /// was written whole to Audi's connection and GO was sent, all within
    /// `START_TIMEOUT`; on any failure the bridge is killed through its pidfd
    /// and its scope, and Unavailable is sent. The bridge is no command of
    /// this session: Cancel and session close leave it running.
    fn bridge_ingress(
        &self,
        key: &[u8; crate::ingress::KEY],
        greeting: &[u8],
        stage: &crate::ingress::Stage<'_>,
        client: OwnedFd,
        request: crate::descriptors::NetnsTcp,
    ) -> Result<(), Refusal> {
        let (Some(config), Some(helper)) = (
            self.daemon.ingress.as_ref(),
            self.daemon
                .utilities
                .get(crate::utilities::Utility::IngressBridge),
        ) else {
            return Err(Refusal::Unavailable);
        };
        crate::ingress::client_kind(&client, config.peer_uid)?;
        let live = crate::ingress::live(config);
        if live.len() >= crate::ingress::MAX_BRIDGES || live.contains(key) {
            return Err(Refusal::Unavailable);
        }
        let guest = crate::descriptors::open_netns_tcp(request)?;
        crate::ingress::stage(&guest, stage)?;
        let uid = rustix::process::geteuid()
            .is_root()
            .then_some(self.daemon.service_uid);
        crate::ingress::start(config, helper, key, greeting, client, guest, uid)
    }

    /// @cc [owner:ghuntley,label:security;isolation] hostd-ingress-bridge
    /// A bridge MUST dial the guest exactly as hostd-netns-connect, hand the
    /// caller's socket over through hostd-bridge-handoff, and only then run
    /// `lilly-ingress-bridge 3 4 [<service uid>]` (the uid whenever hostd is
    /// root) with the accepted end at 3 and the guest connection at 4, as the
    /// sole owner of both (hostd-handoff-sole-owner). Connected is sent once
    /// the helper runs; a refusal is sent otherwise, and nothing follows
    /// either. The bridge is this session's command without a lease:
    /// Cancel or session close kills and reaps it.
    fn bridge(&self, id: u64, socket: OwnedFd, request: crate::descriptors::NetnsTcp) {
        let (Some(helper), Some(private)) = (
            self.daemon
                .utilities
                .get(crate::utilities::Utility::IngressBridge),
            self.daemon.private_dir.as_deref(),
        ) else {
            return self.refuse(id, Refusal::Unavailable);
        };
        let timeout = request.timeout;
        let guest = match crate::descriptors::open_netns_tcp(request) {
            Ok(guest) => guest,
            Err(reason) => return self.refuse(id, reason),
        };
        self.bridge_to(id, socket, guest, helper, private, timeout);
    }

    /// The bridge once the guest connection exists.
    fn bridge_to(
        &self,
        id: u64,
        socket: OwnedFd,
        guest: OwnedFd,
        helper: &Path,
        private: &Path,
        timeout: Duration,
    ) {
        let accepted =
            match crate::descriptors::bridge_handoff(private, self.id, id, &socket, timeout) {
                Ok(accepted) => accepted,
                Err(reason) => return self.refuse(id, reason),
            };
        drop(socket);
        let mut arguments = vec![c"3".to_owned(), c"4".to_owned()];
        if rustix::process::geteuid().is_root() {
            let Ok(uid) = std::ffi::CString::new(self.daemon.service_uid.to_string()) else {
                return self.refuse(id, Refusal::Unavailable);
            };
            arguments.push(uid);
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut book = crate::lock(&self.book, "session book");
            if self.closed.load(Ordering::SeqCst) {
                cancelled.store(true, Ordering::SeqCst);
            }
            book.runs.insert(
                id,
                Run {
                    lease: 0,
                    cancelled: Arc::clone(&cancelled),
                },
            );
        }
        let replied = AtomicBool::new(false);
        let _ = exec::run_handoff(
            &Spec {
                executable: helper,
                arguments: &arguments,
                timeout: BRIDGE_LIFETIME,
                output_limit: crate::protocol::DEFAULT_OUTPUT_LIMIT as usize,
                lease: None,
                inherit: &[],
            },
            vec![accepted, guest],
            &self.daemon.custody,
            &cancelled,
            &|| {
                replied.store(true, Ordering::SeqCst);
                self.reply(id, &Reply::Connected);
            },
        );
        {
            let mut book = crate::lock(&self.book, "session book");
            book.runs.remove(&id);
            self.idle.notify_all();
        }
        if !replied.load(Ordering::SeqCst) {
            self.refuse(id, Refusal::Unavailable);
        }
    }

    /// @cc [owner:ghuntley,label:security;concurrency] hostd-lease-commands-serialized
    /// A command under a lease MUST be refused unless this session holds the
    /// lease, no other command is in flight on it and it is not being
    /// released; a mutating utility, including systemctl stop/kill, MUST be
    /// refused without a lease. A lease
    /// therefore runs at most one command at a time, as the per-lock helper
    /// did.
    fn run(
        &self,
        id: u64,
        lease: u64,
        timeout_ms: u32,
        output_limit: u32,
        utility: crate::utilities::Utility,
        arguments: Vec<std::ffi::CString>,
    ) {
        if lease == 0 && utility.requires_lease(&arguments) {
            return self.refuse(id, Refusal::LeaseRequired);
        }
        let descriptor = if lease == 0 {
            None
        } else {
            match self.daemon.leases.descriptor(self.id, lease) {
                Some(descriptor) => Some(descriptor),
                None => return self.refuse(id, Refusal::UnknownLease),
            }
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut book = crate::lock(&self.book, "session book");
            if lease != 0 {
                if book.busy.contains(&lease) || book.releasing.contains(&lease) {
                    return self.refuse(id, Refusal::LeaseBusy);
                }
                book.busy.insert(lease);
            }
            if self.closed.load(Ordering::SeqCst) {
                cancelled.store(true, Ordering::SeqCst);
            }
            book.runs.insert(
                id,
                Run {
                    lease,
                    cancelled: Arc::clone(&cancelled),
                },
            );
        }
        let Some(arguments) = self.confined(id, utility, arguments) else {
            eprintln!(
                "lilly-hostd: refused utility {} outside its argument grammar",
                utility.index()
            );
            drop(descriptor);
            {
                let mut book = crate::lock(&self.book, "session book");
                book.runs.remove(&id);
                book.busy.remove(&lease);
                self.idle.notify_all();
            }
            return self.reply(
                id,
                &Reply::Result {
                    status: Status::Setup,
                    bytes: Vec::new(),
                },
            );
        };
        let (status, bytes) = match self.daemon.utilities.get(utility) {
            _ if crate::mounts::native(utility, &arguments) => (
                crate::mounts::perform(utility, &arguments, &self.daemon.file_roots),
                Vec::new(),
            ),
            _ if crate::files::native(utility) => (
                crate::files::perform(
                    utility,
                    &arguments,
                    &self.daemon.file_roots,
                    &crate::files::Owners {
                        service: self.daemon.service_uid,
                    },
                ),
                Vec::new(),
            ),
            None => (Status::Setup, Vec::new()),
            Some(executable) => exec::run(
                &Spec {
                    executable,
                    arguments: &arguments,
                    timeout: Duration::from_millis(u64::from(timeout_ms)),
                    output_limit: output_limit as usize,
                    lease: descriptor.as_deref(),
                    inherit: &[],
                },
                &self.daemon.custody,
                &cancelled,
            ),
        };
        if utility == crate::utilities::Utility::Nft {
            if let Some(private) = &self.daemon.private_dir {
                let _ = std::fs::remove_file(private.join(format!("nft-{id}.nft")));
            }
        }
        if status == Status::Setup {
            // Only the utility index: arguments and paths are never logged.
            eprintln!(
                "lilly-hostd: utility {} refused or unavailable",
                utility.index()
            );
        }
        drop(descriptor);
        {
            let mut book = crate::lock(&self.book, "session book");
            book.runs.remove(&id);
            book.busy.remove(&lease);
            self.idle.notify_all();
        }
        self.reply_result(id, status, &bytes);
    }

    /// @cc [owner:ghuntley,label:security;recovery] hostd-transfer-stream-under-lease
    /// A stream MUST be refused without a held lease, and otherwise obeys
    /// hostd-lease-commands-serialized: it runs as the lease's one command,
    /// inherits the lease and `<lease directory>/progress` descriptors, and
    /// is cancelled, killed and reaped by Cancel, lease release or session
    /// close. A local resume runs `lilly-resume-token` first and refuses
    /// (Setup) unless it printed exactly `ok`. A Succeeded or Failed result
    /// carries exactly one byte, the helper's exit code; every other status
    /// carries none.
    #[expect(
        clippy::too_many_lines,
        reason = "one linear custody sequence: validate, lease, run, release"
    )]
    fn transfer_stream(
        &self,
        id: u64,
        lease: u64,
        timeout_ms: u32,
        rate: u32,
        stream: &crate::transfer::Stream,
    ) {
        use std::os::fd::AsRawFd;
        if lease == 0 {
            return self.refuse(id, Refusal::LeaseRequired);
        }
        let Some(descriptor) = self.daemon.leases.descriptor(self.id, lease) else {
            return self.refuse(id, Refusal::UnknownLease);
        };
        let progress = match self.daemon.leases.progress(self.id, lease) {
            Ok(progress) => progress,
            Err(reason) => return self.refuse(id, reason),
        };
        let context = crate::transfer::Context {
            pools: &self.daemon.pools,
            utilities: &self.daemon.utilities,
            side_uid: (self.daemon.service_uid != rustix::process::geteuid().as_raw())
                .then_some(self.daemon.service_uid),
            elevated: rustix::process::geteuid().is_root()
                && self.daemon.peer_uid != rustix::process::geteuid().as_raw(),
        };
        let plan = match crate::transfer::plan(
            stream,
            &context,
            timeout_ms,
            rate,
            Some(progress.as_raw_fd()),
        ) {
            Ok(plan) => plan,
            Err(reason) => {
                eprintln!("lilly-hostd: refused a transfer stream outside its grammar");
                return self.refuse(id, reason);
            }
        };
        let Some(helper) = self
            .daemon
            .utilities
            .get(crate::utilities::Utility::TransferStream)
        else {
            return self.reply_result(id, Status::Setup, &[]);
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut book = crate::lock(&self.book, "session book");
            if book.busy.contains(&lease) || book.releasing.contains(&lease) {
                return self.refuse(id, Refusal::LeaseBusy);
            }
            book.busy.insert(lease);
            if self.closed.load(Ordering::SeqCst) {
                cancelled.store(true, Ordering::SeqCst);
            }
            book.runs.insert(
                id,
                Run {
                    lease,
                    cancelled: Arc::clone(&cancelled),
                },
            );
        }
        let checked = match (
            &plan.resume_check,
            self.daemon
                .utilities
                .get(crate::utilities::Utility::ResumeToken),
        ) {
            (None, _) => true,
            (Some(arguments), Some(executable)) => {
                let (status, output) = exec::run(
                    &Spec {
                        executable,
                        arguments,
                        timeout: Duration::from_secs(10),
                        output_limit: crate::protocol::DEFAULT_OUTPUT_LIMIT as usize,
                        lease: Some(&descriptor),
                        inherit: &[],
                    },
                    &self.daemon.custody,
                    &cancelled,
                );
                status == Status::Succeeded && output == b"ok\n"
            }
            (Some(_), None) => false,
        };
        let (status, bytes) = if checked {
            match exec::run_coded(
                &Spec {
                    executable: helper,
                    arguments: &plan.helper,
                    // The helper enforces the stream deadline itself; this
                    // bound only covers its final reaping.
                    timeout: Duration::from_millis(u64::from(timeout_ms) + 10_000),
                    output_limit: crate::protocol::DEFAULT_OUTPUT_LIMIT as usize,
                    lease: Some(&descriptor),
                    inherit: &[&progress],
                },
                &self.daemon.custody,
                &cancelled,
            ) {
                (status @ (Status::Succeeded | Status::Failed), Some(code), _) => {
                    (status, vec![u8::try_from(code).unwrap_or(u8::MAX)])
                }
                (Status::Succeeded | Status::Failed, None, _) => (Status::Failed, vec![u8::MAX]),
                (status, _, _) => (status, Vec::new()),
            }
        } else {
            (Status::Setup, Vec::new())
        };
        drop(progress);
        drop(descriptor);
        {
            let mut book = crate::lock(&self.book, "session book");
            book.runs.remove(&id);
            book.busy.remove(&lease);
            self.idle.notify_all();
        }
        self.reply_result(id, status, &bytes);
    }

    /// Send a command result, chunked into datagrams of at most `CHUNK_SIZE`.
    fn reply_result(&self, id: u64, status: Status, bytes: &[u8]) {
        let mut chunks = bytes.chunks(CHUNK_SIZE).peekable();
        if chunks.peek().is_none() {
            return self.reply(
                id,
                &Reply::Result {
                    status,
                    bytes: Vec::new(),
                },
            );
        }
        while let Some(chunk) = chunks.next() {
            if chunks.peek().is_some() {
                self.reply(
                    id,
                    &Reply::Chunk {
                        bytes: chunk.to_vec(),
                    },
                );
            } else {
                self.reply(
                    id,
                    &Reply::Result {
                        status,
                        bytes: chunk.to_vec(),
                    },
                );
            }
        }
    }

    /// @cc [owner:ghuntley,label:recovery;concurrency] durable-job-outlives-session
    /// A durable job MUST require a held lease that has no command in flight,
    /// and MUST refuse a key whose job is still running. It runs on its own
    /// thread: closing the session neither cancels it nor releases its lease.
    /// When it finishes its result is stored under its key for ten minutes;
    /// its lease is released then if its session has closed, and otherwise
    /// stays with the live session. Releasing the lease explicitly still
    /// cancels it first.
    #[expect(
        clippy::too_many_arguments,
        reason = "a durable run carries its request id, key, lease, utility, arguments and descriptors explicitly"
    )]
    fn run_durable(
        self: &Arc<Self>,
        id: u64,
        key: [u8; JOB_KEY],
        lease: u64,
        timeout_ms: u32,
        output_limit: u32,
        utility: crate::utilities::Utility,
        arguments: Vec<std::ffi::CString>,
    ) {
        let Some(descriptor) = (lease != 0)
            .then(|| self.daemon.leases.descriptor(self.id, lease))
            .flatten()
        else {
            return self.refuse(id, Refusal::UnknownLease);
        };
        let Some(arguments) = self.confined(id, utility, arguments) else {
            eprintln!(
                "lilly-hostd: refused durable utility {} outside its argument grammar",
                utility.index()
            );
            return self.refuse(id, Refusal::Malformed);
        };
        {
            let mut jobs = crate::lock(&self.daemon.jobs, "job table");
            if matches!(jobs.get(&key), Some(Job::Running)) {
                drop(jobs);
                return self.refuse(id, Refusal::JobRunning);
            }
            let now = Instant::now();
            jobs.retain(|_, job| match job {
                Job::Running => true,
                Job::Done { at, .. } => now.duration_since(*at) < JOB_RETENTION,
            });
            if jobs.len() >= MAX_FINISHED_JOBS {
                drop(jobs);
                return self.refuse(id, Refusal::Malformed);
            }
            let mut book = crate::lock(&self.book, "session book");
            if book.busy.contains(&lease) || book.releasing.contains(&lease) {
                return self.refuse(id, Refusal::LeaseBusy);
            }
            book.busy.insert(lease);
            book.durable.insert(lease);
            jobs.insert(key, Job::Running);
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        crate::lock(&self.book, "session book").runs.insert(
            id,
            Run {
                lease,
                cancelled: Arc::clone(&cancelled),
            },
        );
        let session = Arc::clone(self);
        std::thread::spawn(move || {
            let (status, bytes) = match session.daemon.utilities.get(utility) {
                None => (Status::Setup, Vec::new()),
                Some(executable) => exec::run(
                    &Spec {
                        executable,
                        arguments: &arguments,
                        timeout: Duration::from_millis(u64::from(timeout_ms)),
                        output_limit: output_limit as usize,
                        lease: Some(&descriptor),
                        inherit: &[],
                    },
                    &session.daemon.custody,
                    &cancelled,
                ),
            };
            drop(descriptor);
            crate::lock(&session.daemon.jobs, "job table").insert(
                key,
                Job::Done {
                    status,
                    bytes: bytes.clone(),
                    at: Instant::now(),
                },
            );
            session.daemon.jobs_changed.notify_all();
            let closed = {
                let mut book = crate::lock(&session.book, "session book");
                book.runs.remove(&id);
                book.busy.remove(&lease);
                book.durable.remove(&lease);
                session.idle.notify_all();
                session.closed.load(Ordering::SeqCst)
            };
            if closed {
                session.daemon.leases.release(session.id, lease);
            } else {
                session.reply_result(id, status, &bytes);
            }
        });
    }

    /// @cc [owner:ghuntley,label:recovery] durable-job-attach
    /// attach MUST reply with a finished job's stored result, wait at most
    /// `wait_ms` for a running one (refusing `JobRunning` when the wait ends or
    /// the session closes), and refuse `UnknownJob` for any other key.
    fn attach(&self, id: u64, key: [u8; JOB_KEY], wait_ms: u32) {
        let deadline = Instant::now() + Duration::from_millis(u64::from(wait_ms));
        let mut jobs = crate::lock(&self.daemon.jobs, "job table");
        loop {
            match jobs.get(&key) {
                None => {
                    drop(jobs);
                    return self.refuse(id, Refusal::UnknownJob);
                }
                Some(Job::Done { status, bytes, .. }) => {
                    let (status, bytes) = (*status, bytes.clone());
                    drop(jobs);
                    return self.reply_result(id, status, &bytes);
                }
                Some(Job::Running) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() || self.closed.load(Ordering::SeqCst) {
                        drop(jobs);
                        return self.refuse(id, Refusal::JobRunning);
                    }
                    jobs = crate::wait_timeout(
                        &self.daemon.jobs_changed,
                        jobs,
                        remaining.min(Duration::from_millis(50)),
                        "job table",
                    );
                }
            }
        }
    }

    /// The argument grammar (utility-arguments-grammar), enforced when pool
    /// datasets are configured (the production unit). Returns the arguments
    /// to run with, or None to refuse.
    fn confined(
        &self,
        id: u64,
        utility: crate::utilities::Utility,
        arguments: Vec<std::ffi::CString>,
    ) -> Option<Vec<std::ffi::CString>> {
        if self.daemon.pool_datasets.is_empty() {
            return Some(arguments);
        }
        let context = crate::policy::Context {
            file_roots: &self.daemon.file_roots,
            scope: crate::zfs_policy::Scope {
                datasets: &self.daemon.pool_datasets,
                paths: &self.daemon.socket_roots,
            },
            utilities: &self.daemon.utilities,
            private: self.daemon.private_dir.as_deref(),
            request: id,
        };
        match crate::policy::check(utility, &arguments, &context) {
            crate::policy::Decision::Run => Some(arguments),
            crate::policy::Decision::Rewrite(rewritten) => Some(rewritten),
            crate::policy::Decision::Refuse => None,
        }
    }

    /// @cc [owner:ghuntley,label:recovery] lease-release-after-commands-reaped
    /// Releasing a lease MUST cancel its in-flight command and wait until that
    /// command was killed and reaped before the descriptor is dropped, so no
    /// successor is granted while a utility of the old holder may still run.
    fn release(&self, lease: u64) {
        let mut book = crate::lock(&self.book, "session book");
        book.releasing.insert(lease);
        for run in book.runs.values().filter(|run| run.lease == lease) {
            run.cancelled.store(true, Ordering::SeqCst);
        }
        while book.busy.contains(&lease) {
            book = crate::wait(&self.idle, book, "session book");
        }
        book.releasing.remove(&lease);
        drop(book);
        self.daemon.leases.release(self.id, lease);
    }

    /// @cc [owner:ghuntley,label:recovery] session-close-custody
    /// When a session ends (EOF, a malformed datagram or a socket error) every
    /// queued acquisition MUST stop, every command except a durable job MUST
    /// be killed and reaped, and only then MUST its leases be released; a
    /// durable job's lease is released by the job when it finishes. A Lilly crash therefore
    /// fences exactly like the death of the old per-lock helpers.
    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.daemon.leases.wake();
        self.daemon.jobs_changed.notify_all();
        let mut book = crate::lock(&self.book, "session book");
        let cancel = |book: &Book| {
            for run in book
                .runs
                .values()
                .filter(|run| !book.durable.contains(&run.lease))
            {
                run.cancelled.store(true, Ordering::SeqCst);
            }
        };
        cancel(&book);
        while book.in_flight > 0 {
            book = crate::wait(&self.idle, book, "session book");
            cancel(&book);
        }
        let durable = book.durable.clone();
        drop(book);
        for lease in self.daemon.leases.held_by(self.id) {
            if !durable.contains(&lease) {
                self.daemon.leases.release(self.id, lease);
            }
        }
    }
}
