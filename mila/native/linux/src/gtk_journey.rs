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
    create_private_workdir, fixture_connection_profile, read_descriptor, remove_journey_machine,
    sign_in_failure_code, terminal_passed, FixtureApprover, FixtureHook, JourneyDescriptor,
    JourneyReport, FIXTURE_ANSWER, JOURNEY_PROMPT,
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
const SIGN_IN_DEADLINE: Duration = Duration::from_secs(120);
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
    LoseOnAction,
    AwaitReconnect(Instant, u64),
    /// Opens `host` in the deployment list, then signs in to it.
    Switch(Switch),
    AwaitSwitched(Switch, Instant, u32),
    SignOut,
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
                    return Some(Stage::LoseOnAction);
                }
                let Some(marker) = mila_native_linux::adapter::new_request_id().and_then(|id| {
                    id.get(8..20)
                        .map(|suffix| format!("mila-gtk-journey-{suffix}"))
                }) else {
                    report.record("gtk_terminal", false, "marker_unavailable");
                    return Some(Stage::LoseOnAction);
                };
                let input = widgets::<Entry>(&root)
                    .into_iter()
                    .find(|entry| entry.placeholder_text().as_deref() == Some("Terminal input"));
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
                    return Some(Stage::LoseOnAction);
                }
                if started.elapsed() > STEP_DEADLINE {
                    self.report.record("gtk_terminal", false, "marker_timeout");
                    return Some(Stage::LoseOnAction);
                }
                Some(Stage::AwaitMarker(started, marker))
            }
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
