use serde::{Deserialize, Serialize};

/// A closed, privacy-preserving machine representation suitable for caching.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotMachine {
    pub id: String,
    pub name: String,
    pub desired_state: String,
    pub observed_state: Option<String>,
    pub pinned: bool,
    pub owner: Option<String>,
    pub read: bool,
    pub write: bool,
    pub manage: bool,
}

/// Mutations the native clients may present for a cached machine.
///
/// This keeps action visibility identical across Swift, Kotlin, GTK and WinUI;
/// clients must not reimplement permission or state rules in each UI toolkit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum MachineAction {
    Start,
    Stop,
    Pause,
    Resume,
    Pin,
    Unpin,
    Delete,
}

impl SnapshotMachine {
    /// @cc [owner:ghuntley,label:protocol;security] mila-runtime-machine-actions
    /// Returns actions in the stable order used by the native clients.
    pub fn available_actions(&self) -> Vec<MachineAction> {
        let mut actions = Vec::with_capacity(3);
        if self.write {
            match self.observed_state.as_deref() {
                Some("stopped") => actions.push(MachineAction::Start),
                Some("paused") => actions.push(MachineAction::Resume),
                Some("running") => {
                    actions.push(MachineAction::Pause);
                    actions.push(MachineAction::Stop);
                }
                _ => {}
            }
        }
        actions.push(if self.pinned {
            MachineAction::Unpin
        } else {
            MachineAction::Pin
        });
        if self.manage && self.owner.is_some() && !self.pinned {
            actions.push(MachineAction::Delete);
        }
        actions
    }
}
