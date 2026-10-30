//! Host-owned probe of Underclass' read-only, local monitor boundary.

use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value::Value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::metrics::v1::{
    metric::Data, number_data_point::Value as NumberValue, Gauge, Metric, NumberDataPoint,
    ResourceMetrics, ScopeMetrics,
};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;
use serde::Deserialize;
use std::io::{Read, Write};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_RESPONSE: u64 = 65_536;
const MAX_AGE_MS: u64 = 5_000;

#[derive(Debug, Deserialize)]
struct Counters {
    attempts: u64,
    unknown: u64,
    input_tokens: u64,
    output_tokens: u64,
}

#[derive(Debug, Deserialize)]
struct MonitorView {
    now_ms: u64,
    last_minute: Counters,
    minute_bins: Vec<u64>,
}

// @cc [owner:ghuntley,label:security;reliability] underclass-monitor-probe-bounded
// Only a complete, bounded 200 response with a fresh, nonnegative monitor
// snapshot may count as locally ready. Account labels, request data and tokens
// MUST NOT enter OTLP, logs or collector-assigned resource identity.
fn valid_response(bytes: &[u8], now_ms: u64) -> bool {
    let Some(split) = bytes.windows(4).position(|part| part == b"\r\n\r\n") else {
        return false;
    };
    let Ok(header) = std::str::from_utf8(&bytes[..split]) else {
        return false;
    };
    let mut lines = header.split("\r\n");
    if lines.next() != Some("HTTP/1.1 200 OK") {
        return false;
    }
    let mut content_length = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            return false;
        };
        if name.eq_ignore_ascii_case("content-length") {
            if content_length.is_some() {
                return false;
            }
            content_length = value.trim().parse::<usize>().ok();
        } else if name.eq_ignore_ascii_case("transfer-encoding") {
            return false;
        }
    }
    let body = &bytes[split + 4..];
    if body.len() > MAX_RESPONSE as usize || content_length != Some(body.len()) {
        return false;
    }
    let Ok(view) = serde_json::from_slice::<MonitorView>(body) else {
        return false;
    };
    view.now_ms.abs_diff(now_ms) <= MAX_AGE_MS
        && view.last_minute.unknown <= view.last_minute.attempts
        && view.last_minute.input_tokens <= i64::MAX as u64
        && view.last_minute.output_tokens <= i64::MAX as u64
        && view.minute_bins.len() == 60
        && view
            .minute_bins
            .iter()
            .all(|value| *value <= i64::MAX as u64)
}

fn probe(socket: &Path, now_ms: u64) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(socket) else {
        return false;
    };
    if !metadata.file_type().is_socket() {
        return false;
    }
    let Ok(mut stream) = UnixStream::connect(socket) else {
        return false;
    };
    if stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .and_then(|()| stream.set_write_timeout(Some(Duration::from_secs(2))))
        .is_err()
        || stream
            .write_all(b"GET /monitor HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .is_err()
    {
        return false;
    }
    let mut bytes = Vec::new();
    if stream
        .take(MAX_RESPONSE + 1025)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() as u64 > MAX_RESPONSE + 1024
    {
        return false;
    }
    valid_response(&bytes, now_ms)
}

fn attribute(key: &str, value: &str) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(Value::StringValue(value.to_owned())),
        }),
    }
}

/// @cc [owner:ghuntley,label:reliability] monitor-source-clock
/// Every probe MUST publish its sampling clock alongside the fixed readiness bit;
/// collector scrape timestamps MUST NOT substitute for this source observation.
fn encode(ready: bool, now_ns: u64) -> Vec<u8> {
    ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            resource: Some(Resource {
                attributes: vec![attribute("service.name", "underclass_monitor")],
                ..Default::default()
            }),
            scope_metrics: vec![ScopeMetrics {
                metrics: vec![
                    Metric {
                        name: "overalls.underclass.monitor.ready".to_owned(),
                        data: Some(Data::Gauge(Gauge {
                            data_points: vec![NumberDataPoint {
                                time_unix_nano: now_ns,
                                value: Some(NumberValue::AsInt(i64::from(ready))),
                                ..Default::default()
                            }],
                        })),
                        ..Default::default()
                    },
                    Metric {
                        name: "overalls.underclass.monitor.sample_time".to_owned(),
                        data: Some(Data::Gauge(Gauge {
                            data_points: vec![NumberDataPoint {
                                time_unix_nano: now_ns,
                                value: Some(NumberValue::AsDouble(now_ns as f64 / 1_000_000_000.0)),
                                ..Default::default()
                            }],
                        })),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }],
            ..Default::default()
        }],
    }
    .encode_to_vec()
}

fn send(body: &[u8], socket: &Path) -> Result<(), &'static str> {
    let mut stream = UnixStream::connect(socket).map_err(|_| "collector")?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| "timeout")?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| "timeout")?;
    write!(stream, "POST /v1/metrics HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-protobuf\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len())
        .map_err(|_| "write")?;
    stream.write_all(body).map_err(|_| "write")?;
    let mut response = [0u8; 32];
    let count = stream.read(&mut response).map_err(|_| "response")?;
    if count < 12 || !response[..count].starts_with(b"HTTP/1.1 200") {
        return Err("rejected");
    }
    Ok(())
}

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .min(u128::from(u64::MAX)) as u64
}

/// A local probe publishes fixed 0/1 observations. Missing collector delivery
/// leaves the central readiness candidate unknown, never successful.
pub fn run(monitor_socket: &Path, collector_socket: &Path) -> ! {
    loop {
        let now = now_ns();
        let ready = probe(monitor_socket, now / 1_000_000);
        let _ = send(&encode(ready, now), collector_socket);
        // Keep several observations inside the 45-second source freshness
        // guard even when a collector scrape or rule evaluation is delayed.
        std::thread::sleep(Duration::from_secs(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    fn response(now: u64, attempts: u64, unknown: u64, bins: usize) -> Vec<u8> {
        let body = serde_json::json!({
            "now_ms": now,
            "last_minute": {"attempts": attempts, "unknown": unknown, "input_tokens": 0, "output_tokens": 0},
            "minute_bins": vec![0u64; bins],
            "accounts": [{"label": "private account"}],
            "recent": [{"model": "private model"}]
        }).to_string();
        format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    /// @cc [owner:ghuntley,label:verification] otel-receiver-probe-clock-property
    /// For any generated sample time and readiness, the probe OTLP MUST carry
    /// exactly the readiness and sample-clock gauges at that time.
    #[hegel::test(test_cases = 256)]
    fn probe_sampling_clock_preserves_observation(tc: TestCase) {
        let now = tc.draw(gs::integers::<u64>().max_value(u64::MAX - 1));
        let ready = tc.draw(gs::booleans());
        let request = ExportMetricsServiceRequest::decode(encode(ready, now).as_slice()).unwrap();
        let metrics = &request.resource_metrics[0].scope_metrics[0].metrics;
        assert_eq!(metrics.len(), 2);
        let Some(Data::Gauge(clock)) = &metrics[1].data else {
            panic!("clock gauge");
        };
        assert_eq!(clock.data_points[0].time_unix_nano, now);
        assert_eq!(
            clock.data_points[0].value,
            Some(NumberValue::AsDouble(now as f64 / 1_000_000_000.0))
        );
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-monitor-freshness-property
    /// Generated monitor replies MUST validate only when fresh, conserving and
    /// carrying exactly sixty minute bins.
    #[hegel::test(test_cases = 256)]
    fn monitor_freshness_and_accounting_are_closed(tc: TestCase) {
        let now = tc.draw(gs::integers::<u64>().min_value(10_000).max_value(999_999));
        let attempts = tc.draw(gs::integers::<u64>().max_value(999));
        let unknown = tc.draw(gs::integers::<u64>().max_value(999));
        let offset = tc.draw(gs::integers::<u64>().max_value(11_999));
        let unknown = unknown.min(attempts);
        assert!(valid_response(&response(now, attempts, unknown, 60), now));
        assert!(!valid_response(
            &response(now + 5_001 + offset, attempts, unknown, 60),
            now
        ));
        assert!(!valid_response(
            &response(now, attempts, attempts + 1, 60),
            now
        ));
        assert!(!valid_response(&response(now, attempts, unknown, 59), now));
    }

    #[test]
    fn otlp_contains_fixed_probe_identity_readiness_and_clock() {
        let request = ExportMetricsServiceRequest::decode(encode(false, 42).as_slice()).unwrap();
        let resource = &request.resource_metrics[0];
        assert_eq!(resource.resource.as_ref().unwrap().attributes.len(), 1);
        let metric = &resource.scope_metrics[0].metrics[0];
        assert_eq!(metric.name, "overalls.underclass.monitor.ready");
        let Some(Data::Gauge(gauge)) = &metric.data else {
            panic!("gauge");
        };
        assert_eq!(gauge.data_points[0].value, Some(NumberValue::AsInt(0)));
        assert_eq!(resource.scope_metrics[0].metrics.len(), 2);
        let clock = &resource.scope_metrics[0].metrics[1];
        assert_eq!(clock.name, "overalls.underclass.monitor.sample_time");
        let Some(Data::Gauge(gauge)) = &clock.data else {
            panic!("clock gauge");
        };
        assert_eq!(
            gauge.data_points[0].value,
            Some(NumberValue::AsDouble(42.0 / 1_000_000_000.0))
        );
    }
}
