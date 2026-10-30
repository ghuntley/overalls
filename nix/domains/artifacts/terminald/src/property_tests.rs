//! Generated pure byte-history checks; these do not establish PTY or vsock isolation.
use crate::{crypto, frame, ring::Ring, session};
use hegel::{generators as gs, TestCase};

/// @cc [owner:ghuntley,label:verification;recovery] terminal-ring-history-oracle
/// Every append/resize prefix MUST retain exactly the untruncated suffix of the
/// original byte history; cursor replay MUST report the actual gap and MUST NOT
/// recreate bytes discarded before a later capacity increase.
#[hegel::test(test_cases = 100)]
fn ring_resize_and_cursor_histories(tc: TestCase) {
    let mut zero_capacity = Ring::new(0);
    assert_eq!(zero_capacity.capacity(), 1);
    zero_capacity.push(&[7, 9]);
    assert_eq!(zero_capacity.replay_from(0), (1, vec![9]));
    zero_capacity.set_capacity(0);
    assert_eq!(zero_capacity.capacity(), 1);
    assert_eq!(zero_capacity.replay_from(0), (1, vec![9]));
    let menu = [0_usize, 1, 2, 7, 8, 9, 31, 32, 33, 255, 256, 257];
    let mut ring = Ring::new(8);
    let mut history: Vec<u8> = Vec::new();
    let mut first_retained: usize = 0;
    let mut capacity: usize = 8;
    let steps = tc.draw(gs::integers::<usize>().min_value(1).max_value(64));
    for _ in 0..steps {
        if tc.draw(gs::booleans()) {
            let requested = tc.draw(gs::sampled_from(&menu));
            capacity = requested.max(1);
            ring.set_capacity(requested);
        } else {
            let count = tc.draw(gs::sampled_from(&menu));
            let bytes: Vec<u8> = tc.draw(
                gs::vecs(gs::integers::<u8>())
                    .min_size(count)
                    .max_size(count),
            );
            history.extend_from_slice(&bytes);
            ring.push(&bytes);
        }
        first_retained = first_retained.max(history.len().saturating_sub(capacity));
        let tail = u64::try_from(history.len()).expect("bounded history");
        let base = u64::try_from(first_retained).expect("bounded history");
        assert_eq!(ring.capacity(), capacity);
        assert_eq!(ring.base(), base);
        assert_eq!(ring.tail(), tail);
        let generated = tc.draw(gs::integers::<u64>().min_value(0).max_value(tail + 1));
        for cursor in [
            0,
            base.saturating_sub(1),
            base,
            tail.saturating_sub(1),
            tail,
            tail + 1,
            generated,
        ] {
            let start = cursor.max(base).min(tail);
            let expected = &history[usize::try_from(start).expect("bounded cursor")..];
            assert_eq!(ring.replay_from(cursor), (start, expected.to_vec()));
        }
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] terminal-stream-frame-chunking
/// Splitting or coalescing valid frame bytes MUST preserve their exact payload
/// order. Parsing one frame MUST leave the next frame untouched; partial input
/// MUST remain available until its frame becomes complete.
#[hegel::test(test_cases = 100)]
fn concatenated_frames_survive_arbitrary_chunk_boundaries(tc: TestCase) {
    let sizes = [
        0_usize,
        1,
        2,
        3,
        4,
        5,
        frame::MAX_PAYLOAD - 1,
        frame::MAX_PAYLOAD,
    ];
    let count = tc.draw(gs::integers::<usize>().min_value(1).max_value(4));
    let mut expected: Vec<(u8, Vec<u8>)> = Vec::new();
    let mut wire: Vec<u8> = Vec::new();
    for _ in 0..count {
        let op = tc.draw(gs::integers::<u8>());
        let size = tc.draw(gs::sampled_from(&sizes));
        let payload: Vec<u8> =
            tc.draw(gs::vecs(gs::integers::<u8>()).min_size(size).max_size(size));
        let encoded = frame::encode(op, &payload);
        let declared = u16::try_from(size).expect("bounded frame").to_be_bytes();
        assert_eq!(&encoded[..4], &[frame::MAGIC, op, declared[0], declared[1]]);
        assert_eq!(&encoded[4..], payload.as_slice());
        wire.extend_from_slice(&encoded);
        expected.push((op, payload));
    }
    let mut buffer: Vec<u8> = Vec::new();
    let mut offset: usize = 0;
    let mut index: usize = 0;
    while offset < wire.len() {
        let chunk = tc.draw(gs::sampled_from(&[
            1_usize, 2, 3, 4, 5, 4095, 4096, 4097, 8196,
        ]));
        let end = (offset + chunk).min(wire.len());
        buffer.extend_from_slice(&wire[offset..end]);
        offset = end;
        loop {
            let before = buffer.clone();
            match frame::decode(&buffer) {
                None => {
                    if let Some((_, payload)) = expected.get(index) {
                        assert!(
                            buffer.len() < 4 + payload.len(),
                            "complete expected frame was not decoded"
                        );
                    } else {
                        assert!(buffer.is_empty(), "unexpected trailing stream bytes");
                    }
                    break;
                }
                Some(Err(())) => panic!("valid generated stream rejected"),
                Some(Ok(decoded)) => {
                    let (op, payload) = expected.get(index).expect("no extra frame");
                    assert_eq!(decoded.op, *op);
                    assert_eq!(&decoded.payload, payload);
                    let consumed = frame::consumed(payload.len());
                    assert_eq!(consumed, 4 + payload.len());
                    buffer.drain(..consumed);
                    assert_eq!(buffer.as_slice(), &before[consumed..]);
                    index += 1;
                }
            }
        }
    }
    assert_eq!(index, expected.len());
    assert!(buffer.is_empty(), "no undecoded stream bytes remain");
}

/// @cc [owner:ghuntley,label:verification;capacity] terminal-ring-configured-boundaries
/// Filling around the configured default and maximum ring capacities MUST
/// preserve the exact retained byte suffix through shrink/grow and a later
/// append. These pure checks MUST NOT establish the shared session budget.
#[hegel::test(test_cases = 4)]
fn configured_ring_capacity_families(tc: TestCase) {
    let config = session::Config::default();
    let seed = tc.draw(gs::integers::<u8>());
    for limit in [config.ring_default, config.ring_max] {
        for size in [limit - 1, limit, limit + 1] {
            let mut ring = Ring::new(limit);
            let mut history: Vec<u8> = (0..size)
                .map(|index| seed.wrapping_add(u8::try_from(index % 251).expect("bounded byte")))
                .collect();
            ring.push(&history);
            let mut first_retained = size.saturating_sub(limit);
            let resized = tc.draw(gs::sampled_from(&[1_usize, limit - 1, limit, limit + 1]));
            ring.set_capacity(resized);
            first_retained = first_retained.max(size.saturating_sub(resized));
            let extra = [seed ^ 0xff, 0, seed];
            ring.push(&extra);
            history.extend_from_slice(&extra);
            first_retained = first_retained.max(history.len().saturating_sub(resized));
            let base = u64::try_from(first_retained).expect("bounded base");
            let tail = u64::try_from(history.len()).expect("bounded tail");
            assert_eq!(ring.capacity(), resized);
            assert_eq!(ring.base(), base);
            assert_eq!(ring.tail(), tail);
            for cursor in [
                0,
                base.saturating_sub(1),
                base,
                base + 1,
                tail - 1,
                tail,
                tail + 1,
            ] {
                let start = cursor.max(base).min(tail);
                assert_eq!(
                    ring.replay_from(cursor),
                    (
                        start,
                        history[usize::try_from(start).expect("bounded cursor")..].to_vec()
                    )
                );
            }
        }
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] terminal-ring-fixed-shrink-grow
/// Growing after explicit truncation MUST NOT restore discarded bytes, and a
/// subsequent append MUST preserve the surviving old suffix before new bytes.
#[hegel::test(test_cases = 16)]
fn fixed_shrink_grow_preserves_only_surviving_bytes(tc: TestCase) {
    let original: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(17).max_size(17));
    let extra: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(3).max_size(3));
    let mut ring = Ring::new(8);
    ring.push(&original);
    assert_eq!(ring.base(), 9);
    ring.set_capacity(2);
    assert_eq!(ring.base(), 15);
    ring.set_capacity(16);
    assert_eq!(ring.base(), 15);
    assert_eq!(ring.replay_from(0), (15, original[15..].to_vec()));
    ring.push(&extra);
    let history: Vec<u8> = original.into_iter().chain(extra).collect();
    assert_eq!(ring.base(), 15);
    assert_eq!(ring.tail(), 20);
    for cursor in [0_u64, 14, 15, 16, 17, 18, 19, 20, 21] {
        let start = cursor.clamp(15, 20);
        assert_eq!(
            ring.replay_from(cursor),
            (
                start,
                history[usize::try_from(start).expect("bounded cursor")..].to_vec()
            )
        );
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] terminal-frame-header-refusals
/// Partial headers MUST remain incomplete. Once a full header is present, bad
/// magic or a declared payload above `MAX_PAYLOAD` MUST refuse without waiting
/// for payload bytes, regardless of following data.
#[hegel::test(test_cases = 100)]
fn malformed_frame_headers_refuse_before_payload(tc: TestCase) {
    let op = tc.draw(gs::integers::<u8>());
    let magic_index = tc.draw(gs::integers::<u8>().max_value(u8::MAX - 1));
    let bad_magic = if magic_index >= frame::MAGIC {
        magic_index + 1
    } else {
        magic_index
    };
    let oversized = tc.draw(
        gs::integers::<u16>()
            .min_value(u16::try_from(frame::MAX_PAYLOAD + 1).expect("bounded ceiling"))
            .max_value(u16::MAX),
    );
    let declared = oversized.to_be_bytes();
    for header in [
        [bad_magic, op, 0, 0],
        [frame::MAGIC, op, declared[0], declared[1]],
        [frame::MAGIC, op, 0xff, 0xff],
    ] {
        for length in 0..4 {
            assert_eq!(frame::decode(&header[..length]), None);
        }
        assert_eq!(frame::decode(&header), Some(Err(())));
        let mut with_trailing = header.to_vec();
        let trailing: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(32));
        with_trailing.extend_from_slice(&trailing);
        assert_eq!(frame::decode(&with_trailing), Some(Err(())));
    }
}

fn alphanumeric(tc: &TestCase, min: usize, max: usize) -> String {
    let alphabet: Vec<char> = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        .chars()
        .collect();
    let chars: Vec<char> = tc.draw(
        gs::vecs(gs::sampled_from(&alphabet))
            .min_size(min)
            .max_size(max),
    );
    chars.into_iter().collect()
}

/// @cc [owner:ghuntley,label:verification;protocol] terminal-control-payload-codecs
/// Every well-formed HELLO, CREATE, KILL, RESIZE and ATTACH payload MUST decode
/// to exactly its encoded fields; any truncation or trailing byte MUST refuse,
/// and arbitrary bounded bytes MUST decode without panicking.
#[hegel::test(test_cases = 100)]
fn control_payload_decoders_round_trip_and_refuse_extents(tc: TestCase) {
    let id = tc.draw(gs::integers::<u64>());
    let cols = tc.draw(gs::integers::<u16>());
    let rows = tc.draw(gs::integers::<u16>());
    let cursor = tc.draw(gs::integers::<u64>());
    let mode = tc.draw(gs::integers::<u8>());
    let nonce: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(16).max_size(16));
    let tag: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(32).max_size(32));
    let user = alphanumeric(&tc, 1, 64);
    let term = alphanumeric(&tc, 1, 64);

    let mut hello = nonce.clone();
    hello.extend_from_slice(&tag);
    let mut create = vec![u8::try_from(user.len()).expect("bounded user")];
    create.extend_from_slice(user.as_bytes());
    create.push(u8::try_from(term.len()).expect("bounded term"));
    create.extend_from_slice(term.as_bytes());
    frame::put_u16(&mut create, cols);
    frame::put_u16(&mut create, rows);
    let mut kill = Vec::new();
    frame::put_u64(&mut kill, id);
    let mut resize = kill.clone();
    frame::put_u16(&mut resize, cols);
    frame::put_u16(&mut resize, rows);
    let mut attach = kill.clone();
    frame::put_bytes(&mut attach, &nonce);
    attach.push(mode);
    frame::put_u64(&mut attach, cursor);
    frame::put_u16(&mut attach, cols);
    frame::put_u16(&mut attach, rows);

    assert_eq!(
        session::decode_hello(&hello),
        Some((nonce.clone(), tag.clone()))
    );
    assert_eq!(
        session::decode_create(&create),
        Some((user, term, cols, rows))
    );
    assert_eq!(session::decode_kill(&kill), Some(id));
    assert_eq!(session::decode_resize(&resize), Some((id, cols, rows)));
    let request = session::decode_attach(&attach).expect("well-formed attach");
    assert_eq!(
        (
            request.id,
            request.mode,
            request.cursor,
            request.cols,
            request.rows
        ),
        (id, mode, cursor, cols, rows)
    );
    assert!(request.token == nonce, "attach token field differs");

    let extra = tc.draw(gs::integers::<u8>());
    let arbitrary: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(160));
    let mut candidates: Vec<Vec<u8>> = vec![arbitrary.clone()];
    for payload in [&hello, &create, &kill, &resize, &attach] {
        let cut = tc.draw(gs::integers::<usize>().max_value(payload.len() - 1));
        candidates.push(payload[..cut].to_vec());
        candidates.push(payload[..payload.len() - 1].to_vec());
        candidates.push([payload.as_slice(), &[extra]].concat());
    }
    // Fixed-width payloads decode exactly when their length matches.
    for candidate in &candidates {
        assert_eq!(
            session::decode_hello(candidate).is_some(),
            candidate.len() == 48
        );
        assert_eq!(
            session::decode_kill(candidate).is_some(),
            candidate.len() == 8
        );
        assert_eq!(
            session::decode_resize(candidate).is_some(),
            candidate.len() == 12
        );
        assert_eq!(
            session::decode_attach(candidate).is_some(),
            candidate.len() == 37
        );
    }
    for candidate in [
        &create[..create.len() - 1],
        &[create.as_slice(), &[extra]].concat(),
    ] {
        assert_eq!(session::decode_create(candidate), None);
    }
    let _ = session::decode_create(&arbitrary);
}

/// @cc [owner:ghuntley,label:verification;security] terminal-hmac-streaming-oracle
/// SHA-256 and HMAC tags MUST be independent of how a message is split into
/// parts, keys longer than one block MUST behave as their SHA-256 digest
/// (RFC 2104), and `constant_time_equal` MUST agree with slice equality.
#[hegel::test(test_cases = 100)]
fn digest_and_tag_are_split_invariant(tc: TestCase) {
    let message: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(300));
    let key: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(160));
    let first = tc.draw(gs::integers::<usize>().max_value(message.len()));
    let second = tc.draw(
        gs::integers::<usize>()
            .min_value(first)
            .max_value(message.len()),
    );
    let parts: [&[u8]; 3] = [
        &message[..first],
        &message[first..second],
        &message[second..],
    ];
    assert!(
        crypto::digest(&parts) == crypto::digest(&[&message]),
        "digest depends on split"
    );
    assert!(
        crypto::tag(&key, &parts) == crypto::tag(&key, &[&message]),
        "tag depends on split"
    );
    let mut mac = crypto::Hmac::new(&key);
    for part in parts {
        mac.update(part);
    }
    assert!(
        mac.finish() == crypto::tag(&key, &[&message]),
        "incremental tag differs"
    );
    if key.len() > 64 {
        let hashed = crypto::digest(&[&key]);
        assert!(
            crypto::tag(&key, &[&message]) == crypto::tag(&hashed, &[&message]),
            "long key not hashed"
        );
    }
    let other: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(40));
    let tag = crypto::tag(&key, &[&message]);
    assert_eq!(
        crypto::constant_time_equal(&tag, &other),
        tag.as_slice() == other.as_slice()
    );
    assert!(crypto::constant_time_equal(&tag, &tag));
    let index = tc.draw(gs::integers::<usize>().max_value(31));
    let bit = tc.draw(gs::integers::<u8>().max_value(7));
    let mut flipped = tag;
    flipped[index] ^= 1 << bit;
    assert!(!crypto::constant_time_equal(&tag, &flipped));
    assert!(!crypto::constant_time_equal(&tag, &tag[..index]));
}

/// @cc [owner:ghuntley,label:verification;security] terminal-hello-proof-lattice
/// `verify_hello` MUST accept the minted tag for a 16-byte nonce and refuse any
/// single-bit change, any truncation or extension, any other nonce length, and
/// the same proof under a different placement or execution epoch.
#[hegel::test(test_cases = 100)]
fn hello_proof_accepts_only_the_exact_binding(tc: TestCase) {
    let key: [u8; 32] = tc
        .draw(gs::vecs(gs::integers::<u8>()).min_size(32).max_size(32))
        .try_into()
        .expect("bounded key");
    let epoch = tc.draw(gs::integers::<u64>().min_value(1));
    let placement = "11111111-1111-4111-8111-111111111111".to_string();
    let daemon = session::Daemon::new(
        session::Config::default(),
        key,
        placement.clone(),
        epoch.to_string(),
    );
    let nonce: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(16).max_size(16));
    let tag = daemon.hello_tag(&nonce);
    assert!(daemon.verify_hello(&nonce, &tag));
    let index = tc.draw(gs::integers::<usize>().max_value(31));
    let bit = tc.draw(gs::integers::<u8>().max_value(7));
    let mut flipped = tag;
    flipped[index] ^= 1 << bit;
    assert!(!daemon.verify_hello(&nonce, &flipped));
    let mut other_nonce = nonce.clone();
    other_nonce[index % 16] ^= 1 << bit;
    assert!(!daemon.verify_hello(&other_nonce, &tag));
    let cut = tc.draw(gs::integers::<usize>().max_value(31));
    assert!(!daemon.verify_hello(&nonce, &tag[..cut]));
    assert!(!daemon.verify_hello(&nonce, &[tag.as_slice(), &[0]].concat()));
    assert!(!daemon.verify_hello(&nonce[..15], &tag));
    let other_epoch = session::Daemon::new(
        session::Config::default(),
        key,
        placement,
        epoch.wrapping_add(1).max(1).to_string(),
    );
    assert!(!other_epoch.verify_hello(&nonce, &tag));
    let other_placement = session::Daemon::new(
        session::Config::default(),
        key,
        "22222222-1111-4111-8111-111111111111".into(),
        epoch.to_string(),
    );
    assert!(!other_placement.verify_hello(&nonce, &tag));
}

/// @cc [owner:ghuntley,label:verification;security] terminal-boot-identity-lattice
/// Boot identity MUST be accepted exactly when the challenge is 64 lowercase
/// hex digits, the placement is a hyphenated 36-character hex UUID and the
/// epoch is a canonical positive decimal `u64`, checked by an independent oracle.
#[hegel::test(test_cases = 200)]
fn boot_identity_validation_matches_oracle(tc: TestCase) {
    let hex_lower: Vec<char> = "0123456789abcdef".chars().collect();
    let noisy: Vec<char> = "0123456789abcdefABCDEF-xg ".chars().collect();
    let challenge: String = match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => tc
            .draw(
                gs::vecs(gs::sampled_from(&hex_lower))
                    .min_size(64)
                    .max_size(64),
            )
            .into_iter()
            .collect(),
        1 => tc
            .draw(
                gs::vecs(gs::sampled_from(&noisy[..22]))
                    .min_size(64)
                    .max_size(64),
            )
            .into_iter()
            .collect(),
        _ => tc
            .draw(gs::vecs(gs::sampled_from(&noisy)).min_size(62).max_size(66))
            .into_iter()
            .collect(),
    };
    let placement: String = if tc.draw(gs::booleans()) {
        let hex: Vec<char> = tc.draw(
            gs::vecs(gs::sampled_from(&noisy[..22]))
                .min_size(32)
                .max_size(32),
        );
        let part = |range: std::ops::Range<usize>| hex[range].iter().collect::<String>();
        format!(
            "{}-{}-{}-{}-{}",
            part(0..8),
            part(8..12),
            part(12..16),
            part(16..20),
            part(20..32)
        )
    } else {
        tc.draw(gs::vecs(gs::sampled_from(&noisy)).min_size(34).max_size(38))
            .into_iter()
            .collect()
    };
    let epoch = if tc.draw(gs::booleans()) {
        tc.draw(gs::integers::<u64>()).to_string()
    } else {
        tc.draw(gs::vecs(gs::sampled_from(&['0', '1', '9', '+', '-', ' '])).max_size(21))
            .into_iter()
            .collect()
    };
    let challenge_ok = challenge.len() == 64 && challenge.chars().all(|c| hex_lower.contains(&c));
    let placement_ok = placement.len() == 36
        && placement.char_indices().all(|(index, c)| {
            if [8, 13, 18, 23].contains(&index) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        });
    let epoch_ok = !epoch.is_empty()
        && epoch.len() <= 20
        && epoch.chars().all(|c| c.is_ascii_digit())
        && !epoch.starts_with('0')
        && epoch.parse::<u64>().is_ok();
    let expected = (challenge_ok && placement_ok && epoch_ok)
        .then(|| (challenge.clone(), placement.clone(), epoch.clone()));
    assert_eq!(
        crate::validate_boot_identity(challenge, placement, epoch),
        expected
    );
}
