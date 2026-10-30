//! Unit and Hegel property tests for the guest sanitization boundary.

use super::*;
use crate::binding::canonical_uuid;
use crate::intake::{
    HOST_BYTES_PER_MINUTE, HOST_REQUESTS_PER_MINUTE, VM_BYTES_PER_MINUTE, VM_REQUESTS_PER_MINUTE,
};
use crate::sanitize::{allowed_metric, attribute, safe_name, service_name};
use base64::Engine;
use hegel::{generators as gs, TestCase};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value::Value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::metrics::v1::{metric::Data, Gauge, Metric, NumberDataPoint};
use opentelemetry_proto::tonic::resource::v1::Resource;
use opentelemetry_proto::tonic::trace::v1::{span, Span};
use prost::Message;
use std::time::{Duration, Instant};

fn binding() -> Binding {
    Binding {
        host_id: "12345678-1234-1234-1234-123456789abc".to_owned(),
        vm_id: "22345678-1234-1234-1234-123456789abc".to_owned(),
        placement_id: "32345678-1234-1234-1234-123456789abc".to_owned(),
        execution_epoch: 7,
    }
}

fn request(name: &str, secret: &str) -> ExportMetricsServiceRequest {
    let mut request = ExportMetricsServiceRequest::default();
    let mut resource = opentelemetry_proto::tonic::metrics::v1::ResourceMetrics {
        resource: Some(Resource {
            attributes: vec![attribute("overalls.outer.vm_id", secret.to_owned())],
            ..Default::default()
        }),
        ..Default::default()
    };
    let mut scope = opentelemetry_proto::tonic::metrics::v1::ScopeMetrics::default();
    scope.metrics.push(Metric {
        name: name.to_owned(),
        unit: secret.to_owned(),
        data: Some(Data::Gauge(Gauge {
            data_points: vec![NumberDataPoint {
                attributes: vec![attribute("secret", secret.to_owned())],
                ..Default::default()
            }],
        })),
        ..Default::default()
    });
    resource.scope_metrics.push(scope);
    request.resource_metrics.push(resource);
    request
}

/// @cc [owner:ghuntley,label:verification;capacity] otel-receiver-host-budget-property
/// Generated uploads from up to 4096 distinct guests MUST NOT exceed the
/// host-wide byte or request budget within one window.
#[hegel::test(test_cases = 256)]
fn host_budget_bounds_many_guests(tc: TestCase) {
    let uploads = tc.draw(
        gs::vecs(gs::tuples!(
            gs::integers::<u16>().max_value(4095),
            gs::integers::<usize>().min_value(1).max_value(65_535)
        ))
        .max_size(299),
    );
    let now = Instant::now();
    let mut limiter = IntakeLimit::new(now);
    let mut accepted_bytes = 0usize;
    let mut accepted_requests = 0usize;
    for (guest, size) in uploads {
        let mut identity = binding();
        identity.vm_id = format!("{guest:08x}-1234-1234-1234-123456789abc");
        if limiter.admit(&identity, size, now) {
            accepted_bytes += size;
            accepted_requests += 1;
        }
    }
    assert!(accepted_bytes <= HOST_BYTES_PER_MINUTE);
    assert!(accepted_requests <= HOST_REQUESTS_PER_MINUTE);
}

/// @cc [owner:ghuntley,label:verification;capacity] otel-receiver-guest-budget-property
/// Generated upload sizes from one guest MUST NOT exceed its per-VM byte or
/// request budget within one window.
#[hegel::test(test_cases = 256)]
fn guest_rate_budget_bounds_arbitrary_uploads(tc: TestCase) {
    let sizes = tc.draw(gs::vecs(gs::integers::<usize>().max_value(1_048_576)).max_size(199));
    let now = Instant::now();
    let mut limiter = IntakeLimit::new(now);
    let mut accepted_bytes = 0usize;
    let mut accepted_requests = 0usize;
    for size in sizes {
        if limiter.admit(&binding(), size, now) {
            accepted_bytes += size;
            accepted_requests += 1;
        }
    }
    assert!(accepted_bytes <= VM_BYTES_PER_MINUTE);
    assert!(accepted_requests <= VM_REQUESTS_PER_MINUTE);
}

fn encode_binding(binding: &Binding) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(binding).expect("serialize fixture"))
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-binding-roundtrip
/// Every canonical binding with a nonzero epoch MUST survive encode/parse.
#[hegel::test(test_cases = 256)]
fn valid_binding_round_trips(tc: TestCase) {
    let epoch = tc.draw(gs::integers::<u64>().min_value(1).max_value(u64::MAX - 1));
    let mut expected = binding();
    expected.execution_epoch = epoch;
    assert_eq!(parse_binding(&encode_binding(&expected)), Ok(expected));
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-binding-size-refusal
/// A binding header longer than 512 bytes MUST be refused as `binding_size`
/// before decoding, whatever its content.
#[hegel::test(test_cases = 128)]
fn oversized_binding_header_is_refused(tc: TestCase) {
    let header = tc.draw(
        gs::text()
            .alphabet("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            .min_size(513)
            .max_size(1024),
    );
    assert_eq!(parse_binding(&header), Err("binding_size"));
    let mut padded = encode_binding(&binding());
    while padded.len() <= 512 {
        padded.push_str(&encode_binding(&binding()));
    }
    assert_eq!(parse_binding(&padded), Err("binding_size"));
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-binding-padding-refusal
/// A binding header containing `=` anywhere MUST be refused as `binding_size`,
/// even when the rest of the header is a valid unpadded encoding.
#[hegel::test(test_cases = 128)]
fn padded_binding_header_is_refused(tc: TestCase) {
    let mut header = encode_binding(&binding());
    let at = tc.draw(gs::integers::<usize>().max_value(header.len()));
    let padding = tc.draw(gs::integers::<usize>().min_value(1).max_value(2));
    header.insert_str(at, &"=".repeat(padding));
    assert_eq!(parse_binding(&header), Err("binding_size"));
}

/// Independent canonical UUID oracle: five lowercase-hex groups 8-4-4-4-12.
fn uuid_oracle(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 5
        && groups.iter().zip([8, 4, 4, 4, 12]).all(|(group, width)| {
            group.chars().count() == width
                && group.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))
        })
}

/// A canonical UUID, optionally with one character replaced by a drawn one.
fn draw_uuid(tc: &TestCase) -> String {
    let raw = format!("{:032x}", tc.draw(gs::integers::<u128>()));
    let mut uuid = format!(
        "{}-{}-{}-{}-{}",
        &raw[0..8],
        &raw[8..12],
        &raw[12..16],
        &raw[16..20],
        &raw[20..32]
    );
    if tc.draw(gs::booleans()) {
        let at = tc.draw(gs::integers::<usize>().max_value(35));
        let replacement = tc.draw(gs::sampled_from(vec![
            'A', 'F', 'g', 'z', '-', '0', 'f', ' ', '\u{e9}', '_',
        ]));
        let mut chars: Vec<char> = uuid.chars().collect();
        chars[at] = replacement;
        uuid = chars.into_iter().collect();
    }
    if tc.draw(gs::booleans()) {
        match tc.draw(gs::integers::<u8>().max_value(2)) {
            0 => {
                uuid.pop();
            }
            1 => uuid.push('a'),
            _ => uuid = uuid.to_uppercase(),
        }
    }
    uuid
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-canonical-uuid-oracle
/// `canonical_uuid` MUST accept exactly the lowercase 8-4-4-4-12 hex form,
/// agreeing with an independent group-splitting oracle.
#[hegel::test(test_cases = 512)]
fn canonical_uuid_matches_oracle(tc: TestCase) {
    let value = if tc.draw(gs::booleans()) {
        draw_uuid(&tc)
    } else {
        tc.draw(
            gs::text()
                .alphabet("0123456789abcdefABCDEFg-")
                .min_size(34)
                .max_size(38),
        )
    };
    assert_eq!(canonical_uuid(&value), uuid_oracle(&value));
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-binding-identity-refusal
/// A binding whose host, VM or placement identity is not a canonical UUID,
/// or whose epoch is zero, MUST be refused as `binding_identity`.
#[hegel::test(test_cases = 256)]
fn noncanonical_binding_identity_is_refused(tc: TestCase) {
    let mut candidate = binding();
    let identity = draw_uuid(&tc);
    match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => candidate.host_id = identity,
        1 => candidate.vm_id = identity,
        _ => candidate.placement_id = identity,
    }
    let zero_epoch = tc.draw(gs::booleans());
    if zero_epoch {
        candidate.execution_epoch = 0;
    }
    let canonical = [
        &candidate.host_id,
        &candidate.vm_id,
        &candidate.placement_id,
    ]
    .iter()
    .all(|value| uuid_oracle(value));
    let result = parse_binding(&encode_binding(&candidate));
    if canonical && !zero_epoch {
        assert_eq!(result, Ok(candidate));
    } else {
        assert_eq!(result, Err("binding_identity"));
    }
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-safe-name-bounds
/// `safe_name` MUST accept exactly nonempty names within the length bound,
/// drawn from the closed alphabet, with an alphabetic first byte when required.
#[hegel::test(test_cases = 512)]
fn safe_name_matches_bounds_oracle(tc: TestCase) {
    let name = tc.draw(gs::text().alphabet("aZ09_-. /:\n\u{e9}=").max_size(96));
    let max_len = tc.draw(gs::integers::<usize>().max_value(90));
    let first_alpha = tc.draw(gs::booleans());
    let chars: Vec<char> = name.chars().collect();
    let expected = !chars.is_empty()
        && chars.len() <= max_len
        && (!first_alpha || chars[0].is_ascii_alphabetic())
        && chars
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ' '));
    assert_eq!(safe_name(&name, max_len, first_alpha), expected);
}

const METRIC_VOCABULARY: [&str; 8] = [
    "overalls.guest.requests",
    "overalls.guest.errors",
    "overalls.guest.duration",
    "overalls.guest.active",
    "overalls.guest.tool_calls",
    "overalls.guest.tool_errors",
    "overalls.guest.tokens",
    "overalls.guest.ready",
];

/// @cc [owner:ghuntley,label:verification;capacity] otel-receiver-metric-vocabulary-closed
/// `allowed_metric` MUST accept exactly the eight reviewed guest metric names;
/// every prefix, suffix, case or character variation MUST be refused.
#[hegel::test(test_cases = 512)]
fn allowed_metric_vocabulary_is_closed(tc: TestCase) {
    let base = tc
        .draw(gs::sampled_from(METRIC_VOCABULARY.to_vec()))
        .to_owned();
    let name = match tc.draw(gs::integers::<u8>().max_value(5)) {
        0 => base,
        1 => format!(
            "{base}{}",
            tc.draw(gs::text().alphabet("._sa").min_size(1).max_size(4))
        ),
        2 => format!(
            "{}{base}",
            tc.draw(gs::text().alphabet("._sa").min_size(1).max_size(4))
        ),
        3 => {
            let keep = tc.draw(gs::integers::<usize>().max_value(base.len() - 1));
            base[..keep].to_owned()
        }
        4 => base.to_uppercase(),
        _ => tc.draw(gs::text().alphabet("overalls.guestrqidnmkp_").max_size(32)),
    };
    assert_eq!(
        allowed_metric(&name),
        METRIC_VOCABULARY.contains(&name.as_str())
    );
}

const SERVICE_VOCABULARY: [&str; 9] = [
    "marshall", "lilly", "audi", "porsche", "ziggy", "galileo", "enrico", "brady", "lyra",
];

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-service-name-total
/// `service_name` MUST be total: for any resource it returns the first known
/// string `service.name` value, otherwise `unknown`, never a guest string.
#[hegel::test(test_cases = 256)]
fn service_name_is_total(tc: TestCase) {
    let count = tc.draw(gs::integers::<usize>().max_value(6));
    let mut attributes = Vec::new();
    for _ in 0..count {
        let key = tc.draw(gs::sampled_from(vec![
            "service.name",
            "service.namespace",
            "x",
        ]));
        let value = match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => None,
            1 => Some(AnyValue {
                value: Some(Value::IntValue(tc.draw(gs::integers::<i64>()))),
            }),
            2 => Some(AnyValue {
                value: Some(Value::StringValue(
                    tc.draw(gs::sampled_from(SERVICE_VOCABULARY.to_vec()))
                        .to_owned(),
                )),
            }),
            _ => Some(AnyValue {
                value: Some(Value::StringValue(tc.draw(gs::text().max_size(16)))),
            }),
        };
        attributes.push(KeyValue {
            key: key.to_owned(),
            value,
        });
    }
    let expected = attributes
        .iter()
        .filter(|attribute| attribute.key == "service.name")
        .filter_map(
            |attribute| match attribute.value.as_ref()?.value.as_ref()? {
                Value::StringValue(value) => SERVICE_VOCABULARY
                    .iter()
                    .copied()
                    .find(|service| service == value),
                _ => None,
            },
        )
        .next()
        .unwrap_or("unknown");
    let resource = Resource {
        attributes,
        ..Default::default()
    };
    assert_eq!(service_name(&resource), expected);
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-outer-metric-refusal
/// Generated `overalls.outer.*` metric names MUST be refused.
#[hegel::test(test_cases = 256)]
fn guest_cannot_claim_outer_metric(tc: TestCase) {
    let name = tc.draw(
        gs::text()
            .alphabet("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.")
            .max_size(30),
    );
    let name = format!("overalls.outer.{name}");
    let body = request(&name, "secret").encode_to_vec();
    assert!(sanitize_metrics(&body, &binding()).is_err());
}

/// @cc [owner:ghuntley,label:verification;capacity] otel-receiver-unreviewed-metric-refusal
/// Generated unreviewed `overalls.guest.*` metric names MUST be refused.
#[hegel::test(test_cases = 256)]
fn guest_cannot_expand_metric_vocabulary(tc: TestCase) {
    let name = tc.draw(
        gs::text()
            .alphabet("abcdefghijklmnopqrstuvwxyz")
            .min_size(1)
            .max_size(20),
    );
    let name = format!("overalls.guest.unreviewed_{name}");
    let body = request(&name, "secret").encode_to_vec();
    assert!(sanitize_metrics(&body, &binding()).is_err());
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-metric-identity-replaced
/// For generated guest strings, sanitized metrics MUST carry only the
/// binding-derived resource identity and no guest units or point attributes.
#[hegel::test(test_cases = 256)]
fn guest_resource_and_dimensions_are_replaced(tc: TestCase) {
    let secret = tc.draw(gs::text().exclude_characters("\n").max_size(100));
    let body = request("overalls.guest.requests", &secret).encode_to_vec();
    let clean = sanitize_metrics(&body, &binding()).expect("valid guest metric");
    let parsed = ExportMetricsServiceRequest::decode(clean.as_slice()).expect("clean protobuf");
    let resource = &parsed.resource_metrics[0];
    let attributes = &resource.resource.as_ref().expect("resource").attributes;
    assert_eq!(attributes[0].key.as_str(), "service.name");
    assert_eq!(attributes[1].key.as_str(), "overalls.telemetry.origin");
    assert_eq!(
        attributes[3]
            .value
            .as_ref()
            .and_then(|value| value.value.as_ref()),
        Some(&Value::StringValue(binding().vm_id))
    );
    let metric = &resource.scope_metrics[0].metrics[0];
    assert!(metric.unit.is_empty());
    let Some(Data::Gauge(gauge)) = &metric.data else {
        panic!("sanitized metric lost its gauge");
    };
    assert!(gauge.data_points[0].attributes.is_empty());
}

/// @cc [owner:ghuntley,label:verification;security] otel-receiver-trace-detail-dropped
/// For generated guest strings, sanitized spans MUST drop attributes, events and links.
#[hegel::test(test_cases = 256)]
fn traces_drop_guest_events_and_attributes(tc: TestCase) {
    let secret = tc.draw(gs::text().exclude_characters("\n").max_size(100));
    let mut request = ExportTraceServiceRequest::default();
    let mut resource = opentelemetry_proto::tonic::trace::v1::ResourceSpans::default();
    let mut scope = opentelemetry_proto::tonic::trace::v1::ScopeSpans::default();
    scope.spans.push(Span {
        name: "guest.work".to_owned(),
        attributes: vec![attribute("secret", secret.clone())],
        events: vec![span::Event {
            name: secret.clone(),
            ..Default::default()
        }],
        links: vec![span::Link {
            trace_state: secret.clone(),
            ..Default::default()
        }],
        ..Default::default()
    });
    resource.scope_spans.push(scope);
    request.resource_spans.push(resource);
    let clean = sanitize_traces(&request.encode_to_vec(), &binding()).expect("valid span");
    let parsed = ExportTraceServiceRequest::decode(clean.as_slice()).expect("clean protobuf");
    let span = &parsed.resource_spans[0].scope_spans[0].spans[0];
    assert!(span.attributes.is_empty() && span.events.is_empty() && span.links.is_empty());
}

#[test]
fn metric_count_is_bounded() {
    let mut request = request("overalls.guest.requests", "secret");
    let metric = request.resource_metrics[0].scope_metrics[0].metrics[0].clone();
    request.resource_metrics[0].scope_metrics[0]
        .metrics
        .resize(129, metric);
    assert!(sanitize_metrics(&request.encode_to_vec(), &binding()).is_err());
}

#[test]
fn budgets_reopen_after_window_expires() {
    let now = Instant::now();
    let mut limiter = IntakeLimit::new(now);
    assert!(limiter.admit(&binding(), VM_BYTES_PER_MINUTE, now));
    assert!(!limiter.admit(&binding(), 1, now));
    assert!(limiter.admit(
        &binding(),
        VM_BYTES_PER_MINUTE,
        now + Duration::from_secs(60)
    ));
}
