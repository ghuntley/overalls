use crate::ModelError;
use serde::{Deserialize, Serialize};
use std::fmt;
use uuid::Uuid;

/// A canonical UUID used by a route or protocol identifier.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Identifier(Uuid);

impl Identifier {
    /// @cc [owner:ghuntley,label:protocol;security] mila-model-canonical-identifier
    /// Parses only the lowercase, hyphenated UUID representation used on the wire.
    ///
    /// Identifiers accepted from a route or command MUST be canonical lowercase UUIDs;
    /// accepting another representation would make route formatting ambiguous.
    pub fn parse(value: &str) -> Result<Self, ModelError> {
        let uuid = Uuid::parse_str(value).map_err(|_| ModelError::InvalidIdentifier)?;
        if uuid.to_string() != value {
            return Err(ModelError::InvalidIdentifier);
        }
        Ok(Self(uuid))
    }

    /// Returns the underlying UUID.
    pub const fn uuid(self) -> Uuid {
        self.0
    }
}

impl fmt::Display for Identifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}
