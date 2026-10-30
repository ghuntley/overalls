use crate::{config, http};
use fs2::FileExt;
use lyra::{ssh_certificate::Trust, ssh_files};
use std::fs::{self, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn validate(trust: &Trust, origin: &str, zone: &str) -> io::Result<()> {
    let host = reqwest::Url::parse(origin)
        .map_err(io::Error::other)?
        .host_str()
        .ok_or_else(|| io::Error::other("invalid origin"))?
        .to_owned();
    trust.validate(
        &host,
        zone,
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_secs(),
    )
}
fn read(path: &Path) -> io::Result<String> {
    optional_text(ssh_files::read(path, 8 * 1024 * 1024))
}

fn optional_text(result: io::Result<Vec<u8>>) -> io::Result<String> {
    match result {
        Ok(bytes) => String::from_utf8(bytes).map_err(io::Error::other),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(error),
    }
}

/// @cc [owner:ghuntley,label:security] lyra-ca-trust-installation
/// Only deployment-bound HTTPS policy may establish SSH CA trust. Updates MUST
/// be locked, atomic and symlink-safe, preserve unrelated entries, and refuse
/// managed CA changes or revocation rather than silently replacing trust.
/// Appending trust MUST NOT promote unmanaged trailing text into a managed
/// marker; a configuration that would splice that way refuses before any
/// write.
pub fn install(origin: &str, zone: &str) -> io::Result<Trust> {
    let bytes = http::request_exact(
        &format!("{origin}/bin/ssh-trust.json"),
        reqwest::StatusCode::OK,
        8192,
        Duration::from_secs(10),
    )?;
    let trust: Trust = serde_json::from_slice(&bytes)?;
    validate(&trust, origin, zone)?;
    let directory = config::home()?.join(".ssh");
    if !directory.try_exists()? {
        fs::create_dir(&directory)?;
    }
    if !fs::symlink_metadata(&directory)?.is_dir() {
        return Err(io::Error::other("invalid SSH directory"));
    }
    lyra::platform::restrict_directory(&directory)?;
    let lock = lyra::platform::open_private(
        &directory.join(".overalls-trust.lock"),
        OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false),
    )?;
    lock.try_lock_exclusive()?;
    let policy_path = directory.join("overalls-trust.json");
    let old = read(&policy_path)?;
    if !old.is_empty() {
        let existing: Trust = serde_json::from_str(&old)?;
        if existing.ca != trust.ca
            || existing.management_host != trust.management_host
            || existing.zone != trust.zone
        {
            return Err(io::Error::other(
                "SSH CA conflicts with installed trust; reconcile explicitly",
            ));
        }
    }
    let path = directory.join("known_hosts");
    let prior = read(&path)?;
    let content = merge(&prior, &trust)?;
    ssh_files::atomic(&path, content.as_bytes())?;
    ssh_files::atomic(&policy_path, &serde_json::to_vec(&trust)?)?;
    Ok(trust)
}
fn merge(prior: &str, trust: &Trust) -> io::Result<String> {
    for line in prior.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() >= 4
            && fields[0] == "@revoked"
            && format!("{} {}", fields[2], fields[3]) == trust.ca
        {
            return Err(io::Error::other("SSH CA is revoked"));
        }
    }
    let start = format!("# BEGIN OVERALLS SSH TRUST {}\n", trust.management_host);
    let end = format!("# END OVERALLS SSH TRUST {}\n", trust.management_host);
    let block = format!("{start}{}{end}", trust.known_hosts());
    match (prior.find(&start), prior.find(&end)) {
        (Some(a), Some(b))
            if a < b && prior.matches(&start).count() == 1 && prior.matches(&end).count() == 1 =>
        {
            if prior[a..b + end.len()] != block {
                return Err(io::Error::other("SSH CA trust conflicts"));
            }
            Ok(prior.to_owned())
        }
        (None, None) => {
            let result = format!(
                "{prior}{}{block}",
                if prior.is_empty() || prior.ends_with('\n') {
                    ""
                } else {
                    "\n"
                }
            );
            // Appending MUST NOT promote unmanaged trailing text into a
            // second managed marker at the separator joint.
            if result.matches(&start).count() == 1 && result.matches(&end).count() == 1 {
                Ok(result)
            } else {
                Err(io::Error::other("invalid managed SSH trust"))
            }
        }
        _ => Err(io::Error::other("invalid managed SSH trust")),
    }
}
pub fn load(origin: &str, zone: &str) -> io::Result<Trust> {
    let trust: Trust =
        serde_json::from_str(&read(&config::home()?.join(".ssh/overalls-trust.json"))?)?;
    validate(&trust, origin, zone)?;
    // Recheck the user-controlled revocation file on every connection.
    merge(&read(&config::home()?.join(".ssh/known_hosts"))?, &trust)?;
    Ok(trust)
}

/// Preserve OpenSSH revocation matching (including hashed names and CA keys)
/// while narrowing positive trust to the exact current gateway alias.
pub fn gateway_known_hosts(trust: &Trust, alias: &str) -> io::Result<String> {
    gateway_trust_files(
        trust,
        alias,
        &config::home()?.join(".ssh/known_hosts"),
        &system_known_hosts(),
    )
}

/// OpenSSH's system-wide known hosts: `/etc/ssh` on Unix and
/// `%ProgramData%\ssh` for Win32-OpenSSH.
fn system_known_hosts() -> PathBuf {
    if cfg!(windows) {
        let base = std::env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into());
        PathBuf::from(base).join("ssh").join("ssh_known_hosts")
    } else {
        PathBuf::from("/etc/ssh/ssh_known_hosts")
    }
}

fn gateway_trust_files(
    trust: &Trust,
    alias: &str,
    user: &Path,
    system: &Path,
) -> io::Result<String> {
    let mut content = format!("@cert-authority {alias} {}\n", trust.ca);
    content.push_str(&revocations(&read(user)?));
    content.push_str(&revocations(&optional_text(
        ssh_files::read_system_public_trust(system, 8 * 1024 * 1024),
    )?));
    Ok(content)
}

fn revocations(content: &str) -> String {
    content
        .lines()
        .filter(|line| line.split_whitespace().next() == Some("@revoked"))
        .map(|line| format!("{line}\n"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    fn policy() -> Trust {
        Trust {
            version: 1,
            ca: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                .into(),
            management_host: "example.test".into(),
            zone: "apps.example.test".into(),
            retirement: u64::MAX,
        }
    }
    #[test]
    fn revocation_and_conflicting_managed_authority_are_preserved_and_refused() {
        let policy = policy();
        assert!(merge(&format!("@revoked * {}\n", policy.ca), &policy).is_err());
        let initial = merge("unrelated ssh-ed25519 old\n", &policy).unwrap();
        assert!(merge(&initial.replace(&policy.ca, "ssh-ed25519 other"), &policy).is_err());
        assert_eq!(merge(&initial, &policy).unwrap(), initial);
    }
    #[test]
    fn gateway_preserves_revocations_without_importing_other_authorities() {
        let lines = "@cert-authority * other\n@revoked |1|hash|hash ssh-ed25519 key\n  @revoked *.test ssh-ed25519 ca\n";
        assert_eq!(
            revocations(lines),
            "@revoked |1|hash|hash ssh-ed25519 key\n  @revoked *.test ssh-ed25519 ca\n"
        );
    }
    #[test]
    fn gateway_reads_system_trust_symlinks_and_preserves_revocations() {
        let root = tempfile::tempdir().unwrap();
        let system = root.path().join("system");
        let target = root.path().join("immutable-config");
        let user = root.path().join("user");
        fs::write(&target, "@revoked * ssh-ed25519 revoked\n").unwrap();
        std::os::unix::fs::symlink(&target, &system).unwrap();
        let trust = policy();
        assert_eq!(
            gateway_trust_files(&trust, "gateway.test", &user, &system).unwrap(),
            format!(
                "@cert-authority gateway.test {}\n@revoked * ssh-ed25519 revoked\n",
                trust.ca
            )
        );
        std::os::unix::fs::symlink(&target, &user).unwrap();
        assert!(gateway_trust_files(&trust, "gateway.test", &user, &system).is_err());
    }
    /// @cc [owner:ghuntley,label:verification] installer-generated-refusal-preserves-state
    /// Generated revocations MUST dominate matching CA trust in every ordering,
    /// including hashed host selectors. Conflicting managed blocks MUST fail
    /// without producing replacement trust.
    #[hegel::test(test_cases = 100)]
    fn generated_denials_dominate_matching_ca_trust(tc: TestCase) {
        let leading = tc.draw(gs::integers::<u8>());
        let trailing = tc.draw(gs::integers::<u8>());
        let trust = policy();
        let matching = merge("", &trust).unwrap();
        for selector in [
            "*",
            "|1|AAAAAAAAAAAAAAAAAAAAAAAAAAA=|AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        ] {
            let prior = format!(
                "{}@revoked {selector} {}\n{matching}{}",
                "# unrelated\n".repeat(usize::from(leading)),
                trust.ca,
                "# retained\n".repeat(usize::from(trailing)),
            );
            assert!(merge(&prior, &trust).is_err());
        }
        let conflict = matching.replace(&trust.ca, "ssh-ed25519 invalid");
        assert!(merge(&format!("{conflict}{matching}"), &trust).is_err());
        assert!(merge(&format!("{matching}{conflict}"), &trust).is_err());
    }
    #[hegel::test(test_cases = 100)]
    fn repeated_installation_preserves_unrelated_lines(tc: TestCase) {
        let number = tc.draw(gs::integers::<u64>());
        let prior = format!("other-{number}.test ssh-ed25519 test\n");
        let first = merge(&prior, &policy()).unwrap();
        assert!(first.starts_with(&prior));
        assert_eq!(merge(&first, &policy()).unwrap(), first);
    }

    #[test]
    fn dangling_marker_text_is_refused_rather_than_promoted() {
        let trust = policy();
        // A trailing dangling marker line must not become an empty managed
        // block when the separator newline is appended.
        let dangling = format!("# BEGIN OVERALLS SSH TRUST {}", trust.management_host);
        assert!(merge(&dangling, &trust).is_err());
        assert!(merge(&dangling, &trust).is_err());
        let plain = "other.test ssh-ed25519 AAAABBBB";
        let first = merge(plain, &trust).unwrap();
        assert!(first.starts_with(plain));
        assert_eq!(merge(&first, &trust).unwrap(), first);
    }
    // Generated adjacent-but-unmanaged content: foreign hosts, non-matching
    // revocations, hashed selectors, and dangling marker text that lacks the
    // exact marker bytes for this trust's management host.
    const KNOWN_HOST_FRAGMENTS: &[&str] = &[
        "",
        "other.test ssh-ed25519 AAAABBBB\n",
        "@revoked * ssh-rsa AAAACCCC\n",
        "# BEGIN OVERALLS SSH TRUST other.test\nother.test ssh-ed25519 AAAADDDD\n# END OVERALLS SSH TRUST other.test\n",
        "|1|aGFzaGVk aGFzaGVk ssh-ed25519 AAAAEEEE\n",
        "# BEGIN OVERALLS SSH TRUST example.test",
        "# END OVERALLS SSH TRUST example.test",
    ];

    /// @cc [owner:ghuntley,label:verification] installer-generated-known-hosts-preservation
    /// Generated pre-existing known-hosts configurations MUST keep every
    /// unrelated byte in its exact position; reinstall over real output MUST
    /// converge byte-identically with exactly one managed marker pair.
    #[hegel::test(test_cases = 64)]
    fn generated_known_hosts_configurations_preserve_unrelated_bytes(tc: TestCase) {
        let before = tc.draw(gs::sampled_from(KNOWN_HOST_FRAGMENTS));
        let after = tc.draw(gs::sampled_from(KNOWN_HOST_FRAGMENTS));
        let reinstall = tc.draw(gs::booleans());
        let trust = policy();
        let start = format!("# BEGIN OVERALLS SSH TRUST {}\n", trust.management_host);
        let end = format!("# END OVERALLS SSH TRUST {}\n", trust.management_host);
        let block = format!("{start}{}{end}", trust.known_hosts());
        let prior = if reinstall {
            format!("{before}{block}{after}")
        } else {
            format!("{before}{after}")
        };
        if reinstall {
            let first = merge(&prior, &trust).unwrap();
            assert_eq!(first, prior);
            assert_eq!(merge(&first, &trust).unwrap(), first);
            return;
        }
        // Independent expectation: the fresh append preserves every prior byte
        // when the spliced candidate carries exactly one managed marker pair;
        // promotion of unmanaged trailing text into a marker refuses closed.
        let separator = if prior.is_empty() || prior.ends_with('\n') {
            ""
        } else {
            "\n"
        };
        let candidate = format!("{prior}{separator}{block}");
        if candidate.matches(&start).count() == 1 && candidate.matches(&end).count() == 1 {
            let first = merge(&prior, &trust).unwrap();
            assert_eq!(first, candidate);
            assert!(first.starts_with(&prior));
            assert_eq!(merge(&first, &trust).unwrap(), first);
        } else {
            assert!(merge(&prior, &trust).is_err());
            assert!(merge(&prior, &trust).is_err());
        }
    }

    /// @cc [owner:ghuntley,label:verification] installer-generated-known-hosts-refusal
    /// Generated ambiguous managed-marker arrangements and conflicting managed
    /// interiors MUST be refused on every attempt, never producing replacement
    /// trust.
    #[hegel::test(test_cases = 64)]
    fn generated_known_hosts_marker_ambiguity_is_refused(tc: TestCase) {
        #[derive(Clone, Copy, Debug)]
        enum Ambiguity {
            TwoBegins,
            TwoEnds,
            TwoPairs,
            Reversed,
        }
        let ambiguity = tc.draw(gs::sampled_from(&[
            Ambiguity::TwoBegins,
            Ambiguity::TwoEnds,
            Ambiguity::TwoPairs,
            Ambiguity::Reversed,
        ]));
        let before = tc.draw(gs::sampled_from(KNOWN_HOST_FRAGMENTS));
        let after = tc.draw(gs::sampled_from(KNOWN_HOST_FRAGMENTS));
        let trust = policy();
        let start = format!("# BEGIN OVERALLS SSH TRUST {}\n", trust.management_host);
        let end = format!("# END OVERALLS SSH TRUST {}\n", trust.management_host);
        let block = format!("{start}{}{end}", trust.known_hosts());
        let prior = match ambiguity {
            Ambiguity::TwoBegins => format!("{before}{start}{start}{after}"),
            Ambiguity::TwoEnds => format!("{before}{end}{end}{after}"),
            Ambiguity::TwoPairs => format!("{before}{block}{block}{after}"),
            Ambiguity::Reversed => format!("{before}{end}{after}{start}"),
        };
        assert!(merge(&prior, &trust).is_err());
        assert!(merge(&prior, &trust).is_err());
    }
}
