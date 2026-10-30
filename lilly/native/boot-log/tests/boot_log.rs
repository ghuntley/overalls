#![forbid(unsafe_code)]

use lilly_boot_log::BOOT_LOG_LIMIT;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command as Process, Stdio};
use std::time::{Duration, Instant};

const HELPER: &str = env!("CARGO_BIN_EXE_lilly-boot-log");

struct Running(Child);

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn run_helper(
    log: &Path,
    argv: &[String],
    envs: &[(&str, String)],
) -> (Option<i32>, Option<i32>, Vec<u8>, Vec<u8>, Duration) {
    let started = Instant::now();
    let child = Process::new(HELPER)
        .arg(log)
        .args(argv)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .envs(envs.iter().map(|(k, v)| (*k, v.as_str())))
        .spawn()
        .expect("spawned boot-log");
    let mut locked = Running(child);
    let mut out = Vec::new();
    let mut err = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = locked.0.try_wait().expect("polled helper") {
            break status;
        }
        assert!(Instant::now() < deadline, "helper did not finish");
        std::thread::sleep(Duration::from_millis(20));
    };
    locked
        .0
        .stdout
        .take()
        .expect("stdout")
        .read_to_end(&mut out)
        .expect("read");
    locked
        .0
        .stderr
        .take()
        .expect("stderr")
        .read_to_end(&mut err)
        .expect("read");
    (status.code(), status.signal(), out, err, started.elapsed())
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn harness() -> String {
    std::env::current_exe()
        .expect("harness path")
        .to_string_lossy()
        .into_owned()
}

fn fixture_argv(fixture: &str) -> Vec<String> {
    vec![
        harness(),
        "--exact".to_string(),
        fixture.to_string(),
        "--ignored".to_string(),
        "--nocapture".to_string(),
    ]
}

fn new_log(directory: &tempfile::TempDir) -> PathBuf {
    directory.path().join("boot.raw.log")
}

// -- Fixture children; run only when the helper execs them by name. --

#[test]
#[ignore = "boot-log fixture"]
fn fixture_child_emit() {
    use std::io::Write as _;
    let bytes: usize = std::env::var("HL_LOG_BYTES")
        .expect("flood budget")
        .parse()
        .expect("numeric bytes");
    let code: i32 = std::env::var("HL_LOG_EXIT")
        .unwrap_or_else(|_| "0".to_string())
        .parse()
        .expect("numeric exit");
    let mut out = std::io::stdout().lock();
    let mut remaining = bytes;
    while remaining > 0 {
        let count = remaining.min(4096);
        out.write_all(&vec![b'o'; count]).expect("stdout chunk");
        remaining -= count;
    }
    out.flush().expect("flushed");
    let mut err = std::io::stderr().lock();
    err.write_all(b"stderr-marker\n").expect("stderr marker");
    err.flush().expect("flushed stderr");
    std::process::exit(code);
}

#[test]
#[ignore = "boot-log fixture"]
fn fixture_child_term() {
    rustix::process::kill_process(rustix::process::getpid(), rustix::process::Signal::TERM)
        .expect("self term");
}

// -- Selector and custody gates. --

#[test]
fn usage_variants_exit_sixty_four() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let too_short: Vec<String> = vec![];
    let relative_program = vec!["relative-command".to_string()];
    let relative_log = vec![harness()];
    for (log, argv) in [
        (new_log(&directory), too_short),
        (new_log(&directory), relative_program),
        (PathBuf::from("relative.log"), relative_log),
    ] {
        let (code, _, out, err, _) = run_helper(&log, &argv, &[]);
        assert_eq!(code, Some(64), "argv {argv:?}");
        assert!(out.is_empty() && err.is_empty());
    }
    // argc below the program name itself: helper invoked bare.
    let mut child = Running(
        Process::new(HELPER)
            .stdin(Stdio::null())
            .spawn()
            .expect("spawned bare helper"),
    );
    assert_eq!(wait(&mut child), Some(64));
}

#[test]
fn log_custody_refusals_are_seventy_four() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let log = new_log(&directory);
    let argv = fixture_argv("fixture_child_emit");

    // Pre-existing group-readable file is refused (and truncated by open first).
    std::fs::write(&log, b"legacy").expect("legacy");
    std::fs::set_permissions(&log, std::fs::Permissions::from_mode(0o604)).expect("wide");
    let (code, _, _, _, _) = run_helper(&log, &argv, &[]);
    assert_eq!(code, Some(74));

    // Symlinked log path.
    let alias = directory.path().join("real.log");
    std::fs::File::create(&alias).expect("real");
    std::fs::set_permissions(&alias, std::fs::Permissions::from_mode(0o600)).expect("private");
    let link = directory.path().join("link.log");
    std::os::unix::fs::symlink(&alias, &link).expect("symlink");
    let (code, _, _, _, _) = run_helper(&link, &argv, &[]);
    assert_eq!(code, Some(74));

    // Missing parent directory.
    let missing = directory.path().join("absent").join("boot.log");
    let (code, _, _, _, _) = run_helper(&missing, &argv, &[]);
    assert_eq!(code, Some(74));

    // Hardlinked output is insecure.
    std::fs::write(&log, b"x").expect("rewrite");
    std::fs::set_permissions(&log, std::fs::Permissions::from_mode(0o600)).expect("private");
    let other = directory.path().join("other.log");
    std::fs::hard_link(&log, &other).expect("linked");
    let (code, _, _, _, _) = run_helper(&log, &argv, &[]);
    assert_eq!(code, Some(74));
}

#[test]
fn missing_exec_target_is_seventy_one() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let log = new_log(&directory);
    let (code, _, _, _, _) = run_helper(&log, &["/definitely/missing".to_string()], &[]);
    assert_eq!(code, Some(71));
}

// -- Behavioural evidence. --

#[test]
#[expect(
    clippy::naive_bytecount,
    reason = "counting one byte in a small test log needs no bytecount dependency"
)]
fn child_exit_code_passes_through_and_streams_merge() {
    use std::os::unix::fs::MetadataExt as _;
    let directory = tempfile::tempdir().expect("fixture directory");
    let log = new_log(&directory);
    let argv = fixture_argv("fixture_child_emit");
    let (code, signal, out, err, _) = run_helper(
        &log,
        &argv,
        &[
            ("HL_LOG_BYTES", "2048".to_string()),
            ("HL_LOG_EXIT", "23".to_string()),
        ],
    );
    assert_eq!(code, Some(23));
    assert_eq!(signal, None);
    assert!(out.is_empty() && err.is_empty(), "helper must stay silent");
    // The exec'd harness contributes its own banner/result lines to the merged
    // stream; exact retention is unit-tested. Here: every emitted byte persists.
    let kept = std::fs::read(&log).expect("kept log");
    let o_bytes = kept.iter().filter(|byte| **byte == b'o').count();
    assert_eq!(o_bytes, 2048, "all stdout bytes retained");
    assert!(
        kept.windows(14).any(|window| window == *b"stderr-marker\n"),
        "stderr merged into the same log"
    );
    assert!(
        kept.windows(4).any(|window| window == *b"\n[+0"),
        "console lines carry host-monotonic offsets"
    );
    let metadata = std::fs::metadata(&log).expect("metadata");
    assert_eq!(metadata.mode() & 0o777, 0o600, "log must be owner-only");
}

#[test]
fn flood_retains_exactly_the_bounded_prefix_without_blocking() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let log = new_log(&directory);
    let argv = fixture_argv("fixture_child_emit");
    let total = BOOT_LOG_LIMIT * 3;
    let (code, signal, _, _, elapsed) = run_helper(
        &log,
        &argv,
        &[
            ("HL_LOG_BYTES", total.to_string()),
            ("HL_LOG_EXIT", "0".to_string()),
        ],
    );
    assert_eq!(code, Some(0));
    assert_eq!(signal, None);
    let kept = std::fs::read(&log).expect("kept log");
    // The flood fills the retained prefix before the trailing marker arrives,
    // so the marker itself is correctly discarded beyond the bound.
    assert_eq!(kept.len(), BOOT_LOG_LIMIT, "retention is exactly the bound");
    // The exec'd harness banner occupies only the first few bytes of the
    // retained prefix; everything after it is the flood.
    assert!(
        kept[..64].iter().filter(|byte| **byte != b'o').count() <= 64
            && kept[64..].iter().all(|byte| *byte == b'o'),
        "retained prefix is banner plus flood"
    );
    assert!(
        elapsed < Duration::from_secs(25),
        "flood dragged: {elapsed:?}"
    );
}

#[test]
fn child_signal_death_propagates_through_the_helper() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let log = new_log(&directory);
    let argv = fixture_argv("fixture_child_term");
    let (code, signal, out, err, _) = run_helper(&log, &argv, &[]);
    assert_eq!(code, None);
    assert_eq!(signal, Some(15), "helper must die by SIGTERM too");
    assert!(out.is_empty() && err.is_empty());
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn wait(child: &mut Running) -> Option<i32> {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.0.try_wait().expect("polled") {
            return status.code();
        }
        assert!(Instant::now() < deadline, "child did not exit");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn run_reader(reader: u32, log: &Path) -> Option<i32> {
    let mut child = Running(
        Process::new(HELPER)
            .arg("--reader-uid")
            .arg(reader.to_string())
            .arg(log)
            .args(fixture_argv("fixture_child_emit"))
            .env("HL_LOG_BYTES", "64")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawned boot-log"),
    );
    wait(&mut child)
}

#[expect(
    clippy::expect_used,
    reason = "a fixture setup failure fails the calling test"
)]
fn owner_and_mode(log: &Path) -> (u32, u32) {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::metadata(log).expect("log metadata");
    (metadata.uid(), metadata.mode() & 0o777)
}

/// boot-log-private-to-its-reader: as root the log is handed to the reader,
/// kept 0600, reused on relaunch and refused to any other reader; without
/// root the writer's own uid is its reader and a foreign reader is refused.
#[test]
fn reader_receives_the_private_log_or_custody_is_refused() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let log = new_log(&directory);
    let euid = rustix::process::geteuid().as_raw();
    if euid == 0 {
        assert_eq!(run_reader(65_534, &log), Some(0));
        assert_eq!(owner_and_mode(&log), (65_534, 0o600));
        let bytes = std::fs::read(&log).expect("read log");
        assert!(bytes.windows(13).any(|w| w == b"stderr-marker"));
        assert_eq!(
            run_reader(65_534, &log),
            Some(0),
            "relaunch reuses its file"
        );
        assert_eq!(
            run_reader(65_533, &log),
            Some(74),
            "another reader is refused"
        );
        assert_eq!(owner_and_mode(&log), (65_534, 0o600));
    } else {
        assert_eq!(run_reader(euid, &log), Some(0));
        assert_eq!(owner_and_mode(&log), (euid, 0o600));
        let other = directory.path().join("other.log");
        assert_eq!(
            run_reader(euid + 1, &other),
            Some(74),
            "no hand-over without root"
        );
    }
}
