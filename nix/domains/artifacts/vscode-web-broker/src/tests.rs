use super::*;
use crate::validate::{base32_uuid, dns_label, dns_name};
use hegel::{Generator, TestCase, generators as gs};

fn fixture() -> (Preface, Boot, Descriptor) {
    let id = "11111111-1111-4111-8111-111111111111".to_owned();
    let package = Descriptor {
        protocol: 1,
        commit: "a".repeat(40),
        release: "b".repeat(64),
    };
    let boot = parse_boot(&format!(
        "lilly.placement={id} lilly.execution_epoch=7 lilly.ipv4=10.10.0.2"
    ))
    .unwrap();
    let binding = Binding {
        vm_id: id.clone(),
        host_id: id.clone(),
        placement_id: id.clone(),
        session_id: id.clone(),
        execution_epoch: 7,
        generation: 1,
        label: "e-ceirceircfardairceirceirce-ceirceircfardairceirceirce".to_owned(),
        service: "editor".to_owned(),
        port: PORT,
        user_id: id.clone(),
        guest_account_id: id,
        uid: 200_001,
        username: "alice".to_owned(),
        editor_protocol: 1,
        editor_commit: package.commit.clone(),
        editor_release: package.release.clone(),
        editor_origin:
            "https://e-ceirceircfardairceirceirce-ceirceircfardairceirceirce.apps.example.test"
                .to_owned(),
    };
    (
        Preface {
            version: 1,
            binding,
        },
        boot,
        package,
    )
}

/// @cc [owner:ghuntley,label:verification;security] broker-generation-boot-binding
/// Every positive logical generation MUST admit the bound physical boot, and
/// every foreign execution epoch MUST refuse as a boot mismatch.
#[hegel::test(test_cases = 64)]
fn generations_preserve_boot_but_foreign_epochs_never_authorize(tc: TestCase) {
    let generation = tc.draw(
        gs::integers::<u64>()
            .min_value(1)
            .max_value(i64::MAX.unsigned_abs() - 1),
    );
    let delta = tc.draw(gs::integers::<u64>().min_value(1).max_value(999_999));
    let (mut preface, boot, package) = fixture();
    preface.binding.generation = generation;
    assert_eq!(validate(&preface, &boot, &package), Ok(()));
    preface.binding.execution_epoch = 7 + delta;
    assert_eq!(validate(&preface, &boot, &package), Err(Refusal::Boot));
}

/// @cc [owner:ghuntley,label:verification;security] broker-preface-length-bound
/// Every length header above `MAX_PREFACE` MUST refuse as a frame error before
/// any body allocation or read.
#[hegel::test(test_cases = 64)]
fn size_headers_never_allocate_unbounded_frames(tc: TestCase) {
    let length = tc.draw(
        gs::integers::<u32>()
            .min_value(u32::try_from(MAX_PREFACE).unwrap() + 1)
            .max_value(u32::MAX - 1),
    );
    let mut bytes = &length.to_be_bytes()[..];
    assert_eq!(read_preface(&mut bytes), Err(Refusal::Frame));
}

/// @cc [owner:ghuntley,label:verification;security] broker-uid-package-refusal
/// Every system UID MUST refuse as a binding error and every single-character
/// commit change MUST refuse as a package mismatch.
#[hegel::test(test_cases = 64)]
fn non_account_uids_and_wrong_packages_cannot_authorize(tc: TestCase) {
    let uid = tc.draw(gs::integers::<u32>().max_value(199_999));
    let mutation = tc.draw(gs::integers::<usize>().max_value(39));
    let (mut preface, boot, package) = fixture();
    preface.binding.uid = uid;
    assert_eq!(validate(&preface, &boot, &package), Err(Refusal::Binding));
    preface.binding.uid = 200_001;
    preface
        .binding
        .editor_commit
        .replace_range(mutation..=mutation, "c");
    assert_eq!(validate(&preface, &boot, &package), Err(Refusal::Package));
}

/// @cc [owner:ghuntley,label:verification;security] broker-profile-slot-gateway
/// Every profile and host slot MUST yield exactly its own address and profile
/// gateway, and a duplicated boot field MUST refuse.
#[hegel::test(test_cases = 64)]
fn every_profile_slot_has_only_its_own_gateway(tc: TestCase) {
    let profile = tc.draw(gs::sampled_from(vec![10_u8, 20, 30, 40]));
    let slot = tc.draw(gs::integers::<u16>().min_value(2).max_value(65534));
    let [high, low] = slot.to_be_bytes();
    let line = format!(
        "lilly.placement=11111111-1111-4111-8111-111111111111 lilly.execution_epoch=7 lilly.ipv4=10.{profile}.{high}.{low}"
    );
    let boot = parse_boot(&line).unwrap();
    assert_eq!(boot.gateway, Ipv4Addr::new(10, profile, 0, 1));
    assert_eq!(boot.address, Ipv4Addr::new(10, profile, high, low));
    assert_eq!(
        parse_boot(&format!("{line} lilly.execution_epoch=7")),
        Err(Refusal::Boot)
    );
}

fn lower_hex(character: char) -> bool {
    "0123456789abcdef".contains(character)
}

/// @cc [owner:ghuntley,label:verification;security] broker-hex-oracle
/// hex MUST accept exactly strings of the requested length made only of
/// lowercase hexadecimal digits.
#[hegel::test(test_cases = 128)]
fn hex_matches_lowercase_digit_oracle(tc: TestCase) {
    let value = tc.draw(hegel::one_of!(
        gs::text().alphabet("0123456789abcdef").max_size(12),
        gs::text().alphabet("09afAFg- ").max_size(12),
        gs::text().max_size(12),
    ));
    let length = if tc.draw(gs::booleans()) {
        value.chars().count()
    } else {
        tc.draw(gs::integers::<usize>().max_value(12))
    };
    let expected = value.chars().count() == length && value.chars().all(lower_hex);
    assert_eq!(hex(&value, length), expected);
}

fn uuid_oracle(value: &str) -> bool {
    let groups = value.split('-').collect::<Vec<_>>();
    groups.iter().map(|group| group.len()).eq([8, 4, 4, 4, 12])
        && groups.iter().all(|group| group.chars().all(lower_hex))
}

/// @cc [owner:ghuntley,label:verification;security] broker-uuid-oracle
/// uuid MUST accept exactly lowercase 8-4-4-4-12 hexadecimal groups, as
/// decided by an independent group-splitting oracle over valid UUIDs, single
/// character mutations of them and arbitrary text.
#[hegel::test(test_cases = 128)]
fn uuid_matches_group_oracle(tc: TestCase) {
    let base = tc.draw(gs::uuids()).to_ascii_lowercase();
    assert!(uuid(&base));
    let mut characters = base.chars().collect::<Vec<_>>();
    let position = tc.draw(gs::integers::<usize>().max_value(35));
    characters[position] = tc.draw(gs::sampled_from(vec!['0', 'f', 'g', 'A', '-', ' ', 'é']));
    let mutated = characters.into_iter().collect::<String>();
    assert_eq!(uuid(&mutated), uuid_oracle(&mutated));
    let arbitrary = tc.draw(hegel::one_of!(
        gs::text().alphabet("0a-").max_size(40),
        gs::text().max_size(40),
    ));
    assert_eq!(uuid(&arbitrary), uuid_oracle(&arbitrary));
}

const RESERVED_USERNAMES: [&str; 22] = [
    "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy",
    "www-data", "backup", "list", "irc", "gnats", "nobody", "ubuntu", "sshd", "sudo", "postgres",
];

fn username_model(value: &str) -> bool {
    let characters = value.chars().collect::<Vec<_>>();
    let body = |character: char| {
        character.is_ascii_lowercase() || character.is_ascii_digit() || "_.-".contains(character)
    };
    (1..=32).contains(&characters.len())
        && characters
            .first()
            .is_some_and(|first| first.is_ascii_lowercase() || *first == '_')
        && characters
            .last()
            .is_some_and(|last| last.is_ascii_lowercase() || last.is_ascii_digit() || *last == '_')
        && characters.iter().all(|character| body(*character))
        && !RESERVED_USERNAMES.contains(&value)
        && !value.starts_with("systemd-")
        && !value.starts_with("nixbld")
}

/// @cc [owner:ghuntley,label:verification;security] broker-username-lattice
/// username MUST accept exactly bounded lowercase POSIX names outside the
/// reserved system set. Every accepted name MUST be refused again after a
/// leading separator or capital, a trailing separator, a reserved systemd-
/// prefix or growth beyond 32 bytes.
#[hegel::test(test_cases = 192)]
fn username_accepts_only_the_closed_lattice(tc: TestCase) {
    let value = tc.draw(hegel::one_of!(
        gs::text().alphabet("abz09_.-").max_size(36),
        gs::text().alphabet("aZ/ é_").max_size(6),
        gs::sampled_from(RESERVED_USERNAMES.map(str::to_owned).to_vec()),
        gs::text()
            .alphabet("abc1")
            .max_size(4)
            .map(|suffix| format!("systemd-{suffix}")),
        gs::text()
            .alphabet("abc1")
            .max_size(4)
            .map(|suffix| format!("nixbld{suffix}")),
    ));
    assert_eq!(username(&value), username_model(&value));
    if username(&value) {
        for refused in [
            format!("-{value}"),
            format!(".{value}"),
            format!("A{value}"),
            format!("{value}-"),
            format!("{value}."),
            format!("systemd-{value}"),
            format!("{value}{}", "a".repeat(33 - value.len())),
        ] {
            assert!(!username(&refused));
        }
    }
}

fn dns_label_model(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=63).contains(&bytes.len())
        && bytes
            .iter()
            .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'-'))
        && bytes.first() != Some(&b'-')
        && bytes.last() != Some(&b'-')
}

/// @cc [owner:ghuntley,label:verification;security] broker-dns-bounds
/// `dns_label` MUST accept exactly 1..=63 lowercase LDH bytes without edge
/// hyphens; `dns_name` MUST accept exactly 3..=189 bytes of at least two such
/// labels.
#[hegel::test(test_cases = 128)]
fn dns_labels_and_names_respect_bounds(tc: TestCase) {
    let labels = tc.draw(
        gs::vecs(hegel::one_of!(
            gs::text().alphabet("ab09-").max_size(8),
            gs::text().alphabet("a-").min_size(60).max_size(66),
            gs::text().alphabet("aZ_é").max_size(3),
        ))
        .max_size(12),
    );
    for label in &labels {
        assert_eq!(dns_label(label), dns_label_model(label));
    }
    let name = labels.join(".");
    let expected = (3..=189).contains(&name.len())
        && labels.len() >= 2
        && labels.iter().all(|label| dns_label_model(label));
    assert_eq!(dns_name(&name), expected);
}

const BASE32: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";

/// RFC 4648 lowercase base32 without padding: 128 bits and two zero bits.
fn base32_encode(value: u128) -> String {
    (0..26)
        .map(|index| {
            let digit = if index < 25 {
                (value >> (123 - 5 * index)) & 31
            } else {
                (value & 7) << 2
            };
            char::from(BASE32[usize::try_from(digit).unwrap()])
        })
        .collect()
}

fn canonical_uuid(value: u128) -> String {
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        value >> 96,
        (value >> 80) & 0xffff,
        (value >> 64) & 0xffff,
        (value >> 48) & 0xffff,
        value & 0xffff_ffff_ffff
    )
}

/// @cc [owner:ghuntley,label:verification;security] broker-base32-uuid-roundtrip
/// `base32_uuid` MUST decode every RFC 4648 lowercase encoding of 16 bytes to
/// the canonical UUID that uuid accepts, and MUST refuse every other length,
/// foreign digit or nonzero padding.
#[hegel::test(test_cases = 128)]
fn base32_uuid_round_trips_with_uuid(tc: TestCase) {
    let value = u128::from_be_bytes(tc.draw(gs::arrays(gs::integers::<u8>())));
    let encoded = base32_encode(value);
    let decoded = base32_uuid(&encoded).unwrap();
    assert_eq!(decoded, canonical_uuid(value));
    assert!(uuid(&decoded));
    let candidate = tc.draw(hegel::one_of!(
        gs::text()
            .alphabet("abcdefghijklmnopqrstuvwxyz234567")
            .min_size(26)
            .max_size(26),
        gs::text().alphabet("az27A8=").max_size(28),
    ));
    let digits = candidate
        .bytes()
        .map(|byte| BASE32.iter().position(|digit| *digit == byte))
        .collect::<Option<Vec<_>>>();
    let accepted = digits.is_some_and(|digits| digits.len() == 26 && digits[25] % 4 == 0);
    match base32_uuid(&candidate) {
        Some(decoded) => {
            assert!(accepted);
            let value = u128::from_str_radix(&decoded.replace('-', ""), 16).unwrap();
            assert_eq!(base32_encode(value), candidate);
        }
        None => assert!(!accepted),
    }
}

const REFUSALS: [Refusal; 11] = [
    Refusal::Frame,
    Refusal::Binding,
    Refusal::Boot,
    Refusal::Package,
    Refusal::Origin,
    Refusal::Account,
    Refusal::Custody,
    Refusal::Startup,
    Refusal::Readiness,
    Refusal::Capacity,
    Refusal::Transport,
];

/// Exhaustive: a new variant fails to compile until REFUSALS lists it.
fn refusal_index(refusal: Refusal) -> usize {
    match refusal {
        Refusal::Frame => 0,
        Refusal::Binding => 1,
        Refusal::Boot => 2,
        Refusal::Package => 3,
        Refusal::Origin => 4,
        Refusal::Account => 5,
        Refusal::Custody => 6,
        Refusal::Startup => 7,
        Refusal::Readiness => 8,
        Refusal::Capacity => 9,
        Refusal::Transport => 10,
    }
}

/// @cc [owner:ghuntley,label:verification;security] broker-refusal-names-injective
/// `Refusal::name` MUST be injective over every variant and yield only closed
/// lowercase diagnostic reasons.
#[hegel::test(test_cases = 64)]
fn refusal_names_are_injective(tc: TestCase) {
    let first = tc.draw(gs::sampled_from(REFUSALS.as_slice()));
    let second = tc.draw(gs::sampled_from(REFUSALS.as_slice()));
    assert_eq!(REFUSALS[refusal_index(first)], first);
    assert_eq!(first.name() == second.name(), first == second);
    assert_ne!(first.name(), "");
    assert!(first.name().bytes().all(|byte| byte.is_ascii_lowercase()));
}

/// @cc [owner:ghuntley,label:verification;security] broker-webview-origin-refusal
/// `webview_template` MUST pin every canonical label-bound HTTPS origin's zone,
/// port and release, and MUST refuse with Origin for any scheme, userinfo,
/// path, query, fragment, default-port, case, foreign-label, trailing-dot,
/// single-label-zone or release mutation and for arbitrary text.
#[hegel::test(test_cases = 128)]
fn webview_templates_follow_only_canonical_origins(tc: TestCase) {
    let (mut preface, _, _) = fixture();
    let labels = tc.draw(
        gs::vecs(gs::text().alphabet("abcd019").min_size(1).max_size(8))
            .min_size(1)
            .max_size(3),
    );
    let zone = format!("{}.test", labels.join("."));
    let port = tc.draw(gs::optional(gs::integers::<u16>().min_value(1)));
    let suffix = port.map_or(String::new(), |port| format!(":{port}"));
    let label = preface.binding.label.clone();
    let host = format!("{label}.{zone}");
    let canonical = format!("https://{host}{suffix}");
    preface.binding.editor_origin.clone_from(&canonical);
    let release = preface.binding.editor_release.clone();
    if port == Some(443) {
        assert_eq!(webview_template(&preface.binding), Err(Refusal::Origin));
    } else {
        assert_eq!(
            webview_template(&preface.binding),
            Ok(format!(
                "https://{{{{uuid}}}}.{zone}{suffix}/code-assets/{release}/out/vs/workbench/contrib/webview/browser/pre/"
            ))
        );
    }
    let mutation = tc.draw(gs::integers::<u8>().max_value(12));
    let mutated = match mutation {
        0 => format!("http://{host}{suffix}"),
        1 => format!("{canonical}/"),
        2 => format!("{canonical}/path"),
        3 => format!("{canonical}?q=1"),
        4 => format!("{canonical}#f"),
        5 => format!("https://user@{host}{suffix}"),
        6 => format!("https://user:pw@{host}{suffix}"),
        7 => format!("https://f{host}{suffix}"),
        8 => format!("https://{}{suffix}", host.to_ascii_uppercase()),
        9 => format!("https://{host}:443"),
        10 => format!("https://{host}.{suffix}"),
        11 => format!("https://{label}.test{suffix}"),
        _ => {
            preface.binding.editor_release = "B".repeat(64);
            canonical
        }
    };
    preface.binding.editor_origin = mutated;
    assert_eq!(webview_template(&preface.binding), Err(Refusal::Origin));
    preface.binding.editor_origin = tc.draw(gs::text().max_size(40));
    assert_eq!(webview_template(&preface.binding), Err(Refusal::Origin));
}

#[test]
fn origins_are_canonical_and_templates_are_release_pinned() {
    let (mut preface, _, _) = fixture();
    let template = webview_template(&preface.binding).unwrap();
    assert_eq!(
        template,
        format!(
            "https://{{{{uuid}}}}.apps.example.test/code-assets/{}/out/vs/workbench/contrib/webview/browser/pre/",
            "b".repeat(64)
        )
    );
    let valid_origin = preface.binding.editor_origin.clone();
    for origin in [
        format!("{valid_origin}/"),
        valid_origin.replace("https:", "http:"),
        format!("{valid_origin}:443"),
        format!("{valid_origin}?x=1"),
        "https://foreign.apps.example.test".to_owned(),
        format!("{valid_origin}@evil.example.test"),
    ] {
        preface.binding.editor_origin = origin;
        assert_eq!(webview_template(&preface.binding), Err(Refusal::Origin));
    }
}

#[test]
fn duplicate_and_unknown_fields_are_refused() {
    for body in [
        br#"{"version":1,"version":1,"binding":{}}"#.as_slice(),
        br#"{"version":1,"binding":{},"extra":1}"#.as_slice(),
    ] {
        let mut framed = u32::try_from(body.len()).unwrap().to_be_bytes().to_vec();
        framed.extend_from_slice(body);
        assert_eq!(read_preface(&mut framed.as_slice()), Err(Refusal::Frame));
    }
}

#[test]
fn current_account_names_preserve_dots_and_reject_reserved_names() {
    for value in ["alice", "a", "_", "first.last", "alice_g200001"] {
        assert!(username(value));
    }
    for value in [
        "root",
        "ubuntu",
        "systemd-user",
        "nixbld1",
        "-alice",
        "alice-",
        "a..",
        "Alice",
        "alice/bob",
    ] {
        assert!(!username(value));
    }
}

#[test]
fn labels_require_zero_padding_and_exact_account_identity() {
    let (mut preface, boot, package) = fixture();
    preface.binding.label.replace_range(54..55, "f");
    assert_eq!(validate(&preface, &boot, &package), Err(Refusal::Binding));
    let (mut preface, boot, package) = fixture();
    preface.binding.guest_account_id = "22222222-2222-4222-8222-222222222222".to_owned();
    assert_eq!(validate(&preface, &boot, &package), Err(Refusal::Binding));
}
