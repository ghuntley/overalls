use super::{
    mila_ffi_get_version, mila_ffi_version, mila_machine_command_kind,
    mila_terminal_attach_validate, mila_terminal_input_validate, mila_terminal_resize_validate,
    mila_terminal_validate, mila_thread_command_kind, mila_trust_document_reconcile,
    mila_watch_event_kind, mila_watch_validate_filters, MilaFfiAbiVersion, MilaFfiStatus,
    MilaMachineCommandKind, MilaRouteOutput, MilaSnapshotSummary, MilaThreadCommandKind,
    MilaWatchEventKind, MILA_TERMINAL_MAX_INPUT,
};
use hegel::{generators as gs, TestCase};
use mila_runtime::MachineSnapshot;

/// Keep the C ABI route writer aligned with the vectors consumed by every
/// native client. This catches drift where a platform wrapper accepts a
/// route that the shared boundary cannot canonicalize.
#[test]
fn formats_shared_route_fixture_vectors() {
    let fixture = include_str!("../../../../protocol/test/fixtures/app_routes.json");
    let document: serde_json::Value = serde_json::from_str(fixture).expect("route fixture");
    for vector in document["accepted"].as_array().expect("accepted vectors") {
        let input = std::ffi::CString::new(vector["input"].as_str().unwrap()).unwrap();
        let expected = vector["canonical"].as_str().unwrap().as_bytes();
        let mut bytes = vec![0_u8; expected.len() + 1];
        let mut written = 0_usize;
        // SAFETY: `input` is a live NUL-terminated CString and the output describes the live
        // `bytes` buffer and `written` local.
        let status = unsafe {
            super::mila_route_format(
                input.as_ptr(),
                MilaRouteOutput {
                    bytes: bytes.as_mut_ptr(),
                    capacity: bytes.len(),
                    written: &raw mut written,
                },
            )
        };
        assert_eq!(status, MilaFfiStatus::Ok);
        assert_eq!(written, expected.len());
        assert_eq!(&bytes[..written], expected);
    }
}

#[test]
fn exposes_stable_abi_version() {
    assert_eq!(mila_ffi_version(), 1);
    let mut version = MilaFfiAbiVersion { major: 0, minor: 0 };
    // SAFETY: version points to writable stack storage.
    let status = unsafe { mila_ffi_get_version(&raw mut version) };
    assert_eq!(status, MilaFfiStatus::Ok);
    assert_eq!(version, MilaFfiAbiVersion { major: 1, minor: 0 });
}

#[test]
fn rejects_missing_version_storage() {
    assert_eq!(
        // SAFETY: null is intentionally supplied to verify the C ABI guard.
        unsafe { mila_ffi_get_version(std::ptr::null_mut()) },
        MilaFfiStatus::NullInput
    );
}

#[test]
fn validates_terminal_dimensions_at_the_native_boundary() {
    assert_eq!(mila_terminal_validate(120, 40, 1), MilaFfiStatus::Ok);
    assert_eq!(
        mila_terminal_validate(0, 40, 1),
        MilaFfiStatus::InvalidRequest
    );
    assert_eq!(
        mila_terminal_validate(120, 40, 2),
        MilaFfiStatus::InvalidRequest
    );
}

#[test]
fn projects_thread_command_catalog_without_payloads() {
    let line = std::ffi::CString::new("thread ls").unwrap();
    let mut kind = MilaThreadCommandKind::Unknown;
    assert_eq!(
        // SAFETY: `line` is a live NUL-terminated CString and `kind` a writable local.
        unsafe { mila_thread_command_kind(line.as_ptr(), &raw mut kind) },
        MilaFfiStatus::Ok
    );
    assert_eq!(kind, MilaThreadCommandKind::List);
    let unknown = std::ffi::CString::new("thread delete abc --json").unwrap();
    let mut kind = MilaThreadCommandKind::Unknown;
    assert_eq!(
        // SAFETY: `unknown` is a live NUL-terminated CString and `kind` a writable local.
        unsafe { mila_thread_command_kind(unknown.as_ptr(), &raw mut kind) },
        MilaFfiStatus::InvalidRequest
    );
}

#[test]
#[expect(
    clippy::single_element_loop,
    reason = "a catalogue table with one row today; further rows are added to the same loop"
)]
fn projects_machine_management_catalog_without_payloads() {
    for (line, expected) in [("ls", MilaMachineCommandKind::List)] {
        let line = std::ffi::CString::new(line).unwrap();
        let mut kind = MilaMachineCommandKind::Unknown;
        assert_eq!(
            // SAFETY: `line` is a live NUL-terminated CString and `kind` a writable local.
            unsafe { mila_machine_command_kind(line.as_ptr(), &raw mut kind) },
            MilaFfiStatus::Ok
        );
        assert_eq!(kind, expected);
    }
}

#[test]
fn validates_terminal_control_operations() {
    assert_eq!(
        mila_terminal_attach_validate(7, 120, 40, 1),
        MilaFfiStatus::Ok
    );
    assert_eq!(mila_terminal_resize_validate(120, 40, 1), MilaFfiStatus::Ok);
    assert_eq!(
        mila_terminal_resize_validate(0, 40, 1),
        MilaFfiStatus::InvalidRequest
    );
    assert_eq!(mila_terminal_input_validate(0, 0), MilaFfiStatus::Ok);
    assert_eq!(
        mila_terminal_input_validate(1, 0),
        MilaFfiStatus::InvalidRequest
    );
    assert_eq!(mila_terminal_input_validate(1 << 20, 1), MilaFfiStatus::Ok);
    assert_eq!(
        mila_terminal_input_validate((1 << 20) + 1, 1),
        MilaFfiStatus::InvalidRequest
    );
}

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-terminal-dimension-bounds
/// Every terminal validator MUST accept exactly the 1..=4096 by 1..=512
/// rectangle with a permission bit in {0,1}, for any attach offset, and
/// return only `Ok` or `InvalidRequest`; the oracle is the rectangle itself.
#[hegel::test(test_cases = 256)]
fn terminal_dimension_property_is_bounded(tc: TestCase) {
    let columns = tc.draw(gs::default::<u16>());
    let rows = tc.draw(gs::default::<u16>());
    let permission = tc.draw(gs::default::<u8>());
    let from = tc.draw(gs::default::<u64>());
    let valid = (1..=4096).contains(&columns) && (1..=512).contains(&rows) && permission <= 1;
    let expected = if valid {
        MilaFfiStatus::Ok
    } else {
        MilaFfiStatus::InvalidRequest
    };
    assert_eq!(mila_terminal_validate(columns, rows, permission), expected);
    assert_eq!(
        mila_terminal_attach_validate(from, columns, rows, permission),
        expected
    );
    assert_eq!(
        mila_terminal_resize_validate(columns, rows, permission),
        expected
    );
}

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-terminal-input-bounds
/// Terminal input validation MUST accept exactly lengths up to
/// `MILA_TERMINAL_MAX_INPUT` with a permission bit in {0,1}, and only an
/// empty write without the read-write permission.
#[hegel::test(test_cases = 256)]
fn terminal_input_property_is_bounded(tc: TestCase) {
    let length = tc.draw(gs::integers::<usize>().max_value(2 * MILA_TERMINAL_MAX_INPUT));
    let permission = tc.draw(gs::default::<u8>());
    let valid = match permission {
        0 => length == 0,
        1 => length <= MILA_TERMINAL_MAX_INPUT,
        _ => false,
    };
    let expected = if valid {
        MilaFfiStatus::Ok
    } else {
        MilaFfiStatus::InvalidRequest
    };
    assert_eq!(mila_terminal_input_validate(length, permission), expected);
}

#[test]
fn exposes_only_a_watch_event_tag() {
    let line = br#"{"version":1,"event":"heartbeat"}"#;
    let mut kind = MilaWatchEventKind::Unknown;
    // SAFETY: line and kind are valid for the supplied lengths.
    let status = unsafe { mila_watch_event_kind(line.as_ptr(), line.len(), &raw mut kind) };
    assert_eq!(status, MilaFfiStatus::Ok);
    assert_eq!(kind, MilaWatchEventKind::Heartbeat);
}

#[test]
fn rejects_malformed_watch_lines() {
    let line = br#"{"version":1,"event":"heartbeat"}"#;
    let mut kind = MilaWatchEventKind::Unknown;
    // SAFETY: line and kind are valid; an excessive length must be rejected.
    let status = unsafe { mila_watch_event_kind(line.as_ptr(), 65_537, &raw mut kind) };
    assert_eq!(status, MilaFfiStatus::InvalidRequest);
}

#[test]
fn validates_watch_filter_bound() {
    assert_eq!(mila_watch_validate_filters(64, 0), MilaFfiStatus::Ok);
    assert_eq!(
        mila_watch_validate_filters(65, 0),
        MilaFfiStatus::InvalidRequest
    );
}

#[test]
fn validates_push_poke_without_returning_ciphertext() {
    let envelope = br#"{"deployment":"mila.example.test","push_key":"AAAAAAAAAAAAAAAA","delivery_id":"d1","collapse_id":"c1","kind":"refresh","issued_at":100,"nonce":"n1","ciphertext":"Y2lwaGVy"}"#;
    assert_eq!(
        // SAFETY: `envelope` is a live byte string of the stated length.
        unsafe { super::mila_push_poke_validate(envelope.as_ptr(), envelope.len(), 100) },
        MilaFfiStatus::Ok
    );
    let expired = br#"{"deployment":"mila.example.test","push_key":"AAAAAAAAAAAAAAAA","delivery_id":"d1","collapse_id":"c1","kind":"refresh","issued_at":0,"nonce":"n1","ciphertext":"Y2lwaGVy"}"#;
    assert_eq!(
        // SAFETY: `expired` is a live byte string of the stated length.
        unsafe { super::mila_push_poke_validate(expired.as_ptr(), expired.len(), 86_401) },
        MilaFfiStatus::InvalidRequest
    );
}

#[test]
fn rejects_null_trust_document_inputs() {
    let host = std::ffi::CString::new("mgmt.example.test").unwrap();
    assert_eq!(
        // SAFETY: null document is intentional for the ABI guard test; `host` is a live CString.
        unsafe { super::mila_trust_document_validate(std::ptr::null(), 0, host.as_ptr(), 0) },
        MilaFfiStatus::NullInput
    );
}

fn trust_document(ca: &str, retirement: u64) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "version": 1,
        "ca": ca,
        "management_host": "overalls.example",
        "zone": "apps.overalls.example",
        "retirement": retirement,
    }))
    .expect("trust document")
}

#[test]
fn reconciles_and_serializes_only_rust_selected_trust() {
    let fixture = include_str!("../../mila-transport/tests/fixtures/ssh_host_certificates.json");
    let value: serde_json::Value = serde_json::from_str(fixture).expect("fixture");
    let ca = value["certificates"][0]["ca"].as_str().expect("ca");
    let fetched = trust_document(ca, 2_000);
    let mut output = vec![0_u8; 8192];
    let mut written = 0_usize;
    let host = std::ffi::CString::new("overalls.example").unwrap();
    // SAFETY: `fetched` is a live Vec of the stated length, `host` a live CString, and the output
    // describes the live `output` buffer and `written` local.
    let status = unsafe {
        mila_trust_document_reconcile(
            std::ptr::null(),
            0,
            fetched.as_ptr(),
            fetched.len(),
            host.as_ptr(),
            1_000,
            MilaRouteOutput {
                bytes: output.as_mut_ptr(),
                capacity: output.len(),
                written: &raw mut written,
            },
        )
    };
    assert_eq!(status, MilaFfiStatus::Ok);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&output[..written]).expect("canonical trust")
            ["retirement"],
        2_000
    );
}

#[test]
fn reconciliation_refuses_changed_authority_and_expired_fallback() {
    let fixture = include_str!("../../mila-transport/tests/fixtures/ssh_host_certificates.json");
    let value: serde_json::Value = serde_json::from_str(fixture).expect("fixture");
    let ca = value["certificates"][0]["ca"].as_str().expect("ca");
    let other_ca = value["certificates"][5]["ca"].as_str().expect("other ca");
    let pinned = trust_document(ca, 2_000);
    let fetched = trust_document(other_ca, 3_000);
    let mut output = vec![0_u8; 8192];
    let mut written = 0_usize;
    let host = std::ffi::CString::new("overalls.example").unwrap();
    // SAFETY: the documents are live Vecs of the stated lengths, `host` a live CString, and the
    // output describes the live `output` buffer and `written` local.
    let status = unsafe {
        mila_trust_document_reconcile(
            pinned.as_ptr(),
            pinned.len(),
            fetched.as_ptr(),
            fetched.len(),
            host.as_ptr(),
            1_000,
            MilaRouteOutput {
                bytes: output.as_mut_ptr(),
                capacity: output.len(),
                written: &raw mut written,
            },
        )
    };
    assert_eq!(status, MilaFfiStatus::InvalidRequest);
    // SAFETY: `pinned` is a live Vec of the stated length, the fetched document is null with
    // length zero, `host` a live CString, and the output describes the live `output` buffer and
    // `written` local.
    let status = unsafe {
        mila_trust_document_reconcile(
            pinned.as_ptr(),
            pinned.len(),
            std::ptr::null(),
            0,
            host.as_ptr(),
            2_001,
            MilaRouteOutput {
                bytes: output.as_mut_ptr(),
                capacity: output.len(),
                written: &raw mut written,
            },
        )
    };
    assert_eq!(status, MilaFfiStatus::InvalidRequest);
}

#[test]
fn validates_snapshot_and_returns_safe_summary() {
    let snapshot = MachineSnapshot::new("mgmt.example.test".into(), Some(443), 42, vec![])
        .unwrap()
        .encode()
        .unwrap();
    let host = std::ffi::CString::new("mgmt.example.test").unwrap();
    let mut summary = MilaSnapshotSummary {
        machine_count: 9,
        saved_at: 0,
    };
    // SAFETY: `snapshot` is a live Vec of the stated length, `host` a live CString and `summary` a
    // writable local.
    let status = unsafe {
        super::mila_snapshot_validate(
            snapshot.as_ptr(),
            snapshot.len(),
            host.as_ptr(),
            443,
            1,
            &raw mut summary,
        )
    };
    assert_eq!(status, MilaFfiStatus::Ok);
    assert_eq!(
        summary,
        MilaSnapshotSummary {
            machine_count: 0,
            saved_at: 42
        }
    );
}

#[test]
fn rejects_snapshot_for_wrong_deployment() {
    let snapshot = MachineSnapshot::new("mgmt.example.test".into(), None, 1, vec![])
        .unwrap()
        .encode()
        .unwrap();
    let host = std::ffi::CString::new("other.example.test").unwrap();
    let mut summary = MilaSnapshotSummary {
        machine_count: 0,
        saved_at: 0,
    };
    // SAFETY: `snapshot` is a live Vec of the stated length, `host` a live CString and `summary` a
    // writable local.
    let status = unsafe {
        super::mila_snapshot_validate(
            snapshot.as_ptr(),
            snapshot.len(),
            host.as_ptr(),
            0,
            0,
            &raw mut summary,
        )
    };
    assert_eq!(status, MilaFfiStatus::InvalidRequest);
}
