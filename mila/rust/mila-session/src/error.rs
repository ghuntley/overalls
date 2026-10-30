use mila_transport::ssh::SshError;

/// Errors deliberately exclude server bodies, command text and credentials.
#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("transport failed")]
    Transport(#[from] SshError),
    #[error("server refused the listing")]
    Refused,
    #[error("invalid machine listing")]
    InvalidListing,
    #[error("listing exceeds bounds")]
    Bounds,
    #[error("pagination cursor repeated")]
    RepeatedCursor,
    #[error("no listing has been loaded")]
    NotLoaded,
    #[error("mutation was refused")]
    MutationRefused,
    #[error("invalid thread action")]
    InvalidThreadAction,
}
