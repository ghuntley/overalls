//!
//! The Erlang port ABI puts the control channel at fd 3 and the ack channel at
//! fd 4. `std::process` only maps stdio without an unsafe hook, so the tests use
//! one reviewed `pre_exec` placement shim; the rest of this crate is safe.

#![deny(unsafe_code)]

use std::io::{Read, Write};
use std::path::Path;
use std::process::{Child, Command as Process, Stdio};
use std::time::{Duration, Instant};

const HELPER: &str = env!("CARGO_BIN_EXE_lilly-source-export");

struct EscapedChildren(Vec<rustix::process::Pid>);

impl Drop for EscapedChildren {
    fn drop(&mut self) {
        for pid in &self.0 {
            let _ = rustix::process::kill_process(*pid, rustix::process::Signal::KILL);
        }
    }
}

fn published_pid(path: &Path) -> rustix::process::Pid {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(pid) = std::fs::read_to_string(path)
            .ok()
            .and_then(|value| value.trim().parse::<i32>().ok())
            .and_then(rustix::process::Pid::from_raw)
        {
            return pid;
        }
        assert!(
            Instant::now() < deadline,
            "complete process witness required"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
#[ignore = "export fixture"]
fn fixture_sender_escaped_children() {
    let root = std::path::PathBuf::from(std::env::var_os("HX_ESCAPE_ROOT").expect("fixture root"));
    let count = std::env::var("HX_ESCAPE_COUNT")
        .expect("fixture count")
        .parse::<usize>()
        .expect("bounded count");
    assert!((1..=3).contains(&count));
    std::fs::write(root.join("sender.pid"), std::process::id().to_string())
        .expect("sender witness");
    for index in 0..count {
        let child = Process::new(harness())
            .args([
                "--exact",
                "fixture_escaped_export_child",
                "--ignored",
                "--nocapture",
            ])
            .env("HX_ESCAPE_PID", root.join(format!("escaped-{index}.pid")))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("escaped fixture child");
        drop(child);
        published_pid(&root.join(format!("escaped-{index}.pid")));
    }
    if let Some(mode) = std::env::var_os("HX_ESCAPE_HOLD") {
        while !root.join("release-sender").exists() {
            std::thread::sleep(Duration::from_millis(5));
        }
        match mode.to_str().expect("fixture mode") {
            "fail" => std::process::exit(19),
            "diagnostics" => {
                let mut diagnostics = std::io::stderr().lock();
                for _ in 0..32 {
                    diagnostics
                        .write_all(&[b'!'; 4096])
                        .expect("bounded diagnostic fixture");
                }
                diagnostics.flush().expect("diagnostic fixture flush");
            }
            _ => panic!("unknown fixture mode"),
        }
    }
}

#[test]
#[ignore = "export fixture"]
fn fixture_escaped_export_child() {
    let session = rustix::process::setsid().expect("independent session");
    assert_eq!(
        session.as_raw_nonzero().get(),
        i32::try_from(std::process::id()).expect("PID")
    );
    std::fs::write(
        std::env::var_os("HX_ESCAPE_PID").expect("private PID witness"),
        std::process::id().to_string(),
    )
    .expect("complete escaped witness");
    std::thread::sleep(Duration::from_mins(1));
}

/// @cc [owner:ghuntley,label:verification;recovery] source-export-all-adopted-sessions
/// Successful sender completion MUST NOT release cleanup ownership while
/// independently witnessed adopted children in other sessions remain alive.
/// Explicit child death MUST permit confirmed reaping and exact helper success.
/// This local process property does not establish ZFS or remote transport acceptance.
#[hegel::test(test_cases = 2)]
fn escaped_export_children_are_reaped_before_owner_exit(tc: hegel::TestCase) {
    let drawn = tc.draw(hegel::generators::sampled_from(&[1_usize, 2, 3]));
    for count in [1, 3, drawn] {
        let (lock, directory) = start_pair();
        let root = directory.path().to_str().expect("fixture path").to_owned();
        let count_text = count.to_string();
        let (mut helper, mut control, mut ack) = spawn(
            &lock,
            "5000",
            &harness(),
            &[
                "--exact",
                "fixture_sender_escaped_children",
                "--ignored",
                "--nocapture",
            ],
            &[("HX_ESCAPE_ROOT", &root), ("HX_ESCAPE_COUNT", &count_text)],
        );
        startup(&mut ack, &mut control);
        let mut guards = EscapedChildren(Vec::new());
        let direct = published_pid(&directory.path().join("sender.pid"));
        for index in 0..count {
            let pid = published_pid(&directory.path().join(format!("escaped-{index}.pid")));
            guards.0.push(pid);
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .expect("independent escaped process");
            let fields: Vec<&str> = stat
                .rsplit_once(") ")
                .expect("process name")
                .1
                .split_whitespace()
                .collect();
            assert_ne!(pid, direct);
            assert_eq!(
                fields[2].parse::<i32>().expect("process group"),
                pid.as_raw_nonzero().get()
            );
            assert_eq!(
                fields[3].parse::<i32>().expect("session"),
                pid.as_raw_nonzero().get()
            );
        }
        let completion_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let direct_retired = match std::fs::read_to_string(format!("/proc/{direct}/stat")) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Ok(stat) => stat
                    .rsplit_once(") ")
                    .is_some_and(|(_, fields)| fields.starts_with("Z ")),
                _ => false,
            };
            if direct_retired {
                break;
            }
            assert!(
                Instant::now() < completion_deadline,
                "sender must complete independently"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let outcome = helper.0.try_wait().expect("helper status");
        let escaped_alive = guards.0.iter().all(|pid| {
            std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .and_then(|stat| {
                    stat.rsplit_once(") ")
                        .map(|(_, fields)| !fields.starts_with("Z ") && !fields.starts_with("X "))
                })
                .unwrap_or(false)
        });
        assert!(escaped_alive, "independent escaped child liveness required");
        assert!(outcome.is_none(), "adopted children must retain cleanup ownership after sender completion: count={count}, outcome={outcome:?}, escaped_alive={escaped_alive}");
        for pid in &guards.0 {
            rustix::process::kill_process(*pid, rustix::process::Signal::KILL)
                .expect("explicit fixture child death");
        }
        assert_eq!(helper.wait_bounded(Duration::from_secs(5)).code(), Some(0));
        for pid in &guards.0 {
            assert!(
                !Path::new(&format!("/proc/{pid}")).exists(),
                "adopted child must be reaped before helper exit"
            );
        }
        guards.0.clear();
    }
}

#[derive(Clone, Copy, Debug)]
enum ExportFailure {
    CallerEof,
    Cancel,
    Malformed,
    Deadline,
    SenderFailure,
    Diagnostics,
    Signal,
}

const EXPORT_FAILURES: [ExportFailure; 7] = [
    ExportFailure::CallerEof,
    ExportFailure::Cancel,
    ExportFailure::Malformed,
    ExportFailure::Deadline,
    ExportFailure::SenderFailure,
    ExportFailure::Diagnostics,
    ExportFailure::Signal,
];

/// @cc [owner:ghuntley,label:verification;recovery] export-failed-adopted-lock-custody
/// EOF, cancellation, malformed control, deadline, sender failure and excessive
/// diagnostics MUST retain exporter completion and the stable owner lock while
/// independently witnessed escaped descendants remain live. Explicit descendant
/// death MUST permit confirmed reaping, the exact original failure status and
/// successor lock admission. A signal cannot bypass this cleanup requirement.
#[hegel::test(test_cases = 2)]
fn escaped_export_failure_retains_lock_until_actual_reaping(tc: hegel::TestCase) {
    let trigger = tc.draw(hegel::generators::sampled_from(&EXPORT_FAILURES));
    let count = tc.draw(hegel::generators::sampled_from(&[1_usize, 2, 3]));
    let fixed = EXPORT_FAILURES
        .into_iter()
        .flat_map(|trigger| [1, 3].into_iter().map(move |count| (trigger, count)));
    for (trigger, count) in fixed.chain(std::iter::once((trigger, count))) {
        failed_export_case(trigger, count);
    }
}

fn export_process_retired(pid: rustix::process::Pid) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Ok(stat) => stat
            .rsplit_once(") ")
            .is_some_and(|(_, fields)| fields.starts_with("Z ")),
        _ => false,
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
#[expect(
    clippy::too_many_lines,
    reason = "one linear failure-custody scenario: setup, trigger, witness and reap stay in order"
)]
fn failed_export_case(trigger: ExportFailure, count: usize) {
    use rustix::fs::{flock, FlockOperation};
    let (lock, directory) = start_pair();
    let root = directory.path().to_str().expect("fixture root");
    let count_text = count.to_string();
    let lease = if matches!(trigger, ExportFailure::Deadline) {
        "5000"
    } else {
        "20000"
    };
    let mode = if matches!(trigger, ExportFailure::Diagnostics) {
        "diagnostics"
    } else {
        "fail"
    };
    let (mut helper, control, mut ack) = spawn(
        &lock,
        lease,
        &harness(),
        &[
            "--exact",
            "fixture_sender_escaped_children",
            "--ignored",
            "--nocapture",
        ],
        &[
            ("HX_ESCAPE_ROOT", root),
            ("HX_ESCAPE_COUNT", &count_text),
            ("HX_ESCAPE_HOLD", mode),
        ],
    );
    let mut control = Some(control);
    startup(&mut ack, control.as_mut().expect("live caller"));
    let direct = published_pid(&directory.path().join("sender.pid"));
    let mut guards = EscapedChildren(Vec::new());
    for index in 0..count {
        let pid = published_pid(&directory.path().join(format!("escaped-{index}.pid")));
        guards.0.push(pid);
        let stat =
            std::fs::read_to_string(format!("/proc/{pid}/stat")).expect("escaped process witness");
        let fields: Vec<&str> = stat
            .rsplit_once(") ")
            .expect("process name")
            .1
            .split_whitespace()
            .collect();
        assert_ne!(pid, direct);
        assert_eq!(
            fields[2].parse::<i32>().expect("process group"),
            pid.as_raw_nonzero().get()
        );
        assert_eq!(
            fields[3].parse::<i32>().expect("session"),
            pid.as_raw_nonzero().get()
        );
        assert!(
            !export_process_retired(pid),
            "actual escaped liveness required"
        );
    }
    match trigger {
        ExportFailure::CallerEof => drop(control.take()),
        ExportFailure::Cancel => control
            .as_mut()
            .expect("caller")
            .write_all(b"X\n")
            .expect("cancel"),
        ExportFailure::Malformed => control
            .as_mut()
            .expect("caller")
            .write_all(b"L0\n")
            .expect("invalid renewal"),
        ExportFailure::Deadline => {}
        ExportFailure::SenderFailure | ExportFailure::Diagnostics => {
            std::fs::write(directory.path().join("release-sender"), "release")
                .expect("release sender fixture");
        }
        ExportFailure::Signal => {
            let pid = i32::try_from(helper.0.id())
                .ok()
                .and_then(rustix::process::Pid::from_raw)
                .expect("helper PID");
            rustix::process::kill_process(pid, rustix::process::Signal::TERM)
                .expect("helper cancellation signal");
        }
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while !export_process_retired(direct) {
        assert!(
            Instant::now() < deadline,
            "direct sender must retire: {trigger:?}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(
        guards.0.iter().all(|pid| !export_process_retired(*pid)),
        "escaped descendants must remain independently live"
    );
    assert!(
        helper.0.try_wait().expect("helper outcome").is_none(),
        "failure cannot release adopted custody: {trigger:?}/{count}"
    );
    let successor = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&lock)
        .expect("independent successor lock");
    assert_eq!(
        flock(&successor, FlockOperation::NonBlockingLockExclusive),
        Err(rustix::io::Errno::WOULDBLOCK)
    );
    for pid in &guards.0 {
        rustix::process::kill_process(*pid, rustix::process::Signal::KILL)
            .expect("explicit child death");
    }
    let expected = match trigger {
        ExportFailure::Deadline => 2,
        ExportFailure::SenderFailure => 1,
        ExportFailure::Diagnostics => 3,
        _ => 4,
    };
    assert_eq!(
        helper.wait_bounded(Duration::from_secs(5)).code(),
        Some(expected),
        "exact failure outcome: {trigger:?}"
    );
    for pid in &guards.0 {
        assert!(
            !Path::new(&format!("/proc/{pid}")).exists(),
            "adopted PID must be reaped"
        );
    }
    guards.0.clear();
    flock(&successor, FlockOperation::NonBlockingLockExclusive)
        .expect("successor admission after actual reaping");
}

struct Running(Child);

impl Running {
    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture helper: a failed poll must abort the test"
    )]
    #[expect(
        clippy::panic,
        reason = "integration-test fixture helper: an overdue helper fails the test"
    )]
    fn wait_bounded(&mut self, timeout: Duration) -> std::process::ExitStatus {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = self.0.try_wait().expect("polled helper") {
                return status;
            }
            if Instant::now() > deadline {
                let _ = self.0.kill();
                panic!("helper did not exit in time");
            }
            std::thread::sleep(Duration::from_millis(15));
        }
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn harness() -> String {
    std::env::current_exe()
        .expect("harness path")
        .to_string_lossy()
        .into_owned()
}

/// Spawn the helper with the port ABI: control input on fd 3, ack on fd 4.
/// Descriptor placement is the entire unsafe surface: two dup2 calls whose
/// only externally visible effect is the documented ABI line-up.
#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn spawn(
    lock: &Path,
    lease: &str,
    sender: &str,
    extra: &[&str],
    envs: &[(&str, &str)],
) -> (Running, std::fs::File, std::fs::File) {
    let (control_read, control_write) =
        rustix::pipe::pipe_with(rustix::pipe::PipeFlags::CLOEXEC).expect("control pipe");
    let (ack_read, ack_write) =
        rustix::pipe::pipe_with(rustix::pipe::PipeFlags::CLOEXEC).expect("ack pipe");
    let mut command = Process::new(HELPER);
    command
        .arg(lock)
        .arg(lease)
        .arg(sender)
        .args(extra)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .envs(envs.iter().map(|(key, value)| (*key, *value)));
    let hoists = abi_shim::map_control_channels(&mut command, &control_read, &ack_write);
    let child = Running(command.spawn().expect("spawned export helper"));
    drop(hoists);
    (
        child,
        std::fs::File::from(control_write),
        std::fs::File::from(ack_read),
    )
}

#[allow(
    unsafe_code,
    reason = "test-only placement of the port-ABI descriptors 3 and 4 in the child"
)]
mod abi_shim {
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt as _;
    use std::process::Command;

    /// The Erlang port ABI places control at fd 3 and ack at fd 4 in the
    /// spawned child. Confinement: hoist our pipes to spare descriptors, then
    /// dup2 them onto the fixed numbers in the documented pre-exec window.
    /// The hoisted parent-side duplicates. Releasing them AFTER spawn closes
    /// the pipe's extra writer; earlier closure would leak fd numbers into
    /// std's spawn internals.
    pub(super) struct Hoists(i32, i32);

    impl Drop for Hoists {
        fn drop(&mut self) {
            // SAFETY: both numbers are CLOEXEC duplicates this Hoists owns
            // exclusively; nothing else closes or reuses them before drop.
            unsafe { libc::close(self.0) };
            // SAFETY: as above.
            unsafe { libc::close(self.1) };
        }
    }

    pub(super) fn map_control_channels<C: AsRawFd, A: AsRawFd>(
        command: &mut Command,
        control_read: &C,
        ack_write: &A,
    ) -> Hoists {
        // SAFETY: control_read is a live descriptor borrowed for the call;
        // F_DUPFD_CLOEXEC only duplicates it.
        let hoisted_cr = unsafe { libc::fcntl(control_read.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 8) };
        // SAFETY: as above, for ack_write.
        let hoisted_aw = unsafe { libc::fcntl(ack_write.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 8) };
        assert!(hoisted_cr >= 8 && hoisted_aw >= 8);
        let hook = move || {
            // SAFETY: dup2 on two descriptors this process owns is
            // async-signal-safe and touches no memory.
            if unsafe { libc::dup2(hoisted_cr, 3) } < 0 {
                return Err(std::io::Error::from_raw_os_error(libc::EFAULT));
            }
            // SAFETY: as above.
            if unsafe { libc::dup2(hoisted_aw, 4) } < 0 {
                return Err(std::io::Error::from_raw_os_error(libc::EFAULT));
            }
            Ok(())
        };
        // SAFETY: the hook runs in the forked child before exec and makes only
        // two async-signal-safe dup2 calls on captured integers.
        unsafe { command.pre_exec(hook) };
        Hoists(hoisted_cr, hoisted_aw)
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn new_lock(directory: &tempfile::TempDir) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt as _;
    let path = directory.path().join("owner.lock");
    drop(std::fs::File::create(&path).expect("fixture lock inode"));
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).expect("private");
    path
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn start_pair() -> (std::path::PathBuf, tempfile::TempDir) {
    let directory = tempfile::tempdir().expect("fixture directory");
    let lock = new_lock(&directory);
    (lock, directory)
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn startup(ack_read: &mut std::fs::File, control_write: &mut std::fs::File) {
    control_write
        .write_all(b"startup-nonce\n")
        .expect("offered startup");
    control_write.flush().expect("flushed");
    let mut echo = vec![0_u8; b"startup-nonce\n".len()];
    ack_read.read_exact(&mut echo).expect("startup ack echo");
    assert_eq!(echo, b"startup-nonce\n");
}

// -- Fixture senders (exec'd by the helper under the lease). --

#[test]
#[ignore = "export fixture"]
fn fixture_sender_succeeds() {
    use std::io::Write as _;
    std::io::stdout()
        .write_all(b"disk-bytes-out\n")
        .expect("wrote");
    std::io::stdout().flush().expect("flushed");
}

#[test]
#[ignore = "export fixture"]
fn fixture_sender_sleeps() {
    if let Ok(path) = std::env::var("HX_PIDFILE") {
        std::fs::write(path, format!("{}", std::process::id())).expect("pidfile");
    }
    std::thread::sleep(Duration::from_mins(1));
}

#[test]
#[ignore = "export fixture"]
fn fixture_sender_fails() {
    std::process::exit(23);
}

#[test]
#[ignore = "export fixture"]
fn fixture_sender_floods_diagnostics() {
    use std::io::Write as _;
    let mut err = std::io::stderr().lock();
    let chunk = [b'!'; 4096];
    for _ in 0..30 {
        err.write_all(&chunk).expect("flood chunk");
    }
    err.flush().expect("flushed");
}

// -- Behavioural coverage. --

#[test]
fn startup_acknowledges_and_successful_sender_passes_bytes() {
    let (lock, _dir) = start_pair();
    let (mut helper, mut control_write, mut ack_read) = spawn(
        &lock,
        "5000",
        &harness(),
        &[
            "--exact",
            "fixture_sender_succeeds",
            "--ignored",
            "--nocapture",
        ],
        &[],
    );
    startup(&mut ack_read, &mut control_write);
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(0));
    let mut out = Vec::new();
    helper
        .0
        .stdout
        .take()
        .expect("stdout")
        .read_to_end(&mut out)
        .expect("disk bytes");
    assert!(
        out.windows(15).any(|window| window == *b"disk-bytes-out\n"),
        "disk bytes crossed the inherited stdout: {out:?}"
    );
}

#[test]
fn failing_sender_reports_one() {
    let (lock, _dir) = start_pair();
    let (mut helper, mut control_write, mut ack_read) = spawn(
        &lock,
        "5000",
        &harness(),
        &[
            "--exact",
            "fixture_sender_fails",
            "--ignored",
            "--nocapture",
        ],
        &[],
    );
    startup(&mut ack_read, &mut control_write);
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(1));
}

#[test]
fn renewal_extends_the_lease_before_revocation_cancels() {
    let (lock, _dir) = start_pair();
    let (mut helper, mut control_write, mut ack_read) = spawn(
        &lock,
        "1000",
        &harness(),
        &[
            "--exact",
            "fixture_sender_sleeps",
            "--ignored",
            "--nocapture",
        ],
        &[],
    );
    startup(&mut ack_read, &mut control_write);
    std::thread::sleep(Duration::from_millis(700));
    control_write.write_all(b"L2000\n").expect("renewal");
    std::thread::sleep(Duration::from_millis(600));
    assert!(
        helper.0.try_wait().expect("polled").is_none(),
        "renewal did not extend the lease"
    );
    control_write.write_all(b"X\n").expect("revoke");
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(4));
}

#[test]
fn deadline_expiry_kills_and_reaps_the_sender() {
    let (lock, dir) = start_pair();
    let pidfile = dir.path().join("sender.pid");
    let pidfile_string = pidfile.to_string_lossy().into_owned();
    let (mut helper, mut control_write, mut ack_read) = spawn(
        &lock,
        "1000",
        &harness(),
        &[
            "--exact",
            "fixture_sender_sleeps",
            "--ignored",
            "--nocapture",
        ],
        &[("HX_PIDFILE", pidfile_string.as_str())],
    );
    startup(&mut ack_read, &mut control_write);
    let pid: i32 = {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(contents) = std::fs::read_to_string(&pidfile) {
                break contents.trim().parse().expect("numeric pid");
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(2));
    let proc = format!("/proc/{pid}");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Path::new(&proc).exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!Path::new(&proc).exists(), "sender survived the deadline");
}

#[test]
fn unrenewed_startup_revokes_at_the_lease_deadline() {
    let (lock, _dir) = start_pair();
    let (mut helper, _control_write, _ack_read) = spawn(
        &lock,
        "300",
        &harness(),
        &[
            "--exact",
            "fixture_sender_succeeds",
            "--ignored",
            "--nocapture",
        ],
        &[],
    );
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(4));
}

#[test]
fn excessive_diagnostics_close_the_sender() {
    let (lock, _dir) = start_pair();
    let (mut helper, mut control_write, mut ack_read) = spawn(
        &lock,
        "30000",
        &harness(),
        &[
            "--exact",
            "fixture_sender_floods_diagnostics",
            "--ignored",
            "--nocapture",
        ],
        &[],
    );
    startup(&mut ack_read, &mut control_write);
    assert_eq!(helper.wait_bounded(Duration::from_secs(30)).code(), Some(3));
}

#[test]
fn relative_lock_and_zero_lease_exit_sixty_four() {
    let (lock, _dir) = start_pair();
    for (lock_arg, lease) in [("relative.lock", "1000"), ("/lock", "0"), ("/lock", "0300")] {
        let lock_path = if lock_arg == "relative.lock" {
            Path::new("relative.lock").to_path_buf()
        } else {
            lock.clone()
        };
        let (mut helper, _cw, _ar) = spawn(
            &lock_path,
            lease,
            &harness(),
            &["--exact", "fixture_sender_succeeds"],
            &[],
        );
        assert_eq!(
            helper.wait_bounded(Duration::from_secs(15)).code(),
            Some(64)
        );
    }
}

#[test]
fn contended_lock_exits_seventy_three_without_acknowledgement() {
    use rustix::fs::{flock, FlockOperation};
    let (lock, _dir) = start_pair();
    let anchor = std::fs::File::options()
        .read(true)
        .write(true)
        .open(&lock)
        .expect("anchor");
    flock(&anchor, FlockOperation::NonBlockingLockExclusive).expect("anchor lock");
    let (mut helper, mut control_write, mut ack_read) = spawn(
        &lock,
        "5000",
        &harness(),
        &["--exact", "fixture_sender_succeeds"],
        &[],
    );
    control_write
        .write_all(b"startup-nonce\n")
        .expect("offered startup");
    control_write.flush().expect("flush");
    assert_eq!(
        helper.wait_bounded(Duration::from_secs(15)).code(),
        Some(73)
    );
    let mut echo = Vec::new();
    ack_read.read_to_end(&mut echo).expect("empty ack");
    assert!(echo.is_empty(), "contended helper acknowledged");
}
