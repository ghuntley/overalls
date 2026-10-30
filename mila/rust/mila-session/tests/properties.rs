use hegel::{generators as gs, TestCase};
use mila_session::decode_listing;
use serde_json::{json, Value};

#[expect(
    clippy::fn_params_excessive_bools,
    reason = "test fixture mirrors the listing row flags one-to-one"
)]
fn row(index: u8, write: bool, manage: bool, owner: bool, pinned: bool) -> Value {
    json!({"id": format!("00000000-0000-0000-0000-{index:012x}"), "name": "machine",
        "desired_state": "running", "observed_state": "running", "pinned": pinned,
        "owner": owner, "permissions": {"read": true, "write": write, "manage": manage}})
}
#[expect(
    clippy::unwrap_used,
    clippy::needless_pass_by_value,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test; it takes owned rows so call sites can build them inline"
)]
fn envelope(rows: Vec<Value>, cursor: Option<String>) -> Vec<u8> {
    serde_json::to_vec(&json!({"version": 1, "status": "succeeded", "result": {"items": rows, "next_cursor": cursor}})).unwrap()
}

#[hegel::test(test_cases = 128)]
fn decoded_permissions_never_gain_authority(tc: TestCase) {
    let write = tc.draw(gs::default::<bool>());
    let manage = tc.draw(gs::default::<bool>());
    let owner = tc.draw(gs::default::<bool>());
    let pinned = tc.draw(gs::default::<bool>());
    let index = tc.draw(gs::default::<u8>());
    let listing = decode_listing(&envelope(
        vec![row(index, write, manage, owner, pinned)],
        None,
    ))
    .unwrap();
    let m = &listing.machines()[0];
    assert_eq!(
        (m.write, m.manage, m.owner.is_some(), m.pinned),
        (write, manage, owner, pinned)
    );
    let actions = m.available_actions();
    assert_eq!(actions.contains(&mila_runtime::MachineAction::Stop), write);
    assert_eq!(
        actions.contains(&mila_runtime::MachineAction::Delete),
        manage && owner && !pinned
    );
}

#[hegel::test(test_cases = 128)]
fn malformed_machine_identity_and_authority_are_refused(tc: TestCase) {
    let index = tc.draw(gs::default::<u8>());
    let which = tc.draw(gs::default::<u8>()) % 4;
    let mut m = row(index, true, true, true, false);
    match which {
        0 => m["id"] = json!("not-a-uuid"),
        1 => m["permissions"]["write"] = json!("true"),
        2 => m["owner"] = json!(1),
        _ => m["desired_state"] = json!("future-state"),
    }
    assert!(decode_listing(&envelope(vec![m], None)).is_err());
}

#[hegel::test(test_cases = 128)]
fn arbitrary_bytes_and_duplicate_ids_never_form_a_listing(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(4096));
    let _ = decode_listing(&bytes);
    let index = tc.draw(gs::default::<u8>());
    let m = row(index, true, true, true, false);
    assert!(decode_listing(&envelope(vec![m.clone(), m], None)).is_err());
}

#[hegel::test(test_cases = 128)]
fn valid_cursor_is_preserved_without_changing_authority(tc: TestCase) {
    let count = tc.draw(gs::default::<u8>()) % 8;
    let has_cursor = tc.draw(gs::default::<bool>());
    let rows = (0..count)
        .map(|index| row(index, false, false, false, index % 2 == 0))
        .collect();
    let cursor = has_cursor.then(|| "00000000-0000-0000-0000-000000000001".to_owned());
    let listing = decode_listing(&envelope(rows, cursor)).unwrap();
    assert_eq!(listing.has_more(), has_cursor);
    for machine in listing.machines() {
        assert!(!machine.write);
        assert!(!machine.manage);
        assert!(machine.owner.is_none());
        assert!(!machine
            .available_actions()
            .contains(&mila_runtime::MachineAction::Delete));
    }
}

#[test]
fn read_envelope_and_cursor_are_closed_while_descriptions_are_extensible() {
    let mut m = row(1, true, true, true, false);
    m["future_description"] = json!({"ignored": true});
    m["observed_state"] = json!("future-state");
    let valid = envelope(vec![m.clone()], None);
    let listing = decode_listing(&valid).unwrap();
    assert_eq!(listing.machines()[0].observed_state, None);
    for field in ["version", "status", "request_id"] {
        let mut invalid: Value = serde_json::from_slice(&valid).unwrap();
        invalid[field] = json!("unexpected");
        assert!(decode_listing(&serde_json::to_vec(&invalid).unwrap()).is_err());
    }
    assert!(decode_listing(&envelope(vec![m], Some("bad --json".into()))).is_err());
}

#[test]
fn oversized_pages_and_names_fail_before_projection() {
    let rows: Vec<Value> = (0..=500)
        .map(|index| {
            let mut m = row(0, false, false, false, false);
            m["id"] = json!(format!("00000000-0000-0000-0000-{index:012x}"));
            m
        })
        .collect();
    assert!(decode_listing(&envelope(rows, None)).is_err());
    let mut m = row(0, false, false, false, false);
    m["name"] = json!("x".repeat(4097));
    assert!(decode_listing(&envelope(vec![m], None)).is_err());
    assert!(decode_listing(&vec![b' '; (1 << 20) + 1]).is_err());
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-session-listing-order
/// A decoded listing MUST be ordered pinned first, then by name, then by id,
/// whatever the server's row order, and MUST keep exactly the server's rows.
#[hegel::test(test_cases = 128)]
fn listing_order_is_canonical_and_independent_of_row_order(tc: TestCase) {
    let count = tc.draw(gs::integers::<usize>().max_value(12));
    let rows: Vec<Value> = (0..count)
        .map(|index| {
            let mut m = row(
                u8::try_from(index).unwrap(),
                false,
                false,
                false,
                tc.draw(gs::booleans()),
            );
            m["name"] = json!(tc.draw(gs::text().alphabet("ab").min_size(1).max_size(2)));
            m
        })
        .collect();
    let keys = tc.draw(
        gs::vecs(gs::default::<u32>())
            .min_size(count)
            .max_size(count),
    );
    let mut order: Vec<usize> = (0..count).collect();
    order.sort_by_key(|index| keys[*index]);
    let shuffled: Vec<Value> = order.iter().map(|index| rows[*index].clone()).collect();
    let listing = decode_listing(&envelope(rows.clone(), None)).unwrap();
    let reordered = decode_listing(&envelope(shuffled, None)).unwrap();
    assert_eq!(listing.machines(), reordered.machines());
    for pair in listing.machines().windows(2) {
        let (first, second) = (&pair[0], &pair[1]);
        assert!(first.pinned || !second.pinned);
        if first.pinned == second.pinned {
            assert!(first.name <= second.name);
            if first.name == second.name {
                assert!(first.id < second.id);
            }
        }
    }
    let mut decoded: Vec<&str> = listing.machines().iter().map(|m| m.id.as_str()).collect();
    let mut sent: Vec<&str> = rows.iter().map(|m| m["id"].as_str().unwrap()).collect();
    decoded.sort_unstable();
    sent.sort_unstable();
    assert_eq!(decoded, sent);
}
