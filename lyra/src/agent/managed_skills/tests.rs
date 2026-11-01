use super::git::{git_program, Git};
use super::materialize::{extract_tree, parse_tree, resolve_commit};
use super::validate::safe_relative;
use super::*;
use crate::workspace_source;
use std::fs;
use std::time::Instant;
const THREAD: &str = "00000000-0000-7000-8000-000000000001";
const INSTALLATION: &str = "00000000-0000-7000-8000-000000000002";
const OPERATION: &str = "00000000-0000-7000-8000-000000000003";
fn arguments() -> Value {
    json!({"version":1,"thread_id":THREAD,"installation_id":INSTALLATION,"operation_id":OPERATION,"source":workspace_source::parse_url("https://github.com/example/skills").unwrap().encode(),"subdirectory":"review"})
}
#[test]
fn rejects_untrusted_arguments_and_cross_platform_path_escapes() {
    for path in [
        "../outside",
        "/absolute",
        "a/../b",
        "a\\b",
        "a/CON",
        "file:stream",
        "a/",
        "a/.git",
        "a/space ",
        "a/.",
        "a/CONIN$",
        "a/COM¹",
        "a/日本語",
    ] {
        let mut value = arguments();
        value["subdirectory"] = json!(path);
        assert!(
            validate(&serde_json::from_value(value).unwrap()).is_err(),
            "{path}"
        );
    }
    for path in ["review", "skills/review", ".agents/skills/review"] {
        assert!(safe_relative(path));
    }
    let mut value = arguments();
    value["source"]["provider"] = json!("untrusted");
    assert_eq!(
        validate(&serde_json::from_value(value).unwrap())
            .unwrap_err()
            .code(),
        "invalid_source"
    );
}
#[test]
fn tree_rejects_links_submodules_and_case_collisions() {
    let hash = "a".repeat(40);
    for bad in [
        format!("120000 blob {hash}\tlink\0"),
        format!("160000 commit {hash}\tmodule\0"),
        format!("100644 blob {hash}\tDir/a\0"),
        format!("100644 blob {hash}\t../escape\0"),
    ] {
        let tree = format!("100644 blob {hash}\tSKILL.md\0100644 blob {hash}\tdir/b\0{bad}");
        assert!(parse_tree(tree.as_bytes()).is_err());
    }
    assert_eq!(
        parse_tree(format!("100644 blob {hash}\tSKILL.md\0").as_bytes())
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn header_is_complete_and_bounded() {
    assert_eq!(
        skill_header(b"---\nname: review\ndescription: Review code\n---\nBody").unwrap(),
        "---\nname: review\ndescription: Review code\n---\n"
    );
    assert!(skill_header(b"---\nname: unfinished").is_err());
    assert!(skill_header(format!("---\n{}\n---\n", "x".repeat(MAX_HEADER)).as_bytes()).is_err());
}
#[test]
fn ambiguous_receipt_is_status_only_and_request_conflicts_refuse() {
    let tmp = tempfile::tempdir().unwrap();
    let args = arguments();
    let request: Install = serde_json::from_value(args.clone()).unwrap();
    let path = installation_path(tmp.path(), THREAD, INSTALLATION)
        .unwrap()
        .join("operations");
    secure_directory(&path).unwrap();
    let receipt = Receipt {
        version: 1,
        request_digest: hex::encode(Sha256::digest(serde_json::to_vec(&request).unwrap())),
        outcome: Outcome::Pending,
    };
    write_receipt(
        &path.join(format!("{OPERATION}.json")),
        &receipt,
        &mut || true,
    )
    .unwrap();
    assert_eq!(
        install_at(tmp.path(), &args, &mut || true).unwrap()["status"],
        "uncertain"
    );
    let mut changed = args.clone();
    changed["subdirectory"] = json!("other");
    assert_eq!(
        install_at(tmp.path(), &changed, &mut || true)
            .unwrap_err()
            .code(),
        "operation_conflict"
    );
    assert_eq!(status_at(tmp.path(), &json!({"version":1,"thread_id":THREAD,"installation_id":INSTALLATION,"operation_id":OPERATION})).unwrap()["status"], "uncertain");
}
#[test]
fn released_lock_ignores_fork_inherited_descriptor_copies() {
    let tmp = tempfile::tempdir().unwrap();
    let installation = installation_path(tmp.path(), THREAD, INSTALLATION).unwrap();
    secure_directory(&installation).unwrap();
    let held = lock_installation(&installation).unwrap();
    // A duplicate shares the open file description exactly as a child
    // forked by another thread does between fork and exec.
    let inherited = held.0.try_clone().unwrap();
    assert_eq!(
        lock_installation(&installation).unwrap_err().code(),
        "operation_in_progress",
        "a real holder still excludes other installers"
    );
    drop(held);
    // The surviving copy must not keep the installation locked.
    let next = lock_installation(&installation)
        .expect("released lock must not report operation_in_progress");
    assert_eq!(
        lock_installation(&installation).unwrap_err().code(),
        "operation_in_progress"
    );
    drop(next);
    drop(inherited);
    drop(lock_installation(&installation).unwrap());
}
#[test]
fn failed_lease_cannot_create_a_receipt() {
    let tmp = tempfile::tempdir().unwrap();
    assert_eq!(
        install_at(tmp.path(), &arguments(), &mut || false)
            .unwrap_err()
            .code(),
        "lease_lost"
    );
    assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 0);
}
#[test]
fn digest_detects_local_changes_and_is_order_independent() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("a");
    let b = tmp.path().join("b");
    secure_directory(&a).unwrap();
    secure_directory(&b).unwrap();
    fs::write(a.join("SKILL.md"), b"---\nname: x\ndescription: x\n---\n").unwrap();
    fs::write(a.join("helper"), b"first").unwrap();
    fs::write(b.join("helper"), b"first").unwrap();
    fs::write(b.join("SKILL.md"), b"---\nname: x\ndescription: x\n---\n").unwrap();
    let digest = directory_digest(&a).unwrap();
    assert_eq!(digest, directory_digest(&b).unwrap());
    fs::write(b.join("helper"), b"edited").unwrap();
    assert_ne!(digest, directory_digest(&b).unwrap());
}
#[cfg(unix)]
#[test]
fn linked_managed_paths_and_content_are_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), tmp.path().join("linked")).unwrap();
    assert_eq!(
        secure_directory(&tmp.path().join("linked/child"))
            .unwrap_err()
            .code(),
        "unsafe_path"
    );
    assert_eq!(
        directory_digest(tmp.path()).unwrap_err().code(),
        "unsafe_path"
    );
}
#[test]
fn annotated_tags_pin_the_peeled_commit() {
    let source =
        workspace_source::parse_url("https://github.com/example/skills/releases/tag/v1").unwrap();
    let tag = "a".repeat(40);
    let commit = "b".repeat(40);
    let advertised = format!("{tag}\trefs/tags/v1\n{commit}\trefs/tags/v1^{{}}\n");
    assert_eq!(
        resolve_commit(&source, advertised.as_bytes()).unwrap(),
        (commit, "sha1")
    );
}
#[cfg(unix)]
#[test]
fn extracts_real_blobs_without_running_attributes_filters_or_hooks() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    secure_directory(&home).unwrap();
    let mut alive = || true;
    let mut git = Git {
        program: git_program().unwrap(),
        root: tmp.path(),
        home: &home,
        started: Instant::now(),
        heartbeat: &mut alive,
    };
    let repo = tmp.path().join("repo");
    let repo_arg = repo.to_str().unwrap();
    git.run(&["init", "--bare", "--template=", repo_arg], 4096)
        .unwrap();
    let skill =
        b"---\nname: local\ndescription: Synthetic local skill\n---\nRun explicit instructions.\n";
    let attributes = b"* filter=should-not-run\n";
    for (name, bytes) in [
        ("SKILL.md", skill.as_slice()),
        (".gitattributes", attributes.as_slice()),
    ] {
        let fixture = tmp.path().join("fixture");
        fs::write(&fixture, bytes).unwrap();
        let object = git
            .run(
                &[
                    "--git-dir",
                    repo_arg,
                    "hash-object",
                    "-w",
                    fixture.to_str().unwrap(),
                ],
                128,
            )
            .unwrap();
        let object = std::str::from_utf8(&object).unwrap().trim();
        git.run(
            &[
                "--git-dir",
                repo_arg,
                "update-index",
                "--add",
                "--cacheinfo",
                &format!("100644,{object},{name}"),
            ],
            128,
        )
        .unwrap();
    }
    // This deliberately dangerous local filter must remain inert: the extractor
    // reads blobs, never checkout/smudge or repository scripts.
    git.run(
        &[
            "--git-dir",
            repo_arg,
            "config",
            "filter.should-not-run.smudge",
            "touch SHOULD_NOT_EXIST",
        ],
        128,
    )
    .unwrap();
    let tree = git
        .run(&["--git-dir", repo_arg, "write-tree"], 128)
        .unwrap();
    let tree = std::str::from_utf8(&tree).unwrap().trim();
    let output = tmp.path().join("output");
    extract_tree(&mut git, repo_arg, tree, &output).unwrap();
    assert_eq!(fs::read(output.join("SKILL.md")).unwrap(), skill);
    assert_eq!(fs::read(output.join(".gitattributes")).unwrap(), attributes);
    assert!(!tmp.path().join("SHOULD_NOT_EXIST").exists());
}
#[cfg(unix)]
#[test]
fn lease_loss_kills_git_process_tree_promptly() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    secure_directory(&home).unwrap();
    let started = Instant::now();
    let mut checks = 0_u32;
    let mut alive = || {
        checks += 1;
        checks < 4
    };
    let mut git = Git {
        program: git_program().unwrap(),
        root: tmp.path(),
        home: &home,
        started,
        heartbeat: &mut alive,
    };
    assert_eq!(
        git.run(&["-c", "alias.slow=!sleep 20", "slow"], 128)
            .unwrap_err()
            .code(),
        "lease_lost"
    );
    assert!(started.elapsed() < Duration::from_secs(3));
}
#[test]
fn status_reports_missing_and_preserves_edited_revisions() {
    let tmp = tempfile::tempdir().unwrap();
    let query = json!({"version":1,"thread_id":THREAD,"installation_id":INSTALLATION,"operation_id":OPERATION});
    assert_eq!(status_at(tmp.path(), &query).unwrap()["status"], "missing");
    assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 0);
    let installation = installation_path(tmp.path(), THREAD, INSTALLATION).unwrap();
    let scratch = tmp.path().join("content");
    secure_directory(&scratch).unwrap();
    let bytes = b"---\nname: local\ndescription: A local skill\n---\nbody\n";
    fs::write(scratch.join("SKILL.md"), bytes).unwrap();
    let digest = directory_digest(&scratch).unwrap();
    let path = installation.join("revisions").join(&digest);
    secure_directory(path.parent().unwrap()).unwrap();
    fs::rename(&scratch, &path).unwrap();
    let operations = installation.join("operations");
    secure_directory(&operations).unwrap();
    let receipt = Receipt {
        version: 1,
        request_digest: "a".repeat(64),
        outcome: Outcome::Installed(Installed {
            full_commit: "b".repeat(40),
            content_digest: digest,
            path: wire_path(&path).unwrap(),
            skill_digest: hex::encode(Sha256::digest(bytes)),
            skill_bytes: bytes.len() as u64,
        }),
    };
    write_receipt(
        &operations.join(format!("{OPERATION}.json")),
        &receipt,
        &mut || true,
    )
    .unwrap();
    let result = status_at(tmp.path(), &query).unwrap();
    assert_eq!(result["status"], "installed");
    assert!(serde_json::to_vec(&result).unwrap().len() < 10 * 1024);
    fs::write(path.join("SKILL.md"), "local edit").unwrap();
    assert_eq!(
        status_at(tmp.path(), &query).unwrap_err().code(),
        "local_changes"
    );
    assert_eq!(
        fs::read_to_string(path.join("SKILL.md")).unwrap(),
        "local edit"
    );
}
