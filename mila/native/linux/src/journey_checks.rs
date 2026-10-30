//! Backend-effect checks shared by the headless and GTK live journeys.
//!
//! Each check reads the deployment through the authenticated session
//! (`ls`, `show`, `share show`, `web show`, `thread show`, `thread turns`)
//! and answers whether an action has taken effect. The headless journey
//! calls the session methods directly; the GTK journey presses the page
//! buttons. Both then poll the same check, so a passing GTK step means the
//! window's control changed the deployment, not only its own widgets.
//!
//! Outcome codes are fixed strings; no identifier, name, address or text
//! reaches a report.

use crate::adapter::{decode_listing, decode_share_listing, decode_web_endpoint, WebEndpoint};
use crate::machine_view::project_listing;
use crate::porsche_results::{
    decode_machine_detail, decode_thread_detail, decode_thread_events, decode_thread_rows,
    MachineDetail, ThreadDetail, ThreadEvent,
};
use crate::session::{LiveSession, SessionError};

/// One poll of a journey check.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Check {
    /// The effect is visible; the code names it.
    Pass(&'static str),
    /// Not yet; poll again until the step's deadline.
    Wait,
    /// The effect cannot happen (for example the read was refused).
    Fail(&'static str),
}

/// Size the journey creates a machine with, then resizes it to.
pub const CREATE_SIZE: (u32, u64, u64) = (1, 1024, 10);
pub const RESIZE_SIZE: (u32, u64, u64) = (2, 2048, 10);

/// State carried between the steps of one journey run.
#[derive(Clone, Debug, Default)]
pub struct PageContext {
    /// Name of the machine this run creates (`mila-journey-<hex>`).
    pub machine_name: String,
    /// Its id once the listing shows it.
    pub machine: Option<String>,
    /// The seeded machine sharing and web steps use.
    pub seed_machine: Option<String>,
    pub share_principal: String,
    /// The seeded machine's web endpoint before the journey changed it.
    pub web_before: Option<WebEndpoint>,
    pub thread: Option<String>,
    /// The thread's last event sequence before the prompt was sent.
    pub sequence_before: u64,
    pub question: Option<String>,
    pub plan: Option<String>,
}

impl PageContext {
    /// A context for a fresh machine name; `None` when the CSPRNG is
    /// unavailable.
    pub fn new(share_principal: &str) -> Option<Self> {
        let suffix = crate::adapter::new_request_id()?;
        Some(Self {
            machine_name: format!("mila-journey-{}", &suffix[8..20]),
            share_principal: share_principal.to_owned(),
            ..Self::default()
        })
    }
}

/// The id of the listed machine called `name`.
pub fn machine_named(live: &mut LiveSession, name: &str) -> Result<Option<String>, SessionError> {
    let bytes = live.refresh()?;
    let listing = decode_listing(&bytes).map_err(|_| SessionError::InvalidInput)?;
    let rows = project_listing(&listing).map_err(|_| SessionError::InvalidInput)?;
    Ok(rows
        .into_iter()
        .find(|row| row.name == name)
        .map(|row| row.id))
}

pub fn machine_detail(live: &mut LiveSession, id: &str) -> Result<MachineDetail, SessionError> {
    let bytes = live.machine_show(id)?;
    decode_machine_detail(&bytes).map_err(|_| SessionError::InvalidInput)
}

/// The role `email` holds on `machine`, `None` when it has no grant.
pub fn share_role(
    live: &mut LiveSession,
    machine: &str,
    email: &str,
) -> Result<Option<String>, SessionError> {
    let bytes = live.share_show(machine)?;
    let (_, grants) = decode_share_listing(&bytes).map_err(|_| SessionError::InvalidInput)?;
    Ok(grants
        .into_iter()
        .find(|grant| grant.email.eq_ignore_ascii_case(email))
        .map(|grant| grant.role))
}

pub fn web_endpoint(live: &mut LiveSession, machine: &str) -> Result<WebEndpoint, SessionError> {
    let bytes = live.web_show(machine)?;
    decode_web_endpoint(&bytes).map_err(|_| SessionError::InvalidInput)
}

/// The first listed thread, preferring one on `machine`.
pub fn first_thread(
    live: &mut LiveSession,
    machine: Option<&str>,
) -> Result<Option<String>, SessionError> {
    let bytes = live.thread_action(None, "thread ls", None, None, None)?;
    let rows = decode_thread_rows(&bytes).map_err(|_| SessionError::InvalidInput)?;
    let preferred = rows
        .iter()
        .find(|row| machine.is_some() && row.machine_id.as_deref() == machine)
        .or_else(|| rows.first());
    Ok(preferred.map(|row| row.id.clone()))
}

pub fn thread_detail(live: &mut LiveSession, thread: &str) -> Result<ThreadDetail, SessionError> {
    let bytes = live.thread_action(Some(thread), "thread show", None, None, None)?;
    decode_thread_detail(&bytes).map_err(|_| SessionError::InvalidInput)
}

pub fn thread_events(
    live: &mut LiveSession,
    thread: &str,
) -> Result<Vec<ThreadEvent>, SessionError> {
    let bytes = live.thread_action(Some(thread), "thread turns", None, None, None)?;
    decode_thread_events(&bytes).map_err(|_| SessionError::InvalidInput)
}

fn read_failed(error: SessionError) -> Check {
    match error {
        SessionError::Transport | SessionError::StaleHandle => Check::Fail("session_lost"),
        _ => Check::Fail("read_refused"),
    }
}

/// The created machine is listed; records its id.
pub fn check_created(live: &mut LiveSession, context: &mut PageContext) -> Check {
    match machine_named(live, &context.machine_name) {
        Ok(Some(id)) => {
            context.machine = Some(id);
            Check::Pass("listed")
        }
        Ok(None) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// The created machine's requested state is `desired`.
pub fn check_desired(
    live: &mut LiveSession,
    context: &PageContext,
    desired: &str,
    code: &'static str,
) -> Check {
    let Some(machine) = context.machine.as_deref() else {
        return Check::Fail("machine_missing");
    };
    match machine_detail(live, machine) {
        Ok(detail) if detail.desired_state == desired => Check::Pass(code),
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// The created machine reports the requested CPU count and memory.
pub fn check_resized(live: &mut LiveSession, context: &PageContext) -> Check {
    let Some(machine) = context.machine.as_deref() else {
        return Check::Fail("machine_missing");
    };
    match machine_detail(live, machine) {
        Ok(detail)
            if detail.vcpu == Some(RESIZE_SIZE.0) && detail.memory_mib() == Some(RESIZE_SIZE.1) =>
        {
            Check::Pass("resized")
        }
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// The created machine is gone from the listing or marked deleted.
pub fn check_deleted(live: &mut LiveSession, context: &PageContext) -> Check {
    let Some(machine) = context.machine.as_deref() else {
        return Check::Fail("machine_missing");
    };
    match machine_named(live, &context.machine_name) {
        Ok(None) => return Check::Pass("absent"),
        Ok(Some(_)) => {}
        Err(error) => return read_failed(error),
    }
    match machine_detail(live, machine) {
        Ok(detail) if matches!(detail.desired_state.as_str(), "deleted" | "deleting") => {
            Check::Pass("deleting")
        }
        Ok(_) => Check::Wait,
        Err(SessionError::InvalidInput | SessionError::Unavailable) => Check::Pass("absent"),
        Err(error) => read_failed(error),
    }
}

/// The share principal holds `role` on the seeded machine (`None`: no grant).
pub fn check_share(live: &mut LiveSession, context: &PageContext, role: Option<&str>) -> Check {
    let Some(machine) = context.seed_machine.as_deref() else {
        return Check::Fail("seed_missing");
    };
    match share_role(live, machine, &context.share_principal) {
        Ok(found) if found.as_deref() == role => {
            Check::Pass(if role.is_some() { "granted" } else { "absent" })
        }
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// The seeded machine's endpoint is public or private, at a newer revision
/// than the one the step started from.
pub fn check_web(
    live: &mut LiveSession,
    context: &PageContext,
    public: bool,
    after_revision: u64,
) -> Check {
    let Some(machine) = context.seed_machine.as_deref() else {
        return Check::Fail("seed_missing");
    };
    match web_endpoint(live, machine) {
        Ok(endpoint)
            if (endpoint.visibility == "public") == public
                && endpoint.policy_revision > after_revision =>
        {
            Check::Pass(if public { "public" } else { "private" })
        }
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// A prompt event newer than `context.sequence_before` is in the history.
pub fn check_prompted(live: &mut LiveSession, context: &PageContext) -> Check {
    let Some(thread) = context.thread.as_deref() else {
        return Check::Fail("thread_missing");
    };
    match thread_events(live, thread) {
        Ok(events)
            if events.iter().any(|event| {
                event.kind == "prompt" && event.sequence > context.sequence_before
            }) =>
        {
            Check::Pass("prompt_recorded")
        }
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// Records the thread's open question and plan before the answer and plan
/// steps; a thread without them cannot exercise those controls.
pub fn load_thread_controls(live: &mut LiveSession, context: &mut PageContext) -> Check {
    let Some(thread) = context.thread.as_deref() else {
        return Check::Fail("thread_missing");
    };
    match thread_detail(live, thread) {
        Ok(detail) => {
            context.sequence_before = detail.last_sequence.unwrap_or(0);
            context.question = detail
                .pending_question
                .as_ref()
                .map(|question| question.id.clone());
            context.plan = detail.open_plan().map(|plan| plan.id.clone());
            Check::Pass("loaded")
        }
        Err(error) => read_failed(error),
    }
}

/// The question the journey answered is no longer pending.
pub fn check_answered(live: &mut LiveSession, context: &PageContext) -> Check {
    let (Some(thread), Some(question)) = (context.thread.as_deref(), context.question.as_deref())
    else {
        return Check::Fail("no_pending_question");
    };
    match thread_detail(live, thread) {
        Ok(detail)
            if detail
                .pending_question
                .as_ref()
                .is_none_or(|pending| pending.id != question) =>
        {
            Check::Pass("answered")
        }
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// The plan the journey approved is implemented or no longer open.
pub fn check_plan_approved(live: &mut LiveSession, context: &PageContext) -> Check {
    let (Some(thread), Some(plan)) = (context.thread.as_deref(), context.plan.as_deref()) else {
        return Check::Fail("no_pending_plan");
    };
    match thread_detail(live, thread) {
        Ok(detail) if detail.open_plan().is_none_or(|open| open.id != plan) => {
            Check::Pass("approved")
        }
        Ok(_) => Check::Wait,
        Err(error) => read_failed(error),
    }
}

/// The outcome code for a refused or failed action press.
pub fn action_failed(error: SessionError) -> &'static str {
    match error {
        SessionError::InvalidInput => "refused",
        SessionError::Busy => "busy",
        SessionError::Transport | SessionError::StaleHandle => "session_lost",
        SessionError::Unavailable => "unavailable",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_names_a_fresh_machine_without_identifying_data() {
        let first = PageContext::new("viewer@example.test").unwrap();
        let second = PageContext::new("viewer@example.test").unwrap();
        assert!(first.machine_name.starts_with("mila-journey-"));
        assert_eq!(first.machine_name.len(), "mila-journey-".len() + 12);
        assert_ne!(first.machine_name, second.machine_name);
        assert!(first
            .machine_name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'));
    }

    #[test]
    fn checks_without_their_targets_fail_with_fixed_codes() {
        // Checks never reach the session when their target is missing, so a
        // missing machine or thread is reported, not polled forever.
        let context = PageContext::default();
        assert_eq!(action_failed(SessionError::InvalidInput), "refused");
        assert_eq!(action_failed(SessionError::Transport), "session_lost");
        assert!(context.machine.is_none() && context.thread.is_none());
    }
}
