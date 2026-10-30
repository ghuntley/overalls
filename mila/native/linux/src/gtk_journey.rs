//! Broadway-driven GTK journey (cargo feature `gtk-journey`).
//!
//! `mila-native-linux --gtk-journey <descriptor> [--workdir <new-dir>]` builds
//! the real GTK window inside a private XDG environment derived from the
//! hermetic fixture descriptor, then drives it the way a user would: types
//! the deployment, presses "Sign in with browser", lets the window's own
//! `SignInDriver` fetch trust, create the device key, connect and poll while
//! the fixture approver stands in for the browser, and then uses the Machines,
//! Settings and Terminal pages on the session the window bound. It severs the
//! bound session to exercise loss detection and reconnect, then signs out.
//!
//! The report has the same redacted shape as `mila-linux-journey`: step names
//! and fixed outcome codes only.

use super::{strings, NativeState};
use adw::prelude::*;
use gtk::{glib, Button, Entry, TextView};
use mila_native_linux::deep_link::Page;
use mila_native_linux::device_key::write_private;
use mila_native_linux::journey::{
    create_private_workdir, fixture_connection_profile, read_descriptor, sign_in_failure_code,
    FixtureApprover, JourneyDescriptor, JourneyReport,
};
use mila_native_linux::session::{LiveSession, SignInPhase};
use mila_native_linux::ssh_keys_view::SshKeysStatus;
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

const TICK: Duration = Duration::from_millis(200);
const SIGN_IN_DEADLINE: Duration = Duration::from_secs(120);
const STEP_DEADLINE: Duration = Duration::from_secs(30);
const RECONNECT_DEADLINE: Duration = Duration::from_secs(90);

fn usage() -> glib::ExitCode {
    eprintln!("usage: mila-native-linux --gtk-journey <descriptor> [--workdir <new-dir>]");
    glib::ExitCode::from(2)
}

/// Entry point; `arguments` excludes the program name and the flag.
pub(super) fn main(mut arguments: impl Iterator<Item = std::ffi::OsString>) -> glib::ExitCode {
    let Some(descriptor_path) = arguments.next().map(PathBuf::from) else {
        return usage();
    };
    let mut workdir = None;
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--workdir") => workdir = arguments.next().map(PathBuf::from),
            _ => return usage(),
        }
    }
    let descriptor = match read_descriptor(&descriptor_path) {
        Ok(descriptor) => descriptor,
        Err(error) => {
            eprintln!("mila-native-linux: descriptor rejected: {error:?}");
            return glib::ExitCode::from(2);
        }
    };
    let workdir = match create_private_workdir(workdir) {
        Ok(path) => path,
        Err(_) => {
            eprintln!("mila-native-linux: work directory must be new and private");
            return glib::ExitCode::from(2);
        }
    };
    let code = match prepare_environment(&descriptor, &workdir) {
        Some(ca_path) => run_window(&descriptor, &workdir, &ca_path),
        None => {
            let mut report = JourneyReport::new();
            report.record("gtk_environment", false, "unwritable");
            print_report(&report)
        }
    };
    let _ = std::fs::remove_dir_all(&workdir);
    code
}

/// Points every per-user path the window uses at the private work directory
/// and writes the fixture CA and connection profile. Runs before GTK or any
/// thread starts, so changing the process environment is sound.
fn prepare_environment(descriptor: &JourneyDescriptor, workdir: &Path) -> Option<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    let config = workdir.join("config");
    let data = workdir.join("data");
    for directory in [&config, &data, &config.join("mila")] {
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(directory)
            .ok()?;
    }
    for variable in [
        "MILA_DEPLOYMENT_PATH",
        "MILA_CONNECTIONS_PATH",
        "MILA_DEVICE_KEY_PATH",
    ] {
        std::env::remove_var(variable);
    }
    std::env::set_var("XDG_CONFIG_HOME", &config);
    std::env::set_var("XDG_DATA_HOME", &data);
    let ca_path = workdir.join("fixture-ca.pem");
    write_private(&ca_path, descriptor.tls.ca_pem.as_bytes()).ok()?;
    write_private(
        &config.join("mila").join("connections.json"),
        fixture_connection_profile(descriptor, &ca_path).as_bytes(),
    )
    .ok()?;
    Some(ca_path)
}

fn print_report(report: &JourneyReport) -> glib::ExitCode {
    println!(
        "{}",
        serde_json::to_string(report).expect("report serializes")
    );
    if report.ok {
        glib::ExitCode::SUCCESS
    } else {
        glib::ExitCode::FAILURE
    }
}

fn descendants(widget: &gtk::Widget, found: &mut Vec<gtk::Widget>) {
    let mut child = widget.first_child();
    while let Some(current) = child {
        found.push(current.clone());
        descendants(&current, found);
        child = current.next_sibling();
    }
}

fn page(state: &NativeState, page: Page) -> Option<gtk::Widget> {
    state
        .links
        .borrow()
        .as_ref()
        .and_then(|targets| targets.stack.child_by_name(page.name()))
}

fn widgets<W: IsA<gtk::Widget>>(root: &gtk::Widget) -> Vec<W> {
    let mut found = Vec::new();
    descendants(root, &mut found);
    found
        .into_iter()
        .filter_map(|widget| widget.downcast::<W>().ok())
        .collect()
}

fn click(state: &NativeState, on: Page, label: &str) -> bool {
    let Some(root) = page(state, on) else {
        return false;
    };
    match widgets::<Button>(&root)
        .into_iter()
        .find(|button| button.label().as_deref() == Some(label))
    {
        Some(button) => {
            button.emit_clicked();
            true
        }
        None => false,
    }
}

fn status_text(state: &NativeState) -> String {
    state
        .status
        .borrow()
        .as_ref()
        .map(|label| label.text().to_string())
        .unwrap_or_default()
}

enum Stage {
    SignIn,
    AwaitSignedIn(Instant),
    Machines,
    SshKeys,
    Terminal,
    AwaitMarker(Instant, String),
    Sever,
    AwaitReconnect(Instant, u64),
    SignOut,
}

struct Script {
    descriptor: JourneyDescriptor,
    approver: Rc<FixtureApprover>,
    report: JourneyReport,
    stage: Option<Stage>,
}

impl Script {
    /// Advances one stage; `None` ends the journey.
    fn step(&mut self, state: &NativeState) -> Option<Stage> {
        let stage = self.stage.take()?;
        let report = &mut self.report;
        match stage {
            Stage::SignIn => {
                if let Some(targets) = state.links.borrow().as_ref() {
                    targets
                        .deployment
                        .set_text(&self.descriptor.deployment.host);
                }
                if !click(
                    state,
                    Page::SignIn,
                    &strings::text(strings::Message::SignInStart),
                ) {
                    report.record("gtk_sign_in", false, "button_missing");
                    return None;
                }
                Some(Stage::AwaitSignedIn(Instant::now()))
            }
            Stage::AwaitSignedIn(started) => {
                let driver = state.driver.borrow();
                let flow = driver.flow();
                if flow.phase == SignInPhase::SignedIn && state.session.borrow().is_authenticated()
                {
                    let code = if self.approver.opened() > 0 {
                        "approved"
                    } else {
                        "already"
                    };
                    report.record("gtk_sign_in", true, code);
                    return Some(Stage::Machines);
                }
                if self.approver.failed() {
                    report.record("gtk_sign_in", false, "approver_failed");
                    return None;
                }
                if !driver.is_active() {
                    report.record(
                        "gtk_sign_in",
                        false,
                        sign_in_failure_code(flow.phase, flow.failure),
                    );
                    return None;
                }
                if started.elapsed() > SIGN_IN_DEADLINE {
                    report.record("gtk_sign_in", false, "approval_timeout");
                    return None;
                }
                Some(Stage::AwaitSignedIn(started))
            }
            Stage::Machines => {
                let clicked = click(state, Page::Machines, "Refresh machines");
                let listed = clicked
                    && status_text(state)
                        .lines()
                        .any(|line| line.contains(&self.descriptor.seed.machine_name));
                report.record(
                    "gtk_machines",
                    listed,
                    if listed {
                        "seed_listed"
                    } else {
                        "seed_missing"
                    },
                );
                Some(Stage::SshKeys)
            }
            Stage::SshKeys => {
                let clicked = click(
                    state,
                    Page::Settings,
                    &strings::text(strings::Message::Refresh),
                );
                let own = clicked
                    && state.ssh_keys.borrow().status() == SshKeysStatus::Loaded
                    && state
                        .ssh_keys
                        .borrow()
                        .rows()
                        .iter()
                        .any(|row| row.this_device);
                report.record(
                    "gtk_ssh_keys",
                    own,
                    if own {
                        "device_key_listed"
                    } else {
                        "device_key_missing"
                    },
                );
                Some(Stage::Terminal)
            }
            Stage::Terminal => {
                let Some(root) = page(state, Page::Terminal) else {
                    report.record("gtk_terminal", false, "page_missing");
                    return Some(Stage::Sever);
                };
                if !click(
                    state,
                    Page::Terminal,
                    &strings::text(strings::Message::AttachTerminal),
                ) || state
                    .terminal
                    .borrow()
                    .as_ref()
                    .and_then(|surface| surface.live_generation())
                    .is_none()
                {
                    report.record("gtk_terminal", false, "attach_refused");
                    return Some(Stage::Sever);
                }
                let Some(marker) = mila_native_linux::adapter::new_request_id()
                    .map(|id| format!("mila-gtk-journey-{}", &id[8..20]))
                else {
                    report.record("gtk_terminal", false, "marker_unavailable");
                    return Some(Stage::Sever);
                };
                let input = widgets::<Entry>(&root)
                    .into_iter()
                    .find(|entry| entry.placeholder_text().as_deref() == Some("Terminal input"));
                let Some(input) = input else {
                    report.record("gtk_terminal", false, "input_missing");
                    return Some(Stage::Sever);
                };
                input.set_text(&format!("echo {marker}"));
                if !click(
                    state,
                    Page::Terminal,
                    &strings::text(strings::Message::TerminalSend),
                ) {
                    report.record("gtk_terminal", false, "send_missing");
                    return Some(Stage::Sever);
                }
                Some(Stage::AwaitMarker(Instant::now(), marker))
            }
            Stage::AwaitMarker(started, marker) => {
                let shown = page(state, Page::Terminal)
                    .map(|root| widgets::<TextView>(&root))
                    .unwrap_or_default()
                    .iter()
                    .any(|view| {
                        let buffer = view.buffer();
                        buffer
                            .text(&buffer.start_iter(), &buffer.end_iter(), false)
                            .lines()
                            .any(|line| line.trim() == marker)
                    });
                if shown {
                    report.record("gtk_terminal", true, "marker_seen");
                    return Some(Stage::Sever);
                }
                if started.elapsed() > STEP_DEADLINE {
                    report.record("gtk_terminal", false, "marker_timeout");
                    return Some(Stage::Sever);
                }
                Some(Stage::AwaitMarker(started, marker))
            }
            Stage::Sever => {
                let generation = state.driver.borrow().flow().generation;
                let probe = state
                    .session
                    .borrow()
                    .session()
                    .and_then(LiveSession::probe);
                let Some(probe) = probe else {
                    report.record("gtk_reconnect", false, "not_bound");
                    return Some(Stage::SignOut);
                };
                probe.sever();
                Some(Stage::AwaitReconnect(Instant::now(), generation))
            }
            Stage::AwaitReconnect(started, generation) => {
                let driver = state.driver.borrow();
                let flow = driver.flow();
                if flow.phase == SignInPhase::SignedIn
                    && flow.generation > generation
                    && state.session.borrow().is_authenticated()
                {
                    report.record("gtk_reconnect", true, "reestablished");
                    return Some(Stage::SignOut);
                }
                if !driver.is_active() {
                    report.record(
                        "gtk_reconnect",
                        false,
                        sign_in_failure_code(flow.phase, flow.failure),
                    );
                    return Some(Stage::SignOut);
                }
                if started.elapsed() > RECONNECT_DEADLINE {
                    report.record("gtk_reconnect", false, "reconnect_timeout");
                    return Some(Stage::SignOut);
                }
                Some(Stage::AwaitReconnect(started, generation))
            }
            Stage::SignOut => {
                let clicked = click(
                    state,
                    Page::SignIn,
                    &strings::text(strings::Message::SignInSignOut),
                );
                let released = clicked
                    && !state.session.borrow().is_authenticated()
                    && state.terminal.borrow().is_none()
                    && state.ssh_keys.borrow().status() == SshKeysStatus::SignInRequired
                    && state.driver.borrow().flow().phase == SignInPhase::SignedOut;
                report.record(
                    "gtk_sign_out",
                    released,
                    if released { "released" } else { "retained" },
                );
                None
            }
        }
    }
}

fn run_window(descriptor: &JourneyDescriptor, workdir: &Path, ca_path: &Path) -> glib::ExitCode {
    if adw::init().is_err() {
        let mut report = JourneyReport::new();
        report.record("gtk_environment", false, "display_unavailable");
        return print_report(&report);
    }
    let approver = Rc::new(FixtureApprover::new(descriptor, workdir, ca_path));
    let state = NativeState::with_browser(approver.clone());
    let script = Rc::new(RefCell::new(Script {
        descriptor: descriptor.clone(),
        approver,
        report: JourneyReport::new(),
        stage: Some(Stage::SignIn),
    }));
    let finished = Rc::new(Cell::new(false));
    let application = adw::Application::builder()
        .application_id(super::APPLICATION_ID)
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    {
        let state = state.clone();
        let script = script.clone();
        let finished = finished.clone();
        application.connect_activate(move |app| {
            state.ensure_window(app).present();
            let state = state.clone();
            let script = script.clone();
            let finished = finished.clone();
            let app = app.clone();
            glib::timeout_add_local(TICK, move || {
                let next = script.borrow_mut().step(&state);
                let done = next.is_none();
                script.borrow_mut().stage = next;
                if done {
                    finished.set(true);
                    app.quit();
                    glib::ControlFlow::Break
                } else {
                    glib::ControlFlow::Continue
                }
            });
        });
    }
    application.run_with_args::<&str>(&[]);
    state.drop_authority();
    let mut report = std::mem::take(&mut script.borrow_mut().report);
    if !finished.get() {
        report.record("gtk_window", false, "closed_early");
    }
    print_report(&report)
}
