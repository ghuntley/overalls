use super::*;
use hegel::generators as gs;
use hegel::TestCase;
use std::collections::BTreeSet;

const DATASET: &str = "tank/lilly/vm-owned";
const TARGET: &str = "/pool/vms/owned";

fn os_line(root: &str, mountpoint: &str, fstype: &str, source: &str) -> String {
    format!("20 1 0:20 {root} {mountpoint} rw - {fstype} {source} rw\n")
}

fn c_fixture(name: &str, text: &str) -> MountState {
    let directory = tempfile::tempdir().expect("fixture directory");
    let path = directory.path().join(name);
    std::fs::write(&path, text).expect("staged mountinfo");
    inspect_path(&path, DATASET, TARGET)
}

#[test]
fn the_c_self_test_matrix_is_preserved_verbatim() {
    let exact = os_line("/", TARGET, "zfs", DATASET);
    let other = "21 1 0:21 / /pool/vms/other rw - zfs tank/lilly/vm-other rw\n";
    let alias = os_line("/", "/other", "zfs", DATASET);
    let child = os_line("/", "/pool/vms/owned/child", "tmpfs", "tmpfs");
    let replacement = os_line("/", TARGET, "tmpfs", "tmpfs");
    let malformed = "25 1 0:25 / /pool/vms/owned rw - zfs\n";
    assert_eq!(c_fixture("exact", &exact), MountState::Exact);
    assert_eq!(c_fixture("other", other), MountState::Absent);
    assert_eq!(c_fixture("alias", &alias), MountState::Unsafe);
    assert_eq!(c_fixture("child", &child), MountState::Unsafe);
    assert_eq!(c_fixture("replacement", &replacement), MountState::Unsafe);
    assert_eq!(c_fixture("malformed", malformed), MountState::InspectError);
    assert_eq!(
        c_fixture("duplicate", &format!("{exact}{exact}")),
        MountState::Unsafe
    );
    assert_eq!(
        c_fixture("exact-child", &format!("{exact}{child}")),
        MountState::Unsafe
    );
    assert_eq!(
        c_fixture("other-exact", &format!("{other}{exact}")),
        MountState::Exact
    );
    for index in 0..10_000 {
        let line = os_line("/", &format!("{TARGET}/{index}"), "tmpfs", "tmpfs");
        assert_eq!(c_fixture("descendant", &line), MountState::Unsafe);
        if index >= 1999 {
            break;
        }
        let _ = index;
    }
}

/// @cc [owner:ghuntley,label:verification] hegel-validator-oracle
/// Generated dataset/path strings MUST be classified by the independent
/// character-class spec, not by the implementation's own parsing.
#[hegel::test(test_cases = 100)]
fn dataset_and_path_validators_match_independent_spec(tc: TestCase) {
    // Valid shape ingredients, corrupted editions and outright foreign bytes.
    let mut words = vec![
        "tank/lilly/vm-owned".to_string(),
        "pool/DS_1-2.3:4@snap".to_string(),
        String::new(),
        "/leading".to_string(),
        "trailing/".to_string(),
        "double//slash".to_string(),
        "dot..dot".to_string(),
        "space value".to_string(),
        "bang!value".to_string(),
    ];
    words.push("a".repeat(tc.draw(gs::integers::<usize>().min_value(250).max_value(260))));
    words.push(
        tc.draw(gs::sampled_from(&[
            "fine",
            "fin/./e",
            "fin/../e",
            "escape\\040",
        ]))
        .to_string(),
    );
    let candidate: String = tc.draw(gs::sampled_from(&words)).clone();
    let bytes = candidate.as_bytes();
    let charset = bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_-/.:@".contains(byte));
    let size = bytes.len();
    let dataset_spec = (1..=255).contains(&size)
        && !candidate.starts_with('/')
        && !candidate.ends_with('/')
        && charset
        && !candidate.contains("//")
        && !candidate.contains("..");
    assert_eq!(valid_dataset(&candidate), dataset_spec, "{candidate:?}");
    let path_spec = (2..=4096).contains(&size)
        && candidate.starts_with('/')
        && !candidate.ends_with('/')
        && charset
        && !candidate.contains("//")
        && !candidate.contains("/../")
        && !candidate.contains("/./")
        && !candidate.ends_with("/..")
        && !candidate.ends_with("/.");
    assert_eq!(valid_path(&candidate), path_spec, "{candidate:?}");
}

/// @cc [owner:ghuntley,label:verification] hegel-name-character-class-oracle
/// Arbitrary byte strings MUST pass the shared character-class check exactly
/// when every byte is in the explicitly enumerated pool-local alphabet.
#[hegel::test(test_cases = 200)]
fn character_class_matches_enumerated_alphabet(tc: TestCase) {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-/.:@";
    let bytes = tc.draw(gs::binary().max_size(64));
    let expected = bytes.iter().all(|byte| ALPHABET.contains(byte));
    assert_eq!(clean(&bytes), expected);
}

#[hegel::test(test_cases = 100)]
fn octal_decoding_matches_independent_model(tc: TestCase) {
    let words = [
        "abc", r"\040", r"\011tab", "plain", r"\1short", r"\99x", "end\\",
    ];
    let mut field: Vec<u8> = tc
        .draw(gs::vecs(gs::sampled_from(&words)).min_size(0).max_size(6))
        .concat()
        .into_bytes();
    let mut expected = Vec::new();
    let mut index = 0;
    let mut valid = true;
    let source: Vec<u8> = field.clone();
    while index < source.len() {
        if source[index] == b'\\' {
            if index + 3 >= source.len()
                || !source[index + 1..=index + 3]
                    .iter()
                    .all(|byte| (b'0'..=b'7').contains(byte))
            {
                valid = false;
                break;
            }
            expected.push(
                (source[index + 1] - b'0') * 64
                    + (source[index + 2] - b'0') * 8
                    + (source[index + 3] - b'0'),
            );
            index += 4;
        } else {
            expected.push(source[index]);
            index += 1;
        }
    }
    let outcome = decode_mount_field(&mut field);
    assert_eq!(outcome, valid, "field {source:?}");
    if valid {
        assert_eq!(field, expected, "field {source:?}");
    }
}

fn shaped_line(root: &str, target: &str, fstype: &str, source: &str, id_salt: usize) -> String {
    format!(
        "{} 1 0:{} {} {} rw - {} {} rw\n",
        20 + id_salt,
        20 + id_salt,
        root,
        target,
        fstype,
        source
    )
}

/// @cc [owner:ghuntley,label:verification] hegel-mountinfo-classification-oracle
/// Generated mountinfo lines MUST be classified by the independent model: only
/// one exact "/" / target / dataset / zfs tuple, once; every other related row
/// or repeat is UNSAFE; foreign rows are ABSENT.
#[hegel::test(test_cases = 100)]
fn mountinfo_classification_matches_independent_model(tc: TestCase) {
    let target_suffix = tc.draw(gs::sampled_from(&["", "/child", "/deep/nest"]));
    let pick = |tc: &TestCase| -> (String, String, String, String, usize) {
        let target = if tc.draw(gs::booleans()) {
            TARGET.to_string()
        } else {
            format!("{TARGET}{target_suffix}")
        };
        let source = if tc.draw(gs::booleans()) {
            DATASET.to_string()
        } else {
            tc.draw(gs::sampled_from(&[
                format!("{DATASET}[snap@a]"),
                "tank/lilly/vm-other".to_string(),
                "tmpfs".to_string(),
            ]))
        };
        (
            if tc.draw(gs::booleans()) {
                "/".to_string()
            } else {
                "/root".to_string()
            },
            target,
            if tc.draw(gs::booleans()) {
                "zfs".to_string()
            } else {
                "tmpfs".to_string()
            },
            source,
            tc.draw(gs::integers::<usize>().min_value(0).max_value(9)),
        )
    };
    let line_count = tc.draw(gs::integers::<usize>().min_value(1).max_value(4));
    let mut expected = MountState::Absent;
    let mut content = String::new();
    for salt in 0..line_count {
        let (root, target, fstype, source, id_salt) = pick(&tc);
        let salt = salt * 10 + id_salt;
        content.push_str(&shaped_line(&root, &target, &fstype, &source, salt));
        let related_source = source == DATASET || source.starts_with(&format!("{DATASET}["));
        let related_target = target == TARGET || target.starts_with(&format!("{TARGET}/"));
        if !related_source && !related_target {
            continue;
        }
        let exact = root == "/" && target == TARGET && source == DATASET && fstype == "zfs";
        // The C loop: a related row that is exact while EXACT is already seen —
        // or any related but non-exact row — is UNSAFE and ends the scan.
        if exact && expected == MountState::Absent {
            expected = MountState::Exact;
            continue;
        }
        expected = MountState::Unsafe;
        break;
    }
    match expected {
        MountState::Absent => {
            assert_eq!(c_fixture("generated", &content), MountState::Absent);
        }
        MountState::Exact => assert_eq!(c_fixture("generated", &content), MountState::Exact),
        MountState::Unsafe => assert_eq!(c_fixture("generated", &content), MountState::Unsafe),
        MountState::InspectError => unreachable!(),
    }
}

#[hegel::test(test_cases = 100)]
fn overlong_and_overpopulated_lines_are_inspect_errors(_tc: TestCase) {
    let long = os_line("/", TARGET, "zfs", DATASET) + &"x".repeat(MAX_LINE);
    assert_eq!(c_fixture("long", &long), MountState::InspectError);
    let many = (0..260)
        .map(|i| format!("f{i}"))
        .collect::<Vec<_>>()
        .join(" ");
    let line = format!("{many} - zfs {DATASET} rw\n");
    assert_eq!(c_fixture("many", &line), MountState::InspectError);
}

#[hegel::test(test_cases = 100)]
fn sweep_plan_dedups_and_caps_namespaces(tc: TestCase) {
    let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(10));
    let mut observations = Vec::new();
    for index in 0..count {
        let key = (1000_u64 + index as u64, 2000_u64 + index as u64);
        let state = tc.draw(gs::sampled_from(&[
            MountState::Absent,
            MountState::Exact,
            MountState::Unsafe,
            MountState::InspectError,
        ]));
        observations.push(NamespaceObservation { key, state });
        if tc.draw(gs::booleans()) {
            observations.push(NamespaceObservation { key, state });
        }
    }
    let outcome = plan(&observations);
    let any_unsafe = observations
        .iter()
        .any(|o| matches!(o.state, MountState::Unsafe | MountState::InspectError));
    let expected_dedup_len = {
        let mut seen: Vec<(u64, u64)> = Vec::new();
        for observation in &observations {
            if observation.state == MountState::Exact && !seen.contains(&observation.key) {
                seen.push(observation.key);
            }
        }
        seen.len()
    };
    match outcome {
        SweepPlan::Unconfirmed => {
            assert!(
                any_unsafe || expected_dedup_len > MAX_NAMESPACES,
                "Unconfirmed without violation: {observations:?}"
            );
        }
        SweepPlan::Plan(keys) => {
            assert!(!any_unsafe);
            let mut unique = keys.clone();
            unique.dedup();
            assert_eq!(unique.len(), keys.len(), "duplicates leaked");
            assert!(keys.len() <= MAX_NAMESPACES);
            assert_eq!(keys.len(), expected_dedup_len);
            let expected: BTreeSet<(u64, u64)> = observations
                .iter()
                .filter(|observation| observation.state == MountState::Exact)
                .map(|observation| observation.key)
                .collect();
            assert_eq!(keys.iter().copied().collect::<BTreeSet<_>>(), expected);
        }
    }
}

/// @cc [owner:ghuntley,label:verification] namespace-plan-cap-boundaries
/// Plans MUST contain every distinct exact namespace once up to the cap and
/// fail closed above it. Duplicate descriptor observations MUST NOT consume
/// distinct-namespace capacity; tests do not establish native unmount safety.
#[hegel::test(test_cases = 100)]
fn exact_namespace_cap_preserves_all_targets(tc: TestCase) {
    let generated = tc.draw(
        gs::integers::<usize>()
            .min_value(0)
            .max_value(MAX_NAMESPACES + 1),
    );
    let base = tc.draw(gs::integers::<u64>().min_value(1).max_value(100_000));
    let duplicate = tc.draw(gs::booleans());
    for count in [
        generated,
        MAX_NAMESPACES - 1,
        MAX_NAMESPACES,
        MAX_NAMESPACES + 1,
    ] {
        let mut observations = Vec::new();
        let mut expected: BTreeSet<(u64, u64)> = BTreeSet::new();
        for index in 0..count {
            let value = u64::try_from(index).expect("bounded fixture index");
            let key = (base + value, base + value + 1);
            expected.insert(key);
            let observation = NamespaceObservation {
                key,
                state: MountState::Exact,
            };
            observations.push(observation);
            if duplicate {
                observations.push(observation);
            }
        }
        if count > MAX_NAMESPACES {
            assert_eq!(plan(&observations), SweepPlan::Unconfirmed);
        } else {
            let SweepPlan::Plan(keys) = plan(&observations) else {
                panic!("bounded exact inventory refused");
            };
            assert_eq!(keys.len(), expected.len());
            assert_eq!(keys.into_iter().collect::<BTreeSet<_>>(), expected);
        }
    }
}

/// @cc [owner:ghuntley,label:verification] namespace-plan-inventory-cap
/// The observation cap MUST include absent and duplicate namespace entries.
/// An exact target MUST survive at the cap; one more observation MUST refuse
/// the entire plan even when only one distinct target requires cleanup.
#[hegel::test(test_cases = 100)]
fn observation_cap_counts_absent_and_duplicate_entries(tc: TestCase) {
    let generated = tc.draw(gs::sampled_from(&[
        0,
        1,
        MAX_PROCESSES - 1,
        MAX_PROCESSES,
        MAX_PROCESSES + 1,
    ]));
    let duplicate = tc.draw(gs::booleans());
    for count in [
        generated,
        MAX_PROCESSES - 1,
        MAX_PROCESSES,
        MAX_PROCESSES + 1,
    ] {
        let key = (11_u64, 12_u64);
        let mut observations = vec![
            NamespaceObservation {
                key,
                state: if duplicate {
                    MountState::Exact
                } else {
                    MountState::Absent
                },
            };
            count
        ];
        if let Some(first) = observations.first_mut() {
            first.state = MountState::Exact;
        }
        if count > MAX_PROCESSES {
            assert_eq!(plan(&observations), SweepPlan::Unconfirmed);
        } else {
            let expected = if count == 0 { Vec::new() } else { vec![key] };
            assert_eq!(plan(&observations), SweepPlan::Plan(expected));
        }
    }
}
