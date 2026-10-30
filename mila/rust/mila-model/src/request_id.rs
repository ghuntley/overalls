use crate::{ModelError, REQUEST_PREFIX};
use serde::{Deserialize, Serialize};
use std::fmt;

/// The client allocated mutation request identifier.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct RequestId(String);

impl RequestId {
    /// @cc [owner:ghuntley,label:protocol] mila-model-request-id
    /// Constructs an id from its canonical wire representation.
    ///
    /// Mutation request ids MUST have exactly `porsche-` plus 32 lowercase hexadecimal
    /// characters, preventing accidental retries under a different identity.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        let suffix = value
            .strip_prefix(REQUEST_PREFIX)
            .ok_or(ModelError::InvalidRequestId)?;
        if suffix.len() != 32
            || !suffix
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(ModelError::InvalidRequestId);
        }
        Ok(Self(value.into()))
    }

    /// Returns the wire representation.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for RequestId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}
