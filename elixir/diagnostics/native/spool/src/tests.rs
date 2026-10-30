use super::*;
use crate::schema::attribute;
use crate::store::{digest, number, sql};
use hegel::{generators as gs, TestCase};
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::resource::v1::Resource;
use opentelemetry_proto::tonic::trace::v1::{ResourceSpans, ScopeSpans, Span, Status};
use prost::Message;
use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

fn schema_request() -> (Schema, ExportTraceServiceRequest) {
    let schema = Schema {
        services: BTreeMap::from([(
            "galileo".into(),
            BTreeSet::from(["galileo.request_denied".into()]),
        )]),
        uuid_attributes: BTreeSet::from(["request_id".into()]),
        enum_attributes: BTreeSet::from(["reason".into()]),
        numeric_attributes: BTreeSet::from(["duration_us".into()]),
        enum_values: BTreeSet::from(["unauthorized".into()]),
    };
    let request = ExportTraceServiceRequest {
        resource_spans: vec![ResourceSpans {
            resource: Some(Resource {
                attributes: vec![attribute("service.name", "foreign-secret")],
                ..Resource::default()
            }),
            scope_spans: vec![ScopeSpans {
                spans: vec![Span {
                    name: "galileo.request_denied".into(),
                    trace_id: vec![1; 16],
                    span_id: vec![2; 8],
                    start_time_unix_nano: 1,
                    end_time_unix_nano: 2,
                    attributes: vec![attribute("reason", "unauthorized")],
                    status: Some(Status {
                        message: "secret-exception".into(),
                        code: 2,
                    }),
                    trace_state: "secret-baggage".into(),
                    flags: u32::MAX,
                    ..Span::default()
                }],
                ..ScopeSpans::default()
            }],
            ..ResourceSpans::default()
        }],
    };
    (schema, request)
}

#[test]
fn schema_replaces_origin_and_discards_unreviewed_context() {
    let (schema, request) = schema_request();
    let clean = schema
        .sanitize(
            &request.encode_to_vec(),
            "galileo",
            "trusted-host",
            "0123abc",
        )
        .unwrap();
    let decoded = ExportTraceServiceRequest::decode(clean.as_slice()).unwrap();
    let resource = &decoded.resource_spans[0];
    assert_eq!(
        resource.resource.as_ref().unwrap().attributes,
        vec![
            attribute("service.name", "galileo"),
            attribute("host.name", "trusted-host"),
            attribute("overalls.telemetry.origin", "application"),
            attribute("service.version", "0123abc"),
            attribute("overalls.deployment.revision", "0123abc")
        ]
    );
    let span = &resource.scope_spans[0].spans[0];
    assert!(span.trace_state.is_empty());
    assert!(span.status.as_ref().unwrap().message.is_empty());
    assert_eq!(span.flags, 1);
    assert!(!String::from_utf8_lossy(&clean).contains("secret"));
}

/// @cc [owner:ghuntley,label:verification;security] trace-spool-unreviewed-attribute-refusal
/// An unreviewed attribute key MUST refuse the batch whatever its string value.
#[hegel::test(test_cases = 64)]
fn arbitrary_unreviewed_attribute_bytes_never_pass(tc: TestCase) {
    let value = tc.draw(gs::text().max_size(256));
    let (schema, mut request) = schema_request();
    request.resource_spans[0].scope_spans[0].spans[0]
        .attributes
        .push(attribute("payload", &value));
    assert_eq!(
        schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev"),
        Err(Error::Invalid)
    );
}

#[test]
fn schema_refuses_duplicates_unknown_enums_invalid_ids_and_negative_numbers() {
    let (schema, template) = schema_request();
    for invalid in [
        attribute("reason", "unreviewed"),
        attribute("request_id", "secret"),
        KeyValue {
            key: "duration_us".into(),
            value: Some(AnyValue {
                value: Some(any_value::Value::IntValue(-1)),
            }),
        },
    ] {
        let mut request = template.clone();
        request.resource_spans[0].scope_spans[0].spans[0].attributes = vec![invalid];
        assert_eq!(
            schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev"),
            Err(Error::Invalid)
        );
    }
    let mut request = template;
    request.resource_spans[0].scope_spans[0].spans[0]
        .attributes
        .push(attribute("reason", "unauthorized"));
    assert_eq!(
        schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev"),
        Err(Error::Invalid)
    );
}
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "overalls-trace-spool-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
/// @cc [owner:ghuntley,label:verification;recovery] trace-spool-archive-survives-ack-loss
/// ACK loss, delivery, reopen under a shorter retention policy and replay MUST
/// preserve every accepted body until its original expiry.
#[hegel::test(test_cases = 32)]
fn ack_loss_delivery_reopen_and_policy_change_preserve_archive(tc: TestCase) {
    let bodies = tc.draw(
        gs::vecs(gs::binary().min_size(1).max_size(511))
            .min_size(1)
            .max_size(23),
    );
    let directory = Directory::new();
    let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
    let mut accepted = BTreeMap::new();
    for body in bodies {
        let id = store.accept(&body, NS_PER_SECOND).unwrap();
        assert_eq!(&store.accept(&body, 2 * NS_PER_SECOND).unwrap(), &id);
        store.delivered(&id).unwrap();
        accepted.insert(id, body);
    }
    drop(store);
    let mut store = Store::open(&directory.0, 8_388_608, 60).unwrap();
    assert!(store.pending().unwrap().is_none());
    store.replay().unwrap();
    while let Some(batch) = store.pending().unwrap() {
        assert_eq!(&store.body(&batch).unwrap(), &accepted[&batch.id]);
        store.delivered(&batch.id).unwrap();
    }
    assert_eq!(store.batches, accepted.len() as u64);
    store.expire(3599 * NS_PER_SECOND).unwrap();
    assert_eq!(store.batches, accepted.len() as u64);
    store.expire(3601 * NS_PER_SECOND).unwrap();
    assert_eq!(store.batches, 0);
}

/// Independent UUID oracle: five hyphen-separated hex groups of 8-4-4-4-12.
fn uuid_oracle(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(group, len)| group.len() == len && group.chars().all(|c| c.is_ascii_hexdigit()))
}

/// Draws a string value that is near the UUID shape often enough to exercise
/// both acceptance and refusal of uuid attributes.
fn draw_text_value(tc: &TestCase) -> String {
    match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => tc.draw(gs::text().max_size(48)),
        1 => tc.draw(
            gs::text()
                .alphabet("0123456789abcdefABCDEF-g")
                .min_size(36)
                .max_size(36),
        ),
        2 => tc.draw(gs::sampled_from(vec![
            "unauthorized".to_owned(),
            "unreviewed".to_owned(),
            String::new(),
        ])),
        _ => {
            let mut value: String = (0..32)
                .map(|_| {
                    let nibble = tc.draw(gs::integers::<u32>().max_value(15));
                    char::from_digit(nibble, 16).unwrap()
                })
                .collect();
            for index in [8, 13, 18, 23] {
                value.insert(index, '-');
            }
            value
        }
    }
}

/// @cc [owner:ghuntley,label:verification;security] trace-spool-schema-attribute-closure
/// Over arbitrary keys and values, sanitize MUST accept exactly the reviewed
/// closure: uuid keys with an oracle-valid UUID string, enum keys with a
/// reviewed value and numeric keys with a non-negative integer. Every other
/// key, value type or value MUST refuse as invalid.
#[hegel::test(test_cases = 128)]
fn schema_attribute_closure_over_arbitrary_keys(tc: TestCase) {
    let (schema, mut request) = schema_request();
    let key = if tc.draw(gs::booleans()) {
        tc.draw(gs::sampled_from(vec![
            "request_id".to_owned(),
            "reason".to_owned(),
            "duration_us".to_owned(),
        ]))
    } else {
        tc.draw(gs::text().max_size(24))
    };
    let (value, expected) = if tc.draw(gs::booleans()) {
        let number = tc.draw(gs::integers::<i64>());
        let valid = key == "duration_us" && number >= 0;
        (any_value::Value::IntValue(number), valid)
    } else {
        let text = draw_text_value(&tc);
        let valid = match key.as_str() {
            "request_id" => uuid_oracle(&text),
            "reason" => text == "unauthorized",
            _ => false,
        };
        (any_value::Value::StringValue(text), valid)
    };
    request.resource_spans[0].scope_spans[0].spans[0].attributes = vec![KeyValue {
        key,
        value: Some(AnyValue { value: Some(value) }),
    }];
    let result = schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev");
    if expected {
        assert!(result.is_ok());
    } else {
        assert_eq!(result, Err(Error::Invalid));
    }
}

/// Independent FIPS 180-4 SHA-256, used only as a test oracle for `digest`.
fn sha256_oracle(message: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut padded = message.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&(message.len() as u64 * 8).to_be_bytes());
    for block in padded.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (word, bytes) in w.iter_mut().zip(block.chunks_exact(4)) {
            *word = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        }
        for t in 16..64 {
            let s0 = w[t - 15].rotate_right(7) ^ w[t - 15].rotate_right(18) ^ (w[t - 15] >> 3);
            let s1 = w[t - 2].rotate_right(17) ^ w[t - 2].rotate_right(19) ^ (w[t - 2] >> 10);
            w[t] = w[t - 16]
                .wrapping_add(s0)
                .wrapping_add(w[t - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for t in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[t])
                .wrapping_add(w[t]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
    state.iter().map(|word| format!("{word:08x}")).collect()
}

#[test]
fn sha256_oracle_matches_published_vectors() {
    assert_eq!(
        sha256_oracle(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        sha256_oracle(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        sha256_oracle(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    );
}

/// @cc [owner:ghuntley,label:verification;recovery] trace-spool-digest-identity
/// The batch identity MUST equal an independent SHA-256 lower-case hex digest
/// of the accepted body, and accept MUST return that identity.
#[hegel::test(test_cases = 64)]
fn digest_matches_independent_sha256_and_accept_returns_it(tc: TestCase) {
    let body = tc.draw(gs::binary().min_size(1).max_size(1024));
    let expected = sha256_oracle(&body);
    assert_eq!(digest(&body), expected);
    let directory = Directory::new();
    let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
    assert_eq!(store.accept(&body, NS_PER_SECOND), Ok(expected));
}

/// @cc [owner:ghuntley,label:verification;capacity] trace-spool-admission-bounds
/// Oversized bodies MUST refuse in sanitize (capacity) and accept (invalid);
/// empty bodies MUST refuse in both; accept MUST refuse a zero clock and any
/// clock whose expiry would overflow the signed SQLite range. Refusal MUST
/// count once and leave custody unchanged; in-range admission MUST succeed.
#[hegel::test(test_cases = 48)]
fn body_clock_and_retention_bounds_refuse_before_custody(tc: TestCase) {
    let retention_seconds = tc.draw(gs::integers::<u64>().min_value(60).max_value(31_536_000));
    let boundary = i64::MAX as u64 - retention_seconds * NS_PER_SECOND;
    let length = match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => 0,
        1 => BODY_LIMIT + 1 + tc.draw(gs::integers::<usize>().max_value(4096)),
        2 => BODY_LIMIT,
        _ => tc.draw(gs::integers::<usize>().min_value(1).max_value(512)),
    };
    let fill = tc.draw(gs::integers::<u8>());
    let body = vec![fill; length];
    let offset = tc.draw(gs::integers::<u64>().max_value(1 << 20));
    let now_ns = match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => 0,
        1 => boundary - offset,
        2 => boundary.saturating_add(1 + offset),
        _ => tc.draw(gs::integers::<u64>()),
    };
    let sanitized = Schema {
        services: BTreeMap::new(),
        uuid_attributes: BTreeSet::new(),
        enum_attributes: BTreeSet::new(),
        numeric_attributes: BTreeSet::new(),
        enum_values: BTreeSet::new(),
    }
    .sanitize(&body, "galileo", "host", "rev");
    let (schema, _) = schema_request();
    if length > BODY_LIMIT {
        assert_eq!(sanitized, Err(Error::Capacity));
        assert_eq!(
            schema.sanitize(&body, "galileo", "host", "rev"),
            Err(Error::Capacity)
        );
    } else if length == 0 {
        assert_eq!(
            schema.sanitize(&body, "galileo", "host", "rev"),
            Err(Error::Invalid)
        );
    }
    let directory = Directory::new();
    let mut store = Store::open(&directory.0, 8_388_608, retention_seconds).unwrap();
    let admissible = (1..=BODY_LIMIT).contains(&length) && now_ns != 0 && now_ns <= boundary;
    let result = store.accept(&body, now_ns);
    if admissible {
        assert_eq!(result, Ok(sha256_oracle(&body)));
        assert_eq!((store.batches, store.health.refused), (1, 0));
        let batch = store.pending().unwrap().unwrap();
        assert_eq!(batch.accepted_at_ns, now_ns);
        assert_eq!(
            batch.expires_at_ns,
            now_ns + retention_seconds * NS_PER_SECOND
        );
    } else {
        assert_eq!(result, Err(Error::Invalid));
        assert_eq!((store.batches, store.health.refused), (0, 1));
        assert!(store.pending().unwrap().is_none());
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] trace-spool-sql-integer-roundtrip
/// `sql` MUST accept exactly the values representable as a signed SQLite
/// integer and preserve them; `number` MUST read them back unchanged and
/// refuse negative stored integers.
#[hegel::test(test_cases = 64)]
fn sql_accepts_exactly_signed_range_and_roundtrips_through_sqlite(tc: TestCase) {
    let value = match tc.draw(gs::integers::<u8>().max_value(3)) {
        0 => i64::MAX as u64 - tc.draw(gs::integers::<u64>().max_value(16)),
        1 => i64::MAX as u64 + 1 + tc.draw(gs::integers::<u64>().max_value(16)),
        2 => tc.draw(gs::integers::<u64>().max_value(16)),
        _ => tc.draw(gs::integers::<u64>()),
    };
    let converted = sql(value);
    if value <= i64::MAX as u64 {
        assert_eq!(converted.map(|signed| signed as u64), Ok(value));
    } else {
        assert_eq!(converted, Err(Error::Invalid));
        return;
    }
    let directory = Directory::new();
    let database = rusqlite::Connection::open(directory.0.join("roundtrip.sqlite")).unwrap();
    database
        .execute_batch("CREATE TABLE numbers (value INTEGER NOT NULL) STRICT")
        .unwrap();
    database
        .execute("INSERT INTO numbers VALUES (?1)", [converted.unwrap()])
        .unwrap();
    let read: u64 = database
        .query_row("SELECT value FROM numbers", [], |row| number(row, 0))
        .unwrap();
    assert_eq!(read, value);
    let negative = -1 - tc.draw(gs::integers::<i64>().min_value(0));
    let refused = database.query_row("SELECT ?1", [negative], |row| number(row, 0));
    assert!(matches!(
        refused,
        Err(rusqlite::Error::IntegralValueOutOfRange(0, stored)) if stored == negative
    ));
}

#[test]
fn full_archive_refuses_without_evicting_and_corruption_poisons() {
    let directory = Directory::new();
    let mut store = Store::open(&directory.0, 4_194_304, 3600).unwrap();
    let body = vec![1; BODY_LIMIT];
    let id = store.accept(&body, NS_PER_SECOND).unwrap();
    for n in 2u8..8 {
        store
            .accept(&vec![n; BODY_LIMIT], NS_PER_SECOND + u64::from(n))
            .unwrap();
    }
    assert_eq!(
        store.accept(&vec![8; BODY_LIMIT], NS_PER_SECOND),
        Err(Error::Capacity)
    );
    let batch = store.pending().unwrap().unwrap();
    assert_eq!(store.body(&batch).unwrap(), body);
    store
        .db
        .execute("UPDATE batches SET body=X'00' WHERE id=?1", [id])
        .unwrap();
    assert_eq!(store.body(&batch), Err(Error::Storage));
    assert_eq!(store.accept(b"new", NS_PER_SECOND), Err(Error::Poisoned));
}
#[test]
fn concurrent_writer_missing_database_and_foreign_producer_refuse() {
    let directory = Directory::new();
    let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
    assert!(Store::open(&directory.0, 8_388_608, 3600).is_err());
    store
        .bind(
            "lilly",
            "node",
            "root",
            "lilly.service",
            "/system.slice/lilly.service",
        )
        .unwrap();
    assert_eq!(
        store.bind(
            "ziggy",
            "node",
            "root",
            "lilly.service",
            "/system.slice/lilly.service"
        ),
        Err(Error::Foreign)
    );
    store.accept(b"accepted", NS_PER_SECOND).unwrap();
    drop(store);
    std::fs::remove_file(directory.0.join("archive.sqlite")).unwrap();
    assert!(Store::open(&directory.0, 8_388_608, 3600).is_err());
}

#[test]
fn startup_refuses_orphan_pending_mismatched_index_and_missing_tables() {
    for mutation in [
        "UPDATE pending SET id='orphan-reference'",
        "UPDATE pending SET bytes=bytes+1",
        "UPDATE pending SET accepted_ns=accepted_ns+1",
        "DROP TABLE pending",
    ] {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
        store.accept(b"immutable-accepted", NS_PER_SECOND).unwrap();
        drop(store);
        let database = rusqlite::Connection::open(directory.0.join("archive.sqlite")).unwrap();
        database.execute_batch("PRAGMA foreign_keys=OFF").unwrap();
        database.execute_batch(mutation).unwrap();
        drop(database);
        assert!(
            matches!(
                Store::open(&directory.0, 8_388_608, 3600),
                Err(Error::Storage)
            ),
            "{mutation}"
        );
    }
}
