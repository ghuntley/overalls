use crate::{MutationTracker, NextAction, RuntimeError};
use mila_model::RequestId;
use mila_protocol::Reply;

// (Variants are kept stable for FFI consumers.)

/// A transport-independent operation submitted through a single mutation identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MutationRequest {
    pub request_id: RequestId,
    pub command: String,
}

/// I/O supplied by each platform adapter. The core controls retries and polling.
pub trait SessionBackend {
    type Error;
    fn submit(&mut self, request: &MutationRequest) -> Result<Reply, Self::Error>;
    fn poll(&mut self, request_id: &RequestId) -> Result<Reply, Self::Error>;
}

/// Owns one mutation tracker and prevents accidental duplicate submissions.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionRuntime {
    tracker: MutationTracker,
    command: String,
    submitted: bool,
}
impl SessionRuntime {
    pub fn new(request_id: RequestId, command: String) -> Result<Self, RuntimeError> {
        if command.is_empty() || command.len() > mila_protocol::MAX_COMMAND_BYTES {
            return Err(RuntimeError::InvalidCommand);
        }
        Ok(Self {
            tracker: MutationTracker::submitted(request_id),
            command,
            submitted: false,
        })
    }
    pub fn tracker(&self) -> &MutationTracker {
        &self.tracker
    }
    pub fn submit<B: SessionBackend>(&mut self, backend: &mut B) -> Result<(), RuntimeError> {
        if self.submitted {
            return Err(RuntimeError::AlreadySubmitted);
        }
        self.submitted = true;
        let request = MutationRequest {
            request_id: self.tracker.request_id.clone(),
            command: self.command.clone(),
        };
        let reply = backend
            .submit(&request)
            .map_err(|_| RuntimeError::Backend)?;
        self.tracker.observe(reply)
    }
    pub fn poll<B: SessionBackend>(&mut self, backend: &mut B) -> Result<NextAction, RuntimeError> {
        if !self.submitted {
            return Err(RuntimeError::NotSubmitted);
        }
        if self.tracker.next_action() == NextAction::Done {
            return Ok(NextAction::Done);
        }
        self.tracker.polled()?;
        let reply = backend
            .poll(&self.tracker.request_id)
            .map_err(|_| RuntimeError::Backend)?;
        self.tracker.observe(reply)?;
        Ok(self.tracker.next_action())
    }
}
