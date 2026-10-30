use super::*;
use crate::log::open_log;
use crate::run::{drain, settle};
use hegel::{generators as gs, TestCase};
use rustix::pipe::{pipe_with, PipeFlags};
use std::ffi::OsStr;
use std::ffi::OsString;
use std::os::unix::fs::MetadataExt as _;
use std::os::unix::process::ExitStatusExt as _;
use std::process::{Command as Process, Stdio};
use std::time::Duration;

/// @cc [owner:ghuntley,label:verification] hegel-boot-log-selector-oracle
/// Generated argument vectors MUST be classified by the independent selector
/// spec: an optional leading `--reader-uid N` (N decimal, 1..=4294967294),
/// then exactly an absolute log path and absolute command, plus extra argv.
#[hegel::test(test_cases = 100)]
fn cli_selector_matches_independent_oracle(tc: TestCase) {
    let alphabet = [
        "",
        "/",
        "/log",
        "log",
        "relative",
        "/usr/bin/vm",
        "vm",
        "/x y",
        "--reader-uid",
        "377",
        "0",
        "+1",
        "4294967294",
        "4294967295",
    ];
    let length = tc.draw(gs::integers::<usize>().min_value(0).max_value(7));
    let words: Vec<String> = (0..length)
        .map(|_| tc.draw(gs::sampled_from(&alphabet)).to_string())
        .collect();
    let decimal = |word: &str| {
        (!word.is_empty() && word.bytes().all(|b| b.is_ascii_digit()))
            .then(|| word.parse::<u64>().ok())
            .flatten()
            .filter(|uid| (1..=4_294_967_294).contains(uid))
    };
    let (reader, positional): (Option<Option<u64>>, &[String]) =
        if words.first().map(String::as_str) == Some("--reader-uid") {
            match words.get(1).and_then(|word| decimal(word)) {
                Some(uid) => (Some(Some(uid)), &words[2..]),
                None => (None, &[]),
            }
        } else {
            (Some(None), &words[..])
        };
    let ok = reader.is_some()
        && positional.len() >= 2
        && positional[0].starts_with('/')
        && positional[1].starts_with('/');
    match (
        parse_cli(&words.iter().map(OsString::from).collect::<Vec<_>>()),
        ok,
    ) {
        (None, false) => {}
        (Some(request), true) => {
            assert_eq!(request.reader.map(u64::from), reader.flatten());
            assert_eq!(request.log.as_os_str(), OsStr::new(positional[0].as_str()));
            assert_eq!(
                request.program.as_os_str(),
                OsStr::new(positional[1].as_str())
            );
            let rest: Vec<String> = request
                .arguments
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect();
            assert_eq!(rest, positional[2..].to_vec());
        }
        (parsed, ok) => panic!("selector diverged from oracle: {parsed:?} ok={ok}"),
    }
}

/// @cc [owner:ghuntley,label:verification;capacity] hegel-boot-log-drain-bounded-prefix
/// Draining a generated stream through a real pipe MUST persist exactly the
/// BOOT_LOG_LIMIT-truncated prefix of the independently stamped stream, for
/// sizes around the pipe window and up to three times the limit.
#[hegel::test(test_cases = 100)]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the byte pattern deliberately keeps the low eight bits of a mixed index"
)]
fn drain_retains_exactly_the_bounded_prefix(tc: TestCase) {
    use std::io::Write as _;
    let size = tc.draw(hegel::one_of!(
        gs::integers::<usize>().min_value(0).max_value(4096),
        gs::integers::<usize>()
            .min_value(65530)
            .max_value(65536 + 6),
        gs::integers::<usize>()
            .min_value(BOOT_LOG_LIMIT - 66)
            .max_value(BOOT_LOG_LIMIT + 66),
        gs::integers::<usize>()
            .min_value(BOOT_LOG_LIMIT)
            .max_value(BOOT_LOG_LIMIT * 3),
    ));
    let seed = tc.draw(gs::integers::<u64>());
    let pattern = move |index: usize| ((index as u64).wrapping_mul(2_654_435_761) ^ seed) as u8;

    let (reader, writer) = pipe_with(PipeFlags::CLOEXEC).expect("pipe");
    let expected: Vec<u8> = (0..size).map(pattern).collect();
    let writer_bytes = expected.clone();
    let writer_thread = std::thread::spawn(move || {
        let mut file = std::fs::File::from(writer);
        file.write_all(&writer_bytes).expect("write side");
    });
    let directory = tempfile::tempdir().expect("fixture directory");
    let path = directory.path().join("boot.log.raw");
    let mut output = std::fs::File::create(&path).expect("log file");
    let fixed = Duration::from_millis(1234);
    assert_eq!(drain(&reader, &mut output, &|| fixed), Drained::Complete);
    writer_thread.join().expect("writer joined");
    let kept = std::fs::read(&path).expect("kept bytes");
    let stamped = oracle_stamp(&expected, fixed);
    assert_eq!(kept.len(), stamped.len().min(BOOT_LOG_LIMIT));
    assert_eq!(kept, stamped[..stamped.len().min(BOOT_LOG_LIMIT)]);
}

/// Independent line-splitting oracle for boot-log-line-timestamps: split on
/// CR/LF terminators and prefix every non-empty segment.
fn oracle_stamp(input: &[u8], now: Duration) -> Vec<u8> {
    let prefix = format!("[+{}.{:03}] ", now.as_secs(), now.subsec_millis());
    let mut out = Vec::new();
    let mut segment_start = true;
    for &byte in input {
        let terminator = byte == b'\n' || byte == b'\r';
        if segment_start && !terminator {
            out.extend_from_slice(prefix.as_bytes());
        }
        segment_start = terminator;
        out.push(byte);
    }
    out
}

/// Strip every `[+S.mmm] ` that the stamper inserted, given its exact text.
fn strip_prefix(stamped: &[u8], now: Duration) -> Vec<u8> {
    let prefix = format!("[+{}.{:03}] ", now.as_secs(), now.subsec_millis());
    let mut out = Vec::new();
    let mut index = 0;
    let mut line_start = true;
    while index < stamped.len() {
        let byte = stamped[index];
        let terminator = byte == b'\n' || byte == b'\r';
        if line_start && !terminator {
            assert!(
                stamped[index..].starts_with(prefix.as_bytes()),
                "missing prefix at line start"
            );
            index += prefix.len();
            line_start = false;
            continue;
        }
        line_start = terminator;
        out.push(byte);
        index += 1;
    }
    out
}

fn console_bytes(tc: &TestCase, max: usize) -> Vec<u8> {
    let alphabet: [u8; 6] = *b"aZ \n\r[";
    let length = tc.draw(gs::integers::<usize>().min_value(0).max_value(max));
    (0..length)
        .map(|_| tc.draw(gs::sampled_from(&alphabet)))
        .collect()
}

#[test]
fn prefix_format_is_seconds_and_truncated_milliseconds() {
    for (duration, text) in [
        (Duration::ZERO, "[+0.000] "),
        (Duration::from_micros(1_999), "[+0.001] "),
        (Duration::from_millis(6_412), "[+6.412] "),
        (
            Duration::from_secs(3_725) + Duration::from_nanos(999_999_999),
            "[+3725.999] ",
        ),
    ] {
        let mut out = Vec::new();
        push_prefix(duration, &mut out);
        assert_eq!(out, text.as_bytes());
    }
}

#[test]
fn crlf_and_redraws_carry_one_prefix_per_visible_line() {
    let mut stamper = Stamper::new();
    let mut out = Vec::new();
    stamper.feed(b"Linux\r\n\r\nsystemd\rredraw\n", Duration::ZERO, &mut out);
    assert_eq!(
        out,
        b"[+0.000] Linux\r\n\r\n[+0.000] systemd\r[+0.000] redraw\n".to_vec()
    );
    assert_eq!(stamper.state(), LineState::LineStart);
}

#[test]
fn partial_line_keeps_its_first_read_timestamp() {
    let mut stamper = Stamper::new();
    let mut out = Vec::new();
    stamper.feed(b"Startup ", Duration::from_millis(100), &mut out);
    assert_eq!(stamper.state(), LineState::MidLine);
    stamper.feed(b"finished\nnext", Duration::from_millis(250), &mut out);
    assert_eq!(out, b"[+0.100] Startup finished\n[+0.250] next".to_vec());
}

/// @cc [owner:ghuntley,label:verification] hegel-boot-log-chunking-oracle
/// Arbitrary chunkings of generated console bytes MUST stamp identically to
/// the whole buffer and to the independent line oracle for one clock reading,
/// and stripping the prefixes MUST recover the input exactly.
#[hegel::test(test_cases = 100)]
fn stamping_is_chunking_independent(tc: TestCase) {
    let input = console_bytes(&tc, 512);
    let now = Duration::from_millis(tc.draw(gs::integers::<u64>().max_value(10_000_000)));
    let mut whole = Vec::new();
    Stamper::new().feed(&input, now, &mut whole);
    let mut chunked = Vec::new();
    let mut stamper = Stamper::new();
    let mut rest: &[u8] = &input;
    while !rest.is_empty() {
        let size = tc.draw(gs::integers::<usize>().min_value(1).max_value(rest.len()));
        let (head, tail) = rest.split_at(size);
        stamper.feed(head, now, &mut chunked);
        rest = tail;
    }
    assert_eq!(chunked, whole);
    assert_eq!(whole, oracle_stamp(&input, now));
    assert_eq!(strip_prefix(&whole, now), input);
}

/// @cc [owner:ghuntley,label:verification;capacity] hegel-boot-log-retention-prefix
/// The stamped retention MUST never exceed `BOOT_LOG_LIMIT` and MUST equal the
/// limit-truncated prefix of the unbounded stamped stream for any chunking.
#[hegel::test(test_cases = 100)]
fn retention_is_the_bounded_prefix_of_the_stamped_stream(tc: TestCase) {
    let lines = tc.draw(gs::integers::<usize>().min_value(0).max_value(4));
    let line_length = tc.draw(hegel::one_of!(
        gs::integers::<usize>().min_value(0).max_value(64),
        gs::integers::<usize>()
            .min_value(BOOT_LOG_LIMIT / 4)
            .max_value(BOOT_LOG_LIMIT / 2 + 64),
    ));
    let mut input = Vec::new();
    for _ in 0..lines {
        input.extend(std::iter::repeat_n(b'x', line_length));
        input.push(b'\n');
    }
    input.extend(console_bytes(&tc, 64));
    let now = Duration::from_millis(42);
    let mut retention = Retention::new();
    let mut kept = Vec::new();
    let mut rest: &[u8] = &input;
    while !rest.is_empty() {
        let size = tc.draw(
            gs::integers::<usize>()
                .min_value(1)
                .max_value(rest.len().min(65536)),
        );
        let (head, tail) = rest.split_at(size);
        kept.extend_from_slice(retention.admit(head, now));
        assert!(retention.retained() <= BOOT_LOG_LIMIT);
        rest = tail;
    }
    let stamped = oracle_stamp(&input, now);
    assert_eq!(kept.len(), retention.retained());
    assert_eq!(kept, stamped[..stamped.len().min(BOOT_LOG_LIMIT)]);
}

/// Independent prefix text: decimal digits by repeated division, then the
/// truncated millisecond field zero-padded to three digits by hand.
#[expect(
    clippy::duration_subsec,
    reason = "the oracle derives milliseconds from nanoseconds, independently of push_prefix"
)]
fn prefix_oracle(now: Duration) -> Vec<u8> {
    let mut seconds = now.as_secs();
    let mut digits = Vec::new();
    loop {
        digits.push(b'0' + u8::try_from(seconds % 10).expect("digit"));
        seconds /= 10;
        if seconds == 0 {
            break;
        }
    }
    digits.reverse();
    let millis = now.subsec_nanos() / 1_000_000;
    let mut out = b"[+".to_vec();
    out.extend(digits);
    out.push(b'.');
    for divisor in [100, 10, 1] {
        out.push(b'0' + u8::try_from(millis / divisor % 10).expect("digit"));
    }
    out.extend_from_slice(b"] ");
    out
}

/// @cc [owner:ghuntley,label:verification] hegel-boot-log-prefix-format-oracle
/// `push_prefix` MUST append exactly `[+S.mmm] ` for every duration: whole
/// seconds unbounded, milliseconds truncated (never rounded) and zero-padded,
/// leaving the bytes already in the buffer untouched.
#[hegel::test(test_cases = 300)]
fn push_prefix_matches_the_independent_format_oracle(tc: TestCase) {
    let seconds = tc.draw(hegel::one_of!(
        gs::integers::<u64>().max_value(10_000),
        gs::integers::<u64>()
    ));
    let nanos = tc.draw(gs::integers::<u32>().max_value(999_999_999));
    let now = Duration::new(seconds, nanos);
    let existing = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(16));
    let mut out = existing.clone();
    push_prefix(now, &mut out);
    let mut expected = existing;
    expected.extend(prefix_oracle(now));
    assert_eq!(out, expected);
}

/// The candidate inode at the log path before `open_log` runs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LogShape {
    Absent,
    Regular,
    HardLinked,
    Symlink,
    Directory,
}

/// @cc [owner:ghuntley,label:verification;security] hegel-boot-log-open-log-custody
/// Without root, `open_log` MUST open exactly: an absent path, or a
/// single-link regular file of mode 0600 owned by the writer, truncated, and
/// with a reader only when it is the writer or the writer may hand the file to
/// it. Symlinks (whose targets stay untouched), hard-linked files, directories
/// and any other mode MUST be refused; an opened log is private to its owner.
#[hegel::test(test_cases = 100)]
fn open_log_refuses_every_unproven_inode(tc: TestCase) {
    use std::os::unix::fs::PermissionsExt as _;
    let shape = tc.draw(gs::sampled_from(vec![
        LogShape::Absent,
        LogShape::Regular,
        LogShape::HardLinked,
        LogShape::Symlink,
        LogShape::Directory,
    ]));
    let mode = tc.draw(gs::sampled_from(vec![
        0o600_u32, 0o600, 0o400, 0o640, 0o644, 0o660, 0o700, 0o606,
    ]));
    let euid = rustix::process::geteuid().as_raw();
    let other = if euid == 1 { 2 } else { 1 };
    let reader = tc.draw(gs::sampled_from(vec![None, Some(euid), Some(other)]));
    let directory = tempfile::tempdir().expect("fixture directory");
    let path = directory.path().join("boot.log.raw");
    let target = directory.path().join("target");
    let content = b"previous boot".to_vec();
    match shape {
        LogShape::Absent => {}
        LogShape::Regular | LogShape::HardLinked => {
            std::fs::write(&path, &content).expect("existing log");
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
                .expect("log mode");
            if shape == LogShape::HardLinked {
                std::fs::hard_link(&path, directory.path().join("alias")).expect("hard link");
            }
        }
        LogShape::Symlink => {
            std::fs::write(&target, &content).expect("symlink target");
            std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600))
                .expect("target mode");
            std::os::unix::fs::symlink(&target, &path).expect("symlink");
        }
        LogShape::Directory => std::fs::create_dir(&path).expect("directory"),
    }
    let base = match shape {
        LogShape::Absent => true,
        LogShape::Regular => mode == 0o600,
        LogShape::HardLinked | LogShape::Symlink | LogShape::Directory => false,
    };
    let handed = reader.is_none_or(|uid| uid == euid || euid == 0);
    let result = open_log(&path, reader);
    assert_eq!(
        result.is_ok(),
        base && handed,
        "{shape:?} {mode:o} {reader:?}"
    );
    if result.is_ok() {
        let metadata = std::fs::symlink_metadata(&path).expect("opened log");
        assert!(metadata.is_file());
        assert_eq!(metadata.nlink(), 1);
        assert_eq!(metadata.mode() & 0o777, 0o600);
        assert_eq!(metadata.uid(), reader.unwrap_or(euid));
        assert_eq!(metadata.len(), 0);
    }
    if shape == LogShape::Symlink {
        assert_eq!(std::fs::read(&target).expect("target bytes"), content);
    }
}

/// The settle fixture child: exits with `BOOT_LOG_SETTLE_EXIT`, or kills itself
/// with `BOOT_LOG_SETTLE_SIGNAL`. It runs only when a property execs it by name.
#[test]
#[ignore = "boot-log settle fixture"]
fn settle_fixture_child() {
    if let Ok(signal) = std::env::var("BOOT_LOG_SETTLE_SIGNAL") {
        let signal = rustix::process::Signal::from_named_raw(signal.parse().expect("signal"))
            .expect("named signal");
        rustix::process::kill_process(rustix::process::getpid(), signal).expect("self signal");
        std::thread::sleep(Duration::from_secs(30));
    }
    let code: i32 = std::env::var("BOOT_LOG_SETTLE_EXIT")
        .expect("exit code")
        .parse()
        .expect("numeric exit");
    std::process::exit(code);
}

/// The settle fixture runner: settles a fixture child and exits with the
/// result, so a re-raised signal ends this process and not the test harness.
#[test]
#[ignore = "boot-log settle fixture"]
fn settle_fixture_runner() {
    let mut child = settle_fixture("settle_fixture_child")
        .spawn()
        .expect("fixture child");
    let code = settle(&mut child);
    std::process::exit(i32::from(code));
}

fn settle_fixture(name: &str) -> Process {
    let mut command = Process::new(std::env::current_exe().expect("test binary"));
    command
        .args([
            "--exact",
            &format!("tests::{name}"),
            "--ignored",
            "--nocapture",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

/// @cc [owner:ghuntley,label:verification;recovery] hegel-boot-log-settle-mapping
/// `settle` MUST return a child's exit code unchanged, and for a child killed
/// by a signal MUST end its own process by that same signal.
#[hegel::test(test_cases = 24)]
fn settle_preserves_exit_codes_and_reraises_signals(tc: TestCase) {
    let signals = vec![
        libc::SIGHUP,
        libc::SIGINT,
        libc::SIGKILL,
        libc::SIGUSR1,
        libc::SIGUSR2,
        libc::SIGALRM,
        libc::SIGTERM,
    ];
    let mut runner = settle_fixture("settle_fixture_runner");
    let expected = if tc.draw(gs::booleans()) {
        let code = tc.draw(gs::integers::<u8>());
        runner.env("BOOT_LOG_SETTLE_EXIT", code.to_string());
        (Some(i32::from(code)), None)
    } else {
        let signal = tc.draw(gs::sampled_from(signals));
        runner.env("BOOT_LOG_SETTLE_SIGNAL", signal.to_string());
        (None, Some(signal))
    };
    let status = runner.status().expect("fixture runner");
    assert_eq!((status.code(), status.signal()), expected);
}
