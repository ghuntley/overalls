use hegel::{generators as gs, TestCase};
use mila_transport::{parse_host_certificate_blob, parse_host_certificate_line};
/// @cc [owner:ghuntley,label:verification;security] mila-transport-certificate-blob-totality
/// Parsing an arbitrary host certificate blob MUST return without panicking.
#[hegel::test(test_cases = 64)]
fn arbitrary_bytes_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(300));
    let _ = parse_host_certificate_blob(&bytes);
}
/// @cc [owner:ghuntley,label:verification;security] mila-transport-certificate-line-totality
/// Parsing an arbitrary host certificate line MUST return without panicking.
#[hegel::test(test_cases = 64)]
fn malformed_lines_are_rejected(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(300));
    let s = String::from_utf8_lossy(&bytes);
    let _ = parse_host_certificate_line(&s);
}

use mila_transport::{
    decode_trust_document, decode_watch_line, pty, reconcile_trust, RequestRefusal,
    TerminalAttachRequest, TrustDocument, TrustRefusal, WatchEvent, WatchFormat, WatchRequest,
    MAX_WATCH_LINE_BYTES,
};
use serde_json::{json, Value};
use std::collections::BTreeSet;
/// @cc [owner:ghuntley,label:verification;security] mila-transport-trust-document-totality
/// Decoding arbitrary trust-document bytes up to past the size cap MUST return
/// without panicking.
#[hegel::test(test_cases = 64)]
fn arbitrary_trust_bytes_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(9000));
    let _ = decode_trust_document(&bytes, "mila.example", 1);
}
fn trust(ca: &str, host: &str, zone: &str, retirement: u64) -> TrustDocument {
    TrustDocument {
        version: 1,
        ca: ca.to_owned(),
        management_host: host.to_owned(),
        zone: zone.to_owned(),
        retirement,
    }
}

#[test]
fn trust_reconciliation_keeps_authority_and_latest_retirement() {
    let pinned = trust("ssh-ed25519 pinned", "mila.example", "zone.example", 200);
    let older = trust("ssh-ed25519 pinned", "mila.example", "zone.example", 100);
    let newer = trust("ssh-ed25519 pinned", "mila.example", "zone.example", 300);
    assert_eq!(reconcile_trust(None, older.clone()), Ok(older.clone()));
    assert_eq!(reconcile_trust(Some(&pinned), older), Ok(pinned.clone()));
    assert_eq!(reconcile_trust(Some(&pinned), newer.clone()), Ok(newer));
    for changed in [
        trust("ssh-ed25519 other", "mila.example", "zone.example", 300),
        trust("ssh-ed25519 pinned", "other.example", "zone.example", 300),
        trust("ssh-ed25519 pinned", "mila.example", "other.example", 300),
    ] {
        assert_eq!(
            reconcile_trust(Some(&pinned), changed),
            Err(TrustRefusal::Conflicts)
        );
    }
}

fn trust_document(tc: &TestCase) -> TrustDocument {
    TrustDocument {
        version: tc.draw(gs::integers::<u8>().min_value(1).max_value(2)),
        ca: tc
            .draw(gs::sampled_from(vec![
                "ssh-ed25519 AAAA",
                "ssh-ed25519 BBBB",
            ]))
            .to_owned(),
        management_host: tc
            .draw(gs::sampled_from(vec!["mila.example", "other.example"]))
            .to_owned(),
        zone: tc
            .draw(gs::sampled_from(vec!["zone.example", "zone.other"]))
            .to_owned(),
        retirement: tc.draw(gs::integers::<u64>().max_value(1_000)),
    }
}

/// @cc [owner:ghuntley,label:verification;security] mila-transport-trust-reconcile
/// `reconcile_trust` MUST adopt a first fetched document, refuse any fetched
/// document that changes the pinned CA, management host or zone, otherwise keep the
/// pinned authority with the later retirement, and be idempotent: reconciling the
/// result again with the same fetched document, or with itself, changes nothing.
#[hegel::test(test_cases = 256)]
fn trust_reconciliation_preserves_authority_and_is_idempotent(tc: TestCase) {
    let pinned = trust_document(&tc);
    let fetched = trust_document(&tc);
    assert_eq!(reconcile_trust(None, fetched.clone()), Ok(fetched.clone()));
    let same = pinned.ca == fetched.ca
        && pinned.management_host == fetched.management_host
        && pinned.zone == fetched.zone;
    match reconcile_trust(Some(&pinned), fetched.clone()) {
        Ok(result) => {
            assert!(same);
            assert!(result.same_authority(&pinned));
            assert_eq!(result.retirement, pinned.retirement.max(fetched.retirement));
            assert!(result == pinned || result == fetched);
            assert_eq!(
                reconcile_trust(Some(&result), fetched.clone()),
                Ok(result.clone())
            );
            assert_eq!(
                reconcile_trust(Some(&result), result.clone()),
                Ok(result.clone())
            );
        }
        Err(refusal) => {
            assert!(!same);
            assert_eq!(refusal, TrustRefusal::Conflicts);
        }
    }
}

fn uuid_pool(tc: &TestCase, max: usize) -> Vec<uuid::Uuid> {
    // Drawing from a small pool forces duplicates so dedup is exercised.
    let pool: Vec<uuid::Uuid> = (0u128..96).map(uuid::Uuid::from_u128).collect();
    tc.draw(gs::vecs(gs::sampled_from(pool)).max_size(max))
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-transport-request-bounds
/// `WatchRequest::new` MUST sort and deduplicate both filter sets and accept them
/// exactly when the distinct total is at most `MAX_FILTERS`, and
/// `TerminalAttachRequest::validate` MUST accept exactly 1..=4096 columns by
/// 1..=512 rows.
#[hegel::test(test_cases = 256)]
fn watch_and_attach_requests_enforce_bounds(tc: TestCase) {
    let machines = uuid_pool(&tc, 80);
    let threads = uuid_pool(&tc, 80);
    let distinct_machines: BTreeSet<_> = machines.iter().copied().collect();
    let distinct_threads: BTreeSet<_> = threads.iter().copied().collect();
    let within = distinct_machines.len() + distinct_threads.len() <= WatchRequest::MAX_FILTERS;
    match WatchRequest::new(machines, threads) {
        Ok(request) => {
            assert!(within);
            assert_eq!(
                request.machines,
                distinct_machines.into_iter().collect::<Vec<_>>()
            );
            assert_eq!(
                request.threads,
                distinct_threads.into_iter().collect::<Vec<_>>()
            );
        }
        Err(refusal) => {
            assert!(!within);
            assert_eq!(refusal, RequestRefusal::TooManyFilters);
        }
    }

    let request = TerminalAttachRequest {
        machine_id: uuid::Uuid::from_u128(1),
        session_id: uuid::Uuid::from_u128(2),
        from: tc.draw(gs::default::<u64>()),
        columns: tc.draw(gs::default::<u16>()),
        rows: tc.draw(gs::default::<u16>()),
        read_write: tc.draw(gs::booleans()),
    };
    let valid = (1..=4096).contains(&request.columns) && (1..=512).contains(&request.rows);
    assert_eq!(
        request.validate(),
        if valid {
            Ok(())
        } else {
            Err(RequestRefusal::InvalidDimensions)
        }
    );
}

fn ids_json(ids: &[uuid::Uuid]) -> Value {
    Value::Array(ids.iter().map(|id| json!(id.to_string())).collect())
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-transport-watch-line
/// `decode_watch_line` MUST be total over arbitrary bytes, refuse any line over
/// `MAX_WATCH_LINE_BYTES` even when it is otherwise valid, accept a valid line at
/// the cap, decode generated version-1 events to exactly the encoded values, and
/// refuse filter lists longer than `MAX_FILTERS`.
#[hegel::test(test_cases = 256)]
fn watch_lines_are_total_capped_and_exact(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(512));
    let _ = decode_watch_line(&bytes);

    let heartbeat = br#"{"version":1,"event":"heartbeat"}"#;
    let mut at_cap = heartbeat.to_vec();
    at_cap.resize(MAX_WATCH_LINE_BYTES, b' ');
    assert_eq!(decode_watch_line(&at_cap), Ok(WatchEvent::Heartbeat));
    let extra = tc.draw(gs::integers::<usize>().min_value(1).max_value(64));
    at_cap.resize(MAX_WATCH_LINE_BYTES + extra, b' ');
    assert_eq!(decode_watch_line(&at_cap), Err(WatchFormat("too long")));

    let id = uuid::Uuid::from_u128(tc.draw(gs::default::<u128>()));
    let machines = uuid_pool(&tc, 70);
    let threads = uuid_pool(&tc, 70);
    let authenticated = tc.draw(gs::booleans());
    let (value, expected) = match tc.draw(gs::integers::<u8>().max_value(7)) {
        0 => (
            json!({"version": 1, "event": "watching", "session_id": id.to_string(),
                "machines": ids_json(&machines), "threads": ids_json(&threads)}),
            if machines.len() > WatchRequest::MAX_FILTERS
                || threads.len() > WatchRequest::MAX_FILTERS
            {
                Err(WatchFormat("field"))
            } else {
                Ok(WatchEvent::Watching {
                    session_id: id,
                    machines: machines.clone(),
                    threads: threads.clone(),
                })
            },
        ),
        1 => (
            json!({"version": 1, "event": "heartbeat"}),
            Ok(WatchEvent::Heartbeat),
        ),
        2 => (
            json!({"version": 1, "event": "machine", "id": id.to_string()}),
            Ok(WatchEvent::MachineChanged(id)),
        ),
        3 => (
            json!({"version": 1, "event": "terminal_session", "machine_id": id.to_string()}),
            Ok(WatchEvent::TerminalSessionsChanged(id)),
        ),
        4 => (
            json!({"version": 1, "event": "thread", "id": id.to_string()}),
            Ok(WatchEvent::ThreadChanged(id)),
        ),
        5 => (
            json!({"version": 1, "event": "session", "id": id.to_string(),
                "status": if authenticated { "authenticated" } else { "pending" }}),
            Ok(WatchEvent::Session { id, authenticated }),
        ),
        6 => (
            json!({"version": 2, "event": "heartbeat"}),
            Err(WatchFormat("version")),
        ),
        _ => (
            json!({"version": 1, "event": "future_event"}),
            Ok(WatchEvent::Unknown),
        ),
    };
    let line = serde_json::to_vec(&value).expect("encode watch line");
    assert_eq!(decode_watch_line(&line), expected);
}

#[derive(Clone, Copy, Debug)]
enum PtyStep {
    Output(usize),
    Input(usize),
    Resize(u16, u16),
    Close,
}

/// @cc [owner:ghuntley,label:verification;security;terminal] mila-transport-pty-refusal
/// The PTY policy MUST refuse every output, input, resize and close for a stale
/// generation and, once closed, for the current generation too; payload bounds and
/// dimension bounds MUST be checked only for a live current generation, against an
/// independent model of the session state.
#[hegel::test(test_cases = 256)]
fn pty_refuses_stale_and_closed_sessions(tc: TestCase) {
    let generation = tc.draw(gs::integers::<u64>().max_value(8));
    let columns = tc.draw(gs::integers::<u16>().max_value(600));
    let rows = tc.draw(gs::integers::<u16>().max_value(600));
    let valid_dimensions =
        (1..=pty::MAX_COLUMNS).contains(&columns) && (1..=pty::MAX_ROWS).contains(&rows);
    let Ok(dimensions) = pty::Dimensions::new(columns, rows) else {
        assert!(!valid_dimensions);
        return;
    };
    assert!(valid_dimensions);
    let mut session = pty::Session::attach(generation, dimensions);
    let mut closed = false;
    let mut current = dimensions;
    let steps = tc.draw(gs::integers::<usize>().max_value(12));
    for _ in 0..steps {
        let at = tc.draw(gs::integers::<u64>().max_value(8));
        let step = match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => PtyStep::Output(tc.draw(gs::integers::<usize>().max_value(pty::MAX_CHUNK + 2))),
            1 => PtyStep::Input(tc.draw(gs::integers::<usize>().max_value(pty::MAX_INPUT + 2))),
            2 => PtyStep::Resize(
                tc.draw(
                    gs::integers::<u16>()
                        .min_value(1)
                        .max_value(pty::MAX_COLUMNS),
                ),
                tc.draw(gs::integers::<u16>().min_value(1).max_value(pty::MAX_ROWS)),
            ),
            _ => PtyStep::Close,
        };
        let gate = if at != generation {
            Err(pty::Error::StaleGeneration)
        } else if closed {
            Err(pty::Error::Closed)
        } else {
            Ok(())
        };
        let (actual, expected) = match step {
            PtyStep::Output(length) => (
                session.accept_output(at, &vec![0; length]),
                gate.and(if length > pty::MAX_CHUNK {
                    Err(pty::Error::Bounds)
                } else {
                    Ok(())
                }),
            ),
            PtyStep::Input(length) => (
                session.input(at, &vec![0; length]),
                gate.and(if length > pty::MAX_INPUT {
                    Err(pty::Error::Bounds)
                } else {
                    Ok(())
                }),
            ),
            PtyStep::Resize(columns, rows) => {
                let next = pty::Dimensions::new(columns, rows).expect("bounded dimensions");
                let result = session.resize(at, next);
                if gate.is_ok() {
                    current = next;
                }
                (result, gate)
            }
            PtyStep::Close => {
                let result = session.close(at);
                if gate.is_ok() {
                    closed = true;
                }
                (result, gate)
            }
        };
        assert_eq!(actual, expected);
        assert_eq!(session.dimensions(), current);
        assert_eq!(
            session.state(),
            if closed {
                pty::State::Closed
            } else {
                pty::State::Attached
            }
        );
    }
}
