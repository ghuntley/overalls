//! Guest OTLP metric and trace sanitization with closed vocabularies.

use crate::binding::Binding;
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value::Value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;

const MAX_METRICS: usize = 128;
const MAX_POINTS: usize = 1024;
const MAX_SPANS: usize = 256;

pub(crate) fn safe_name(name: &str, max_len: usize, first_alpha: bool) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= max_len
        && (!first_alpha || bytes[0].is_ascii_alphabetic())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'_' | b'-' | b'.' | b' '))
}

pub(crate) fn allowed_metric(name: &str) -> bool {
    matches!(
        name,
        "overalls.guest.requests"
            | "overalls.guest.errors"
            | "overalls.guest.duration"
            | "overalls.guest.active"
            | "overalls.guest.tool_calls"
            | "overalls.guest.tool_errors"
            | "overalls.guest.tokens"
            | "overalls.guest.ready"
    )
}

pub(crate) fn service_name(resource: &Resource) -> &'static str {
    const SERVICES: &[&str] = &[
        "marshall", "lilly", "audi", "porsche", "ziggy", "galileo", "enrico", "brady", "lyra",
    ];
    for attribute in &resource.attributes {
        if attribute.key == "service.name" {
            if let Some(AnyValue {
                value: Some(Value::StringValue(value)),
            }) = &attribute.value
            {
                if let Some(service) = SERVICES.iter().find(|service| **service == value) {
                    return service;
                }
            }
        }
    }
    "unknown"
}

pub(crate) fn attribute(key: &str, value: String) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(Value::StringValue(value)),
        }),
    }
}

fn replace_resource(resource: &mut Resource, binding: &Binding, service: &str) {
    resource.attributes = vec![
        attribute("service.name", format!("guest-{service}")),
        attribute("overalls.telemetry.origin", "guest".to_owned()),
        attribute("overalls.outer.host_id", binding.host_id.clone()),
        attribute("overalls.outer.vm_id", binding.vm_id.clone()),
        attribute("overalls.outer.placement_id", binding.placement_id.clone()),
        attribute(
            "overalls.outer.execution_epoch",
            binding.execution_epoch.to_string(),
        ),
    ];
    resource.dropped_attributes_count = 0;
}

// @cc [owner:ghuntley,label:security] guest-telemetry-untrusted
// Only the guest metric namespace and closed resource labels may leave this process.
pub fn sanitize_metrics(body: &[u8], binding: &Binding) -> Result<Vec<u8>, &'static str> {
    let mut request = ExportMetricsServiceRequest::decode(body).map_err(|_| "protobuf")?;
    let mut metric_count = 0usize;
    let mut point_count = 0usize;
    for resource in &mut request.resource_metrics {
        let original = resource.resource.get_or_insert_with(Resource::default);
        let service = service_name(original);
        replace_resource(original, binding, service);
        resource.schema_url.clear();
        for scope in &mut resource.scope_metrics {
            if let Some(instrumentation) = &mut scope.scope {
                instrumentation.attributes.clear();
                instrumentation.name = "overalls-guest".to_owned();
                instrumentation.version.clear();
                instrumentation.dropped_attributes_count = 0;
            }
            scope.schema_url.clear();
            for metric in &mut scope.metrics {
                metric_count += 1;
                if metric_count > MAX_METRICS || !allowed_metric(&metric.name) {
                    return Err("metric_name_or_count");
                }
                metric.description.clear();
                metric.unit.clear();
                use opentelemetry_proto::tonic::metrics::v1::metric::Data;
                match metric.data.as_mut().ok_or("metric_kind")? {
                    Data::Gauge(data) => {
                        point_count += data.data_points.len();
                        for point in &mut data.data_points {
                            point.attributes.clear();
                            point.exemplars.clear();
                        }
                    }
                    Data::Sum(data) => {
                        point_count += data.data_points.len();
                        for point in &mut data.data_points {
                            point.attributes.clear();
                            point.exemplars.clear();
                        }
                    }
                    Data::Histogram(data) => {
                        point_count += data.data_points.len();
                        for point in &mut data.data_points {
                            if point.explicit_bounds.len() > 32 {
                                return Err("histogram_bounds");
                            }
                            point.attributes.clear();
                            point.exemplars.clear();
                        }
                    }
                    _ => return Err("metric_kind"),
                }
                if point_count > MAX_POINTS {
                    return Err("point_count");
                }
            }
        }
    }
    if metric_count == 0 {
        return Err("empty_metrics");
    }
    Ok(request.encode_to_vec())
}

pub fn sanitize_traces(body: &[u8], binding: &Binding) -> Result<Vec<u8>, &'static str> {
    let mut request = ExportTraceServiceRequest::decode(body).map_err(|_| "protobuf")?;
    let mut span_count = 0usize;
    for resource in &mut request.resource_spans {
        let original = resource.resource.get_or_insert_with(Resource::default);
        let service = service_name(original);
        replace_resource(original, binding, service);
        resource.schema_url.clear();
        for scope in &mut resource.scope_spans {
            if let Some(instrumentation) = &mut scope.scope {
                instrumentation.attributes.clear();
                instrumentation.name = "overalls-guest".to_owned();
                instrumentation.version.clear();
                instrumentation.dropped_attributes_count = 0;
            }
            scope.schema_url.clear();
            for span in &mut scope.spans {
                span_count += 1;
                if span_count > MAX_SPANS || !safe_name(&span.name, 80, true) {
                    return Err("span_name_or_count");
                }
                span.attributes.clear();
                span.events.clear();
                span.links.clear();
                span.trace_state.clear();
                span.dropped_attributes_count = 0;
                span.dropped_events_count = 0;
                span.dropped_links_count = 0;
                if let Some(status) = &mut span.status {
                    status.message.clear();
                }
            }
        }
    }
    if span_count == 0 {
        return Err("empty_traces");
    }
    Ok(request.encode_to_vec())
}
