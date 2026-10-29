//! Presentation-safe machine list/detail projections for GTK.
//!
//! The session decoder validates protocol identity and permissions. This module
//! copies only display fields into a UI-owned projection and rejects control
//! characters before text reaches a GTK label.

use mila_session::MachineListing;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MachineRow {
    pub id: String,
    pub name: String,
    pub desired_state: String,
    pub observed_state: Option<String>,
    pub pinned: bool,
    pub can_read: bool,
    pub can_write: bool,
    pub can_manage: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MachineViewError {
    UnsafeDisplayText,
    TooManyMachines,
    NotFound,
    InvalidIdentifier,
}

const MAX_UI_MACHINES: usize = 256;

/// @cc [owner:ghuntley,label:security;desktop] linux-machine-view-bounded
/// GTK rows MUST derive from validated session listings and reject unsafe display text.
pub fn project_listing(listing: &MachineListing) -> Result<Vec<MachineRow>, MachineViewError> {
    if listing.machines().len() > MAX_UI_MACHINES {
        return Err(MachineViewError::TooManyMachines);
    }
    listing.machines().iter().map(project_machine).collect()
}

pub fn project_detail(
    listing: &MachineListing,
    machine_id: &str,
) -> Result<MachineRow, MachineViewError> {
    if machine_id.is_empty() || machine_id.len() > 64 || machine_id.chars().any(char::is_control) {
        return Err(MachineViewError::InvalidIdentifier);
    }
    let machine = listing
        .machines()
        .iter()
        .find(|machine| machine.id == machine_id)
        .ok_or(MachineViewError::NotFound)?;
    project_machine(machine)
}

fn project_machine(
    machine: &mila_runtime::SnapshotMachine,
) -> Result<MachineRow, MachineViewError> {
    if machine.name.chars().any(char::is_control)
        || machine.desired_state.chars().any(char::is_control)
        || machine
            .observed_state
            .as_deref()
            .is_some_and(|state| state.chars().any(char::is_control))
    {
        return Err(MachineViewError::UnsafeDisplayText);
    }
    Ok(MachineRow {
        id: machine.id.clone(),
        name: machine.name.clone(),
        desired_state: machine.desired_state.clone(),
        observed_state: machine.observed_state.clone(),
        pinned: machine.pinned,
        can_read: machine.read,
        can_write: machine.write,
        can_manage: machine.manage,
    })
}

#[cfg(test)]
mod tests {
    use super::{project_detail, project_listing, MachineViewError};
    use crate::adapter::decode_listing;

    const ID: &str = "01234567-89ab-cdef-0123-456789abcdef";

    fn listing() -> mila_session::MachineListing {
        decode_listing(
            format!(
                r#"{{"version":1,"status":"succeeded","result":{{"items":[{{"id":"{ID}","name":"Builder","desired_state":"running","observed_state":"running","pinned":true,"owner":true,"permissions":{{"read":true,"write":false,"manage":false}}}}],"next_cursor":null}}}}"#
            )
            .as_bytes(),
        )
        .expect("listing")
    }

    #[test]
    fn projects_bounded_list_and_detail_without_server_envelopes() {
        let listing = listing();
        let rows = project_listing(&listing).expect("rows");
        assert_eq!(rows[0].name, "Builder");
        assert!(rows[0].pinned);
        assert!(!rows[0].can_write);
        assert_eq!(project_detail(&listing, ID).unwrap().id, ID);
        assert_eq!(
            project_detail(&listing, "01234567-89ab-cdef-0123-456789abcdee"),
            Err(MachineViewError::NotFound)
        );
        assert_eq!(
            project_detail(&listing, "bad\n"),
            Err(MachineViewError::InvalidIdentifier)
        );
    }

    #[test]
    fn refuses_control_characters_before_gtk_projection() {
        let listing = decode_listing(
            format!(
                r#"{{"version":1,"status":"succeeded","result":{{"items":[{{"id":"{ID}","name":"bad\u000a","desired_state":"running","observed_state":null,"pinned":false,"owner":false,"permissions":{{"read":true,"write":false,"manage":false}}}}],"next_cursor":null}}}}"#
            )
            .as_bytes(),
        )
        .expect("protocol listing");
        assert_eq!(
            project_listing(&listing),
            Err(MachineViewError::UnsafeDisplayText)
        );
    }

    #[test]
    fn rejects_listing_larger_than_ui_bound() {
        let items = (0..257).map(|index| format!(r#"{{"id":"01234567-89ab-cdef-0123-{index:012x}","name":"Builder","desired_state":"running","observed_state":null,"pinned":false,"owner":false,"permissions":{{"read":true,"write":false,"manage":false}}}}"#)).collect::<Vec<_>>().join(",");
        let payload = format!(
            r#"{{"version":1,"status":"succeeded","result":{{"items":[{items}],"next_cursor":null}}}}"#
        );
        let listing = decode_listing(payload.as_bytes()).expect("protocol listing");
        assert_eq!(
            project_listing(&listing),
            Err(MachineViewError::TooManyMachines)
        );
    }
}
