#![cfg(target_os = "linux")]
//! Stateful property test of `overalls open` against a fake `ssh` (ADR-0128).
//!
//! The fake records every argv and answers with scripted Porsche and guest
//! outcomes. It exercises the real CLI binary, not Porsche, Audi or a guest.

use hegel::{generators as gs, TestCase};
use lyra::workspace_source::{self, WorkspaceSource};
use serde::Deserialize;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use tempfile::TempDir;

const ZONE: &str = "vm.test";
const PORSCHE: &str = "porsche.test";

const FAKE_SSH: &str = r#"#!/bin/sh
dir=$OVERALLS_FAKE_SSH_DIR
n=$(ls "$dir/calls" | wc -l | tr -d ' ')
printf '%s\0' "$@" > "$dir/calls/$n"
if [ "$1" = -T ]; then
  id=
  previous=
  for argument in "$@"; do
    if [ "$previous" = --request-id ]; then id=$argument; fi
    previous=$argument
  done
  sed "s/@REQUEST_ID@/$id/g" "$dir/porsche.json"
  exit "$(cat "$dir/porsche.status")"
fi
if [ "$1" = -o ]; then
  exit "$(cat "$dir/probe.status")"
fi
exit "$(cat "$dir/guest.status")"
"#;

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
/// One shared HOME so the CLI's seed copy happens once per test process.
fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home = Path::new(env!("CARGO_TARGET_TMPDIR")).join("open-cli-home");
        if home.exists() {
            fs::remove_dir_all(&home).expect("stale fixture home");
        }
        fs::create_dir_all(home.join(".config/overalls")).expect("config directory");
        fs::write(
            home.join(".config/overalls/config.json"),
            format!(r#"{{"origin":"https://{PORSCHE}","zone":"{ZONE}"}}"#),
        )
        .expect("fixture config");
        let bin = home.join("fake-bin");
        fs::create_dir_all(&bin).expect("fake bin");
        fs::write(bin.join("ssh"), FAKE_SSH).expect("fake ssh");
        fs::set_permissions(bin.join("ssh"), fs::Permissions::from_mode(0o755))
            .expect("fake ssh mode");
        home
    })
}

#[derive(Deserialize)]
struct Vectors {
    accepted: Vec<Url>,
    refused: Vec<Url>,
}

#[derive(Deserialize)]
struct Url {
    url: String,
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn urls() -> &'static (Vec<String>, Vec<String>) {
    static URLS: OnceLock<(Vec<String>, Vec<String>)> = OnceLock::new();
    URLS.get_or_init(|| {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/workspace_sources.json");
        let vectors: Vectors =
            serde_json::from_slice(&fs::read(path).expect("vectors")).expect("typed vectors");
        let mut refused: Vec<String> = vectors.refused.into_iter().map(|url| url.url).collect();
        refused.extend(
            [
                "https://github.com/o/r/tree/$(touch${IFS}/tmp/pwned)",
                "https://github.com/o/r';id;'",
                "-oProxyCommand=id",
            ]
            .map(str::to_owned),
        );
        (
            vectors.accepted.into_iter().map(|url| url.url).collect(),
            refused,
        )
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Porsche {
    Running,
    ExitFailure,
    WrongRequest,
    Failed,
    NotRunning,
    UnsafeName,
    Malformed,
}

struct OpenMachine {
    fixture: TempDir,
    url: String,
    porsche: Porsche,
    machine_id: u128,
    machine_name: String,
    guest_exit: u8,
    guest_ready: bool,
    command: Vec<String>,
    request_ids: Vec<String>,
    guest_calls: usize,
}

fn uuid(value: u128) -> String {
    let bytes = value.to_be_bytes();
    format!(
        "{}-{}-{}-{}-{}",
        hex::encode(&bytes[..4]),
        hex::encode(&bytes[4..6]),
        hex::encode(&bytes[6..8]),
        hex::encode(&bytes[8..10]),
        hex::encode(&bytes[10..])
    )
}

/// Independent oracle for `OverallsProtocol.IngressName.label/2`.
#[expect(
    clippy::expect_used,
    reason = "generated machine names are ASCII, so every byte offset is a boundary"
)]
fn expected_label(name: &str, id: u128) -> String {
    let prefix = name.get(..name.len().min(22)).expect("ASCII machine name");
    format!("v-{}-{id:032x}", prefix.trim_end_matches('-'))
}

fn single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn read_calls(directory: &Path) -> Vec<Vec<String>> {
    let mut entries: Vec<(usize, Vec<String>)> = fs::read_dir(directory)
        .expect("calls")
        .map(|entry| {
            let entry = entry.expect("call entry");
            let index: usize = entry
                .file_name()
                .to_string_lossy()
                .parse()
                .expect("numbered call");
            let bytes = fs::read(entry.path()).expect("call bytes");
            let arguments = bytes
                .split(|byte| *byte == 0)
                .filter(|part| !part.is_empty())
                .map(|part| String::from_utf8(part.to_vec()).expect("utf-8 argv"))
                .collect();
            (index, arguments)
        })
        .collect();
    entries.sort();
    entries
        .into_iter()
        .map(|(_, arguments)| arguments)
        .collect()
}

impl OpenMachine {
    fn porsche_response(&self) -> (String, u8) {
        let id = uuid(self.machine_id);
        let body = |request: &str, status: &str, outcome: &str, name: &str| {
            format!(
                r#"{{"version":1,"request_id":"{request}","status":"{status}","operation_id":"{id}","result":{{"id":"{id}","name":"{name}","image_id":"x","profile":"oss","outcome":"{outcome}"}}}}"#
            )
        };
        let name = self.machine_name.as_str();
        match self.porsche {
            Porsche::Running => (body("@REQUEST_ID@", "succeeded", "running", name), 0),
            Porsche::ExitFailure => (
                r#"{"version":1,"status":"error","error":"forbidden","request_id":"@REQUEST_ID@"}"#
                    .into(),
                3,
            ),
            Porsche::WrongRequest => (body("other-request", "succeeded", "running", name), 0),
            Porsche::Failed => (body("@REQUEST_ID@", "failed", "failed", name), 1),
            Porsche::NotRunning => (body("@REQUEST_ID@", "succeeded", "stopped", name), 0),
            Porsche::UnsafeName => (body("@REQUEST_ID@", "succeeded", "running", "x;id"), 0),
            Porsche::Malformed => ("not json\n".into(), 0),
        }
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn execute(&mut self) -> (i32, Vec<Vec<String>>) {
        let directory = self.fixture.path();
        let calls = directory.join("calls");
        if calls.exists() {
            fs::remove_dir_all(&calls).expect("reset calls");
        }
        fs::create_dir_all(&calls).expect("calls directory");
        let (body, status) = self.porsche_response();
        fs::write(directory.join("porsche.json"), body).expect("porsche fixture");
        fs::write(directory.join("porsche.status"), status.to_string()).expect("porsche status");
        fs::write(directory.join("guest.status"), self.guest_exit.to_string())
            .expect("guest status");
        let probe = if self.guest_ready { "0" } else { "255" };
        fs::write(directory.join("probe.status"), probe).expect("probe status");
        let home = home();
        let path = format!(
            "{}:{}",
            home.join("fake-bin").display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let mut command = Command::new(env!("CARGO_BIN_EXE_overalls"));
        command.arg("open").arg(&self.url);
        if !self.command.is_empty() {
            command.arg("--").args(&self.command);
        }
        let output = command
            .env("HOME", home)
            .env_remove("XDG_CONFIG_HOME")
            .env("XDG_STATE_HOME", home.join("state"))
            .env("PATH", path)
            .env("OVERALLS_FAKE_SSH_DIR", directory)
            .env("OVERALLS_OPEN_READY_TIMEOUT", "1")
            .output()
            .expect("overalls open");
        (output.status.code().unwrap_or(-1), read_calls(&calls))
    }

    #[expect(
        clippy::expect_used,
        reason = "shared-vector oracle: a mismatch must fail the test"
    )]
    fn check_porsche_call(&mut self, call: &[String], source: &WorkspaceSource) {
        let canonical = source.to_url();
        let fixed: Vec<&str> = vec![
            "-T",
            "-p",
            "22",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
            "--",
            PORSCHE,
            "new",
            "--source",
            &canonical,
            "--profile",
            "oss",
            "--request-id",
        ];
        assert_eq!(call.len(), fixed.len() + 4, "{call:?}");
        assert_eq!(&call[..fixed.len()], fixed.as_slice());
        let request = &call[fixed.len()];
        let hex = request
            .strip_prefix("overalls-open-")
            .expect("request prefix");
        assert!(hex.len() == 32 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert!(!self.request_ids.contains(request), "request ID reused");
        self.request_ids.push(request.clone());
        assert_eq!(&call[fixed.len() + 1..], ["--timeout", "600", "--json"]);
    }

    fn check_guest_call(&self, call: &[String], source: &WorkspaceSource) {
        let host = format!(
            "{}.{ZONE}",
            expected_label(&self.machine_name, self.machine_id)
        );
        assert_eq!(call.len(), 4, "{call:?}");
        assert_eq!(&call[..3], ["-t", "--", host.as_str()]);
        let tail = if self.command.is_empty() {
            "exec \"${SHELL:-/bin/sh}\" -l\n".to_owned()
        } else {
            let words: Vec<String> = self.command.iter().map(|word| single_quote(word)).collect();
            format!(
                "exec \"${{SHELL:-/bin/sh}}\" -l -c 'exec \"$@\"' overalls-open {}\n",
                words.join(" ")
            )
        };
        // Exact oracle: the fixed body, the quoted repository name and the
        // quoted user words are the only inputs; owner and ref never appear.
        let expected = format!(
            "{WAIT_SCRIPT}cd -- /workspace/{} || exit 1\n{tail}",
            single_quote(source.repository())
        );
        assert_eq!(call[3], expected);
    }
}

const WAIT_SCRIPT: &str = r#"status_file=/run/overalls-workspace/status
waited=0
last=
while :; do
  state=$(cat "$status_file" 2>/dev/null) || state=waiting
  case "$state" in
    done) break ;;
    failed) echo 'overalls: the repository clone failed' >&2; exit 1 ;;
    cloning) ;;
    *) state=waiting ;;
  esac
  if [ "$state" != "$last" ]; then echo "overalls: repository $state" >&2; last=$state; fi
  if [ "$waited" -ge 900 ]; then echo 'overalls: timed out waiting for the repository clone' >&2; exit 1; fi
  sleep 2
  waited=$((waited + 2))
done
"#;

#[hegel::state_machine]
impl OpenMachine {
    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn validate_url(&mut self, tc: TestCase) {
        let (accepted, refused) = urls();
        let valid = tc.draw(gs::booleans());
        self.url = if valid {
            tc.draw(gs::sampled_from(accepted.clone()))
        } else {
            tc.draw(gs::sampled_from(refused.clone()))
        };
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn create(&mut self, tc: TestCase) {
        self.porsche = tc.draw(gs::sampled_from(vec![
            Porsche::Running,
            Porsche::Running,
            Porsche::ExitFailure,
            Porsche::WrongRequest,
            Porsche::Failed,
            Porsche::NotRunning,
            Porsche::UnsafeName,
            Porsche::Malformed,
        ]));
        self.machine_id = tc.draw(gs::integers::<u128>());
        let generated = format!("vm-{:032x}", self.machine_id);
        self.machine_name = tc.draw(gs::sampled_from(vec![
            generated,
            "work".to_owned(),
            "abcdefghijklmnopqrstu-wxyz".to_owned(),
        ]));
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn guest_session(&mut self, tc: TestCase) {
        self.guest_exit = tc.draw(gs::integers::<u8>().max_value(3));
        self.guest_ready = tc.draw(gs::booleans());
        self.command =
            tc.draw(gs::vecs(gs::text().alphabet("ab -;$'\"`\\|&*()<>\n").max_size(8)).max_size(3));
        if self.command.first().is_some_and(String::is_empty) {
            self.command.clear();
        }
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[rule]
    fn open(&mut self, _: TestCase) {
        let (code, calls) = self.execute();
        let Ok(source) = workspace_source::parse_url(&self.url) else {
            assert_ne!(code, 0);
            assert!(calls.is_empty(), "invalid URL invoked ssh: {calls:?}");
            return;
        };
        let (first, rest) = calls.split_first().expect("Porsche call");
        self.check_porsche_call(first, &source);
        if self.porsche == Porsche::Running {
            let host = format!(
                "{}.{ZONE}",
                expected_label(&self.machine_name, self.machine_id)
            );
            let probe = [
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                "--",
                host.as_str(),
                "true",
            ];
            let probes = rest.iter().take_while(|call| call[0] == "-o").count();
            assert!(probes >= 1, "no readiness probe: {calls:?}");
            for call in &rest[..probes] {
                assert_eq!(call.as_slice(), probe);
            }
            let sessions = &rest[probes..];
            if self.guest_ready {
                assert_eq!(probes, 1, "ready guest probed more than once: {calls:?}");
                assert_eq!(sessions.len(), 1, "exactly one guest ssh: {calls:?}");
                self.check_guest_call(&sessions[0], &source);
                self.guest_calls += 1;
                assert_eq!(code, i32::from(self.guest_exit));
            } else {
                assert_ne!(code, 0);
                assert!(
                    sessions.is_empty(),
                    "session before guest was ready: {calls:?}"
                );
            }
        } else {
            assert_ne!(code, 0);
            assert!(rest.is_empty(), "guest ssh after failure: {calls:?}");
        }
    }

    #[invariant]
    fn request_ids_are_unique(&mut self, _: TestCase) {
        let mut ids = self.request_ids.clone();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), self.request_ids.len());
        assert!(self.guest_calls <= self.request_ids.len());
    }
}

// @cc [owner:ghuntley,label:verification;security] lyra-open-stage-machine
// Across generated URL, creation and guest outcomes, an invalid URL MUST make
// no ssh call, every failure MUST exit non-zero without a guest ssh, and
// success MUST probe until the guest accepts SSH, never start a session for a
// guest that stays unreachable, and otherwise exec exactly one guest ssh whose
// argv derives only from the
// validated repository name, Porsche's validated machine identity and the zone.
#[hegel::test(test_cases = 24)]
fn open_stage_machine(tc: TestCase) {
    let machine = OpenMachine {
        fixture: tempfile::tempdir().expect("fixture directory"),
        url: urls().0[0].clone(),
        porsche: Porsche::Running,
        machine_id: 1,
        machine_name: "work".into(),
        guest_exit: 0,
        guest_ready: true,
        command: Vec::new(),
        request_ids: Vec::new(),
        guest_calls: 0,
    };
    hegel::stateful::run(machine, tc);
}
