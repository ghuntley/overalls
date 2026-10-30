use hegel::{generators as gs, TestCase};
use std::fs;
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;

const HELD: &str =
    "printf '%s\\n' \"$$\" > \"$1\"; while test ! -e \"$2\"; do sleep 0.01; done; printf done";

struct Owner {
    child: Child,
    pid_file: PathBuf,
    release: PathBuf,
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test"
)]
fn shell() -> PathBuf {
    let path =
        PathBuf::from(std::env::var_os("ENRICO_TEST_SHELL").expect("set pinned fixture shell"));
    assert!(
        path.is_absolute() && path.is_file(),
        "fixture shell must exist"
    );
    path
}

fn await_condition(mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !predicate() {
        assert!(Instant::now() < deadline, "native witness did not converge");
        thread::sleep(Duration::from_millis(5));
    }
}

fn retired(pid: u32) -> bool {
    match fs::read_to_string(format!("/proc/{pid}/stat")) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Ok(value) => value
            .rsplit_once(") ")
            .is_some_and(|(_, rest)| rest.starts_with("Z ") || rest.starts_with("X ")),
        _ => false,
    }
}

#[expect(
    clippy::expect_used,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test"
)]
fn spawn(
    directory: &Path,
    repository: &str,
    mode: &str,
    timeout: u64,
    limit: usize,
    script: &str,
) -> Owner {
    let pid_file = directory.join(format!("{repository}-{mode}.pid"));
    let release = directory.join(format!("{repository}-{mode}.release"));
    let child = Command::new(env!("CARGO_BIN_EXE_enrico-git-owner"))
        .args([timeout.to_string(), limit.to_string()])
        .arg(directory)
        .arg(repository)
        .arg(mode)
        .arg(shell())
        .args(["-c", script, "fixture"])
        .arg(&pid_file)
        .arg(&release)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("native owner starts");
    Owner {
        child,
        pid_file,
        release,
    }
}

impl Owner {
    /// @cc [owner:ghuntley,label:verification] complete-native-pid-witness
    /// File creation MUST NOT count as a published process witness. Wait for
    /// complete positive PID bytes before inspecting or signaling that process.
    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test"
    )]
    fn pid(&self) -> u32 {
        let mut observed: Option<u32> = None;
        await_condition(|| {
            observed = fs::read_to_string(&self.pid_file)
                .ok()
                .and_then(|value| value.trim().parse::<u32>().ok())
                .filter(|pid| *pid > 0 && i32::try_from(*pid).is_ok());
            observed.is_some()
        });
        observed.expect("complete positive PID witness")
    }

    #[expect(
        clippy::expect_used,
        reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test"
    )]
    fn finish(&mut self) -> (i32, Vec<u8>) {
        let mut status = None;
        await_condition(|| {
            status = self.child.try_wait().expect("native wait");
            status.is_some()
        });
        let mut bytes = Vec::new();
        self.child
            .stdout
            .take()
            .expect("output pipe")
            .read_to_end(&mut bytes)
            .expect("bounded fixture output");
        (
            status
                .expect("observed exit")
                .code()
                .expect("ordinary exit"),
            bytes,
        )
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        self.child.stdin.take();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                return;
            }
            thread::sleep(Duration::from_millis(5));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// @cc [owner:ghuntley,label:verification;capacity] native-configured-output-families
/// Production blob and path-scan limits MUST preserve every byte at the exact
/// limit and refuse one-byte overflow while output is concurrently drained.
#[hegel::test(test_cases = 2)]
fn configured_large_output_boundaries(tc: TestCase) {
    let selected = tc.draw(gs::integers::<usize>().max_value(1));
    for limit in [
        16_777_216_usize,
        67_108_864,
        [16_777_216, 67_108_864][selected],
    ] {
        for overflow in [false, true] {
            let directory = TempDir::new().expect("isolated native directory");
            let count = limit + usize::from(overflow);
            let script = format!("head -c {count} /dev/zero");
            let mut owner = spawn(
                directory.path(),
                "large",
                "exclusive",
                3_600_000,
                limit,
                &script,
            );
            let output = owner.child.stdout.take().expect("concurrent output pipe");
            let reader = thread::spawn(move || {
                let mut output = output;
                #[expect(
                    clippy::large_stack_arrays,
                    reason = "one 64 KiB read chunk fits the 2 MiB default test-thread stack"
                )]
                let mut buffer = [0_u8; 65_536];
                let mut count = 0_usize;
                loop {
                    let read = output.read(&mut buffer).expect("bounded output stream");
                    if read == 0 {
                        break;
                    }
                    assert!(buffer[..read].iter().all(|byte| *byte == 0));
                    count += read;
                }
                count
            });
            let mut status = None;
            await_condition(|| {
                status = owner.child.try_wait().expect("native wait");
                status.is_some()
            });
            assert_eq!(
                status.expect("observed completion").code(),
                Some(if overflow { 125 } else { 0 })
            );
            let received = reader.join().expect("independent byte oracle");
            if overflow {
                assert!(received <= limit);
            } else {
                assert_eq!(received, limit);
            }
            let mut successor = spawn(
                directory.path(),
                "large",
                "exclusive",
                10_000,
                65_536,
                "printf successor",
            );
            assert_eq!(successor.finish(), (0, b"successor".to_vec()));
        }
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] native-caller-death-successor
/// Caller EOF MUST retire the actual child and release stable locks before a
/// successor completes. The PID and output oracle MUST observe real processes.
#[hegel::test(test_cases = 6)]
fn caller_death_retires_child_before_successor(tc: TestCase) {
    let suffix = tc.draw(gs::integers::<u8>());
    let directory = TempDir::new().expect("isolated native directory");
    let repository = format!("repo-{suffix}");
    let mut owner = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        HELD,
    );
    let pid = owner.pid();
    let lock_path = directory.path().join(format!(".enrico-{repository}.lock"));
    let inode = {
        use std::os::unix::fs::MetadataExt;
        fs::metadata(&lock_path).expect("held lock").ino()
    };
    owner.child.stdin.take();
    assert_eq!(owner.finish().0, 126);
    await_condition(|| retired(pid));
    let mut successor = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        "printf successor",
    );
    assert_eq!(successor.finish(), (0, b"successor".to_vec()));
    assert_eq!(fs::metadata(lock_path).expect("stable lock").ino(), inode);
}

/// @cc [owner:ghuntley,label:verification;capacity] native-eight-slot-refusal
/// Eight held native commands MUST refuse a ninth without execution. Closing
/// one caller MUST permit exactly one successor while all other owners survive.
#[hegel::test(test_cases = 3)]
fn native_saturation_reclaims_only_released_slot(tc: TestCase) {
    let selected = tc.draw(gs::integers::<usize>().max_value(7));
    let directory = TempDir::new().expect("isolated native directory");
    let mut owners: Vec<Owner> = (0..8)
        .map(|index| {
            spawn(
                directory.path(),
                &format!("repo-{index}"),
                "exclusive",
                10_000,
                65_536,
                HELD,
            )
        })
        .collect();
    let pids: Vec<u32> = owners.iter().map(Owner::pid).collect();
    let mut refused = spawn(directory.path(), "ninth", "exclusive", 10_000, 65_536, HELD);
    assert_eq!(refused.finish(), (75, Vec::new()));
    assert!(!refused.pid_file.exists());
    let mut read = spawn(directory.path(), "repo-0", "shared", 10_000, 65_536, HELD);
    assert_eq!(read.finish(), (75, Vec::new()));
    assert!(!read.pid_file.exists());
    owners[selected].child.stdin.take();
    assert_eq!(owners[selected].finish().0, 126);
    await_condition(|| retired(pids[selected]));
    let replacement = spawn(directory.path(), "ninth", "exclusive", 10_000, 65_536, HELD);
    let replacement_pid = replacement.pid();
    assert!(!retired(replacement_pid));
    for (index, pid) in pids.iter().enumerate() {
        if index != selected {
            assert!(!retired(*pid));
        }
    }
    let mut refused_again = spawn(directory.path(), "tenth", "exclusive", 10_000, 65_536, HELD);
    assert_eq!(refused_again.finish().0, 75);
}

struct DescendantGuard(u32);

impl Drop for DescendantGuard {
    fn drop(&mut self) {
        if let Some(pid) = i32::try_from(self.0)
            .ok()
            .and_then(rustix::process::Pid::from_raw)
        {
            let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
        }
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] native-helper-kill-retained-authority
/// SIGKILL of the helper MUST kill its direct child. A surviving descendant
/// MUST retain writer authority until explicitly retired, refusing successors.
#[hegel::test(test_cases = 3)]
fn helper_kill_preserves_surviving_descendant_authority(tc: TestCase) {
    let suffix = tc.draw(gs::integers::<u8>());
    let directory = TempDir::new().expect("isolated native directory");
    let repository = format!("killed-{suffix}");
    let script = "sleep 600 & printf '%s\\n' \"$!\" > \"$1.descendant\"; printf '%s\\n' \"$$\" > \"$1\"; while test ! -e \"$2\"; do sleep 0.01; done";
    let mut owner = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        script,
    );
    let direct = owner.pid();
    let descendant = fs::read_to_string(owner.pid_file.with_extension("pid.descendant"))
        .expect("independent descendant witness")
        .trim()
        .parse::<u32>()
        .expect("numeric descendant");
    assert!(descendant > 0 && descendant != direct);
    let guard = DescendantGuard(descendant);
    owner.child.kill().expect("SIGKILL helper");
    owner.child.wait().expect("reap helper");
    await_condition(|| retired(direct));
    assert!(!retired(descendant));
    fs::remove_file(&owner.pid_file).expect("clear previous child witness");
    let mut refused = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        HELD,
    );
    assert_eq!(refused.finish(), (75, Vec::new()));
    assert!(!refused.pid_file.exists());
    drop(guard);
    await_condition(|| retired(descendant));
    let mut successor = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        "printf successor",
    );
    assert_eq!(successor.finish(), (0, b"successor".to_vec()));
}

#[derive(Clone, Copy, Debug)]
enum EscapedTrigger {
    CallerEof,
    Deadline,
    Completion,
}

/// @cc [owner:ghuntley,label:verification;recovery;capacity] escaped-native-retained-authority
/// A descendant independently witnessed in another session MUST retain its
/// repository and admission locks after unresolved cleanup. Successors MUST
/// remain refused until its actual death; neighbor owners MUST survive unchanged.
/// This local kernel property does not establish service-cgroup recovery.
#[hegel::test(test_cases = 2)]
fn escaped_session_retains_authority_until_actual_death(tc: TestCase) {
    let trigger = tc.draw(gs::sampled_from(&[
        EscapedTrigger::CallerEof,
        EscapedTrigger::Deadline,
        EscapedTrigger::Completion,
    ]));
    let neighbors = tc.draw(gs::integers::<usize>().max_value(7));
    for (trigger, neighbors) in [
        (EscapedTrigger::CallerEof, 7),
        (EscapedTrigger::Deadline, 7),
        (EscapedTrigger::Completion, 7),
        (trigger, neighbors),
    ] {
        escaped_session_history(trigger, neighbors);
    }
}

struct RetainedLocks {
    admission: usize,
    repository: usize,
}

fn retained_locks(pid: u32) -> Option<RetainedLocks> {
    let mut result = RetainedLocks {
        admission: 0,
        repository: 0,
    };
    for entry in fs::read_dir(format!("/proc/{pid}/fd")).ok()? {
        let target = fs::read_link(entry.ok()?.path()).ok()?;
        let name = target.file_name()?.to_str()?;
        #[expect(
            clippy::case_sensitive_file_extension_comparisons,
            reason = "the helper creates slot locks with the exact lowercase .lock suffix"
        )]
        let admission = name.starts_with(".enrico-git-slot-") && name.ends_with(".lock");
        if admission {
            result.admission += 1;
        }
        if name == ".enrico-escaped.lock" {
            result.repository += 1;
        }
    }
    Some(result)
}

#[expect(
    clippy::expect_used,
    clippy::too_many_lines,
    reason = "integration-test fixture helper outside #[test] that drives one complete escaped-session history; a failed fixture step must abort the calling test"
)]
fn escaped_session_history(trigger: EscapedTrigger, count: usize) {
    assert!(count <= 7);
    let setsid = PathBuf::from(
        std::env::var_os("ENRICO_TEST_SETSID").expect("set pinned session fixture utility"),
    );
    assert!(setsid.is_absolute() && setsid.is_file());
    let directory = TempDir::new().expect("isolated native directory");
    let script = r#""$ENRICO_TEST_SETSID" "$ENRICO_TEST_SHELL" -c 'exec >/dev/null 2>&1; printf "%s\n" "$$" > "$1"; exec sleep 600' fixture "$1.descendant" & while test ! -s "$1.descendant"; do sleep 0.01; done; printf '%s\n' "$$" > "$1"; while test ! -e "$2"; do sleep 0.01; done; printf done"#;
    let mut owner = spawn(
        directory.path(),
        "escaped",
        "exclusive",
        if matches!(trigger, EscapedTrigger::Deadline) {
            1_000
        } else {
            10_000
        },
        65_536,
        script,
    );
    let direct = owner.pid();
    let descendant = fs::read_to_string(owner.pid_file.with_extension("pid.descendant"))
        .expect("independent escaped PID witness")
        .trim()
        .parse::<u32>()
        .expect("numeric escaped PID");
    assert!(descendant > 0 && descendant != direct);
    let guard = DescendantGuard(descendant);
    let stat = fs::read_to_string(format!("/proc/{descendant}/stat"))
        .expect("actual escaped process metadata");
    let fields: Vec<&str> = stat
        .rsplit_once(") ")
        .expect("process name boundary")
        .1
        .split_whitespace()
        .collect();
    assert_eq!(fields[2].parse::<u32>().expect("process group"), descendant);
    assert_eq!(
        fields[3].parse::<u32>().expect("process session"),
        descendant
    );
    let mut neighbors: Vec<Owner> = (0..count)
        .map(|index| {
            spawn(
                directory.path(),
                &format!("neighbor-{index}"),
                "exclusive",
                60_000,
                65_536,
                HELD,
            )
        })
        .collect();
    let witnesses: Vec<u32> = neighbors.iter().map(Owner::pid).collect();
    match trigger {
        EscapedTrigger::CallerEof => {
            owner.child.stdin.take();
        }
        EscapedTrigger::Deadline => {}
        EscapedTrigger::Completion => {
            fs::write(&owner.release, b"release").expect("ordinary child completion");
        }
    }
    let outcome = owner.finish().0;
    let locks = retained_locks(descendant);
    let admission_fds = locks.as_ref().map(|locks| locks.admission);
    let repository_fds = locks.as_ref().map(|locks| locks.repository);
    assert_eq!(
        outcome,
        126,
        "unresolved cleanup: trigger={trigger:?}, neighbors={count}, escaped_alive={}, admission_fds={admission_fds:?}, repository_fds={repository_fds:?}",
        !retired(descendant)
    );
    await_condition(|| retired(direct));
    assert!(!retired(descendant));
    fs::remove_file(&owner.pid_file).expect("clear prior direct child witness");
    let mut refused = spawn(
        directory.path(),
        "escaped",
        "exclusive",
        10_000,
        65_536,
        HELD,
    );
    assert_eq!(refused.finish(), (75, Vec::new()));
    assert!(!refused.pid_file.exists());
    let mut read = spawn(
        directory.path(),
        "escaped",
        "shared",
        10_000,
        65_536,
        "printf independent",
    );
    assert_eq!(
        read.finish(),
        if count == 7 {
            (75, Vec::new())
        } else {
            (0, b"independent".to_vec())
        }
    );
    for (neighbor, pid) in neighbors.iter_mut().zip(&witnesses) {
        assert!(neighbor
            .child
            .try_wait()
            .expect("neighbor owner state")
            .is_none());
        assert!(!retired(*pid));
    }
    drop(guard);
    await_condition(|| retired(descendant));
    let mut successor = spawn(
        directory.path(),
        "escaped",
        "exclusive",
        10_000,
        65_536,
        "printf successor",
    );
    assert_eq!(successor.finish(), (0, b"successor".to_vec()));
    for (neighbor, pid) in neighbors.iter_mut().zip(witnesses) {
        assert!(neighbor
            .child
            .try_wait()
            .expect("preserved neighbor owner")
            .is_none());
        assert!(!retired(pid));
        neighbor.child.stdin.take();
        assert_eq!(neighbor.finish().0, 126);
        await_condition(|| retired(pid));
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] native-write-contention-readable
/// A held writer MUST refuse another writer of that repository while bounded
/// reads remain available and leave the original writer alive.
#[hegel::test(test_cases = 4)]
fn write_contention_keeps_reads_available(tc: TestCase) {
    let suffix = tc.draw(gs::integers::<u8>());
    let directory = TempDir::new().expect("isolated native directory");
    let repository = format!("repo-{suffix}");
    let mut writer = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        HELD,
    );
    let pid = writer.pid();
    let mut competing = spawn(
        directory.path(),
        &repository,
        "exclusive",
        10_000,
        65_536,
        "printf wrong",
    );
    assert_eq!(competing.finish(), (75, Vec::new()));
    let mut reader = spawn(
        directory.path(),
        &repository,
        "shared",
        10_000,
        65_536,
        "printf retained",
    );
    assert_eq!(reader.finish(), (0, b"retained".to_vec()));
    assert!(!retired(pid));
    fs::write(&writer.release, b"release").expect("release held writer");
    assert_eq!(writer.finish(), (0, b"done".to_vec()));
    await_condition(|| retired(pid));
}

/// @cc [owner:ghuntley,label:verification;capacity] native-timeout-and-output-bound
/// Deadline and overflow refusal MUST retire actual children; exact-limit
/// output MUST preserve every byte and report the real successful exit.
#[hegel::test(test_cases = 5)]
fn command_limits_retire_owner_and_preserve_exact_boundary(tc: TestCase) {
    let limit = tc.draw(gs::sampled_from(&[1_usize, 7, 8, 9, 255, 256, 257]));
    let directory = TempDir::new().expect("isolated native directory");
    let mut timed = spawn(directory.path(), "timeout", "exclusive", 1_000, limit, HELD);
    let pid = timed.pid();
    assert_eq!(timed.finish().0, 124);
    await_condition(|| retired(pid));
    for (size, expected) in [(limit, 0), (limit + 1, 125)] {
        let script = format!("head -c {size} /dev/zero");
        let mut output = spawn(
            directory.path(),
            "output",
            "exclusive",
            10_000,
            limit,
            &script,
        );
        let (status, bytes) = output.finish();
        assert_eq!(status, expected);
        if expected == 0 {
            assert_eq!(bytes, vec![0; size]);
        } else {
            assert!(bytes.len() <= limit);
        }
    }
}

/// @cc [owner:ghuntley,label:verification;security] native-lock-inode-refusal
/// Linked or nonprivate repository lock inodes MUST refuse before utility
/// execution without changing the supplied inode or its contents.
#[hegel::test(test_cases = 6)]
fn insecure_repository_locks_refuse_without_execution(tc: TestCase) {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let kind = tc.draw(gs::integers::<u8>().max_value(2));
    let directory = TempDir::new().expect("isolated native directory");
    let source = directory.path().join("source");
    let lock_path = directory.path().join(".enrico-repo.lock");
    fs::write(&source, b"untouched").expect("witness file");
    fs::set_permissions(&source, fs::Permissions::from_mode(0o600)).expect("private witness");
    match kind {
        0 => symlink(&source, &lock_path).expect("linked witness"),
        1 => fs::hard_link(&source, &lock_path).expect("hard-linked witness"),
        _ => {
            fs::rename(&source, &lock_path).expect("lock witness");
            fs::set_permissions(&lock_path, fs::Permissions::from_mode(0o644))
                .expect("nonprivate witness");
        }
    }
    let mut owner = spawn(directory.path(), "repo", "exclusive", 10_000, 65_536, HELD);
    assert_eq!(owner.finish(), (126, Vec::new()));
    assert!(!owner.pid_file.exists());
    assert_eq!(
        fs::read(&lock_path).expect("unchanged witness"),
        b"untouched"
    );
}

/// @cc [owner:ghuntley,label:verification;recovery] native-blocked-output-caller-death
/// Caller EOF MUST retire the child even after the helper's actual stdout pipe
/// is full; a successor MUST regain the same repository's write authority.
#[hegel::test(test_cases = 4)]
fn blocked_output_still_observes_caller_death(tc: TestCase) {
    let initial = tc.draw(gs::sampled_from(&[0_usize, 1, 4096, 65_536]));
    let directory = TempDir::new().expect("isolated native directory");
    let script = "printf '%s\\n' \"$$\" > \"$1\"; exec head -c 16777216 /dev/zero";
    let mut owner = spawn(
        directory.path(),
        "blocked",
        "exclusive",
        10_000,
        16_777_216,
        script,
    );
    let pid = owner.pid();
    if initial > 0 {
        let mut bytes = vec![0; initial];
        owner
            .child
            .stdout
            .as_mut()
            .expect("output pipe")
            .read_exact(&mut bytes)
            .expect("initial output");
        assert_eq!(bytes, vec![0; initial]);
    }
    let output = owner.child.stdout.as_ref().expect("output pipe");
    let probe = rustix::fs::open(
        format!("/proc/{}/fd/1", owner.child.id()),
        rustix::fs::OFlags::WRONLY | rustix::fs::OFlags::NONBLOCK,
        rustix::fs::Mode::empty(),
    )
    .expect("controlled output pipe witness");
    assert_eq!(
        rustix::fs::fstat(&probe).expect("writer identity").st_ino,
        rustix::fs::fstat(output).expect("reader identity").st_ino
    );
    await_condition(|| {
        let mut descriptors = [rustix::event::PollFd::new(
            &probe,
            rustix::event::PollFlags::OUT,
        )];
        rustix::event::poll(
            &mut descriptors,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 0,
            }),
        )
        .expect("pipe readiness");
        rustix::io::ioctl_fionread(output).expect("actual queued bytes") > 0
            && !descriptors[0]
                .revents()
                .contains(rustix::event::PollFlags::OUT)
    });
    drop(probe);
    owner.child.stdin.take();
    assert_eq!(owner.finish().0, 126);
    await_condition(|| retired(pid));
    let mut successor = spawn(
        directory.path(),
        "blocked",
        "exclusive",
        10_000,
        65_536,
        "printf successor",
    );
    assert_eq!(successor.finish(), (0, b"successor".to_vec()));
}

/// @cc [owner:ghuntley,label:verification;recovery] native-descendant-group-retirement
/// Caller EOF, deadline and ordinary completion MUST stop both the direct
/// child and its independently recorded background descendant before a successor.
#[hegel::test(test_cases = 2)]
fn private_group_descendants_retire_before_successor(tc: TestCase) {
    let generated = tc.draw(gs::integers::<usize>().max_value(2));
    for effect in [0_usize, 1, 2, generated] {
        let directory = TempDir::new().expect("isolated native directory");
        let script = "sleep 600 & printf '%s\\n' \"$!\" > \"$1.descendant\"; printf '%s\\n' \"$$\" > \"$1\"; while test ! -e \"$2\"; do sleep 0.01; done; printf done";
        let mut owner = spawn(
            directory.path(),
            "tree",
            "exclusive",
            if effect == 1 { 1_000 } else { 10_000 },
            65_536,
            script,
        );
        let pid = owner.pid();
        let descendant = fs::read_to_string(owner.pid_file.with_extension("pid.descendant"))
            .expect("independent descendant witness")
            .trim()
            .parse::<u32>()
            .expect("numeric descendant");
        assert!(descendant > 0 && descendant != pid);
        assert!(!retired(descendant));
        match effect {
            0 => {
                owner.child.stdin.take();
            }
            1 => {}
            _ => {
                fs::write(&owner.release, b"release").expect("ordinary completion");
            }
        }
        assert_eq!(owner.finish().0, [126, 124, 0][effect]);
        await_condition(|| {
            !PathBuf::from(format!("/proc/{pid}")).exists()
                && !PathBuf::from(format!("/proc/{descendant}")).exists()
        });
        let mut successor = spawn(
            directory.path(),
            "tree",
            "exclusive",
            10_000,
            65_536,
            "printf successor",
        );
        assert_eq!(successor.finish(), (0, b"successor".to_vec()));
    }
}

/// @cc [owner:ghuntley,label:verification;security] native-cli-invalid-before-effects
/// Invalid time/output/path/repository/mode/executable schemas MUST return
/// usage refusal before creating lock files or executing a child.
#[hegel::test(test_cases = 4)]
fn invalid_cli_refuses_before_lock_or_child_effects(tc: TestCase) {
    let timeout = tc.draw(gs::sampled_from(&[
        "0",
        "3600001",
        "18446744073709551615",
        "invalid",
    ]));
    let directory = TempDir::new().expect("isolated native directory");
    let baseline = vec![
        "1000".to_owned(),
        "65536".to_owned(),
        directory.path().to_str().expect("fixture path").to_owned(),
        "repo".to_owned(),
        "exclusive".to_owned(),
        shell().to_str().expect("fixture executable").to_owned(),
        "-c".to_owned(),
        "printf wrong".to_owned(),
    ];
    for (index, invalid) in [
        (0, timeout),
        (1, "0"),
        (1, "67108865"),
        (2, "relative"),
        (3, "."),
        (3, ".."),
        (3, "../repo"),
        (4, "invalid"),
        (5, "relative-executable"),
    ] {
        let mut arguments = baseline.clone();
        arguments[index] = invalid.to_owned();
        let output = Command::new(env!("CARGO_BIN_EXE_enrico-git-owner"))
            .args(arguments)
            .output()
            .expect("invalid invocation returns");
        assert_eq!(output.status.code(), Some(64));
        assert!(output.stdout.is_empty() && output.stderr.is_empty());
        assert_eq!(
            fs::read_dir(directory.path())
                .expect("exact fixture inventory")
                .count(),
            0
        );
    }
}
