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

use super::strings::Message as M;
use super::{pages, strings, NativeState};
use adw::prelude::*;
use gtk::{glib, Box, Button, Entry, TextView};
use mila_native_linux::deep_link::Page;
use mila_native_linux::device_key::write_private;
use mila_native_linux::journey::{
    create_private_workdir, fixture_connection_profile, guest_echo, guest_size_answer,
    read_descriptor, remove_journey_machine, shows_line, sign_in_failure_code, terminal_passed,
    FixtureApprover, FixtureHook, JourneyDescriptor, JourneyReport, FIXTURE_ANSWER,
    GUEST_BOOT_DEADLINE, GUEST_RESIZE, HOOK_MAX_SECONDS, JOURNEY_PROMPT,
};
use mila_native_linux::journey_checks::{
    check_answered, check_created, check_deleted, check_desired, check_plan_approved,
    check_prompted, check_resize_created, check_resized, check_resumed, check_share, check_web,
    first_thread, load_thread_controls, machine_named, refusal_code, web_endpoint, Check,
    PageContext, CREATE_SIZE, RESIZE_SIZE,
};
use mila_native_linux::machine_view::project_snapshot;
use mila_native_linux::session::{LiveSession, SessionError, SignInPhase};
use mila_native_linux::ssh_keys_view::SshKeysStatus;
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

const TICK: Duration = Duration::from_millis(200);
/// Attach presses to retry, one per tick, when no server answer arrived.
const TERMINAL_ATTEMPTS: u32 = 50;
/// Covers one approver call (up to `HOOK_MAX_SECONDS`) plus polling.
const SIGN_IN_DEADLINE: Duration = Duration::from_secs(HOOK_MAX_SECONDS + 90);
const STEP_DEADLINE: Duration = Duration::from_secs(30);
const RECONNECT_DEADLINE: Duration = Duration::from_secs(90);
const PAGE_STEP_DEADLINE: Duration = Duration::from_secs(60);

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
    let Ok(workdir) = create_private_workdir(workdir) else {
        eprintln!("mila-native-linux: work directory must be new and private");
        return glib::ExitCode::from(2);
    };
    let code = if let Some(ca_path) = prepare_environment(&descriptor, &workdir) {
        run_window(&descriptor, &workdir, &ca_path)
    } else {
        let mut report = JourneyReport::new();
        report.record("gtk_environment", false, "unwritable");
        print_report(&report)
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
        two_deployment_profiles(descriptor, &ca_path)?.as_bytes(),
    )
    .ok()?;
    Some(ca_path)
}

/// The second deployment the picker steps add: the fixture under its IP
/// literal, which its certificate also names. It is a separate list entry,
/// connection profile, trust pin and sign-in against the same backend.
const SECOND_DEPLOYMENT: &str = "127.0.0.1";

/// The fixture's connection profile plus one for [`SECOND_DEPLOYMENT`] on
/// the same ports and CA.
fn two_deployment_profiles(descriptor: &JourneyDescriptor, ca_path: &Path) -> Option<String> {
    let mut document: serde_json::Value =
        serde_json::from_str(&fixture_connection_profile(descriptor, ca_path)).ok()?;
    let profiles = document.get_mut("profiles")?.as_array_mut()?;
    let mut second = profiles.first()?.clone();
    *second.get_mut("host")? = serde_json::Value::from(SECOND_DEPLOYMENT);
    profiles.push(second);
    Some(document.to_string())
}

/// Presses `host`'s Open button in the deployment list.
fn open_deployment(state: &NativeState, host: &str) -> bool {
    let Some(root) = page(state, Page::Deployments) else {
        return false;
    };
    let open = strings::text(strings::Message::DeploymentOpen);
    widgets::<Box>(&root)
        .into_iter()
        .find(|row| {
            row.first_child()
                .and_then(|child| child.downcast::<gtk::Label>().ok())
                .is_some_and(|label| label.text() == host)
        })
        .and_then(|row| {
            widgets::<Button>(row.upcast_ref())
                .into_iter()
                .find(|button| button.label().as_deref() == Some(open.as_str()))
        })
        .map(|button| button.emit_clicked())
        .is_some()
}

/// Types `host` into the deployment field and presses Add deployment.
fn add_deployment(state: &NativeState, host: &str) -> bool {
    if let Some(targets) = state.links.borrow().as_ref() {
        targets.deployment.set_text(host);
    }
    click(
        state,
        Page::Deployments,
        &strings::text(strings::Message::DeploymentAddAndSelect),
    )
}

/// The persisted deployment hosts and the selected one.
fn deployment_state(state: &NativeState) -> (Vec<String>, Option<String>) {
    state
        .deployment_list()
        .map(|list| {
            let rows = list.rows();
            let selected = rows
                .iter()
                .find(|row| row.selected)
                .map(|row| row.host.clone());
            (rows.into_iter().map(|row| row.host).collect(), selected)
        })
        .unwrap_or_default()
}

/// No authority survives a deployment switch: no session, sign-in
/// generation, listing, terminal or SSH-key rows.
// See the `linux-authority-drop-on-switch` contract in CONTRACTS.
fn released(state: &NativeState) -> bool {
    !state.session.borrow().is_authenticated()
        && state.machine_listing.borrow().is_none()
        && state.terminal.borrow().is_none()
        && state.ssh_keys.borrow().status() == SshKeysStatus::SignInRequired
        && state.driver.borrow().flow().phase == SignInPhase::SignedOut
}

fn print_report(report: &JourneyReport) -> glib::ExitCode {
    #[expect(
        clippy::expect_used,
        reason = "JourneyReport derives Serialize over integers, booleans and strings only, which serde_json always encodes"
    )]
    let encoded = serde_json::to_string(report).expect("report serializes");
    println!("{encoded}");
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

fn section(state: &NativeState, on: Page, name: &str) -> Option<gtk::Widget> {
    let root = page(state, on)?;
    let mut found = Vec::new();
    descendants(&root, &mut found);
    found
        .into_iter()
        .find(|widget| widget.widget_name() == name)
}

/// Presses the first (or, for a confirmation bar, the last) visible button
/// labelled `label` inside a page section.
fn press_in(state: &NativeState, on: Page, name: &str, label: &str, last: bool) -> bool {
    let Some(root) = section(state, on, name) else {
        return false;
    };
    let buttons = widgets::<Button>(&root)
        .into_iter()
        .filter(|button| button.label().as_deref() == Some(label) && button.is_visible());
    let button = if last {
        buttons.last()
    } else {
        buttons.into_iter().next()
    };
    match button {
        Some(button) => {
            button.emit_clicked();
            true
        }
        None => false,
    }
}

fn press(state: &NativeState, on: Page, name: &str, message: M) -> Result<(), &'static str> {
    press_in(state, on, name, &strings::text(message), false)
        .then_some(())
        .ok_or("control_missing")
}

fn confirm(state: &NativeState, message: M) -> Result<(), &'static str> {
    press_in(
        state,
        Page::Machines,
        pages::MACHINE_LIFECYCLE,
        &strings::text(message),
        true,
    )
    .then_some(())
    .ok_or("confirm_missing")
}

/// Types `text` into the entry whose placeholder is `placeholder`.
fn fill(
    state: &NativeState,
    on: Page,
    name: &str,
    placeholder: M,
    text: &str,
) -> Result<(), &'static str> {
    let root = section(state, on, name).ok_or("control_missing")?;
    let placeholder = strings::text(placeholder);
    let entry = widgets::<Entry>(&root)
        .into_iter()
        .find(|entry| entry.placeholder_text().as_deref() == Some(placeholder.as_str()))
        .ok_or("field_missing")?;
    entry.set_text(text);
    Ok(())
}

fn labels_in(state: &NativeState, on: Page, name: &str) -> Vec<String> {
    let Some(root) = section(state, on, name) else {
        return Vec::new();
    };
    let mut texts: Vec<String> = widgets::<gtk::Label>(&root)
        .into_iter()
        .map(|label| label.text().to_string())
        .collect();
    texts.extend(
        widgets::<Button>(&root)
            .into_iter()
            .filter_map(|button| button.label().map(|label| label.to_string())),
    );
    texts
}

/// Runs a check on the window's bound session.
fn live_check(state: &NativeState, check: impl FnOnce(&mut LiveSession) -> Check) -> Check {
    match state.with_live(|live| Ok(check(live))) {
        Some(Ok(check)) => check,
        Some(Err(_)) => Check::Fail("session_lost"),
        None => Check::Fail("not_bound"),
    }
}

/// State carried between page steps.
struct PageWork {
    context: PageContext,
    hook: FixtureHook,
    hook_missing: bool,
    revision: u64,
    seed_name: String,
    /// Whether the pause step took effect.
    paused: bool,
}

impl PageWork {
    fn machine(&self) -> String {
        self.context.machine.clone().unwrap_or_default()
    }

    fn seed(&self) -> String {
        self.context.seed_machine.clone().unwrap_or_default()
    }

    /// Asks the fixture to observe the journey machine, as the provisioner
    /// would; a missing hook is recorded once.
    fn observe(&mut self, report: &mut JourneyReport) {
        if let Some(machine) = self.context.machine.as_deref() {
            if !self.hook.observe(machine) && !self.hook_missing {
                self.hook_missing = true;
                report.record("gtk_fixture_observe", false, "fixture_hook_unavailable");
            }
        }
    }
}

type Press = std::boxed::Box<
    dyn Fn(&NativeState, &mut PageWork, &mut JourneyReport) -> Result<(), &'static str>,
>;
type Probe = std::boxed::Box<dyn Fn(&NativeState, &mut PageWork) -> Check>;

/// One GTK page step: press the window's controls, then poll the backend
/// effect through the window's session until the deadline.
struct PageStep {
    name: &'static str,
    press: Press,
    check: Probe,
}

fn step(
    name: &'static str,
    press: impl Fn(&NativeState, &mut PageWork, &mut JourneyReport) -> Result<(), &'static str>
        + 'static,
    check: impl Fn(&NativeState, &mut PageWork) -> Check + 'static,
) -> PageStep {
    PageStep {
        name,
        press: std::boxed::Box::new(press),
        check: std::boxed::Box::new(check),
    }
}

fn select_machine(state: &NativeState, id: &str) -> Result<(), &'static str> {
    fill(state, Page::Machines, pages::MACHINE_LIST, M::MachineId, id)
}

fn select_thread(state: &NativeState, work: &PageWork) -> Result<(), &'static str> {
    let thread = work.context.thread.clone().ok_or("no_thread")?;
    fill(
        state,
        Page::Threads,
        pages::THREAD_LIST,
        M::MachineId,
        &thread,
    )?;
    press(state, Page::Threads, pages::THREAD_DETAIL, M::TabInfo)
}

fn lifecycle(name: &'static str, message: M, desired: &'static str) -> PageStep {
    step(
        name,
        move |state, work, report| {
            work.observe(report);
            select_machine(state, &work.machine())?;
            press(state, Page::Machines, pages::MACHINE_LIFECYCLE, message)
        },
        move |state, work| {
            live_check(state, |live| {
                check_desired(live, &work.context, desired, desired)
            })
        },
    )
}

/// Every page step, in the order the fixture admits them.
#[expect(
    clippy::too_many_lines,
    reason = "one linear table of every fixture page step, in admission order"
)]
fn page_steps() -> VecDeque<PageStep> {
    let mut steps = VecDeque::new();
    steps.push_back(step(
        "gtk_machines",
        |state, _, _| press(state, Page::Machines, pages::MACHINE_LIST, M::Refresh),
        |state, work| {
            if labels_in(state, Page::Machines, pages::MACHINE_LIST).contains(&work.seed_name) {
                Check::Pass("seed_listed")
            } else {
                Check::Fail("seed_missing")
            }
        },
    ));
    steps.push_back(step(
        "gtk_machine_detail",
        |state, work, _| {
            select_machine(state, &work.seed())?;
            press(state, Page::Machines, pages::MACHINE_LIFECYCLE, M::TabInfo)
        },
        |state, work| {
            if labels_in(state, Page::Machines, pages::MACHINE_LIFECYCLE).contains(&work.seed_name)
            {
                Check::Pass("detail_shown")
            } else {
                Check::Fail("detail_missing")
            }
        },
    ));
    steps.push_back(step(
        "gtk_sharing_add",
        |state, work, _| {
            select_machine(state, &work.seed())?;
            let principal = work.context.share_principal.clone();
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SHARING,
                M::SharingEmail,
                &principal,
            )?;
            press(state, Page::Machines, pages::MACHINE_SHARING, M::SharingAdd)
        },
        |state, work| {
            live_check(state, |live| {
                check_share(live, &work.context, Some("viewer"))
            })
        },
    ));
    steps.push_back(step(
        "gtk_sharing_remove",
        |state, _, _| {
            press(
                state,
                Page::Machines,
                pages::MACHINE_SHARING,
                M::SharingRemove,
            )?;
            confirm(state, M::SharingRemove)
        },
        |state, work| live_check(state, |live| check_share(live, &work.context, None)),
    ));
    steps.push_back(step(
        "gtk_web_show",
        |state, _, _| press(state, Page::Machines, pages::MACHINE_WEB, M::Refresh),
        |state, work| {
            let shown = labels_in(state, Page::Machines, pages::MACHINE_WEB);
            let visible = [M::WebPublic, M::WebPrivate]
                .iter()
                .any(|message| shown.contains(&strings::text(*message)));
            let seed = work.seed();
            match state.with_live(|live| web_endpoint(live, &seed)) {
                Some(Ok(endpoint)) if visible => {
                    work.revision = endpoint.policy_revision;
                    Check::Pass("loaded")
                }
                Some(Ok(_) | Err(SessionError::Busy)) => Check::Wait,
                _ => Check::Fail("read_refused"),
            }
        },
    ));
    for (name, message, public) in [
        ("gtk_web_public", M::WebPublic, true),
        ("gtk_web_private", M::WebPrivate, false),
    ] {
        steps.push_back(step(
            name,
            move |state, work, _| {
                let seed = work.seed();
                if let Some(Ok(endpoint)) = state.with_live(|live| web_endpoint(live, &seed)) {
                    work.revision = endpoint.policy_revision;
                }
                press(state, Page::Machines, pages::MACHINE_WEB, M::Refresh)?;
                press(state, Page::Machines, pages::MACHINE_WEB, message)
            },
            move |state, work| {
                let revision = work.revision;
                live_check(state, |live| {
                    check_web(live, &work.context, public, revision)
                })
            },
        ));
    }
    steps.push_back(step(
        "gtk_lifecycle_create",
        |state, work, _| {
            let (cpu, memory, disk) = CREATE_SIZE;
            let name = work.context.machine_name.clone();
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::MachineName,
                &name,
            )?;
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::KvCpu,
                &cpu.to_string(),
            )?;
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::MemoryFieldMib,
                &memory.to_string(),
            )?;
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::DiskFieldGib,
                &disk.to_string(),
            )?;
            press(state, Page::Machines, pages::MACHINE_SIZE, M::ActionCreate)
        },
        |state, work| live_check(state, |live| check_created(live, &mut work.context)),
    ));
    steps.push_back(lifecycle("gtk_lifecycle_stop", M::ActionStop, "stopped"));
    steps.push_back(lifecycle("gtk_lifecycle_start", M::ActionStart, "running"));
    let mut pause = lifecycle("gtk_lifecycle_pause", M::ActionPause, "paused");
    let check = pause.check;
    pause.check = std::boxed::Box::new(move |state, work| {
        let outcome = check(state, work);
        if matches!(outcome, Check::Pass(_)) {
            work.paused = true;
        }
        outcome
    });
    steps.push_back(pause);
    steps.push_back(step(
        "gtk_lifecycle_resume",
        |state, work, _| {
            select_machine(state, &work.machine())?;
            press(
                state,
                Page::Machines,
                pages::MACHINE_LIFECYCLE,
                M::ActionResume,
            )
        },
        |state, work| {
            let key = pages::action_key("resume", &work.machine());
            let request = state.requests.borrow().settled(&key).map(str::to_owned);
            let paused = work.paused;
            live_check(state, |live| {
                check_resumed(live, &work.context, request.as_deref(), paused)
            })
        },
    ));
    steps.push_back(step(
        "gtk_lifecycle_delete",
        |state, work, _| {
            select_machine(state, &work.machine())?;
            press(
                state,
                Page::Machines,
                pages::MACHINE_LIFECYCLE,
                M::ActionDelete,
            )?;
            confirm(state, M::ActionDelete)
        },
        |state, work| live_check(state, |live| check_deleted(live, &work.context)),
    ));
    // Resize a second created machine: a pinned resize keeps its machine
    // busy, so it runs after the other lifecycle steps on its own machine.
    steps.push_back(step(
        "gtk_lifecycle_resize_create",
        |state, work, _| {
            // The deletion holds capacity until the stand-in observes it.
            if let Some(machine) = work.context.machine.as_deref() {
                work.hook.observe(machine);
            }
            let (cpu, memory, disk) = CREATE_SIZE;
            let name = work.context.resize_machine_name.clone();
            for (field, value) in [
                (M::MachineName, name),
                (M::KvCpu, cpu.to_string()),
                (M::MemoryFieldMib, memory.to_string()),
                (M::DiskFieldGib, disk.to_string()),
            ] {
                fill(state, Page::Machines, pages::MACHINE_SIZE, field, &value)?;
            }
            press(state, Page::Machines, pages::MACHINE_SIZE, M::ActionCreate)
        },
        |state, work| live_check(state, |live| check_resize_created(live, &mut work.context)),
    ));
    steps.push_back(step(
        "gtk_lifecycle_resize",
        |state, work, report| {
            let resize_machine = work.context.resize_machine.clone().unwrap_or_default();
            if !work.hook.observe(&resize_machine) && !work.hook_missing {
                work.hook_missing = true;
                report.record("gtk_fixture_observe", false, "fixture_hook_unavailable");
            }
            let (cpu, memory, disk) = RESIZE_SIZE;
            select_machine(state, &resize_machine)?;
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::KvCpu,
                &cpu.to_string(),
            )?;
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::MemoryFieldMib,
                &memory.to_string(),
            )?;
            fill(
                state,
                Page::Machines,
                pages::MACHINE_SIZE,
                M::DiskFieldGib,
                &disk.to_string(),
            )?;
            press(state, Page::Machines, pages::MACHINE_SIZE, M::ActionResize)
        },
        |state, work| {
            let (cpu, memory, disk) = RESIZE_SIZE;
            let resize_machine = work.context.resize_machine.clone().unwrap_or_default();
            let key = pages::resize_key(&resize_machine, Some(cpu), Some(memory), Some(disk));
            let request = state.requests.borrow().settled(&key).map(str::to_owned);
            live_check(state, |live| {
                check_resized(live, &work.context, request.as_deref())
            })
        },
    ));
    steps.push_back(step(
        "gtk_threads_list",
        |state, work, _| {
            work.context.thread = work.hook.create_thread();
            if work.context.thread.is_none() {
                let seed = work.context.seed_machine.clone();
                work.context.thread = state
                    .with_live(|live| first_thread(live, seed.as_deref()))
                    .and_then(Result::ok)
                    .flatten();
            }
            work.context.thread.as_ref().ok_or("no_thread")?;
            press(state, Page::Threads, pages::THREAD_LIST, M::Refresh)
        },
        |state, work| {
            let thread = work.context.thread.clone().unwrap_or_default();
            let rows = labels_in(state, Page::Threads, pages::THREAD_LIST).len();
            let listed = state.with_live(|live| {
                live.thread_action(None, "thread ls", None, None, None)
                    .map(|bytes| {
                        mila_native_linux::porsche_results::decode_thread_rows(&bytes)
                            .is_ok_and(|rows| rows.iter().any(|row| row.id == thread))
                    })
            });
            match listed {
                Some(Ok(true)) if rows > 1 => Check::Pass("listed"),
                Some(Ok(_) | Err(SessionError::Busy)) => Check::Wait,
                _ => Check::Fail("read_refused"),
            }
        },
    ));
    steps.push_back(step(
        "gtk_threads_prompt",
        |state, work, _| {
            select_thread(state, work)?;
            match live_check(state, |live| load_thread_controls(live, &mut work.context)) {
                Check::Pass(_) => {}
                Check::Fail(code) => return Err(code),
                Check::Wait => return Err("thread_missing"),
            }
            fill(
                state,
                Page::Threads,
                pages::THREAD_DETAIL,
                M::ThreadComposerHint,
                JOURNEY_PROMPT,
            )?;
            press(state, Page::Threads, pages::THREAD_DETAIL, M::ThreadSend)
        },
        |state, work| live_check(state, |live| check_prompted(live, &work.context)),
    ));
    steps.push_back(step(
        "gtk_threads_answer",
        |state, work, _| {
            let thread = work.context.thread.clone().ok_or("no_thread")?;
            let asked = work.hook.question(&thread);
            let _ = live_check(state, |live| load_thread_controls(live, &mut work.context));
            if work.context.question.is_none() {
                work.context.question = asked;
            }
            work.context
                .question
                .as_ref()
                .ok_or("no_pending_question")?;
            select_thread(state, work)?;
            fill(
                state,
                Page::Threads,
                pages::THREAD_DETAIL,
                M::ThreadAnswerHint,
                FIXTURE_ANSWER,
            )?;
            press(
                state,
                Page::Threads,
                pages::THREAD_DETAIL,
                M::ThreadAnswerSend,
            )
        },
        |state, work| live_check(state, |live| check_answered(live, &work.context)),
    ));
    steps.push_back(step(
        "gtk_threads_plan_approve",
        |state, work, _| {
            let thread = work.context.thread.clone().ok_or("no_thread")?;
            let proposed = work.hook.proposal(&thread);
            let _ = live_check(state, |live| load_thread_controls(live, &mut work.context));
            if work.context.plan.is_none() {
                work.context.plan = proposed;
            }
            work.context.plan.as_ref().ok_or("no_pending_plan")?;
            select_thread(state, work)?;
            press(
                state,
                Page::Threads,
                pages::THREAD_DETAIL,
                M::ThreadPlanApprove,
            )
        },
        |state, work| live_check(state, |live| check_plan_approved(live, &work.context)),
    ));
    steps
}

enum Stage {
    Deployments,
    SignIn,
    AwaitSignedIn(Instant),
    SshKeys,
    Pages,
    Terminal,
    AwaitMarker(Instant, String),
    /// The guest-backed PTY steps on the fixture's terminal machine.
    Guest(Guest, Instant),
    LoseOnAction,
    AwaitReconnect(Instant, u64),
    /// Opens `host` in the deployment list, then signs in to it.
    Switch(Switch),
    AwaitSwitched(Switch, Instant, u32),
    SignOut,
}

/// One guest-backed terminal step; each carries the echo marker after open.
#[derive(Clone)]
enum Guest {
    Open,
    Echo(String),
    Resize(String),
    Replay(String),
    Kill,
    /// Marshall confirms a kill asynchronously: a named Attach must come to
    /// be refused, or its stream must end within a few seconds of opening.
    Closing(Option<Instant>),
}

impl Guest {
    const STEPS: [&'static str; 5] = [
        "gtk_terminal_guest_open",
        "gtk_terminal_guest_echo",
        "gtk_terminal_guest_resize",
        "gtk_terminal_guest_replay",
        "gtk_terminal_guest_kill",
    ];

    const fn index(&self) -> usize {
        match self {
            Self::Open => 0,
            Self::Echo(_) => 1,
            Self::Resize(_) => 2,
            Self::Replay(_) => 3,
            Self::Kill | Self::Closing(_) => 4,
        }
    }
}

/// The terminal page's session, columns, rows and input fields.
struct TerminalFields {
    session: Entry,
    columns: Entry,
    rows: Entry,
    input: Entry,
}

fn terminal_fields(state: &NativeState) -> Option<TerminalFields> {
    let root = page(state, Page::Terminal)?;
    let entries = widgets::<Entry>(&root);
    let by_hint = |message| {
        let hint = strings::text(message);
        entries
            .iter()
            .find(|entry| entry.placeholder_text().as_deref() == Some(hint.as_str()))
            .cloned()
    };
    let session = by_hint(strings::Message::TerminalSessionHint)?;
    let columns = session.next_sibling()?.downcast::<Entry>().ok()?;
    let rows = columns.next_sibling()?.downcast::<Entry>().ok()?;
    let input = by_hint(strings::Message::TerminalInputHint)?;
    Some(TerminalFields {
        session,
        columns,
        rows,
        input,
    })
}

/// The terminal page's rendered text.
fn terminal_text(state: &NativeState) -> String {
    page(state, Page::Terminal)
        .map(|root| widgets::<TextView>(&root))
        .unwrap_or_default()
        .iter()
        .map(|view| {
            let buffer = view.buffer();
            buffer
                .text(&buffer.start_iter(), &buffer.end_iter(), false)
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn terminal_live(state: &NativeState) -> bool {
    state
        .terminal
        .borrow()
        .as_ref()
        .and_then(mila_native_linux::terminal_surface::TerminalSurface::live_generation)
        .is_some()
}

/// Presses the last button labelled `message` on the terminal page: the
/// confirmation bar's button follows the action row's.
fn click_last(state: &NativeState, message: strings::Message) -> bool {
    let label = strings::text(message);
    page(state, Page::Terminal)
        .and_then(|root| {
            widgets::<Button>(&root)
                .into_iter()
                .filter(|button| button.label().as_deref() == Some(label.as_str()))
                .last()
        })
        .map(|button| button.emit_clicked())
        .is_some()
}

/// One deployment switch step.
#[derive(Clone, Copy)]
struct Switch {
    name: &'static str,
    host: Target,
    next: Option<Target>,
}

impl Switch {
    /// The fixture's trust document names one management host, so signing
    /// in to its IP-literal alias must fail closed; the fixture itself must
    /// sign in again.
    fn host_bound(self) -> bool {
        matches!(self.host, Target::Second)
    }
}

#[derive(Clone, Copy)]
enum Target {
    Fixture,
    Second,
}

struct Script {
    descriptor: JourneyDescriptor,
    approver: Rc<FixtureApprover>,
    report: JourneyReport,
    stage: Option<Stage>,
    work: PageWork,
    steps: VecDeque<PageStep>,
    current: Option<(PageStep, Instant)>,
    /// Attach presses that failed without a server answer, such as while
    /// the heartbeat probe held the session.
    terminal_attempts: u32,
}

/// Switch to the second deployment, then back to the fixture.
const SWITCH_AWAY: Switch = Switch {
    name: "gtk_deployment_switch",
    host: Target::Second,
    next: Some(Target::Fixture),
};

impl Script {
    /// After the guestless refusal check: the guest PTY steps when the
    /// fixture runs its terminal machine, then loss detection.
    fn after_terminal(&self) -> Stage {
        if self.descriptor.seed.terminal_machine_id.is_some() {
            Stage::Guest(Guest::Open, Instant::now())
        } else {
            Stage::LoseOnAction
        }
    }

    /// Records `code` for `step` and every guest step after it.
    fn guest_failed(&mut self, step: &Guest, code: &'static str) -> Stage {
        for name in &Guest::STEPS[step.index()..] {
            self.report.record(name, false, code);
        }
        Stage::LoseOnAction
    }

    // See the `linux-journey-guest-terminal` contract in CONTRACTS.
    #[expect(
        clippy::too_many_lines,
        reason = "one match arm per guest terminal step keeps the five steps in report order"
    )]
    fn guest_tick(&mut self, state: &NativeState, step: Guest, started: Instant) -> Option<Stage> {
        let machine = self
            .descriptor
            .seed
            .terminal_machine_id
            .clone()
            .unwrap_or_default();
        let Some(fields) = terminal_fields(state) else {
            return Some(self.guest_failed(&step, "fields_missing"));
        };
        let attach = || {
            click(
                state,
                Page::Terminal,
                &strings::text(strings::Message::AttachTerminal),
            )
        };
        let send = |line: &str| {
            fields.input.set_text(line.trim_end_matches('\r'));
            click(
                state,
                Page::Terminal,
                &strings::text(strings::Message::TerminalSend),
            )
        };
        let refusal = || {
            state
                .session
                .borrow()
                .session()
                .and_then(LiveSession::last_refusal)
        };
        match step {
            Guest::Open => {
                // Only terminal operations run on this machine. An empty
                // session field makes Attach open the account's session.
                if select_machine(state, &machine).is_err() {
                    return Some(self.guest_failed(&step, "machine_field_missing"));
                }
                fields.session.set_text("");
                fields.columns.set_text("100");
                fields.rows.set_text("30");
                if attach() && terminal_live(state) && !fields.session.text().is_empty() {
                    let Some(marker) = mila_native_linux::adapter::new_request_id()
                        .and_then(|id| id.get(8..20).map(|suffix| format!("mila-gtk-{suffix}")))
                    else {
                        return Some(self.guest_failed(&step, "marker_unavailable"));
                    };
                    self.report.record(Guest::STEPS[0], true, "attached");
                    let (typed, _) = guest_echo(&marker);
                    if !send(&typed) {
                        return Some(self.guest_failed(&Guest::Echo(marker), "send_missing"));
                    }
                    return Some(Stage::Guest(Guest::Echo(marker), Instant::now()));
                }
                // A just-booted guest answers temporarily_unavailable.
                match refusal().as_deref() {
                    Some("temporarily_unavailable") | None
                        if started.elapsed() < GUEST_BOOT_DEADLINE =>
                    {
                        Some(Stage::Guest(Guest::Open, started))
                    }
                    other => Some(self.guest_failed(&step, refusal_code(other))),
                }
            }
            Guest::Echo(marker) => {
                let (_, echoed) = guest_echo(&marker);
                if shows_line(&terminal_text(state), &echoed) {
                    self.report.record(Guest::STEPS[1], true, "output_seen");
                    let (columns, rows) = GUEST_RESIZE;
                    fields.columns.set_text(&columns.to_string());
                    fields.rows.set_text(&rows.to_string());
                    let resized = click(
                        state,
                        Page::Terminal,
                        &strings::text(strings::Message::TerminalResize),
                    );
                    if !resized || !send("stty size") {
                        return Some(self.guest_failed(&Guest::Resize(marker), "resize_missing"));
                    }
                    return Some(Stage::Guest(Guest::Resize(marker), Instant::now()));
                }
                Some(self.guest_wait(Guest::Echo(marker), started))
            }
            Guest::Resize(marker) => {
                if shows_line(&terminal_text(state), &guest_size_answer()) {
                    self.report.record(Guest::STEPS[2], true, "resized");
                    // Detach drops this device's channel and viewport; the
                    // named Attach must bring the earlier output back.
                    let detached = click(
                        state,
                        Page::Terminal,
                        &strings::text(strings::Message::TerminalDetach),
                    ) && state.terminal.borrow().is_none()
                        && !shows_line(&terminal_text(state), &guest_echo(&marker).1);
                    if !detached || fields.session.text().is_empty() || !attach() {
                        return Some(self.guest_failed(&Guest::Replay(marker), "detach_failed"));
                    }
                    return Some(Stage::Guest(Guest::Replay(marker), Instant::now()));
                }
                Some(self.guest_wait(Guest::Resize(marker), started))
            }
            Guest::Replay(marker) => {
                if shows_line(&terminal_text(state), &guest_echo(&marker).1) {
                    self.report.record(Guest::STEPS[3], true, "replayed");
                    return Some(Stage::Guest(Guest::Kill, Instant::now()));
                }
                Some(self.guest_wait(Guest::Replay(marker), started))
            }
            Guest::Closing(opened) => self.guest_closing(state, opened, started),
            Guest::Kill => {
                // Close, confirm, then a named Attach must be refused.
                let closed = click(
                    state,
                    Page::Terminal,
                    &strings::text(strings::Message::TerminalClose),
                ) && click_last(state, strings::Message::TerminalClose)
                    && status_text(state) == strings::text(strings::Message::TerminalEnded);
                if !closed {
                    return Some(self.guest_failed(&step, "not_closed"));
                }
                Some(Stage::Guest(Guest::Closing(None), Instant::now()))
            }
        }
    }

    /// One poll of [`Guest::Closing`]; `opened` is when the current probe
    /// attach opened, if it did.
    fn guest_closing(
        &mut self,
        state: &NativeState,
        opened: Option<Instant>,
        started: Instant,
    ) -> Option<Stage> {
        let closed = |report: &mut JourneyReport| {
            report.record(Guest::STEPS[4], true, "closed");
            Some(Stage::LoseOnAction)
        };
        match opened {
            Some(_) if !terminal_live(state) => closed(&mut self.report),
            Some(at) if at.elapsed() < Duration::from_secs(3) => {
                Some(Stage::Guest(Guest::Closing(opened), started))
            }
            _ if started.elapsed() > PAGE_STEP_DEADLINE => {
                Some(self.guest_failed(&Guest::Kill, "still_attachable"))
            }
            _ => {
                if terminal_live(state) {
                    let _ = click(
                        state,
                        Page::Terminal,
                        &strings::text(strings::Message::TerminalDetach),
                    );
                }
                let attached = click(
                    state,
                    Page::Terminal,
                    &strings::text(strings::Message::AttachTerminal),
                ) && terminal_live(state);
                if attached {
                    Some(Stage::Guest(Guest::Closing(Some(Instant::now())), started))
                } else {
                    closed(&mut self.report)
                }
            }
        }
    }

    fn guest_wait(&mut self, step: Guest, started: Instant) -> Stage {
        if started.elapsed() > STEP_DEADLINE {
            return self.guest_failed(&step, "output_timeout");
        }
        Stage::Guest(step, started)
    }

    fn host(&self, target: Target) -> String {
        match target {
            Target::Fixture => self.descriptor.deployment.host.clone(),
            Target::Second => SECOND_DEPLOYMENT.to_owned(),
        }
    }

    /// Presses the next page step or polls the current one; `true` while
    /// page steps remain.
    fn page_tick(&mut self, state: &NativeState) -> bool {
        if self.current.is_none() {
            let Some(next) = self.steps.pop_front() else {
                if let Some(machine) = self.work.context.resize_machine.take() {
                    let hook = &self.work.hook;
                    let _ = state.with_live(|live| {
                        Ok::<_, SessionError>(remove_journey_machine(hook, live, &machine))
                    });
                }
                return false;
            };
            if let Some(label) = state.status.borrow().as_ref() {
                label.set_label("");
            }
            if let Err(code) = (next.press)(state, &mut self.work, &mut self.report) {
                self.report.record(next.name, false, code);
                return true;
            }
            self.current = Some((next, Instant::now()));
            return true;
        }
        let Some((current, started)) = self.current.take() else {
            return true;
        };
        // The page shows a refusal as soon as the deployment answers; report
        // its closed code instead of polling until the deadline.
        if status_text(state) == strings::text(M::RequestRefused) {
            let refusal = state
                .session
                .borrow()
                .session()
                .and_then(LiveSession::last_refusal);
            self.report
                .record(current.name, false, refusal_code(refusal.as_deref()));
            return true;
        }
        match (current.check)(state, &mut self.work) {
            Check::Pass(code) => {
                self.report.record(current.name, true, code);
            }
            Check::Fail(code) => {
                self.report.record(current.name, false, code);
            }
            Check::Wait if started.elapsed() > PAGE_STEP_DEADLINE => {
                self.report.record(current.name, false, "timeout");
            }
            Check::Wait => self.current = Some((current, started)),
        }
        true
    }

    /// Advances one stage; `None` ends the journey.
    #[expect(
        clippy::too_many_lines,
        reason = "one match arm per journey stage; ADR-0265 keeps mila-linux lint-only, so splitting is deferred"
    )]
    #[expect(
        clippy::similar_names,
        reason = "`stage` (journey position) and `state` (window state) are distinct domain terms"
    )]
    fn step(&mut self, state: &NativeState) -> Option<Stage> {
        let stage = self.stage.take()?;
        match stage {
            Stage::Deployments => {
                // Add both deployments through the picker, then select the
                // fixture again with its Open button.
                let fixture = self.descriptor.deployment.host.clone();
                let added =
                    add_deployment(state, &fixture) && add_deployment(state, SECOND_DEPLOYMENT);
                let (hosts, selected) = deployment_state(state);
                let both = added
                    && hosts.len() == 2
                    && hosts.contains(&fixture)
                    && selected.as_deref() == Some(SECOND_DEPLOYMENT);
                self.report.record(
                    "gtk_deployments_add",
                    both,
                    if both { "two_listed" } else { "not_listed" },
                );
                let reselected = open_deployment(state, &fixture)
                    && deployment_state(state).1.as_deref() == Some(fixture.as_str());
                self.report.record(
                    "gtk_deployment_select",
                    reselected,
                    if reselected {
                        "selected"
                    } else {
                        "not_selected"
                    },
                );
                Some(Stage::SignIn)
            }
            Stage::SignIn => {
                let report = &mut self.report;
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
                let report = &mut self.report;
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
                    return Some(Stage::SshKeys);
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
                self.report.record(
                    "gtk_ssh_keys",
                    own,
                    if own {
                        "device_key_listed"
                    } else {
                        "device_key_missing"
                    },
                );
                // Resolve the seeded machine before the page steps.
                let seed = self.descriptor.seed.machine_id.clone().or_else(|| {
                    let name = self.descriptor.seed.machine_name.clone();
                    state
                        .with_live(|live| machine_named(live, &name))
                        .and_then(Result::ok)
                        .flatten()
                });
                self.work.context.seed_machine = seed;
                Some(Stage::Pages)
            }
            Stage::Pages => {
                if self.page_tick(state) {
                    Some(Stage::Pages)
                } else {
                    Some(Stage::Terminal)
                }
            }
            Stage::Terminal => {
                let report = &mut self.report;
                let Some(root) = page(state, Page::Terminal) else {
                    report.record("gtk_terminal", false, "page_missing");
                    return Some(Stage::LoseOnAction);
                };
                if select_machine(state, &self.work.seed()).is_err() {
                    report.record("gtk_terminal", false, "machine_field_missing");
                    return Some(Stage::LoseOnAction);
                }
                let clicked = click(
                    state,
                    Page::Terminal,
                    &strings::text(strings::Message::AttachTerminal),
                );
                let live = state
                    .terminal
                    .borrow()
                    .as_ref()
                    .and_then(mila_native_linux::terminal_surface::TerminalSurface::live_generation)
                    .is_some();
                if !clicked || !live {
                    let refusal = state
                        .session
                        .borrow()
                        .session()
                        .and_then(LiveSession::last_refusal);
                    let shown =
                        status_text(state) == strings::text(strings::Message::TerminalRefused);
                    let code = match refusal.as_deref() {
                        Some("terminal_unavailable") if shown => "terminal_unavailable",
                        Some(_) => "attach_refused",
                        None => "attach_failed",
                    };
                    if code == "attach_failed" && self.terminal_attempts < TERMINAL_ATTEMPTS {
                        self.terminal_attempts += 1;
                        return Some(Stage::Terminal);
                    }
                    report.record("gtk_terminal", terminal_passed(code), code);
                    return Some(self.after_terminal());
                }
                let Some(marker) = mila_native_linux::adapter::new_request_id().and_then(|id| {
                    id.get(8..20)
                        .map(|suffix| format!("mila-gtk-journey-{suffix}"))
                }) else {
                    report.record("gtk_terminal", false, "marker_unavailable");
                    return Some(Stage::LoseOnAction);
                };
                let input = widgets::<Entry>(&root).into_iter().find(|entry| {
                    entry.placeholder_text().as_deref()
                        == Some(strings::text(strings::Message::TerminalInputHint).as_str())
                });
                let Some(input) = input else {
                    report.record("gtk_terminal", false, "input_missing");
                    return Some(Stage::LoseOnAction);
                };
                input.set_text(&format!("echo {marker}"));
                if !click(
                    state,
                    Page::Terminal,
                    &strings::text(strings::Message::TerminalSend),
                ) {
                    report.record("gtk_terminal", false, "send_missing");
                    return Some(Stage::LoseOnAction);
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
                    self.report.record("gtk_terminal", true, "marker_seen");
                    return Some(self.after_terminal());
                }
                if started.elapsed() > STEP_DEADLINE {
                    self.report.record("gtk_terminal", false, "marker_timeout");
                    return Some(self.after_terminal());
                }
                Some(Stage::AwaitMarker(started, marker))
            }
            Stage::Guest(step, started) => self.guest_tick(state, step, started),
            Stage::LoseOnAction => {
                // Sever the bound session, then press a page action: the
                // transport error must release the session and start a new
                // sign-in generation at once, not at the next heartbeat.
                let generation = state.driver.borrow().flow().generation;
                let probe = state
                    .session
                    .borrow()
                    .session()
                    .and_then(LiveSession::probe);
                let Some(probe) = probe else {
                    self.report.record("gtk_loss_detected", false, "not_bound");
                    return Some(Stage::SignOut);
                };
                probe.sever();
                let pressed = press(state, Page::Machines, pages::MACHINE_LIST, M::Refresh).is_ok();
                let immediate = pressed
                    && !state.session.borrow().is_authenticated()
                    && state.driver.borrow().flow().generation > generation;
                self.report.record(
                    "gtk_loss_detected",
                    immediate,
                    if immediate {
                        "on_page_action"
                    } else {
                        "not_detected"
                    },
                );
                Some(Stage::AwaitReconnect(Instant::now(), generation))
            }
            Stage::AwaitReconnect(started, generation) => {
                let report = &mut self.report;
                let driver = state.driver.borrow();
                let flow = driver.flow();
                if flow.phase == SignInPhase::SignedIn
                    && flow.generation > generation
                    && state.session.borrow().is_authenticated()
                {
                    report.record("gtk_reconnect", true, "reestablished");
                    return Some(Stage::Switch(SWITCH_AWAY));
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
            Stage::Switch(switch) => {
                let host = self.host(switch.host);
                // Open switches the selection and must release every
                // authority at once, before any new sign-in.
                let opened = open_deployment(state, &host);
                let selected = deployment_state(state).1.as_deref() == Some(host.as_str());
                if !(opened && selected && released(state)) {
                    self.report.record(switch.name, false, "retained");
                    return Some(Stage::SignOut);
                }
                let before = self.approver.opened();
                if !click(
                    state,
                    Page::SignIn,
                    &strings::text(strings::Message::SignInStart),
                ) {
                    self.report.record(switch.name, false, "button_missing");
                    return Some(Stage::SignOut);
                }
                Some(Stage::AwaitSwitched(switch, Instant::now(), before))
            }
            Stage::AwaitSwitched(switch, started, before) => {
                let host = self.host(switch.host);
                let (phase, failure, target) = {
                    let driver = state.driver.borrow();
                    let flow = driver.flow();
                    (
                        flow.phase,
                        flow.failure,
                        driver.target().map(|target| target.host().to_owned()),
                    )
                };
                let next = switch.next.map_or(Stage::SignOut, |host| {
                    Stage::Switch(Switch {
                        name: "gtk_deployment_switch_back",
                        host,
                        next: None,
                    })
                });
                if phase == SignInPhase::SignedIn && state.session.borrow().is_authenticated() {
                    // The new session reads the deployment's listing.
                    let seed = self.work.seed();
                    let listed = state
                        .with_live(LiveSession::refresh)
                        .and_then(Result::ok)
                        .is_some_and(|bytes| {
                            project_snapshot(&bytes)
                                .is_ok_and(|rows| rows.iter().any(|row| row.id == seed))
                        });
                    let code = match (target.as_deref() == Some(host.as_str()), listed) {
                        _ if switch.host_bound() => "host_binding_bypassed",
                        (false, _) => "wrong_deployment",
                        (true, false) => "seed_missing",
                        (true, true) if self.approver.opened() > before => "approved",
                        (true, true) => "already",
                    };
                    self.report
                        .record(switch.name, code == "approved" || code == "already", code);
                    return Some(next);
                }
                if phase != SignInPhase::Connecting && phase != SignInPhase::AwaitingApproval {
                    let code = sign_in_failure_code(phase, failure);
                    let bound = switch.host_bound()
                        && code == "host_untrusted"
                        && !state.session.borrow().is_authenticated()
                        && target.as_deref() == Some(host.as_str());
                    self.report.record(
                        switch.name,
                        bound,
                        if bound { "host_bound_refused" } else { code },
                    );
                    return Some(next);
                }
                if started.elapsed() > SIGN_IN_DEADLINE {
                    self.report.record(switch.name, false, "approval_timeout");
                    return Some(next);
                }
                Some(Stage::AwaitSwitched(switch, started, before))
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
                self.report.record(
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
    let Some(context) = PageContext::new(&descriptor.seed.share_principal) else {
        let mut report = JourneyReport::new();
        report.record("gtk_environment", false, "csprng_unavailable");
        return print_report(&report);
    };
    let script = Rc::new(RefCell::new(Script {
        descriptor: descriptor.clone(),
        approver,
        report: JourneyReport::new(),
        stage: Some(Stage::Deployments),
        work: PageWork {
            context,
            hook: FixtureHook::new(descriptor, workdir, ca_path),
            hook_missing: false,
            revision: 0,
            seed_name: descriptor.seed.machine_name.clone(),
            paused: false,
        },
        steps: page_steps(),
        current: None,
        terminal_attempts: 0,
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
