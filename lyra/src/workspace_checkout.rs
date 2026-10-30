//! Guest-only ref and change-head resolution. Source identity remains immutable.
use crate::workspace_receiver::GitRunner;
use crate::workspace_source::{valid_commit, Provider, Revision, WorkspaceSource};
use serde::Deserialize;
use std::io::{self, Read};
use std::time::Duration;

const MAXIMUM_RESPONSE: u64 = 1_048_576;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ObjectFormat {
    Sha1,
    Sha256,
}
impl ObjectFormat {
    fn for_commit(value: &str) -> Self {
        if value.len() == 64 {
            Self::Sha256
        } else {
            Self::Sha1
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CheckoutRevision {
    Default,
    Commit(String),
    Ref(String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkout {
    pub url: String,
    pub revision: CheckoutRevision,
    pub object_format: ObjectFormat,
}

/// @cc [owner:ghuntley,label:security;protocol] workspace-checkout-resolution
/// Source identity MUST remain unchanged. Named links select the longest advertised
/// matching branch/tag, with branches winning equal-name ties. Change-head URLs MUST
/// remain on the source provider's exact HTTPS origin with no redirects or credentials.
pub fn resolve(source: &WorkspaceSource, git: &mut impl GitRunner) -> io::Result<Checkout> {
    let url = source.clone_url();
    let mut object_format = ObjectFormat::Sha1;
    let revision = match source.revision() {
        Revision::Default => CheckoutRevision::Default,
        Revision::Commit { value } => {
            if value.len() == 40 {
                // Forty digits can also abbreviate an object in a SHA256 repository.
                let output = git.output(&[
                    "ls-remote".into(),
                    "--heads".into(),
                    "--tags".into(),
                    "--".into(),
                    url.clone(),
                ])?;
                if let Some((_, _, format)) = advertised_refs(&output)?.first() {
                    object_format = *format;
                }
            } else {
                object_format = ObjectFormat::for_commit(value);
            }
            CheckoutRevision::Commit(value.clone())
        }
        Revision::Ref { value } | Revision::Tag { value } => {
            let output = git.output(&[
                "ls-remote".into(),
                "--heads".into(),
                "--tags".into(),
                "--".into(),
                url.clone(),
            ])?;
            match select_ref(
                value,
                matches!(source.revision(), Revision::Tag { .. }),
                &output,
            ) {
                Ok((reference, format)) => {
                    object_format = format;
                    CheckoutRevision::Ref(reference)
                }
                Err(error) => {
                    // Provider tree/src links can carry an object ID and a file path.
                    // Advertised refs always win ambiguity, including hex branch names.
                    let object = value.split('/').next().unwrap_or_default();
                    if error.kind() == io::ErrorKind::NotFound
                        && matches!(source.revision(), Revision::Ref { .. })
                        && valid_commit(object)
                    {
                        if object.len() == 64 {
                            object_format = ObjectFormat::Sha256;
                        } else if let Some((_, _, format)) = advertised_refs(&output)?.first() {
                            object_format = *format;
                        } else {
                            object_format = ObjectFormat::for_commit(object);
                        }
                        CheckoutRevision::Commit(object.to_ascii_lowercase())
                    } else {
                        return Err(error);
                    }
                }
            }
        }
        Revision::Change { value } => match source.provider() {
            Provider::Github | Provider::Gitlab => {
                let reference = match source.provider() {
                    Provider::Github => format!("refs/pull/{value}/head"),
                    _ => format!("refs/merge-requests/{value}/head"),
                };
                let output = git.output(&[
                    "ls-remote".into(),
                    "--".into(),
                    url.clone(),
                    reference.clone(),
                ])?;
                object_format = advertised_refs(&output)?
                    .into_iter()
                    .find(|(_, name, _)| *name == reference)
                    .map(|(_, _, format)| format)
                    .ok_or_else(|| {
                        io::Error::new(io::ErrorKind::NotFound, "workspace ref unavailable")
                    })?;
                CheckoutRevision::Ref(reference)
            }
            Provider::Codeberg | Provider::Bitbucket => return git.change_head(source),
        },
    };
    Ok(Checkout {
        url,
        revision,
        object_format,
    })
}
/// @cc [owner:ghuntley,label:protocol] workspace-checkout-object-format
/// Selected advertised refs MUST retain their Git object format. A listing with
/// mixed SHA1 and SHA256 object IDs MUST refuse rather than choose a format.
/// Parse bounded advertised refs without allowing remote strings into git argv.
pub fn select_ref(
    value: &str,
    tag_only: bool,
    output: &[u8],
) -> io::Result<(String, ObjectFormat)> {
    let refs = advertised_refs(output)?;
    let mut selected: Option<(&str, bool, ObjectFormat)> = None;
    for (_, reference, format) in refs {
        let (name, branch) = if let Some(name) = reference.strip_prefix("refs/heads/") {
            (name, true)
        } else if let Some(name) = reference.strip_prefix("refs/tags/") {
            (name, false)
        } else {
            continue;
        };
        if name.ends_with("^{}")
            || tag_only && branch
            || !(value == name
                || value
                    .strip_prefix(name)
                    .is_some_and(|tail| tail.starts_with('/')))
        {
            continue;
        }
        // Prefixes come from validated user input, never unchecked remote names.
        if selected.is_none_or(|(old, old_branch, _)| {
            name.len() > old.len() || name.len() == old.len() && branch && !old_branch
        }) {
            selected = Some((name, branch, format));
        }
    }
    selected
        .map(|(name, branch, format)| {
            (
                format!("refs/{}/{name}", if branch { "heads" } else { "tags" }),
                format,
            )
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "workspace ref unavailable"))
}
fn advertised_refs(output: &[u8]) -> io::Result<Vec<(&str, &str, ObjectFormat)>> {
    if output.len() as u64 > MAXIMUM_RESPONSE {
        return Err(refused());
    }
    let output = std::str::from_utf8(output).map_err(|_| refused())?;
    let mut refs = Vec::new();
    let mut object_format: Option<ObjectFormat> = None;
    for line in output.lines() {
        let Some((sha, reference)) = line.split_once('\t') else {
            return Err(refused());
        };
        if !matches!(sha.len(), 40 | 64) || !valid_commit(sha) {
            return Err(refused());
        }
        let format = ObjectFormat::for_commit(sha);
        if object_format.is_some_and(|previous| previous != format) {
            return Err(refused());
        }
        object_format = Some(format);
        refs.push((sha, reference, format));
    }
    Ok(refs)
}
fn refused() -> io::Error {
    io::Error::other("workspace checkout refused")
}
#[derive(Deserialize)]
struct CodebergPull {
    head: CodebergHead,
}
#[derive(Deserialize)]
struct CodebergHead {
    repo: CodebergRepo,
    sha: String,
}
#[derive(Deserialize)]
struct CodebergRepo {
    clone_url: String,
}
#[derive(Deserialize)]
struct BitbucketPull {
    source: BitbucketSource,
}
#[derive(Deserialize)]
struct BitbucketSource {
    repository: BitbucketRepo,
    commit: BitbucketCommit,
}
#[derive(Deserialize)]
struct BitbucketRepo {
    links: BitbucketLinks,
}
#[derive(Deserialize)]
struct BitbucketLinks {
    clone: Vec<BitbucketClone>,
}
#[derive(Deserialize)]
struct BitbucketClone {
    name: String,
    href: String,
}
#[derive(Deserialize)]
struct BitbucketCommit {
    hash: String,
}

pub fn api_url(source: &WorkspaceSource) -> io::Result<String> {
    let Revision::Change { value } = source.revision() else {
        return Err(refused());
    };
    match source.provider() {
        Provider::Codeberg => Ok(format!(
            "https://codeberg.org/api/v1/repos/{}/pulls/{value}",
            source.display_name()
        )),
        Provider::Bitbucket => Ok(format!(
            "https://api.bitbucket.org/2.0/repositories/{}/pullrequests/{value}",
            source.display_name()
        )),
        _ => Err(refused()),
    }
}
pub fn decode_head(provider: Provider, bytes: &[u8]) -> io::Result<Checkout> {
    if bytes.len() as u64 > MAXIMUM_RESPONSE {
        return Err(refused());
    }
    let (url, sha) = match provider {
        Provider::Codeberg => {
            let pull: CodebergPull = serde_json::from_slice(bytes).map_err(|_| refused())?;
            (pull.head.repo.clone_url, pull.head.sha)
        }
        Provider::Bitbucket => {
            let pull: BitbucketPull = serde_json::from_slice(bytes).map_err(|_| refused())?;
            let url = pull
                .source
                .repository
                .links
                .clone
                .into_iter()
                .find(|entry| entry.name == "https")
                .ok_or_else(refused)?
                .href;
            (url, pull.source.commit.hash)
        }
        _ => return Err(refused()),
    };
    let parsed = crate::workspace_source::parse_url(&url).map_err(|_| refused())?;
    // A clone URL is precisely a root identity, with an optional .git suffix.
    if parsed.provider() != provider
        || !matches!(parsed.revision(), Revision::Default)
        || !(url == parsed.to_url() || url == parsed.clone_url())
        || !matches!(sha.len(), 40 | 64)
        || !valid_commit(&sha)
    {
        return Err(refused());
    }
    Ok(Checkout {
        url: parsed.clone_url(),
        object_format: ObjectFormat::for_commit(&sha),
        revision: CheckoutRevision::Commit(sha.to_ascii_lowercase()),
    })
}
pub fn fetch_head(source: &WorkspaceSource, ca_bundle: &std::path::Path) -> io::Result<Checkout> {
    let mut builder = reqwest::blocking::Client::builder()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .user_agent("overalls-workspaced/0.1");
    // Guest fixture and production trust both use the image's root bundle.
    let certificates = std::fs::read(ca_bundle).map_err(|_| refused())?;
    for certificate in
        reqwest::Certificate::from_pem_bundle(&certificates).map_err(|_| refused())?
    {
        builder = builder.add_root_certificate(certificate);
    }
    let client = builder.build().map_err(|_| refused())?;
    let response = client.get(api_url(source)?).send().map_err(|_| refused())?;
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|len| len > MAXIMUM_RESPONSE)
    {
        return Err(refused());
    }
    let mut bytes = Vec::new();
    response
        .take(MAXIMUM_RESPONSE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| refused())?;
    decode_head(source.provider(), &bytes)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn longest_ref_and_branch_tie() {
        let sha = "a".repeat(40);
        let refs = format!(
            "{sha}\trefs/heads/feature\n{sha}\trefs/tags/feature/x\n{sha}\trefs/heads/feature/x\n"
        );
        assert_eq!(
            select_ref("feature/x/path", false, refs.as_bytes()).unwrap(),
            ("refs/heads/feature/x".into(), ObjectFormat::Sha1)
        );
        assert_eq!(
            select_ref("feature/x/path", true, refs.as_bytes()).unwrap(),
            ("refs/tags/feature/x".into(), ObjectFormat::Sha1)
        );
        assert!(select_ref("missing", false, refs.as_bytes()).is_err());
    }
    #[test]
    fn change_heads_reject_foreign_origins_and_oversized_bodies() {
        let sha = "a".repeat(40);
        for url in [
            "https://evil.test/a/b.git",
            "https://u@codeberg.org/a/b.git",
            "https://codeberg.org:443/a/b.git",
            "https://codeberg.org/a/b.git?token=x",
        ] {
            assert!(decode_head(
                Provider::Codeberg,
                format!(r#"{{"head":{{"repo":{{"clone_url":"{url}"}},"sha":"{sha}"}}}}"#)
                    .as_bytes()
            )
            .is_err());
        }
        let body = format!(
            r#"{{"head":{{"repo":{{"clone_url":"https://codeberg.org/fork/repo.git"}},"sha":"{sha}"}}}}"#
        );
        assert_eq!(
            decode_head(Provider::Codeberg, body.as_bytes())
                .unwrap()
                .url,
            "https://codeberg.org/fork/repo.git"
        );
        assert!(decode_head(
            Provider::Codeberg,
            &vec![b' '; usize::try_from(MAXIMUM_RESPONSE).unwrap() + 1]
        )
        .is_err());
    }
}
