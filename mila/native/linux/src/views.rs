//! GTK bindings for the deployment list, terminal surface, SSH-key settings
//! and deep-link/share pages.
//!
//! Every decision is delegated to the GTK-independent library modules
//! (`deployments`, `terminal_surface`, `ssh_keys_view`, `deep_link`, `route`);
//! these functions only build widgets, copy typed projections into them and
//! forward user actions.

use super::{strings, NativeState};
use gtk::prelude::*;
use gtk::{gdk, glib, Align, Box, Button, Entry, Label, ListBox, Orientation, TextView};
use mila_native_linux::deep_link::{present, LinkNotice, Page};
use mila_native_linux::route::{share_inbound, share_route, ActivationBatch, MachinePage, Target};
use mila_native_linux::session::{ApprovalInfo, SignInFailure, SignInPhase};
use mila_native_linux::session::{LiveSession, SessionPtyBackend};
use mila_native_linux::ssh_keys_view::{RevokeOutcome, SshKeySource, SshKeysStatus};
use mila_native_linux::terminal::{HostPtyTransport, PtyError};
use mila_native_linux::terminal_surface::{TerminalSurface, TickOutcome};
use mila_native_linux::terminal_text::TerminalKey;
use std::{cell::RefCell, rc::Rc, time::Duration};

/// The GTK terminal surface: authority is the window's session binding and
/// the transport is the authenticated FFI PTY behind `HostPtyTransport`.
pub(super) type GtkTerminal = TerminalSurface<
    Rc<RefCell<mila_native_linux::session::SessionBinding>>,
    HostPtyTransport<SessionPtyBackend>,
>;

/// Main-loop interval between terminal reads; each read is non-blocking.
const TERMINAL_FRAME: Duration = Duration::from_millis(33);

/// Widgets a deep link may select or pre-fill.
#[derive(Clone)]
pub(super) struct LinkTargets {
    pub(super) stack: gtk::Stack,
    pub(super) deployment: Entry,
    pub(super) machine: Entry,
    pub(super) terminal_session: Entry,
    pub(super) thread: Entry,
}

/// A destructive action awaiting explicit confirmation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum Pending {
    RemoveDeployment(String),
    RevokeKey(String),
    DeleteMachine(String),
    RemoveShare { machine: String, email: String },
}

/// One confirmation bar shared by the settings pages.
#[derive(Clone)]
pub(super) struct ConfirmBar {
    pub(super) container: Box,
    prompt: Label,
    pending: Rc<RefCell<Option<Pending>>>,
}

impl ConfirmBar {
    pub(super) fn new() -> (Self, Button) {
        let container = Box::new(Orientation::Horizontal, 8);
        let prompt = Label::new(None);
        prompt.set_wrap(true);
        prompt.set_hexpand(true);
        prompt.set_halign(Align::Start);
        let confirm = Button::new();
        let cancel = Button::with_label(&strings::text(strings::Message::Cancel));
        container.append(&prompt);
        container.append(&confirm);
        container.append(&cancel);
        container.set_visible(false);
        let bar = Self {
            container,
            prompt,
            pending: Rc::new(RefCell::new(None)),
        };
        let cancelled = bar.clone();
        cancel.connect_clicked(move |_| cancelled.clear());
        (bar, confirm)
    }

    pub(super) fn ask(&self, confirm: &Button, pending: Pending, prompt: &str, action: &str) {
        self.prompt.set_label(prompt);
        confirm.set_label(action);
        *self.pending.borrow_mut() = Some(pending);
        self.container.set_visible(true);
    }

    pub(super) fn take(&self) -> Option<Pending> {
        let pending = self.pending.borrow_mut().take();
        self.container.set_visible(false);
        pending
    }

    fn clear(&self) {
        let _ = self.take();
    }
}

pub(super) fn clear_list(list: &ListBox) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
}

pub(super) fn heading(text: &str) -> Label {
    let label = Label::new(Some(text));
    label.set_halign(Align::Start);
    label.add_css_class("title-3");
    label
}

/// Deployment list with Add, Open and confirmed Remove.
#[expect(
    clippy::too_many_lines,
    reason = "linear GTK page construction; ADR-0265 keeps mila-linux lint-only, so splitting is deferred"
)]
pub(super) fn build_deployments(
    state: &NativeState,
    page: &Box,
    deployment: &Entry,
    status: &Label,
) -> Rc<dyn Fn()> {
    page.append(&heading(&strings::text(strings::Message::DeploymentsTitle)));
    let (confirm_bar, confirm_button) = ConfirmBar::new();
    let list = ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let render: super::RenderSlot = Rc::new(RefCell::new(None));

    let render_impl = {
        let state = state.clone();
        let list = list.clone();
        let deployment = deployment.clone();
        let status = status.clone();
        let confirm_bar = confirm_bar.clone();
        let confirm_button = confirm_button.clone();
        let render = render.clone();
        Rc::new(move || {
            clear_list(&list);
            let rows = state
                .deployment_list()
                .map(|list| list.rows())
                .unwrap_or_default();
            if rows.is_empty() {
                list.append(&Label::new(Some(&strings::text(
                    strings::Message::DeploymentsEmpty,
                ))));
            }
            for row in rows {
                let line = Box::new(Orientation::Horizontal, 8);
                let host = Label::new(Some(&row.host));
                host.set_hexpand(true);
                host.set_halign(Align::Start);
                line.append(&host);
                if row.selected {
                    line.append(&Label::new(Some(&strings::text(
                        strings::Message::DeploymentSelected,
                    ))));
                }
                let open = Button::with_label(&strings::text(strings::Message::DeploymentOpen));
                let remove = Button::with_label(&strings::text(strings::Message::DeploymentRemove));
                {
                    let state = state.clone();
                    let host = row.host.clone();
                    let deployment = deployment.clone();
                    let status = status.clone();
                    let render = render.clone();
                    open.connect_clicked(move |_| {
                        match state.update_deployments(|list| list.select(&host)) {
                            Ok(changed) => {
                                if changed {
                                    state.drop_authority();
                                }
                                deployment.set_text(&host);
                                state.show_page(Page::Machines);
                                status.set_label(&strings::text(
                                    strings::Message::SignInDeploymentRequired,
                                ));
                            }
                            Err(_) => status.set_label(&strings::text(
                                strings::Message::DeploymentForgetFailed,
                            )),
                        }
                        if let Some(render) = render.borrow().as_ref() {
                            render();
                        }
                    });
                }
                {
                    let host = row.host.clone();
                    let confirm_bar = confirm_bar.clone();
                    let confirm_button = confirm_button.clone();
                    remove.connect_clicked(move |_| {
                        confirm_bar.ask(
                            &confirm_button,
                            Pending::RemoveDeployment(host.clone()),
                            &strings::format(
                                strings::Message::DeploymentRemoveConfirm,
                                &[("host", &host)],
                            ),
                            &strings::text(strings::Message::DeploymentRemove),
                        );
                    });
                }
                line.append(&open);
                line.append(&remove);
                list.append(&line);
            }
        })
    };
    *render.borrow_mut() = Some(render_impl.clone());

    {
        let state = state.clone();
        let deployment = deployment.clone();
        let status = status.clone();
        let render = render_impl.clone();
        let confirm_bar = confirm_bar.clone();
        confirm_button.connect_clicked(move |_| {
            let Some(Pending::RemoveDeployment(host)) = confirm_bar.take() else {
                return;
            };
            match state.update_deployments(|list| Ok(list.forget(&host))) {
                Ok(outcome) => {
                    if outcome.was_selected {
                        state.drop_authority();
                        deployment.set_text("");
                    }
                    status.set_label(&strings::text(strings::Message::DeploymentForgotten));
                }
                Err(_) => {
                    status.set_label(&strings::text(strings::Message::DeploymentForgetFailed));
                }
            }
            render();
        });
    }

    let add = Button::with_label(&strings::text(strings::Message::DeploymentAddAndSelect));
    {
        let state = state.clone();
        let deployment = deployment.clone();
        let status = status.clone();
        let render = render_impl.clone();
        add.connect_clicked(move |_| {
            let host = deployment.text().trim().to_owned();
            match state.update_deployments(|list| {
                let canonical = list.add(&host)?;
                let changed = list.select(canonical.as_str())?;
                Ok((canonical, changed))
            }) {
                Ok((canonical, changed)) => {
                    if changed {
                        state.drop_authority();
                    }
                    deployment.set_text(canonical.as_str());
                    status.set_label(&strings::text(strings::Message::SignInDeploymentRequired));
                }
                Err(_) => status.set_label(&strings::text(strings::Message::DeploymentHostInvalid)),
            }
            render();
        });
    }
    page.append(deployment);
    page.append(&add);
    page.append(&list);
    page.append(&confirm_bar.container);
    render_impl();
    render_impl
}

fn terminal_error(error: PtyError) -> strings::Message {
    match error {
        PtyError::Unauthenticated => strings::Message::TerminalSignedOut,
        PtyError::Transport => strings::Message::TerminalUnreachable,
        PtyError::InvalidRequest | PtyError::Render => strings::Message::TerminalInvalid,
    }
}

fn key_for(key: gdk::Key, modifiers: gdk::ModifierType) -> Option<TerminalKey> {
    let named = match key {
        gdk::Key::Return | gdk::Key::KP_Enter => Some(TerminalKey::Enter),
        gdk::Key::BackSpace => Some(TerminalKey::Backspace),
        gdk::Key::Tab => Some(TerminalKey::Tab),
        gdk::Key::Escape => Some(TerminalKey::Escape),
        gdk::Key::Up => Some(TerminalKey::Up),
        gdk::Key::Down => Some(TerminalKey::Down),
        gdk::Key::Left => Some(TerminalKey::Left),
        gdk::Key::Right => Some(TerminalKey::Right),
        gdk::Key::Home => Some(TerminalKey::Home),
        gdk::Key::End => Some(TerminalKey::End),
        gdk::Key::Delete => Some(TerminalKey::Delete),
        gdk::Key::Page_Up => Some(TerminalKey::PageUp),
        gdk::Key::Page_Down => Some(TerminalKey::PageDown),
        _ => None,
    };
    named.or_else(|| {
        let character = key.to_unicode()?;
        if modifiers.contains(gdk::ModifierType::CONTROL_MASK) {
            Some(TerminalKey::Control(character))
        } else {
            Some(TerminalKey::Text(character))
        }
    })
}

/// Installs the frame timer once; it removes itself when the surface stops.
fn start_polling(state: &NativeState, view: &TextView, status: &Label) {
    if state.terminal_polling.replace(true) {
        return;
    }
    let state = state.clone();
    let view = view.clone();
    let status = status.clone();
    glib::timeout_add_local(TERMINAL_FRAME, move || {
        let outcome = state
            .terminal
            .borrow_mut()
            .as_mut()
            .map_or(TickOutcome::Detached, TerminalSurface::tick);
        if outcome == TickOutcome::Updated {
            if let Some(surface) = state.terminal.borrow().as_ref() {
                view.buffer().set_text(&surface.text());
            }
        }
        match outcome {
            TickOutcome::Ended => status.set_label(&strings::text(strings::Message::TerminalEnded)),
            TickOutcome::Failed(error) => {
                status.set_label(&strings::text(terminal_error(error)));
                // A transport failure means the session itself is gone:
                // release it and reconnect now rather than at the heartbeat.
                if error == PtyError::Transport {
                    state.session_lost();
                }
            }
            _ => {}
        }
        if outcome.keeps_polling() {
            glib::ControlFlow::Continue
        } else {
            state.terminal_polling.set(false);
            glib::ControlFlow::Break
        }
    });
}

fn parse_dimensions(columns: &Entry, rows: &Entry) -> Option<(u16, u16)> {
    columns
        .text()
        .trim()
        .parse::<u16>()
        .ok()
        .zip(rows.text().trim().parse::<u16>().ok())
}

/// Terminal page: text view bound to the surface viewport plus lifecycle
/// controls. Returns the session-id entry for deep-link pre-fill.
/// `machine` is the Machines page's machine-id entry; the terminal attaches
/// to a session of that machine.
#[expect(
    clippy::too_many_lines,
    reason = "linear GTK page construction; ADR-0265 keeps mila-linux lint-only, so splitting is deferred"
)]
pub(super) fn build_terminal(
    state: &NativeState,
    page: &Box,
    machine: &Entry,
    status: &Label,
) -> Entry {
    page.append(&heading(&strings::text(strings::Message::TerminalsTitle)));
    let session = Entry::builder()
        .placeholder_text("Terminal session ID")
        .max_length(128)
        .hexpand(true)
        .build();
    let columns = Entry::builder().text("80").max_length(4).build();
    let rows = Entry::builder().text("24").max_length(3).build();
    let input = Entry::builder()
        .placeholder_text("Terminal input")
        .hexpand(true)
        .build();
    let view = TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .focusable(true)
        .wrap_mode(gtk::WrapMode::None)
        .build();
    let scroller = gtk::ScrolledWindow::builder()
        .child(&view)
        .min_content_height(320)
        .vexpand(true)
        .build();

    let keys = gtk::EventControllerKey::new();
    {
        let state = state.clone();
        let status = status.clone();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            let Some(key) = key_for(key, modifiers) else {
                return glib::Propagation::Proceed;
            };
            let mut terminal = state.terminal.borrow_mut();
            let Some(surface) = terminal
                .as_mut()
                .filter(|surface| surface.live_generation().is_some())
            else {
                return glib::Propagation::Proceed;
            };
            if let Err(error) = surface.send_key(key) {
                status.set_label(&strings::text(terminal_error(error)));
            }
            glib::Propagation::Stop
        });
    }
    view.add_controller(keys);

    let actions = Box::new(Orientation::Horizontal, 8);
    let attach = Button::with_label(&strings::text(strings::Message::AttachTerminal));
    {
        let state = state.clone();
        let session = session.clone();
        let machine = machine.clone();
        let columns = columns.clone();
        let rows = rows.clone();
        let view = view.clone();
        let status = status.clone();
        attach.connect_clicked(move |_| {
            let Some((width, height)) = parse_dimensions(&columns, &rows) else {
                status.set_label(&strings::text(strings::Message::TerminalInvalid));
                return;
            };
            let machine_id = machine.text().trim().to_owned();
            if machine_id.is_empty() {
                status.set_label(&strings::text(strings::Message::MachineFieldInvalid));
                return;
            }
            // An empty session id opens or rejoins this account's own session.
            let id = session.text().trim().to_owned();
            let result = {
                let mut terminal = state.terminal.borrow_mut();
                if terminal
                    .as_ref()
                    .is_some_and(|surface| surface.live_generation().is_none())
                {
                    // A finished surface may be bound to another session id.
                    *terminal = None;
                }
                if terminal.is_none() {
                    let backend = SessionPtyBackend::new(state.session.clone(), 0);
                    *terminal = TerminalSurface::new(
                        state.session.clone(),
                        HostPtyTransport::new(backend),
                        width,
                        height,
                    )
                    .ok();
                }
                terminal
                    .as_mut()
                    .ok_or(PtyError::InvalidRequest)
                    .and_then(|surface| surface.attach(&machine_id, &id, width, height))
            };
            match result {
                Ok(_) => {
                    view.buffer().set_text("");
                    status.set_label(&strings::text(strings::Message::TerminalLive));
                    view.grab_focus();
                    start_polling(&state, &view, &status);
                }
                Err(error) => {
                    // A closed server refusal (for example no guest to attach
                    // to) is the deployment's answer, not a local failure.
                    let refused = state
                        .session
                        .borrow()
                        .session()
                        .and_then(LiveSession::last_refusal)
                        .is_some();
                    status.set_label(&strings::text(if refused {
                        strings::Message::TerminalRefused
                    } else {
                        terminal_error(error)
                    }));
                }
            }
        });
    }
    let send = Button::with_label(&strings::text(strings::Message::TerminalSend));
    {
        let state = state.clone();
        let input = input.clone();
        let status = status.clone();
        send.connect_clicked(move |_| {
            let mut line = input.text().to_string();
            line.push('\r');
            let result = state
                .terminal
                .borrow_mut()
                .as_mut()
                .ok_or(PtyError::InvalidRequest)
                .and_then(|surface| surface.send(line.as_bytes()));
            match result {
                Ok(()) => input.set_text(""),
                Err(error) => status.set_label(&strings::text(terminal_error(error))),
            }
        });
    }
    let reconnect = Button::with_label(&strings::text(strings::Message::TerminalReconnect));
    {
        let state = state.clone();
        let view = view.clone();
        let status = status.clone();
        reconnect.connect_clicked(move |_| {
            let result = state
                .terminal
                .borrow_mut()
                .as_mut()
                .ok_or(PtyError::InvalidRequest)
                .and_then(TerminalSurface::reconnect);
            match result {
                Ok(_) => {
                    status.set_label(&strings::text(strings::Message::TerminalLive));
                    start_polling(&state, &view, &status);
                }
                Err(error) => status.set_label(&strings::text(terminal_error(error))),
            }
        });
    }
    let resize = Button::with_label(&strings::text(strings::Message::TerminalResize));
    {
        let state = state.clone();
        let columns = columns.clone();
        let rows = rows.clone();
        let status = status.clone();
        resize.connect_clicked(move |_| {
            let result = parse_dimensions(&columns, &rows)
                .ok_or(PtyError::InvalidRequest)
                .and_then(|(width, height)| {
                    state
                        .terminal
                        .borrow_mut()
                        .as_mut()
                        .ok_or(PtyError::InvalidRequest)
                        .and_then(|surface| surface.resize(width, height))
                });
            if let Err(error) = result {
                status.set_label(&strings::text(terminal_error(error)));
            }
        });
    }
    let close = Button::with_label(&strings::text(strings::Message::TerminalClose));
    {
        let state = state.clone();
        let status = status.clone();
        close.connect_clicked(move |_| {
            let result = state
                .terminal
                .borrow_mut()
                .as_mut()
                .ok_or(PtyError::InvalidRequest)
                .and_then(TerminalSurface::kill);
            match result {
                Ok(()) => status.set_label(&strings::text(strings::Message::TerminalEnded)),
                Err(error) => status.set_label(&strings::text(terminal_error(error))),
            }
        });
    }
    for button in [&attach, &send, &reconnect, &resize, &close] {
        actions.append(button);
    }
    let dimensions = Box::new(Orientation::Horizontal, 8);
    dimensions.append(&session);
    dimensions.append(&columns);
    dimensions.append(&rows);
    page.append(&dimensions);
    page.append(&scroller);
    page.append(&input);
    page.append(&actions);
    session
}

fn render_ssh_keys(state: &NativeState, list: &ListBox, status: &Label, ask: &Rc<dyn Fn(String)>) {
    clear_list(list);
    let view = state.ssh_keys.borrow();
    let message = match view.status() {
        SshKeysStatus::SignInRequired => Some(strings::Message::SshKeysSignInFirst),
        SshKeysStatus::Loading => Some(strings::Message::SshKeysLoading),
        SshKeysStatus::Failed => Some(strings::Message::SshKeysFailed),
        SshKeysStatus::Empty => Some(strings::Message::SshKeysEmpty),
        SshKeysStatus::Loaded => None,
    };
    status.set_label(&message.map(strings::text).unwrap_or_default());
    for row in view.rows() {
        let line = Box::new(Orientation::Horizontal, 8);
        let text = Box::new(Orientation::Vertical, 2);
        let label =
            Label::new(Some(&row.label.clone().unwrap_or_else(|| {
                strings::text(strings::Message::SshKeyUnlabelled)
            })));
        label.set_halign(Align::Start);
        let fingerprint = Label::new(Some(&row.fingerprint));
        fingerprint.set_halign(Align::Start);
        fingerprint.set_selectable(true);
        fingerprint.add_css_class("dim-label");
        text.append(&label);
        text.append(&fingerprint);
        text.set_hexpand(true);
        line.append(&text);
        if row.this_device {
            line.append(&Label::new(Some(&strings::text(
                strings::Message::SshKeyThisDevice,
            ))));
        } else {
            let button = Button::with_label(&strings::text(strings::Message::SshKeyRevoke));
            let id = row.id.clone();
            let ask = ask.clone();
            button.connect_clicked(move |_| ask(id.clone()));
            line.append(&button);
        }
        list.append(&line);
    }
}

/// SSH-key settings: Refresh, rows with Revoke, and a confirmation bar.
pub(super) fn build_ssh_keys(state: &NativeState, page: &Box, status: &Label) -> Rc<dyn Fn()> {
    page.append(&heading(&strings::text(strings::Message::SshKeysTitle)));
    let explain = Label::new(Some(&strings::text(strings::Message::SshKeysExplain)));
    explain.set_wrap(true);
    explain.set_halign(Align::Start);
    page.append(&explain);
    let list_status = Label::new(None);
    list_status.set_halign(Align::Start);
    let list = ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let (confirm_bar, confirm_button) = ConfirmBar::new();

    let ask: Rc<dyn Fn(String)> = {
        let state = state.clone();
        let confirm_bar = confirm_bar.clone();
        let confirm_button = confirm_button.clone();
        Rc::new(move |id: String| {
            let Some(fingerprint) = state.ssh_keys.borrow().confirmation_fingerprint(&id) else {
                return;
            };
            confirm_bar.ask(
                &confirm_button,
                Pending::RevokeKey(id),
                &strings::format(
                    strings::Message::SshKeyRevokeConfirm,
                    &[("fingerprint", &fingerprint)],
                ),
                &strings::text(strings::Message::SshKeyRevoke),
            );
        })
    };
    let render: Rc<dyn Fn()> = {
        let state = state.clone();
        let list = list.clone();
        let list_status = list_status.clone();
        Rc::new(move || render_ssh_keys(&state, &list, &list_status, &ask))
    };

    let refresh = Button::with_label(&strings::text(strings::Message::Refresh));
    {
        let state = state.clone();
        let render = render.clone();
        refresh.connect_clicked(move |_| {
            {
                let mut binding = state.session.borrow_mut();
                let source = binding
                    .session_mut()
                    .map(|live| -> &mut dyn SshKeySource { live });
                state.ssh_keys.borrow_mut().refresh(source);
            }
            render();
        });
    }
    {
        let state = state.clone();
        let render = render.clone();
        let status = status.clone();
        let confirm_bar = confirm_bar.clone();
        confirm_button.connect_clicked(move |_| {
            let Some(Pending::RevokeKey(id)) = confirm_bar.take() else {
                return;
            };
            let outcome = {
                let mut binding = state.session.borrow_mut();
                let source = binding
                    .session_mut()
                    .map(|live| -> &mut dyn SshKeySource { live });
                state.ssh_keys.borrow_mut().revoke(
                    source,
                    &id,
                    mila_native_linux::adapter::new_request_id,
                )
            };
            status.set_label(&strings::text(match outcome {
                RevokeOutcome::Revoked => strings::Message::RequestSucceeded,
                RevokeOutcome::Refused => strings::Message::RequestRefused,
                RevokeOutcome::Uncertain => strings::Message::RequestWaiting,
                RevokeOutcome::Unavailable => strings::Message::SshKeysSignInFirst,
                RevokeOutcome::ThisDevice => strings::Message::SshKeyThisDevice,
            }));
            render();
        });
    }
    page.append(&refresh);
    page.append(&list_status);
    page.append(&list);
    page.append(&confirm_bar.container);
    render();
    render
}

/// Shared handling of every inbound link: desktop open, entry, paste, drop.
pub(super) fn handle_batch(state: &NativeState, batch: &ActivationBatch, status: &Label) {
    let selected = state
        .deployment_list()
        .ok()
        .and_then(|list| list.selected().map(|host| host.as_str().to_owned()));
    let authenticated = state.session.borrow().is_authenticated();
    let decisions = batch.decisions(selected.as_deref(), authenticated);
    let Some(decision) = decisions.first() else {
        status.set_label(&strings::text(strings::Message::LinkRefused));
        return;
    };
    let presentation = present(decision);
    if let Some(targets) = state.links.borrow().as_ref() {
        let prefill = &presentation.prefill;
        for (entry, value) in [
            (&targets.deployment, &prefill.deployment_host),
            (&targets.machine, &prefill.machine_id),
            (&targets.terminal_session, &prefill.terminal_session_id),
            (&targets.thread, &prefill.thread_id),
        ] {
            if let Some(value) = value {
                entry.set_text(value);
            }
        }
    }
    state.show_page(presentation.page);
    status.set_label(&match presentation.notice {
        LinkNotice::UnknownDeployment => strings::format(
            strings::Message::LinkUnknownDeployment,
            &[("host", &presentation.authority)],
        ),
        LinkNotice::SignInRequired => strings::format(
            strings::Message::LinkSignInRequired,
            &[("host", &presentation.authority)],
        ),
        LinkNotice::Opened => decision.canonical(),
    });
}

/// Link entry and Open control; pasted text goes through the same batch.
pub(super) fn build_link_controls(state: &NativeState, page: &Box, status: &Label) {
    let entry = Entry::builder()
        .placeholder_text("overalls://")
        .max_length(2048)
        .hexpand(true)
        .build();
    let open = Button::with_label(&strings::text(strings::Message::DeploymentOpen));
    {
        let state = state.clone();
        let entry = entry.clone();
        let status = status.clone();
        open.connect_clicked(move |_| {
            handle_batch(&state, &share_inbound(entry.text().as_str()), &status);
        });
    }
    let line = Box::new(Orientation::Horizontal, 8);
    line.append(&entry);
    line.append(&open);
    page.append(&line);
}

/// Accept dropped `overalls://` text (one link per line) anywhere on the window.
pub(super) fn install_drop_target(
    state: &NativeState,
    widget: &impl IsA<gtk::Widget>,
    status: &Label,
) {
    let target = gtk::DropTarget::new(glib::Type::STRING, gdk::DragAction::COPY);
    let state = state.clone();
    let status = status.clone();
    target.connect_drop(move |_, value, _, _| {
        let Ok(text) = value.get::<String>() else {
            return false;
        };
        handle_batch(&state, &share_inbound(&text), &status);
        true
    });
    widget.add_controller(target);
}

/// "Copy link" for a page: the target comes from that page's typed entries
/// and is canonicalized by `share_route` before reaching the clipboard.
pub(super) fn copy_link_button(
    state: &NativeState,
    status: &Label,
    target: impl Fn() -> Target + 'static,
) -> Button {
    let button = Button::with_label(&strings::text(strings::Message::LinkCopy));
    let state = state.clone();
    let status = status.clone();
    button.connect_clicked(move |button| {
        let host = state
            .deployment_list()
            .ok()
            .and_then(|list| list.selected().map(|host| host.as_str().to_owned()));
        match host.and_then(|host| share_route(&host, &target()).ok()) {
            Some(link) => {
                button.clipboard().set_text(&link);
                status.set_label(&strings::text(strings::Message::LinkCopied));
            }
            None => status.set_label(&strings::text(strings::Message::LinkRefused)),
        }
    });
    button
}

/// Typed share targets read from page entries; invalid ids fall back to the
/// page's list route rather than producing a non-canonical link.
pub(super) fn machine_target(machine: &Entry) -> Target {
    let id = machine.text().trim().to_owned();
    if id.is_empty() {
        Target::Machines
    } else {
        Target::Machine {
            id,
            page: MachinePage::Overview,
        }
    }
}

pub(super) fn terminal_target(machine: &Entry, session: &Entry) -> Target {
    let id = machine.text().trim().to_owned();
    let session_id = session.text().trim().to_owned();
    match (id.is_empty(), session_id.is_empty()) {
        (true, _) => Target::Machines,
        (false, true) => Target::Machine {
            id,
            page: MachinePage::Terminals,
        },
        (false, false) => Target::Machine {
            id,
            page: MachinePage::Terminal { session_id },
        },
    }
}

pub(super) fn thread_target(thread: &Entry) -> Target {
    let id = thread.text().trim().to_owned();
    if id.is_empty() {
        Target::Threads
    } else {
        Target::Thread { id }
    }
}

/// Sign-in page: Sign in, Open approval page, Reconnect and Sign out over the
/// window's `SignInDriver`, plus the phase message, the approval fingerprint
/// and the signed-in account. Returns the page renderer.
#[expect(
    clippy::too_many_lines,
    reason = "linear GTK page construction; ADR-0265 keeps mila-linux lint-only, so splitting is deferred"
)]
pub(super) fn build_sign_in(
    state: &NativeState,
    sign_in_page: &Box,
    deployment: &Entry,
    status: &Label,
) -> Rc<dyn Fn()> {
    // Sign-in runs the GTK-independent SignInDriver: trust fetch, device
    // key, certificate-authenticated connect, approval browser launch,
    // whoami polling, heartbeat and reconnect run off the main loop. GTK
    // forwards the buttons and renders the reducer's phase.
    let sign_in_status = Label::new(None);
    sign_in_status.set_wrap(true);
    sign_in_status.set_halign(Align::Start);
    let fingerprint_title = Label::new(Some(&strings::text(strings::Message::SignInFingerprint)));
    fingerprint_title.set_halign(Align::Start);
    let fingerprint_value = Label::new(None);
    fingerprint_value.set_halign(Align::Start);
    fingerprint_value.set_selectable(true);
    let account_title = Label::new(Some(&strings::text(strings::Message::SignInAccount)));
    account_title.set_halign(Align::Start);
    let account_value = Label::new(None);
    account_value.set_halign(Align::Start);
    let sign_in_controls = Box::new(Orientation::Horizontal, 8);
    let sign_in_button = Button::with_label(&strings::text(strings::Message::SignInStart));
    let open_approval = Button::with_label(&strings::text(strings::Message::SignInOpenBrowser));
    let reconnect = Button::with_label(&strings::text(strings::Message::SignInReconnect));
    let sign_out_button = Button::with_label(&strings::text(strings::Message::SignInSignOut));
    let render: Rc<dyn Fn()> = {
        let state = state.clone();
        let status = sign_in_status.clone();
        let fingerprint_title = fingerprint_title.clone();
        let fingerprint_value = fingerprint_value.clone();
        let account_title = account_title.clone();
        let account_value = account_value.clone();
        let open_approval = open_approval.clone();
        let reconnect = reconnect.clone();
        let sign_out_button = sign_out_button.clone();
        Rc::new(move || {
            let driver = state.driver.borrow();
            let flow = driver.flow();
            let host = driver
                .target()
                .map(mila_native_linux::signin_driver::SignInTarget::https_authority)
                .unwrap_or_default();
            let message = match (flow.phase, flow.failure) {
                (SignInPhase::SignedOut | SignInPhase::SignedIn, _) => None,
                (SignInPhase::Connecting, _) => Some(strings::format(
                    strings::Message::SignInConnecting,
                    &[("host", &host)],
                )),
                (SignInPhase::AwaitingApproval, _) => {
                    Some(strings::text(strings::Message::SignInApprove))
                }
                (SignInPhase::Disconnected, _) => {
                    Some(strings::text(strings::Message::SignInDisconnected))
                }
                (SignInPhase::Expired, _) => Some(strings::text(strings::Message::SignInExpired)),
                (SignInPhase::Failed, failure) => Some(strings::text(match failure {
                    Some(SignInFailure::DeviceKey) => strings::Message::SignInFailedDeviceKey,
                    Some(SignInFailure::HostUntrusted) => strings::Message::SignInFailedHost,
                    Some(SignInFailure::Refused) => strings::Message::SignInFailedRefused,
                    Some(SignInFailure::Unreachable) => strings::Message::SignInFailedUnreachable,
                    Some(SignInFailure::Protocol) | None => strings::Message::SignInFailedProtocol,
                })),
            };
            status.set_label(message.as_deref().unwrap_or_default());
            status.set_visible(message.is_some());
            let fingerprint = flow
                .approval
                .as_ref()
                .map(|approval| approval.fingerprint.clone());
            fingerprint_title.set_visible(fingerprint.is_some());
            fingerprint_value.set_visible(fingerprint.is_some());
            fingerprint_value.set_label(fingerprint.as_deref().unwrap_or_default());
            let signed_in = flow.phase == SignInPhase::SignedIn;
            account_title.set_visible(signed_in);
            account_value.set_visible(signed_in);
            account_value.set_label(if signed_in {
                flow.account.as_deref().unwrap_or_default()
            } else {
                ""
            });
            open_approval.set_sensitive(flow.approval.is_some());
            reconnect.set_sensitive(
                matches!(
                    flow.phase,
                    SignInPhase::Disconnected | SignInPhase::Expired | SignInPhase::Failed
                ) && driver.target().is_some(),
            );
            sign_out_button.set_sensitive(flow.phase != SignInPhase::SignedOut);
        })
    };
    *state.sign_in_render.borrow_mut() = Some(render.clone());

    let sign_in_status_out = status.clone();
    let deployment_input = deployment.clone();
    let sign_in_state = state.clone();
    sign_in_button.connect_clicked(move |_| {
        let host = deployment_input.text().trim().to_owned();
        let Ok(changed) = sign_in_state.update_deployments(|list| list.add_and_select(&host))
        else {
            sign_in_status_out
                .set_label(&strings::text(strings::Message::SignInDeploymentRequired));
            return;
        };
        if changed {
            sign_in_state.drop_authority();
        }
        if let Err(message) = sign_in_state.begin_sign_in() {
            sign_in_status_out.set_label(&strings::text(message));
        }
    });
    sign_in_controls.append(&sign_in_button);

    let approval_state = state.clone();
    open_approval.connect_clicked(move |_| {
        // Re-open the link the driver already validated for this
        // generation's HTTPS authority; validate again at the boundary.
        let approval = {
            let driver = approval_state.driver.borrow();
            let authority = driver
                .target()
                .map(mila_native_linux::signin_driver::SignInTarget::https_authority);
            driver.flow().approval.clone().zip(authority)
        };
        if let Some((approval, authority)) = approval {
            if ApprovalInfo::validate_for_host(
                &approval.url,
                &approval.fingerprint,
                approval.issued_at,
                &authority,
            )
            .is_ok()
            {
                approval_state.browser.open(&approval);
            }
        }
    });
    sign_in_controls.append(&open_approval);

    let reconnect_state = state.clone();
    reconnect.connect_clicked(move |_| {
        if reconnect_state.driver.borrow_mut().reconnect() {
            reconnect_state.start_sign_in_pump();
        }
        reconnect_state.render_sign_in();
    });
    sign_in_controls.append(&reconnect);

    let sign_out_state = state.clone();
    sign_out_button.connect_clicked(move |_| {
        // Never retain authenticated projections after sign-out: machine
        // listing, terminal generation and SSH-key rows are all dropped.
        // A subsequent session must refresh from the server.
        sign_out_state.drop_authority();
    });
    sign_in_controls.append(&sign_out_button);
    sign_in_page.append(&sign_in_controls);
    sign_in_page.append(&sign_in_status);
    sign_in_page.append(&fingerprint_title);
    sign_in_page.append(&fingerprint_value);
    sign_in_page.append(&account_title);
    sign_in_page.append(&account_value);
    render();
    render
}
