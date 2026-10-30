use super::{MachineAction, SnapshotMachine};

fn machine(
    state: Option<&str>,
    pinned: bool,
    owner: bool,
    write: bool,
    manage: bool,
) -> SnapshotMachine {
    SnapshotMachine {
        id: "id".into(),
        name: "name".into(),
        desired_state: "running".into(),
        observed_state: state.map(str::to_owned),
        pinned,
        owner: owner.then(|| "me".into()),
        read: true,
        write,
        manage,
    }
}

#[test]
fn action_visibility_matches_client_policy() {
    assert_eq!(
        machine(Some("running"), false, true, true, true).available_actions(),
        vec![
            MachineAction::Pause,
            MachineAction::Stop,
            MachineAction::Pin,
            MachineAction::Delete
        ]
    );
    assert_eq!(
        machine(Some("stopped"), true, true, true, true).available_actions(),
        vec![MachineAction::Start, MachineAction::Unpin]
    );
    assert_eq!(
        machine(Some("paused"), false, false, false, true).available_actions(),
        vec![MachineAction::Pin]
    );
}

#[test]
fn unknown_state_fails_closed_to_pin_only() {
    assert_eq!(
        machine(Some("migrating"), false, true, true, true).available_actions(),
        vec![MachineAction::Pin, MachineAction::Delete]
    );
}
