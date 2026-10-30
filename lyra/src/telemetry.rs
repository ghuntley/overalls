//! Best-effort OTLP diagnostics from the guest executor. Guest claims never define fleet SLOs.

use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value::Value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::metrics::v1::{
    metric::Data, number_data_point::Value as NumberValue, AggregationTemporality, Histogram,
    HistogramDataPoint, Metric, NumberDataPoint, Sum,
};
use opentelemetry_proto::tonic::resource::v1::Resource;
use opentelemetry_proto::tonic::trace::v1::{ResourceSpans, ScopeSpans, Span};
use prost::Message;
use reqwest::header::CONTENT_TYPE;
use sha2::{Digest, Sha256};
use std::io;
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const ENDPOINT: &str = "https://otel.integration.internal/v1/metrics";
const TRACE_ENDPOINT: &str = "https://otel.integration.internal/v1/traces";
const BOUNDS_SECONDS: [f64; 6] = [0.01, 0.05, 0.1, 0.5, 1.0, 5.0];
const QUEUE_CAPACITY: usize = 16;

#[derive(Debug)]
struct Diagnostic {
    metrics: Vec<u8>,
    trace: Option<Vec<u8>>,
}

// @cc [owner:ghuntley,label:observability;recovery] lyra-bounded-diagnostic-worker
// A single observer worker MUST perform all diagnostic network I/O. Producers
// MUST use nonblocking admission into a fixed queue; saturation, failed spawn,
// receiver loss and TLS/HTTP failure MUST NOT delay acknowledged tool progress.
// Queued data MUST contain only the reviewed encoded metrics and spans.
fn diagnostic_queue(
    capacity: usize,
    mut export: impl FnMut(Diagnostic) + Send + 'static,
) -> io::Result<SyncSender<Diagnostic>> {
    let (sender, receiver) = mpsc::sync_channel(capacity);
    std::thread::Builder::new()
        .name("lyra-diagnostics".to_owned())
        .spawn(move || {
            while let Ok(diagnostic) = receiver.recv() {
                export(diagnostic);
            }
        })?;
    Ok(sender)
}

fn export(diagnostic: Diagnostic) {
    let Ok(client) = lyra::private_http::telemetry_client() else {
        return;
    };
    let _ = client
        .post(ENDPOINT)
        .header(CONTENT_TYPE, "application/x-protobuf")
        .body(diagnostic.metrics)
        .send();
    if let Some(trace) = diagnostic.trace {
        let _ = client
            .post(TRACE_ENDPOINT)
            .header(CONTENT_TYPE, "application/x-protobuf")
            .body(trace)
            .send();
    }
}

#[derive(Clone, Debug)]
struct Snapshot {
    start_ns: u64,
    calls: u64,
    errors: u64,
    duration_sum: f64,
    buckets: [u64; BOUNDS_SECONDS.len() + 1],
}

impl Snapshot {
    fn new(start_ns: u64) -> Self {
        Self {
            start_ns,
            calls: 0,
            errors: 0,
            duration_sum: 0.0,
            buckets: [0; BOUNDS_SECONDS.len() + 1],
        }
    }

    fn record(&mut self, completed: bool, duration: Duration) {
        self.calls = self.calls.saturating_add(1);
        if !completed {
            self.errors = self.errors.saturating_add(1);
        }
        let seconds = duration.as_secs_f64().min(86_400.0);
        self.duration_sum += seconds;
        let index = BOUNDS_SECONDS
            .iter()
            .position(|bound| seconds <= *bound)
            .unwrap_or(BOUNDS_SECONDS.len());
        self.buckets[index] = self.buckets[index].saturating_add(1);
    }
}

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn sum(name: &str, value: u64, snapshot: &Snapshot, now: u64) -> Metric {
    Metric {
        name: name.to_owned(),
        data: Some(Data::Sum(Sum {
            data_points: vec![NumberDataPoint {
                start_time_unix_nano: snapshot.start_ns,
                time_unix_nano: now,
                value: Some(NumberValue::AsInt(i64::try_from(value).unwrap_or(i64::MAX))),
                ..Default::default()
            }],
            aggregation_temporality: AggregationTemporality::Cumulative as i32,
            is_monotonic: true,
        })),
        ..Default::default()
    }
}

fn encode(snapshot: &Snapshot, now: u64) -> Vec<u8> {
    let mut request = ExportMetricsServiceRequest::default();
    let mut resource = opentelemetry_proto::tonic::metrics::v1::ResourceMetrics {
        resource: Some(Resource {
            attributes: vec![KeyValue {
                key: "service.name".to_owned(),
                value: Some(AnyValue {
                    value: Some(Value::StringValue("lyra".to_owned())),
                }),
            }],
            ..Default::default()
        }),
        ..Default::default()
    };
    let mut scope = opentelemetry_proto::tonic::metrics::v1::ScopeMetrics::default();
    scope.metrics.push(sum(
        "overalls.guest.tool_calls",
        snapshot.calls,
        snapshot,
        now,
    ));
    scope.metrics.push(sum(
        "overalls.guest.tool_errors",
        snapshot.errors,
        snapshot,
        now,
    ));
    scope.metrics.push(Metric {
        name: "overalls.guest.duration".to_owned(),
        unit: "s".to_owned(),
        data: Some(Data::Histogram(Histogram {
            data_points: vec![HistogramDataPoint {
                start_time_unix_nano: snapshot.start_ns,
                time_unix_nano: now,
                count: snapshot.calls,
                sum: Some(snapshot.duration_sum),
                bucket_counts: snapshot.buckets.to_vec(),
                explicit_bounds: BOUNDS_SECONDS.to_vec(),
                ..Default::default()
            }],
            aggregation_temporality: AggregationTemporality::Cumulative as i32,
        })),
        ..Default::default()
    });
    resource.scope_metrics.push(scope);
    request.resource_metrics.push(resource);
    request.encode_to_vec()
}

// @cc [owner:ghuntley,label:security;verification] lyra-guest-tool-trace
// Encode one span for an acknowledged terminal tool result with fixed names and
// no attributes, events, links, status message or raw command identifier.
// Invalid IDs MUST suppress the trace without affecting the tool result.
fn encode_trace(command_id: &str, started_ns: u64, ended_ns: u64) -> Option<Vec<u8>> {
    let compact: String = command_id.chars().filter(|ch| *ch != '-').collect();
    if compact.len() != 32 || hex::decode(&compact).ok()?.len() != 16 {
        return None;
    }
    let digest = Sha256::digest(
        [
            b"overalls.lyra.tool.trace.v1:".as_slice(),
            compact.as_bytes(),
        ]
        .concat(),
    );
    let span = Span {
        trace_id: digest[..16].to_vec(),
        span_id: digest[16..24].to_vec(),
        name: "lyra.tool_result".to_owned(),
        start_time_unix_nano: started_ns,
        end_time_unix_nano: ended_ns,
        ..Default::default()
    };
    Some(
        ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: Some(Resource {
                    // The host collector adds the receiving host's deployment
                    // revision; the guest names only its own build version.
                    attributes: vec![
                        KeyValue {
                            key: "service.name".to_owned(),
                            value: Some(AnyValue {
                                value: Some(Value::StringValue("lyra".to_owned())),
                            }),
                        },
                        KeyValue {
                            key: "service.version".to_owned(),
                            value: Some(AnyValue {
                                value: Some(Value::StringValue(
                                    env!("CARGO_PKG_VERSION").to_owned(),
                                )),
                            }),
                        },
                    ],
                    ..Default::default()
                }),
                scope_spans: vec![ScopeSpans {
                    spans: vec![span],
                    ..Default::default()
                }],
                ..Default::default()
            }],
        }
        .encode_to_vec(),
    )
}

// @cc [owner:ghuntley,label:security;recovery] lyra-guest-telemetry-best-effort
// Emit only cumulative, unlabeled tool counts, duration and a fixed-name span after the terminal
// control transition succeeds. Telemetry failure MUST NOT affect tool execution,
// and arguments, output, URLs, credentials and arbitrary errors MUST NOT enter OTLP.
pub(crate) fn tool_result(command_id: &str, completed: bool, duration: Duration) {
    static STATE: OnceLock<Mutex<Snapshot>> = OnceLock::new();
    static WORKER: OnceLock<Option<SyncSender<Diagnostic>>> = OnceLock::new();
    if !crate::config::guest_root() {
        return;
    }
    let now = now_ns();
    let state = STATE.get_or_init(|| Mutex::new(Snapshot::new(now)));
    let snapshot = match state.try_lock() {
        Ok(mut state) => {
            state.record(completed, duration);
            state.clone()
        }
        Err(_) => return,
    };
    let payload = encode(&snapshot, now);
    let trace = encode_trace(
        command_id,
        now.saturating_sub(u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)),
        now,
    );
    if let Some(worker) = WORKER.get_or_init(|| diagnostic_queue(QUEUE_CAPACITY, export).ok()) {
        // Snapshot totals continue across refused queue admission; a later
        // accepted snapshot includes them. Individual spans remain best effort.
        let _ = worker.try_send(Diagnostic {
            metrics: payload,
            trace,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    #[test]
    fn blocked_observer_cannot_block_tool_diagnostics_or_grow_the_queue() {
        let (entered, observation) = mpsc::sync_channel(1);
        let (release, blocked) = mpsc::sync_channel::<()>(1);
        let sender = diagnostic_queue(QUEUE_CAPACITY, move |_| {
            let _ = entered.send(());
            let _ = blocked.recv();
        })
        .unwrap();
        let diagnostic = || Diagnostic {
            metrics: encode(&Snapshot::new(1), 2),
            trace: encode_trace("00112233445566778899aabbccddeeff", 1, 2),
        };
        sender.try_send(diagnostic()).unwrap();
        observation.recv_timeout(Duration::from_secs(2)).unwrap();
        for _ in 0..QUEUE_CAPACITY {
            sender.try_send(diagnostic()).unwrap();
        }
        for _ in 0..1_000 {
            assert!(matches!(
                sender.try_send(diagnostic()),
                Err(mpsc::TrySendError::Full(_))
            ));
        }
        // Disconnect both controls so the worker exits without waiting for
        // network or accidentally keeping a test thread alive.
        drop(observation);
        drop(release);
        drop(sender);
    }

    #[hegel::test(test_cases = 100)]
    fn generated_tool_outcomes_keep_bounded_cumulative_points(tc: TestCase) {
        let duration_ms = tc.draw(gs::integers::<u32>());
        let outcomes = tc.draw(gs::integers::<u8>());
        let mut state = Snapshot::new(1);
        for index in 0..=outcomes {
            state.record(
                index & 1 == 0,
                Duration::from_millis(u64::from(duration_ms)),
            );
        }
        let bytes = encode(&state, 2);
        let decoded = ExportMetricsServiceRequest::decode(bytes.as_slice()).unwrap();
        let metrics = &decoded.resource_metrics[0].scope_metrics[0].metrics;
        assert_eq!(metrics.len(), 3);
        assert_eq!(state.calls, u64::from(outcomes) + 1);
        assert_eq!(state.errors, u64::from(outcomes).div_ceil(2));
        assert_eq!(state.buckets.iter().sum::<u64>(), state.calls);
        #[expect(
            clippy::cast_precision_loss,
            reason = "generated call counts are far below 2^52"
        )]
        let calls = state.calls as f64;
        assert!(state.duration_sum <= 86_400.0 * calls);
        assert_eq!(
            metrics
                .iter()
                .map(|metric| metric.name.as_str())
                .collect::<Vec<_>>(),
            [
                "overalls.guest.tool_calls",
                "overalls.guest.tool_errors",
                "overalls.guest.duration"
            ]
        );
        assert!(
            matches!(&metrics[0].data, Some(Data::Sum(value)) if value.data_points[0].attributes.is_empty())
        );
        assert!(
            matches!(&metrics[1].data, Some(Data::Sum(value)) if value.data_points[0].attributes.is_empty())
        );
        assert!(
            matches!(&metrics[2].data, Some(Data::Histogram(value)) if value.data_points[0].attributes.is_empty())
        );
    }

    #[hegel::test(test_cases = 100)]
    fn generated_trace_ids_keep_only_fixed_span_data(tc: TestCase) {
        let id = tc.draw(gs::integers::<u128>());
        let command_id = format!("{id:032x}");
        let bytes = encode_trace(&command_id, 100, 200).expect("valid id");
        let decoded = ExportTraceServiceRequest::decode(bytes.as_slice()).expect("trace protobuf");
        let resource = &decoded.resource_spans[0];
        let keys: Vec<&str> = resource
            .resource
            .as_ref()
            .unwrap()
            .attributes
            .iter()
            .map(|attribute| attribute.key.as_str())
            .collect();
        assert_eq!(keys, ["service.name", "service.version"]);
        let span = &resource.scope_spans[0].spans[0];
        assert_eq!(span.name, "lyra.tool_result");
        assert!(span.attributes.is_empty() && span.events.is_empty() && span.links.is_empty());
        assert_eq!(span.trace_id.len(), 16);
        assert_eq!(span.span_id.len(), 8);
        assert!(!bytes
            .windows(command_id.len())
            .any(|window| window == command_id.as_bytes()));
        assert_eq!(encode_trace(&command_id, 100, 200), Some(bytes));
        assert!(encode_trace("invalid", 100, 200).is_none());
    }
}
