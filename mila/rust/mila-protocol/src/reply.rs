use crate::ProtocolError;
use mila_model::{Identifier, RequestId};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The protocol's closed receipt status.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReceiptStatus {
    Accepted,
    Succeeded,
    Failed,
    Superseded,
}

/// A typed mutation receipt.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Receipt {
    pub version: u8,
    pub request_id: RequestId,
    pub status: ReceiptStatus,
    pub operation_id: Option<Identifier>,
    #[serde(default)]
    pub result: Value,
}

/// A command result or refusal returned by Porsche.
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    Receipt(Receipt),
    Read(Value),
    Error {
        error: String,
        message: Option<String>,
    },
}

/// @cc [owner:ghuntley,label:protocol] mila-protocol-strict-envelope
/// Decodes a JSON result while preserving unknown result-body fields.
///
/// Envelope fields MUST be validated before use; result bodies may retain unknown keys
/// so store-distributed clients can read additive server fields safely.
pub fn decode_reply(value: &str) -> Result<Reply, ProtocolError> {
    let object: serde_json::Map<String, Value> =
        serde_json::from_str(value).map_err(|_| ProtocolError::InvalidJson)?;
    if object.get("error").is_some() {
        let error = object
            .get("error")
            .and_then(Value::as_str)
            .ok_or(ProtocolError::InvalidJson)?
            .to_owned();
        let message = object
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_owned);
        return Ok(Reply::Error { error, message });
    }
    if object.get("status").is_some() && object.get("request_id").is_some() {
        let receipt: Receipt = serde_json::from_value(Value::Object(object))
            .map_err(|_| ProtocolError::InvalidJson)?;
        return Ok(Reply::Receipt(receipt));
    }
    Ok(Reply::Read(Value::Object(object)))
}
