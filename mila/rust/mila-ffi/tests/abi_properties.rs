//! Hegel properties for the C ABI validators' caller-buffer and status contract
//! (ADR-0265). Every caller-owned output buffer is followed by guard bytes that
//! must survive the call, and every status must stay in the stable set.
use hegel::{generators as gs, TestCase};
use mila_ffi::{
    mila_machine_command_kind, mila_push_key_request_encode, mila_push_registration_validate,
    mila_route_format, mila_snapshot_validate, mila_thread_command_kind,
    mila_trust_document_reconcile, mila_watch_event_kind, MilaFfiStatus, MilaMachineCommandKind,
    MilaRouteOutput, MilaSnapshotSummary, MilaThreadCommandKind, MilaWatchEventKind,
};
use mila_model::MilaRoute;
use mila_runtime::MachineSnapshot;
use std::ffi::{c_char, CString};

const CANARY: u8 = 0xa5;
const GUARD: usize = 16;
const UNWRITTEN: usize = usize::MAX;
/// The stable `MilaFfiStatus` discriminants published in `include/mila_ffi.h`.
const STABLE_STATUSES: [i32; 5] = [0, -1, -2, -3, -4];

/// Result of one call into a validator that writes a caller-owned buffer.
struct Written {
    status: MilaFfiStatus,
    /// The buffer's first `capacity` bytes; the guard bytes were checked.
    bytes: Vec<u8>,
    written: usize,
}

/// Calls `call` with `capacity` bytes of canary-filled storage followed by
/// [`GUARD`] canary bytes, and asserts that the guard survives and the status
/// is stable.
fn call_with_output(
    capacity: usize,
    call: impl FnOnce(MilaRouteOutput) -> MilaFfiStatus,
) -> Written {
    let mut buffer = vec![CANARY; capacity + GUARD];
    let mut written = UNWRITTEN;
    let status = call(MilaRouteOutput {
        bytes: buffer.as_mut_ptr(),
        capacity,
        written: &mut written,
    });
    assert!(
        buffer[capacity..].iter().all(|byte| *byte == CANARY),
        "a validator wrote past the caller's capacity"
    );
    assert!(STABLE_STATUSES.contains(&(status as i32)));
    buffer.truncate(capacity);
    Written {
        status,
        bytes: buffer,
        written,
    }
}

fn untouched(bytes: &[u8]) -> bool {
    bytes.iter().all(|byte| *byte == CANARY)
}

/// Arbitrary text without interior NULs, so it can cross as a C string.
fn c_text(tc: &TestCase, max_size: usize) -> CString {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(max_size));
    let text: Vec<u8> = String::from_utf8_lossy(&bytes)
        .bytes()
        .filter(|byte| *byte != 0)
        .collect();
    CString::new(text).expect("NUL bytes were removed")
}

fn accepted_routes() -> Vec<String> {
    let fixture = include_str!("../../../../protocol/test/fixtures/app_routes.json");
    let document: serde_json::Value = serde_json::from_str(fixture).expect("route fixture");
    document["accepted"]
        .as_array()
        .expect("accepted vectors")
        .iter()
        .map(|vector| vector["input"].as_str().expect("route input").to_owned())
        .collect()
}

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-route-format-bounded
/// `mila_route_format` MUST agree with `MilaRoute::parse`/`format` on accepted
/// fixture routes and arbitrary text, write only within the caller's capacity,
/// leave the buffer and `written` untouched on refusal, and NUL-terminate only
/// when spare capacity exists.
#[hegel::test(test_cases = 128)]
fn route_format_matches_parser_within_capacity(tc: TestCase) {
    let input = if tc.draw(gs::booleans()) {
        CString::new(tc.draw(gs::sampled_from(accepted_routes()))).expect("fixture route")
    } else {
        c_text(&tc, 160)
    };
    let capacity = tc.draw(gs::integers::<usize>().max_value(160));
    let expected = input
        .to_str()
        .ok()
        .and_then(|text| MilaRoute::parse(text).ok())
        .map(|route| route.format());
    // SAFETY: `input` is a live NUL-terminated string and the output storage
    // is owned by `call_with_output` for the duration of the call.
    let result = call_with_output(capacity, |output| unsafe {
        mila_route_format(input.as_ptr(), output)
    });
    match expected {
        None => {
            assert_eq!(result.status, MilaFfiStatus::InvalidRoute);
            assert_eq!(result.written, UNWRITTEN);
            assert!(untouched(&result.bytes));
        }
        Some(canonical) if canonical.len() > capacity => {
            assert_eq!(result.status, MilaFfiStatus::OutputTooSmall);
            assert_eq!(result.written, UNWRITTEN);
            assert!(untouched(&result.bytes));
        }
        Some(canonical) => {
            assert_eq!(result.status, MilaFfiStatus::Ok);
            assert_eq!(result.written, canonical.len());
            assert_eq!(&result.bytes[..canonical.len()], canonical.as_bytes());
            if capacity > canonical.len() {
                assert_eq!(result.bytes[canonical.len()], 0);
                assert!(untouched(&result.bytes[canonical.len() + 1..]));
            }
        }
    }
}

const TRUST_HOST: &str = "overalls.example";

fn trust_document(ca: &str, retirement: u64) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "version": 1,
        "ca": ca,
        "management_host": TRUST_HOST,
        "zone": "apps.overalls.example",
        "retirement": retirement,
    }))
    .expect("trust document")
}

/// Two distinct certificate authorities from the shared transport fixture.
fn fixture_authorities() -> (String, String) {
    let fixture = include_str!("../../mila-transport/tests/fixtures/ssh_host_certificates.json");
    let document: serde_json::Value = serde_json::from_str(fixture).expect("fixture");
    let authority = |index: usize| {
        document["certificates"][index]["ca"]
            .as_str()
            .expect("certificate authority")
            .to_owned()
    };
    (authority(0), authority(5))
}

/// Draws an absent, well-formed or arbitrary trust document.
fn draw_trust_input(tc: &TestCase, authorities: &(String, String)) -> Vec<u8> {
    match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => Vec::new(),
        1 => trust_document(
            &authorities.0,
            tc.draw(gs::integers::<u64>().max_value(4_000)),
        ),
        2 => trust_document(
            &authorities.1,
            tc.draw(gs::integers::<u64>().max_value(4_000)),
        ),
        _ => tc.draw(gs::vecs(gs::default::<u8>()).max_size(256)),
    }
}

fn reconcile(pinned: &[u8], fetched: &[u8], now: u64, capacity: usize) -> Written {
    let host = CString::new(TRUST_HOST).expect("host");
    let pointer = |bytes: &[u8]| {
        if bytes.is_empty() {
            std::ptr::null()
        } else {
            bytes.as_ptr()
        }
    };
    // SAFETY: both inputs are live slices of the declared lengths (or null
    // with length zero), `host` is NUL-terminated, and the output storage is
    // owned by `call_with_output` for the duration of the call.
    call_with_output(capacity, |output| unsafe {
        mila_trust_document_reconcile(
            pointer(pinned),
            pinned.len(),
            pointer(fetched),
            fetched.len(),
            host.as_ptr(),
            now,
            output,
        )
    })
}

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-trust-reconcile-bounded
/// `mila_trust_document_reconcile` over absent, valid, conflicting and
/// arbitrary documents MUST write only within the caller's capacity, report the
/// required length on `OutputTooSmall`, and return on success exactly the bytes
/// a sufficiently large buffer receives, which decode as a trust document.
#[hegel::test(test_cases = 128)]
fn trust_reconcile_writes_within_capacity(tc: TestCase) {
    let authorities = fixture_authorities();
    let pinned = draw_trust_input(&tc, &authorities);
    let fetched = draw_trust_input(&tc, &authorities);
    let now = tc.draw(gs::integers::<u64>().max_value(4_000));
    let capacity = tc.draw(gs::integers::<usize>().max_value(1_024));
    let full = reconcile(&pinned, &fetched, now, 8_192);
    let result = reconcile(&pinned, &fetched, now, capacity);
    match full.status {
        MilaFfiStatus::Ok => {
            let selected = &full.bytes[..full.written];
            assert!(mila_transport::decode_trust_document(selected, TRUST_HOST, 0).is_ok());
            assert_eq!(result.written, full.written);
            if full.written > capacity {
                assert_eq!(result.status, MilaFfiStatus::OutputTooSmall);
                assert!(untouched(&result.bytes));
            } else {
                assert_eq!(result.status, MilaFfiStatus::Ok);
                assert_eq!(&result.bytes[..result.written], selected);
                assert!(untouched(&result.bytes[result.written..]));
            }
        }
        refused => {
            assert_eq!(refused, MilaFfiStatus::InvalidRequest);
            assert_eq!(result.status, MilaFfiStatus::InvalidRequest);
            assert_eq!(result.written, UNWRITTEN);
            assert!(untouched(&result.bytes));
        }
    }
}

const APNS_TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const FCM_TOKEN: &str = "fcm-token_0123456789:abcdefghijklmnopqrstuvwxyz";
const WNS_CHANNEL: &str = "https://db5.notify.windows.com/?token=AwYAAAB";

/// Push registration arguments drawn from valid and invalid pools.
struct PushArguments {
    provider: u8,
    environment: u8,
    token: CString,
    app_id: CString,
    deployment: CString,
    endpoint: Option<CString>,
}

fn draw_push_arguments(tc: &TestCase) -> PushArguments {
    let provider = tc.draw(gs::integers::<u8>().max_value(3));
    if tc.draw(gs::booleans()) {
        // A registration the runtime accepts: APNs in either environment,
        // FCM and WNS in production, WNS with its channel as the endpoint.
        let token = match provider {
            1 => FCM_TOKEN,
            2 => WNS_CHANNEL,
            _ => APNS_TOKEN,
        };
        let environment = if provider == 0 {
            tc.draw(gs::integers::<u8>().max_value(1))
        } else {
            1
        };
        let text = |value: &str| CString::new(value).expect("constants have no NUL");
        return PushArguments {
            provider,
            environment,
            token: text(token),
            app_id: text("dev.overalls.mila"),
            deployment: text("mila.example.test"),
            endpoint: (provider == 2).then(|| text(WNS_CHANNEL)),
        };
    }
    let pick = |tc: &TestCase, pool: &[&str]| {
        if tc.draw(gs::integers::<u8>().max_value(7)) == 0 {
            c_text(tc, 64)
        } else {
            let pool: Vec<String> = pool.iter().map(|value| (*value).to_owned()).collect();
            CString::new(tc.draw(gs::sampled_from(pool))).expect("pool values have no NUL")
        }
    };
    PushArguments {
        provider,
        environment: tc.draw(gs::integers::<u8>().max_value(2)),
        token: pick(tc, &[APNS_TOKEN, FCM_TOKEN, WNS_CHANNEL, ""]),
        app_id: pick(tc, &["dev.overalls.mila", "", "has space"]),
        deployment: pick(tc, &["mila.example.test", "", "-bad-.example"]),
        endpoint: if tc.draw(gs::booleans()) {
            Some(pick(tc, &[WNS_CHANNEL, APNS_TOKEN]))
        } else {
            None
        },
    }
}

fn encode_push_key_request(arguments: &PushArguments, capacity: usize) -> Written {
    // SAFETY: every string argument is a live NUL-terminated C string or a
    // null endpoint, and the output storage is owned by `call_with_output`.
    call_with_output(capacity, |output| unsafe {
        mila_push_key_request_encode(
            arguments.provider,
            arguments.environment,
            arguments.token.as_ptr(),
            arguments.app_id.as_ptr(),
            arguments.deployment.as_ptr(),
            arguments
                .endpoint
                .as_ref()
                .map_or(std::ptr::null::<c_char>(), |value| value.as_ptr()),
            output,
        )
    })
}

/// @cc [owner:ghuntley,label:verification;privacy] mila-ffi-push-key-request-bounded
/// `mila_push_key_request_encode` MUST refuse exactly what
/// `mila_push_registration_validate` refuses without touching the buffer, and
/// otherwise write the Susan body only within the caller's capacity, reporting
/// its length on `OutputTooSmall`.
#[hegel::test(test_cases = 128)]
fn push_key_request_agrees_with_validation_within_capacity(tc: TestCase) {
    let arguments = draw_push_arguments(&tc);
    let capacity = tc.draw(gs::integers::<usize>().max_value(512));
    // SAFETY: the same live arguments as `encode_push_key_request`.
    let validation = unsafe {
        mila_push_registration_validate(
            arguments.provider,
            arguments.environment,
            arguments.token.as_ptr(),
            arguments.app_id.as_ptr(),
            arguments.deployment.as_ptr(),
            arguments
                .endpoint
                .as_ref()
                .map_or(std::ptr::null::<c_char>(), |value| value.as_ptr()),
        )
    };
    assert!(STABLE_STATUSES.contains(&(validation as i32)));
    let full = encode_push_key_request(&arguments, 4_096);
    let result = encode_push_key_request(&arguments, capacity);
    if validation == MilaFfiStatus::Ok {
        assert_eq!(full.status, MilaFfiStatus::Ok);
        let body = &full.bytes[..full.written];
        assert!(serde_json::from_slice::<serde_json::Value>(body).is_ok());
        assert_eq!(result.written, body.len());
        if body.len() > capacity {
            assert_eq!(result.status, MilaFfiStatus::OutputTooSmall);
            assert!(untouched(&result.bytes));
        } else {
            assert_eq!(result.status, MilaFfiStatus::Ok);
            assert_eq!(&result.bytes[..body.len()], body);
            assert!(untouched(&result.bytes[body.len()..]));
        }
    } else {
        assert_eq!(result.status, validation);
        assert_eq!(result.written, UNWRITTEN);
        assert!(untouched(&result.bytes));
    }
}

const SNAPSHOT_HOST: &str = "mgmt.example.test";

/// @cc [owner:ghuntley,label:verification;security] mila-ffi-projection-total
/// The snapshot, watch-line and command-kind projections MUST be total over
/// arbitrary and well-formed input, return only `Ok` or `InvalidRequest`, and
/// leave their out-parameter untouched on refusal.
#[hegel::test(test_cases = 128)]
fn projections_are_total_and_leave_outputs_on_refusal(tc: TestCase) {
    let bytes = match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => MachineSnapshot::new(SNAPSHOT_HOST.into(), Some(443), 42, vec![])
            .and_then(|snapshot| snapshot.encode())
            .expect("empty snapshot"),
        1 => tc.draw(gs::sampled_from(vec![
            br#"{"version":1,"event":"heartbeat"}"#.to_vec(),
            br#"{"version":1,"event":"resync"}"#.to_vec(),
        ])),
        _ => tc.draw(gs::vecs(gs::default::<u8>()).max_size(512)),
    };
    let host = if tc.draw(gs::booleans()) {
        CString::new(SNAPSHOT_HOST).expect("host")
    } else {
        c_text(&tc, 32)
    };
    let refused_or_ok = |status: MilaFfiStatus| {
        assert!(STABLE_STATUSES.contains(&(status as i32)));
        assert!(matches!(
            status,
            MilaFfiStatus::Ok | MilaFfiStatus::InvalidRequest
        ));
        status == MilaFfiStatus::Ok
    };

    let sentinel = MilaSnapshotSummary {
        machine_count: u32::MAX,
        saved_at: u64::MAX,
    };
    let mut summary = sentinel;
    // SAFETY: `bytes` is a live slice of the declared length, `host` is
    // NUL-terminated and `summary` is writable stack storage.
    let status = unsafe {
        mila_snapshot_validate(
            bytes.as_ptr(),
            bytes.len(),
            host.as_ptr(),
            443,
            1,
            &mut summary,
        )
    };
    if !refused_or_ok(status) {
        assert_eq!(summary, sentinel);
    }

    let mut watch = MilaWatchEventKind::Session;
    // SAFETY: `bytes` is a live slice of the declared length and `watch` is
    // writable stack storage.
    let status = unsafe { mila_watch_event_kind(bytes.as_ptr(), bytes.len(), &mut watch) };
    if !refused_or_ok(status) {
        assert_eq!(watch, MilaWatchEventKind::Session);
    }

    let line = if tc.draw(gs::booleans()) {
        let catalogue = ["ls", "thread ls", "thread read", "web show", "rm"];
        let catalogue: Vec<String> = catalogue.iter().map(|line| (*line).to_owned()).collect();
        CString::new(tc.draw(gs::sampled_from(catalogue))).expect("catalogue line")
    } else {
        c_text(&tc, 128)
    };
    let mut machine = MilaMachineCommandKind::WebSet;
    // SAFETY: `line` is NUL-terminated and `machine` is writable stack storage.
    let status = unsafe { mila_machine_command_kind(line.as_ptr(), &mut machine) };
    if !refused_or_ok(status) {
        assert_eq!(machine, MilaMachineCommandKind::WebSet);
    }

    let mut thread = MilaThreadCommandKind::Read;
    // SAFETY: `line` is NUL-terminated and `thread` is writable stack storage.
    let status = unsafe { mila_thread_command_kind(line.as_ptr(), &mut thread) };
    if !refused_or_ok(status) {
        assert_eq!(thread, MilaThreadCommandKind::Read);
    }
}
