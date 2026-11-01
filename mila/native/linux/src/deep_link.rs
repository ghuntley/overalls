//! Navigation-only presentation of resolved deep links.
//!
//! [`present`] turns a [`NavigationDecision`] into the GTK page to show and
//! the identifiers to pre-fill in that page's entries. It never yields a
//! command, a deployment change or an approval: the user still presses the
//! page's own control to act.

use crate::route::{ActivationRoute, MachinePage, NavigationDecision, Target};
use std::time::{Duration, Instant};

/// The GTK stack page a link selects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Page {
    Machines,
    Threads,
    Terminal,
    Settings,
    /// The deployment list, used for links to a deployment not yet added.
    Deployments,
    /// Sign-in controls, used for signed-out deployments and SSH approval.
    SignIn,
}

impl Page {
    /// Stable `gtk::Stack` child name.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Machines => "machines",
            Self::Threads => "threads",
            Self::Terminal => "terminal",
            Self::Settings => "settings",
            Self::Deployments => "deployments",
            Self::SignIn => "sign-in",
        }
    }
}

/// Why the link landed where it did; the UI maps this to localized text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LinkNotice {
    Opened,
    UnknownDeployment,
    SignInRequired,
}

/// Entries the target page pre-fills. All values come from the closed route
/// table, so they are canonical identifiers or a validated GitHub source.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Prefill {
    pub deployment_host: Option<String>,
    pub machine_id: Option<String>,
    pub terminal_session_id: Option<String>,
    pub thread_id: Option<String>,
    pub launch_source: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeepLinkPresentation {
    pub page: Page,
    pub notice: LinkNotice,
    pub authority: String,
    pub prefill: Prefill,
}

/// @cc [owner:ghuntley,label:security;navigation] linux-deep-link-target-widgets
/// A link for an unknown deployment MUST land on the deployment list with only
/// the host pre-filled, and a signed-out link MUST land on sign-in without
/// pre-filling target identifiers; only an authenticated `Open` decision may
/// pre-fill machine, terminal, thread or launch entries of its target page.
pub fn present(decision: &NavigationDecision) -> DeepLinkPresentation {
    match decision {
        NavigationDecision::UnknownDeployment { authority, .. } => DeepLinkPresentation {
            page: Page::Deployments,
            notice: LinkNotice::UnknownDeployment,
            authority: authority.clone(),
            prefill: Prefill {
                deployment_host: Some(authority.clone()),
                ..Prefill::default()
            },
        },
        NavigationDecision::SignInRequired { authority, .. } => DeepLinkPresentation {
            page: Page::SignIn,
            notice: LinkNotice::SignInRequired,
            authority: authority.clone(),
            prefill: Prefill::default(),
        },
        NavigationDecision::Open { authority, target } => {
            let (page, prefill) = open_target(target);
            DeepLinkPresentation {
                page,
                notice: LinkNotice::Opened,
                authority: authority.clone(),
                prefill,
            }
        }
    }
}

fn open_target(target: &Target) -> (Page, Prefill) {
    let mut prefill = Prefill::default();
    let page = match target {
        Target::Machines => Page::Machines,
        Target::Threads => Page::Threads,
        Target::Settings => Page::Settings,
        Target::Thread { id } => {
            prefill.thread_id = Some(id.clone());
            Page::Threads
        }
        Target::Launch { source } => {
            prefill.launch_source = Some(source.clone());
            Page::Machines
        }
        Target::SshApproved { .. } => Page::SignIn,
        Target::Machine { id, page } => {
            prefill.machine_id = Some(id.clone());
            match page {
                MachinePage::Overview | MachinePage::Info | MachinePage::Web => Page::Machines,
                MachinePage::Terminals => Page::Terminal,
                MachinePage::Terminal { session_id } => {
                    prefill.terminal_session_id = Some(session_id.clone());
                    Page::Terminal
                }
                MachinePage::Threads => Page::Threads,
                MachinePage::Thread { thread_id } => {
                    prefill.thread_id = Some(thread_id.clone());
                    Page::Threads
                }
            }
        }
    };
    (page, prefill)
}

/// How long a link received while signed out stays eligible for completion.
pub const PENDING_LINK_LIFETIME: Duration = Duration::from_secs(600);

/// The result of offering an authenticated session to a held link.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LinkCompletion {
    /// Nothing is held, or the session is not yet authenticated.
    Nothing,
    /// The held link outlived its lifetime or no longer resolves to the
    /// authenticated selected deployment; it was discarded.
    Expired,
    /// The held link now opens its target on the authenticated deployment.
    Opened(NavigationDecision),
}

/// One share or open activation that arrived while its deployment was
/// selected but signed out, held so that signing in completes it.
#[derive(Clone, Debug, Default)]
pub struct PendingLink {
    held: Option<(ActivationRoute, Instant)>,
}

impl PendingLink {
    /// @cc [owner:ghuntley,label:security;navigation] linux-share-completion
    /// Only a `SignInRequired` decision MAY be held, at most one at a time:
    /// any newer activation, accepted or refused, replaces or clears it. A held link MUST complete
    /// at most once, only within [`PENDING_LINK_LIFETIME`], and only when it
    /// re-resolves to `Open` against the authenticated selected deployment;
    /// sign-out and a deployment switch MUST discard it. Completion is
    /// navigation only, through the same [`present`] projection.
    pub fn offer(&mut self, decision: &NavigationDecision, now: Instant) -> bool {
        self.held = match decision {
            NavigationDecision::SignInRequired { .. } => {
                ActivationRoute::parse(&decision.canonical())
                    .ok()
                    .map(|route| (route, now))
            }
            NavigationDecision::UnknownDeployment { .. } | NavigationDecision::Open { .. } => None,
        };
        self.held.is_some()
    }

    /// The canonical link being held, if any.
    pub fn held(&self) -> Option<String> {
        self.held.as_ref().map(|(route, _)| route.canonical())
    }

    /// Drops the held link (sign-out, deployment switch or removal).
    pub fn discard(&mut self) {
        self.held = None;
    }

    /// Completes the held link once the selected deployment is authenticated.
    pub fn complete(
        &mut self,
        selected_authority: Option<&str>,
        authenticated: bool,
        now: Instant,
    ) -> LinkCompletion {
        if !authenticated {
            return LinkCompletion::Nothing;
        }
        let Some((route, received)) = self.held.take() else {
            return LinkCompletion::Nothing;
        };
        let fresh = now
            .checked_duration_since(received)
            .is_some_and(|age| age <= PENDING_LINK_LIFETIME);
        match route.navigation(selected_authority, true) {
            decision @ NavigationDecision::Open { .. } if fresh => LinkCompletion::Opened(decision),
            _ => LinkCompletion::Expired,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::route::{share_inbound, share_route, ActivationBatch, ActivationRoute};

    const MACHINE: &str = "01234567-89ab-cdef-0123-456789abcdef";
    const OTHER: &str = "fedcba98-7654-3210-fedc-ba9876543210";

    fn decide(uri: &str, selected: Option<&str>, authenticated: bool) -> DeepLinkPresentation {
        let batch = ActivationBatch::parse([uri]);
        present(&batch.decisions(selected, authenticated)[0])
    }

    #[test]
    fn authenticated_links_select_target_widgets() {
        let host = Some("mila.example");
        let cases = [
            (
                "overalls://mila.example/machines".to_owned(),
                Page::Machines,
            ),
            ("overalls://mila.example/threads".to_owned(), Page::Threads),
            (
                "overalls://mila.example/settings".to_owned(),
                Page::Settings,
            ),
            (
                format!("overalls://mila.example/machines/{MACHINE}"),
                Page::Machines,
            ),
            (
                format!("overalls://mila.example/machines/{MACHINE}/web"),
                Page::Machines,
            ),
            (
                format!("overalls://mila.example/machines/{MACHINE}/terminals"),
                Page::Terminal,
            ),
            (
                format!("overalls://mila.example/machines/{MACHINE}/threads"),
                Page::Threads,
            ),
            (
                format!("overalls://mila.example/ssh/approved?session={MACHINE}"),
                Page::SignIn,
            ),
        ];
        for (uri, page) in cases {
            let presentation = decide(&uri, host, true);
            assert_eq!(presentation.page, page, "{uri}");
            assert_eq!(presentation.notice, LinkNotice::Opened);
        }
        let terminal = decide(
            &format!("overalls://mila.example/machines/{MACHINE}/terminals/{OTHER}"),
            host,
            true,
        );
        assert_eq!(terminal.prefill.machine_id.as_deref(), Some(MACHINE));
        assert_eq!(terminal.prefill.terminal_session_id.as_deref(), Some(OTHER));
        let thread = decide(
            &format!("overalls://mila.example/threads/{OTHER}"),
            host,
            true,
        );
        assert_eq!(thread.prefill.thread_id.as_deref(), Some(OTHER));
        let launch = decide(
            "overalls://mila.example/launch?source=https%3A%2F%2Fgithub.com%2Fo%2Fr",
            host,
            true,
        );
        assert_eq!(
            launch.prefill.launch_source.as_deref(),
            Some("https://github.com/o/r")
        );
    }

    #[test]
    fn unknown_and_signed_out_links_never_prefill_targets() {
        let uri = format!("overalls://other.example/machines/{MACHINE}/terminals/{OTHER}");
        let unknown = decide(&uri, Some("mila.example"), true);
        assert_eq!(unknown.page, Page::Deployments);
        assert_eq!(
            unknown.prefill,
            Prefill {
                deployment_host: Some("other.example".into()),
                ..Prefill::default()
            }
        );
        let signed_out = decide(&uri, Some("other.example"), false);
        assert_eq!(signed_out.page, Page::SignIn);
        assert_eq!(signed_out.notice, LinkNotice::SignInRequired);
        assert_eq!(signed_out.prefill, Prefill::default());
    }

    #[test]
    fn share_links_are_canonical_closed_routes() {
        let target = Target::Machine {
            id: MACHINE.into(),
            page: MachinePage::Terminal {
                session_id: OTHER.into(),
            },
        };
        let link = share_route("mila.example:8443", &target).unwrap();
        assert_eq!(
            link,
            format!("overalls://mila.example:8443/machines/{MACHINE}/terminals/{OTHER}")
        );
        assert_eq!(ActivationRoute::parse(&link).unwrap().canonical(), link);
        let bad = Target::Machine {
            id: "../../etc".into(),
            page: MachinePage::Overview,
        };
        assert!(share_route("mila.example", &bad).is_err());
        assert!(share_route("Mila.Example", &Target::Machines).is_err());
        assert!(share_route("mila.example/x", &Target::Machines).is_err());
    }

    #[test]
    fn shared_text_uses_uri_list_lines_and_bounds() {
        let text = format!(
            "# comment\r\noveralls://mila.example/machines\r\n\r\n  overalls://mila.example/machines/{MACHINE}  \nnot a link\n"
        );
        let batch = share_inbound(&text);
        assert_eq!(batch.routes().len(), 2);
        assert_eq!(batch.rejected(), 1);
        let huge = "overalls://mila.example/machines\n".repeat(4_000);
        let refused = share_inbound(&huge);
        assert_eq!(refused.routes(), []);
        assert_eq!(refused.rejected(), 1);
        let many = (0..100)
            .map(|index| format!("overalls://h{index}.example/machines"))
            .collect::<Vec<_>>()
            .join("\n");
        let bounded = share_inbound(&many);
        assert_eq!(bounded.routes().len(), 64);
        assert_eq!(bounded.rejected(), 36);
    }

    #[test]
    fn signed_out_links_complete_once_after_sign_in() {
        let now = Instant::now();
        let uri = format!("overalls://mila.example/machines/{MACHINE}/terminals");
        let signed_out =
            ActivationBatch::parse([uri.as_str()]).decisions(Some("mila.example"), false);
        let mut pending = PendingLink::default();
        assert!(pending.offer(&signed_out[0], now));
        assert_eq!(pending.held().as_deref(), Some(uri.as_str()));
        assert_eq!(
            pending.complete(Some("mila.example"), false, now),
            LinkCompletion::Nothing,
            "an unauthenticated session leaves the link held"
        );
        let LinkCompletion::Opened(decision) = pending.complete(Some("mila.example"), true, now)
        else {
            panic!("authenticated completion opens the held link");
        };
        let presentation = present(&decision);
        assert_eq!(presentation.page, Page::Terminal);
        assert_eq!(presentation.prefill.machine_id.as_deref(), Some(MACHINE));
        assert_eq!(
            pending.complete(Some("mila.example"), true, now),
            LinkCompletion::Nothing,
            "a held link completes at most once"
        );
    }

    #[test]
    fn held_links_fail_closed_on_other_hosts_age_and_newer_activations() {
        let now = Instant::now();
        let uri = "overalls://mila.example/threads";
        let signed_out = ActivationBatch::parse([uri]).decisions(Some("mila.example"), false);
        let mut pending = PendingLink::default();
        assert!(pending.offer(&signed_out[0], now));
        assert_eq!(
            pending.complete(Some("other.example"), true, now),
            LinkCompletion::Expired,
            "another deployment's session never completes the link"
        );
        assert_eq!(pending.held(), None);
        assert!(pending.offer(&signed_out[0], now));
        let late = now + PENDING_LINK_LIFETIME + Duration::from_secs(1);
        assert_eq!(
            pending.complete(Some("mila.example"), true, late),
            LinkCompletion::Expired
        );
        assert!(pending.offer(&signed_out[0], now));
        pending.discard();
        assert_eq!(
            pending.complete(Some("mila.example"), true, now),
            LinkCompletion::Nothing
        );
        // Unknown-deployment and already-open decisions are never held, and
        // a newer activation replaces the held one.
        assert!(pending.offer(&signed_out[0], now));
        let unknown = ActivationBatch::parse(["overalls://other.example/threads"])
            .decisions(Some("mila.example"), false);
        assert!(!pending.offer(&unknown[0], now));
        assert_eq!(pending.held(), None);
        let open = ActivationBatch::parse([uri]).decisions(Some("mila.example"), true);
        assert!(!pending.offer(&open[0], now));
        assert_eq!(pending.held(), None);
    }
}
