#![forbid(unsafe_code)]

use hegel::generators as gs;
use hegel::TestCase;
use std::process::{Command, Stdio};

const PROBE: &str = env!("CARGO_BIN_EXE_lilly-kvm-probe");

#[expect(
    clippy::expect_used,
    reason = "integration-test helper: failing to spawn the probe must abort the test"
)]
fn run_probe(arguments: &[String], envs: &[(String, String)]) -> (Option<i32>, Vec<u8>, Vec<u8>) {
    let output = Command::new(PROBE)
        .args(arguments)
        // A clean environment proves the ambient one cannot steer the verdict.
        .env_clear()
        .envs(
            envs.iter()
                .map(|(key, value)| (key.as_str(), value.as_str())),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("spawned probe");
    (output.status.code(), output.stdout, output.stderr)
}

/// @cc [owner:ghuntley,label:verification] hegel-kvm-probe-argv-env-agnostic
/// Generated argument vectors and environment noise MUST NOT influence the
/// verdict: the probe consults exactly /dev/kvm, produces no output and returns
/// only 0 or 1.
#[hegel::test]
fn probe_ignores_arguments_and_environment(tc: TestCase) {
    let argc = tc.draw(gs::integers::<usize>().min_value(0).max_value(5));
    let alphabet = ["", "-x", "/dev/kvm", "kvm", "--force", "first\nsecond"];
    let argv: Vec<String> = (0..argc)
        .map(|_| tc.draw(gs::sampled_from(&alphabet)).to_string())
        .collect();
    let limit = tc.draw(gs::integers::<usize>().min_value(0).max_value(4));
    let envs: Vec<(String, String)> = (0..limit)
        .map(|index| (format!("LILLY_UNUSED_{index}"), index.to_string()))
        .collect();
    let (code, out, err) = run_probe(&argv, &envs);
    assert!(
        matches!(code, Some(0 | 1)),
        "verdict outside allowed codes: {code:?}"
    );
    assert!(out.is_empty(), "stdout leaked {out:?}");
    assert!(err.is_empty(), "stderr leaked {err:?}");
    if !std::path::Path::new("/dev/kvm")
        .try_exists()
        .unwrap_or(false)
    {
        assert_eq!(code, Some(1), "execution capability without the device");
    }
}

#[hegel::test]
fn probe_is_deterministic_across_repeats(tc: TestCase) {
    let repeats = tc.draw(gs::integers::<usize>().min_value(2).max_value(4));
    let verdicts: Vec<Option<i32>> = (0..repeats).map(|_| run_probe(&[], &[]).0).collect();
    assert!(verdicts.iter().all(|verdict| *verdict == verdicts[0]));
}
