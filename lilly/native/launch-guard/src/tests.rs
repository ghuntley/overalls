use super::*;
use hegel::{generators as gs, TestCase};

fn good_uuid(tc: &TestCase) -> String {
    let mut text = String::with_capacity(36);
    for index in 0..36 {
        if matches!(index, 8 | 13 | 18 | 23) {
            text.push('-');
        } else {
            let digit = tc.draw(gs::integers::<u8>().min_value(0).max_value(15));
            text.push(char::from_digit(digit.into(), 16).expect("hex digit"));
        }
    }
    text
}

fn spec_expect(arguments: &[&str]) -> bool {
    let [lock, intent, placement_id, epoch, generation, program, ..] = arguments else {
        return false;
    };
    let absolute_ok = [lock, intent, program]
        .iter()
        .all(|value| value.starts_with('/'));
    let placement_ok = placement_id.len() == 36
        && placement_id.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                matches!(byte, b'0'..=b'9' | b'a'..=b'f')
            }
        });
    let counter_ok = |value: &str| {
        !value.is_empty()
            && !value.starts_with('0')
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value
                .parse::<u64>()
                .is_ok_and(|number| (1..=u64::try_from(i64::MAX).unwrap()).contains(&number))
    };
    absolute_ok && placement_ok && counter_ok(epoch) && counter_ok(generation)
}

/// @cc [owner:ghuntley,label:verification] hegel-launch-selector-oracle
/// Generated argument vectors MUST be classified by an independent selector
/// spec, and accepted selectors MUST preserve every field byte-for-byte.
#[hegel::test(test_cases = 100)]
fn cli_selector_matches_independent_oracle(tc: TestCase) {
    let alphabet = [
        "", "/", "/lock", "/intent", "relative", "jailer", "/jailer", "shared",
    ];
    let length = tc.draw(gs::integers::<usize>().min_value(0).max_value(8));
    let mut words: Vec<String> = Vec::new();
    for _ in 0..length {
        words.push(tc.draw(gs::sampled_from(&alphabet)).to_string());
    }
    // Bias some draws into structurally valid prefix territory while retaining
    // corruption slots at every position.
    if words.len() >= 6 {
        if tc.draw(gs::booleans()) {
            words[0] = "/lock".to_string();
        }
        if tc.draw(gs::booleans()) {
            words[1] = "/intent".to_string();
        }
        if tc.draw(gs::booleans()) {
            words[2] = good_uuid(&tc);
        }
        if tc.draw(gs::booleans()) {
            words[3] = tc
                .draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(i64::MAX as u64),
                )
                .to_string();
        }
        if tc.draw(gs::booleans()) {
            words[4] = tc
                .draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(i64::MAX as u64),
                )
                .to_string();
        }
        if tc.draw(gs::booleans()) {
            words[5] = "/jailer".to_string();
        }
    }
    let references: Vec<&str> = words.iter().map(String::as_str).collect();
    let arguments: Vec<OsString> = words.iter().map(OsString::from).collect();
    let expected = spec_expect(&references);
    match (parse_cli(&arguments), expected) {
        (None, false) => {}
        (Some(request), true) => {
            assert_eq!(request.lock.as_os_str(), OsStr::new(words[0].as_str()));
            assert_eq!(request.intent.as_os_str(), OsStr::new(words[1].as_str()));
            assert_eq!(request.placement, words[2]);
            assert_eq!(request.epoch.to_string(), words[3],);
            assert_eq!(request.generation.to_string(), words[4],);
            assert_eq!(request.program.as_os_str(), OsStr::new(words[5].as_str()));
            let rest: Vec<String> = request
                .arguments
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect();
            assert_eq!(rest, words[6..].to_vec());
        }
        (parsed, expected) => panic!("selector diverged from oracle: {parsed:?} {expected}"),
    }
}

#[test]
fn intent_framing_edge_byte_positions() {
    let placement = b"01234567-89ab-4def-8123-456789abcdef";
    let epoch = 0x0102_0304_0506_0708_u64;
    let generation = 0x1112_1314_1516_1718_u64;
    let mut bytes = Vec::with_capacity(INTENT_BYTES);
    bytes.extend_from_slice(placement);
    bytes.extend_from_slice(&epoch.to_be_bytes());
    bytes.extend_from_slice(&generation.to_be_bytes());
    bytes.push(RUNNING_STATE);
    assert_eq!(bytes.len(), INTENT_BYTES);
    let intent = Intent {
        placement: *placement,
        epoch,
        generation,
        state: RUNNING_STATE,
    };
    let directory = tempfile::tempdir().expect("fixture directory");
    let path = directory.path().join("intent");
    std::fs::write(&path, &bytes).expect("staged intent");
    let fd: OwnedFd = std::fs::File::open(&path).expect("opened intent").into();
    assert_eq!(read_intent(&fd), Ok(intent));
    let short: OwnedFd = std::fs::File::open({
        std::fs::write(directory.path().join("short"), &bytes[..52]).expect("staged short");
        directory.path().join("short")
    })
    .expect("opened short")
    .into();
    assert_eq!(read_intent(&short), Err(IntentError::Framing));
}

/// @cc [owner:ghuntley,label:verification] hegel-launch-current-predicate
/// Generated intent/request pairs MUST authorize exec only when placement,
/// epoch, generation and the running-state byte ALL match, byte for byte.
#[hegel::test(test_cases = 100)]
fn current_generation_predicate_is_exact(tc: TestCase) {
    let uuid = good_uuid(&tc);
    let epoch = tc.draw(
        gs::integers::<u64>()
            .min_value(1)
            .max_value(i64::MAX as u64),
    );
    let generation = tc.draw(
        gs::integers::<u64>()
            .min_value(1)
            .max_value(i64::MAX as u64),
    );
    let mut request = Request {
        lock: PathBuf::from("/lock"),
        intent: PathBuf::from("/intent"),
        placement: uuid.clone(),
        epoch,
        generation,
        program: PathBuf::from("/jailer"),
        arguments: Vec::new(),
        owner: None,
    };
    let mut bytes: [u8; 36] = uuid.as_bytes().try_into().expect("uuid bytes");
    let mut intent = Intent {
        placement: bytes,
        epoch,
        generation,
        state: RUNNING_STATE,
    };
    assert!(current(&intent, &request));
    let field = tc.draw(gs::integers::<u8>().min_value(0).max_value(3));
    match field {
        0 => {
            let position = tc.draw(gs::integers::<usize>().min_value(0).max_value(35));
            bytes[position] = match bytes[position] {
                b'-' => b'-',
                b'f' => b'e',
                value => value + 1,
            };
            intent.placement = bytes;
        }
        1 => {
            request.epoch = epoch.wrapping_add(
                tc.draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(u64::from(u16::MAX)),
                ),
            );
        }
        2 => {
            request.generation = generation.wrapping_add(
                tc.draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(u64::from(u16::MAX)),
                ),
            );
        }
        _ => intent.state = tc.draw(gs::integers::<u8>()),
    }
    let placed_same = intent.placement[..] == request.placement.as_bytes()[..];
    let expected = placed_same
        && intent.epoch == request.epoch
        && intent.generation == request.generation
        && intent.state == RUNNING_STATE;
    assert_eq!(current(&intent, &request), expected);
}

/// `--owner-uid` admits exactly one extra nonzero, canonical owner uid.
#[test]
fn owner_uid_prefix_is_optional_and_canonical() {
    let base = [
        "/lock",
        "/intent",
        "11111111-2222-4333-8444-555555555555",
        "1",
        "2",
        "/jailer",
    ];
    let parse = |prefix: &[&str]| {
        let arguments: Vec<OsString> = prefix
            .iter()
            .chain(base.iter())
            .map(OsString::from)
            .collect();
        parse_cli(&arguments).map(|request| request.owner)
    };
    assert_eq!(parse(&[]), Some(None));
    assert_eq!(parse(&["--owner-uid", "977"]), Some(Some(977)));
    assert_eq!(parse(&["--owner-uid", "0"]), None);
    assert_eq!(parse(&["--owner-uid", "0977"]), None);
    assert_eq!(parse(&["--owner-uid", "+977"]), None);
    assert_eq!(parse(&["--owner-uid"]), None);
}

/// Independent encoder for the intent frame layout documented on
/// `INTENT_BYTES`: placement, big-endian epoch, big-endian generation, state.
fn encode_intent(intent: &Intent) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(INTENT_BYTES);
    bytes.extend_from_slice(&intent.placement);
    bytes.extend_from_slice(&intent.epoch.to_be_bytes());
    bytes.extend_from_slice(&intent.generation.to_be_bytes());
    bytes.push(intent.state);
    bytes
}

/// @cc [owner:ghuntley,label:verification;recovery] hegel-launch-intent-frame-roundtrip
/// Every generated intent MUST survive encode/decode unchanged, every arbitrary
/// 53-byte frame MUST decode and re-encode to the same bytes, and every other
/// length MUST be a framing failure.
#[hegel::test(test_cases = 200)]
fn intent_frame_decode_round_trips(tc: TestCase) {
    let intent = Intent {
        placement: tc.draw(gs::arrays::<_, u8, 36>(gs::integers::<u8>())),
        epoch: tc.draw(gs::integers::<u64>()),
        generation: tc.draw(gs::integers::<u64>()),
        state: tc.draw(gs::integers::<u8>()),
    };
    let encoded = encode_intent(&intent);
    assert_eq!(encoded.len(), INTENT_BYTES);
    assert_eq!(decode_intent(&encoded), Ok(intent));

    let frame = tc.draw(gs::arrays::<_, u8, INTENT_BYTES>(gs::integers::<u8>()));
    let decoded = decode_intent(&frame).expect("53-byte frame decodes");
    assert_eq!(encode_intent(&decoded), frame.to_vec());

    let other = tc.draw(gs::binary().max_size(2 * INTENT_BYTES));
    let expected_ok = other.len() == INTENT_BYTES;
    assert_eq!(decode_intent(&other).is_ok(), expected_ok);
}

/// @cc [owner:ghuntley,label:verification] hegel-launch-placement-oracle
/// `parse_placement` MUST accept exactly the 36-byte lowercase hyphenated UUID
/// wire form, judged by an independent byte oracle, and return it unchanged.
#[hegel::test(test_cases = 200)]
fn placement_parser_matches_independent_oracle(tc: TestCase) {
    let mut bytes: Vec<u8> = if tc.draw(gs::booleans()) {
        good_uuid(&tc).into_bytes()
    } else {
        tc.draw(gs::vecs(gs::sampled_from(&b"0123456789abcdefABCDEFg-_ \xff"[..])).max_size(40))
    };
    if !bytes.is_empty() && tc.draw(gs::booleans()) {
        let position = tc.draw(gs::integers::<usize>().max_value(bytes.len() - 1));
        bytes[position] = tc.draw(gs::sampled_from(&b"0aAfFg-:\x00\xff"[..]));
    }
    let oracle = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase(),
        });
    match parse_placement(OsStr::from_bytes(&bytes)) {
        Some(parsed) => {
            assert!(oracle, "placement parser accepted an oracle refusal");
            assert_eq!(parsed.as_bytes(), &bytes[..]);
        }
        None => assert!(!oracle, "placement parser refused an oracle acceptance"),
    }
}

/// @cc [owner:ghuntley,label:verification] hegel-launch-counter-oracle
/// `counter` MUST accept exactly canonical decimal text (no sign, no leading
/// zero, ASCII digits only) whose value lies in `1..=i64::MAX`, judged by an
/// independent u128 oracle, and return that value.
#[hegel::test(test_cases = 200)]
fn counter_matches_independent_oracle(tc: TestCase) {
    let mut text: Vec<u8> = match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => tc.draw(gs::integers::<u64>()).to_string().into_bytes(),
        1 => tc
            .draw(gs::integers::<u128>().max_value(u128::from(u64::MAX) * 4))
            .to_string()
            .into_bytes(),
        _ => tc.draw(gs::vecs(gs::sampled_from(&b"0123456789+- x\xff"[..])).max_size(24)),
    };
    if tc.draw(gs::booleans()) {
        let prefix = tc.draw(gs::sampled_from(&[&b"0"[..], b"+", b"-", b" "]));
        text.splice(0..0, prefix.iter().copied());
    }
    let oracle = (!text.is_empty()
        && text[0] != b'0'
        && text.len() <= 39
        && text.iter().all(u8::is_ascii_digit))
    .then(|| {
        text.iter()
            .fold(0_u128, |value, digit| value * 10 + u128::from(digit - b'0'))
    })
    .filter(|value| (1..=i64::MAX as u128).contains(value))
    .map(|value| u64::try_from(value).expect("bounded by i64::MAX"));
    assert_eq!(counter(OsStr::from_bytes(&text)), oracle);
}

/// @cc [owner:ghuntley,label:verification;security] hegel-launch-file-refusal-matrix
/// `acquire_fd` MUST admit only a regular, single-link, owner-only (0600) file
/// of exactly the expected size reached without following a symlink; every
/// other generated combination of size, mode, link count and symlink refuses.
#[hegel::test(test_cases = 100)]
fn custody_file_refusal_matrix(tc: TestCase) {
    use std::os::unix::fs::PermissionsExt;
    let expected_size = tc.draw(gs::sampled_from(&[0_u64, INTENT_BYTES as u64]));
    // Each defect is drawn independently so single-defect cases stay common.
    let wrong_size = tc.draw(gs::booleans());
    let wrong_mode = tc.draw(gs::booleans());
    let hardlinked = tc.draw(gs::booleans());
    let symlinked = tc.draw(gs::booleans());
    let cloexec = tc.draw(gs::booleans());
    let actual_size = if wrong_size {
        let delta = tc.draw(gs::sampled_from(&[1_u64, 2, INTENT_BYTES as u64]));
        if expected_size > 0 && tc.draw(gs::booleans()) {
            expected_size - 1
        } else {
            expected_size + delta
        }
    } else {
        expected_size
    };
    let mode = if wrong_mode {
        tc.draw(gs::sampled_from(&[
            0o400_u32, 0o640, 0o604, 0o700, 0o660, 0o666,
        ]))
    } else {
        tc.draw(gs::sampled_from(&[0o600_u32, 0o1600]))
    };

    let directory = tempfile::tempdir().expect("fixture directory");
    let target = directory.path().join("target");
    std::fs::write(
        &target,
        vec![0_u8; usize::try_from(actual_size).expect("small")],
    )
    .expect("staged file");
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(mode)).expect("mode");
    if hardlinked {
        std::fs::hard_link(&target, directory.path().join("alias")).expect("hard link");
    }
    let path = if symlinked {
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&target, &link).expect("symlink");
        link
    } else {
        target
    };
    // Only the guard's own uid owns the fixture, so the owner override is inert.
    let oracle = actual_size == expected_size && mode & 0o777 == 0o600 && !hardlinked && !symlinked;
    let admitted = acquire_fd(&path, expected_size, cloexec, None).is_ok();
    assert_eq!(admitted, oracle);
}
