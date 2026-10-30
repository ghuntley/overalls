use adw::prelude::*;
use adw::{Application, ApplicationWindow};
use gtk::{gio, glib, Align, Box, Button, Entry, Label, Orientation, TextDirection};
use mila_native_linux::adapter::{decode_notification_devices, RequestLedger};
use mila_native_linux::connection_profile::ConnectionProfiles;
use mila_native_linux::deep_link::Page;
use mila_native_linux::deployments::{DeploymentError, DeploymentList, DeploymentStore};
use mila_native_linux::notifications::NotificationState;
use mila_native_linux::route::ActivationBatch;
use mila_native_linux::session::{ApprovalInfo, LiveSession, SessionBinding, SessionError};
use mila_native_linux::signin_driver::{
    ApprovalBrowser, DriverEvent, Execution, LiveConnector, SignInDriver, SignInPolicy,
};
use mila_native_linux::ssh_keys_view::SshKeysView;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};
#[cfg(feature = "gtk-journey")]
mod gtk_journey;
mod pages;
mod persistence;
mod strings;
mod views;
const APPLICATION_ID: &str = "dev.overalls.Mila.Linux";
/// Main-loop interval for applying sign-in driver results.
const SIGN_IN_FRAME: Duration = Duration::from_millis(100);
/// SSH connect and per-command timeout for the live session.
const SESSION_TIMEOUT_MS: u32 = 20_000;

/// Opens approval links in the user's default browser.
struct GioBrowser;

impl ApprovalBrowser for GioBrowser {
    fn open(&self, approval: &ApprovalInfo) -> bool {
        gio::AppInfo::launch_default_for_uri(&approval.url, None::<&gio::AppLaunchContext>).is_ok()
    }
}
#[derive(Clone)]
struct NativeState {
    status: Rc<RefCell<Option<Label>>>,
    connector: Arc<LiveConnector>,
    driver: Rc<RefCell<SignInDriver<LiveConnector>>>,
    browser: Rc<dyn ApprovalBrowser>,
    clock: Instant,
    sign_in_pumping: Rc<Cell<bool>>,
    sign_in_render: Rc<RefCell<Option<Rc<dyn Fn()>>>>,
    session: Rc<RefCell<SessionBinding>>,
    machine_listing: Rc<RefCell<Option<mila_session::MachineListing>>>,
    deployment_store: Option<DeploymentStore>,
    terminal: Rc<RefCell<Option<views::GtkTerminal>>>,
    terminal_polling: Rc<Cell<bool>>,
    ssh_keys: Rc<RefCell<SshKeysView>>,
    links: Rc<RefCell<Option<views::LinkTargets>>>,
    rerender: Rc<RefCell<Vec<Rc<dyn Fn()>>>>,
    /// Request ids of page mutations whose outcome is unknown because the
    /// transport failed; a retry of the same action reuses the id so the
    /// deployment applies it at most once. Keyed by action and target only.
    requests: Rc<RefCell<RequestLedger>>,
}
impl NativeState {
    fn new() -> Self {
        Self::with_browser(Rc::new(GioBrowser))
    }

    fn with_browser(browser: Rc<dyn ApprovalBrowser>) -> Self {
        let connector = Arc::new(LiveConnector::new(
            mila_native_linux::device_key::default_path(),
            SESSION_TIMEOUT_MS,
        ));
        Self {
            status: Rc::new(RefCell::new(None)),
            driver: Rc::new(RefCell::new(SignInDriver::new(
                connector.clone(),
                SignInPolicy::default(),
                Execution::Thread,
            ))),
            connector,
            browser,
            clock: Instant::now(),
            sign_in_pumping: Rc::new(Cell::new(false)),
            sign_in_render: Rc::new(RefCell::new(None)),
            session: Rc::new(RefCell::new(SessionBinding::default())),
            machine_listing: Rc::new(RefCell::new(None)),
            deployment_store: DeploymentStore::from_environment(),
            terminal: Rc::new(RefCell::new(None)),
            terminal_polling: Rc::new(Cell::new(false)),
            ssh_keys: Rc::new(RefCell::new(SshKeysView::default())),
            links: Rc::new(RefCell::new(None)),
            rerender: Rc::new(RefCell::new(Vec::new())),
            requests: Rc::new(RefCell::new(RequestLedger::default())),
        }
    }

    /// Runs one page operation on the bound session. Returns `None` when no
    /// authenticated session is bound. A transport or stale-handle error
    /// reports the session lost at once, so reconnect starts without
    /// waiting for the next heartbeat.
    // @cc linux-page-action-loss: a page action's transport failure releases
    // the session and advances the sign-in generation before it returns.
    fn with_live<T>(
        &self,
        op: impl FnOnce(&mut LiveSession) -> Result<T, SessionError>,
    ) -> Option<Result<T, SessionError>> {
        let result = {
            let mut binding = self.session.borrow_mut();
            let live = binding.session_mut().filter(|live| live.is_open())?;
            op(live)
        };
        if matches!(
            result,
            Err(SessionError::Transport | SessionError::StaleHandle)
        ) {
            self.session_lost();
        }
        Some(result)
    }

    /// Runs a page mutation with a request id for `key`. The id is kept only
    /// while the outcome is unknown (transport loss), so a retry is
    /// idempotent; any definite outcome forgets it.
    fn mutate<T>(
        &self,
        key: &str,
        op: impl FnOnce(&mut LiveSession, &str) -> Result<T, SessionError>,
    ) -> Option<Result<T, SessionError>> {
        let Some(request) = self.requests.borrow().id_for(key) else {
            return Some(Err(SessionError::Unavailable));
        };
        let result = self.with_live(|live| op(live, &request));
        let unknown = matches!(
            result,
            Some(Err(SessionError::Transport | SessionError::StaleHandle))
        );
        self.requests.borrow_mut().settle(key, request, unknown);
        result
    }

    /// Reports the bound session lost to the driver and releases it; the
    /// driver's reconnect runs on the sign-in pump.
    fn session_lost(&self) {
        let lost = self.driver.borrow_mut().report_loss();
        if lost {
            self.release_session();
            self.start_sign_in_pump();
            self.render_sign_in();
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
        self.driver.borrow_mut().sign_out();
        // Retained request ids belong to this deployment and account; a
        // reconnect after loss keeps them, a switch or sign-out does not.
        self.requests.borrow_mut().clear();
        self.release_session();
    }

    /// Releases the bound session and everything projected from it, without
    /// ending the sign-in generation (a reconnect may follow).
    fn release_session(&self) {
        if let Some(surface) = self.terminal.borrow_mut().as_mut() {
            surface.sign_out();
        }
        *self.terminal.borrow_mut() = None;
        self.session.borrow_mut().clear();
        *self.machine_listing.borrow_mut() = None;
        self.ssh_keys.borrow_mut().sign_out();
        for render in self.rerender.borrow().iter() {
            render();
        }
        self.render_sign_in();
    }

    fn render_sign_in(&self) {
        let render = self.sign_in_render.borrow().clone();
        if let Some(render) = render {
            render();
        }
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.clock.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// Starts signing in to the selected deployment through the driver.
    fn begin_sign_in(&self) -> Result<(), strings::Message> {
        let selected = self
            .deployment_list()
            .ok()
            .and_then(|list| list.selected().cloned())
            .ok_or(strings::Message::SignInDeploymentRequired)?;
        let profiles = match ConnectionProfiles::default_path() {
            Some(path) => ConnectionProfiles::load(&path),
            None => Ok(ConnectionProfiles::default()),
        }
        .map_err(|_| strings::Message::SignInProfileInvalid)?;
        let target = profiles
            .resolve(&selected)
            .map_err(|_| strings::Message::SignInProfileInvalid)?;
        let switching = {
            let driver = self.driver.borrow();
            driver.is_active() && driver.target() != Some(&target)
        };
        if switching {
            self.drop_authority();
        }
        self.driver.borrow_mut().start(target);
        self.start_sign_in_pump();
        self.render_sign_in();
        Ok(())
    }

    fn start_sign_in_pump(&self) {
        if self.sign_in_pumping.replace(true) {
            return;
        }
        let state = self.clone();
        glib::timeout_add_local(SIGN_IN_FRAME, move || {
            if state.pump_sign_in() {
                glib::ControlFlow::Continue
            } else {
                state.sign_in_pumping.set(false);
                glib::ControlFlow::Break
            }
        });
    }

    /// One main-loop step: heartbeat the bound session, apply finished
    /// driver jobs, bind an established session or release a lost one.
    fn pump_sign_in(&self) -> bool {
        let now = self.now_ms();
        let before = {
            let flow = self.driver.borrow();
            let flow = flow.flow();
            (flow.phase, flow.generation, flow.approval.is_some())
        };
        let mut lost = false;
        if self.driver.borrow().heartbeat_due(now) {
            let probe = self.session.borrow().session().and_then(LiveSession::probe);
            let mut driver = self.driver.borrow_mut();
            match probe {
                Some(probe) => driver.heartbeat(probe, now),
                None => lost = driver.report_loss(),
            }
        }
        let events = self.driver.borrow_mut().poll(now, &*self.browser);
        if lost {
            self.release_session();
        }
        for event in events {
            match event {
                DriverEvent::Established { session, .. } => {
                    self.session.borrow_mut().bind(session);
                    {
                        let mut keys = self.ssh_keys.borrow_mut();
                        keys.set_device_fingerprint(self.connector.device_fingerprint());
                        keys.begin_session();
                    }
                    for render in self.rerender.borrow().iter() {
                        render();
                    }
                }
                DriverEvent::Lost => self.release_session(),
            }
        }
        let after = {
            let flow = self.driver.borrow();
            let flow = flow.flow();
            (flow.phase, flow.generation, flow.approval.is_some())
        };
        if before != after {
            self.render_sign_in();
        }
        self.driver.borrow().is_active()
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

        // Sign-in runs the GTK-independent SignInDriver; see views::build_sign_in.
        views::build_sign_in(self, &sign_in_page, &deployment, &content);

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
            let state = self.clone();
            let device_id = notification_id.clone();
            button.connect_clicked(move |_| {
                let device = device_id.text().trim().to_owned();
                let result = state.with_live(|live| match operation {
                    "list" => live.device_list().and_then(|bytes| {
                        decode_notification_devices(&bytes)
                            .map(|_| ())
                            .map_err(|_| SessionError::InvalidInput)
                    }),
                    "remove" => live.device_remove(&device),
                    "enable" => live.device_preference(&device, true),
                    "disable" => live.device_preference(&device, false),
                    _ => Err(SessionError::InvalidInput),
                });
                let Some(result) = result else {
                    status.set_label(&strings::text(strings::Message::NotificationRequireSignIn));
                    return;
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
        let machine_id = pages::build_machines(self, &machines_page, &content);
        // The terminal page binds the authenticated PTY (HostPtyTransport over
        // the session FFI) to a GTK text view through the library surface.
        // PTY bytes are decoded in the transport; GTK receives viewport text.
        let terminal_session = views::build_terminal(self, &terminal_page, &content);
        let terminal_link_machine = machine_id.clone();
        let terminal_link_session = terminal_session.clone();
        terminal_page.append(&views::copy_link_button(self, &content, move || {
            views::terminal_target(&terminal_link_machine, &terminal_link_session)
        }));
        let thread_id = pages::build_threads(self, &threads_page, &content);
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
    #[cfg(feature = "gtk-journey")]
    {
        let mut arguments = std::env::args_os().skip(1);
        if arguments.next().as_deref() == Some(std::ffi::OsStr::new("--gtk-journey")) {
            return gtk_journey::main(arguments);
        }
    }
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
    use mila_native_linux::session::{SignInFailure, SignInPhase};

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
        let machines_page = page(Page::Machines);
        let threads_page = page(Page::Threads);
        let _sign_in = page(Page::SignIn);
        let deployment = Entry::new();
        let machine = Entry::new();
        let thread = Entry::new();
        let render = views::build_deployments(&state, &deployments_page, &deployment, &status);
        state.rerender.borrow_mut().push(render);
        let terminal_session = views::build_terminal(&state, &terminal_page, &status);
        let render_keys = views::build_ssh_keys(&state, &settings_page, &status);
        state.rerender.borrow_mut().push(render_keys);
        let machine_page_id = pages::build_machines(&state, &machines_page, &status);
        let thread_page_id = pages::build_threads(&state, &threads_page, &status);
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

        // Machines and Threads: every control shows catalog text and refuses
        // without a bound session; Delete asks for confirmation first.
        let sign_in_required = strings::text(strings::Message::SignInRequired);
        let refresh = strings::text(strings::Message::Refresh);
        find(&machines_page, &refresh)[0].emit_clicked();
        assert!(texts(&machines_page).contains(&sign_in_required));
        let delete = strings::text(strings::Message::ActionDelete);
        find(&machines_page, &delete)[0].emit_clicked();
        assert_eq!(
            status.label(),
            strings::text(strings::Message::MachineFieldInvalid)
        );
        machine_page_id.set_text("01234567-89ab-cdef-0123-456789abcdef");
        find(&machines_page, &delete)[0].emit_clicked();
        let prompt = strings::format(
            strings::Message::ConfirmDelete,
            &[("name", "01234567-89ab-cdef-0123-456789abcdef")],
        );
        assert!(texts(&machines_page).contains(&prompt));
        find(&machines_page, &delete).last().unwrap().emit_clicked();
        assert_eq!(status.label(), sign_in_required);
        assert!(state.requests.borrow().is_empty());
        for action in [
            strings::Message::ActionStart,
            strings::Message::ActionStop,
            strings::Message::ActionPause,
            strings::Message::ActionResume,
            strings::Message::ActionCreate,
            strings::Message::ActionResize,
            strings::Message::SharingAdd,
            strings::Message::WebPublic,
        ] {
            status.set_label("");
            find(&machines_page, &strings::text(action))[0].emit_clicked();
            assert_ne!(status.label(), "", "{}", strings::text(action));
        }
        find(&threads_page, &refresh)[0].emit_clicked();
        assert!(texts(&threads_page).contains(&sign_in_required));
        thread_page_id.set_text("thread-1");
        find(&threads_page, &strings::text(strings::Message::TabInfo))[0].emit_clicked();
        assert_eq!(status.label(), sign_in_required);
        find(&threads_page, &strings::text(strings::Message::ThreadSend))[0].emit_clicked();
        assert_eq!(
            status.label(),
            strings::text(strings::Message::ThreadFailed)
        );

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
        sign_in_page_runs_the_live_driver(&directory);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[derive(Default)]
    struct RecordingBrowser(Cell<u32>);

    impl ApprovalBrowser for RecordingBrowser {
        fn open(&self, _: &ApprovalInfo) -> bool {
            self.0.set(self.0.get() + 1);
            true
        }
    }

    fn settle(state: &NativeState) {
        let context = glib::MainContext::default();
        let started = Instant::now();
        while state.driver.borrow().is_active() && started.elapsed() < Duration::from_secs(60) {
            context.iteration(false);
            std::thread::sleep(Duration::from_millis(10));
        }
        while context.iteration(false) {}
    }

    /// The Sign in button runs the window's real driver and live connector:
    /// it creates the owner-only device key, attempts the HTTPS trust fetch
    /// for the profile's port and CA, and renders the typed failure when the
    /// deployment cannot present trust. No session is bound and no approval
    /// link is opened.
    fn sign_in_page_runs_the_live_driver(directory: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::create_dir_all(directory).unwrap();
        let key_path = directory.join("data").join("device-key");
        let profiles = directory.join("connections.json");
        std::env::set_var("MILA_DEPLOYMENT_PATH", directory.join("sign-in.json"));
        std::env::set_var("MILA_DEVICE_KEY_PATH", &key_path);
        std::env::set_var("MILA_CONNECTIONS_PATH", &profiles);
        let browser = Rc::new(RecordingBrowser::default());
        let state = NativeState::with_browser(browser.clone());
        std::env::remove_var("MILA_DEPLOYMENT_PATH");
        std::env::remove_var("MILA_DEVICE_KEY_PATH");
        let status = Label::new(None);
        let page = Box::new(Orientation::Vertical, 8);
        let deployment = Entry::new();
        views::build_sign_in(&state, &page, &deployment, &status);
        let start = strings::text(strings::Message::SignInStart);

        // An invalid profile fails closed before any key or network use.
        std::fs::write(
            &profiles,
            br#"{"version":1,"profiles":[{"host":"bad host"}]}"#,
        )
        .unwrap();
        std::fs::set_permissions(&profiles, std::fs::Permissions::from_mode(0o600)).unwrap();
        deployment.set_text("unreachable.invalid");
        find(&page, &start)[0].emit_clicked();
        assert_eq!(
            status.label(),
            strings::text(strings::Message::SignInProfileInvalid)
        );
        assert!(!key_path.exists());
        assert_eq!(state.driver.borrow().flow().phase, SignInPhase::SignedOut);

        // A valid profile runs trust fetch on the profile's port and CA.
        std::fs::write(
            &profiles,
            br#"{"version":1,"profiles":[{"host":"unreachable.invalid","ssh_port":2222,"https_port":9,"ca_file":"/nonexistent/ca.pem"}]}"#,
        )
        .unwrap();
        find(&page, &start)[0].emit_clicked();
        assert!(texts(&page).contains(&strings::format(
            strings::Message::SignInConnecting,
            &[("host", "unreachable.invalid:9")]
        )));
        settle(&state);
        std::env::remove_var("MILA_CONNECTIONS_PATH");
        let flow = state.driver.borrow().flow().clone();
        assert_eq!(flow.phase, SignInPhase::Failed);
        assert_eq!(flow.failure, Some(SignInFailure::HostUntrusted));
        assert!(texts(&page).contains(&strings::text(strings::Message::SignInFailedHost)));
        let mode = std::fs::metadata(&key_path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "device key created owner-only");
        assert!(!state.session.borrow().is_authenticated());
        assert_eq!(browser.0.get(), 0);
        assert!(!state.sign_in_pumping.get(), "pump stops when inactive");

        // Reconnect retries the same target; Sign out ends the generation.
        let reconnect = find(&page, &strings::text(strings::Message::SignInReconnect));
        assert!(reconnect[0].is_sensitive());
        let generation = flow.generation;
        reconnect[0].emit_clicked();
        assert!(state.driver.borrow().flow().generation > generation);
        find(&page, &strings::text(strings::Message::SignInSignOut))[0].emit_clicked();
        assert_eq!(state.driver.borrow().flow().phase, SignInPhase::SignedOut);
        settle(&state);
        assert_eq!(state.driver.borrow().flow().phase, SignInPhase::SignedOut);
    }
}
