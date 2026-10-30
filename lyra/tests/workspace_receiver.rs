#![cfg(target_os = "linux")]
//! Shared-grammar agreement and receiver state-machine properties (ADR-0128).

use hegel::{generators as gs, TestCase};
use lyra::workspace_checkout::{self, Checkout, CheckoutRevision, ObjectFormat};
use lyra::workspace_receiver::{
    self as receiver, Binding, GitRunner, Paths, Receiver, Reply, Retry, Status,
};
use lyra::workspace_source::{self, Revision, WorkspaceSource};
use serde::Deserialize;
use serde_json::{json, Value};
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::OnceLock;
use std::time::Duration;
use tempfile::TempDir;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Vectors {
    version: u8,
    accepted: Vec<Accepted>,
    refused: Vec<Refused>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Accepted {
    url: String,
    source: Value,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Refused {
    url: String,
    reason: String,
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn vectors() -> &'static Vectors {
    static VECTORS: OnceLock<Vectors> = OnceLock::new();
    VECTORS.get_or_init(|| {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/workspace_sources.json");
        let bytes = fs::read(path).expect("shared vector file");
        let vectors: Vectors = serde_json::from_slice(&bytes).expect("typed vector file");
        assert_eq!(vectors.version, 2);
        assert!(!vectors.accepted.is_empty() && !vectors.refused.is_empty());
        vectors
    })
}

#[expect(
    clippy::panic,
    reason = "shared-vector oracle: a mismatch must fail the test"
)]
fn check_accepted(vector: &Accepted) {
    let source = workspace_source::parse_url(&vector.url)
        .unwrap_or_else(|reason| panic!("{} refused: {reason}", vector.url));
    assert_eq!(source.encode(), vector.source);
    assert_eq!(
        workspace_source::parse_url(&source.to_url()),
        Ok(source.clone())
    );
    assert_eq!(workspace_source::decode(&source.encode()), Ok(source));
}

#[expect(
    clippy::panic,
    reason = "shared-vector oracle: a mismatch must fail the test"
)]
fn check_refused(vector: &Refused) {
    match workspace_source::parse_url(&vector.url) {
        Ok(source) => panic!("{} accepted as {source:?}", vector.url),
        Err(reason) => assert_eq!(reason.as_str(), vector.reason, "{}", vector.url),
    }
}

#[test]
fn every_shared_vector_agrees_with_the_elixir_grammar() {
    vectors().accepted.iter().for_each(check_accepted);
    vectors().refused.iter().for_each(check_refused);
}

/// @cc [owner:ghuntley,label:verification;protocol] lyra-workspace-vector-agreement
/// The Rust grammar MUST agree with every shared fixture vector, and every
/// accepted vector MUST survive canonical URL and wire round trips unchanged.
#[hegel::test(test_cases = 64)]
fn drawn_vectors_agree_and_survive_url_decoration(tc: TestCase) {
    let accepted = tc.draw(gs::sampled_from(vectors().accepted.clone()));
    check_accepted(&accepted);
    let refused = tc.draw(gs::sampled_from(vectors().refused.clone()));
    check_refused(&refused);
    // Query strings and fragments are discarded before parsing.
    let suffix = tc.draw(gs::sampled_from(vec!["?tab=x", "#readme", "?a=b#c", ""]));
    let decorated = Accepted {
        url: format!(
            "{}{suffix}",
            accepted.url.split(['?', '#']).next().unwrap_or_default()
        ),
        ..accepted
    };
    check_accepted(&decorated);
}

const HOSTILE: &str = "-;$()`'\"\\|&*<>~ \t\n%./@+=,:_!#?{}[]aZ09";

fn allowed(value: &str, extra: &[u8]) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte) || extra.contains(&byte))
}

fn assert_inert(source: &WorkspaceSource) {
    for value in source
        .namespace()
        .iter()
        .map(String::as_str)
        .chain([source.repository()])
    {
        assert!(!value.is_empty() && !value.starts_with('-'));
        assert!(allowed(value, b""));
        assert!(value != "." && value != "..");
    }
    match source.revision() {
        Revision::Default => {}
        Revision::Change { value } => assert!(*value > 0 && i32::try_from(*value).is_ok()),
        Revision::Ref { value } | Revision::Tag { value } | Revision::Commit { value } => {
            assert!(allowed(value, b"/@+=,"));
            assert!(!value.contains(".."));
            assert!(value.split('/').all(|p| !p.starts_with(['-', '.'])));
        }
    }
}

/// @cc [owner:ghuntley,label:verification;security] lyra-workspace-hostile-urls
/// Generated hostile URLs MUST never yield an owner, repository or reference
/// that starts with "-" or contains shell, whitespace, quote or a traversal
/// component. Valid repository names such as `0..` are inert and stay accepted.
#[hegel::test(test_cases = 400)]
fn generated_hostile_urls_never_yield_option_or_shell_values(tc: TestCase) {
    // Mostly-valid alphabets reach acceptance; hostile ones probe refusal.
    let alphabet = tc.draw(gs::sampled_from(vec!["aZ09-._", "aZ09-._/@+=,", HOSTILE]));
    let segment = || gs::text().alphabet(alphabet).max_size(12);
    let prefix = tc.draw(gs::sampled_from(vec![
        "https://github.com/",
        "https://github.com/",
        "http://github.com/",
        "https://github.com:443/",
        "https://GitHub.com/",
        "github.com/",
        "",
    ]));
    let kind = tc.draw(gs::sampled_from(vec![
        "", "/tree/", "/commit/", "/pull/", "/blob/", "/",
    ]));
    let owner = tc.draw(segment());
    let repo = tc.draw(segment());
    let reference = tc.draw(segment());
    let tail = tc.draw(segment());
    let url = format!("{prefix}{owner}/{repo}{kind}{reference}/{tail}");
    if let Ok(source) = workspace_source::parse_url(&url) {
        assert_inert(&source);
        assert_eq!(workspace_source::parse_url(&source.to_url()), Ok(source));
    }
    let bytes = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(600));
    if let Ok(source) = workspace_source::parse_url(&String::from_utf8_lossy(&bytes)) {
        assert_inert(&source);
    }
}

fn binding() -> Binding {
    Binding {
        placement_id: "11111111-1111-4111-8111-111111111111".into(),
        execution_epoch: 7,
        boot_challenge: "c".repeat(64),
    }
}

fn request(source: &WorkspaceSource, binding: &Binding) -> Value {
    json!({
        "version": 1,
        "placement_id": binding.placement_id,
        "execution_epoch": binding.execution_epoch,
        "boot_challenge": binding.boot_challenge,
        "nonce": "0123456789abcdef".repeat(4),
        "source": source.encode(),
    })
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn line(value: &Value) -> Vec<u8> {
    serde_json::to_vec(value).expect("request encoding")
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn accepted_sources() -> Vec<WorkspaceSource> {
    vectors()
        .accepted
        .iter()
        .map(|vector| workspace_source::parse_url(&vector.url).expect("accepted vector"))
        .collect()
}

#[derive(Clone, Copy, Debug)]
enum Mutation {
    Placement,
    Epoch,
    Challenge,
    Version,
    UpperNonce,
    ShortNonce,
    UnknownField,
    UnknownSourceField,
    MissingRevision,
    InvalidSource,
    Oversize,
}

/// @cc [owner:ghuntley,label:verification;security] lyra-workspace-envelope-refusal
/// Every binding mismatch, unknown field, malformed nonce, invalid source and
/// oversize line MUST be refused; the unmodified envelope MUST be accepted.
#[hegel::test(test_cases = 200)]
fn envelope_validation_refuses_every_mutation(tc: TestCase) {
    let binding = binding();
    let source = tc.draw(gs::sampled_from(accepted_sources()));
    let valid = request(&source, &binding);
    let delivery = receiver::validate_request(&line(&valid), &binding).expect("valid envelope");
    assert_eq!(delivery.source, source);
    let mutation = tc.draw(gs::sampled_from(vec![
        Mutation::Placement,
        Mutation::Epoch,
        Mutation::Challenge,
        Mutation::Version,
        Mutation::UpperNonce,
        Mutation::ShortNonce,
        Mutation::UnknownField,
        Mutation::UnknownSourceField,
        Mutation::MissingRevision,
        Mutation::InvalidSource,
        Mutation::Oversize,
    ]));
    let mut value = valid.clone();
    match mutation {
        Mutation::Placement => {
            value["placement_id"] = json!("22222222-2222-4222-8222-222222222222");
        }
        Mutation::Epoch => {
            let delta = tc.draw(gs::integers::<u64>().min_value(1).max_value(1 << 40));
            value["execution_epoch"] = json!(binding.execution_epoch.wrapping_add(delta));
        }
        Mutation::Challenge => value["boot_challenge"] = json!("d".repeat(64)),
        Mutation::Version => value["version"] = json!(2),
        Mutation::UpperNonce => value["nonce"] = json!("A".repeat(64)),
        Mutation::ShortNonce => value["nonce"] = json!("a".repeat(63)),
        Mutation::UnknownField => value["extra"] = json!(true),
        Mutation::UnknownSourceField => value["source"]["token"] = json!("x"),
        Mutation::MissingRevision => {
            if let Some(map) = value["source"].as_object_mut() {
                map.remove("revision");
            }
        }
        Mutation::InvalidSource => value["source"]["namespace"] = json!("-rf"),
        Mutation::Oversize => {
            let padding = tc.draw(gs::integers::<usize>().min_value(4096).max_value(9000));
            value["source"]["repository"] = json!("r".repeat(padding));
        }
    }
    assert!(
        receiver::validate_request(&line(&value), &binding).is_err(),
        "{mutation:?}"
    );
    let mut padded = line(&valid);
    padded.resize(receiver::MAXIMUM_REQUEST + 1, b' ');
    assert!(receiver::validate_request(&padded, &binding).is_err());
}

/// Fake `git`: records every argument vector and simulates clone output.
struct FakeGit {
    calls: Vec<Vec<String>>,
    fail_at: Option<usize>,
}

impl GitRunner for FakeGit {
    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn output(&mut self, _: &[String]) -> io::Result<Vec<u8>> {
        let mut output = format!("{}\trefs/heads/main\n", "a".repeat(40));
        for vector in &vectors().accepted {
            let source = workspace_source::decode(&vector.source).expect("fixture");
            if let Revision::Change { value } = source.revision() {
                let reference = match source.provider() {
                    workspace_source::Provider::Github => Some(format!("refs/pull/{value}/head")),
                    workspace_source::Provider::Gitlab => {
                        Some(format!("refs/merge-requests/{value}/head"))
                    }
                    _ => None,
                };
                if let Some(reference) = reference {
                    let _ = writeln!(output, "{}\t{reference}", "a".repeat(40));
                }
            }
            let prefix = match source.revision() {
                Revision::Ref { value } => Some(("heads", value)),
                Revision::Tag { value } => Some(("tags", value)),
                _ => None,
            };
            if let Some((kind, value)) = prefix {
                let _ = writeln!(output, "{}\trefs/{kind}/{value}", "a".repeat(40));
            }
        }
        Ok(output.into_bytes())
    }
    fn change_head(&mut self, source: &WorkspaceSource) -> io::Result<Checkout> {
        Ok(Checkout {
            url: source.clone_url(),
            revision: CheckoutRevision::Commit("a".repeat(40)),
            object_format: ObjectFormat::Sha1,
        })
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn run(&mut self, arguments: &[String]) -> io::Result<bool> {
        let step = self.calls.len();
        self.calls.push(arguments.to_vec());
        if self.fail_at == Some(step) {
            return Ok(false);
        }
        if matches!(
            arguments.first().map(String::as_str),
            Some("clone" | "init")
        ) {
            let directory = PathBuf::from(arguments.last().expect("clone directory"));
            fs::create_dir_all(directory.join(".git"))?;
            fs::write(directory.join("README"), "fixture\n")?;
            fs::set_permissions(directory.join("README"), fs::Permissions::from_mode(0o644))?;
            std::os::unix::fs::symlink("/etc/shadow", directory.join("escape"))?;
        }
        Ok(true)
    }
}

const FIXED_OPTIONS: [&str; 8] = [
    "--branch",
    "--",
    "-C",
    "--detach",
    "--depth",
    "--no-tags",
    "--filter=blob:none",
    "--no-checkout",
];

struct ReceiverMachine {
    root: TempDir,
    receiver: Receiver,
    git: FakeGit,
    sources: Vec<WorkspaceSource>,
    persisted: Option<WorkspaceSource>,
    first_write: Option<(u64, Vec<u8>)>,
    done: bool,
    status: Status,
    calls_at_done: Option<usize>,
    shared_git_configuration: bool,
}

impl ReceiverMachine {
    fn paths(&self) -> Paths {
        Paths::under(self.root.path())
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn deliver(&mut self, source: WorkspaceSource) {
        let decision = self.receiver.deliver(&source).expect("delivery");
        match &self.persisted {
            Some(existing) if *existing != source => {
                assert_eq!(decision.reply, Reply::Conflict);
                assert!(!decision.clone);
            }
            _ => {
                assert_eq!(decision.reply, Reply::Accepted);
                assert_eq!(decision.clone, !self.done);
                self.persisted = Some(source);
            }
        }
        let paths = self.paths();
        if self.first_write.is_none() {
            let metadata = fs::metadata(paths.source()).expect("persisted source");
            self.first_write = Some((metadata.ino(), fs::read(paths.source()).expect("bytes")));
        }
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture: a failed setup step must abort the test"
    )]
    fn clone_once(&mut self, fail_at: Option<usize>) {
        let Some(source) = self.persisted.clone() else {
            return;
        };
        let before = self.git.calls.len();
        self.git.fail_at = fail_at.map(|step| before + step);
        let result = self
            .receiver
            .attempt(&source, &mut self.git)
            .expect("attempt");
        let paths = self.paths();
        if self.done {
            assert!(result);
            assert_eq!(self.git.calls.len(), before, "clone ran after done");
            return;
        }
        let target = workspace_checkout::resolve(&source, &mut self.git).expect("resolve fixture");
        let planned = receiver::git_plan(&target, &paths.partial(&source)).len();
        match fail_at {
            Some(step) if step < planned => {
                assert!(!result);
                assert!(fs::symlink_metadata(paths.partial(&source)).is_err());
                assert!(fs::symlink_metadata(paths.checkout(&source)).is_err());
            }
            _ => {
                assert!(result);
                self.done = true;
                self.status = Status::Done;
                self.calls_at_done = Some(self.git.calls.len());
                let checkout = paths.checkout(&source);
                let mode = |path: &Path| {
                    fs::symlink_metadata(path)
                        .expect("mode")
                        .permissions()
                        .mode()
                        & 0o777
                };
                assert_eq!(mode(&checkout), 0o777);
                assert_eq!(mode(&checkout.join("README")), 0o666);
                assert!(fs::symlink_metadata(checkout.join("escape"))
                    .expect("link")
                    .file_type()
                    .is_symlink());
            }
        }
    }
}

#[hegel::state_machine]
impl ReceiverMachine {
    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn deliver_same(&mut self, tc: TestCase) {
        let source = match &self.persisted {
            Some(source) => source.clone(),
            None => tc.draw(gs::sampled_from(self.sources.clone())),
        };
        self.deliver(source);
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn deliver_different(&mut self, tc: TestCase) {
        let source = tc.draw(gs::sampled_from(self.sources.clone()));
        tc.assume(self.persisted.as_ref() != Some(&source));
        self.deliver(source);
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[rule]
    fn replay(&mut self, _: TestCase) {
        let Some(source) = self.persisted.clone() else {
            return;
        };
        let binding = binding();
        let delivery = receiver::validate_request(&line(&request(&source, &binding)), &binding)
            .expect("replayed envelope");
        self.deliver(delivery.source);
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[rule]
    fn restart(&mut self, _: TestCase) {
        let receiver = Receiver::new(self.paths()).expect("restart");
        if self.shared_git_configuration {
            let _ = fs::remove_file(self.paths().git_configuration());
        }
        self.receiver = if self.shared_git_configuration {
            receiver.with_shared_git_configuration()
        } else {
            receiver
        };
        let resumed = self.receiver.start().expect("startup");
        if self.done {
            assert_eq!(resumed, None);
            self.status = Status::Done;
        } else if let Some(source) = &self.persisted {
            assert_eq!(resumed.as_ref(), Some(source));
            self.status = Status::Cloning;
        } else {
            assert_eq!(resumed, None);
            self.status = Status::Waiting;
        }
    }

    #[rule]
    fn clone_success(&mut self, _: TestCase) {
        self.clone_once(None);
    }

    #[allow(
        clippy::needless_pass_by_value,
        reason = "Hegel rules take TestCase by value; `expect` is unfulfillable on re-emitted rules"
    )]
    #[rule]
    fn clone_failure(&mut self, tc: TestCase) {
        let step = tc.draw(gs::integers::<usize>().max_value(3));
        self.clone_once(Some(step));
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[rule]
    fn retries_exhausted(&mut self, _: TestCase) {
        let Some(source) = self.persisted.clone() else {
            return;
        };
        if self.done {
            return;
        }
        let mut failing = AlwaysFail(&mut self.git);
        let retry = Retry {
            attempts: 3,
            initial: Duration::ZERO,
            maximum: Duration::ZERO,
        };
        let mut sleeps = 0;
        let status = self
            .receiver
            .clone_with_retry(&source, &mut failing, retry, &mut |_| sleeps += 1, || {})
            .expect("bounded retry");
        assert_eq!(status, Status::Failed);
        assert_eq!(sleeps, 2);
        self.status = Status::Failed;
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[invariant]
    fn source_written_at_most_once(&mut self, _: TestCase) {
        let paths = self.paths();
        match &self.first_write {
            None => assert!(fs::symlink_metadata(paths.source()).is_err()),
            Some((inode, bytes)) => {
                let metadata = fs::metadata(paths.source()).expect("source");
                assert_eq!(metadata.ino(), *inode, "source.json rewritten");
                assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
                assert_eq!(&fs::read(paths.source()).expect("bytes"), bytes);
            }
        }
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[invariant]
    fn no_clone_after_done_and_status_matches(&mut self, _: TestCase) {
        if let Some(count) = self.calls_at_done {
            assert_eq!(self.git.calls.len(), count);
        }
        assert_eq!(self.receiver.done(), self.done);
        let paths = self.paths();
        if self.shared_git_configuration && self.done {
            let configuration = paths.git_configuration();
            let metadata = fs::symlink_metadata(&configuration).expect("trusted configuration");
            assert!(metadata.file_type().is_file());
            assert_eq!(metadata.permissions().mode() & 0o777, 0o644);
            assert_eq!(
                metadata.uid(),
                fs::metadata(&paths.run).expect("run owner").uid()
            );
        }
        if let Ok(bytes) = fs::read(paths.status()) {
            assert_eq!(bytes, format!("{}\n", self.status.as_str()).into_bytes());
            assert_eq!(
                fs::metadata(paths.status())
                    .expect("status")
                    .permissions()
                    .mode()
                    & 0o777,
                0o644
            );
        }
    }

    // `expect` is unfulfillable here: the state-machine macro re-emits rules.
    #[allow(
        clippy::expect_used,
        reason = "Hegel state-machine rule: a failed step must fail the property"
    )]
    #[invariant]
    fn git_arguments_never_become_options(&mut self, _: TestCase) {
        for call in &self.git.calls {
            for argument in call {
                assert!(
                    !argument.starts_with('-') || FIXED_OPTIONS.contains(&argument.as_str()),
                    "{argument:?}"
                );
            }
            let separator = call.iter().position(|argument| argument == "--");
            if call.first().map(String::as_str) == Some("clone") {
                let separator = separator.expect("clone separator");
                assert_eq!(call.len(), separator + 3);
                assert!(workspace_source::parse_url(&call[separator + 1]).is_ok());
            }
            if call.get(2).map(String::as_str) == Some("remote") {
                let separator = separator.expect("remote separator");
                assert_eq!(call.len(), separator + 3);
                assert!(workspace_source::parse_url(&call[separator + 2]).is_ok());
            }
            if call.get(2).map(String::as_str) == Some("fetch") {
                assert!(call
                    .windows(2)
                    .any(|pair| pair[0] == "--depth" && pair[1] == "1"));
            }
        }
    }
}

/// Runner that fails every attempt while still recording argv.
struct AlwaysFail<'a>(&'a mut FakeGit);

impl GitRunner for AlwaysFail<'_> {
    fn output(&mut self, arguments: &[String]) -> io::Result<Vec<u8>> {
        self.0.output(arguments)
    }
    fn change_head(&mut self, source: &WorkspaceSource) -> io::Result<Checkout> {
        self.0.change_head(source)
    }

    fn run(&mut self, arguments: &[String]) -> io::Result<bool> {
        self.0.calls.push(arguments.to_vec());
        Ok(false)
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] lyra-workspace-receiver-state-machine
/// Generated deliveries, replays, restarts, clone successes, clone failures and
/// retry exhaustion MUST keep source.json written at most once, answer a
/// different source with conflict, never run git after done and never pass an
/// input-derived git argument that begins with "-".
#[hegel::test(test_cases = 64)]
fn receiver_state_machine(tc: TestCase) {
    let root = tempfile::tempdir().expect("temporary guest root");
    let mut receiver = Receiver::new(Paths::under(root.path())).expect("receiver");
    let shared_git_configuration = tc.draw(gs::booleans());
    if shared_git_configuration {
        receiver = receiver.with_shared_git_configuration();
    }
    let mut sources = accepted_sources();
    sources
        .push(workspace_source::parse_url("https://github.com/o/other/tree/main").expect("valid"));
    let machine = ReceiverMachine {
        root,
        receiver,
        git: FakeGit {
            calls: Vec::new(),
            fail_at: None,
        },
        sources,
        persisted: None,
        first_write: None,
        done: false,
        status: Status::Waiting,
        calls_at_done: None,
        shared_git_configuration,
    };
    hegel::stateful::run(machine, tc);
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn native_receiver(paths: Paths) -> Receiver {
    Receiver::new(paths)
        .expect("native receiver")
        .with_shared_git_configuration()
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn real_git(system_configuration: &Path, arguments: &[&std::ffi::OsStr], foreign: bool) -> Output {
    Command::new("git")
        .env_clear()
        .env(
            "PATH",
            std::env::var_os("PATH").expect("test Git search path"),
        )
        .env("GIT_CONFIG_SYSTEM", system_configuration)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env(
            "GIT_TEST_ASSUME_DIFFERENT_OWNER",
            if foreign { "1" } else { "0" },
        )
        .args(arguments)
        .output()
        .expect("real Git process")
}

#[test]
fn native_git_include_trusts_only_exact_checkout_and_survives_runtime_loss() {
    let root = tempfile::tempdir().expect("temporary guest root");
    let paths = Paths::under(root.path());
    let source = workspace_source::parse_url("https://github.com/fixture/approved").unwrap();
    let other = workspace_source::parse_url("https://github.com/fixture/unrelated").unwrap();
    let receiver = native_receiver(paths.clone());
    receiver.deliver(&source).unwrap();
    let checkout = paths.checkout(&source);
    let unrelated = paths.checkout(&other);
    fs::create_dir_all(&checkout).unwrap();
    fs::create_dir_all(&unrelated).unwrap();
    let system_configuration = root.path().join("system-gitconfig");
    fs::write(
        &system_configuration,
        format!(
            "[include]\npath = {}\n",
            paths.git_configuration().display()
        ),
    )
    .unwrap();
    for path in [&checkout, &unrelated] {
        let result = real_git(
            &system_configuration,
            &["init".as_ref(), "-q".as_ref(), path.as_os_str()],
            false,
        );
        assert!(result.status.success(), "fixture Git init failed");
    }
    let probe = |path: &Path| {
        real_git(
            &system_configuration,
            &[
                "-C".as_ref(),
                path.as_os_str(),
                "rev-parse".as_ref(),
                "--show-toplevel".as_ref(),
            ],
            true,
        )
    };
    assert!(
        !probe(&checkout).status.success(),
        "ownership check was not exercised"
    );
    let mut git = FakeGit {
        calls: Vec::new(),
        fail_at: None,
    };
    assert!(receiver.attempt(&source, &mut git).unwrap());
    assert!(git.calls.is_empty(), "finished checkout was cloned again");
    assert!(
        probe(&checkout).status.success(),
        "exact approved path was refused"
    );
    assert!(
        !probe(&unrelated).status.success(),
        "unrelated path gained ownership trust"
    );
    let configuration = fs::read(paths.git_configuration()).unwrap();
    assert_eq!(receiver.deliver(&other).unwrap().reply, Reply::Conflict);
    assert_eq!(fs::read(paths.git_configuration()).unwrap(), configuration);
    fs::remove_file(paths.git_configuration()).unwrap();
    let restarted = native_receiver(paths.clone());
    assert_eq!(restarted.start().unwrap(), None);
    assert_eq!(fs::read(paths.status()).unwrap(), b"done\n");
    assert!(
        probe(&checkout).status.success(),
        "volatile configuration was not restored"
    );
    assert!(
        !probe(&unrelated).status.success(),
        "reboot expanded ownership trust"
    );
    assert_eq!(
        fs::metadata(&paths.state).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(paths.git_configuration())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o644
    );
}

#[test]
fn native_git_publication_failure_withholds_done_and_retries_existing_checkout() {
    let root = tempfile::tempdir().expect("temporary guest root");
    let paths = Paths::under(root.path());
    let source = workspace_source::parse_url("https://github.com/fixture/approved").unwrap();
    let receiver = native_receiver(paths.clone());
    receiver.deliver(&source).unwrap();
    fs::set_permissions(&paths.run, fs::Permissions::from_mode(0o777)).unwrap();
    let mut git = FakeGit {
        calls: Vec::new(),
        fail_at: None,
    };
    assert!(receiver.attempt(&source, &mut git).is_err());
    assert!(
        !receiver.done(),
        "unsafe public configuration granted completion"
    );
    assert!(!paths.git_configuration().exists());
    let calls = git.calls.len();
    fs::set_permissions(&paths.run, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(receiver.attempt(&source, &mut git).unwrap());
    assert_eq!(git.calls.len(), calls, "publication retry cloned again");
    assert_eq!(fs::read(paths.status()).unwrap(), b"done\n");
}

#[test]
fn native_git_startup_refuses_linked_configuration_without_stale_done() {
    let root = tempfile::tempdir().expect("temporary guest root");
    let paths = Paths::under(root.path());
    let source = workspace_source::parse_url("https://github.com/fixture/approved").unwrap();
    let receiver = native_receiver(paths.clone());
    receiver.deliver(&source).unwrap();
    let mut git = FakeGit {
        calls: Vec::new(),
        fail_at: None,
    };
    assert!(receiver.attempt(&source, &mut git).unwrap());
    let outside = root.path().join("unrelated-gitconfig");
    fs::write(&outside, b"unrelated configuration\n").unwrap();
    fs::remove_file(paths.git_configuration()).unwrap();
    std::os::unix::fs::symlink(&outside, paths.git_configuration()).unwrap();
    assert!(native_receiver(paths.clone()).start().is_err());
    assert_eq!(fs::read(paths.status()).unwrap(), b"waiting\n");
    assert_eq!(fs::read(&outside).unwrap(), b"unrelated configuration\n");
}
