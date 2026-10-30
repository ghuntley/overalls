#![forbid(unsafe_code)]

use lilly_launch_guard::{INTENT_BYTES, RUNNING_STATE};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

const GUARD: &str = env!("CARGO_BIN_EXE_lilly-launch-guard");

struct Fixture {
    directory: tempfile::TempDir,
    lock: PathBuf,
    intent: PathBuf,
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn fixture() -> Fixture {
    let directory = tempfile::tempdir().expect("fixture directory");
    let lock = directory.path().join("owner.lock");
    std::fs::File::create(&lock).expect("lock inode");
    let intent = directory.path().join("intent.bin");
    std::fs::write(&intent, vec![0_u8; INTENT_BYTES]).expect("intent inode");
    for path in [&lock, &intent] {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).expect("private");
    }
    Fixture {
        directory,
        lock,
        intent,
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn write_intent(fixture: &Fixture, placement: &str, epoch: u64, generation: u64, state: u8) {
    let mut bytes = Vec::with_capacity(INTENT_BYTES);
    bytes.extend_from_slice(placement.as_bytes());
    bytes.extend_from_slice(&epoch.to_be_bytes());
    bytes.extend_from_slice(&generation.to_be_bytes());
    bytes.push(state);
    assert_eq!(bytes.len(), INTENT_BYTES);
    std::fs::write(&fixture.intent, bytes).expect("intent payload");
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn spawn_guard(
    fixture: &Fixture,
    placement: &str,
    epoch: &str,
    generation: &str,
    exec: &str,
    extra: &[&str],
) -> std::process::Child {
    Process::new(GUARD)
        .arg(&fixture.lock)
        .arg(&fixture.intent)
        .arg(placement)
        .args([epoch, generation, exec])
        .args(extra)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawned guard")
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn wait_code(child: &mut std::process::Child) -> Option<i32> {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.try_wait().expect("polled guard") {
            return status.code();
        }
        assert!(Instant::now() < deadline, "guard did not exit");
        std::thread::sleep(Duration::from_millis(10));
    }
}

const UUID: &str = "01234567-89ab-4a4b-8c4d-ef0123456789";

#[test]
fn valid_generation_execs_and_the_exec_target_owns_the_process() {
    let fixture = fixture();
    write_intent(&fixture, UUID, 7, 9, RUNNING_STATE);
    // The exec target is the guard's own binary with invalid arguments: exit 64
    // proves the image was replaced (guard custody codes are 71/74/75).
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    assert_eq!(wait_code(&mut child), Some(64));
}

#[test]
fn missing_exec_target_reports_seventy_one() {
    let fixture = fixture();
    write_intent(&fixture, UUID, 7, 9, RUNNING_STATE);
    let mut child = spawn_guard(&fixture, UUID, "7", "9", "/definitely/missing/jailer", &[]);
    assert_eq!(wait_code(&mut child), Some(71));
}

#[test]
fn stale_or_foreign_intent_is_seventy_five() {
    let fixture = fixture();
    for (placement, epoch, generation, state) in [
        ("11234567-89ab-4a4b-8c4d-ef0123456789", 7, 9, RUNNING_STATE),
        (UUID, 8, 9, RUNNING_STATE),
        (UUID, 7, 10, RUNNING_STATE),
        (UUID, 7, 9, 0_u8),
        (UUID, 7, 9, 2_u8),
    ] {
        write_intent(&fixture, placement, epoch, generation, state);
        let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
        assert_eq!(
            wait_code(&mut child),
            Some(75),
            "placement={placement} epoch={epoch} generation={generation} state={state}"
        );
    }
}

#[test]
fn unsafe_or_missing_intent_files_are_seventy_four() {
    let fixture = fixture();
    write_intent(&fixture, UUID, 7, 9, RUNNING_STATE);

    // Wrong sizes cannot be a valid intent at all.
    std::fs::write(&fixture.intent, vec![0_u8; INTENT_BYTES - 1]).expect("short intent");
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    assert_eq!(wait_code(&mut child), Some(74));

    // Hardlinked intent is insecure.
    write_intent(&fixture, UUID, 7, 9, RUNNING_STATE);
    let alias = fixture.directory.path().join("intent-alias.bin");
    std::fs::hard_link(&fixture.intent, &alias).expect("fixture hardlink");
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    assert_eq!(wait_code(&mut child), Some(74));
    std::fs::remove_file(&alias).expect("cleaned alias");

    // Group/world readable intent is insecure.
    std::fs::set_permissions(&fixture.intent, std::fs::Permissions::from_mode(0o604))
        .expect("widened");
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    assert_eq!(wait_code(&mut child), Some(74));
    std::fs::set_permissions(&fixture.intent, std::fs::Permissions::from_mode(0o600))
        .expect("restored");

    // Symlinked intent is insecure.
    std::fs::remove_file(&fixture.intent).expect("removed intent");
    std::os::unix::fs::symlink(&alias, &fixture.intent).expect("fixture symlink");
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    assert_eq!(wait_code(&mut child), Some(74));

    // Missing files.
    std::fs::remove_file(&fixture.lock).expect("removed lock");
    write_intent(&fixture, UUID, 7, 9, RUNNING_STATE);
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    assert_eq!(wait_code(&mut child), Some(74));
}

#[test]
fn exclusive_holder_defers_and_releases_cross_exec_lock() {
    use rustix::fs::{flock, FlockOperation};
    let fixture = fixture();
    write_intent(&fixture, UUID, 7, 9, RUNNING_STATE);
    // Hold the intent lock exclusively; the guard must block before exec.
    let anchor = std::fs::File::options()
        .read(true)
        .write(true)
        .open(&fixture.lock)
        .expect("anchor");
    flock(&anchor, FlockOperation::NonBlockingLockExclusive).expect("anchor lock");
    let mut child = spawn_guard(&fixture, UUID, "7", "9", GUARD, &[]);
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        child.try_wait().expect("polled guard").is_none(),
        "guard overtook an exclusive lock"
    );
    flock(&anchor, FlockOperation::Unlock).expect("anchor release");
    assert_eq!(wait_code(&mut child), Some(64));

    // Once the guard's shared acquisition rides across exec, a fresh exclusive
    // attempt must contend until the exec'd image exits. The exec target is
    // the harness's own ignorable sleeper fixture.
    let harness = std::env::current_exe()
        .expect("harness")
        .to_string_lossy()
        .into_owned();
    let mut child = Process::new(GUARD)
        .arg(&fixture.lock)
        .arg(&fixture.intent)
        .arg(UUID)
        .args(["7", "9", harness.as_str()])
        .args(["--exact", "fixture_child_sleep", "--ignored", "--nocapture"])
        .env("HL_GUARD_FIXTURE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawned guard");
    let contention = || {
        let attempt = std::fs::File::options()
            .read(true)
            .write(true)
            .open(&fixture.lock)
            .expect("contender");
        flock(&attempt, FlockOperation::NonBlockingLockExclusive)
    };
    // Wait until the exec'd image holds the shared lock.
    let deadline = Instant::now() + Duration::from_secs(10);
    while contention().is_ok() {
        assert!(Instant::now() < deadline, "shared lock never crossed exec");
        assert!(
            child.try_wait().expect("polled guard").is_none(),
            "guard exited before showing shared custody"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The fixture sleeps two seconds inside the exec'd image; the lock must
    // stay contended for the whole remaining window, not just at observation.
    std::thread::sleep(Duration::from_millis(150));
    assert!(
        contention().is_err(),
        "shared lock did not persist across exec"
    );
    assert!(
        child.try_wait().expect("polled guard").is_none(),
        "exec'd image exited during its sleep budget"
    );
    assert_eq!(wait_code(&mut child), Some(0));
    assert!(contention().is_ok(), "released lock was not reacquirable");
}

#[test]
#[ignore = "guard exec fixture"]
fn fixture_child_sleep() {
    std::thread::sleep(Duration::from_secs(2));
}

struct WaitingGuard(std::process::Child);

impl Drop for WaitingGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[derive(Clone, Copy, Debug)]
enum WaitingRevocation {
    Stopped,
    InvalidState,
    ForeignPlacement,
    NewEpoch,
    NewGeneration,
    ShortPayload,
    UnsafePermissions,
    HardlinkedPayload,
    Unchanged,
}

const WAITING_REVOCATIONS: [WaitingRevocation; 9] = [
    WaitingRevocation::Stopped,
    WaitingRevocation::InvalidState,
    WaitingRevocation::ForeignPlacement,
    WaitingRevocation::NewEpoch,
    WaitingRevocation::NewGeneration,
    WaitingRevocation::ShortPayload,
    WaitingRevocation::UnsafePermissions,
    WaitingRevocation::HardlinkedPayload,
    WaitingRevocation::Unchanged,
];

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn witnessed_shared_wait(child: &mut std::process::Child, lock: &std::path::Path) {
    use std::os::unix::fs::MetadataExt as _;
    let inode = std::fs::metadata(lock).expect("stable lock identity").ino();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        assert!(
            child.try_wait().expect("guard status").is_none(),
            "guard exited before acquiring shared custody"
        );
        let inventory = std::fs::read_to_string("/proc/locks").expect("kernel lock inventory");
        let waiting = inventory.lines().any(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let Some(arrow) = fields.iter().position(|field| *field == "->") else {
                return false;
            };
            match &fields[arrow + 1..] {
                ["FLOCK", "ADVISORY", "READ", pid, identity, ..] => {
                    pid.parse::<u32>().ok() == Some(child.id())
                        && identity
                            .rsplit(':')
                            .next()
                            .and_then(|value| value.parse::<u64>().ok())
                            == Some(inode)
                }
                _ => false,
            }
        });
        if waiting {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "exact guard PID must be a blocked shared flock waiter"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
#[ignore = "guard exec fixture"]
fn fixture_guard_exec_marker() {
    std::fs::write(
        std::env::var_os("LG_EXEC_MARKER").expect("private marker path"),
        b"exec",
    )
    .expect("exec witness");
}

/// @cc [owner:ghuntley,label:verification;recovery] launch-waiter-revalidates-intent
/// A guard independently witnessed waiting for shared custody MUST inspect the
/// post-lock intent. Stopped, foreign, superseded or unsafe payloads MUST refuse
/// exec without creating the target marker; unchanged current intent MUST exec.
/// This local locking property does not establish systemd or VM isolation.
#[hegel::test(test_cases = 2)]
fn waiting_guard_refuses_revoked_intent_after_exclusive_release(tc: hegel::TestCase) {
    let trigger = tc.draw(hegel::generators::sampled_from(&WAITING_REVOCATIONS));
    let epoch = tc.draw(hegel::generators::sampled_from(&[
        1_u64,
        7,
        i64::MAX as u64 - 1,
    ]));
    let generation = tc.draw(hegel::generators::sampled_from(&[
        1_u64,
        9,
        i64::MAX as u64 - 1,
    ]));
    let fixed = WAITING_REVOCATIONS
        .into_iter()
        .map(|trigger| (trigger, 7, 9));
    for (trigger, epoch, generation) in fixed.chain(std::iter::once((trigger, epoch, generation))) {
        waiting_intent_case(trigger, epoch, generation);
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a setup failure must abort the test"
)]
fn waiting_intent_case(trigger: WaitingRevocation, epoch: u64, generation: u64) {
    use rustix::fs::{flock, FlockOperation};
    let fixture = fixture();
    write_intent(&fixture, UUID, epoch, generation, RUNNING_STATE);
    let anchor = std::fs::File::options()
        .read(true)
        .write(true)
        .open(&fixture.lock)
        .expect("exclusive coordinator anchor");
    flock(&anchor, FlockOperation::NonBlockingLockExclusive).expect("coordinator lock");
    let marker = fixture.directory.path().join("exec.marker");
    let mut guard = WaitingGuard(
        Process::new(GUARD)
            .arg(&fixture.lock)
            .arg(&fixture.intent)
            .arg(UUID)
            .arg(epoch.to_string())
            .arg(generation.to_string())
            .arg(std::env::current_exe().expect("trusted test executable"))
            .args([
                "--exact",
                "fixture_guard_exec_marker",
                "--ignored",
                "--nocapture",
            ])
            .env("LG_EXEC_MARKER", &marker)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("waiting guard"),
    );
    witnessed_shared_wait(&mut guard.0, &fixture.lock);
    assert!(!marker.exists(), "exec cannot precede shared custody");
    let expected = match trigger {
        WaitingRevocation::Stopped => {
            write_intent(&fixture, UUID, epoch, generation, 0);
            75
        }
        WaitingRevocation::InvalidState => {
            write_intent(&fixture, UUID, epoch, generation, 255);
            75
        }
        WaitingRevocation::ForeignPlacement => {
            write_intent(
                &fixture,
                "11234567-89ab-4a4b-8c4d-ef0123456789",
                epoch,
                generation,
                RUNNING_STATE,
            );
            75
        }
        WaitingRevocation::NewEpoch => {
            write_intent(&fixture, UUID, epoch + 1, generation, RUNNING_STATE);
            75
        }
        WaitingRevocation::NewGeneration => {
            write_intent(&fixture, UUID, epoch, generation + 1, RUNNING_STATE);
            75
        }
        WaitingRevocation::ShortPayload => {
            std::fs::OpenOptions::new()
                .write(true)
                .open(&fixture.intent)
                .expect("intent file")
                .set_len(52)
                .expect("short payload");
            74
        }
        WaitingRevocation::UnsafePermissions => {
            std::fs::set_permissions(&fixture.intent, std::fs::Permissions::from_mode(0o640))
                .expect("unsafe private fixture");
            74
        }
        WaitingRevocation::HardlinkedPayload => {
            std::fs::hard_link(
                &fixture.intent,
                fixture.directory.path().join("intent.alias"),
            )
            .expect("fixture hardlink");
            74
        }
        WaitingRevocation::Unchanged => {
            write_intent(&fixture, UUID, epoch, generation, RUNNING_STATE);
            0
        }
    };
    flock(&anchor, FlockOperation::Unlock).expect("exclusive coordinator release");
    assert_eq!(
        wait_code(&mut guard.0),
        Some(expected),
        "exact post-lock result: {trigger:?}"
    );
    assert_eq!(
        marker.exists(),
        matches!(trigger, WaitingRevocation::Unchanged),
        "exact exec witness: {trigger:?}"
    );
    flock(&anchor, FlockOperation::NonBlockingLockExclusive)
        .expect("shared custody retired before next coordinator");
}
