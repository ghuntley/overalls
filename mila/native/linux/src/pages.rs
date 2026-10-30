//! GTK Machines (list, detail, lifecycle, create/resize, sharing, web) and
//! Threads pages.
//!
//! Every action runs through [`NativeState::with_live`] on the session the
//! window signed in with, so a transport error releases the session and
//! starts reconnect immediately. Responses are decoded by the library
//! (`machine_view`, `porsche_results`, `adapter`) before any field reaches a
//! widget, and every visible string comes from the shared catalogs.

use super::strings::{self, Message as M};
use super::views::{self, clear_list, heading, ConfirmBar, Pending};
use super::NativeState;
use gtk::prelude::*;
use gtk::{gio, Align, Box, Button, DropDown, Entry, Label, ListBox, Orientation};
use mila_native_linux::adapter::{
    browser_endpoint_url, decode_share_listing, decode_web_endpoint, format_machine_action,
    WebEndpoint,
};
use mila_native_linux::machine_view::project_snapshot;
use mila_native_linux::porsche_results::{
    decode_machine_detail, decode_thread_detail, decode_thread_events, decode_thread_rows,
    ThreadDetail,
};
use mila_native_linux::session::SessionError;
use std::{cell::RefCell, rc::Rc};

/// Widget names the GTK journey uses to find a section's controls.
pub(super) const MACHINE_LIST: &str = "mila-machine-list";
pub(super) const MACHINE_LIFECYCLE: &str = "mila-machine-lifecycle";
pub(super) const MACHINE_SIZE: &str = "mila-machine-size";
pub(super) const MACHINE_SHARING: &str = "mila-machine-sharing";
pub(super) const MACHINE_WEB: &str = "mila-machine-web";
pub(super) const THREAD_LIST: &str = "mila-thread-list";
pub(super) const THREAD_DETAIL: &str = "mila-thread-detail";

/// Wire role values in the order the role selector shows them.
const ROLES: [(&str, M); 3] = [
    ("viewer", M::ShareRoleViewer),
    ("operator", M::ShareRoleOperator),
    ("manager", M::ShareRoleManager),
];

fn section(page: &Box, name: &str, title: Option<M>) -> Box {
    let section = Box::new(Orientation::Vertical, 6);
    section.set_widget_name(name);
    if let Some(title) = title {
        section.append(&heading(&strings::text(title)));
    }
    page.append(&section);
    section
}

fn entry(placeholder: M, max: i32) -> Entry {
    Entry::builder()
        .placeholder_text(strings::text(placeholder))
        .max_length(max)
        .hexpand(true)
        .build()
}

/// A title label and a value label on one row.
fn pair(parent: &Box, title: M) -> Label {
    let row = Box::new(Orientation::Horizontal, 8);
    let name = Label::new(Some(&strings::text(title)));
    name.set_halign(Align::Start);
    name.add_css_class("dim-label");
    let value = Label::new(None);
    value.set_halign(Align::Start);
    value.set_selectable(true);
    value.set_wrap(true);
    row.append(&name);
    row.append(&value);
    parent.append(&row);
    value
}

fn line(text: &str) -> Label {
    let label = Label::new(Some(text));
    label.set_halign(Align::Start);
    label.set_wrap(true);
    label
}

/// The catalog word for a machine state; unknown values show as unknown.
pub(super) fn state_message(state: &str) -> M {
    match state {
        "running" => M::StateRunning,
        "stopped" => M::StateStopped,
        "paused" => M::StatePaused,
        "pending" => M::StatePending,
        "failed" => M::StateFailed,
        "deleted" => M::StateDeleted,
        "deleting" => M::StateDeleting,
        "stopping" => M::StateStopping,
        "starting" => M::StateStarting,
        "suspending" => M::StateSuspending,
        "resuming" => M::StateResuming,
        _ => M::StateUnknown,
    }
}

fn thread_status_message(status: &str) -> M {
    match status {
        "ready" => M::ThreadStatusReady,
        "provisioning" => M::ThreadStatusProvisioning,
        "archived" => M::ThreadStatusArchived,
        _ => M::StateUnknown,
    }
}

/// The catalog phrase for a Marshall thread event kind (`Marshall.Agents.Event`).
fn thread_event_message(kind: &str) -> M {
    match kind {
        "prompt" => M::ThreadEventPrompt,
        "assistant" | "model_output" => M::ThreadEventAssistant,
        "turn_started" => M::ThreadEventTurnStarted,
        "turn_finished" => M::ThreadEventTurnFinished,
        "turn_failed" => M::ThreadEventTurnFailed,
        "tool_queued" | "tool_result" => M::ThreadEventTool,
        "child_spawned" => M::ThreadEventChild,
        "waiting_for_vm" => M::ThreadEventWaitingForMachine,
        "questions_requested" => M::ThreadEventQuestions,
        "questions_answered" => M::ThreadEventAnswered,
        "questions_cancelled" => M::ThreadEventQuestionsCancelled,
        "plan_proposed" => M::ThreadEventPlan,
        "context_captured" | "context_compacted" | "maintenance_finished" => {
            M::ThreadEventMaintenance
        }
        _ => M::ThreadEventOther,
    }
}

/// Request-ledger key of a lifecycle action on one machine.
pub(super) fn action_key(action: &str, machine: &str) -> String {
    format!("{action}:{machine}")
}

/// Request-ledger key of a resize; `None` fields keep the current size.
pub(super) fn resize_key(
    machine: &str,
    cpu: Option<u32>,
    memory: Option<u64>,
    disk: Option<u64>,
) -> String {
    format!("resize:{machine}:{cpu:?}:{memory:?}:{disk:?}")
}

/// The message for a finished mutation.
pub(super) fn outcome_message<T>(result: &Option<Result<T, SessionError>>) -> M {
    match result {
        None => M::SignInRequired,
        Some(Ok(_)) => M::RequestSucceeded,
        Some(Err(SessionError::Transport | SessionError::StaleHandle)) => M::RequestWaiting,
        Some(Err(SessionError::Busy)) => M::RequestWaiting,
        Some(Err(_)) => M::RequestRefused,
    }
}

fn machine_id(entry: &Entry) -> Option<String> {
    let id = entry.text().trim().to_owned();
    format_machine_action("show", &id, None).ok().map(|_| id)
}

/// One size field: `Ok(None)` when empty, `Err` when it is not a number.
fn size_field<T: std::str::FromStr>(entry: &Entry) -> Result<Option<T>, ()> {
    let text = entry.text();
    let text = text.trim();
    if text.is_empty() {
        Ok(None)
    } else {
        text.parse().map(Some).map_err(|_| ())
    }
}

/// Size fields for create and resize. Empty fields are `None`: create
/// fills them from [`CREATE_DEFAULTS`], resize keeps the current value.
type SizeFields = (Option<u32>, Option<u64>, Option<u64>);

fn parse_size(cpu: &Entry, memory: &Entry, disk: &Entry) -> Option<SizeFields> {
    Some((
        size_field(cpu).ok()?,
        size_field(memory).ok()?,
        size_field(disk).ok()?,
    ))
}

/// CPU count, memory MiB and disk GiB used when a create field is empty.
const CREATE_DEFAULTS: (u32, u64, u64) = (1, 1024, 10);

/// Builds the Machines page and returns the machine-id entry deep links fill.
pub(super) fn build_machines(state: &NativeState, page: &Box, status: &Label) -> Entry {
    let id = entry(M::MachineId, 64);

    // List.
    let list_section = section(page, MACHINE_LIST, Some(M::Machines));
    let refresh = Button::with_label(&strings::text(M::Refresh));
    let list = ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let list_status = line("");
    list_section.append(&refresh);
    list_section.append(&list_status);
    list_section.append(&list);
    list_section.append(&id);
    {
        let state = state.clone();
        let list = list.clone();
        let list_status = list_status.clone();
        let id = id.clone();
        refresh.connect_clicked(move |_| {
            clear_list(&list);
            let rows = state.with_live(|live| {
                let bytes = live.refresh()?;
                let rows = project_snapshot(&bytes).map_err(|_| SessionError::InvalidInput)?;
                *state.machine_listing.borrow_mut() = Some(rows.clone());
                Ok(rows)
            });
            let rows = match rows {
                None => return list_status.set_label(&strings::text(M::SignInRequired)),
                Some(Err(_)) => return list_status.set_label(&strings::text(M::MachinesFailed)),
                Some(Ok(rows)) => rows,
            };
            list_status.set_label(&if rows.is_empty() {
                strings::text(M::MachinesEmpty)
            } else {
                String::new()
            });
            for row in rows {
                let line_box = Box::new(Orientation::Horizontal, 8);
                let select = Button::with_label(&row.name);
                let observed = row.observed_state.as_deref().unwrap_or("unavailable");
                let state_label = Label::new(Some(&strings::text(if observed == "unavailable" {
                    M::StateUnavailable
                } else {
                    state_message(observed)
                })));
                line_box.append(&select);
                line_box.append(&state_label);
                if row.pinned {
                    line_box.append(&Label::new(Some(&strings::text(M::MachinesPinned))));
                }
                let id = id.clone();
                let machine = row.id.clone();
                select.connect_clicked(move |_| id.set_text(&machine));
                list.append(&line_box);
            }
        });
    }

    // Detail and lifecycle.
    let lifecycle = section(page, MACHINE_LIFECYCLE, None);
    let info = Button::with_label(&strings::text(M::TabInfo));
    lifecycle.append(&info);
    let name_value = pair(&lifecycle, M::MachineName);
    let observed_value = pair(&lifecycle, M::KvState);
    let desired_value = pair(&lifecycle, M::MachineDesired);
    let cpu_value = pair(&lifecycle, M::KvCpu);
    let memory_value = pair(&lifecycle, M::KvMemory);
    let disk_value = pair(&lifecycle, M::KvDisk);
    let show_detail: Rc<dyn Fn()> = {
        let state = state.clone();
        let name_value = name_value.clone();
        let id = id.clone();
        let status = status.clone();
        Rc::new(move || {
            let Some(machine) = machine_id(&id) else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            let detail = state.with_live(|live| {
                let bytes = live.machine_show(&machine)?;
                decode_machine_detail(&bytes).map_err(|_| SessionError::InvalidInput)
            });
            match detail {
                None => status.set_label(&strings::text(M::SignInRequired)),
                Some(Err(_)) => status.set_label(&strings::text(M::MachineNotFound)),
                Some(Ok(detail)) => {
                    name_value.set_label(&detail.name);
                    observed_value.set_label(&strings::text(
                        detail
                            .observed_state
                            .as_deref()
                            .map_or(M::StateUnavailable, state_message),
                    ));
                    desired_value.set_label(&strings::text(state_message(&detail.desired_state)));
                    cpu_value
                        .set_label(&detail.vcpu.map(|cpu| cpu.to_string()).unwrap_or_default());
                    memory_value.set_label(&detail.memory_mib().map_or(String::new(), |mib| {
                        strings::format(M::MemoryMib, &[("mib", &mib.to_string())])
                    }));
                    disk_value.set_label(&detail.disk_gib().map_or(String::new(), |gib| {
                        strings::format(M::DiskGib, &[("gib", &gib.to_string())])
                    }));
                }
            }
        })
    };
    {
        let show_detail = show_detail.clone();
        info.connect_clicked(move |_| show_detail());
    }
    let actions = Box::new(Orientation::Horizontal, 8);
    let (confirm_bar, confirm_button) = ConfirmBar::new();
    for (message, action) in [
        (M::ActionStart, "start"),
        (M::ActionStop, "stop"),
        (M::ActionPause, "pause"),
        (M::ActionResume, "resume"),
        (M::ActionDelete, "rm"),
    ] {
        let button = Button::with_label(&strings::text(message));
        let state = state.clone();
        let id = id.clone();
        let status = status.clone();
        let confirm_bar = confirm_bar.clone();
        let confirm_button = confirm_button.clone();
        let name_value = name_value.clone();
        button.connect_clicked(move |_| {
            let Some(machine) = machine_id(&id) else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            if action == "rm" {
                let name = name_value.text();
                let name = if name.is_empty() {
                    machine.clone()
                } else {
                    name.to_string()
                };
                confirm_bar.ask(
                    &confirm_button,
                    Pending::DeleteMachine(machine),
                    &strings::format(M::ConfirmDelete, &[("name", &name)]),
                    &strings::text(M::ActionDelete),
                );
                return;
            }
            let result = state.mutate(&action_key(action, &machine), |live, request| {
                live.machine_action(&machine, action, request)
            });
            status.set_label(&strings::text(outcome_message(&result)));
        });
        actions.append(&button);
    }
    {
        let state = state.clone();
        let status = status.clone();
        let confirm_bar = confirm_bar.clone();
        confirm_button.connect_clicked(move |_| match confirm_bar.take() {
            Some(Pending::DeleteMachine(machine)) => {
                let result = state.mutate(&action_key("rm", &machine), |live, request| {
                    live.machine_action(&machine, "rm", request)
                });
                status.set_label(&strings::text(outcome_message(&result)));
            }
            Some(Pending::RemoveShare { machine, email }) => {
                let result = state.mutate(
                    &format!("share-remove:{machine}:{email}"),
                    |live, request| live.share_mutation(&machine, &email, None, false, request),
                );
                status.set_label(&strings::text(outcome_message(&result)));
            }
            _ => {}
        });
    }
    lifecycle.append(&actions);
    lifecycle.append(&confirm_bar.container);

    // Create and resize.
    let size = section(page, MACHINE_SIZE, Some(M::ActionNew));
    let name = entry(M::MachineName, 128);
    let cpu = entry(M::KvCpu, 3);
    let memory = entry(M::MemoryFieldMib, 7);
    let disk = entry(M::DiskFieldGib, 5);
    for widget in [&name, &cpu, &memory, &disk] {
        size.append(widget);
    }
    let size_actions = Box::new(Orientation::Horizontal, 8);
    let create = Button::with_label(&strings::text(M::ActionCreate));
    {
        let state = state.clone();
        let status = status.clone();
        let (name, cpu, memory, disk) = (name.clone(), cpu.clone(), memory.clone(), disk.clone());
        create.connect_clicked(move |_| {
            let machine_name = name.text().trim().to_owned();
            let Some((cpu, memory, disk)) = parse_size(&cpu, &memory, &disk) else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            let cpu = cpu.unwrap_or(CREATE_DEFAULTS.0);
            let memory = memory.unwrap_or(CREATE_DEFAULTS.1);
            let disk = disk.unwrap_or(CREATE_DEFAULTS.2);
            let key = format!("new:{machine_name}:{cpu}:{memory}:{disk}");
            let result = state.mutate(&key, |live, request| {
                live.machine_create(&machine_name, cpu, memory, disk, request)
            });
            status.set_label(&strings::text(match &result {
                Some(Err(SessionError::InvalidInput)) if machine_name.is_empty() => {
                    M::MachineFieldInvalid
                }
                _ => outcome_message(&result),
            }));
        });
    }
    let resize = Button::with_label(&strings::text(M::ActionResize));
    {
        let state = state.clone();
        let status = status.clone();
        let id = id.clone();
        let (cpu, memory, disk) = (cpu.clone(), memory.clone(), disk.clone());
        resize.connect_clicked(move |_| {
            let (Some(machine), Some((cpu, memory, disk))) =
                (machine_id(&id), parse_size(&cpu, &memory, &disk))
            else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            let key = resize_key(&machine, cpu, memory, disk);
            let result = state.mutate(&key, |live, request| {
                // Empty fields keep the machine's current size, read now
                // rather than from a possibly stale detail view.
                let current = if cpu.is_some() && memory.is_some() && disk.is_some() {
                    None
                } else {
                    let bytes = live.machine_show(&machine)?;
                    Some(decode_machine_detail(&bytes).map_err(|_| SessionError::InvalidInput)?)
                };
                let keep = |value: Option<u64>| value.ok_or(SessionError::InvalidInput);
                let cpu = match cpu {
                    Some(cpu) => cpu,
                    None => current
                        .as_ref()
                        .and_then(|detail| detail.vcpu)
                        .ok_or(SessionError::InvalidInput)?,
                };
                let memory = match memory {
                    Some(memory) => memory,
                    None => keep(current.as_ref().and_then(|detail| detail.memory_mib()))?,
                };
                let disk = match disk {
                    Some(disk) => disk,
                    None => keep(current.as_ref().and_then(|detail| detail.disk_gib()))?,
                };
                live.machine_resize(&machine, cpu, memory, disk, request)
            });
            status.set_label(&strings::text(outcome_message(&result)));
        });
    }
    size_actions.append(&create);
    size_actions.append(&resize);
    size.append(&size_actions);
    size.append(&line(&strings::text(M::ResizeExplain)));

    // Sharing.
    let sharing = section(page, MACHINE_SHARING, Some(M::SharingTitle));
    let email = entry(M::SharingEmail, 320);
    let role_names = ROLES.map(|(_, message)| strings::text(message));
    let role = DropDown::from_strings(&role_names.iter().map(String::as_str).collect::<Vec<_>>());
    let share_actions = Box::new(Orientation::Horizontal, 8);
    let share_refresh = Button::with_label(&strings::text(M::Refresh));
    let share_add = Button::with_label(&strings::text(M::SharingAdd));
    let share_remove = Button::with_label(&strings::text(M::SharingRemove));
    let grants = ListBox::new();
    grants.set_selection_mode(gtk::SelectionMode::None);
    let grants_status = line("");
    {
        let state = state.clone();
        let id = id.clone();
        let grants = grants.clone();
        let grants_status = grants_status.clone();
        share_refresh.connect_clicked(move |_| {
            clear_list(&grants);
            let Some(machine) = machine_id(&id) else {
                return grants_status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            let listing = state.with_live(|live| {
                let bytes = live.share_show(&machine)?;
                decode_share_listing(&bytes).map_err(|_| SessionError::InvalidInput)
            });
            let (owner, items) = match listing {
                None => return grants_status.set_label(&strings::text(M::SignInRequired)),
                Some(Err(_)) => return grants_status.set_label(&strings::text(M::SharingFailed)),
                Some(Ok(listing)) => listing,
            };
            grants_status.set_label(&if items.is_empty() {
                strings::text(M::SharingEmpty)
            } else {
                String::new()
            });
            let row = |who: &str, role: M| {
                let line_box = Box::new(Orientation::Horizontal, 8);
                line_box.append(&Label::new(Some(who)));
                line_box.append(&Label::new(Some(&strings::text(role))));
                grants.append(&line_box);
            };
            row(&owner, M::ShareRoleOwner);
            for grant in items {
                let role = ROLES
                    .iter()
                    .find(|(wire, _)| *wire == grant.role)
                    .map_or(M::StateUnknown, |(_, message)| *message);
                row(&grant.email, role);
            }
        });
    }
    {
        let state = state.clone();
        let id = id.clone();
        let email = email.clone();
        let role = role.clone();
        let status = status.clone();
        share_add.connect_clicked(move |_| {
            let address = email.text().trim().to_owned();
            let Some(machine) = machine_id(&id) else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            if !address.contains('@') {
                return status.set_label(&strings::text(M::SharingEmailInvalid));
            }
            let Some((wire, _)) = ROLES.get(role.selected() as usize) else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            let key = format!("share-add:{machine}:{address}:{wire}");
            let result = state.mutate(&key, |live, request| {
                live.share_mutation(&machine, &address, Some(wire), true, request)
            });
            status.set_label(&strings::text(outcome_message(&result)));
        });
    }
    {
        let id = id.clone();
        let email = email.clone();
        let status = status.clone();
        let confirm_bar = confirm_bar.clone();
        let confirm_button = confirm_button.clone();
        share_remove.connect_clicked(move |_| {
            let address = email.text().trim().to_owned();
            let Some(machine) = machine_id(&id) else {
                return status.set_label(&strings::text(M::MachineFieldInvalid));
            };
            if !address.contains('@') {
                return status.set_label(&strings::text(M::SharingEmailInvalid));
            }
            confirm_bar.ask(
                &confirm_button,
                Pending::RemoveShare {
                    machine,
                    email: address.clone(),
                },
                &strings::format(M::SharingRemoveConfirm, &[("email", &address)]),
                &strings::text(M::SharingRemove),
            );
        });
    }
    share_actions.append(&share_refresh);
    share_actions.append(&share_add);
    share_actions.append(&share_remove);
    sharing.append(&email);
    sharing.append(&role);
    sharing.append(&share_actions);
    sharing.append(&grants_status);
    sharing.append(&grants);

    // Web endpoint.
    let web = section(page, MACHINE_WEB, Some(M::TabWeb));
    let web_refresh = Button::with_label(&strings::text(M::Refresh));
    let visibility_value = pair(&web, M::WebVisibility);
    let port_value = pair(&web, M::WebPort);
    let address_value = pair(&web, M::WebAddress);
    let port = entry(M::WebPort, 5);
    let web_actions = Box::new(Orientation::Horizontal, 8);
    let endpoint: Rc<RefCell<Option<WebEndpoint>>> = Rc::new(RefCell::new(None));
    let load_web: Rc<dyn Fn() -> bool> = {
        let state = state.clone();
        let id = id.clone();
        let status = status.clone();
        let endpoint = endpoint.clone();
        let port = port.clone();
        Rc::new(move || {
            endpoint.borrow_mut().take();
            let Some(machine) = machine_id(&id) else {
                status.set_label(&strings::text(M::MachineFieldInvalid));
                return false;
            };
            let loaded = state.with_live(|live| {
                let bytes = live.web_show(&machine)?;
                decode_web_endpoint(&bytes).map_err(|_| SessionError::InvalidInput)
            });
            match loaded {
                None => status.set_label(&strings::text(M::SignInRequired)),
                Some(Err(_)) => status.set_label(&strings::text(M::WebFailed)),
                Some(Ok(loaded)) => {
                    visibility_value.set_label(&strings::text(if loaded.visibility == "public" {
                        M::WebPublic
                    } else {
                        M::WebPrivate
                    }));
                    port_value.set_label(&loaded.port.to_string());
                    port.set_text(&loaded.port.to_string());
                    address_value.set_label(&loaded.url.clone().unwrap_or_else(|| {
                        strings::text(if loaded.visibility == "public" {
                            M::WebNoAddress
                        } else {
                            M::WebPrivateExplain
                        })
                    }));
                    *endpoint.borrow_mut() = Some(loaded);
                    return true;
                }
            }
            false
        })
    };
    {
        let load_web = load_web.clone();
        web_refresh.connect_clicked(move |_| {
            load_web();
        });
    }
    for (message, public) in [(M::WebPublic, true), (M::WebPrivate, false)] {
        let button = Button::with_label(&strings::text(message));
        let state = state.clone();
        let status = status.clone();
        let endpoint = endpoint.clone();
        let port = port.clone();
        let load_web = load_web.clone();
        button.connect_clicked(move |_| {
            let Some(current) = endpoint.borrow().clone() else {
                return status.set_label(&strings::text(M::WebFailed));
            };
            let Some(target_port) = port.text().trim().parse::<u16>().ok().filter(|p| *p > 0)
            else {
                return status.set_label(&strings::text(M::WebPortInvalid));
            };
            let key = format!(
                "web:{}:{target_port}:{public}:{}",
                current.machine_id, current.policy_revision
            );
            let result = state.mutate(&key, |live, request| {
                live.web_set(
                    &current.machine_id,
                    target_port,
                    public,
                    current.policy_revision,
                    request,
                )
            });
            let refused = matches!(result, Some(Err(SessionError::InvalidInput)));
            // Any change invalidates the loaded endpoint; reload it so the
            // page shows the deployment's current revision and visibility.
            load_web();
            status.set_label(&strings::text(if refused {
                M::WebConflict
            } else {
                outcome_message(&result)
            }));
        });
        web_actions.append(&button);
    }
    let web_open = Button::with_label(&strings::text(M::WebOpen));
    {
        let state = state.clone();
        let endpoint = endpoint.clone();
        let status = status.clone();
        web_open.connect_clicked(move |_| {
            if !state.session.borrow().is_authenticated() {
                endpoint.borrow_mut().take();
                return status.set_label(&strings::text(M::SignInRequired));
            }
            let current = endpoint.borrow().clone();
            match current.as_ref().and_then(browser_endpoint_url) {
                // decode_web_endpoint already required HTTPS on the endpoint's
                // port and the canonical machine route.
                Some(url) => {
                    if gio::AppInfo::launch_default_for_uri(url, None::<&gio::AppLaunchContext>)
                        .is_err()
                    {
                        status.set_label(&strings::text(M::WebFailed));
                    }
                }
                None => status.set_label(&strings::text(M::WebNoAddress)),
            }
        });
    }
    web_actions.append(&web_refresh);
    web_actions.append(&web_open);
    web.append(&port);
    web.append(&web_actions);

    let link_entry = id.clone();
    page.append(&views::copy_link_button(state, status, move || {
        views::machine_target(&link_entry)
    }));
    id
}

/// Builds the Threads page and returns the thread-id entry deep links fill.
pub(super) fn build_threads(state: &NativeState, page: &Box, status: &Label) -> Entry {
    let id = entry(M::MachineId, 128);
    let list_section = section(page, THREAD_LIST, Some(M::Threads));
    let refresh = Button::with_label(&strings::text(M::Refresh));
    let list = ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let list_status = line("");
    list_section.append(&refresh);
    list_section.append(&list_status);
    list_section.append(&list);
    list_section.append(&id);

    let detail_section = section(page, THREAD_DETAIL, None);
    let info = Button::with_label(&strings::text(M::TabInfo));
    detail_section.append(&info);
    let title_value = heading("");
    let mode_value = line("");
    detail_section.append(&title_value);
    detail_section.append(&mode_value);
    let question_title = line(&strings::text(M::ThreadQuestionTitle));
    let plan_title = line(&strings::text(M::ThreadPlanTitle));
    let plan_text = line("");
    let events = ListBox::new();
    events.set_selection_mode(gtk::SelectionMode::None);
    let detail: Rc<RefCell<Option<ThreadDetail>>> = Rc::new(RefCell::new(None));

    let load: Rc<dyn Fn()> = {
        let state = state.clone();
        let id = id.clone();
        let status = status.clone();
        let detail = detail.clone();
        let question_title = question_title.clone();
        let plan_title = plan_title.clone();
        let plan_text = plan_text.clone();
        let events = events.clone();
        Rc::new(move || {
            detail.borrow_mut().take();
            clear_list(&events);
            question_title.set_visible(false);
            plan_title.set_visible(false);
            plan_text.set_visible(false);
            let thread = id.text().trim().to_owned();
            let loaded = state.with_live(|live| {
                let shown = live.thread_action(Some(&thread), "thread show", None, None, None)?;
                let shown = decode_thread_detail(&shown).map_err(|_| SessionError::InvalidInput)?;
                let turns = live.thread_action(Some(&thread), "thread turns", None, None, None)?;
                let turns = decode_thread_events(&turns).map_err(|_| SessionError::InvalidInput)?;
                Ok((shown, turns))
            });
            let (shown, turns) = match loaded {
                None => return status.set_label(&strings::text(M::SignInRequired)),
                Some(Err(_)) => return status.set_label(&strings::text(M::ThreadFailed)),
                Some(Ok(loaded)) => loaded,
            };
            title_value.set_label(
                &shown
                    .title
                    .clone()
                    .unwrap_or_else(|| strings::text(M::ThreadUntitled)),
            );
            mode_value.set_label(&strings::text(if shown.busy {
                M::ThreadWorking
            } else if shown.collaboration_mode.as_deref() == Some("plan") {
                M::ThreadModePlan
            } else {
                M::ThreadModeWork
            }));
            question_title.set_visible(shown.pending_question.is_some());
            if let Some(plan) = shown.open_plan() {
                plan_title.set_visible(true);
                plan_text.set_visible(true);
                let text = plan.text.clone().unwrap_or_default();
                plan_text.set_label(
                    &text
                        .chars()
                        .filter(|character| {
                            (*character == '\n' || !character.is_control())
                                && !matches!(
                                    character,
                                    '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
                                )
                        })
                        .collect::<String>(),
                );
            }
            if turns.is_empty() {
                events.append(&line(&strings::text(M::ThreadNoTurns)));
            }
            for event in turns {
                events.append(&line(&strings::text(thread_event_message(&event.kind))));
            }
            *detail.borrow_mut() = Some(shown);
        })
    };
    {
        let load = load.clone();
        info.connect_clicked(move |_| load());
    }
    {
        let state = state.clone();
        let list = list.clone();
        let list_status = list_status.clone();
        let id = id.clone();
        let load = load.clone();
        refresh.connect_clicked(move |_| {
            clear_list(&list);
            let rows = state.with_live(|live| {
                let bytes = live.thread_action(None, "thread ls", None, None, None)?;
                decode_thread_rows(&bytes).map_err(|_| SessionError::InvalidInput)
            });
            let rows = match rows {
                None => return list_status.set_label(&strings::text(M::SignInRequired)),
                Some(Err(_)) => return list_status.set_label(&strings::text(M::ThreadsFailed)),
                Some(Ok(rows)) => rows,
            };
            list_status.set_label(&if rows.is_empty() {
                strings::text(M::ThreadsEmpty)
            } else {
                String::new()
            });
            for row in rows {
                let line_box = Box::new(Orientation::Horizontal, 8);
                let select = Button::with_label(
                    &row.title
                        .clone()
                        .unwrap_or_else(|| strings::text(M::ThreadUntitled)),
                );
                line_box.append(&select);
                if let Some(status) = row.status.as_deref() {
                    line_box.append(&Label::new(Some(&strings::text(thread_status_message(
                        status,
                    )))));
                }
                let id = id.clone();
                let load = load.clone();
                let thread = row.id.clone();
                select.connect_clicked(move |_| {
                    id.set_text(&thread);
                    load();
                });
                list.append(&line_box);
            }
        });
    }

    // Composer, answer and plan controls act on the loaded thread.
    let composer = entry(M::ThreadComposerHint, i32::from(u16::MAX));
    let send = Button::with_label(&strings::text(M::ThreadSend));
    let answer = entry(M::ThreadAnswerHint, i32::from(u16::MAX));
    let answer_send = Button::with_label(&strings::text(M::ThreadAnswerSend));
    let revision = entry(M::ThreadPlanRevisionHint, i32::from(u16::MAX));
    let approve = Button::with_label(&strings::text(M::ThreadPlanApprove));
    let revise = Button::with_label(&strings::text(M::ThreadPlanRevise));
    #[derive(Clone, Copy)]
    enum Kind {
        Prompt,
        Answer,
        Approve,
        Revise,
    }
    for (button, kind, input) in [
        (&send, Kind::Prompt, Some(composer.clone())),
        (&answer_send, Kind::Answer, Some(answer.clone())),
        (&approve, Kind::Approve, None),
        (&revise, Kind::Revise, Some(revision.clone())),
    ] {
        let state = state.clone();
        let status = status.clone();
        let detail = detail.clone();
        let load = load.clone();
        button.connect_clicked(move |_| {
            let Some(shown) = detail.borrow().clone() else {
                return status.set_label(&strings::text(M::ThreadFailed));
            };
            if shown.busy && matches!(kind, Kind::Prompt) {
                return status.set_label(&strings::text(M::ThreadBusy));
            }
            let text = input.as_ref().map(|entry| entry.text().to_string());
            if let Some(text) = text.as_deref() {
                if text.trim().is_empty() || text.contains('\0') {
                    return status.set_label(&strings::text(M::ThreadTextInvalid));
                }
                if text.len() > 64 * 1024 {
                    return status.set_label(&strings::text(M::ThreadTextTooLarge));
                }
            }
            let (command, secondary) = match kind {
                Kind::Prompt => ("thread prompt", None),
                Kind::Answer => (
                    "thread answer",
                    shown
                        .pending_question
                        .as_ref()
                        .map(|question| question.id.clone()),
                ),
                Kind::Approve => (
                    "thread plan approve",
                    shown.open_plan().map(|plan| plan.id.clone()),
                ),
                Kind::Revise => (
                    "thread plan revise",
                    shown.open_plan().map(|plan| plan.id.clone()),
                ),
            };
            if !matches!(kind, Kind::Prompt) && secondary.is_none() {
                return status.set_label(&strings::text(M::ThreadFailed));
            }
            // The key distinguishes texts by an in-memory digest so a retry
            // reuses the id only for the same text; the text is not retained.
            let digest = text.as_deref().map_or(0, |text| {
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                text.hash(&mut hasher);
                hasher.finish()
            });
            let key = format!(
                "{command}:{}:{}:{digest:016x}",
                shown.id,
                secondary.as_deref().unwrap_or_default(),
            );
            let result = state.mutate(&key, |live, request| {
                live.thread_action(
                    Some(&shown.id),
                    command,
                    secondary.as_deref(),
                    text.as_deref(),
                    Some(request),
                )
            });
            status.set_label(&strings::text(outcome_message(&result)));
            if matches!(result, Some(Ok(_))) {
                if let Some(entry) = input.as_ref() {
                    entry.set_text("");
                }
                load();
            }
        });
    }
    for widget in [
        composer.upcast_ref::<gtk::Widget>(),
        send.upcast_ref(),
        question_title.upcast_ref(),
        answer.upcast_ref(),
        answer_send.upcast_ref(),
        plan_title.upcast_ref(),
        plan_text.upcast_ref(),
        revision.upcast_ref(),
        approve.upcast_ref(),
        revise.upcast_ref(),
        events.upcast_ref(),
    ] {
        detail_section.append(widget);
    }
    question_title.set_visible(false);
    plan_title.set_visible(false);
    plan_text.set_visible(false);

    let link_entry = id.clone();
    page.append(&views::copy_link_button(state, status, move || {
        views::thread_target(&link_entry)
    }));
    id
}
