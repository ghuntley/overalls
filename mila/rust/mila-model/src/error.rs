use thiserror::Error;

/// Typed errors shared by model constructors and parsers.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ModelError {
    #[error("invalid identifier")]
    InvalidIdentifier,
    #[error("invalid application route")]
    InvalidRoute,
    #[error("invalid workspace source")]
    InvalidSource,
    #[error("invalid request id")]
    InvalidRequestId,
}
