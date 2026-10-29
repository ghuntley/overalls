//! Tests of native file effects (contract native-file-effects-beneath-roots).

use crate::files::{perform, Owners};
use crate::protocol::Status;
use crate::utilities::Utility;
use std::ffi::CString;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

fn native(root: &Path, utility: Utility, argv: &[&str]) -> Status {
    let argv: Vec<CString> = argv.iter().map(|a| CString::new(*a).unwrap()).collect();
    perform(
        utility,
        &argv,
        &[root.to_path_buf()],
        &Owners {
            service: rustix::process::geteuid().as_raw(),
        },
    )
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_string()
}

/// Each accepted shape performs its effect natively.
#[test]
fn native_file_effects_perform_lillys_shapes() {
    if crate::descriptor_resolution::unavailable("native_file_effects_perform_lillys_shapes") {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let p = |name: &str| text(&root.join(name));
    let me = rustix::process::geteuid().as_raw();

    assert_eq!(
        native(
            &root,
            Utility::Truncate,
            &["--size", "1048576", "--", &p("disk")]
        ),
        Status::Succeeded
    );
    assert_eq!(std::fs::metadata(p("disk")).unwrap().len(), 1_048_576);
    assert_eq!(
        native(&root, Utility::Chmod, &["444", "--", &p("disk")]),
        Status::Succeeded
    );
    assert_eq!(
        std::fs::metadata(p("disk")).unwrap().permissions().mode() & 0o777,
        0o444
    );
    // chown sets uid and gid alike; an unprivileged test user may only do
    // that when its group id equals its user id.
    let chown = native(
        &root,
        Utility::Chown,
        &[&format!("{me}:{me}"), "--", &p("disk")],
    );
    let allowed = me == 0 || rustix::process::getegid().as_raw() == me;
    assert_eq!(
        chown,
        if allowed {
            Status::Succeeded
        } else {
            Status::Failed
        }
    );
    assert_eq!(
        native(
            &root,
            Utility::Chown,
            &["--no-dereference", &format!("{me}:{me}"), "--", &p("disk")],
        ),
        chown,
    );
    assert_eq!(
        native(&root, Utility::Sync, &["--", &p("disk"), &text(&root)]),
        Status::Succeeded
    );
    assert_eq!(
        native(
            &root,
            Utility::Mv,
            &["--no-target-directory", "--", &p("disk"), &p("moved")]
        ),
        Status::Succeeded
    );
    assert!(root.join("moved").exists() && !root.join("disk").exists());
    std::fs::write(p("other"), b"x").unwrap();
    // --no-clobber keeps an existing target and succeeds, like GNU mv.
    assert_eq!(
        native(
            &root,
            Utility::Mv,
            &[
                "--no-clobber",
                "--no-target-directory",
                "--",
                &p("other"),
                &p("moved")
            ]
        ),
        Status::Succeeded
    );
    assert!(root.join("other").exists());
    assert_eq!(
        native(&root, Utility::Mkfifo, &["--mode=0600", "--", &p("fifo")]),
        Status::Succeeded
    );
    assert_eq!(
        native(&root, Utility::Rm, &["--", &p("fifo")]),
        Status::Succeeded
    );
    assert_eq!(
        native(&root, Utility::Rm, &["--", &p("fifo")]),
        Status::Failed
    );
    assert_eq!(
        native(&root, Utility::Rm, &["--force", "--", &p("fifo")]),
        Status::Succeeded
    );

    std::fs::create_dir_all(root.join("tree/a/b")).unwrap();
    std::fs::write(root.join("tree/a/b/file"), b"x").unwrap();
    std::os::unix::fs::symlink("/etc", root.join("tree/a/link")).unwrap();
    assert_eq!(
        native(&root, Utility::Rm, &["--", &p("tree")]),
        Status::Failed
    );
    assert_eq!(
        native(
            &root,
            Utility::Rm,
            &["-rf", "--one-file-system", "--", &p("tree")]
        ),
        Status::Succeeded
    );
    assert!(!root.join("tree").exists());
    assert!(Path::new("/etc").exists());
    assert_eq!(
        native(
            &root,
            Utility::Rm,
            &["-rf", "--one-file-system", "--", &p("tree")]
        ),
        Status::Succeeded
    );
}

/// Snapshot memory and state keep the native single-path ownership grammar.
#[test]
fn checkpoint_outputs_require_individual_native_ownership_requests() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let memory = text(&root.join("memory"));
    let state = text(&root.join("state"));
    std::fs::write(&memory, b"memory fixture").unwrap();
    std::fs::write(&state, b"state fixture").unwrap();
    let me = rustix::process::geteuid().as_raw();
    let owner = format!("{me}:{me}");

    // The native boundary accepts one path per request. In an unprivileged
    // fixture whose primary group differs from its uid the effect fails,
    // but the request must still pass the closed argument grammar.
    let expected = if me == 0 || rustix::process::getegid().as_raw() == me {
        Status::Succeeded
    } else {
        Status::Failed
    };
    for path in [&memory, &state] {
        assert_eq!(
            native(
                &root,
                Utility::Chown,
                &["--no-dereference", &owner, "--", path],
            ),
            expected,
        );
    }
    assert_eq!(
        native(
            &root,
            Utility::Chown,
            &["--no-dereference", &owner, "--", &memory, &state],
        ),
        Status::Setup,
    );
    assert_eq!(std::fs::read(memory).unwrap(), b"memory fixture");
    assert_eq!(std::fs::read(state).unwrap(), b"state fixture");
}

/// Paths outside the roots, symlinked components, other shapes, modes and
/// owners are refused without any effect.
#[test]
fn native_file_effects_refuse_out_of_policy_requests() {
    if crate::descriptor_resolution::unavailable(
        "native_file_effects_refuse_out_of_policy_requests",
    ) {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let base = directory.path().canonicalize().unwrap();
    let root = base.join("root");
    let outside = base.join("outside");
    std::fs::create_dir(&root).unwrap();
    std::fs::create_dir(&outside).unwrap();
    std::fs::write(outside.join("secret"), b"x").unwrap();
    std::fs::set_permissions(
        outside.join("secret"),
        std::fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    std::os::unix::fs::symlink(&outside, root.join("escape")).unwrap();
    let inside = |name: &str| text(&root.join(name));
    let secret = text(&outside.join("secret"));

    assert_eq!(
        native(&root, Utility::Chmod, &["444", "--", &secret]),
        Status::Setup
    );
    assert_eq!(
        native(
            &root,
            Utility::Chmod,
            &["444", "--", &inside("escape/secret")]
        ),
        Status::Failed
    );
    assert_eq!(
        native(&root, Utility::Rm, &["--", &inside("escape/secret")]),
        Status::Failed
    );
    assert_eq!(
        native(
            &root,
            Utility::Truncate,
            &["--size", "0", "--", &inside("escape/secret")]
        ),
        Status::Failed
    );
    assert_eq!(
        native(
            &root,
            Utility::Chmod,
            &["444", "--", &inside("../outside/secret")]
        ),
        Status::Setup
    );
    assert_eq!(
        std::fs::metadata(&secret).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(std::fs::read(&secret).unwrap(), b"x");
    // Removing the symlink itself never touches its target.
    assert_eq!(
        native(
            &root,
            Utility::Rm,
            &["-rf", "--one-file-system", "--", &inside("escape")]
        ),
        Status::Succeeded
    );
    assert!(outside.join("secret").exists());

    std::fs::write(inside("file"), b"x").unwrap();
    assert_eq!(
        native(&root, Utility::Chmod, &["4755", "--", &inside("file")]),
        Status::Setup
    );
    assert_eq!(
        native(&root, Utility::Chmod, &["777", "--", &inside("file")]),
        Status::Setup
    );
    assert_eq!(
        native(
            &root,
            Utility::Chown,
            &["1000002:1000003", "--", &inside("file")]
        ),
        Status::Setup
    );
    assert_eq!(
        native(&root, Utility::Mv, &["--", &inside("file"), &inside("x")]),
        Status::Setup
    );
    assert_eq!(
        native(&root, Utility::Rm, &["-r", "--", &inside("file")]),
        Status::Setup
    );
    assert_eq!(native(&root, Utility::Sync, &["--"]), Status::Setup);
}

fn cstrings(argv: &[&str]) -> Vec<CString> {
    argv.iter().map(|a| CString::new(*a).unwrap()).collect()
}

/// Mount requests outside the jail shapes or the roots are refused before
/// any mount call (native-jail-mounts-beneath-roots, snapshot-mount-shape).
#[test]
fn mounts_refuse_out_of_policy_requests() {
    use crate::mounts::{perform, snapshot_mount_allowed};
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    std::fs::write(root.join("file"), b"x").unwrap();
    let roots = [root.clone()];
    let inside = text(&root.join("file"));
    let refused = |utility, argv: &[&str]| perform(utility, &cstrings(argv), &roots);

    assert_eq!(
        refused(Utility::Mount, &["--bind", "--", "/etc/shadow", &inside]),
        Status::Setup
    );
    assert_eq!(
        refused(Utility::Mount, &["--bind", "--", &inside, "/etc/shadow"]),
        Status::Setup
    );
    assert_eq!(
        refused(Utility::Mount, &["--rbind", "--", &inside, &inside]),
        Status::Setup
    );
    assert_eq!(
        refused(
            Utility::Mount,
            &["-o", "remount,bind,exec,rw", "--", &inside]
        ),
        Status::Setup
    );
    assert_eq!(refused(Utility::Umount, &["--", "/"]), Status::Setup);
    assert_eq!(
        refused(Utility::Umount, &["-l", "--", &inside]),
        Status::Setup
    );
    assert_eq!(
        refused(Utility::Umount, &["--", &text(&root)]),
        Status::Setup
    );

    let target = text(&root.join("mount"));
    let allowed = |argv: &[&str]| snapshot_mount_allowed(&cstrings(argv), &roots);
    assert!(allowed(&[
        "-t",
        "zfs",
        "-o",
        "ro,nodev,nosuid,noexec",
        "tank/lilly/vm-a@backup-1",
        &target
    ]));
    assert!(!allowed(&[
        "-t",
        "zfs",
        "-o",
        "rw",
        "tank/lilly/vm-a@backup-1",
        &target
    ]));
    assert!(!allowed(&[
        "-t",
        "zfs",
        "-o",
        "ro,nodev,nosuid,noexec",
        "tank/lilly/vm-a",
        &target
    ]));
    assert!(!allowed(&[
        "-t",
        "zfs",
        "-o",
        "ro,nodev,nosuid,noexec",
        "/dev/sda1@x",
        &target
    ]));
    assert!(!allowed(&[
        "-t",
        "zfs",
        "-o",
        "ro,nodev,nosuid,noexec",
        "tank/lilly/vm-a@b",
        "/etc"
    ]));
    assert!(!allowed(&[
        "-t",
        "ext4",
        "-o",
        "ro,nodev,nosuid,noexec",
        "tank/lilly/vm-a@b",
        &target
    ]));
}

/// Lilly's ZFS shapes pass; escapes from the pool datasets do not
/// (zfs-arguments-within-pools).
#[test]
fn zfs_grammar_confines_mutations_to_pool_datasets() {
    use crate::zfs_policy::{mutation, read, Scope};
    let datasets = [b"zroot/lilly".to_vec()];
    let paths = [std::path::PathBuf::from("/var/lib/lilly/pool")];
    let scope = Scope {
        datasets: &datasets,
        paths: &paths,
    };
    let ok = |argv: &[&str]| {
        let argv: Vec<&[u8]> = argv.iter().map(|a| a.as_bytes()).collect();
        mutation(&argv, &scope)
    };
    assert!(ok(&[
        "create",
        "-o",
        "mountpoint=/var/lib/lilly/pool/templates/1",
        "-o",
        "compression=lz4",
        "-o",
        "lilly:pool=abc-1",
        "zroot/lilly/template-1"
    ]));
    assert!(ok(&[
        "snapshot",
        "-o",
        "lilly:backup_nonce=n1",
        "zroot/lilly/vm-a@backup-1"
    ]));
    assert!(ok(&["destroy", "zroot/lilly/vm-a@backup-1"]));
    assert!(ok(&[
        "set",
        "lilly:transfer_nonce=11111111-2222-4333-8444-555555555555",
        "zroot/lilly/checkpoint-a@lilly-checkpoint"
    ]));
    for property in [
        "readonly=off",
        "lilly:transfer_nonce=invalid",
        "lilly:other=abc",
    ] {
        assert!(!ok(&[
            "set",
            property,
            "zroot/lilly/checkpoint-a@lilly-checkpoint"
        ]));
    }
    assert!(ok(&["destroy", "zroot/lilly/vm-a"]));
    assert!(ok(&[
        "set",
        "readonly=off",
        "canmount=on",
        "zroot/lilly/vm-a"
    ]));
    assert!(ok(&["mount", "zroot/lilly/vm-a"]));
    assert!(ok(&["receive", "-A", "zroot/lilly/vm-a"]));

    assert!(!ok(&["destroy", "zroot/lilly"]));
    assert!(!ok(&["destroy", "zroot"]));
    assert!(!ok(&["destroy", "zroot/other/vm"]));
    assert!(!ok(&["destroy", "-r", "zroot/lilly/vm-a"]));
    assert!(!ok(&["destroy", "zroot/lillyx/vm"]));
    assert!(!ok(&["set", "setuid=on", "zroot/lilly/vm-a"]));
    assert!(!ok(&["set", "mountpoint=/etc", "zroot/lilly/vm-a"]));
    assert!(!ok(&[
        "set",
        "mountpoint=/var/lib/lilly/pool",
        "zroot/lilly/vm-a"
    ]));
    assert!(!ok(&[
        "create",
        "-o",
        "mountpoint=/var/lib/lilly/pool/../../etc",
        "zroot/lilly/x"
    ]));
    assert!(!ok(&["create", "zroot/lilly/vm-a@snap"]));
    assert!(!ok(&["snapshot", "zroot/lilly/vm-a"]));
    assert!(!ok(&["promote", "zroot/lilly/vm-a"]));
    assert!(!ok(&["set", "sharenfs=on", "zroot/lilly/vm-a"]));

    let reads = |zpool, argv: &[&str]| {
        let argv: Vec<&[u8]> = argv.iter().map(|a| a.as_bytes()).collect();
        read(zpool, &argv)
    };
    assert!(reads(false, &["list", "-Hp", "zroot"]));
    assert!(reads(true, &["status", "-jPp", "zroot"]));
    assert!(!reads(false, &["destroy", "-r", "zroot"]));
    assert!(!reads(true, &["destroy", "zroot"]));
}
