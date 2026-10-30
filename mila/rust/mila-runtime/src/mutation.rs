use crate::RuntimeError;
use mila_model::RequestId;
use mila_protocol::{ReceiptStatus, Reply};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The externally observable phase of one mutation request.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum MutationPhase {
    Submitted,
    Uncertain,
    Accepted,
    Succeeded,
    Failed,
    Refused,
}

impl MutationPhase {
    pub const fn terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Refused)
    }
}

/// Immutable state for a mutation submitted at most once.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MutationTracker {
    pub request_id: RequestId,
    pub phase: MutationPhase,
    pub polls: u32,
    pub operation_id: Option<String>,
    pub error: Option<String>,
    pub result: Value,
}

impl MutationTracker {
    /// @cc [owner:ghuntley,label:protocol;security] mila-runtime-mutation-once
    /// Allocates a tracker before any network submission.
    ///
    /// A tracker MUST retain one request id for its lifetime; uncertainty transitions
    /// to polling and MUST never create a second submission id.
    pub fn submitted(request_id: RequestId) -> Self {
        Self {
            request_id,
            phase: MutationPhase::Submitted,
            polls: 0,
            operation_id: None,
            error: None,
            result: Value::Object(serde_json::Map::default()),
        }
    }

    /// Records a poll issued against the original request id.
    pub fn polled(&mut self) -> Result<(), RuntimeError> {
        if self.phase.terminal() {
            return Ok(());
        }
        self.polls = self.polls.saturating_add(1);
        Ok(())
    }

    /// Marks the submission outcome unknown without permitting resubmission.
    pub fn uncertain(&mut self) {
        if !self.phase.terminal() {
            self.phase = MutationPhase::Uncertain;
        }
    }

    /// Applies a receipt or refusal; terminal states absorb late replies.
    pub fn observe(&mut self, reply: Reply) -> Result<(), RuntimeError> {
        if self.phase.terminal() {
            return Ok(());
        }
        match reply {
            Reply::Receipt(receipt) => {
                if receipt.request_id != self.request_id {
                    return Err(RuntimeError::RequestMismatch);
                }
                if let (Some(previous), Some(current)) = (&self.operation_id, receipt.operation_id)
                {
                    if previous != &current.to_string() {
                        return Err(RuntimeError::OperationMismatch);
                    }
                }
                self.operation_id = receipt.operation_id.map(|value| value.to_string());
                self.result = receipt.result;
                self.phase = match receipt.status {
                    ReceiptStatus::Accepted => MutationPhase::Accepted,
                    ReceiptStatus::Succeeded => MutationPhase::Succeeded,
                    ReceiptStatus::Failed | ReceiptStatus::Superseded => MutationPhase::Failed,
                };
            }
            Reply::Error { error, .. } => {
                self.error = Some(error);
                self.phase = MutationPhase::Refused;
            }
            Reply::Read(_) => self.uncertain(),
        }
        Ok(())
    }

    /// Returns the command the caller may issue next.
    pub const fn next_action(&self) -> NextAction {
        if self.phase.terminal() {
            NextAction::Done
        } else {
            NextAction::Poll
        }
    }
}

/// Runtime work required after observing a tracker.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NextAction {
    Poll,
    Done,
}
