//! Typed, bounded navigation routes for `overalls://` activation.

use std::{fmt, str::FromStr};

const MAX_ROUTE_BYTES: usize = 2_048;

/// A route selected by a link. It contains navigation data only; it has no command semantics.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivationRoute {
    authority: Authority,
    target: Target,
}

impl ActivationRoute {
    /// Parses one canonical route from the desktop activation boundary.
    ///
    /// The parser intentionally accepts the same route families as Mila's shared model while
    /// keeping this native scaffold independent from the existing Rust workspace.
    pub fn parse(value: &str) -> Result<Self, RouteError> {
        if value.len() > MAX_ROUTE_BYTES
            || value
                .chars()
                .any(|character| character.is_control() || character == ' ')
            || value.contains('#')
        {
            return Err(RouteError::Invalid);
        }
        let rest = value
            .strip_prefix("overalls://")
            .ok_or(RouteError::Invalid)?;
        let (location, query) = match rest.split_once('?') {
            Some((location, query)) if !query.contains('?') => (location, Some(query)),
            Some(_) => return Err(RouteError::Invalid),
            None => (rest, None),
        };
        if location.contains(['%', '@']) {
            return Err(RouteError::Invalid);
        }
        let mut pieces = location.split('/');
        let authority = Authority::parse(pieces.next().ok_or(RouteError::Invalid)?)?;
        let segments = pieces.collect::<Vec<_>>();
        if segments.iter().any(|segment| segment.is_empty()) {
            return Err(RouteError::Invalid);
        }
        let target = Target::parse(&segments, query)?;
        Ok(Self { authority, target })
    }

    /// Returns the canonical route string used for display and subsequent activation.
    pub fn canonical(&self) -> String {
        let authority = self.authority.to_string();
        format!("overalls://{authority}{}", self.target.path())
    }

    /// Returns the navigation target without exposing authority internals to the UI.
    pub const fn target(&self) -> &Target {
        &self.target
    }

    /// Classifies a route against the selected deployment and current session.
    /// Classification only chooses a navigation destination; it never performs
    /// a command or changes deployment/session state.
    pub fn navigation(
        &self,
        selected_authority: Option<&str>,
        authenticated: bool,
    ) -> NavigationDecision {
        let authority = self.authority.to_string();
        let target = self.target.clone();
        if selected_authority != Some(authority.as_str()) {
            NavigationDecision::UnknownDeployment { authority, target }
        } else if authenticated {
            NavigationDecision::Open { authority, target }
        } else {
            NavigationDecision::SignInRequired { authority, target }
        }
    }
}

/// @cc [owner:ghuntley,label:security;navigation] linux-share-route-closed
/// An outbound share link MUST be produced only by re-parsing the formatted
/// route through [`ActivationRoute::parse`], so a shared link is always a
/// canonical member of the closed route table and never carries a command.
pub fn share_route(authority: &str, target: &Target) -> Result<String, RouteError> {
    ActivationRoute::parse(&format!("overalls://{authority}{}", target.path()))
        .map(|route| route.canonical())
}

/// Most bytes accepted from one drop or paste before it is refused whole.
const MAX_SHARED_TEXT_BYTES: usize = 64 * 1024;

/// @cc [owner:ghuntley,label:security;navigation] linux-share-inbound-batch
/// Shared or dropped text MUST be split into at most the bounded activation
/// batch of `text/uri-list` lines, skipping blank and `#` comment lines; text
/// larger than the share bound MUST be refused whole as one rejected value.
pub fn share_inbound(text: &str) -> ActivationBatch {
    if text.len() > MAX_SHARED_TEXT_BYTES {
        return ActivationBatch {
            routes: Vec::new(),
            rejected: 1,
        };
    }
    ActivationBatch::parse(
        text.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#')),
    )
}

/// Parses all URI values delivered by a desktop open activation.
///
/// Invalid values are deliberately represented as errors without retaining their input. This
/// keeps the activation boundary useful for navigation while preventing malformed links from
/// being echoed into the UI or logs.
pub fn parse_activation_uris<'a>(
    uris: impl IntoIterator<Item = &'a str>,
) -> Vec<Result<ActivationRoute, RouteError>> {
    uris.into_iter().map(ActivationRoute::parse).collect()
}

const MAX_OPEN_ROUTES: usize = 64;

/// The bounded result of one desktop open activation. Rejected values are
/// represented only by a count so malformed URI text cannot reach the UI.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivationBatch {
    routes: Vec<ActivationRoute>,
    rejected: usize,
}

/// The safe result of resolving a deep link against local deployment/session
/// state. An unknown or signed-out deployment never reaches a target screen.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NavigationDecision {
    UnknownDeployment { authority: String, target: Target },
    SignInRequired { authority: String, target: Target },
    Open { authority: String, target: Target },
}

impl NavigationDecision {
    pub fn canonical(&self) -> String {
        let (authority, target) = match self {
            Self::UnknownDeployment { authority, target }
            | Self::SignInRequired { authority, target }
            | Self::Open { authority, target } => (authority, target),
        };
        format!("overalls://{authority}{}", target.path())
    }
}

impl ActivationBatch {
    /// @cc [owner:ghuntley,label:security;navigation] linux-open-activation-batch
    /// Desktop activation MUST retain only bounded typed routes; malformed and
    /// excess values become a count and never reach UI text or persistence.
    pub fn parse<'a>(uris: impl IntoIterator<Item = &'a str>) -> Self {
        let mut routes = Vec::new();
        let mut rejected = 0;
        let mut seen = std::collections::HashSet::new();
        for result in uris.into_iter().map(ActivationRoute::parse) {
            if routes.len() >= MAX_OPEN_ROUTES {
                rejected += 1;
            } else if let Ok(route) = result {
                if seen.insert(route.canonical()) {
                    routes.push(route);
                } else {
                    rejected += 1;
                }
            } else {
                rejected += 1;
            }
        }
        Self { routes, rejected }
    }

    pub fn routes(&self) -> &[ActivationRoute] {
        &self.routes
    }

    pub const fn rejected(&self) -> usize {
        self.rejected
    }

    pub fn canonical_routes(&self) -> Vec<String> {
        self.routes.iter().map(ActivationRoute::canonical).collect()
    }

    /// Resolves every retained route against the active deployment and session.
    /// Invalid and excess inputs are already discarded by [`Self::parse`], so this
    /// projection is safe to hand to a native navigation surface.
    pub fn decisions(
        &self,
        selected_authority: Option<&str>,
        authenticated: bool,
    ) -> Vec<NavigationDecision> {
        self.routes
            .iter()
            .map(|route| route.navigation(selected_authority, authenticated))
            .collect()
    }
}

impl FromStr for ActivationRoute {
    type Err = RouteError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

/// A validated route authority. Host names are lower-case DNS labels with an optional port.
#[derive(Clone, Debug, Eq, PartialEq)]
struct Authority {
    host: String,
    port: Option<u16>,
}

impl Authority {
    fn parse(value: &str) -> Result<Self, RouteError> {
        let (host, port) = match value.split_once(':') {
            Some((host, port)) if !port.is_empty() && !port.contains(':') => {
                let parsed = port.parse::<u16>().map_err(|_| RouteError::Invalid)?;
                if parsed == 0 || port != parsed.to_string() {
                    return Err(RouteError::Invalid);
                }
                (host, Some(parsed))
            }
            Some(_) => return Err(RouteError::Invalid),
            None => (value, None),
        };
        if !valid_hostname(host) {
            return Err(RouteError::Invalid);
        }
        Ok(Self {
            host: host.to_owned(),
            port,
        })
    }
}

impl fmt::Display for Authority {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.port {
            Some(port) => write!(formatter, "{}:{port}", self.host),
            None => formatter.write_str(&self.host),
        }
    }
}

fn valid_hostname(value: &str) -> bool {
    value.len() <= 253
        && !value.is_empty()
        && value.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
                && !label.starts_with('-')
                && !label.ends_with('-')
        })
}

/// The closed set of destinations that a link can select.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Target {
    Machines,
    Threads,
    Settings,
    Machine { id: String, page: MachinePage },
    Thread { id: String },
    Launch { source: String },
    SshApproved { session_id: String },
}

impl Target {
    fn parse(segments: &[&str], query: Option<&str>) -> Result<Self, RouteError> {
        match (segments, query) {
            (["machines"], None) => Ok(Self::Machines),
            (["threads"], None) => Ok(Self::Threads),
            (["settings"], None) => Ok(Self::Settings),
            (["machines", id], None) if canonical_id(id) => Ok(Self::Machine {
                id: (*id).to_owned(),
                page: MachinePage::Overview,
            }),
            (["machines", id, page], None) if canonical_id(id) => Ok(Self::Machine {
                id: (*id).to_owned(),
                page: MachinePage::parse(page)?,
            }),
            (["machines", id, "terminals", session_id], None)
                if canonical_id(id) && canonical_id(session_id) =>
            {
                Ok(Self::Machine {
                    id: (*id).to_owned(),
                    page: MachinePage::Terminal {
                        session_id: (*session_id).to_owned(),
                    },
                })
            }
            (["machines", id, "threads", thread_id], None)
                if canonical_id(id) && canonical_id(thread_id) =>
            {
                Ok(Self::Machine {
                    id: (*id).to_owned(),
                    page: MachinePage::Thread {
                        thread_id: (*thread_id).to_owned(),
                    },
                })
            }
            (["threads", id], None) if canonical_id(id) => Ok(Self::Thread {
                id: (*id).to_owned(),
            }),
            (["launch"], Some(query)) => {
                let source = parse_query(query, "source")?;
                if !valid_workspace_source(&source) {
                    return Err(RouteError::Invalid);
                }
                Ok(Self::Launch { source })
            }
            (["ssh", "approved"], Some(query)) => Ok(Self::SshApproved {
                session_id: parse_query(query, "session").and_then(|value| {
                    canonical_id(&value)
                        .then_some(value)
                        .ok_or(RouteError::Invalid)
                })?,
            }),
            _ => Err(RouteError::Invalid),
        }
    }

    fn path(&self) -> String {
        match self {
            Self::Machines => "/machines".to_owned(),
            Self::Threads => "/threads".to_owned(),
            Self::Settings => "/settings".to_owned(),
            Self::Machine { id, page } => format!("/machines/{id}{}", page.path()),
            Self::Thread { id } => format!("/threads/{id}"),
            Self::Launch { source } => format!("/launch?source={}", encode_component(source)),
            Self::SshApproved { session_id } => format!("/ssh/approved?session={session_id}"),
        }
    }
}

/// A page beneath a machine route.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MachinePage {
    Overview,
    Info,
    Web,
    Terminals,
    Terminal { session_id: String },
    Threads,
    Thread { thread_id: String },
}

impl MachinePage {
    fn parse(value: &str) -> Result<Self, RouteError> {
        match value {
            "info" => Ok(Self::Info),
            "web" => Ok(Self::Web),
            "terminals" => Ok(Self::Terminals),
            "threads" => Ok(Self::Threads),
            _ => Err(RouteError::Invalid),
        }
    }

    fn path(&self) -> String {
        match self {
            Self::Overview => String::new(),
            Self::Info => "/info".to_owned(),
            Self::Web => "/web".to_owned(),
            Self::Terminals => "/terminals".to_owned(),
            Self::Terminal { session_id } => format!("/terminals/{session_id}"),
            Self::Threads => "/threads".to_owned(),
            Self::Thread { thread_id } => format!("/threads/{thread_id}"),
        }
    }
}

fn canonical_id(value: &str) -> bool {
    value.len() == 36
        && value.as_bytes().iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()
            }
        })
}

fn parse_query(query: &str, expected_key: &str) -> Result<String, RouteError> {
    let (key, value) = query.split_once('=').ok_or(RouteError::Invalid)?;
    if key != expected_key || value.is_empty() || value.contains(['=', '&']) {
        return Err(RouteError::Invalid);
    }
    decode_component(value).ok_or(RouteError::Invalid)
}

fn valid_workspace_source(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("https://github.com/") else {
        return false;
    };
    if rest.contains(['?', '#', '%', '@', '\\']) {
        return false;
    }
    let pieces = rest.trim_end_matches(".git").split('/').collect::<Vec<_>>();
    if pieces.len() != 2 && pieces.len() != 4 {
        return false;
    }
    if pieces[..2].iter().any(|part| !valid_label(part)) {
        return false;
    }
    if pieces.len() == 2 {
        return true;
    }
    pieces[2] == "pull"
        && pieces[3].parse::<u32>().is_ok_and(|number| number > 0)
        && !pieces[3].starts_with('0')
}

fn valid_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && value
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value
            .as_bytes()
            .last()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' || byte == b'.'
        })
        && value != "."
        && value != ".."
}

fn decode_component(value: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let raw = value.as_bytes();
    let mut index = 0;
    while index < raw.len() {
        if raw[index] == b'%' {
            if index + 2 >= raw.len() {
                return None;
            }
            let high = (raw[index + 1] as char).to_digit(16)? as u8;
            let low = (raw[index + 2] as char).to_digit(16)? as u8;
            bytes.push(high * 16 + low);
            index += 3;
        } else {
            bytes.push(raw[index]);
            index += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn encode_component(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                vec![char::from(byte).to_string()]
            }
            _ => vec![format!("%{byte:02X}")],
        })
        .collect()
}

/// Route parse failures intentionally expose no input or query data.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RouteError {
    Invalid,
}

impl fmt::Display for RouteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("invalid overalls route")
    }
}

impl std::error::Error for RouteError {}

#[cfg(test)]
mod tests {
    use super::{
        parse_activation_uris, ActivationBatch, ActivationRoute, MachinePage, NavigationDecision,
        Target,
    };

    const HOST: &str = "overalls://fleet.example";
    const ID: &str = "01234567-89ab-cdef-0123-456789abcdef";

    #[test]
    fn accepts_canonical_navigation_routes() {
        let route = ActivationRoute::parse(&format!("{HOST}/machines/{ID}/info")).expect("route");
        assert_eq!(route.canonical(), format!("{HOST}/machines/{ID}/info"));
        assert_eq!(
            route.target(),
            &Target::Machine {
                id: ID.to_owned(),
                page: MachinePage::Info,
            }
        );
    }

    #[test]
    fn rejects_unsafe_or_unknown_routes() {
        for value in [
            "http://fleet.example/machines",
            "overalls://Fleet.example/machines",
            "overalls://fleet.example/machines/%2F",
            "overalls://fleet.example/machines/not-an-id",
            "overalls://fleet.example/machines#fragment",
            "overalls://user@fleet.example/machines",
            "overalls://fleet.example/unknown",
        ] {
            assert!(ActivationRoute::parse(value).is_err(), "accepted {value}");
        }
    }

    #[test]
    fn route_parser_rejects_every_ascii_control_byte_in_authority() {
        // Property-style coverage over the full control-byte domain protects the
        // activation boundary from accidentally admitting a newly handled byte.
        for byte in 0u8..=31 {
            let control = char::from(byte);
            let value = format!("overalls://fleet{control}.example/machines");
            assert!(
                ActivationRoute::parse(&value).is_err(),
                "accepted byte {byte}"
            );
        }
        assert!(ActivationRoute::parse("overalls://fleet.example/machines").is_ok());
    }

    #[test]
    fn launch_query_round_trips_without_executing_it() {
        let route = ActivationRoute::parse(
            "overalls://fleet.example/launch?source=https%3A%2F%2Fgithub.com%2Fowner%2Frepo",
        )
        .expect("route");
        assert_eq!(
            route.canonical(),
            "overalls://fleet.example/launch?source=https%3A%2F%2Fgithub.com%2Fowner%2Frepo"
        );
        assert!(matches!(route.target(), Target::Launch { .. }));
    }

    #[test]
    fn parses_every_uri_in_a_multi_open_activation() {
        let values = [
            "overalls://fleet.example/machines",
            "overalls://fleet.example/settings",
            "https://fleet.example/machines",
        ];
        let results = parse_activation_uris(values);
        assert_eq!(results.len(), values.len());
        assert!(results[0].is_ok());
        assert!(results[1].is_ok());
        assert!(results[2].is_err());
    }

    #[test]
    fn activation_batch_keeps_only_typed_routes_and_bounds_open_count() {
        let mut values = vec![
            "overalls://fleet.example/machines",
            "https://fleet.example/machines",
        ];
        values.extend(std::iter::repeat("overalls://fleet.example/settings").take(65));
        let batch = ActivationBatch::parse(values);
        assert_eq!(batch.routes().len(), 2);
        assert_eq!(batch.rejected(), 65);
        assert_eq!(
            batch.canonical_routes()[0],
            "overalls://fleet.example/machines"
        );
        assert_eq!(
            batch.canonical_routes()[1],
            "overalls://fleet.example/settings"
        );
    }

    #[test]
    fn batch_decisions_preserve_authentication_fence() {
        let batch = ActivationBatch::parse([
            "overalls://fleet.example/machines",
            "overalls://other.example/settings",
        ]);
        let decisions = batch.decisions(Some("fleet.example"), false);
        assert!(matches!(
            decisions[0],
            NavigationDecision::SignInRequired { .. }
        ));
        assert!(matches!(
            decisions[1],
            NavigationDecision::UnknownDeployment { .. }
        ));
    }

    #[test]
    fn batch_decisions_never_include_rejected_or_cross_deployment_open() {
        let batch = ActivationBatch::parse([
            "overalls://fleet.example/machines",
            "https://fleet.example/machines",
            "overalls://other.example/settings",
        ]);
        assert_eq!(batch.rejected(), 1);
        let decisions = batch.decisions(Some("fleet.example"), true);
        assert_eq!(decisions.len(), 2);
        assert!(matches!(decisions[0], NavigationDecision::Open { .. }));
        assert!(matches!(
            decisions[1],
            NavigationDecision::UnknownDeployment { .. }
        ));
    }

    #[test]
    fn navigation_requires_the_selected_authenticated_deployment() {
        let route = ActivationRoute::parse(&format!("{HOST}/machines/{ID}/info")).expect("route");
        assert!(matches!(
            route.navigation(None, true),
            NavigationDecision::UnknownDeployment { .. }
        ));
        assert!(matches!(
            route.navigation(Some("fleet.example"), false),
            NavigationDecision::SignInRequired { .. }
        ));
        let decision = route.navigation(Some("fleet.example"), true);
        assert!(matches!(decision, NavigationDecision::Open { .. }));
        assert_eq!(decision.canonical(), format!("{HOST}/machines/{ID}/info"));
    }
}
