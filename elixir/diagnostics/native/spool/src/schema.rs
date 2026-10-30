//! Reviewed span schema and provenance-replacing sanitization.

use crate::{Error, BODY_LIMIT};
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Schema {
    pub services: BTreeMap<String, BTreeSet<String>>,
    pub uuid_attributes: BTreeSet<String>,
    pub enum_attributes: BTreeSet<String>,
    pub numeric_attributes: BTreeSet<String>,
    pub enum_values: BTreeSet<String>,
}

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if [8, 13, 18, 23].contains(&i) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

pub(crate) fn attribute(key: &str, value: &str) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(any_value::Value::StringValue(value.to_owned())),
        }),
    }
}

impl Schema {
    pub fn load(path: &Path) -> Result<Self, Error> {
        let bytes = std::fs::read(path).map_err(|_| Error::Storage)?;
        if bytes.len() > 1_048_576 {
            return Err(Error::Invalid);
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)
    }

    /// @cc [owner:ghuntley,label:security] trace-schema-closes-provenance
    /// Unreviewed names/attributes MUST refuse. Producer resources, events,
    /// baggage and status messages MUST be discarded before durable storage.
    /// The resource MUST be exactly the configured service, host, application
    /// origin and deployment revision; the revision comes from the host build,
    /// never from the producer.
    #[expect(
        rustdoc::broken_intra_doc_links,
        reason = "the @cc contract tag is bracketed metadata, not an intra-doc link"
    )]
    #[expect(
        clippy::too_many_lines,
        reason = "one linear reviewed admission path; splitting it would scatter the closed provenance checks"
    )]
    pub fn sanitize(
        &self,
        body: &[u8],
        service: &str,
        host: &str,
        revision: &str,
    ) -> Result<Vec<u8>, Error> {
        if body.len() > BODY_LIMIT {
            return Err(Error::Capacity);
        }
        let names = self.services.get(service).ok_or(Error::Invalid)?;
        let mut request = ExportTraceServiceRequest::decode(body).map_err(|_| Error::Invalid)?;
        if request.resource_spans.len() != 1 {
            return Err(Error::Invalid);
        }
        let mut count = 0;
        for resource in &mut request.resource_spans {
            resource.resource = Some(Resource {
                attributes: vec![
                    attribute("service.name", service),
                    attribute("host.name", host),
                    attribute("overalls.telemetry.origin", "application"),
                    attribute("service.version", revision),
                    attribute("overalls.deployment.revision", revision),
                ],
                dropped_attributes_count: 0,
                ..Resource::default()
            });
            resource.schema_url.clear();
            if resource.scope_spans.len() > 8 {
                return Err(Error::Capacity);
            }
            for scope in &mut resource.scope_spans {
                scope.schema_url.clear();
                if let Some(instrumentation) = &mut scope.scope {
                    instrumentation.name = "overalls-reviewed".into();
                    instrumentation.version = "1".into();
                    instrumentation.attributes.clear();
                    instrumentation.dropped_attributes_count = 0;
                }
                for span in &mut scope.spans {
                    count += 1;
                    if count > 128
                        || !names.contains(&span.name)
                        || span.attributes.len() > 32
                        || span.trace_id.len() != 16
                        || span.span_id.len() != 8
                        || span.trace_id.iter().all(|byte| *byte == 0)
                        || span.span_id.iter().all(|byte| *byte == 0)
                        || (!span.parent_span_id.is_empty() && span.parent_span_id.len() != 8)
                        || span.start_time_unix_nano == 0
                        || span.end_time_unix_nano > i64::MAX as u64
                        || span.end_time_unix_nano < span.start_time_unix_nano
                        || !(0..=5).contains(&span.kind)
                        || span
                            .status
                            .as_ref()
                            .is_some_and(|status| !(0..=2).contains(&status.code))
                    {
                        return Err(Error::Invalid);
                    }
                    let mut keys = BTreeSet::new();
                    for attr in &span.attributes {
                        if !keys.insert(&attr.key) {
                            return Err(Error::Invalid);
                        }
                        let value = attr
                            .value
                            .as_ref()
                            .and_then(|v| v.value.as_ref())
                            .ok_or(Error::Invalid)?;
                        let valid = match value {
                            any_value::Value::StringValue(value)
                                if self.uuid_attributes.contains(&attr.key) =>
                            {
                                uuid(value)
                            }
                            any_value::Value::StringValue(value)
                                if self.enum_attributes.contains(&attr.key) =>
                            {
                                self.enum_values.contains(value)
                            }
                            any_value::Value::IntValue(value)
                                if self.numeric_attributes.contains(&attr.key) =>
                            {
                                *value >= 0
                            }
                            _ => false,
                        };
                        if !valid {
                            return Err(Error::Invalid);
                        }
                    }
                    span.attributes.sort_by(|a, b| a.key.cmp(&b.key));
                    span.events.clear();
                    span.links.clear();
                    span.trace_state.clear();
                    span.flags &= 1;
                    span.dropped_events_count = 0;
                    span.dropped_links_count = 0;
                    if let Some(status) = &mut span.status {
                        status.message.clear();
                    }
                }
            }
        }
        if count == 0 {
            return Err(Error::Invalid);
        }
        let bytes = request.encode_to_vec();
        if bytes.len() > BODY_LIMIT {
            return Err(Error::Capacity);
        }
        Ok(bytes)
    }
}
