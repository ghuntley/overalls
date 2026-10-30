//! Real subprocess bounds and malformed advertised-ref refusal.
use lyra::workspace_checkout::{self, Checkout};
use lyra::workspace_receiver::{GitRunner, SystemGit};
use lyra::workspace_source::{self, WorkspaceSource};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const CHILD_SLEEP: Duration = Duration::from_secs(3);
const OUTPUT_LIMIT: usize = 1_048_576;

fn helper_invocation(name: &str) -> bool {
    std::env::args().any(|argument| argument == name)
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn invoked_program() -> PathBuf {
    PathBuf::from(std::env::args_os().next().expect("invoked executable"))
}

fn ready_path() -> PathBuf {
    invoked_program().with_extension("ready")
}

#[test]
fn workspace_git_configuration_environment_helper() {
    if !helper_invocation("workspace_git_configuration_environment_helper") {
        return;
    }
    let home = std::env::var_os("HOME").expect("test home environment");
    let path = PathBuf::from(home).join(".captured-git-config");
    let system = std::env::var_os("GIT_CONFIG_SYSTEM").unwrap_or_default();
    let no_system = std::env::var_os("GIT_CONFIG_NOSYSTEM").unwrap_or_default();
    fs::write(
        path,
        [
            system.as_encoded_bytes(),
            b"\n",
            no_system.as_encoded_bytes(),
        ]
        .concat(),
    )
    .expect("record git configuration environment");
}

// These helpers are ordinary no-op tests unless explicitly launched as the
// fake git executable. Its descendant inherits the captured stdout pipe.
#[test]
fn workspace_git_sleeping_pipe_helper() {
    if !helper_invocation("workspace_git_sleeping_pipe_helper") {
        return;
    }
    fs::write(ready_path(), std::process::id().to_string()).expect("child readiness");
    thread::sleep(CHILD_SLEEP);
}

#[expect(
    clippy::zombie_processes,
    reason = "the fixture parent must exit before its stdout-holding child; the regression verifies group cancellation"
)]
#[expect(
    clippy::expect_used,
    clippy::panic,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn spawn_pipe_holder() {
    let mut child = Command::new(invoked_program())
        .args([
            "--exact",
            "workspace_git_sleeping_pipe_helper",
            "--nocapture",
        ])
        .stdout(Stdio::inherit())
        .stderr(Stdio::null())
        .spawn()
        .expect("stdout-holding descendant");
    let started = Instant::now();
    while !ready_path().exists() {
        if started.elapsed() > Duration::from_secs(1) {
            child.kill().expect("stop unready helper");
            child.wait().expect("reap unready helper");
            panic!("descendant did not start");
        }
        thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn workspace_git_inherited_pipe_helper() {
    if helper_invocation("workspace_git_inherited_pipe_helper") {
        spawn_pipe_holder();
        // The top-level process exits while its descendant keeps stdout open.
    }
}

#[test]
fn workspace_git_oversized_pipe_helper() {
    if helper_invocation("workspace_git_oversized_pipe_helper") {
        spawn_pipe_holder();
        io::stdout()
            .write_all(&vec![b'x'; OUTPUT_LIMIT + 1])
            .expect("oversized fixture output");
        thread::sleep(CHILD_SLEEP);
    }
}

#[expect(
    clippy::expect_used,
    clippy::panic,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn process_alive(pid: u32) -> bool {
    match fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => {
            let (_, fields) = stat.rsplit_once(") ").expect("Linux process stat");
            // A killed orphan can briefly remain a zombie until init reaps it.
            !fields.starts_with('Z')
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => panic!("cannot inspect helper process: {error}"),
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn bounded_output(helper: &str, timeout: Duration) {
    let root = tempfile::tempdir().expect("fixture root");
    let program = root.path().join("fake-git");
    symlink(std::env::current_exe().expect("test executable"), &program).expect("fake executable");
    let ready = program.with_extension("ready");
    let mut git = SystemGit {
        program,
        ca_bundle: root.path().join("unused-ca"),
        home: root.path().to_path_buf(),
        system_configuration: None,
    };
    let started = Instant::now();
    let outcome = git.output_with_timeout(
        &["--exact".into(), helper.into(), "--nocapture".into()],
        timeout,
    );
    let elapsed = started.elapsed();
    let pid: u32 = fs::read_to_string(ready)
        .expect("descendant entered before cancellation")
        .parse()
        .expect("positive helper PID");
    assert!(pid > 0);
    assert!(outcome.is_err(), "bounded output must be refused");
    assert!(elapsed < Duration::from_secs(1), "elapsed: {elapsed:?}");
    let cleanup = Instant::now();
    while process_alive(pid) && cleanup.elapsed() < Duration::from_millis(250) {
        thread::sleep(Duration::from_millis(1));
    }
    assert!(
        !process_alive(pid),
        "output cutoff left its descendant alive"
    );
}

/// @cc [owner:ghuntley,label:verification;recovery] workspace-git-deadline-cleans-pipe-holders
/// The output deadline MUST return even when git exits before an inherited-stdout
/// descendant, and cancellation MUST terminate that descendant rather than leave
/// the reader join blocked until its natural exit.
#[test]
fn deadline_kills_descendant_holding_stdout_after_parent_exits() {
    bounded_output(
        "workspace_git_inherited_pipe_helper",
        Duration::from_millis(200),
    );
}

/// @cc [owner:ghuntley,label:verification;recovery] workspace-git-limit-cleans-process-tree
/// Output over one MiB MUST be refused promptly and terminate both the active git
/// executable and descendants, without waiting for the ordinary deadline.
#[test]
fn output_limit_kills_active_parent_and_descendant() {
    bounded_output(
        "workspace_git_oversized_pipe_helper",
        Duration::from_secs(2),
    );
}

/// @cc [owner:ghuntley,label:verification;security] workspace-git-system-config
/// Native `SystemGit` MUST select only the daemon-owned system configuration and
/// MUST leave ordinary guest Git isolated from system configuration.
#[test]
fn native_system_config_is_selected_without_widening_defaults() {
    let root = tempfile::tempdir().expect("fixture root");
    let program = root.path().join("fake-git");
    symlink(std::env::current_exe().expect("test executable"), &program).expect("fake executable");
    let selected = root.path().join("native-gitconfig");
    let mut native = SystemGit {
        program: program.clone(),
        ca_bundle: root.path().join("unused-ca"),
        home: root.path().to_path_buf(),
        system_configuration: Some(selected.clone()),
    };
    native
        .output_with_timeout(
            &[
                "--exact".into(),
                "workspace_git_configuration_environment_helper".into(),
                "--nocapture".into(),
            ],
            Duration::from_secs(2),
        )
        .expect("native helper succeeds");
    let captured = fs::read_to_string(root.path().join(".captured-git-config"))
        .expect("native configuration capture");
    assert_eq!(captured, format!("{}\n", selected.display()));

    let mut ordinary = SystemGit {
        program,
        ca_bundle: root.path().join("unused-ca"),
        home: root.path().to_path_buf(),
        system_configuration: None,
    };
    ordinary
        .output_with_timeout(
            &[
                "--exact".into(),
                "workspace_git_configuration_environment_helper".into(),
                "--nocapture".into(),
            ],
            Duration::from_secs(2),
        )
        .expect("ordinary helper succeeds");
    assert_eq!(
        fs::read_to_string(root.path().join(".captured-git-config"))
            .expect("ordinary configuration capture"),
        "\n1"
    );
}

struct Advertised(Vec<u8>);
impl GitRunner for Advertised {
    #[expect(
        clippy::panic,
        reason = "test double: an unexpected call must fail the test"
    )]
    fn run(&mut self, _: &[String]) -> io::Result<bool> {
        panic!("resolution must not invoke checkout commands")
    }
    fn output(&mut self, _: &[String]) -> io::Result<Vec<u8>> {
        Ok(self.0.clone())
    }
    #[expect(
        clippy::panic,
        reason = "test double: an unexpected call must fail the test"
    )]
    fn change_head(&mut self, _: &WorkspaceSource) -> io::Result<Checkout> {
        panic!("named resolution must not invoke a provider API")
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] workspace-hex-fallback-requires-valid-ref-list
/// A hexadecimal named link MAY fall back to an object only after a valid bounded
/// advertised-ref list has no match. Malformed or oversized lists MUST be refused;
/// an advertised hexadecimal branch MUST win over object fallback.
#[test]
fn hexadecimal_named_links_fail_closed_on_invalid_advertised_output() {
    let source = workspace_source::parse_url("https://bitbucket.org/o/r/src/abcdef1/file")
        .expect("named hexadecimal source");
    for output in [b"malformed\n".to_vec(), vec![b'x'; OUTPUT_LIMIT + 1]] {
        assert!(workspace_checkout::resolve(&source, &mut Advertised(output)).is_err());
    }
    let sha = "a".repeat(40);
    let refs = format!("{sha}\trefs/tags/abcdef1\n{sha}\trefs/heads/abcdef1\n");
    let checkout = workspace_checkout::resolve(&source, &mut Advertised(refs.into_bytes()))
        .expect("advertised hexadecimal branch");
    assert_eq!(
        checkout.revision,
        workspace_checkout::CheckoutRevision::Ref("refs/heads/abcdef1".into())
    );
    let checkout = workspace_checkout::resolve(&source, &mut Advertised(Vec::new()))
        .expect("valid empty list permits object fallback");
    assert_eq!(
        checkout.revision,
        workspace_checkout::CheckoutRevision::Commit("abcdef1".into())
    );
}
