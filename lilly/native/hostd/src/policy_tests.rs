//! Tests of the utility argument grammar (contract utility-arguments-grammar),
//! using the argv shapes Lilly sends today.

use crate::policy::{check, Context, Decision};
use crate::utilities::{Table, Utility};
use crate::zfs_policy::Scope;
use std::ffi::{CString, OsString};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

const NS: &str = "lilly-0123456789ab";
const UPLINK: &str = "lu0123456789ab";
const TAP: &str = "lvabcdef012345";

struct Fixture {
    _directory: tempfile::TempDir,
    bin: PathBuf,
    table: Table,
}

fn fixture() -> Fixture {
    let directory = tempfile::tempdir().unwrap();
    let bin = directory.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    for name in ["ip", "nft", "sysctl", "lilly-flow-label"] {
        let path = bin.join(name);
        std::fs::write(&path, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let table = Table::resolve(&OsString::from(&bin));
    Fixture {
        _directory: directory,
        bin,
        table,
    }
}

fn decide(fixture: &Fixture, utility: Utility, argv: &[&str]) -> Decision {
    let roots = [
        PathBuf::from("/var/lib/lilly"),
        PathBuf::from("/var/lib/lilly/pool"),
        PathBuf::from("/run/lilly-clone-copies"),
        PathBuf::from("/run/overalls-backups"),
    ];
    let datasets = [b"zroot/lilly".to_vec()];
    let paths = [PathBuf::from("/var/lib/lilly/pool")];
    let context = Context {
        file_roots: &roots,
        scope: Scope {
            datasets: &datasets,
            paths: &paths,
        },
        utilities: &fixture.table,
        private: None,
        request: 1,
    };
    let argv: Vec<CString> = argv.iter().map(|a| CString::new(*a).unwrap()).collect();
    check(utility, &argv, &context)
}

fn ok(fixture: &Fixture, utility: Utility, argv: &[&str]) -> bool {
    !matches!(decide(fixture, utility, argv), Decision::Refuse)
}

#[test]
fn lillys_shapes_are_accepted() {
    let f = fixture();
    fn ns(rest: &[&'static str]) -> Vec<&'static str> {
        let mut argv = vec!["netns", "exec", NS, "/nix/store/x-iproute2/bin/ip"];
        argv.extend_from_slice(rest);
        argv
    }
    for argv in [
        vec!["netns", "list"],
        vec!["netns", "add", NS],
        vec!["netns", "delete", NS],
        vec!["netns", "pids", NS],
        vec!["-j", "link", "show"],
        vec!["-j", "-4", "addr", "show"],
        vec!["-j", "-d", "link", "show", "dev", UPLINK],
        vec![
            "link", "add", UPLINK, "type", "veth", "peer", "name", "uplink", "netns", NS,
        ],
        vec![
            "link",
            "set",
            "dev",
            UPLINK,
            "alias",
            "lilly:11111111-2222-4333-8444-555555555555",
        ],
        vec!["link", "delete", UPLINK],
        vec!["addr", "replace", "169.254.255.1/30", "dev", UPLINK],
        vec!["link", "set", UPLINK, "up"],
        ns(&["-d", "-j", "link", "show"]),
        ns(&["-j", "route", "show", "exact", "10.1.0.5/32"]),
        ns(&["addr", "replace", "10.1.0.1/32", "dev", TAP]),
        ns(&["link", "set", "dev", TAP, "up"]),
        ns(&["link", "set", "dev", TAP, "address", "02:fc:00:14:00:01"]),
        ns(&["link", "set", "lo", "up"]),
        ns(&[
            "tuntap", "add", "dev", TAP, "mode", "tap", "user", "1000010",
        ]),
        ns(&["tuntap", "del", "dev", TAP, "mode", "tap"]),
        ns(&[
            "route",
            "replace",
            "default",
            "via",
            "169.254.255.1",
            "dev",
            "uplink",
        ]),
        ns(&[
            "route",
            "replace",
            "10.1.0.5/32",
            "dev",
            TAP,
            "scope",
            "link",
        ]),
        ns(&[
            "route",
            "replace",
            "local",
            "0.0.0.0/0",
            "dev",
            "lo",
            "table",
            "1111",
        ]),
        ns(&[
            "rule",
            "add",
            "priority",
            "1111",
            "fwmark",
            "0x42524144/0xffffffff",
            "lookup",
            "1111",
        ]),
        ns(&[
            "link",
            "set",
            "dev",
            TAP,
            "alias",
            "lilly:11111111-2222-4333-8444-555555555555:10.1.0.5:1000010",
        ]),
    ] {
        assert!(ok(&f, Utility::Ip, &argv), "{argv:?}");
    }
    assert!(ok(&f, Utility::Nft, &["--json", "list", "tables"]));
    assert!(ok(
        &f,
        Utility::Ip,
        &[
            "netns",
            "exec",
            NS,
            "/nix/store/y/bin/nft",
            "-j",
            "list",
            "table",
            "inet",
            "guard_abc"
        ]
    ));
    assert!(ok(
        &f,
        Utility::Ip,
        &[
            "netns",
            "exec",
            NS,
            "/nix/store/y/bin/sysctl",
            "-qw",
            "net.ipv4.ip_forward=1",
            "net.ipv4.conf.all.rp_filter=1",
            "net.ipv4.conf.all.arp_announce=2",
            "net.ipv4.conf.default.arp_announce=2"
        ]
    ));
    assert!(ok(
        &f,
        Utility::Ip,
        &[
            "netns",
            "exec",
            NS,
            "/nix/store/y/bin/lilly-flow-label",
            "10.1.0.5",
            "40000",
            "10.1.0.1",
            "443"
        ]
    ));
    assert!(ok(&f, Utility::Sysctl, &["-n", "net.ipv4.ip_forward"]));
    assert!(ok(
        &f,
        Utility::Sysctl,
        &[
            "-qw",
            &format!("net.ipv6.conf.{UPLINK}.disable_ipv6=1"),
            &format!("net.ipv4.conf.{UPLINK}.accept_source_route=0")
        ]
    ));
    for argv in [
        vec!["show", "lilly.slice", "--property=ActiveState", "--value"],
        vec![
            "show",
            "--property=Id",
            "--value",
            "--no-pager",
            "lilly-vm-*.service",
        ],
        vec![
            "stop",
            "lilly-vm-11111111-2222-4333-8444-555555555555.service",
        ],
        vec![
            "kill",
            "--kill-who=all",
            "--signal=KILL",
            "lilly-vm-11111111-2222-4333-8444-555555555555.service",
        ],
        vec![
            "show",
            "lilly-vm-11111111-2222-4333-8444-555555555555.service",
            "--property=ActiveState",
            "--property=ControlGroup",
        ],
        vec![
            "list-units",
            "--all",
            "--plain",
            "--no-legend",
            "--no-pager",
            "lilly-vm-11111111-2222-4333-8444-555555555555.service",
        ],
    ] {
        assert!(ok(&f, Utility::Systemctl, &argv), "{argv:?}");
    }
    assert!(ok(
        &f,
        Utility::Cp,
        &[
            "--archive",
            "--no-target-directory",
            "--",
            "/var/lib/lilly/pool/.lilly-zfs",
            "/run/overalls-backups/pools/abc"
        ]
    ));
    assert!(ok(
        &f,
        Utility::ImageCopy,
        &[
            "copy",
            "/nix/store/x-image/rootfs.ext4",
            "/var/lib/lilly/pool/templates/1/rootfs.ext4.pending",
            "4096"
        ]
    ));
    assert!(ok(
        &f,
        Utility::ImageCopy,
        &[
            "auto",
            "/var/lib/lilly/pool/templates/1/rootfs.ext4",
            "/var/lib/lilly/pool/vms/a/.rootfs.pending",
            "4096",
            "/var/lib/lilly/pool/.lilly-templates/locks/ab/owner.lock"
        ]
    ));
    assert!(ok(
        &f,
        Utility::ImageCopy,
        &[
            "snapshot",
            "/run/lilly-clone-copies/r/rootfs.ext4",
            "/var/lib/lilly/pool/vms/a/.clone-rootfs.ext4",
            "4096",
            "1000010"
        ]
    ));
    assert!(ok(
        &f,
        Utility::SshKeygen,
        &[
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "",
            "-f",
            "/var/lib/lilly/transfer/id_ed25519"
        ]
    ));
    assert!(ok(
        &f,
        Utility::ZfsNamespaceUnmount,
        &["zroot/lilly/vm-a", "/var/lib/lilly/pool/vms/a"]
    ));
    assert!(ok(&f, Utility::KvmProbe, &[]));
}

/// Lifecycle operations MUST target one exact VM unit, never a slice, wildcard,
/// another service or a broader signal/target grammar.
#[test]
fn systemctl_lifecycle_cannot_expand_past_one_vm() {
    let f = fixture();
    let vm = "lilly-vm-11111111-2222-4333-8444-555555555555.service";
    for target in [
        "lilly.slice",
        "lilly-vm-*.service",
        "sshd.service",
        "lilly-vm-other.service",
        "lilly-vm-11111111-2222-4333-8444-555555555555.scope",
    ] {
        assert!(!ok(&f, Utility::Systemctl, &["stop", target]));
        assert!(!ok(
            &f,
            Utility::Systemctl,
            &["kill", "--kill-who=all", "--signal=KILL", target]
        ));
    }
    for argv in [
        vec!["stop", vm, vm],
        vec!["kill", "--kill-who=all", "--signal=KILL", vm, vm],
        vec!["kill", "--kill-who=main", "--signal=KILL", vm],
        vec!["kill", "--kill-who=all", "--signal=TERM", vm],
        vec!["kill", vm],
        vec!["restart", vm],
    ] {
        assert!(!ok(&f, Utility::Systemctl, &argv));
    }
}

#[test]
fn escapes_are_refused() {
    let f = fixture();
    let refused = |utility, argv: &[&str]| !ok(&f, utility, argv);
    // Namespaced execution of anything but the four utilities, or outside Lilly's namespaces.
    assert!(refused(
        Utility::Ip,
        &["netns", "exec", NS, "/bin/sh", "-c", "id"]
    ));
    assert!(refused(
        Utility::Ip,
        &[
            "netns",
            "exec",
            "other",
            "/nix/store/x/bin/ip",
            "link",
            "show"
        ]
    ));
    assert!(refused(
        Utility::Ip,
        &[
            "netns",
            "exec",
            NS,
            "/nix/store/x/bin/ip",
            "netns",
            "exec",
            NS,
            "/bin/sh"
        ]
    ));
    // Host devices and namespaces are out of reach.
    assert!(refused(Utility::Ip, &["link", "delete", "eth0"]));
    assert!(refused(Utility::Ip, &["link", "set", "eth0", "down"]));
    assert!(refused(Utility::Ip, &["netns", "delete", "other"]));
    assert!(refused(
        Utility::Ip,
        &["route", "replace", "default", "via", "1.2.3.4", "dev", "eth0"]
    ));
    assert!(refused(Utility::Ip, &["-j", "link", "set", "eth0", "down"]));
    // Gateway MAC changes stay on namespaced guest taps and locally administered unicast.
    let ns_ip = |rest: &[&'static str]| {
        let mut argv = vec!["netns", "exec", NS, "/nix/store/x-iproute2/bin/ip"];
        argv.extend_from_slice(rest);
        argv
    };
    assert!(refused(
        Utility::Ip,
        &["link", "set", "dev", TAP, "address", "02:fc:00:14:00:01"]
    ));
    for (device, mac) in [
        ("uplink", "02:fc:00:14:00:01"),
        ("lo", "02:fc:00:14:00:01"),
        ("eth0", "02:fc:00:14:00:01"),
        (TAP, "00:fc:00:14:00:01"),
        (TAP, "03:fc:00:14:00:01"),
        (TAP, "02:FC:00:14:00:01"),
        (TAP, "02:fc:00:14:00"),
        (TAP, "02:fc:00:14:00:01:02"),
        (TAP, "02:fc:00:14:00:0g"),
    ] {
        assert!(refused(
            Utility::Ip,
            &ns_ip(&["link", "set", "dev", device, "address", mac])
        ));
    }
    assert!(refused(Utility::Ip, &["-batch", "/tmp/x"]));
    assert!(refused(Utility::Nft, &["flush", "ruleset"]));
    assert!(refused(Utility::Nft, &["--file", "/etc/nftables.conf"]));
    assert!(refused(Utility::Sysctl, &["-qw", "kernel.modprobe=/tmp/x"]));
    assert!(refused(Utility::Sysctl, &["-qw", "net.ipv4.ip_forward=1"]));
    assert!(refused(
        Utility::Sysctl,
        &["-qw", "net.ipv4.conf.eth0.rp_filter=0"]
    ));
    assert!(refused(
        Utility::Sysctl,
        &["-qw", "net.ipv4.conf.eth0.arp_announce=2"]
    ));
    assert!(refused(Utility::Systemctl, &["stop", "sshd.service"]));
    assert!(refused(
        Utility::Systemctl,
        &[
            "start",
            "lilly-vm-11111111-2222-4333-8444-555555555555.service"
        ]
    ));
    assert!(refused(Utility::Systemctl, &["stop", "lilly-vm-*.service"]));
    assert!(refused(Utility::Systemctl, &["show", "sshd.service"]));
    assert!(refused(
        Utility::Cp,
        &[
            "--archive",
            "--no-target-directory",
            "--",
            "/etc",
            "/run/overalls-backups/pools/abc"
        ]
    ));
    assert!(refused(
        Utility::ImageCopy,
        &["copy", "/nix/store/x/rootfs.ext4", "/etc/shadow", "4096"]
    ));
    assert!(refused(
        Utility::SshKeygen,
        &[
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "",
            "-f",
            "/root/.ssh/id_ed25519"
        ]
    ));
    assert!(refused(
        Utility::ZfsNamespaceUnmount,
        &["zroot/other", "/var/lib/lilly/pool/vms/a"]
    ));
    assert!(refused(Utility::KvmProbe, &["--anything"]));
    assert!(refused(Utility::Zpool, &["destroy", "zroot"]));
    assert!(refused(Utility::Zfs, &["destroy", "-r", "zroot"]));
}

#[test]
fn systemctl_lifecycle_is_limited_to_one_exact_vm_service() {
    let f = fixture();
    let unit = "lilly-vm-11111111-2222-4333-8444-555555555555.service";
    assert!(ok(&f, Utility::Systemctl, &["stop", unit]));
    assert!(ok(
        &f,
        Utility::Systemctl,
        &["kill", "--kill-who=all", "--signal=KILL", unit]
    ));
    for name in [
        "lilly.slice",
        "lilly-vm-*.service",
        "lilly-vm-invalid.service",
        "lilly-vm-11111111-2222-4333-8444-555555555555.scope",
        "sshd.service",
        "--all",
        "",
    ] {
        assert!(!ok(&f, Utility::Systemctl, &["stop", name]));
        assert!(!ok(
            &f,
            Utility::Systemctl,
            &["kill", "--kill-who=all", "--signal=KILL", name]
        ));
    }
    assert!(!ok(&f, Utility::Systemctl, &["stop", unit, unit]));
    assert!(!ok(
        &f,
        Utility::Systemctl,
        &["kill", "--kill-who=all", "--signal=KILL", unit, unit]
    ));
}

#[test]
fn namespaced_executables_are_replaced_by_hostds_own() {
    let f = fixture();
    match decide(
        &f,
        Utility::Ip,
        &[
            "netns",
            "exec",
            NS,
            "/home/attacker/nft",
            "--file",
            "/var/lib/lilly/network/x.nft",
        ],
    ) {
        Decision::Rewrite(argv) => {
            assert_eq!(
                argv[3].as_bytes(),
                f.bin.join("nft").as_os_str().as_encoded_bytes()
            );
            assert_eq!(argv[4].as_bytes(), b"--file");
        }
        other => panic!("expected a rewrite, got {other:?}"),
    }
}

const ROOT_RULES: &str = "add table inet lilly_0123456789ab_filter
delete table inet lilly_0123456789ab_filter
table inet lilly_0123456789ab_filter {
  chain forward { type filter hook forward priority 0; policy accept; }
}
add table ip lilly_0123456789ab_nat
delete table ip lilly_0123456789ab_nat
table ip lilly_0123456789ab_nat {
  chain postrouting { type nat hook postrouting priority 100; }
}
";

/// Host-namespace rule files may touch only Lilly's own tables
/// (host-nft-own-tables-only).
#[test]
fn host_rule_files_touch_only_lillys_tables() {
    use crate::nft_policy::host_rules;
    assert!(host_rules(ROOT_RULES));
    assert!(host_rules(
        "add table inet lilly_0123456789ab_filter\ndelete table inet lilly_0123456789ab_filter\n"
    ));
    assert!(!host_rules("flush ruleset\n"));
    assert!(!host_rules("delete table inet filter\n"));
    assert!(!host_rules("table inet nixos-fw {\n}\n"));
    assert!(!host_rules("include \"/etc/nftables.conf\"\n"));
    assert!(!host_rules("table inet lilly_0123456789ab_filter {\n"));
    assert!(!host_rules("}\ntable inet filter {\n}\n"));
    assert!(!host_rules("add table netdev lilly_0123456789ab_filter\n"));
}

/// The checked bytes, not the caller's file, are what nft loads.
#[test]
fn host_rule_files_load_from_a_private_checked_copy() {
    if crate::descriptor_resolution::unavailable("host_rule_files_load_from_a_private_checked_copy")
    {
        return;
    }
    let f = fixture();
    let directory = tempfile::tempdir().unwrap();
    let base = directory.path().canonicalize().unwrap();
    let state = base.join("state");
    let private = base.join("private");
    std::fs::create_dir(&state).unwrap();
    std::fs::create_dir(&private).unwrap();
    let file = state.join("root.nft");
    std::fs::write(&file, ROOT_RULES).unwrap();
    let roots = [state.clone()];
    let datasets = [b"zroot/lilly".to_vec()];
    let context = Context {
        file_roots: &roots,
        scope: Scope {
            datasets: &datasets,
            paths: &[],
        },
        utilities: &f.table,
        private: Some(&private),
        request: 7,
    };
    let argv = |path: &std::path::Path| {
        vec![
            CString::new("--file").unwrap(),
            CString::new(path.as_os_str().as_encoded_bytes()).unwrap(),
        ]
    };
    match check(Utility::Nft, &argv(&file), &context) {
        Decision::Rewrite(rewritten) => {
            let copy = private.join("nft-7.nft");
            assert_eq!(rewritten[1].as_bytes(), copy.as_os_str().as_encoded_bytes());
            assert_eq!(std::fs::read_to_string(&copy).unwrap(), ROOT_RULES);
        }
        other => panic!("expected the checked copy, got {other:?}"),
    }
    std::fs::write(&file, "flush ruleset\n").unwrap();
    assert_eq!(
        check(Utility::Nft, &argv(&file), &context),
        Decision::Refuse
    );
    assert_eq!(
        check(
            Utility::Nft,
            &argv(std::path::Path::new("/etc/nftables.conf")),
            &context
        ),
        Decision::Refuse
    );
}
