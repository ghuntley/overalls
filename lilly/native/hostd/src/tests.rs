use crate::exec::{start_reaper, Custody};
use crate::leases::Leases;
use crate::protocol::*;
use crate::session::{serve, Daemon};
use crate::utilities::{Table, Utility};
use hegel::{generators as gs, TestCase};
use rustix::net::{
    connect, recv, send, socket_with, AddressFamily, RecvFlags, SendFlags, SocketAddrUnix,
    SocketFlags, SocketType,
};
use std::ffi::{CString, OsString};
use std::os::fd::OwnedFd;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- protocol

/// Independent model of an acceptable Run body.
fn spec_run(
    timeout: u32,
    limit: u32,
    utility: u8,
    arguments: &[Vec<u8>],
    terminated: bool,
) -> bool {
    (1000..=14_400_000).contains(&timeout)
        && (limit == 65_536 || limit == 4_194_304)
        && usize::from(utility) < Utility::ALL.len()
        // systemd-run, the stream helper, ssh, cmp and the bridge are reachable only
        // through LaunchVm, TransferStream and BridgeNetnsTcp.
        && ![24, 28, 29, 30, 31].contains(&utility)
        && arguments.len() <= 127
        && terminated
        && arguments.iter().all(|argument| !argument.contains(&0))
}

/// @cc [owner:ghuntley,label:verification] hostd-decoder-oracle
/// Generated Run datagrams MUST be classified by an independent model, and
/// every accepted datagram MUST re-encode to exactly the received bytes. The
/// decoder is never compared to itself.
#[hegel::test]
fn run_decoding_matches_independent_model(tc: TestCase) {
    let timeout = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(990).max_value(1010),
        gs::integers::<u32>()
            .min_value(14_399_990)
            .max_value(14_400_010),
        gs::integers::<u32>(),
    ));
    let limit = tc.draw(hegel::one_of!(
        gs::just(65_536_u32),
        gs::just(4_194_304_u32),
        gs::integers::<u32>(),
    ));
    let utility = tc.draw(gs::integers::<u8>().min_value(0).max_value(40));
    let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(130));
    let terminated = tc.draw(gs::booleans());
    let arguments: Vec<Vec<u8>> = (0..count)
        .map(|_| tc.draw(gs::binary().max_size(6)))
        .map(|argument| argument.into_iter().filter(|byte| *byte != 0).collect())
        .collect();
    let mut body = vec![OP_RUN_FOR_TEST];
    body.extend(7_u64.to_be_bytes());
    body.extend(3_u64.to_be_bytes());
    body.extend(timeout.to_be_bytes());
    body.extend(limit.to_be_bytes());
    body.push(utility);
    for (index, argument) in arguments.iter().enumerate() {
        body.extend(argument);
        if terminated || index + 1 < arguments.len() {
            body.push(0);
        }
    }
    // An unterminated empty last argument is the same bytes as no argument.
    let mut model_arguments = arguments.clone();
    let mut model_terminated = terminated || arguments.is_empty();
    if !terminated && model_arguments.last().is_some_and(Vec::is_empty) {
        model_arguments.pop();
        model_terminated = true;
    }
    let accepted = spec_run(timeout, limit, utility, &model_arguments, model_terminated);
    let decoded = decode(&body);
    assert_eq!(decoded.is_some(), accepted, "body {body:?}");
    if let Some(envelope) = decoded {
        assert_eq!(encode_request(&envelope), body);
    }
}

const OP_RUN_FOR_TEST: u8 = 4;

/// @cc [owner:ghuntley,label:verification] hostd-directory-model
/// Acquire datagrams MUST be accepted exactly when the directory is
/// absolute, NUL-free, at most 4096 bytes and has no empty, `.` or `..`
/// component, and the wait is at most 120000 ms.
#[hegel::test]
fn acquire_decoding_matches_model(tc: TestCase) {
    let parts: Vec<Vec<u8>> = (0..tc.draw(gs::integers::<usize>().min_value(0).max_value(5)))
        .map(|_| {
            tc.draw(hegel::one_of!(
                gs::just(b"a".to_vec()),
                gs::just(b".".to_vec()),
                gs::just(b"..".to_vec()),
                gs::just(Vec::new()),
                gs::binary().max_size(4),
            ))
        })
        .collect();
    let absolute = tc.draw(gs::booleans());
    let mut directory = Vec::new();
    for part in &parts {
        if absolute || !directory.is_empty() {
            directory.push(b'/');
        }
        directory.extend(part);
    }
    let wait = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(0).max_value(10),
        gs::integers::<u32>().min_value(119_990).max_value(120_010),
    ));
    let mode = tc.draw(gs::integers::<u8>().min_value(0).max_value(2));
    let mut body = vec![2_u8];
    body.extend(9_u64.to_be_bytes());
    body.push(mode);
    body.extend(wait.to_be_bytes());
    body.extend(&directory);
    let model = mode <= 1
        && wait <= 120_000
        && directory.first() == Some(&b'/')
        && !directory.contains(&0)
        && directory[1..]
            .split(|byte| *byte == b'/')
            .all(|part| !part.is_empty() && part != b"." && part != b"..");
    assert_eq!(decode(&body).is_some(), model, "directory {directory:?}");
}

/// Replies round-trip through the reference decoder.
#[hegel::test]
fn replies_round_trip(tc: TestCase) {
    let id = tc.draw(gs::integers::<u64>());
    let bytes = tc.draw(gs::binary().max_size(64));
    let reply = match tc.draw(gs::integers::<u8>().min_value(0).max_value(6)) {
        0 => Reply::Hello { version: 1 },
        1 => Reply::Granted {
            lease: tc.draw(gs::integers::<u64>()),
        },
        2 => Reply::Refused {
            reason: Refusal::LeaseBusy,
        },
        3 => Reply::Released,
        4 => Reply::Chunk { bytes },
        5 => Reply::Connected,
        _ => Reply::Result {
            status: Status::Cancelled,
            bytes,
        },
    };
    assert_eq!(decode_reply(&encode_reply(id, &reply)), Some((id, reply)));
}

/// Mutating utilities and the closed table stay in step with Lilly's list.
#[test]
fn utility_table_is_dense_and_mutations_marked() {
    for (index, utility) in Utility::ALL.iter().enumerate() {
        assert_eq!(usize::from(utility.index()), index);
        assert_eq!(
            Utility::from_index(u8::try_from(index).unwrap()),
            Some(*utility)
        );
    }
    assert_eq!(
        Utility::from_index(u8::try_from(Utility::ALL.len()).unwrap()),
        None
    );
    for utility in [
        Utility::ImageCopy,
        Utility::Mv,
        Utility::Rm,
        Utility::ZfsMutation,
        Utility::Mount,
        Utility::Umount,
        Utility::SystemdRun,
        Utility::Chown,
        Utility::Chmod,
    ] {
        assert!(utility.mutating());
    }
    for utility in [
        Utility::Zfs,
        Utility::Stat,
        Utility::Systemctl,
        Utility::ImageIdentity,
    ] {
        assert!(!utility.mutating());
    }
}

// ------------------------------------------------------------------ leases

fn leases(root: &Path) -> Leases {
    Leases::new(&[root.to_path_buf()]).expect("root opens")
}

/// @cc [owner:ghuntley,label:verification;concurrency] lease-fifo-property
/// For generated sequences of exclusive and shared waiters queued behind a
/// held exclusive lease, grants MUST follow arrival order (shared waiters
/// may share a grant with the shared waiters directly before them) and no
/// exclusive lease may ever overlap another lease on the same inode.
#[hegel::test(test_cases = 30)]
fn lease_grants_follow_arrival_order(tc: TestCase) {
    if crate::descriptor_resolution::unavailable("lease_grants_follow_arrival_order") {
        return;
    }
    let modes: Vec<Mode> = (0..tc.draw(gs::integers::<usize>().min_value(1).max_value(6)))
        .map(|_| {
            if tc.draw(gs::booleans()) {
                Mode::Shared
            } else {
                Mode::Exclusive
            }
        })
        .collect();
    let directory = tempfile::tempdir().expect("tempdir");
    let table = Arc::new(leases(directory.path()));
    let never = Arc::new(AtomicBool::new(false));
    let (first, _) = table
        .acquire(0, Mode::Exclusive, directory.path(), Duration::ZERO, &never)
        .expect("first lease");
    let log = Arc::new(Mutex::new(Vec::<(usize, &'static str, Mode)>::new()));
    let mut threads = Vec::new();
    for (index, mode) in modes.iter().copied().enumerate() {
        let shared = Arc::clone(&table);
        let log = Arc::clone(&log);
        let never = Arc::clone(&never);
        let path = directory.path().to_path_buf();
        threads.push(std::thread::spawn(move || {
            let (lease, _) = shared
                .acquire(
                    index as u64 + 1,
                    mode,
                    &path,
                    Duration::from_secs(20),
                    &never,
                )
                .expect("granted");
            log.lock().unwrap().push((index, "granted", mode));
            std::thread::sleep(Duration::from_millis(15));
            log.lock().unwrap().push((index, "released", mode));
            shared.release(index as u64 + 1, lease);
        }));
        // Arrival order is the order threads reach the queue: wait until this
        // waiter is queued before the next one starts (no timing assumption).
        let deadline = Instant::now() + Duration::from_secs(20);
        while table.waiting() < index + 1 {
            assert!(Instant::now() < deadline, "waiter {index} never queued");
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    assert!(table.release(0, first));
    for thread in threads {
        thread.join().expect("waiter");
    }
    let log = log.lock().unwrap();
    // Grant order follows arrival order. Consecutive shared waiters form one
    // group that may be granted together, in any order within the group.
    let mut groups = Vec::new();
    let mut group = 0;
    for (index, mode) in modes.iter().enumerate() {
        if index > 0 && !(*mode == Mode::Shared && modes[index - 1] == Mode::Shared) {
            group += 1;
        }
        groups.push(group);
    }
    let grants: Vec<usize> = log
        .iter()
        .filter(|(_, event, _)| *event == "granted")
        .map(|(index, _, _)| groups[*index])
        .collect();
    let mut sorted = grants.clone();
    sorted.sort_unstable();
    assert_eq!(grants, sorted, "log {log:?}");
    // Mutual exclusion: replay the log.
    let mut holders: Vec<Mode> = Vec::new();
    for (_, event, mode) in log.iter() {
        if *event == "granted" {
            assert!(
                !holders.contains(&Mode::Exclusive)
                    && (*mode == Mode::Shared || holders.is_empty()),
                "overlap in {log:?}"
            );
            holders.push(*mode);
        } else {
            let position = holders.iter().position(|held| held == mode).unwrap();
            holders.remove(position);
        }
    }
}

#[test]
fn zero_wait_is_one_attempt_and_contention_is_distinct() {
    if crate::descriptor_resolution::unavailable(
        "zero_wait_is_one_attempt_and_contention_is_distinct",
    ) {
        return;
    }
    let directory = tempfile::tempdir().expect("tempdir");
    let table = leases(directory.path());
    let never = AtomicBool::new(false);
    let (lease, _) = table
        .acquire(1, Mode::Exclusive, directory.path(), Duration::ZERO, &never)
        .unwrap();
    let started = Instant::now();
    assert_eq!(
        table
            .acquire(2, Mode::Exclusive, directory.path(), Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Contended
    );
    assert!(started.elapsed() < Duration::from_millis(100));
    // Another process's flock is contention too.
    assert!(table.release(1, lease));
    let outside = std::fs::File::open(directory.path().join("owner.lock")).unwrap();
    rustix::fs::flock(
        &outside,
        rustix::fs::FlockOperation::NonBlockingLockExclusive,
    )
    .unwrap();
    assert_eq!(
        table
            .acquire(
                2,
                Mode::Exclusive,
                directory.path(),
                Duration::from_millis(60),
                &never
            )
            .unwrap_err(),
        Refusal::Contended
    );
    drop(outside);
    assert!(table
        .acquire(
            2,
            Mode::Exclusive,
            directory.path(),
            Duration::from_millis(500),
            &never
        )
        .is_ok());
}

#[test]
fn unsafe_inodes_and_paths_outside_roots_are_unavailable() {
    let directory = tempfile::tempdir().expect("tempdir");
    let table = leases(directory.path());
    let never = AtomicBool::new(false);
    let outside = tempfile::tempdir().expect("tempdir");
    assert_eq!(
        table
            .acquire(1, Mode::Exclusive, outside.path(), Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Unavailable
    );
    // A symlinked component is refused.
    std::os::unix::fs::symlink(outside.path(), directory.path().join("link")).unwrap();
    assert_eq!(
        table
            .acquire(
                1,
                Mode::Exclusive,
                &directory.path().join("link"),
                Duration::ZERO,
                &never
            )
            .unwrap_err(),
        Refusal::Unavailable
    );
    // A group-writable or hard-linked inode is refused.
    let lock = directory.path().join("w");
    std::fs::create_dir(&lock).unwrap();
    std::fs::write(lock.join("owner.lock"), b"").unwrap();
    std::fs::set_permissions(
        lock.join("owner.lock"),
        std::fs::Permissions::from_mode(0o620),
    )
    .unwrap();
    assert_eq!(
        table
            .acquire(1, Mode::Exclusive, &lock, Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Unavailable
    );
    let linked = directory.path().join("l");
    std::fs::create_dir(&linked).unwrap();
    std::fs::write(linked.join("owner.lock"), b"").unwrap();
    std::fs::hard_link(linked.join("owner.lock"), directory.path().join("extra")).unwrap();
    assert_eq!(
        table
            .acquire(1, Mode::Exclusive, &linked, Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Unavailable
    );
}

// ----------------------------------------------------------------- session

struct Fixture {
    _directory: tempfile::TempDir,
    socket: PathBuf,
    root: PathBuf,
}

/// Writes a fixture script for the pinned shell in `LILLY_TEST_SHELL` (Buck2
/// sets a Nix bash) or `/bin/sh` under Cargo. The bodies stay POSIX, so dash
/// (Debian's `/bin/sh`) runs them too.
fn script(directory: &Path, name: &str, body: &str) {
    let path = directory.join(name);
    let shell = std::env::var("LILLY_TEST_SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
    std::fs::write(&path, format!("#!{shell}\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A daemon on a private socket whose utility table resolves to test scripts:
/// `stat` echoes its arguments, `cp` (mutating, not native) sleeps for $1 seconds
/// and `realpath` prints $1 bytes.
fn daemon() -> Fixture {
    start_reaper().expect("subreaper");
    let directory = tempfile::tempdir().expect("tempdir");
    let bin = directory.path().join("bin");
    let root = directory.path().join("root");
    std::fs::create_dir(&bin).unwrap();
    std::fs::create_dir(&root).unwrap();
    script(&bin, "stat", "echo \"$@\"");
    script(&bin, "systemctl", "echo \"$@\"");
    script(&bin, "cp", "sleep \"$1\"");
    script(&bin, "realpath", "head -c \"$1\" /dev/zero");
    // The stream helper records its argv and progress descriptor, then exits
    // with the code named by its consumer's last argument when numeric. It
    // writes through /proc: dash cannot redirect to a descriptor above 9, and
    // the inherited one often is.
    let record = directory.path().join("stream-record");
    script(
        &bin,
        "lilly-transfer-stream",
        &format!(
            "printf '%s\\n' \"$@\" > {record}\nfd=$3\n[ \"$fd\" = - ] || printf 'progress' >> \"/proc/self/fd/$fd\" || exit 70\nexit 6",
            record = record.display()
        ),
    );
    script(&bin, "zfs", "exit 0");
    script(
        &bin,
        "lilly-resume-token",
        "[ \"$3\" = 1-ab-cd-ef ] && echo ok",
    );
    let mut path = OsString::from(&bin);
    path.push(":");
    path.push(std::env::var_os("PATH").unwrap_or_default());
    let daemon = Arc::new(Daemon::new(
        Leases::new(std::slice::from_ref(&root)).unwrap(),
        Table::resolve(&path),
        Custody::ProcessGroup,
        rustix::process::geteuid().as_raw(),
        Vec::new(),
    ));
    let socket = directory.path().join("hostd.sock");
    let listener = socket_with(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    rustix::net::bind(&listener, &SocketAddrUnix::new(&socket).unwrap()).unwrap();
    rustix::net::listen(&listener, 16).unwrap();
    std::thread::spawn(move || loop {
        let Ok(connection) = rustix::net::accept_with(&listener, SocketFlags::CLOEXEC) else {
            return;
        };
        let daemon = Arc::clone(&daemon);
        std::thread::spawn(move || serve(daemon, connection));
    });
    Fixture {
        _directory: directory,
        socket,
        root,
    }
}

struct Client {
    socket: OwnedFd,
}

impl Client {
    fn connect(fixture: &Fixture) -> Client {
        let socket = socket_with(
            AddressFamily::UNIX,
            SocketType::SEQPACKET,
            SocketFlags::CLOEXEC,
            None,
        )
        .unwrap();
        connect(&socket, &SocketAddrUnix::new(&fixture.socket).unwrap()).unwrap();
        let client = Client { socket };
        client.send(1, Request::Hello { version: 1 });
        assert_eq!(client.receive(), (1, Reply::Hello { version: 1 }));
        client
    }

    fn send(&self, id: u64, request: Request) {
        send(
            &self.socket,
            &encode_request(&Envelope { id, request }),
            SendFlags::NOSIGNAL,
        )
        .unwrap();
    }

    fn receive(&self) -> (u64, Reply) {
        let mut buffer = vec![0_u8; 70_000];
        let (size, _) = recv(&self.socket, &mut buffer, RecvFlags::empty()).unwrap();
        decode_reply(&buffer[..size]).expect("reply decodes")
    }

    fn acquire(&self, id: u64, directory: &Path, wait_ms: u32) -> Reply {
        self.send(
            id,
            Request::Acquire {
                mode: Mode::Exclusive,
                wait_ms,
                directory: directory.as_os_str().as_encoded_bytes().to_vec(),
            },
        );
        self.receive().1
    }

    fn run(&self, id: u64, lease: u64, utility: Utility, arguments: &[&str], timeout_ms: u32) {
        self.send(
            id,
            Request::Run {
                lease,
                timeout_ms,
                output_limit: 65_536,
                utility,
                arguments: arguments
                    .iter()
                    .map(|a| CString::new(*a).unwrap())
                    .collect(),
            },
        );
    }

    /// Collect a command's chunks and final result.
    fn result(&self) -> (Status, Vec<u8>) {
        let mut bytes = Vec::new();
        loop {
            match self.receive().1 {
                Reply::Chunk { bytes: chunk } => bytes.extend(chunk),
                Reply::Result {
                    status,
                    bytes: rest,
                } => {
                    bytes.extend(rest);
                    return (status, bytes);
                }
                other => panic!("unexpected {other:?}"),
            }
        }
    }
}

#[test]
fn hello_is_required_and_version_checked() {
    let fixture = daemon();
    let socket = socket_with(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    connect(&socket, &SocketAddrUnix::new(&fixture.socket).unwrap()).unwrap();
    let client = Client { socket };
    client.send(5, Request::Hello { version: 2 });
    assert_eq!(
        client.receive(),
        (
            5,
            Reply::Refused {
                reason: Refusal::Version
            }
        )
    );
}

#[test]
fn commands_capture_output_and_mutations_need_a_lease() {
    let fixture = daemon();
    let client = Client::connect(&fixture);
    client.run(2, 0, Utility::Stat, &["one", "two"], 5000);
    assert_eq!(client.result(), (Status::Succeeded, b"one two\n".to_vec()));
    client.run(3, 0, Utility::Cp, &["0"], 5000);
    assert_eq!(
        client.receive(),
        (
            3,
            Reply::Refused {
                reason: Refusal::LeaseRequired
            }
        )
    );
    // Output larger than one datagram arrives in chunks and reassembles.
    client.run(4, 0, Utility::Realpath, &["100000"], 5000);
    assert_eq!(client.result(), (Status::OutputLimit, Vec::new()));
    client.run(5, 0, Utility::Realpath, &["60000"], 5000);
    let (status, bytes) = client.result();
    assert_eq!((status, bytes.len()), (Status::Succeeded, 60_000));
}

/// Systemctl's read-only index MUST NOT permit lease-free stop/kill. The
/// same confined lifecycle grammar becomes executable under a live lease.
#[test]
fn systemctl_queries_are_lease_free_but_lifecycle_is_serialized() {
    if crate::descriptor_resolution::unavailable(
        "systemctl_queries_are_lease_free_but_lifecycle_is_serialized",
    ) {
        return;
    }
    let fixture = daemon();
    let client = Client::connect(&fixture);
    let vm = "lilly-vm-11111111-2222-4333-8444-555555555555.service";
    for (index, arguments) in [vec!["show", vm], vec!["list-units", "--all", vm]]
        .iter()
        .enumerate()
    {
        client.run(2 + index as u64, 0, Utility::Systemctl, arguments, 5000);
        assert_eq!(
            client.result(),
            (
                Status::Succeeded,
                format!("{}\n", arguments.join(" ")).into_bytes()
            )
        );
    }
    let operations = [
        vec!["stop", vm],
        vec!["kill", "--kill-who=all", "--signal=KILL", vm],
    ];
    for (index, arguments) in operations.iter().enumerate() {
        let id = 4 + index as u64;
        client.run(id, 0, Utility::Systemctl, arguments, 5000);
        assert_eq!(
            client.receive(),
            (
                id,
                Reply::Refused {
                    reason: Refusal::LeaseRequired
                }
            )
        );
    }
    let Reply::Granted { lease } = client.acquire(6, &fixture.root, 0) else {
        panic!("lease")
    };
    for (index, arguments) in operations.iter().enumerate() {
        client.run(7 + index as u64, lease, Utility::Systemctl, arguments, 5000);
        assert_eq!(
            client.result(),
            (
                Status::Succeeded,
                format!("{}\n", arguments.join(" ")).into_bytes()
            )
        );
    }
    client.send(9, Request::Release { lease });
    assert_eq!(client.receive(), (9, Reply::Released));
}

#[test]
fn timeouts_kill_and_leases_serialize_commands() {
    if crate::descriptor_resolution::unavailable("timeouts_kill_and_leases_serialize_commands") {
        return;
    }
    let fixture = daemon();
    let client = Client::connect(&fixture);
    let Reply::Granted { lease } = client.acquire(2, &fixture.root, 0) else {
        panic!("lease")
    };
    let started = Instant::now();
    client.run(3, lease, Utility::Cp, &["30"], 1000);
    // A second command on the same lease is refused while one runs.
    std::thread::sleep(Duration::from_millis(100));
    client.run(4, lease, Utility::Cp, &["0"], 1000);
    assert_eq!(
        client.receive(),
        (
            4,
            Reply::Refused {
                reason: Refusal::LeaseBusy
            }
        )
    );
    assert_eq!(client.result(), (Status::TimedOut, Vec::new()));
    assert!(started.elapsed() < Duration::from_secs(5));
}

/// @cc [owner:ghuntley,label:verification;recovery] session-death-fences
/// Closing a session with a command in flight MUST kill that command and
/// release its lease, after which another session is granted the lease; a
/// release likewise cancels its lease's command first.
#[test]
fn session_death_kills_commands_and_releases_leases() {
    if crate::descriptor_resolution::unavailable("session_death_kills_commands_and_releases_leases")
    {
        return;
    }
    let fixture = daemon();
    let first = Client::connect(&fixture);
    let Reply::Granted { lease } = first.acquire(2, &fixture.root, 0) else {
        panic!("lease")
    };
    first.run(3, lease, Utility::Cp, &["30"], 60_000);
    std::thread::sleep(Duration::from_millis(100));
    let second = Client::connect(&fixture);
    assert_eq!(
        second.acquire(2, &fixture.root, 0),
        Reply::Refused {
            reason: Refusal::Contended
        }
    );
    let started = Instant::now();
    drop(first);
    assert!(matches!(
        second.acquire(3, &fixture.root, 10_000),
        Reply::Granted { .. }
    ));
    assert!(started.elapsed() < Duration::from_secs(5));
    // Release cancels the in-flight command before replying.
    let third_root = fixture.root.join("third");
    std::fs::create_dir(&third_root).unwrap();
    let Reply::Granted { lease } = second.acquire(4, &third_root, 0) else {
        panic!("lease")
    };
    second.run(5, lease, Utility::Cp, &["30"], 60_000);
    std::thread::sleep(Duration::from_millis(100));
    second.send(6, Request::Release { lease });
    let mut replies = vec![second.receive(), second.receive()];
    replies.sort_by_key(|(id, _)| *id);
    assert_eq!(
        replies,
        vec![
            (
                5,
                Reply::Result {
                    status: Status::Cancelled,
                    bytes: Vec::new()
                }
            ),
            (6, Reply::Released)
        ]
    );
}

#[test]
fn options_parse_strictly() {
    let parse = |items: &[&str]| {
        crate::parse_options(&items.iter().map(OsString::from).collect::<Vec<_>>())
    };
    assert!(parse(&["--socket", "/run/s", "--root", "/var/lib/lilly"]).is_some());
    assert!(parse(&["--socket", "/run/s"]).is_none());
    assert!(parse(&["--socket", "run/s", "--root", "/x"]).is_none());
    assert!(
        parse(&["--socket", "/run/s", "--root", "/x", "--cgroup", "self"])
            .is_some_and(|options| options.cgroup == Some(None))
    );
    assert!(parse(&["--socket", "/a", "--socket", "/b", "--root", "/x"]).is_none());
    assert!(parse(&["--socket", "/a", "--root", "/x", "--peer-uid", "nobody"]).is_none());
    assert!(
        parse(&["--socket", "/a", "--root", "/x", "--service-uid", "977"])
            .is_some_and(|options| options.service_uid == Some(977) && options.peer_uid.is_none())
    );
    assert!(parse(&["--socket", "/a", "--root", "/x", "--service-uid", "lilly"]).is_none());
    assert!(parse(&[
        "--socket",
        "/a",
        "--root",
        "/x",
        "--service-uid",
        "1",
        "--service-uid",
        "2"
    ])
    .is_none());
    assert!(parse(&["--socket", "/a", "--root", "/x", "--bogus", "1"]).is_none());
}

/// @cc [owner:ghuntley,label:verification;recovery] durable-job-survives-session
/// A durable job MUST keep running and keep its lease after its session
/// closes; another session MUST be able to attach to its result, and is
/// granted the lease only once the job finished.
#[test]
fn durable_jobs_outlive_their_session() {
    if crate::descriptor_resolution::unavailable("durable_jobs_outlive_their_session") {
        return;
    }
    let fixture = daemon();
    let key = [7_u8; JOB_KEY];
    let first = Client::connect(&fixture);
    let Reply::Granted { lease } = first.acquire(2, &fixture.root, 0) else {
        panic!("lease")
    };
    first.send(
        3,
        Request::RunDurable {
            key,
            lease,
            timeout_ms: 10_000,
            output_limit: 65_536,
            utility: Utility::Cp,
            arguments: vec![CString::new("1").unwrap()],
        },
    );
    std::thread::sleep(Duration::from_millis(100));
    drop(first);
    let second = Client::connect(&fixture);
    // The job still holds the lease.
    assert_eq!(
        second.acquire(2, &fixture.root, 0),
        Reply::Refused {
            reason: Refusal::Contended
        }
    );
    second.send(
        3,
        Request::Attach {
            key,
            wait_ms: 10_000,
        },
    );
    assert_eq!(second.result(), (Status::Succeeded, Vec::new()));
    assert!(matches!(
        second.acquire(4, &fixture.root, 2_000),
        Reply::Granted { .. }
    ));
    second.send(
        5,
        Request::Attach {
            key: [9_u8; JOB_KEY],
            wait_ms: 0,
        },
    );
    assert_eq!(
        second.receive(),
        (
            5,
            Reply::Refused {
                reason: Refusal::UnknownJob
            }
        )
    );
}

// --------------------------------------------------------------- VM launch

fn launch_tools() -> crate::vm_launch::Tools {
    crate::vm_launch::Tools {
        boot_log: PathBuf::from("/tools/boot-log"),
        unshare: PathBuf::from("/tools/unshare"),
        launch_guard: PathBuf::from("/tools/guard"),
        jailer: PathBuf::from("/tools/jailer"),
        firecracker: PathBuf::from("/tools/firecracker"),
    }
}

fn launch(firmware: bool) -> crate::vm_launch::Launch {
    crate::vm_launch::Launch {
        placement: *b"11111111-2222-4333-8444-555555555555",
        epoch: 7,
        generation: 9,
        uid: 1_000_010,
        memory_bytes: 1_342_177_280,
        vcpus: 2,
        firmware,
        logging: true,
        restore: false,
        state_dir: b"/var/lib/lilly/vms".to_vec(),
        namespace: b"lilly-guests".to_vec(),
        pool: b"/pool".to_vec(),
    }
}

fn strings(argv: Vec<CString>) -> Vec<String> {
    argv.into_iter().map(|a| a.into_string().unwrap()).collect()
}

/// The launch command line moved from Lilly's `Unit.arguments/5`; these are
/// that test's guarantees (vm-launch-argv-derived-by-hostd).
#[test]
fn vm_launch_builds_the_unit_command_line() {
    let pools = [PathBuf::from("/pool")];
    let roots = [PathBuf::from("/var/lib/lilly")];
    let tools = launch_tools();
    let kernel =
        strings(crate::vm_launch::argv(Some(&tools), &roots, &pools, &launch(false), 0).unwrap());
    let pci =
        strings(crate::vm_launch::argv(Some(&tools), &roots, &pools, &launch(true), 0).unwrap());
    let placement = "11111111-2222-4333-8444-555555555555";
    assert!(!kernel.contains(&"--enable-pci".to_string()));
    let index = pci.iter().position(|a| a == "/firecracker.json").unwrap();
    assert_eq!(
        pci[index + 1..index + 4],
        ["--enable-pci", "--metadata", "/metadata.json"]
    );
    let mut without = pci.clone();
    without.drain(index + 1..index + 4);
    assert_eq!(without, kernel);
    assert!(kernel.contains(&format!(
        "--description=Overalls VM v1 placement={placement} epoch=7 generation=9"
    )));
    assert!(kernel.contains(&format!("lilly.slice/lilly-vm-{placement}.service")));
    assert!(kernel.contains(&format!("/var/lib/lilly/vms/{placement}/boot.log")));
    assert!(kernel.contains(&format!("/var/lib/lilly/vms/{placement}/launch/owner.lock")));
    assert!(kernel.contains(&"/pool/.lilly-jails".to_string()));
    assert!(kernel.contains(&"/run/netns/lilly-guests".to_string()));
    assert!(kernel.ends_with(&[
        "--log-path".into(),
        "/log-7-9.fifo".into(),
        "--metrics-path".into(),
        "/metrics-7-9.fifo".into()
    ]));
    let separator = kernel.iter().position(|a| a == "--").unwrap();
    assert_eq!(
        kernel[separator..separator + 10],
        [
            "--",
            "/tools/boot-log",
            &format!("/var/lib/lilly/vms/{placement}/boot.log"),
            "/tools/unshare",
            "--fork",
            "--pid",
            "--kill-child=KILL",
            "/tools/unshare",
            "--mount-proc",
            "/tools/guard"
        ]
    );
    assert!(!kernel
        .iter()
        .any(|a| a.starts_with("--property=StandardOutput=")));
}

/// An unprivileged service uid reaches exactly the boot-log writer
/// (`--reader-uid`) and the launch guard (`--owner-uid`); otherwise the
/// command line is the root one (vm-launch-argv-derived-by-hostd).
#[test]
fn vm_launch_hands_an_unprivileged_service_its_files() {
    let pools = [PathBuf::from("/pool")];
    let roots = [PathBuf::from("/var/lib/lilly")];
    let tools = launch_tools();
    let placement = "11111111-2222-4333-8444-555555555555";
    let root =
        strings(crate::vm_launch::argv(Some(&tools), &roots, &pools, &launch(false), 0).unwrap());
    let service =
        strings(crate::vm_launch::argv(Some(&tools), &roots, &pools, &launch(false), 377).unwrap());
    let writer = service.iter().position(|a| a == "/tools/boot-log").unwrap();
    assert_eq!(
        service[writer..writer + 4],
        [
            "/tools/boot-log",
            "--reader-uid",
            "377",
            &format!("/var/lib/lilly/vms/{placement}/boot.log")
        ]
    );
    let guard = service.iter().position(|a| a == "/tools/guard").unwrap();
    assert_eq!(service[guard + 1..guard + 3], ["--owner-uid", "377"]);
    let mut stripped = service.clone();
    stripped.drain(guard + 1..guard + 3);
    stripped.drain(writer + 1..writer + 3);
    assert_eq!(stripped, root);
    assert!(!root
        .iter()
        .any(|a| a == "--reader-uid" || a == "--owner-uid"));
}

/// Snapshot loading is only legal on an unconfigured VMM. The independent
/// model checks every launch mode, including firmware and logging, so a restore
/// cannot accidentally follow the cold-boot configuration path.
#[hegel::test]
fn restore_launch_never_boots_before_snapshot_load(tc: TestCase) {
    let pools = [PathBuf::from("/pool")];
    let roots = [PathBuf::from("/var/lib/lilly")];
    let tools = launch_tools();
    let firmware = tc.draw(gs::booleans());
    let mut request = launch(firmware);
    request.restore = true;
    request.logging = tc.draw(gs::booleans());
    let arguments =
        strings(crate::vm_launch::argv(Some(&tools), &roots, &pools, &request, 377).unwrap());
    for forbidden in [
        "--config-file",
        "/firecracker.json",
        "--metadata",
        "/metadata.json",
    ] {
        assert!(!arguments.iter().any(|argument| argument == forbidden));
    }
    assert_eq!(
        arguments.iter().any(|argument| argument == "--enable-pci"),
        firmware
    );
    assert!(arguments
        .windows(2)
        .any(|pair| pair == ["--api-sock", "/api.sock"]));
    assert!(arguments.iter().any(|argument| argument == "--owner-uid"));
    assert!(arguments
        .iter()
        .any(|argument| argument == "--property=KillMode=control-group"));
    // Restore mode changes no launch custody or resource restrictions.
    request.uid = 0;
    assert_eq!(
        crate::vm_launch::argv(Some(&tools), &roots, &pools, &request, 377),
        Err(Refusal::Malformed)
    );
}

#[test]
fn vm_launch_refuses_unknown_launch_flags() {
    let envelope = Envelope {
        id: 1,
        request: Request::LaunchVm {
            lease: 1,
            launch: launch(false),
        },
    };
    let mut frame = encode_request(&envelope);
    // Datagram header (9), then lease/placement/epoch/generation/uid/memory/vCPU.
    let flags = 9 + 8 + 36 + 8 + 8 + 4 + 8 + 1;
    frame[flags] |= 0b1000;
    assert_eq!(decode(&frame), None);
}

#[test]
fn vm_launch_refuses_out_of_policy_requests() {
    let pools = [PathBuf::from("/pool")];
    let roots = [PathBuf::from("/var/lib/lilly")];
    let tools = launch_tools();
    let refused = |change: &dyn Fn(&mut crate::vm_launch::Launch)| {
        let mut request = launch(false);
        change(&mut request);
        crate::vm_launch::argv(Some(&tools), &roots, &pools, &request, 0)
    };
    assert_eq!(refused(&|l| l.uid = 0), Err(Refusal::Malformed));
    assert_eq!(refused(&|l| l.uid = 1_262_143), Err(Refusal::Malformed));
    assert_eq!(
        refused(&|l| l.pool = b"/etc".to_vec()),
        Err(Refusal::Malformed)
    );
    assert_eq!(
        refused(&|l| l.pool = b"/pool/../etc".to_vec()),
        Err(Refusal::Malformed)
    );
    assert_eq!(
        refused(&|l| l.namespace = b"../../proc/1/ns/net".to_vec()),
        Err(Refusal::Malformed)
    );
    assert_eq!(
        refused(&|l| l.placement = *b"11111111-2222-4333-8444-55555555555X"),
        Err(Refusal::Malformed)
    );
    assert_eq!(refused(&|l| l.epoch = 0), Err(Refusal::Malformed));
    assert_eq!(
        refused(&|l| l.state_dir = b"/etc/lilly".to_vec()),
        Err(Refusal::Malformed)
    );
    assert_eq!(
        refused(&|l| l.state_dir = b"/var/lib/lilly/../../etc".to_vec()),
        Err(Refusal::Malformed)
    );
    assert_eq!(refused(&|l| l.vcpus = 0), Err(Refusal::Malformed));
    assert_eq!(refused(&|l| l.memory_bytes = 1), Err(Refusal::Malformed));
    assert_eq!(
        crate::vm_launch::argv(None, &roots, &pools, &launch(false), 0),
        Err(Refusal::Unavailable)
    );
}

/// `LaunchVm` datagrams round-trip, and direct systemd-run requests are refused.
#[hegel::test]
fn vm_launch_decoding_round_trips(tc: TestCase) {
    let mut request = launch(tc.draw(gs::booleans()));
    request.logging = tc.draw(gs::booleans());
    request.restore = tc.draw(gs::booleans());
    request.epoch = tc.draw(gs::integers::<u64>());
    request.uid = tc.draw(gs::integers::<u32>());
    let envelope = Envelope {
        id: tc.draw(gs::integers::<u64>()),
        request: Request::LaunchVm {
            lease: tc.draw(gs::integers::<u64>()),
            launch: request,
        },
    };
    let bytes = encode_request(&envelope);
    assert_eq!(decode(&bytes), Some(envelope));
    let direct = encode_request(&Envelope {
        id: 1,
        request: Request::Run {
            lease: 1,
            timeout_ms: 10_000,
            output_limit: DEFAULT_OUTPUT_LIMIT,
            utility: Utility::SystemdRun,
            arguments: vec![],
        },
    });
    assert_eq!(decode(&direct), None);
}

// ---------------------------------------------------------- transfer stream

fn local_stream(lease: u64, producer: Option<crate::transfer::Producer>) -> Request {
    let placement = b"11111111-2222-4333-8444-555555555555".to_vec();
    Request::TransferStream {
        lease,
        timeout_ms: 5_000,
        rate: 0,
        stream: Box::new(crate::transfer::Stream {
            producer: producer.unwrap_or(crate::transfer::Producer::LocalSend {
                dataset: b"tank/lilly".to_vec(),
                placement: placement.clone(),
            }),
            consumer: crate::transfer::Consumer::Receive {
                dataset: b"tank/lilly".to_vec(),
                pool: b"/pool".to_vec(),
                placement,
                host: b"44444444-5555-4666-8777-888888888888".to_vec(),
                pool_id: b"55555555-6666-4777-8888-999999999999".to_vec(),
                nonce: b"0123456789abcdef0123456789abcdef".to_vec(),
            },
        }),
    }
}

/// A stream needs a held lease, runs the helper with the derived argv and an
/// inherited progress descriptor on `<lease directory>/progress`, and returns
/// exactly the helper's exit code; generic runs of the helper are refused.
#[test]
fn transfer_streams_run_the_helper_under_the_lease() {
    if crate::descriptor_resolution::unavailable("transfer_streams_run_the_helper_under_the_lease")
    {
        return;
    }
    let fixture = daemon();
    let client = Client::connect(&fixture);
    client.send(2, local_stream(0, None));
    assert_eq!(
        client.receive(),
        (
            2,
            Reply::Refused {
                reason: Refusal::LeaseRequired
            }
        )
    );
    let directory = fixture.root.join("stream");
    std::fs::create_dir(&directory).unwrap();
    let Reply::Granted { lease } = client.acquire(3, &directory, 0) else {
        panic!("lease")
    };
    client.send(4, local_stream(lease, None));
    assert_eq!(client.result(), (Status::Failed, vec![6]));
    let record = std::fs::read_to_string(fixture.root.parent().unwrap().join("stream-record"))
        .expect("helper ran");
    let argv: Vec<&str> = record.lines().collect();
    assert_eq!(&argv[..2], ["5000", "0"]);
    assert_ne!(argv[2], "-", "a progress descriptor was inherited");
    assert_eq!(&argv[3..6], ["-", "-", "4"]);
    assert_eq!(
        argv[9],
        "tank/lilly/vm-11111111-2222-4333-8444-555555555555@lilly-b"
    );
    assert_eq!(
        std::fs::read(directory.join("progress")).unwrap(),
        b"progress"
    );
    // The helper is never reachable through a generic Run.
    let direct = encode_request(&Envelope {
        id: 5,
        request: Request::Run {
            lease,
            timeout_ms: 10_000,
            output_limit: DEFAULT_OUTPUT_LIMIT,
            utility: Utility::TransferStream,
            arguments: vec![],
        },
    });
    assert_eq!(decode(&direct), None);
}

/// A local resume runs only after lilly-resume-token confirmed the token.
#[test]
fn local_resume_requires_the_token_check() {
    if crate::descriptor_resolution::unavailable("local_resume_requires_the_token_check") {
        return;
    }
    let fixture = daemon();
    let client = Client::connect(&fixture);
    let directory = fixture.root.join("resume");
    std::fs::create_dir(&directory).unwrap();
    let Reply::Granted { lease } = client.acquire(2, &directory, 0) else {
        panic!("lease")
    };
    let resume = |token: &[u8]| {
        local_stream(
            lease,
            Some(crate::transfer::Producer::LocalResume {
                dataset: b"tank/lilly".to_vec(),
                placement: b"11111111-2222-4333-8444-555555555555".to_vec(),
                to_guid: b"42".to_vec(),
                token: token.to_vec(),
            }),
        )
    };
    client.send(3, resume(b"1-ab-cd-00"));
    assert_eq!(client.result(), (Status::Setup, vec![]));
    client.send(4, resume(b"1-ab-cd-ef"));
    assert_eq!(client.result(), (Status::Failed, vec![6]));
}
