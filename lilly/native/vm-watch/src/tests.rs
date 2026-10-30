use super::*;
use hegel::{generators as gs, TestCase};
use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt as _;

/// @cc [owner:ghuntley,label:verification] hegel-vm-watch-selectors
/// Generated PID texts and cgroup paths MUST be accepted exactly when the
/// independent canonical models accept them; nothing else selects a process.
#[hegel::test(test_cases = 100)]
fn pid_selector_matches_model(tc: TestCase) {
    let candidates = [
        "0", "1", "01", "42", "4194304", "4194305", "99999999", "", "-1", " 7", "7 ", "x",
    ];
    let text = if tc.draw(gs::booleans()) {
        tc.draw(gs::sampled_from(&candidates)).to_string()
    } else {
        tc.draw(gs::integers::<u32>()).to_string()
    };
    let model = !text.is_empty()
        && !text.starts_with('0')
        && text.len() <= 7
        && text.bytes().all(|b| b.is_ascii_digit())
        && text
            .parse::<u32>()
            .is_ok_and(|v| (1..=PID_MAX).contains(&v));
    assert_eq!(pid_value(&text).is_some(), model, "{text:?}");
}

/// @cc [owner:ghuntley,label:verification;security] hegel-vm-watch-cgroup-selector
/// Generated cgroup paths MUST be accepted exactly when they are strictly below
/// /sys/fs/cgroup with nonempty, non-dot segments and no trailing slash.
#[hegel::test(test_cases = 100)]
fn cgroup_selector_matches_model(tc: TestCase) {
    let segments = [
        "lilly.slice",
        "overalls-vm-1.service",
        "a",
        ".",
        "..",
        "",
        "x y",
    ];
    let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(4));
    let parts: Vec<&str> = (0..count)
        .map(|_| tc.draw(gs::sampled_from(&segments)))
        .collect();
    let trailing = tc.draw(gs::booleans());
    let mut text = format!("/sys/fs/cgroup/{}", parts.join("/"));
    if trailing {
        text.push('/');
    }
    let model = count > 0
        && !trailing
        && parts
            .iter()
            .all(|p| !p.is_empty() && *p != "." && *p != "..");
    assert_eq!(cgroup_path(&text).is_some(), model, "{text:?}");
    assert!(cgroup_path("/sys/fs/cgroupx/a").is_none());
    assert!(cgroup_path("/tmp/a").is_none());
}

/// @cc [owner:ghuntley,label:verification] hegel-vm-watch-events-membership
/// `populated` MUST read exactly the cgroup.events populated flag and `member`
/// MUST match only a canonical line equal to the PID.
#[hegel::test(test_cases = 100)]
fn events_and_membership_parse_exactly(tc: TestCase) {
    let value = tc.draw(gs::booleans());
    let frozen = tc.draw(gs::booleans());
    let events = format!(
        "populated {}\nfrozen {}\n",
        u8::from(value),
        u8::from(frozen)
    );
    assert_eq!(populated(&events), Some(value));
    assert_eq!(populated("frozen 0\n"), None);
    let pid = tc.draw(gs::integers::<u32>().min_value(1).max_value(PID_MAX));
    let other = if pid == PID_MAX { 1 } else { pid + 1 };
    assert!(member(&format!("{other}\n{pid}\n"), pid));
    assert!(!member(&format!("{other}\n"), pid));
    assert!(!member(&format!("0{pid}\n"), pid));
}

/// @cc [owner:ghuntley,label:verification;security] hegel-vm-watch-cli-lattice
/// `parse_cli` MUST select a target exactly when there are two UTF-8 arguments
/// and both `cgroup_path` and `pid_value` accept them, and the selected target
/// MUST carry exactly those component results; any other vector selects nothing.
#[hegel::test(test_cases = 200)]
fn cli_is_the_meet_of_both_selectors(tc: TestCase) {
    let cgroups = [
        "/sys/fs/cgroup/lilly.slice/overalls-vm-1.service",
        "/sys/fs/cgroup/a",
        "/sys/fs/cgroup/",
        "/sys/fs/cgroup/a/",
        "/sys/fs/cgroup/a/../b",
        "/sys/fs/cgroup/./a",
        "/sys/fs/cgroupx/a",
        "/tmp/a",
        "relative",
        "42",
    ];
    let pids = [
        "1",
        "42",
        "4194304",
        "4194305",
        "0",
        "01",
        "",
        "-1",
        " 7",
        "x",
        "/sys/fs/cgroup/a",
    ];
    let count = tc.draw(gs::integers::<usize>().max_value(4));
    let mut arguments: Vec<OsString> = Vec::with_capacity(count);
    for index in 0..count {
        let argument = match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => OsString::from(tc.draw(gs::sampled_from(&cgroups))),
            1 => OsString::from(tc.draw(gs::sampled_from(&pids))),
            2 if index == 1 => OsString::from(
                tc.draw(gs::integers::<u32>().max_value(PID_MAX + 2))
                    .to_string(),
            ),
            2 => OsString::from(format!(
                "/sys/fs/cgroup/{}",
                tc.draw(gs::text().alphabet("ab./ ").max_size(12))
            )),
            // Non-UTF-8 bytes never select a target.
            _ => OsString::from_vec(vec![b'/', 0xff, b'1']),
        };
        arguments.push(argument);
    }
    let expected = match arguments.as_slice() {
        [cgroup, pid] => cgroup
            .to_str()
            .and_then(cgroup_path)
            .zip(pid.to_str().and_then(pid_value))
            .map(|(cgroup, pid)| Target { cgroup, pid }),
        _ => None,
    };
    assert_eq!(parse_cli(&arguments), expected);
}

#[test]
fn cli_requires_exactly_two_canonical_arguments() {
    let ok = [
        OsString::from("/sys/fs/cgroup/lilly.slice/a.service"),
        OsString::from("42"),
    ];
    assert_eq!(
        parse_cli(&ok),
        Some(Target {
            cgroup: PathBuf::from("/sys/fs/cgroup/lilly.slice/a.service"),
            pid: 42
        })
    );
    assert!(parse_cli(&ok[..1]).is_none());
    let extra = [ok[0].clone(), ok[1].clone(), OsString::from("x")];
    assert!(parse_cli(&extra).is_none());
}

/// Real kernel behaviour where the build environment exposes cgroup v2: watch
/// a child in this process's own cgroup and kill it. Skips (passes) when the
/// sandbox has no readable cgroup2 mount; the NixOS vm-watch test always runs it.
#[test]
fn a_killed_child_is_reported_exited_promptly() {
    let Some(cgroup) = own_cgroup() else { return };
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .expect("sleep");
    let target = Target {
        cgroup,
        pid: child.id(),
    };
    // The kept-open peer stands in for Lilly's port: no EOF, no input.
    let (parent_read, _parent_write) = std::os::unix::net::UnixStream::pair().expect("pair");
    let handle = std::thread::spawn(move || {
        let mut out = Vec::new();
        let outcome = watch_with(&target, &mut out, &parent_read);
        (outcome, out)
    });
    std::thread::sleep(std::time::Duration::from_millis(200));
    let started = std::time::Instant::now();
    child.kill().expect("kill");
    let _ = child.wait();
    let (outcome, out) = handle.join().expect("watcher");
    assert_eq!(outcome, Outcome::Exited);
    assert_eq!(out, b"armed\n");
    assert!(started.elapsed() < std::time::Duration::from_millis(500));
}

fn own_cgroup() -> Option<PathBuf> {
    let text = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    let relative = text.lines().find_map(|line| line.strip_prefix("0::"))?;
    let path = cgroup_path(&format!("/sys/fs/cgroup{relative}"))?;
    std::fs::read_to_string(path.join("cgroup.procs")).ok()?;
    std::fs::read_to_string(path.join("cgroup.events")).ok()?;
    Some(path)
}
