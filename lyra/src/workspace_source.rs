//! Closed source-v2 identities, shared with OverallsProtocol.WorkspaceSource.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Github,
    Gitlab,
    Codeberg,
    Bitbucket,
}
impl Provider {
    pub fn host(self) -> &'static str {
        match self {
            Self::Github => "github.com",
            Self::Gitlab => "gitlab.com",
            Self::Codeberg => "codeberg.org",
            Self::Bitbucket => "bitbucket.org",
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Github => "github",
            Self::Gitlab => "gitlab",
            Self::Codeberg => "codeberg",
            Self::Bitbucket => "bitbucket",
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Revision {
    Default,
    Ref { value: String },
    Tag { value: String },
    Commit { value: String },
    Change { value: u32 },
}
/// Fields remain private: only validated construction is permitted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceSource {
    provider: Provider,
    namespace: Vec<String>,
    repository: String,
    revision: Revision,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    InvalidUrl,
    UnsupportedHost,
    InvalidNamespace,
    InvalidRepository,
    InvalidReference,
}
impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidUrl => "invalid_url",
            Self::UnsupportedHost => "unsupported_host",
            Self::InvalidNamespace => "invalid_namespace",
            Self::InvalidRepository => "invalid_repository",
            Self::InvalidReference => "invalid_reference",
        }
    }
}
impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidMessage;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Wire {
    version: u8,
    provider: Provider,
    namespace: Vec<String>,
    repository: String,
    revision: Revision,
}
impl WorkspaceSource {
    pub fn provider(&self) -> Provider {
        self.provider
    }
    pub fn namespace(&self) -> &[String] {
        &self.namespace
    }
    pub fn repository(&self) -> &str {
        &self.repository
    }
    pub fn revision(&self) -> &Revision {
        &self.revision
    }
    pub fn display_name(&self) -> String {
        format!("{}/{}", self.namespace.join("/"), self.repository)
    }
    pub fn clone_url(&self) -> String {
        format!(
            "https://{}/{}.git",
            self.provider.host(),
            self.display_name()
        )
    }
    #[expect(
        clippy::match_same_arms,
        reason = "one arm per provider and revision keeps the URL table readable"
    )]
    pub fn to_url(&self) -> String {
        let base = format!("https://{}/{}", self.provider.host(), self.display_name());
        let suffix = match (&self.provider, &self.revision) {
            (_, Revision::Default) => String::new(),
            (Provider::Github, Revision::Ref { value }) => format!("/tree/{value}"),
            (Provider::Github, Revision::Tag { value }) => format!("/releases/tag/{value}"),
            (Provider::Github, Revision::Commit { value }) => format!("/commit/{value}"),
            (Provider::Github, Revision::Change { value }) => format!("/pull/{value}"),
            (Provider::Gitlab, Revision::Ref { value }) => format!("/-/tree/{value}"),
            (Provider::Gitlab, Revision::Tag { value }) => format!("/-/tags/{value}"),
            (Provider::Gitlab, Revision::Commit { value }) => format!("/-/commit/{value}"),
            (Provider::Gitlab, Revision::Change { value }) => format!("/-/merge_requests/{value}"),
            (Provider::Codeberg, Revision::Ref { value }) => format!("/src/branch/{value}"),
            (Provider::Codeberg, Revision::Tag { value }) => format!("/src/tag/{value}"),
            (Provider::Codeberg, Revision::Commit { value }) => format!("/commit/{value}"),
            (Provider::Codeberg, Revision::Change { value }) => format!("/pulls/{value}"),
            (Provider::Bitbucket, Revision::Ref { value }) => format!("/src/{value}"),
            (Provider::Bitbucket, Revision::Commit { value }) => format!("/commits/{value}"),
            (Provider::Bitbucket, Revision::Change { value }) => format!("/pull-requests/{value}"),
            (Provider::Bitbucket, Revision::Tag { .. }) => {
                unreachable!("validated provider revision")
            }
        };
        format!("{base}{suffix}")
    }
    pub fn encode(&self) -> Value {
        serde_json::json!({"version":2,"provider":self.provider,"namespace":self.namespace,"repository":self.repository,"revision":self.revision})
    }
}

/// @cc [owner:ghuntley,label:security;protocol] lyra-workspace-source-closed-grammar
/// Parsing and decoding MUST agree with the Elixir source-v2 language. Hosts,
/// revision kinds and fields are closed; no accepted argument introduces options,
/// traversal, shell syntax or an arbitrary network origin.
pub fn parse_url(url: &str) -> Result<WorkspaceSource, Refusal> {
    if url.len() > 1024 {
        return Err(Refusal::InvalidUrl);
    }
    let stripped = url.split(['?', '#']).next().unwrap_or_default();
    let (provider, path) = [
        Provider::Github,
        Provider::Gitlab,
        Provider::Codeberg,
        Provider::Bitbucket,
    ]
    .into_iter()
    .find_map(|p| {
        stripped
            .strip_prefix(&format!("https://{}/", p.host()))
            .map(|path| (p, path))
    })
    .ok_or(
        if stripped.starts_with("https://") || stripped.starts_with("http://") {
            Refusal::UnsupportedHost
        } else {
            Refusal::InvalidUrl
        },
    )?;
    let parts: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    let (namespace, repository, rest) = if provider == Provider::Gitlab {
        let end = parts.iter().position(|p| *p == "-").unwrap_or(parts.len());
        if end < 2 {
            return Err(Refusal::InvalidUrl);
        }
        (&parts[..end - 1], parts[end - 1], &parts[end..])
    } else {
        let [_, repository, rest @ ..] = parts.as_slice() else {
            return Err(Refusal::InvalidUrl);
        };
        (&parts[..1], *repository, rest)
    };
    if !valid_namespace(provider, namespace) {
        return Err(Refusal::InvalidNamespace);
    }
    let repository = repository.strip_suffix(".git").unwrap_or(repository);
    if !valid_repository(repository) {
        return Err(Refusal::InvalidRepository);
    }
    Ok(WorkspaceSource {
        provider,
        namespace: namespace.iter().map(|v| (*v).to_owned()).collect(),
        repository: repository.to_owned(),
        revision: parse_revision(provider, rest)?,
    })
}
fn parse_revision(provider: Provider, rest: &[&str]) -> Result<Revision, Refusal> {
    match (provider, rest) {
        (_, []) => Ok(Revision::Default),
        (Provider::Github, ["tree", parts @ ..])
        | (Provider::Gitlab, ["-", "tree", parts @ ..])
        | (Provider::Codeberg, ["src", "branch", parts @ ..])
        | (Provider::Bitbucket, ["src", parts @ ..]) => named(false, parts),
        (Provider::Github | Provider::Codeberg, ["releases", "tag", parts @ ..])
        | (Provider::Gitlab, ["-", "tags" | "releases", parts @ ..])
        | (Provider::Codeberg, ["src", "tag", parts @ ..]) => named(true, parts),
        (Provider::Github | Provider::Codeberg, ["commit", value])
        | (Provider::Gitlab, ["-", "commit", value])
        | (Provider::Bitbucket, ["commits", value]) => commit(value),
        (Provider::Codeberg, ["src", "commit", value, parts @ ..])
            if parts.is_empty() || valid_named(&parts.join("/")) =>
        {
            commit(value)
        }
        (Provider::Github, ["pull", value, tab @ ..]) => {
            change(value, tab, &["files", "commits", "checks"])
        }
        (Provider::Gitlab, ["-", "merge_requests", value, tab @ ..]) => {
            change(value, tab, &["diffs", "commits", "pipelines", "changes"])
        }
        (Provider::Codeberg, ["pulls", value, tab @ ..]) => {
            change(value, tab, &["files", "commits"])
        }
        (Provider::Bitbucket, ["pull-requests", value, tab @ ..]) => {
            change(value, tab, &["diff", "commits", "activity"])
        }
        _ => Err(Refusal::InvalidReference),
    }
}
fn named(tag: bool, parts: &[&str]) -> Result<Revision, Refusal> {
    let value = parts.join("/");
    if !valid_named(&value) {
        return Err(Refusal::InvalidReference);
    }
    Ok(if tag {
        Revision::Tag { value }
    } else {
        Revision::Ref { value }
    })
}
fn commit(value: &str) -> Result<Revision, Refusal> {
    if valid_commit(value) {
        Ok(Revision::Commit {
            value: value.to_ascii_lowercase(),
        })
    } else {
        Err(Refusal::InvalidReference)
    }
}
fn change(value: &str, tabs: &[&str], allowed: &[&str]) -> Result<Revision, Refusal> {
    if value.starts_with('0')
        || value.len() > 10
        || !value.bytes().all(|b| b.is_ascii_digit())
        || !(tabs.is_empty() || tabs.len() == 1 && allowed.contains(&tabs[0]))
    {
        return Err(Refusal::InvalidReference);
    }
    let value = value
        .parse::<u32>()
        .map_err(|_| Refusal::InvalidReference)?;
    if value == 0 || value > i32::MAX as u32 {
        return Err(Refusal::InvalidReference);
    }
    Ok(Revision::Change { value })
}
#[expect(
    clippy::case_sensitive_file_extension_comparisons,
    reason = "Git names are case-sensitive; only the exact lowercase suffix is reserved"
)]
pub fn decode(value: &Value) -> Result<WorkspaceSource, InvalidMessage> {
    let wire: Wire = serde_json::from_value(value.clone()).map_err(|_| InvalidMessage)?;
    if wire.version != 2
        || !valid_namespace(
            wire.provider,
            &wire
                .namespace
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        )
        || !valid_repository(&wire.repository)
        || wire.repository.ends_with(".git")
        || !valid_revision(&wire.revision)
        || wire.provider == Provider::Bitbucket && matches!(wire.revision, Revision::Tag { .. })
    {
        return Err(InvalidMessage);
    }
    let source = WorkspaceSource {
        provider: wire.provider,
        namespace: wire.namespace,
        repository: wire.repository,
        revision: wire.revision,
    };
    if source.to_url().len() > 1024 {
        return Err(InvalidMessage);
    }
    Ok(source)
}
fn valid_namespace(provider: Provider, parts: &[&str]) -> bool {
    if parts.is_empty()
        || provider != Provider::Gitlab && parts.len() != 1
        || parts.join("/").len() > 255
    {
        return false;
    }
    if provider == Provider::Github {
        let value = parts[0];
        return (1..=39).contains(&value.len())
            && !value.starts_with('-')
            && !value.ends_with('-')
            && !value.contains("--")
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-');
    }
    parts.iter().all(|p| {
        (1..=100).contains(&p.len())
            && p.bytes()
                .next()
                .is_some_and(|b| b.is_ascii_alphanumeric() || b == b'_')
            && p.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            && !p.contains("..")
    })
}
#[expect(
    clippy::case_sensitive_file_extension_comparisons,
    reason = "Git names are case-sensitive; only the exact lowercase suffix is reserved"
)]
fn valid_repository(value: &str) -> bool {
    (1..=100).contains(&value.len())
        && !value.starts_with('-')
        && ![".", ".."].contains(&value)
        && !value.ends_with(".git")
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
#[expect(
    clippy::case_sensitive_file_extension_comparisons,
    reason = "Git names are case-sensitive; only the exact lowercase suffix is reserved"
)]
fn valid_named(value: &str) -> bool {
    (1..=255).contains(&value.len())
        && value != "@"
        && !value.contains("..")
        && !value.ends_with('.')
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._/@+=,-".contains(&b))
        && value
            .split('/')
            .all(|p| !p.is_empty() && !p.starts_with(['.', '-']) && !p.ends_with(".lock"))
}
pub fn valid_commit(value: &str) -> bool {
    (7..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn valid_revision(revision: &Revision) -> bool {
    match revision {
        Revision::Default => true,
        Revision::Ref { value } | Revision::Tag { value } => valid_named(value),
        Revision::Commit { value } => valid_commit(value) && value.to_ascii_lowercase() == *value,
        Revision::Change { value } => *value > 0 && i32::try_from(*value).is_ok(),
    }
}
