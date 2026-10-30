#![forbid(unsafe_code)]

use std::process::{Command as Process, Stdio};

const HELPER: &str = env!("CARGO_BIN_EXE_lilly-export-channel");

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper: a spawn failure must abort the test"
)]
fn run(arguments: &[&str], envs: &[(&str, &str)]) -> Option<i32> {
    Process::new(HELPER)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .env_remove("SSH_ORIGINAL_COMMAND")
        .envs(envs.iter().copied())
        .status()
        .expect("spawned helper")
        .code()
}

#[test]
fn usage_lattice_is_sixty_four() {
    assert_eq!(run(&[], &[]), Some(64));
    assert_eq!(run(&["bridge", "relative.sock", "key"], &[]), Some(64));
    // no SSH_ORIGINAL_COMMAND: bridge refuses at the selector, never guessing.
    assert_eq!(
        run(&["bridge", "/tmp/none.sock", &"A".repeat(68)], &[]),
        Some(64)
    );
    assert_eq!(run(&["serve", "root"], &[]), Some(64));
}

#[test]
fn bridge_with_missing_socket_is_refused() {
    assert_eq!(
        run(
            &["bridge", "/nonexistent/export.sock", &"A".repeat(68)],
            &[("SSH_ORIGINAL_COMMAND", "zfs send x")],
        ),
        Some(1)
    );
}

#[test]
fn serve_with_unknown_account_is_refused() {
    assert_eq!(
        run(&["serve", "definitely-missing-account", "/dev/null"], &[]),
        Some(1)
    );
}
