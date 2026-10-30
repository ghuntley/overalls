use thiserror::Error;

/// Runtime state machine failures.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RuntimeError {
    #[error("receipt request id does not match the tracker")]
    RequestMismatch,
    #[error("receipt operation id changed")]
    OperationMismatch,
    #[error("invalid snapshot")]
    InvalidSnapshot,
    #[error("snapshot is too large")]
    SnapshotTooLarge,
    #[error("snapshot belongs to another deployment")]
    SnapshotDeploymentMismatch,
    #[error("invalid push registration")]
    InvalidPushRegistration,
    #[error("invalid push poke")]
    InvalidPoke,
    #[error("command is invalid or exceeds bounds")]
    InvalidCommand,
    #[error("mutation was already submitted")]
    AlreadySubmitted,
    #[error("mutation has not been submitted")]
    NotSubmitted,
    #[error("session backend failed")]
    Backend,
    #[error("storage backend failed")]
    Storage,
}
