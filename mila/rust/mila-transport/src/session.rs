use thiserror::Error;

/// A bounded request accepted by a Porsche session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SessionRequest {
    Exec { command: String },
    Watch { machine_id: String },
}
/// Typed replies keep transport details out of native UI wrappers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SessionReply {
    Output(Vec<u8>),
    State { machine_id: String, state: String },
    Closed,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error)]
pub enum TransportError {
    #[error("session is closed")]
    Closed,
    #[error("request exceeds bounds")]
    RequestTooLarge,
    #[error("transport unavailable")]
    Unavailable,
}
/// Platform implementations provide the I/O while the Rust core owns validation.
pub trait PorscheSession {
    fn send(&mut self, request: SessionRequest) -> Result<SessionReply, TransportError>;
}
