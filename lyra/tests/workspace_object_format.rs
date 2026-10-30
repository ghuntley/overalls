#![cfg(target_os = "linux")]
//! Real local Git object-format resolution and checkout, without provider I/O.
use lyra::workspace_checkout::{self, CheckoutRevision, ObjectFormat};
use lyra::workspace_receiver::{git_plan, GitRunner, SystemGit};
use lyra::workspace_source::{self, WorkspaceSource};
use std::io;
use std::path::Path;
use std::time::Duration;

struct AdvertisedGit {
    listing: Vec<u8>,
}

impl GitRunner for AdvertisedGit {
    fn run(&mut self, _arguments: &[String]) -> io::Result<bool> {
        Err(io::Error::other("fixture only supplies advertised refs"))
    }

    fn output(&mut self, _arguments: &[String]) -> io::Result<Vec<u8>> {
        Ok(self.listing.clone())
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn run_git(git: &mut SystemGit, arguments: &[&str]) -> Vec<u8> {
    let arguments: Vec<String> = arguments.iter().map(|value| (*value).into()).collect();
    git.output_with_timeout(&arguments, Duration::from_secs(5))
        .expect("bounded local git fixture")
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture: a failed setup step must abort the test"
)]
fn git_under(root: &Path) -> SystemGit {
    let path = std::env::var_os("PATH").expect("pinned shell PATH");
    let program = std::env::split_paths(&path)
        .map(|directory| directory.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git in the pinned shell");
    SystemGit {
        program,
        ca_bundle: root.join("unused-local-ca"),
        home: root.into(),
        system_configuration: None,
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] workspace-sha256-real-git
/// Full and abbreviated SHA256 commits, advertised branches and dedicated change
/// refs MUST check out exact content with the production plan; SHA1 MUST still work.
#[test]
fn real_git_checks_out_both_object_formats() {
    let root = tempfile::tempdir().expect("fixture root");
    let mut git = git_under(root.path());
    for (format, flag, length) in [
        (ObjectFormat::Sha1, "--object-format=sha1", 40),
        (ObjectFormat::Sha256, "--object-format=sha256", 64),
    ] {
        let remote = root.path().join(format!("remote-{length}"));
        let remote_path = remote.to_str().expect("fixture path");
        run_git(
            &mut git,
            &["init", flag, "--initial-branch=main", "--", remote_path],
        );
        run_git(
            &mut git,
            &[
                "-C",
                remote_path,
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                "commit",
                "--allow-empty",
                "-m",
                "fixture",
            ],
        );
        let commit =
            String::from_utf8(run_git(&mut git, &["-C", remote_path, "rev-parse", "HEAD"]))
                .expect("ASCII object ID")
                .trim()
                .to_owned();
        assert_eq!(commit.len(), length);
        for reference in ["refs/pull/9/head", "refs/merge-requests/9/head"] {
            run_git(
                &mut git,
                &["-C", remote_path, "update-ref", reference, &commit],
            );
        }
        let listing = run_git(&mut git, &["ls-remote", "--", remote_path]);
        for (kind, url) in [
            (
                "commit",
                format!("https://github.com/fixture/repo/commit/{commit}"),
            ),
            ("branch", "https://github.com/fixture/repo/tree/main".into()),
            (
                "abbreviated",
                format!(
                    "https://github.com/fixture/repo/commit/{}",
                    commit.get(..40).unwrap()
                ),
            ),
            (
                "github-change",
                "https://github.com/fixture/repo/pull/9".into(),
            ),
            (
                "gitlab-change",
                "https://gitlab.com/fixture/repo/-/merge_requests/9".into(),
            ),
        ] {
            let source: WorkspaceSource =
                workspace_source::parse_url(&url).expect("source2 fixture");
            let mut advertised = AdvertisedGit {
                listing: listing.clone(),
            };
            let mut checkout =
                workspace_checkout::resolve(&source, &mut advertised).expect("resolved format");
            assert_eq!(checkout.object_format, format);
            assert!(matches!(
                checkout.revision,
                CheckoutRevision::Commit(_) | CheckoutRevision::Ref(_)
            ));
            checkout.url = remote_path.into();
            let destination = root.path().join(format!("checkout-{length}-{kind}"));
            for arguments in git_plan(&checkout, &destination) {
                git.output_with_timeout(&arguments, Duration::from_secs(5))
                    .expect("bounded checkout");
            }
            let actual = run_git(
                &mut git,
                &[
                    "-C",
                    destination.to_str().expect("fixture path"),
                    "rev-parse",
                    "HEAD",
                ],
            );
            assert_eq!(
                String::from_utf8(actual).expect("ASCII object ID").trim(),
                commit
            );
        }
    }
}

#[test]
fn mixed_object_formats_are_refused() {
    let listing = format!(
        "{}\trefs/heads/main\n{}\trefs/tags/main\n",
        "a".repeat(40),
        "b".repeat(64)
    );
    assert_eq!(
        workspace_checkout::select_ref("main", false, listing.as_bytes())
            .unwrap_err()
            .kind(),
        io::ErrorKind::Other,
    );
}
