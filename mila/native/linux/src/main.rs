use adw::prelude::*;
use adw::{Application, ApplicationWindow};
use gtk::{gio, glib, Align, Box, Button, Entry, Label, Orientation, TextDirection};
use mila_native_linux::adapter::{
    browser_endpoint_url, decode_listing, decode_notification_devices, decode_web_endpoint,
    format_machine_action, format_thread_response, format_web_command,
};
use mila_native_linux::deep_link::Page;
use mila_native_linux::deployments::{DeploymentError, DeploymentList, DeploymentStore};
use mila_native_linux::machine_view::{project_detail, project_listing};
use mila_native_linux::notifications::NotificationState;
use mila_native_linux::route::ActivationBatch;
use mila_native_linux::session::{
    ApprovalInfo, SessionBinding, SignInEvent, SignInFlow, SignInPhase, WhoamiOutcome,
};
use mila_native_linux::ssh_keys_view::SshKeysView;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
mod persistence;
mod strings;
mod views;
const APPLICATION_ID: &str = "dev.overalls.Mila.Linux";
#[derive(Clone)]
struct NativeState {
    status: Rc<RefCell<Option<Label>>>,
    sign_in: Rc<RefCell<SignInFlow>>,
    session: Rc<RefCell<SessionBinding>>,
    machine_listing: Rc<RefCell<Option<mila_session::MachineListing>>>,
    deployment_store: Option<DeploymentStore>,
    terminal: Rc<RefCell<Option<views::GtkTerminal>>>,
    terminal_polling: Rc<Cell<bool>>,
    ssh_keys: Rc<RefCell<SshKeysView>>,
    links: Rc<RefCell<Option<views::LinkTargets>>>,
    rerender: Rc<RefCell<Vec<Rc<dyn Fn()>>>>,
}
impl NativeState {
    fn new() -> Self {
        Self {
            status: Rc::new(RefCell::new(None)),
            sign_in: Rc::new(RefCell::new(SignInFlow::default())),
            session: Rc::new(RefCell::new(SessionBinding::default())),
            machine_listing: Rc::new(RefCell::new(None)),
            deployment_store: DeploymentStore::from_environment(),
            terminal: Rc::new(RefCell::new(None)),
            terminal_polling: Rc::new(Cell::new(false)),
            ssh_keys: Rc::new(RefCell::new(SshKeysView::default())),
            links: Rc::new(RefCell::new(None)),
            rerender: Rc::new(RefCell::new(Vec::new())),
        }
    }

    fn deployment_list(&self) -> Result<DeploymentList, DeploymentError> {
        self.deployment_store
            .as_ref()
            .map_or(Ok(DeploymentList::default()), DeploymentStore::load)
    }

    fn update_deployments<R>(
        &self,
        change: impl FnOnce(&mut DeploymentList) -> Result<R, DeploymentError>,
    ) -> Result<R, DeploymentError> {
        let store = self
            .deployment_store
            .as_ref()
            .ok_or(DeploymentError::InvalidData)?;
        store.update(change).map(|(_, result)| result)
    }

    /// A deployment switch, removal or sign-out invalidates every
    /// authenticated handle and projection: session, approval generation,
    /// machine listing, terminal generation and SSH-key rows.
    fn drop_authority(&self) {
        if let Some(surface) = self.terminal.borrow_mut().as_mut() {
            surface.sign_out();
        }
        *self.terminal.borrow_mut() = None;
        self.session.borrow_mut().clear();
        *self.machine_listing.borrow_mut() = None;
        self.ssh_keys.borrow_mut().sign_out();
        let mut flow = self.sign_in.borrow_mut();
        *flow = flow.clone().apply(SignInEvent::SignOut);
        drop(flow);
        for render in self.rerender.borrow().iter() {
            render();
        }
    }

    fn show_page(&self, page: Page) {
        if let Some(targets) = self.links.borrow().as_ref() {
            targets.stack.set_visible_child_name(page.name());
        }
    }
    fn ensure_window(&self, app: &adw::Application) -> ApplicationWindow {
        if let Some(window) = app.active_window() {
            if let Ok(window) = window.downcast::<ApplicationWindow>() {
                return window;
            }
        }
        let root = Box::new(Orientation::Vertical, 12);
        root.set_margin_top(24);
        root.set_margin_bottom(24);
        root.set_margin_start(24);
        root.set_margin_end(24);
        let title_text = strings::text(strings::Message::AppName);
        let title = Label::new(Some(&title_text));
        title.set_halign(Align::Start);
        title.add_css_class("title-1");
        root.append(&title);
        let stack = gtk::Stack::new();
        stack.set_vexpand(true);
        let switcher = gtk::StackSwitcher::new();
        switcher.set_stack(Some(&stack));
        root.append(&switcher);
        let page = || {
            let page = Box::new(Orientation::Vertical, 8);
            page.set_margin_top(12);
            page
        };
        let machines_page = page();
        let threads_page = page();
        let terminal_page = page();
        let deployments_page = page();
        let sign_in_page = page();
        let settings_page = page();
        for (child, page_id, title) in [
            (
                &machines_page,
                Page::Machines,
                strings::text(strings::Message::Machines),
            ),
            (
                &threads_page,
                Page::Threads,
                strings::text(strings::Message::Threads),
            ),
            (
                &terminal_page,
                Page::Terminal,
                strings::text(strings::Message::TerminalsTitle),
            ),
            (
                &deployments_page,
                Page::Deployments,
                strings::text(strings::Message::DeploymentsTitle),
            ),
            (
                &sign_in_page,
                Page::SignIn,
                strings::text(strings::Message::SignInTitle),
            ),
            (
                &settings_page,
                Page::Settings,
                strings::text(strings::Message::Settings),
            ),
        ] {
            let scroller = gtk::ScrolledWindow::builder()
                .child(child)
                .vexpand(true)
                .hscrollbar_policy(gtk::PolicyType::Never)
                .build();
            stack.add_titled(&scroller, Some(page_id.name()), &title);
        }
        root.append(&stack);
        let ready_text = strings::text(strings::Message::Ready);
        let content = Label::new(Some(&ready_text));
        content.set_wrap(true);
        content.set_halign(Align::Start);
        content.set_selectable(true);
        *self.status.borrow_mut() = Some(content.clone());

        let settings = persistence::load_settings().unwrap_or_default();
        root.set_direction(match settings.direction() {
            persistence::LocaleDirection::Rtl => TextDirection::Rtl,
            persistence::LocaleDirection::Ltr => TextDirection::Ltr,
        });
        let appearance_label = Label::new(Some(&strings::text(strings::Message::Appearance)));
        appearance_label.set_halign(Align::Start);
        settings_page.append(&appearance_label);
        let settings_actions = Box::new(Orientation::Horizontal, 8);
        for (label, appearance) in [
            (
                strings::text(strings::Message::AppearanceSystem),
                persistence::Appearance::System,
            ),
            (
                strings::text(strings::Message::AppearanceLight),
                persistence::Appearance::Light,
            ),
            (
                strings::text(strings::Message::AppearanceDark),
                persistence::Appearance::Dark,
            ),
        ] {
            let button = Button::with_label(&label);
            let status = content.clone();
            let locale = settings.locale.clone();
            button.connect_clicked(move |_| {
                let value = persistence::Settings {
                    appearance,
                    locale: locale.clone(),
                };
                match persistence::save_settings(&value) {
                    Ok(()) => status.set_label(&format!(
                        "{}: {:?}",
                        strings::text(strings::Message::Appearance),
                        appearance
                    )),
                    Err(_) => status.set_label("Settings could not be saved."),
                }
            });
            settings_actions.append(&button);
        }
        settings_page.append(&settings_actions);
        let locale = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::Locale))
            .text(&settings.locale)
            .max_length(35)
            .hexpand(true)
            .build();
        let save_settings = Button::with_label(&strings::text(strings::Message::SaveSettings));
        let locale_input = locale.clone();
        let settings_status = content.clone();
        let saved_appearance = settings.appearance;
        save_settings.connect_clicked(move |_| {
            match persistence::Settings::validate(saved_appearance, locale_input.text().as_str())
                .and_then(|value| persistence::save_settings(&value).map(|_| value))
            {
                Ok(value) => {
                    settings_status.set_label(&format!("Settings saved: {}", value.locale))
                }
                Err(_) => settings_status.set_label("Settings locale rejected by Rust policy."),
            }
        });
        settings_page.append(&locale);
        settings_page.append(&save_settings);

        let deployment = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::DeploymentSelect))
            .hexpand(true)
            .build();
        if let Some(selected) = self
            .deployment_list()
            .ok()
            .and_then(|list| list.selected().cloned())
        {
            deployment.set_text(selected.as_str());
        }
        let render_deployments =
            views::build_deployments(self, &deployments_page, &deployment, &content);
        self.rerender.borrow_mut().push(render_deployments);

        // Deep links can also be entered, pasted or dropped. Every path uses
        // the same bounded activation batch and navigation-only presentation
        // as desktop `open` events.
        views::build_link_controls(self, &deployments_page, &content);

        let machine_detail_id = Entry::builder()
            .placeholder_text("Machine UUID for detail")
            .hexpand(true)
            .build();
        let machine_status = content.clone();
        let machine_session = self.session.clone();
        let machine_listing = self.machine_listing.clone();
        let refresh_machines = Button::with_label("Refresh machines");
        refresh_machines.connect_clicked(move |_| {
            let binding = machine_session.borrow();
            let Some(live) = binding.session() else {
                machine_status.set_label("Machine list unavailable until sign-in.");
                return;
            };
            match live
                .listing()
                .and_then(|bytes| {
                    decode_listing(&bytes)
                        .map_err(|_| mila_native_linux::session::SessionError::InvalidInput)
                })
                .and_then(|listing| {
                    let rows = project_listing(&listing)
                        .map_err(|_| mila_native_linux::session::SessionError::InvalidInput)?;
                    *machine_listing.borrow_mut() = Some(listing);
                    let summary = rows
                        .iter()
                        .map(|row| {
                            format!(
                                "{}{} — {}",
                                if row.pinned { "★ " } else { "" },
                                row.name,
                                row.observed_state.as_deref().unwrap_or("unavailable")
                            )
                        })
                        .collect::<Vec<_>>();
                    Ok(summary.join("\n"))
                }) {
                Ok(summary) if summary.is_empty() => {
                    machine_status.set_label("No machines returned.")
                }
                Ok(summary) => machine_status.set_label(&format!("Machines\n{summary}")),
                Err(_) => machine_status.set_label("Machine list rejected by Rust policy."),
            }
        });
        let detail_status = content.clone();
        let detail_listing = self.machine_listing.clone();
        let detail_id = machine_detail_id.clone();
        let show_machine = Button::with_label("Show machine detail");
        show_machine.connect_clicked(move |_| {
            let id = detail_id.text().trim().to_owned();
            let Some(listing) = detail_listing.borrow().as_ref().cloned() else {
                detail_status.set_label("Refresh machines before opening detail.");
                return;
            };
            match project_detail(&listing, &id) {
                Ok(row) => detail_status.set_label(&format!(
                    "Machine {}\nDesired: {}\nObserved: {}\nRead: {}  Write: {}  Manage: {}",
                    row.name,
                    row.desired_state,
                    row.observed_state.as_deref().unwrap_or("unavailable"),
                    row.can_read,
                    row.can_write,
                    row.can_manage
                )),
                Err(_) => detail_status.set_label("Machine detail unavailable."),
            }
        });
        machines_page.append(&machine_detail_id);
        machines_page.append(&refresh_machines);
        machines_page.append(&show_machine);

        // The lifecycle controls are deliberately state-only until the host
        // supplies its owner-only Linux device signer and HTTPS trust fetcher.
        // They still exercise the same generation/approval/reconnect reducer as
        // the connected path and never claim authenticated authority locally.
        let sign_in_controls = Box::new(Orientation::Horizontal, 8);
        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let deployment_input = deployment.clone();
        let sign_in_button = Button::with_label(&strings::text(strings::Message::SignInStart));
        let sign_in_state = self.clone();
        sign_in_button.connect_clicked(move |_| {
            let host = deployment_input.text().trim().to_owned();
            let Ok(changed) = sign_in_state.update_deployments(|list| list.add_and_select(&host))
            else {
                sign_in_status
                    .set_label(&strings::text(strings::Message::SignInDeploymentRequired));
                return;
            };
            if changed {
                sign_in_state.drop_authority();
            }
            let mut flow = sign_in.borrow_mut();
            *flow = flow.clone().apply(SignInEvent::Start);
            sign_in_status.set_label(&strings::text(strings::Message::SignInConnecting));
        });
        sign_in_controls.append(&sign_in_button);

        let approval_url = Entry::builder()
            .placeholder_text("Browser approval URL (HTTPS)")
            .hexpand(true)
            .build();
        let approval_fingerprint = Entry::builder()
            .placeholder_text("Approval fingerprint")
            .hexpand(true)
            .build();
        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let url = approval_url.clone();
        let fingerprint = approval_fingerprint.clone();
        let approval_button = Button::with_label(&strings::text(strings::Message::SignInApprove));
        approval_button.connect_clicked(move |_| {
            let mut flow = sign_in.borrow_mut();
            let generation = flow.generation;
            let outcome = WhoamiOutcome::Approval {
                url: url.text().trim().to_owned(),
                fingerprint: fingerprint.text().trim().to_owned(),
            };
            *flow = flow.clone().apply(SignInEvent::Whoami {
                generation,
                outcome,
                at: 0,
            });
            sign_in_status.set_label(if flow.phase == SignInPhase::AwaitingApproval {
                "Approval pending; open the HTTPS link in your browser."
            } else {
                "Approval URL rejected by Rust policy."
            });
        });
        sign_in_controls.append(&approval_button);

        let sign_in = self.sign_in.clone();
        let session = self.session.clone();
        let sign_in_status = content.clone();
        let check_approval = Button::with_label("Check approval");
        check_approval.connect_clicked(move |_| {
            let generation = sign_in.borrow().generation;
            let outcome = match session.borrow().session() {
                Some(live) => live.whoami(),
                None => Err(mila_native_linux::session::SessionError::StaleHandle),
            };
            let mut flow = sign_in.borrow_mut();
            match outcome {
                Ok(outcome) => {
                    *flow = flow.clone().apply(SignInEvent::Whoami {
                        generation,
                        outcome,
                        at: 0,
                    });
                    sign_in_status.set_label(match flow.phase {
                        SignInPhase::SignedIn => "Deployment approved and signed in.",
                        SignInPhase::AwaitingApproval => "Approval is still pending.",
                        _ => "Deployment identity check refused.",
                    });
                }
                Err(_) => sign_in_status.set_label("No authenticated deployment session."),
            }
        });
        sign_in_controls.append(&check_approval);

        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let approval_deployment = deployment.clone();
        let open_approval = Button::with_label(&strings::text(strings::Message::SignInOpenBrowser));
        open_approval.connect_clicked(move |_| {
            let flow = sign_in.borrow();
            let Some(approval) = flow.approval.as_ref() else {
                sign_in_status.set_label("No live approval link is available.");
                return;
            };
            let expected_host = approval_deployment.text().trim().to_owned();
            if ApprovalInfo::validate_for_host(
                &approval.url,
                &approval.fingerprint,
                approval.issued_at,
                &expected_host,
            )
            .is_err()
            {
                sign_in_status.set_label("Approval URL rejected by Rust policy.");
                return;
            }
            match gio::AppInfo::launch_default_for_uri(
                &approval.url,
                None::<&gio::AppLaunchContext>,
            ) {
                Ok(()) => sign_in_status.set_label("Approval opened in the browser."),
                Err(_) => sign_in_status.set_label("The browser could not open approval."),
            }
        });
        sign_in_controls.append(&open_approval);

        let sign_in_status = content.clone();
        let sign_out_state = self.clone();
        let sign_out_button = Button::with_label(&strings::text(strings::Message::SignInSignOut));
        sign_out_button.connect_clicked(move |_| {
            // Never retain authenticated projections after sign-out: machine
            // listing, terminal generation and SSH-key rows are all dropped.
            // A subsequent session must refresh from the server.
            sign_out_state.drop_authority();
            sign_in_status.set_label("Signed out; deployment trust and approval remain pinned.");
        });
        sign_in_controls.append(&sign_out_button);
        sign_in_page.append(&sign_in_controls);
        sign_in_page.append(&approval_url);
        sign_in_page.append(&approval_fingerprint);

        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let reconnect = Button::with_label(&strings::text(strings::Message::SignInReconnect));
        reconnect.connect_clicked(move |_| {
            let mut flow = sign_in.borrow_mut();
            let previous = flow.phase;
            *flow = flow.clone().apply(SignInEvent::Start);
            sign_in_status.set_label(if previous == SignInPhase::Disconnected {
                "Reconnect started; a fresh generation must reauthenticate."
            } else {
                "Reconnect requires a disconnected authenticated session."
            });
        });
        sign_in_page.append(&reconnect);

        // Linux intentionally reports lock capability explicitly. The shared retired client
        // policy marks Linux as unavailable; keeping this state visible prevents
        // presenting a control that cannot be honored by the native platform.
        let lock_title = strings::text(strings::Message::LockTitle);
        let lock_button = Button::with_label(&lock_title);
        // The capability is explicitly unavailable on Linux; keep the control
        // visible for discoverability but prevent it from implying an action.
        lock_button.set_sensitive(false);
        let lock_status = content.clone();
        lock_button.connect_clicked(move |_| {
            let explanation = strings::text(strings::Message::LockExplain);
            let unavailable = strings::text(strings::Message::LockUnavailable);
            lock_status.set_label(&format!("{unavailable}\n{explanation}"));
        });
        settings_page.append(&lock_button);
        // Linux can show local desktop notifications through the desktop
        // environment, while Susan push registration remains unavailable.
        let notification_state = Rc::new(RefCell::new(NotificationState::desktop()));
        let notification_button =
            Button::with_label(&strings::text(strings::Message::NotificationsTitle));
        let notification_status = content.clone();
        let notification_state_for_action = notification_state.clone();
        notification_button.connect_clicked(move |_| {
            let mut state = notification_state_for_action.borrow_mut();
            match state.enable() {
                Ok(()) => notification_status.set_label("Notifications enabled."),
                Err(_) => notification_status
                    .set_label(&strings::text(strings::Message::NotificationsExplain)),
            }
        });
        settings_page.append(&notification_button);
        let notification_id = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::NotificationDeviceId))
            .hexpand(true)
            .build();
        let notification_actions = Box::new(Orientation::Horizontal, 8);
        for (message, operation) in [
            (strings::Message::NotificationRefresh, "list"),
            (strings::Message::NotificationRemove, "remove"),
            (strings::Message::NotificationEnable, "enable"),
            (strings::Message::NotificationDisable, "disable"),
        ] {
            let button = Button::with_label(&strings::text(message));
            let status = content.clone();
            let session = self.session.clone();
            let device_id = notification_id.clone();
            button.connect_clicked(move |_| {
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    status.set_label(&strings::text(strings::Message::NotificationRequireSignIn));
                    return;
                };
                let result = match operation {
                    "list" => live.device_list().and_then(|bytes| {
                        decode_notification_devices(&bytes)
                            .map(|items| format!("{} notification devices", items.len()))
                            .map_err(|_| mila_native_linux::session::SessionError::InvalidInput)
                    }),
                    "remove" => live
                        .device_remove(device_id.text().trim())
                        .map(|()| String::new()),
                    "enable" => live
                        .device_preference(device_id.text().trim(), true)
                        .map(|()| String::new()),
                    "disable" => live
                        .device_preference(device_id.text().trim(), false)
                        .map(|()| String::new()),
                    _ => Err(mila_native_linux::session::SessionError::InvalidInput),
                };
                let message = if result.is_ok() {
                    strings::text(strings::Message::NotificationAccepted)
                } else {
                    strings::text(strings::Message::NotificationRejected)
                };
                status.set_label(&message);
            });
            notification_actions.append(&button);
        }
        settings_page.append(&notification_id);
        settings_page.append(&notification_actions);
        let machine_id = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::MachineUuid))
            .hexpand(true)
            .build();
        let request_id = Entry::builder()
            .placeholder_text("Request UUID (for mutations)")
            .hexpand(true)
            .build();
        let actions = Box::new(Orientation::Horizontal, 8);
        // `rm` is Porsche's closed-command spelling for deleting a machine.
        // Keep it in the native action set so GTK exposes the complete lifecycle
        // supported by the authenticated Rust session.
        for action in ["show", "start", "stop", "pause", "resume", "rm"] {
            let button = Button::with_label(action);
            let machine = machine_id.clone();
            let request = request_id.clone();
            let label = content.clone();
            let session = self.session.clone();
            let action = action.to_owned();
            button.connect_clicked(move |_| {
                if action == "show" {
                    let request = (!request.text().is_empty()).then(|| request.text().to_string());
                    match format_machine_action(
                        &action,
                        machine.text().as_str(),
                        request.as_deref(),
                    ) {
                        Ok(command) => label.set_label(&format!("Machine command\n{command}")),
                        Err(_) => label.set_label("Machine command rejected by Rust policy."),
                    }
                    return;
                }
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    label.set_label("Machine mutations require sign-in.");
                    return;
                };
                // Keep the owned GTK entry text alive while its trimmed views
                // are passed through validation and the authenticated session.
                let machine_text = machine.text();
                let machine_id = machine_text.trim();
                let request_text = request.text();
                let request_id = request_text.trim();
                if request_id.is_empty() {
                    label.set_label("Machine mutations require a request UUID.");
                    return;
                }
                // Run the same bounded Rust command formatter used by the
                // non-transport path before touching the authenticated
                // session. This rejects malformed IDs and command-like input
                // at the GTK boundary and keeps lifecycle requests replay-safe.
                if format_machine_action(&action, machine_id, Some(request_id)).is_err() {
                    label.set_label("Machine mutation rejected by Rust policy.");
                    return;
                }
                match live.machine_action(machine_id, &action, request_id) {
                    Ok(()) => label.set_label("Machine mutation accepted."),
                    Err(_) => label.set_label("Machine mutation rejected by Rust policy."),
                }
            });
            actions.append(&button);
        }
        machines_page.append(&machine_id);
        machines_page.append(&request_id);
        machines_page.append(&actions);
        let create_name = Entry::builder()
            .placeholder_text("New machine name")
            .hexpand(true)
            .build();
        let create_button = Button::with_label("Create machine");
        let create_status = content.clone();
        let create_session = self.session.clone();
        let create_request = request_id.clone();
        let create_name_input = create_name.clone();
        create_button.connect_clicked(move |_| {
            let mut binding = create_session.borrow_mut();
            let Some(live) = binding.session_mut() else {
                create_status.set_label("Machine creation requires sign-in.");
                return;
            };
            match live.machine_create(
                create_name_input.text().trim(),
                1,
                1024,
                10_240,
                create_request.text().trim(),
            ) {
                Ok(()) => create_status.set_label("Machine creation accepted."),
                Err(_) => create_status.set_label("Machine creation rejected by Rust policy."),
            }
        });
        machines_page.append(&create_name);
        machines_page.append(&create_button);
        let resize_button = Button::with_label("Resize machine");
        let resize_status = content.clone();
        let resize_session = self.session.clone();
        let resize_machine = machine_id.clone();
        let resize_request = request_id.clone();
        resize_button.connect_clicked(move |_| {
            let mut binding = resize_session.borrow_mut();
            let Some(live) = binding.session_mut() else {
                resize_status.set_label("Machine resize requires sign-in.");
                return;
            };
            match live.machine_resize(
                resize_machine.text().trim(),
                1,
                1024,
                10_240,
                resize_request.text().trim(),
            ) {
                Ok(()) => resize_status.set_label("Machine resize accepted."),
                Err(_) => resize_status.set_label("Machine resize rejected by Rust policy."),
            }
        });
        machines_page.append(&resize_button);
        let share_email = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::ShareEmail))
            .hexpand(true)
            .build();
        let share_role = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::ShareRole))
            .hexpand(true)
            .build();
        let share_actions = Box::new(Orientation::Horizontal, 8);
        for (label_text, operation) in [
            (strings::text(strings::Message::ShareAdd), "add"),
            (strings::text(strings::Message::ShareRemove), "remove"),
        ] {
            let button = Button::with_label(&label_text);
            let machine = machine_id.clone();
            let email = share_email.clone();
            let role = share_role.clone();
            let status = content.clone();
            let session = self.session.clone();
            let request_id = request_id.clone();
            button.connect_clicked(move |_| {
                let request = request_id.text().trim().to_owned();
                let selected_role =
                    (!role.text().trim().is_empty()).then(|| role.text().trim().to_owned());
                let add = operation == "add";
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    status.set_label("Sharing mutations require sign-in.");
                    return;
                };
                match live.share_mutation(
                    machine.text().trim(),
                    email.text().trim(),
                    selected_role.as_deref(),
                    add,
                    &request,
                ) {
                    Ok(()) => status.set_label("Sharing mutation accepted."),
                    Err(_) => status.set_label("Sharing request rejected by Rust policy."),
                }
            });
            share_actions.append(&button);
        }
        machines_page.append(&share_email);
        machines_page.append(&share_role);
        machines_page.append(&share_actions);
        let share_response = Entry::builder()
            .placeholder_text("share show JSON (paste response)")
            .hexpand(true)
            .build();
        let share_load = Button::with_label(&strings::text(strings::Message::ShareLoad));
        let share_status = content.clone();
        let response_input = share_response.clone();
        share_load.connect_clicked(
            move |_| match mila_native_linux::adapter::decode_share_listing(
                response_input.text().as_bytes(),
            ) {
                Ok((owner, grants)) => share_status
                    .set_label(&format!("Owner: {owner}\n{} share grants", grants.len())),
                Err(_) => share_status.set_label("Sharing listing rejected by Rust policy."),
            },
        );
        machines_page.append(&share_response);
        machines_page.append(&share_load);
        // The terminal page binds the authenticated PTY (HostPtyTransport over
        // the session FFI) to a GTK text view through the library surface.
        // PTY bytes are decoded in the transport; GTK receives viewport text.
        let terminal_session = views::build_terminal(self, &terminal_page, &content);
        let terminal_link_machine = machine_id.clone();
        let terminal_link_session = terminal_session.clone();
        terminal_page.append(&views::copy_link_button(self, &content, move || {
            views::terminal_target(&terminal_link_machine, &terminal_link_session)
        }));
        let thread_id = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::ThreadId))
            .max_length(128)
            .hexpand(true)
            .build();
        let thread_actions = Box::new(Orientation::Horizontal, 8);
        for operation in ["ls", "show"] {
            let label = if operation == "ls" {
                strings::text(strings::Message::ThreadList)
            } else {
                strings::text(strings::Message::ThreadShow)
            };
            let button = Button::with_label(&label);
            let input = thread_id.clone();
            let status = content.clone();
            let session = self.session.clone();
            let operation = operation.to_owned();
            button.connect_clicked(move |_| {
                let id = (!input.text().is_empty()).then(|| input.text().to_string());
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    status.set_label("Thread controls require sign-in.");
                    return;
                };
                let command = if operation == "ls" {
                    "thread ls"
                } else {
                    "thread show"
                };
                match live.thread_action(id.as_deref(), command, None, None, None) {
                    Ok(bytes) => match format_thread_response(&bytes) {
                        Ok(response) => status.set_label(&response),
                        Err(_) => status.set_label("Thread response rejected by Rust policy."),
                    },
                    Err(_) => status.set_label("Thread command rejected by Rust policy."),
                }
            });
            thread_actions.append(&button);
        }
        let turns = Button::with_label("Thread turns");
        let turns_input = thread_id.clone();
        let turns_status = content.clone();
        let turns_session = self.session.clone();
        turns.connect_clicked(move |_| {
            let mut binding = turns_session.borrow_mut();
            let Some(live) = binding.session_mut() else {
                turns_status.set_label("Thread controls require sign-in.");
                return;
            };
            match live.thread_action(
                Some(turns_input.text().trim()),
                "thread turns",
                None,
                None,
                None,
            ) {
                Ok(bytes) => match format_thread_response(&bytes) {
                    Ok(response) => turns_status.set_label(&response),
                    Err(_) => turns_status.set_label("Thread response rejected by Rust policy."),
                },
                Err(_) => turns_status.set_label("Thread turns rejected by Rust policy."),
            }
        });
        thread_actions.append(&turns);
        let thread_secondary = Entry::builder()
            .placeholder_text("Turn or question ID")
            .max_length(128)
            .hexpand(true)
            .build();
        let thread_input = Entry::builder()
            .placeholder_text("Thread input (stdin)")
            // GtkEntry:max-length is bounded by G_MAXUINT16; 65536 aborts
            // window construction. The Rust thread action enforces its own
            // stdin bound.
            .max_length(i32::from(u16::MAX))
            .hexpand(true)
            .build();
        for (message, command, needs_secondary) in [
            (strings::Message::ThreadPrompt, "thread prompt", false),
            (strings::Message::ThreadAnswer, "thread answer", true),
        ] {
            let button = Button::with_label(&strings::text(message));
            let thread = thread_id.clone();
            let secondary = thread_secondary.clone();
            let input = thread_input.clone();
            let request = request_id.clone();
            let session = self.session.clone();
            let status = content.clone();
            button.connect_clicked(move |_| {
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    status.set_label("Thread controls require sign-in.");
                    return;
                };
                let secondary_value = needs_secondary.then(|| secondary.text().trim().to_owned());
                let request_value =
                    (!request.text().trim().is_empty()).then(|| request.text().trim().to_owned());
                match live.thread_action(
                    Some(thread.text().trim()),
                    command,
                    secondary_value.as_deref(),
                    Some(input.text().as_str()),
                    request_value.as_deref(),
                ) {
                    Ok(bytes) => match format_thread_response(&bytes) {
                        Ok(response) => status.set_label(&response),
                        Err(_) => status.set_label("Thread response rejected by Rust policy."),
                    },
                    Err(_) => status.set_label("Thread mutation rejected by Rust policy."),
                }
            });
            thread_actions.append(&button);
        }
        for (message, command, needs_input) in [
            (
                strings::Message::ThreadPlanApprove,
                "thread plan approve",
                false,
            ),
            (
                strings::Message::ThreadPlanRevise,
                "thread plan revise",
                true,
            ),
        ] {
            let button = Button::with_label(&strings::text(message));
            let thread = thread_id.clone();
            let secondary = thread_secondary.clone();
            let input = thread_input.clone();
            let request = request_id.clone();
            let session = self.session.clone();
            let status = content.clone();
            button.connect_clicked(move |_| {
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    status.set_label("Thread controls require sign-in.");
                    return;
                };
                let request_value =
                    (!request.text().trim().is_empty()).then(|| request.text().trim().to_owned());
                let input_value = needs_input.then(|| input.text().to_owned());
                match live.thread_action(
                    Some(thread.text().trim()),
                    command,
                    Some(secondary.text().trim()),
                    input_value.as_deref(),
                    request_value.as_deref(),
                ) {
                    Ok(bytes) => match format_thread_response(&bytes) {
                        Ok(response) => status.set_label(&response),
                        Err(_) => status.set_label("Thread response rejected by Rust policy."),
                    },
                    Err(_) => status.set_label("Thread mutation rejected by Rust policy."),
                }
            });
            thread_actions.append(&button);
        }
        threads_page.append(&thread_id);
        threads_page.append(&thread_secondary);
        threads_page.append(&thread_input);
        threads_page.append(&thread_actions);
        let thread_link_entry = thread_id.clone();
        threads_page.append(&views::copy_link_button(self, &content, move || {
            views::thread_target(&thread_link_entry)
        }));
        let web_port = Entry::builder()
            .placeholder_text("Web port (1-65535)")
            .hexpand(true)
            .build();
        let web_request = Entry::builder()
            .placeholder_text("Request UUID (for web changes)")
            .hexpand(true)
            .build();
        let web_revision = Entry::builder()
            .placeholder_text("Policy revision")
            .hexpand(true)
            .build();
        let web_actions = Box::new(Orientation::Horizontal, 8);
        // Keep the last authenticated endpoint in memory only.  The URL is
        // accepted from the Rust decoder after machine/route and HTTPS
        // validation; GTK never constructs or persists browser destinations.
        let web_endpoint: Rc<RefCell<Option<mila_native_linux::adapter::WebEndpoint>>> =
            Rc::new(RefCell::new(None));
        for (label_text, operation, public) in [
            (strings::text(strings::Message::WebShow), "show", false),
            (strings::text(strings::Message::WebPublic), "set", true),
            (strings::text(strings::Message::WebPrivate), "set", false),
        ] {
            let button = Button::with_label(&label_text);
            let machine = machine_id.clone();
            let port = web_port.clone();
            let request = web_request.clone();
            let revision = web_revision.clone();
            let session = self.session.clone();
            let status = content.clone();
            let endpoint_state = web_endpoint.clone();
            button.connect_clicked(move |_| {
                let machine_id = machine.text().trim().to_owned();
                let parsed_port = (!port.text().is_empty())
                    .then(|| port.text().parse::<u16>().ok())
                    .flatten();
                let request_id = (!request.text().is_empty()).then(|| request.text().to_string());
                let parsed_revision = (!revision.text().is_empty())
                    .then(|| revision.text().parse::<u64>().ok())
                    .flatten();
                let mut binding = session.borrow_mut();
                let Some(live) = binding.session_mut() else {
                    status.set_label("Web endpoint unavailable until sign-in.");
                    return;
                };
                if operation == "show" {
                    let result = live.web_show(&machine_id).and_then(|bytes| {
                        decode_web_endpoint(&bytes)
                            .map_err(|_| mila_native_linux::session::SessionError::InvalidInput)
                    });
                    match result.as_ref() {
                        Ok(endpoint) => status.set_label(&format!(
                            "Web endpoint\n{}:{} ({}, revision {})",
                            endpoint.label,
                            endpoint.port,
                            endpoint.visibility,
                            endpoint.policy_revision
                        )),
                        Err(_) => status.set_label("Web endpoint read rejected."),
                    }
                    if let Ok(endpoint) = result {
                        *endpoint_state.borrow_mut() = Some(endpoint);
                    }
                } else {
                    let Some(port) = parsed_port else {
                        status.set_label("Web port rejected.");
                        return;
                    };
                    let Some(revision) = parsed_revision else {
                        status.set_label("Web policy revision rejected.");
                        return;
                    };
                    let Some(request_id) = request_id.as_deref() else {
                        status.set_label("Web request id rejected.");
                        return;
                    };
                    if format_web_command(
                        operation,
                        &machine_id,
                        Some(port),
                        public,
                        Some(request_id),
                    )
                    .is_err()
                    {
                        status.set_label("Web request rejected by Rust policy.");
                        return;
                    }
                    match live.web_set(&machine_id, port, public, revision, request_id) {
                        Ok(()) => {
                            // A mutation invalidates the previously decoded URL;
                            // require a fresh authenticated `web show` before launch.
                            endpoint_state.borrow_mut().take();
                            status.set_label("Web endpoint change submitted.");
                        }
                        Err(_) => status.set_label("Web endpoint change rejected."),
                    }
                }
            });
            web_actions.append(&button);
        }
        machines_page.append(&web_port);
        machines_page.append(&web_request);
        machines_page.append(&web_revision);
        machines_page.append(&web_actions);
        let open_web = Button::with_label("Open web endpoint");
        let open_web_status = content.clone();
        let endpoint_state = web_endpoint.clone();
        let open_web_session = self.session.clone();
        open_web.connect_clicked(move |_| {
            if open_web_session.borrow().session().is_none() {
                endpoint_state.borrow_mut().take();
                open_web_status.set_label("Web controls require sign-in.");
                return;
            }
            let Some(endpoint) = endpoint_state.borrow().as_ref().cloned() else {
                open_web_status.set_label("Load a web endpoint before opening it.");
                return;
            };
            let Some(url) = browser_endpoint_url(&endpoint) else {
                open_web_status.set_label("This machine has no public web endpoint.");
                return;
            };
            // decode_web_endpoint already enforces HTTPS and the canonical
            // machine route. Re-check the scheme at the launch boundary so a
            // future state refactor cannot turn this into an open redirect.
            match gio::AppInfo::launch_default_for_uri(url, None::<&gio::AppLaunchContext>) {
                Ok(()) => open_web_status.set_label("Web endpoint opened in the browser."),
                Err(_) => open_web_status.set_label("The browser could not open the endpoint."),
            }
        });
        machines_page.append(&open_web);
        let machine_link_entry = machine_id.clone();
        machines_page.append(&views::copy_link_button(self, &content, move || {
            views::machine_target(&machine_link_entry)
        }));
        let render_ssh_keys = views::build_ssh_keys(self, &settings_page, &content);
        self.rerender.borrow_mut().push(render_ssh_keys);
        *self.links.borrow_mut() = Some(views::LinkTargets {
            stack: stack.clone(),
            deployment: deployment.clone(),
            machine: machine_id.clone(),
            terminal_session: terminal_session.clone(),
            thread: thread_id.clone(),
        });
        root.append(&content);
        let window = ApplicationWindow::builder()
            .application(app)
            .title(strings::text(strings::Message::AppName))
            .default_width(900)
            .default_height(720)
            .content(&root)
            .build();
        views::install_drop_target(self, &window, &content);
        let close_state = self.clone();
        window.connect_close_request(move |_| {
            close_state.drop_authority();
            glib::Propagation::Proceed
        });
        window
    }
    fn activate(&self, app: &adw::Application) {
        self.ensure_window(app).present();
    }
    fn open(&self, app: &adw::Application, files: &[gio::File]) {
        let window = self.ensure_window(app);
        let uris = files.iter().map(|file| file.uri()).collect::<Vec<_>>();
        let batch = ActivationBatch::parse(uris.iter().map(|uri| uri.as_str()));
        if let Some(status) = self.status.borrow().clone() {
            views::handle_batch(self, &batch, &status);
        }
        window.present();
    }
}
fn main() -> glib::ExitCode {
    adw::init().expect("GTK/libadwaita initialization failed");
    let css = gtk::CssProvider::new();
    css.load_from_data("* { font-family: JetBrains Mono, monospace; font-size: 14px; } window, box { background: #fff; color: #000; } button, entry { border: 2px solid #000; border-radius: 0; background: #eee; color: #000; } button:hover { background: #000; color: #fff; } @media (prefers-color-scheme: dark) { window, box { background: #000; color: #fff; } button, entry { border-color: #fff; background: #111; color: #fff; } button:hover { background: #fff; color: #000; } } ");
    gtk::style_context_add_provider_for_display(
        &gtk::gdk::Display::default().expect("display"),
        &css,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    let application = Application::builder()
        .application_id(APPLICATION_ID)
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    let state = NativeState::new();
    let a = state.clone();
    application.connect_activate(move |app| a.activate(app));
    let o = state.clone();
    application.connect_open(move |app, files, _| o.open(app, files));
    application.run()
}

/// GTK widget-lifecycle tests. They need a display; CI runs them against a
/// Broadway server and sets `MILA_GTK_TESTS_REQUIRED=1` so a missing display
/// fails instead of skipping. Everything runs in one test function because
/// GTK binds to the first thread that initializes it.
#[cfg(test)]
mod gtk_tests {
    use super::*;
    use mila_native_linux::route::share_inbound;

    fn buttons(widget: &gtk::Widget, label: &str, found: &mut Vec<Button>) {
        if let Some(button) = widget.downcast_ref::<Button>() {
            if button.label().as_deref() == Some(label) {
                found.push(button.clone());
            }
        }
        let mut child = widget.first_child();
        while let Some(current) = child {
            buttons(&current, label, found);
            child = current.next_sibling();
        }
    }

    fn find(widget: &impl IsA<gtk::Widget>, label: &str) -> Vec<Button> {
        let mut found = Vec::new();
        buttons(widget.upcast_ref(), label, &mut found);
        found
    }

    fn labels(widget: &gtk::Widget, found: &mut Vec<String>) {
        if let Some(label) = widget.downcast_ref::<Label>() {
            if label.is_visible() || label.parent().is_some() {
                found.push(label.label().to_string());
            }
        }
        let mut child = widget.first_child();
        while let Some(current) = child {
            labels(&current, found);
            child = current.next_sibling();
        }
    }

    fn texts(widget: &impl IsA<gtk::Widget>) -> Vec<String> {
        let mut found = Vec::new();
        labels(widget.upcast_ref(), &mut found);
        found
    }

    #[test]
    fn gtk_pages_bind_deployments_links_terminal_and_ssh_keys() {
        if adw::init().is_err() {
            assert!(
                std::env::var_os("MILA_GTK_TESTS_REQUIRED").is_none(),
                "GTK display required but unavailable"
            );
            eprintln!("skipping GTK widget tests: no display");
            return;
        }
        let directory = std::env::temp_dir().join(format!("mila-gtk-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::env::set_var("MILA_DEPLOYMENT_PATH", directory.join("deployment.json"));
        let state = NativeState::new();
        std::env::remove_var("MILA_DEPLOYMENT_PATH");
        let status = Label::new(None);
        let stack = gtk::Stack::new();
        let page = |name: Page| {
            let page = Box::new(Orientation::Vertical, 8);
            stack.add_named(&page, Some(name.name()));
            page
        };
        let deployments_page = page(Page::Deployments);
        let terminal_page = page(Page::Terminal);
        let settings_page = page(Page::Settings);
        let _machines = page(Page::Machines);
        let _threads = page(Page::Threads);
        let _sign_in = page(Page::SignIn);
        let deployment = Entry::new();
        let machine = Entry::new();
        let thread = Entry::new();
        let render = views::build_deployments(&state, &deployments_page, &deployment, &status);
        state.rerender.borrow_mut().push(render);
        let terminal_session = views::build_terminal(&state, &terminal_page, &status);
        let render_keys = views::build_ssh_keys(&state, &settings_page, &status);
        state.rerender.borrow_mut().push(render_keys);
        *state.links.borrow_mut() = Some(views::LinkTargets {
            stack: stack.clone(),
            deployment: deployment.clone(),
            machine: machine.clone(),
            terminal_session: terminal_session.clone(),
            thread: thread.clone(),
        });

        // Deployment list: add+select, then confirmed remove.
        let empty = strings::text(strings::Message::DeploymentsEmpty);
        assert!(texts(&deployments_page).contains(&empty));
        deployment.set_text("Mila.Example");
        find(
            &deployments_page,
            &strings::text(strings::Message::DeploymentAddAndSelect),
        )[0]
        .emit_clicked();
        assert_eq!(deployment.text(), "mila.example");
        let shown = texts(&deployments_page);
        assert!(shown.contains(&"mila.example".to_owned()));
        assert!(shown.contains(&strings::text(strings::Message::DeploymentSelected)));
        deployment.set_text("second.example");
        find(
            &deployments_page,
            &strings::text(strings::Message::DeploymentAddAndSelect),
        )[0]
        .emit_clicked();
        find(
            &deployments_page,
            &strings::text(strings::Message::DeploymentOpen),
        )[0]
        .emit_clicked();
        assert_eq!(
            state
                .deployment_list()
                .unwrap()
                .selected()
                .unwrap()
                .as_str(),
            "mila.example"
        );
        assert_eq!(stack.visible_child_name().as_deref(), Some("machines"));

        // Links: unknown deployment lands on the list, signed-out on sign-in.
        views::handle_batch(
            &state,
            &share_inbound("overalls://other.example/machines"),
            &status,
        );
        assert_eq!(stack.visible_child_name().as_deref(), Some("deployments"));
        assert_eq!(deployment.text(), "other.example");
        assert!(status.label().contains("other.example"));
        let machine_id = "01234567-89ab-cdef-0123-456789abcdef";
        views::handle_batch(
            &state,
            &share_inbound(&format!(
                "overalls://mila.example/machines/{machine_id}/terminals"
            )),
            &status,
        );
        assert_eq!(stack.visible_child_name().as_deref(), Some("sign-in"));
        assert_eq!(
            machine.text(),
            "",
            "signed-out links never pre-fill targets"
        );
        views::handle_batch(&state, &share_inbound("not a link"), &status);
        assert_eq!(status.label(), strings::text(strings::Message::LinkRefused));

        // Copy link uses the selected deployment and canonical route.
        machine.set_text(machine_id);
        let entry = machine.clone();
        let copy = views::copy_link_button(&state, &status, move || views::machine_target(&entry));
        copy.emit_clicked();
        assert_eq!(status.label(), strings::text(strings::Message::LinkCopied));
        machine.set_text("../etc");
        copy.emit_clicked();
        assert_eq!(status.label(), strings::text(strings::Message::LinkRefused));

        // Terminal: attach without a session is refused before any transport.
        find(
            &terminal_page,
            &strings::text(strings::Message::AttachTerminal),
        )[0]
        .emit_clicked();
        assert_eq!(
            status.label(),
            strings::text(strings::Message::TerminalSignedOut)
        );
        assert!(!state.terminal_polling.get());
        find(
            &terminal_page,
            &strings::text(strings::Message::TerminalSend),
        )[0]
        .emit_clicked();
        assert_eq!(
            status.label(),
            strings::text(strings::Message::TerminalInvalid)
        );

        // SSH keys: signed out shows the sign-in prompt and no rows.
        find(&settings_page, &strings::text(strings::Message::Refresh))[0].emit_clicked();
        assert!(
            texts(&settings_page).contains(&strings::text(strings::Message::SshKeysSignInFirst))
        );
        assert!(find(
            &settings_page,
            &strings::text(strings::Message::SshKeyRevoke)
        )
        .is_empty());

        // Removing the selected deployment drops its selection and authority.
        let remove = strings::text(strings::Message::DeploymentRemove);
        let rows = find(&deployments_page, &remove);
        rows[0].emit_clicked();
        let confirm = find(&deployments_page, &remove);
        confirm.last().unwrap().emit_clicked();
        let list = state.deployment_list().unwrap();
        assert_eq!(list.hosts().len(), 1);
        assert!(list.selected().is_none());
        assert_eq!(deployment.text(), "");
        assert_eq!(
            status.label(),
            strings::text(strings::Message::DeploymentForgotten)
        );
        let _ = std::fs::remove_dir_all(&directory);
    }
}
