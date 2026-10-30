#![cfg(target_os = "linux")]

use hegel::{generators as gs, TestCase};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;

const MANAGED: &str = "var/lib/overalls/bin/overalls";
const STATUS: &str = "var/lib/overalls/update/status.json";
const READY: &str = "run/overalls-agent/ready";

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// @cc [owner:ghuntley,label:verification;isolation] supervisor-fixture-private-root
/// The actual supervisor MUST execute inside a private user, mount, PID and
/// network namespace and chroot. Fixed guest paths MUST belong to its temporary
/// root. Killing and reaping namespace init MUST remove every fixture child.
/// Candidate ready files are synthetic registration receipts, not evidence of
/// Marshall authority, TLS, tool execution or Firecracker isolation.
struct Fixture {
    root: TempDir,
    supervisor: Option<Child>,
}

impl Fixture {
    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn new(installed: &[u8]) -> Self {
        let fixture = Self {
            root: tempfile::tempdir().expect("private root"),
            supervisor: None,
        };
        for path in [
            "etc/overalls",
            "var/lib/overalls/bin",
            "var/lib/overalls/update",
            "run/overalls-agent",
            "dev",
            "proc",
            "nix/store",
        ] {
            fs::create_dir_all(fixture.path(path)).expect("fixture directory");
        }
        fs::write(
            fixture.path("etc/overalls/guest-agent"),
            "isolated fixture\n",
        )
        .expect("guest marker");
        fs::write(fixture.path("dev/null"), "").expect("null mount target");
        fs::copy(env!("CARGO_BIN_EXE_overalls"), fixture.path("seed"))
            .expect("actual immutable supervisor");
        fixture.executable(MANAGED, installed);
        fixture.status(&json!({"installed": digest(installed), "applied": digest(installed)}));
        fixture
    }

    fn path(&self, path: &str) -> PathBuf {
        self.root.path().join(path)
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn executable(&self, path: &str, bytes: &[u8]) {
        fs::write(self.path(path), bytes).expect("fixture executable");
        fs::set_permissions(self.path(path), fs::Permissions::from_mode(0o700))
            .expect("executable mode");
    }

    #[expect(
        clippy::expect_used,
        clippy::unwrap_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn status(&self, value: &Value) {
        fs::write(self.path(STATUS), serde_json::to_vec(value).unwrap()).expect("fixture status");
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn read_status(&self) -> Value {
        serde_json::from_slice(&fs::read(self.path(STATUS)).expect("status bytes"))
            .expect("typed JSON value")
    }

    fn stage(&self, candidate: &[u8]) {
        self.executable("var/lib/overalls/bin/overalls.pending", candidate);
        let mut status = self.read_status();
        status["staged"] = json!(digest(candidate));
        self.status(&status);
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn interrupted_activation(&self, candidate: &[u8]) {
        fs::hard_link(
            self.path(MANAGED),
            self.path("var/lib/overalls/bin/overalls.previous"),
        )
        .expect("saved original inode");
        self.stage(candidate);
        fs::rename(
            self.path("var/lib/overalls/bin/overalls.pending"),
            self.path(MANAGED),
        )
        .expect("activation crash boundary");
        // A reboot can occur after rename but before the status commit. Startup
        // must derive the installed identity from the actual executable bytes.
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn start(&mut self) {
        assert!(self.supervisor.is_none());
        let script = r#"
set -eu
mount --make-rprivate /
mount --rbind /nix/store "$1/nix/store"
mount -o remount,bind,ro "$1/nix/store"
mount --bind /dev/null "$1/dev/null"
mount -t proc proc "$1/proc"
exec chroot "$1" /seed agent-supervisor
"#;
        self.supervisor = Some(
            Command::new("unshare")
                .args([
                    "--user",
                    "--map-root-user",
                    "--mount",
                    "--pid",
                    "--fork",
                    "--kill-child=KILL",
                    "--net",
                    "sh",
                    "-c",
                    script,
                    "fixture",
                ])
                .arg(self.root.path())
                .env("PATH", fixture_path())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .expect("isolated real supervisor"),
        );
    }

    #[expect(
        clippy::unwrap_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn wait_for(&mut self, seconds: u64, assertion: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(seconds);
        loop {
            assert!(
                self.supervisor
                    .as_mut()
                    .unwrap()
                    .try_wait()
                    .unwrap()
                    .is_none(),
                "supervisor exited before recovery"
            );
            if assertion(self) {
                return;
            }
            assert!(Instant::now() < deadline, "supervisor recovery deadline");
            thread::sleep(Duration::from_millis(30));
        }
    }

    #[expect(
        clippy::unwrap_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn registered(&mut self, bytes: &[u8], seconds: u64) {
        let expected = digest(bytes);
        self.wait_for(seconds, |fixture| {
            fs::read_to_string(fixture.path(READY)).is_ok_and(|ready| ready == expected)
        });
        assert_eq!(fs::read(self.path(MANAGED)).unwrap(), bytes);
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn stop(&mut self) {
        if let Some(mut child) = self.supervisor.take() {
            let descendants: Vec<ProcessIdentity> = descendants(child.id())
                .into_iter()
                .filter_map(ProcessIdentity::read)
                .collect();
            let _ = child.kill();
            child.wait().expect("namespace controller reaped");
            let deadline = Instant::now() + Duration::from_secs(5);
            while descendants.iter().any(ProcessIdentity::live) {
                assert!(
                    Instant::now() < deadline,
                    "fixture descendant survived namespace teardown"
                );
                thread::sleep(Duration::from_millis(10));
            }
        }
        fs::remove_dir_all(self.path("run/overalls-agent")).expect("discard volatile boot state");
        fs::create_dir(self.path("run/overalls-agent")).expect("fresh boot state");
    }

    #[expect(
        clippy::unwrap_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn executors(&self) -> Vec<ProcessIdentity> {
        descendants(self.supervisor.as_ref().unwrap().id())
            .into_iter()
            .filter(|pid| {
                fs::read(format!("/proc/{pid}/cmdline")).is_ok_and(|command| {
                    command
                        .split(|byte| *byte == 0)
                        .any(|arg| arg == b"agent-executor")
                })
            })
            .filter_map(ProcessIdentity::read)
            .collect()
    }
}

struct ProcessIdentity {
    pid: u32,
    started: String,
    state: String,
}

impl ProcessIdentity {
    fn read(pid: u32) -> Option<Self> {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let fields: Vec<&str> = stat.rsplit_once(") ")?.1.split_whitespace().collect();
        Some(Self {
            pid,
            started: fields.get(19)?.to_string(),
            state: fields.first()?.to_string(),
        })
    }

    fn live(&self) -> bool {
        Self::read(self.pid)
            .is_some_and(|current| current.started == self.started && current.state != "Z")
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn descendants(parent: u32) -> Vec<u32> {
    let mut found = Vec::new();
    let children =
        fs::read_to_string(format!("/proc/{parent}/task/{parent}/children")).unwrap_or_default();
    for child in children.split_whitespace() {
        let pid = child.parse().expect("kernel process ID");
        found.push(pid);
        found.extend(descendants(pid));
    }
    found
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop();
    }
}

#[expect(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn shell() -> PathBuf {
    let output = Command::new("sh")
        .args(["-c", "command -v sh"])
        .output()
        .expect("Nix shell path");
    assert!(output.status.success());
    let path = fs::canonicalize(String::from_utf8(output.stdout).unwrap().trim())
        .expect("shell store path");
    assert!(path.starts_with("/nix/store"));
    path
}

#[expect(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn fixture_path() -> std::ffi::OsString {
    let mut directories = Vec::new();
    for name in [
        "sh",
        "mount",
        "chroot",
        "unshare",
        "sha256sum",
        "cut",
        "tr",
        "touch",
        "sleep",
    ] {
        let output = Command::new("sh")
            .args(["-c", "command -v \"$1\"", "fixture", name])
            .output()
            .expect("fixture tool lookup");
        assert!(output.status.success());
        let tool = fs::canonicalize(String::from_utf8(output.stdout).unwrap().trim())
            .expect("fixture tool store path");
        assert!(tool.starts_with("/nix/store"));
        directories.push(tool.parent().unwrap().to_owned());
    }
    std::env::join_paths(directories).expect("fixture tool path")
}

fn executor(label: u64, drain: bool) -> Vec<u8> {
    format!(
        "#!{}\n# fixture revision {label}\n\
         test \"$1\" = __update-worker && exit 0\n\
         test \"$1\" = agent-executor || exit 2\n\
         sha256sum \"$0\" | cut -d' ' -f1 | tr -d '\\n' >/run/overalls-agent/ready\n\
         touch /run/overalls-agent/active\n\
         while ! test -f /run/overalls-agent/stop; do sleep .02; done\n\
         if {}; then\n\
           touch /run/overalls-agent/draining\n\
           while ! test -f /run/overalls-agent/release; do sleep .02; done\n\
           touch /run/overalls-agent/finished\n\
         fi\n",
        shell().display(),
        if drain { "true" } else { "false" }
    )
    .into_bytes()
}

#[derive(Clone, Copy, Debug)]
enum Failure {
    Format,
    Interpreter,
    EarlyExit,
}

fn candidate(failure: Failure, revision: u64) -> Vec<u8> {
    match failure {
        Failure::Format => format!("\u{7f}ELF-not-executable-{revision}").into_bytes(),
        Failure::Interpreter => format!("#!/missing-fixture-interpreter-{revision}\n").into_bytes(),
        Failure::EarlyExit => {
            format!("#!{}\n# {revision}\nexit 17\n", shell().display()).into_bytes()
        }
    }
}

#[expect(
    clippy::unwrap_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn rejected_history(failure: Failure, revision: u64, reboot: bool) {
    let old = executor(revision, false);
    let bad = candidate(failure, revision);
    let mut fixture = Fixture::new(&old);
    let old_inode = fs::metadata(fixture.path(MANAGED)).unwrap().ino();
    if reboot {
        fixture.interrupted_activation(&bad);
    } else {
        fixture.stage(&bad);
    }
    fixture.start();
    fixture.wait_for(12, |fixture| {
        fixture.read_status()["rejected"] == digest(&bad)
    });
    fixture.registered(&old, 5);
    let status = fixture.read_status();
    assert_eq!(status["applied"], digest(&old));
    assert_eq!(status["installed"], digest(&old));
    assert_eq!(status["last_check"], "rolled_back");
    assert!(status["rejected_until_ms"].as_u64().is_some());
    assert_eq!(
        fs::metadata(fixture.path(MANAGED)).unwrap().ino(),
        old_inode
    );
    assert!(!fixture
        .path("var/lib/overalls/bin/overalls.previous")
        .exists());
    assert!(!fixture
        .path("var/lib/overalls/bin/overalls.pending")
        .exists());

    // Reboot preserves the recovered executable; a different verified candidate
    // may then activate. No test helper performs production rollback.
    fixture.stop();
    let new = executor(revision.wrapping_add(1), false);
    fixture.stage(&new);
    fixture.start();
    fixture.wait_for(12, |fixture| {
        fixture.read_status()["applied"] == digest(&new)
    });
    fixture.registered(&new, 5);
    assert_eq!(
        fs::read(fixture.path("var/lib/overalls/bin/overalls.previous")).unwrap(),
        old
    );
}

#[hegel::test(test_cases = 8)]
fn generated_failed_candidates_restore_and_allow_fresh_retry(tc: TestCase) {
    let revision = tc.draw(gs::integers::<u64>());
    let failure = tc.draw(gs::sampled_from(&[
        Failure::Format,
        Failure::Interpreter,
        Failure::EarlyExit,
    ]));
    let reboot = tc.draw(gs::booleans());
    rejected_history(failure, revision, reboot);
}

#[test]
fn every_spawn_failure_boundary_restores_the_original_inode() {
    for failure in [Failure::Format, Failure::Interpreter, Failure::EarlyExit] {
        for reboot in [false, true] {
            rejected_history(failure, 28, reboot);
        }
    }
}

#[hegel::test(test_cases = 4)]
fn replacement_waits_for_active_work_before_switching_inode(tc: TestCase) {
    let revision = tc.draw(gs::integers::<u64>());
    let old = executor(revision, true);
    let new = executor(revision.wrapping_add(1), false);
    let mut fixture = Fixture::new(&old);
    fixture.stage(&new);
    fixture.start();
    fixture.wait_for(5, |fixture| {
        fixture.path("run/overalls-agent/draining").exists()
    });
    assert_eq!(fs::read(fixture.path(MANAGED)).unwrap(), old);
    assert!(!fixture
        .path("var/lib/overalls/bin/overalls.previous")
        .exists());
    fs::write(fixture.path("run/overalls-agent/release"), "").unwrap();
    fixture.wait_for(5, |fixture| {
        fixture.read_status()["applied"] == digest(&new)
    });
    fixture.registered(&new, 5);
    assert!(fixture.path("run/overalls-agent/finished").exists());
}

#[test]
fn running_candidate_without_registration_is_killed_after_deadline() {
    let old = executor(28, false);
    let bad = format!("#!{}\nwhile true; do sleep .1; done\n", shell().display()).into_bytes();
    let mut fixture = Fixture::new(&old);
    fixture.interrupted_activation(&bad);
    let started = Instant::now();
    fixture.start();
    fixture.wait_for(5, |fixture| !fixture.executors().is_empty());
    let candidate_processes = fixture.executors();
    assert_eq!(candidate_processes.len(), 1);
    fixture.wait_for(100, |fixture| {
        fixture.read_status()["rejected"] == digest(&bad)
    });
    assert!(started.elapsed() >= Duration::from_secs(90));
    fixture.registered(&old, 5);
    assert!(candidate_processes.iter().all(|process| !process.live()));
}

#[test]
fn registered_candidate_restarts_without_restoring_saved_previous() {
    let old = executor(28, false);
    let new = executor(29, false);
    let mut fixture = Fixture::new(&old);
    fixture.interrupted_activation(&new);
    fixture.start();
    fixture.wait_for(5, |fixture| {
        fixture.read_status()["applied"] == digest(&new)
    });
    fixture.stop();
    fixture.start();
    fixture.registered(&new, 5);
    assert!(fixture.read_status()["rejected"].is_null());
    assert_eq!(
        fs::read(fixture.path("var/lib/overalls/bin/overalls.previous")).unwrap(),
        old
    );
}
