//! Porsche's bounded JSON and SSH command protocol.

use mila_model::{MilaRoute, ModelError};

mod command;
mod error;
mod grammar;
mod lex;
mod reply;

pub use command::{Command, OptionValue, PayloadKind};
pub use error::ProtocolError;
pub use grammar::{device_public_key_valid, parse_platform};
pub use mila_model::{MilaPage, WorkspaceSource};
pub use reply::{decode_reply, Receipt, ReceiptStatus, Reply};

/// Maximum command-line bytes accepted by Porsche.
pub const MAX_COMMAND_BYTES: usize = 8_192;
/// Maximum token count accepted by Porsche's lexer.
pub const MAX_TOKENS: usize = 32;

/// Encodes a route through the shared model parser.
pub fn parse_route(value: &str) -> Result<MilaRoute, ModelError> {
    MilaRoute::parse(value)
}

#[cfg(test)]
mod tests;
