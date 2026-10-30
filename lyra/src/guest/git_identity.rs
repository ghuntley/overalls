//! Public Git attribution carried by the current boot, never used as authority.
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::Path;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GitIdentity {
    version: u8,
    name: String,
    email: String,
}

fn valid_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    (3..=254).contains(&value.len())
        && local.split('.').all(|part| {
            !part.is_empty()
                && part.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || b"!#$%&'*+/=?^_`{|}~-".contains(&byte)
                })
        })
        && domain.split('.').all(|part| {
            !part.is_empty()
                && part
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && part
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

impl GitIdentity {
    /// @cc [owner:ghuntley,label:security;protocol] guest-git-attribution-closed-grammar
    /// Version-1 attribution MUST preserve a trimmed 1..128-byte UTF-8 name
    /// without Unicode Cc/Cf characters or angle brackets and a 3..254-byte
    /// ASCII dot-atom mailbox with nonempty DNS labels. Invalid values MUST refuse.
    pub fn validate(&self) -> io::Result<()> {
        let field = |value: &str, maximum: usize| {
            !value.is_empty()
                && value.len() <= maximum
                && value.trim() == value
                && !value.chars().any(|c| {
                    matches!(
                        unicode_general_category::get_general_category(c),
                        unicode_general_category::GeneralCategory::Control
                            | unicode_general_category::GeneralCategory::Format
                    ) || matches!(c, '<' | '>')
                })
        };
        if self.version != 1 || !field(&self.name, 128) || !valid_email(&self.email) {
            return Err(io::Error::other("invalid git identity"));
        }
        Ok(())
    }

    pub fn parse(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() > 2048 {
            return Err(io::Error::other("invalid git identity"));
        }
        let value: Self =
            serde_json::from_slice(bytes).map_err(|_| io::Error::other("invalid git identity"))?;
        value.validate()?;
        Ok(value)
    }

    fn configuration(&self) -> io::Result<String> {
        self.validate()?;
        let escape = |value: &str| value.replace('\\', "\\\\").replace('"', "\\\"");
        Ok(format!(
            "[user]\n\tname = \"{}\"\n\temail = \"{}\"\n",
            escape(&self.name),
            escape(&self.email)
        ))
    }
}

/// @cc [owner:ghuntley,label:security;protocol] guest-git-identity-single-boot-value
/// The kernel command line MUST contain at most one identity, encoded as unpadded
/// base64url version-1 JSON. Malformed, duplicate or oversized values MUST refuse.
pub fn from_command_line(line: &str) -> io::Result<Option<GitIdentity>> {
    let mut identities = line
        .split_ascii_whitespace()
        .filter_map(|part| part.strip_prefix("lilly.git_identity="));
    let Some(encoded) = identities.next() else {
        return Ok(None);
    };
    if encoded.len() > 2731 || identities.next().is_some() {
        return Err(io::Error::other("invalid git identity"));
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| io::Error::other("invalid git identity"))?;
    GitIdentity::parse(&bytes).map(Some)
}

/// @cc [owner:ghuntley,label:security;recovery] guest-git-identity-runtime-file
/// Before accepting workspace requests the guest MUST publish current boot Git
/// attribution in a daemon-owned runtime include, even without a source request.
/// Missing identity MUST clear the include, and existing links or writable parent
/// directories MUST refuse rather than redirect privileged writes.
pub fn install(directory: &Path, identity: Option<&GitIdentity>) -> io::Result<()> {
    use std::io::Write;
    fs::create_dir_all(directory)?;
    let metadata = fs::symlink_metadata(directory)?;
    if !metadata.file_type().is_dir() {
        return Err(io::Error::other("invalid git identity directory"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid has no preconditions and cannot fail.
        let euid = unsafe { libc::geteuid() };
        if fs::canonicalize(directory)? != directory
            || metadata.uid() != euid
            || metadata.mode() & 0o022 != 0
        {
            return Err(io::Error::other("invalid git identity directory"));
        }
        fs::set_permissions(directory, fs::Permissions::from_mode(0o755))?;
    }
    let path = directory.join("gitconfig");
    match fs::symlink_metadata(&path) {
        Ok(metadata) if !metadata.file_type().is_file() => {
            return Err(io::Error::other("invalid git identity file"))
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let content = identity
        .map(GitIdentity::configuration)
        .transpose()?
        .unwrap_or_default();
    let mut file = tempfile::NamedTempFile::new_in(directory)?;
    file.write_all(content.as_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.as_file()
            .set_permissions(fs::Permissions::from_mode(0o644))?;
    }
    file.persist(&path).map_err(|error| error.error)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// @cc [owner:ghuntley,label:verification;protocol] git-identity-generated-transport-agreement
    /// Every generated accepted attribution MUST round-trip through kernel
    /// transport unchanged, and a duplicated value MUST refuse.
    #[hegel::test(test_cases = 80)]
    fn generated_identity_roundtrips(tc: hegel::TestCase) {
        use hegel::generators as gs;
        let suffix = tc.draw(gs::text().alphabet("aZ09é\\\"-").max_size(24));
        let mailbox = tc.draw(gs::text().alphabet("aZ09").max_size(32));
        let value = serde_json::json!({"version":1,"name":format!("Author {suffix} End"),"email":format!("a{mailbox}@example.test")});
        let bytes = serde_json::to_vec(&value).unwrap();
        let identity = GitIdentity::parse(&bytes).unwrap();
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&bytes);
        let line = format!("lilly.git_identity={encoded}");
        assert_eq!(from_command_line(&line).unwrap(), Some(identity));
        assert!(from_command_line(&format!("{line} {line}")).is_err());
    }

    /// @cc [owner:ghuntley,label:verification;security] git-identity-generated-injection-refusal
    /// Adding a control, format character or display-name delimiter anywhere
    /// inside an otherwise valid name MUST fail before configuration publication.
    #[hegel::test(test_cases = 80)]
    fn generated_name_injections_refuse(tc: hegel::TestCase) {
        use hegel::generators as gs;
        let prefix = tc.draw(gs::text().alphabet("aZ09").max_size(20));
        let suffix = tc.draw(gs::text().alphabet("aZ09").max_size(20));
        let bad = tc.draw(gs::sampled_from(vec![
            "\n", "\r", "\0", "\t", "<", ">", "\u{200b}", "\u{feff}",
        ]));
        let value = serde_json::json!({"version":1,"name":format!("a{prefix}{bad}{suffix}z"),"email":"a@example.test"});
        assert!(GitIdentity::parse(&serde_json::to_vec(&value).unwrap()).is_err());
    }

    #[test]
    fn rejects_control_format_and_malformed_mailboxes() {
        for name in [
            "",
            " trimmed",
            "trailing ",
            "line\nfeed",
            "<Name>",
            "zero\u{200b}width",
        ] {
            let value = serde_json::json!({"version":1,"name":name,"email":"valid@example.test"});
            assert!(GitIdentity::parse(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        for email in [
            "a..b@example.test",
            ".a@example.test",
            "a@example..test",
            "a@-example.test",
            "a@example-.test",
            "a@example.test\n",
            "a@",
            "a@@example.test",
        ] {
            let value = serde_json::json!({"version":1,"name":"Name","email":email});
            assert!(GitIdentity::parse(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        for name in ["Renée", "Example \" Name", "Name\\suffix"] {
            let value = serde_json::json!({"version":1,"name":name,"email":"a.b+tag@example.test"});
            assert!(GitIdentity::parse(&serde_json::to_vec(&value).unwrap()).is_ok());
        }
    }

    #[test]
    fn kernel_roundtrip_and_duplicate_refusal() {
        let raw = br#"{"version":1,"name":"Example Person","email":"person@example.test"}"#;
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw);
        let line = format!("lilly.git_identity={encoded}");
        assert_eq!(
            from_command_line(&line).unwrap(),
            Some(GitIdentity::parse(raw).unwrap())
        );
        assert!(from_command_line(&format!("{line} {line}")).is_err());
        assert!(from_command_line("lilly.git_identity=invalid").is_err());
        assert_eq!(from_command_line("quiet").unwrap(), None);
    }

    #[test]
    fn git_values_are_quoted_and_absence_clears_previous_boot() {
        let root = tempfile::tempdir().unwrap();
        let directory = fs::canonicalize(root.path()).unwrap().join("identity");
        let value = GitIdentity::parse(
            br#"{"version":1,"name":"Example \\\" Person","email":"person@example.test"}"#,
        )
        .unwrap();
        install(&directory, Some(&value)).unwrap();
        let result = std::process::Command::new("git")
            .args(["config", "--file"])
            .arg(directory.join("gitconfig"))
            .args(["--get", "user.name"])
            .output()
            .unwrap();
        assert!(result.status.success());
        assert_eq!(
            String::from_utf8(result.stdout).unwrap().trim_end(),
            value.name
        );
        install(&directory, None).unwrap();
        assert_eq!(fs::read(directory.join("gitconfig")).unwrap(), b"");
    }

    #[test]
    fn current_identity_is_effective_without_a_repository() {
        let root = tempfile::tempdir().unwrap();
        let directory = fs::canonicalize(root.path()).unwrap().join("identity");
        let system = root.path().join("system-gitconfig");
        fs::write(
            &system,
            format!(
                "[include]\npath = {}\n",
                directory.join("gitconfig").display()
            ),
        )
        .unwrap();
        let identity = GitIdentity::parse(
            br#"{"version":1,"name":"Current Author","email":"current@example.test"}"#,
        )
        .unwrap();
        install(&directory, Some(&identity)).unwrap();
        let git = std::env::var_os("OVERALLS_TEST_GIT").unwrap_or_else(|| "git".into());
        let result = std::process::Command::new(git)
            .args(["var", "GIT_AUTHOR_IDENT"])
            .current_dir(root.path())
            .env_clear()
            .env("HOME", root.path())
            .env("GIT_CONFIG_SYSTEM", &system)
            .env(
                "GIT_CONFIG_GLOBAL",
                if cfg!(windows) { "NUL" } else { "/dev/null" },
            )
            .output()
            .unwrap();
        assert!(result.status.success());
        assert!(String::from_utf8(result.stdout)
            .unwrap()
            .starts_with("Current Author <current@example.test> "));
    }

    #[cfg(unix)]
    #[test]
    fn identity_include_refuses_links() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        fs::create_dir(&target).unwrap();
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(install(&link, None).is_err());
    }
}
