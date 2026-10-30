use thiserror::Error;

/// Typed protocol failures.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProtocolError {
    #[error("invalid command")]
    InvalidCommand,
    #[error("command too large")]
    CommandTooLarge,
    #[error("invalid JSON")]
    InvalidJson,
}
