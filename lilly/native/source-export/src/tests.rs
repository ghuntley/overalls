use super::*;
use hegel::generators as gs;
use hegel::generators::Generator as _;
use hegel::TestCase;

/// @cc [owner:ghuntley,label:verification] hegel-source-export-selectors
/// Generated leases and argv shapes MUST classify against the independent
/// spec: positive decimal within 1..=300000, no leading zero, absolute paths,
/// sender arity and total byte span as the C helper measured them.
#[hegel::test(test_cases = 100)]
fn lease_and_selector_match_independent_spec(tc: TestCase) {
    let lease_candidates = [
        "0",
        "00",
        "01",
        "1",
        "1000",
        "299999",
        "300000",
        "300001",
        "x",
        "",
        "-1",
        "300000 ",
        "3000000",
        "18446744073709551615123",
    ];
    let path_candidates = ["", "/", "/lock", "/sender", "relative", "/x y"];
    let lease = tc.draw(gs::sampled_from(&lease_candidates)).to_string();
    let lock = tc.draw(gs::sampled_from(&path_candidates)).to_string();
    let sender = tc.draw(gs::sampled_from(&path_candidates)).to_string();
    let rest_count = tc.draw(gs::integers::<usize>().min_value(0).max_value(130));
    let arguments: Vec<OsString> = [lock, lease, sender]
        .into_iter()
        .map(OsString::from)
        .chain((0..rest_count).map(|index| OsString::from(format!("arg{index}"))))
        .collect();

    let lease_spec = |text: &str| {
        !text.is_empty()
            && !text.starts_with('0')
            && text.bytes().all(|byte| byte.is_ascii_digit())
            && text
                .parse::<u64>()
                .is_ok_and(|value| (1..=300_000).contains(&value))
    };
    let argv_spec = arguments.len() >= 3 && arguments.len() <= 130;
    let expected = argv_spec
        && arguments[0].as_os_str().as_bytes().starts_with(b"/")
        && arguments[2].as_os_str().as_bytes().starts_with(b"/")
        && lease_spec(&arguments[1].to_string_lossy());

    match (parse_cli(&arguments), expected) {
        (None, false) => {}
        (Some(request), true) => {
            assert_eq!(request.lock.as_os_str(), arguments[0].as_os_str());
            assert_eq!(request.sender.as_os_str(), arguments[2].as_os_str());
            assert_eq!(request.arguments.len(), arguments.len() - 3);
        }
        (parsed, expected) => panic!("selector diverged: {parsed:?} {expected}"),
    }
}

/// @cc [owner:ghuntley,label:verification] hegel-source-export-renew-or-revoke
/// Only a valid `L<millis>` line renews; every other byte shape revokes.
#[hegel::test(test_cases = 100)]
fn control_frames_renew_or_revoke_exactly(tc: TestCase) {
    let candidates: Vec<Vec<u8>> = vec![
        b"L1".to_vec(),
        b"L300000".to_vec(),
        b"L300001".to_vec(),
        b"L0".to_vec(),
        b"L".to_vec(),
        b"X".to_vec(),
        b"".to_vec(),
        b" L1000".to_vec(),
        vec![b'L', 0x80, b'1'],
    ];
    let frame = tc.draw(gs::sampled_from(&candidates)).clone();
    let expected = match frame.as_slice() {
        [b'L', rest @ ..] => std::str::from_utf8(rest).ok().and_then(|text| {
            let value: u32 = text.parse().ok()?;
            ((1..=300_000).contains(&value)
                && !text.is_empty()
                && !text.starts_with('0')
                && text.bytes().all(|byte| byte.is_ascii_digit()))
            .then_some(value)
        }),
        _ => None,
    };
    assert_eq!(parse_control(&frame), expected.map(Control::Renew));
}

/// The independent renewal specification: `L` then 1..=6 ASCII digits with
/// no leading zero, whose decimal value lies in 1..=300000.
fn renewal_oracle(frame: &[u8]) -> Option<u32> {
    let (&first, digits) = frame.split_first()?;
    if first != b'L'
        || digits.is_empty()
        || digits.len() > 6
        || digits[0] == b'0'
        || !digits.iter().all(u8::is_ascii_digit)
    {
        return None;
    }
    let value = digits
        .iter()
        .fold(0_u32, |acc, digit| acc * 10 + u32::from(digit - b'0'));
    (value <= 300_000).then_some(value)
}

/// @cc [owner:ghuntley,label:verification;protocol] hegel-source-export-control-lattice
/// Arbitrary control frames MUST renew exactly when the independent digit-wise
/// oracle accepts them, with the oracle's value; every other byte shape
/// (non-`L` heads, empty, leading zero, non-digits, non-UTF-8, out of range)
/// revokes. Frames are bounded to CONTROL_FRAME_LIMIT bytes.
#[hegel::test(test_cases = 300)]
fn control_frame_lattice_matches_independent_oracle(tc: TestCase) {
    let frame: Vec<u8> = match tc.draw(gs::integers::<u8>().min_value(0).max_value(3)) {
        0 => tc.draw(gs::binary().max_size(CONTROL_FRAME_LIMIT)),
        1 => {
            let tail = tc.draw(gs::binary().max_size(8));
            [b"L".as_slice(), tail.as_slice()].concat()
        }
        2 => {
            let digits =
                tc.draw(gs::vecs(gs::integers::<u8>().min_value(b'0').max_value(b'9')).max_size(8));
            [b"L".as_slice(), digits.as_slice()].concat()
        }
        _ => {
            let value = tc.draw(gs::one_of(vec![
                gs::integers::<u32>()
                    .min_value(0)
                    .max_value(300_010)
                    .boxed(),
                gs::integers::<u32>().boxed(),
            ]));
            format!("L{value}").into_bytes()
        }
    };
    assert_eq!(
        parse_control(&frame),
        renewal_oracle(&frame).map(Control::Renew),
        "frame of {} bytes",
        frame.len()
    );
}
