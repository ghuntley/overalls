use crate::config::{self, Config};
use crate::http;
use crate::log::{self, Event};
use reqwest::{Method, StatusCode};
use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use tempfile::NamedTempFile;

fn valid_host_key<'a>(host: &str, bytes: &'a [u8]) -> io::Result<&'a str> {
    if bytes.len() > 1024 {
        return Err(io::Error::other("host key too large"));
    }
    let line = std::str::from_utf8(bytes).map_err(|_| io::Error::other("invalid host key"))?;
    let key = line
        .strip_prefix(&format!("{host} ssh-ed25519 "))
        .and_then(|v| v.strip_suffix('\n'));
    if !key.is_some_and(|v| {
        !v.is_empty()
            && v.len() < 100
            && v.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
    }) {
        return Err(io::Error::other("invalid host key"));
    }
    Ok(line)
}

fn valid_host_keys<'a>(host: &str, bytes: &'a [u8], allow_multiple: bool) -> io::Result<&'a str> {
    if bytes.len() > if allow_multiple { 8192 } else { 1024 } {
        return Err(io::Error::other("host key response too large"));
    }
    let body = std::str::from_utf8(bytes).map_err(|_| io::Error::other("invalid host keys"))?;
    let mut seen = HashSet::new();
    let mut count = 0;
    for line in body.split_inclusive('\n') {
        count += 1;
        if count > if allow_multiple { 16 } else { 1 } {
            return Err(io::Error::other("too many host keys"));
        }
        valid_host_key(host, line.as_bytes())?;
        if !seen.insert(line) {
            return Err(io::Error::other("duplicate host key"));
        }
    }
    if count == 0 {
        return Err(io::Error::other("missing host key"));
    }
    Ok(body)
}

// @cc [owner:ghuntley,label:security] lyra-generated-profile-key-lookup
// The host-key command MUST obtain only current keys through the bounded Rust
// HTTPS client. Nested gateway rotation permits a bounded set.
pub(crate) fn print_host_key(url: &str, host: &str, allow_multiple: bool) -> io::Result<()> {
    if !config::valid_host(host) {
        return Err(io::Error::other("invalid host key name"));
    }
    let maximum = if allow_multiple { 8192 } else { 1024 };
    let line = http::request_exact(url, StatusCode::OK, maximum, Duration::from_secs(3))
        .and_then(|bytes| valid_host_keys(host, &bytes, allow_multiple).map(str::to_owned));
    let line = match line {
        Ok(line) => line,
        Err(error) => {
            let _ = log::emit(Event::LookupFailed, None);
            return Err(error);
        }
    };
    io::stdout().write_all(line.as_bytes())
}

fn known_host(config: &Config, host: &str, label: &str) -> io::Result<NamedTempFile> {
    let url = format!("{}/api/audi/v1/known-hosts/{label}", config.origin);
    let bytes = http::request(&url, Method::GET, None, None, 1024, Duration::from_secs(3))?;
    let line = valid_host_key(host, &bytes)?;
    let mut file = NamedTempFile::new()?;
    file.write_all(line.as_bytes())?;
    file.flush()?;
    Ok(file)
}

/// @cc [owner:ghuntley,label:security] lyra-proof-agent-parity
/// The isolated gateway SSH process MUST use the effective `IdentityAgent` of
/// the Porsche whoami proof connection, including Host/Match rules, direct and
/// relative socket paths, $VARIABLE, ${VARIABLE}, inherited `SSH_AUTH_SOCK` and
/// none. Agent paths MUST remain a child-only `SSH_AUTH_SOCK` value and never
/// enter the shell `ProxyCommand` or persistent diagnostics.
fn proof_identity_agent(origin: &str, ssh: &OsStr) -> io::Result<AgentSelection> {
    let host = origin
        .strip_prefix("https://")
        .and_then(|authority| authority.split(':').next())
        .ok_or_else(|| io::Error::other("invalid origin"))?;
    let local = lyra::platform::local_user_name()?;
    let username = local.as_str();
    if username.len() > 255 || username.chars().any(char::is_control) {
        return Err(io::Error::other("invalid local username"));
    }
    let output = Command::new(ssh)
        .args([
            "-G", "-T", "-p", "22", "-l", username, "--", host, "whoami", "--json",
        ])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() || output.stdout.len() > 65_536 {
        return Err(io::Error::other("SSH configuration unavailable"));
    }
    parse_identity_agent(&output.stdout)?.resolve(|name| std::env::var_os(name))
}

#[derive(Debug, PartialEq, Eq)]
enum AgentSetting {
    Inherited,
    Disabled,
    Socket(PathBuf),
    Variable(String),
}

#[derive(Debug, PartialEq, Eq)]
enum AgentSelection {
    Inherited,
    Disabled,
    Socket(PathBuf),
}

impl AgentSetting {
    fn resolve(
        self,
        variable: impl FnOnce(&str) -> Option<OsString>,
    ) -> io::Result<AgentSelection> {
        match self {
            Self::Inherited => Ok(AgentSelection::Inherited),
            Self::Disabled => Ok(AgentSelection::Disabled),
            Self::Socket(path) => Ok(AgentSelection::Socket(path)),
            Self::Variable(name) => match variable(&name) {
                Some(value) if value.len() <= 4096 => {
                    Ok(AgentSelection::Socket(PathBuf::from(value)))
                }
                Some(_) => Err(io::Error::other("SSH identity agent too long")),
                None => Ok(AgentSelection::Disabled),
            },
        }
    }
}

fn valid_environment_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric() || first == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

/// @cc [owner:ghuntley,label:security] lyra-agent-setting-parse
/// The parsed setting MUST preserve OpenSSH-expanded socket bytes and resolve
/// only its documented none, `SSH_AUTH_SOCK` and $VARIABLE special forms. It MUST
/// reject duplicate, oversized or control-character values. An explicitly
/// empty socket path MUST remain distinct from an absent setting.
fn parse_identity_agent(output: &[u8]) -> io::Result<AgentSetting> {
    let mut selected = None;
    for line in output.split(|byte| *byte == b'\n') {
        if let Some(value) = line.strip_prefix(b"identityagent ") {
            if selected.is_some() || value.len() > 4096 || value.iter().any(u8::is_ascii_control) {
                return Err(io::Error::other("invalid SSH identity agent"));
            }
            selected = Some(match value {
                b"none" => AgentSetting::Disabled,
                b"SSH_AUTH_SOCK" => AgentSetting::Inherited,
                value if value.starts_with(b"$") && !value.starts_with(b"${") => {
                    let name = std::str::from_utf8(&value[1..])
                        .map_err(|_| io::Error::other("invalid SSH identity agent"))?;
                    if !valid_environment_name(name) {
                        return Err(io::Error::other("invalid SSH identity agent"));
                    }
                    AgentSetting::Variable(name.to_owned())
                }
                value => AgentSetting::Socket(PathBuf::from(os_from_bytes(value)?)),
            });
        }
    }
    Ok(selected.unwrap_or(AgentSetting::Inherited))
}

/// OpenSSH prints the agent setting as raw bytes on Unix and as UTF-8 on
/// Windows (an agent named pipe such as `\\.\pipe\openssh-ssh-agent`).
#[cfg(unix)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Unix conversion is total; the Windows variant shares the signature"
)]
fn os_from_bytes(value: &[u8]) -> io::Result<OsString> {
    use std::os::unix::ffi::OsStringExt;
    Ok(OsString::from_vec(value.to_vec()))
}

#[cfg(windows)]
fn os_from_bytes(value: &[u8]) -> io::Result<OsString> {
    String::from_utf8(value.to_vec())
        .map(OsString::from)
        .map_err(|_| io::Error::other("invalid SSH identity agent"))
}

/// `-o` value for a file path: Windows profile paths may contain spaces, which
/// OpenSSH would split, so they are double-quoted there.
fn path_option(path: &Path) -> String {
    let value = path.display().to_string();
    if cfg!(windows) {
        format!("\"{value}\"")
    } else {
        value
    }
}

/// @cc [owner:ghuntley,label:security] lyra-outer-ssh-pinned
/// A failed current-key lookup MUST stop before SSH. The subprocess MUST use
/// exact current-key pinning and the setup-selected identity only; it MUST
/// permit an encrypted selected key's passphrase or macOS Keychain lookup,
/// while disabling server password methods. It MUST inherit relay bytes
/// without inspecting or logging them.
pub(crate) fn run(host: &str, identity: &str) -> io::Result<i32> {
    if !config::valid_ssh_identity_name(identity) {
        return Err(io::Error::other("invalid SSH identity"));
    }
    let identity_path = config::home()?.join(".ssh").join(identity);
    let metadata = fs::symlink_metadata(&identity_path)?;
    if !metadata.file_type().is_file() || metadata.len() > 65_536 {
        return Err(io::Error::other("SSH identity unavailable"));
    }
    let config = config::load()?;
    let label =
        config::label_for(host, &config.zone).ok_or_else(|| io::Error::other("invalid VM host"))?;
    let ssh = config::ssh_program(Some(&config));
    let agent = proof_identity_agent(&config.origin, &ssh)?;
    let key = match known_host(&config, host, label) {
        Ok(key) => key,
        Err(error) => {
            let _ = log::emit(Event::LookupFailed, None);
            return Err(error);
        }
    };
    let trust = crate::trust::load(&config.origin, &config.zone)?;
    let current = fs::read_to_string(key.path())?;
    let fields: Vec<_> = current.split_whitespace().collect();
    if fields.len() != 3 {
        return Err(io::Error::other("invalid gateway identity"));
    }
    let alias = lyra::ssh_certificate::gateway_principal(
        &format!("{} {}", fields[1], fields[2]),
        &trust.management_host,
    )?;
    fs::write(
        key.path(),
        crate::trust::gateway_known_hosts(&trust, &alias)?,
    )?;
    let agent_kind = match agent {
        AgentSelection::Inherited => 0,
        AgentSelection::Disabled => 2,
        AgentSelection::Socket(_) => 1,
    };
    let _ = log::emit(Event::ProxyAgentSelected, Some(agent_kind));
    let _ = log::emit(Event::ProxyStarted, None);
    let result = ssh_command_with_alias(
        &ssh,
        host,
        label,
        key.path(),
        &identity_path,
        &agent,
        &alias,
    )
    .stdin(Stdio::inherit())
    .stdout(Stdio::inherit())
    .stderr(Stdio::inherit())
    .status()?;
    let code = result.code().unwrap_or(1);
    let _ = log::emit(Event::ProxyEnded, Some(i64::from(code).cast_unsigned()));
    Ok(code)
}

#[cfg(test)]
fn ssh_command(
    host: &str,
    label: &str,
    host_key_path: &Path,
    identity_path: &Path,
    identity_agent: &AgentSelection,
) -> Command {
    ssh_command_with_alias(
        OsStr::new("ssh"),
        host,
        label,
        host_key_path,
        identity_path,
        identity_agent,
        host,
    )
}

fn ssh_command_with_alias(
    ssh: &OsStr,
    host: &str,
    label: &str,
    host_key_path: &Path,
    identity_path: &Path,
    identity_agent: &AgentSelection,
    host_alias: &str,
) -> Command {
    let null = lyra::platform::null_device();
    let mut command = Command::new(ssh);
    command
        .args(["-4", "-F", null])
        .args([
            "-T",
            "-p",
            "22",
            "-l",
            "audi",
            "-o",
            "BatchMode=no",
            "-o",
            "PreferredAuthentications=publickey",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "KbdInteractiveAuthentication=no",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "ConnectionAttempts=1",
            "-o",
            "ControlMaster=no",
            "-o",
            "ControlPath=none",
            "-o",
            "ClearAllForwardings=yes",
            "-o",
            "ForwardAgent=no",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
            "-o",
            "CheckHostIP=no",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "VerifyHostKeyDNS=no",
        ])
        .arg("-i")
        .arg(identity_path)
        .arg("-o")
        .arg(format!("GlobalKnownHostsFile={null}"))
        .arg("-o")
        .arg(format!("UserKnownHostsFile={}", path_option(host_key_path)))
        .arg("-o")
        .arg(format!("HostKeyAlias={host_alias}"));
    if cfg!(target_os = "macos") {
        command.args(["-o", "IgnoreUnknown=UseKeychain", "-o", "UseKeychain=yes"]);
    }
    match identity_agent {
        AgentSelection::Disabled => {
            command.env_remove("SSH_AUTH_SOCK");
        }
        AgentSelection::Inherited => {}
        AgentSelection::Socket(path) => {
            command.env("SSH_AUTH_SOCK", path);
        }
    }
    command.args(["--", host, "connect", label]);
    command
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    use std::os::unix::ffi::OsStrExt;

    #[test]
    fn gateway_offers_only_the_identity_selected_during_setup() {
        let command = ssh_command(
            "vm-0123456789abcdef0123456789abcdef.apps.example.test",
            "vm-0123456789abcdef0123456789abcdef",
            Path::new("/tmp/current-host-key"),
            Path::new("/home/user/.ssh/work_key"),
            &AgentSelection::Socket(PathBuf::from(
                "/Users/user/Library/Group Containers/1Password/agent.sock",
            )),
        );
        let arguments: Vec<_> = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect();
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["-i", "/home/user/.ssh/work_key"]));
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["-o", "IdentitiesOnly=yes"]));
        assert!(arguments.windows(2).any(|pair| pair == ["-F", "/dev/null"]));
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["-o", "BatchMode=no"]));
        assert!(arguments
            .windows(2)
            .any(|pair| pair == ["-o", "PasswordAuthentication=no"]));
        if cfg!(target_os = "macos") {
            assert!(arguments
                .windows(2)
                .any(|pair| pair == ["-o", "UseKeychain=yes"]));
        }
        assert_eq!(
            command
                .get_envs()
                .find(|(key, _)| *key == "SSH_AUTH_SOCK")
                .and_then(|(_, value)| value),
            Some(OsStr::new(
                "/Users/user/Library/Group Containers/1Password/agent.sock"
            ))
        );
    }

    #[test]
    fn one_password_agent_path_survives_ssh_config_parsing() {
        let value = b"user ghuntley\nidentityagent /Users/ghuntley/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\n";
        assert_eq!(
            parse_identity_agent(value).unwrap(),
            AgentSetting::Socket(PathBuf::from(
                "/Users/ghuntley/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
            ))
        );
        assert_eq!(
            parse_identity_agent(b"user ghuntley\n").unwrap(),
            AgentSetting::Inherited
        );
        assert_eq!(
            parse_identity_agent(b"identityagent ../../other.sock\n").unwrap(),
            AgentSetting::Socket(PathBuf::from("../../other.sock"))
        );
        assert!(
            parse_identity_agent(b"identityagent /tmp/a.sock\nidentityagent /tmp/b.sock\n")
                .is_err()
        );
    }

    #[test]
    fn openssh_expands_quoted_agent_path_with_spaces() {
        let directory = tempfile::tempdir().unwrap();
        let configuration = directory.path().join("config");
        let socket = directory.path().join("Group Containers/agent.sock");
        fs::write(
            &configuration,
            format!("Host *\n  IdentityAgent \"{}\"\n", socket.display()),
        )
        .unwrap();
        let output = Command::new("ssh")
            .args(["-F"])
            .arg(&configuration)
            .args(["-G", "example.test"])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            parse_identity_agent(&output.stdout).unwrap(),
            AgentSetting::Socket(socket)
        );
    }

    #[test]
    fn openssh_agent_forms_select_the_proved_socket() {
        let directory = tempfile::tempdir().unwrap();
        let configuration = directory.path().join("config");
        let socket = directory.path().join("agent.sock");
        let socket_text = socket.to_string_lossy();
        let cases = [
            ("none", Some(AgentSetting::Disabled)),
            ("SSH_AUTH_SOCK", Some(AgentSetting::Inherited)),
            (
                "$OVERALLS_TEST_AGENT",
                Some(AgentSetting::Variable("OVERALLS_TEST_AGENT".into())),
            ),
            (
                "${OVERALLS_TEST_AGENT}",
                Some(AgentSetting::Socket(socket.clone())),
            ),
            (
                "${OVERALLS_EMPTY_AGENT}",
                Some(AgentSetting::Socket(PathBuf::new())),
            ),
            ("%d/overalls-agent.sock", None),
            (
                "./agent.sock",
                Some(AgentSetting::Socket(PathBuf::from("./agent.sock"))),
            ),
        ];
        for (setting, expected) in cases {
            fs::write(
                &configuration,
                format!("Host *\n  IdentityAgent {setting}\n"),
            )
            .unwrap();
            let output = Command::new("ssh")
                .arg("-F")
                .arg(&configuration)
                .args([
                    "-G",
                    "-T",
                    "-l",
                    "localname",
                    "--",
                    "example.test",
                    "whoami",
                    "--json",
                ])
                .env("OVERALLS_TEST_AGENT", socket_text.as_ref())
                .env("OVERALLS_EMPTY_AGENT", "")
                .output()
                .unwrap();
            assert!(output.status.success(), "{setting}");
            let selected = parse_identity_agent(&output.stdout).unwrap();
            match expected {
                Some(expected) => assert_eq!(selected, expected, "{setting}"),
                None => assert!(
                    matches!(selected, AgentSetting::Socket(path) if path.is_absolute() && path.ends_with("overalls-agent.sock"))
                ),
            }
        }
    }

    #[test]
    fn command_specific_agent_rule_matches_the_porsche_proof() {
        let directory = tempfile::tempdir().unwrap();
        let configuration = directory.path().join("config");
        fs::write(&configuration, "Match command \"whoami --json\"\n  IdentityAgent /tmp/proof.sock\nHost *\n  IdentityAgent none\n").unwrap();
        let output = Command::new("ssh")
            .arg("-F")
            .arg(&configuration)
            .args([
                "-G",
                "-T",
                "-l",
                "localname",
                "--",
                "example.test",
                "whoami",
                "--json",
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            parse_identity_agent(&output.stdout).unwrap(),
            AgentSetting::Socket(PathBuf::from("/tmp/proof.sock"))
        );
    }

    #[test]
    fn legacy_environment_agent_is_resolved_without_exposing_its_name_to_ssh() {
        let setting = parse_identity_agent(b"identityagent $OVERALLS_AGENT\n").unwrap();
        let selected = setting
            .resolve(|name| {
                assert_eq!(name, "OVERALLS_AGENT");
                Some(OsString::from("/Users/person/Group Containers/agent.sock"))
            })
            .unwrap();
        assert_eq!(
            selected,
            AgentSelection::Socket(PathBuf::from("/Users/person/Group Containers/agent.sock"))
        );
        let command = ssh_command(
            "vm-0123456789abcdef0123456789abcdef.apps.example.test",
            "vm-0123456789abcdef0123456789abcdef",
            Path::new("/tmp/key"),
            Path::new("/tmp/public.pub"),
            &selected,
        );
        assert_eq!(
            command
                .get_envs()
                .find(|(name, _)| *name == "SSH_AUTH_SOCK")
                .and_then(|(_, value)| value),
            Some(OsStr::new("/Users/person/Group Containers/agent.sock"))
        );
        assert_eq!(
            AgentSetting::Variable("MISSING".into())
                .resolve(|_| None)
                .unwrap(),
            AgentSelection::Disabled
        );
        assert!(parse_identity_agent(b"identityagent $BAD-NAME\n").is_err());
        assert_eq!(
            parse_identity_agent(b"identityagent \n").unwrap(),
            AgentSetting::Socket(PathBuf::new())
        );
    }

    #[test]
    fn disabled_agent_clears_inherited_socket_and_default_agent_keeps_it() {
        let command_for = |selection: &AgentSelection| {
            ssh_command(
                "vm-0123456789abcdef0123456789abcdef.apps.example.test",
                "vm-0123456789abcdef0123456789abcdef",
                Path::new("/tmp/key"),
                Path::new("/tmp/public.pub"),
                selection,
            )
        };
        let disabled = command_for(&AgentSelection::Disabled);
        assert_eq!(
            disabled
                .get_envs()
                .find(|(name, _)| *name == "SSH_AUTH_SOCK"),
            Some((OsStr::new("SSH_AUTH_SOCK"), None))
        );
        let inherited = command_for(&AgentSelection::Inherited);
        assert!(inherited
            .get_envs()
            .all(|(name, _)| name != "SSH_AUTH_SOCK"));
    }

    #[test]
    fn non_utf8_socket_path_remains_byte_exact() {
        let setting = parse_identity_agent(b"identityagent /tmp/agent-\xff.sock\n").unwrap();
        let selected = setting.resolve(|_| None).unwrap();
        let command = ssh_command(
            "vm-0123456789abcdef0123456789abcdef.apps.example.test",
            "vm-0123456789abcdef0123456789abcdef",
            Path::new("/tmp/key"),
            Path::new("/tmp/public.pub"),
            &selected,
        );
        assert_eq!(
            command
                .get_envs()
                .find(|(name, _)| *name == "SSH_AUTH_SOCK")
                .and_then(|(_, value)| value)
                .map(OsStr::as_bytes),
            Some(&b"/tmp/agent-\xff.sock"[..])
        );
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_agent_setting_cannot_add_ssh_options(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        if let Ok(agent) = parse_identity_agent(&bytes) {
            match agent {
                AgentSetting::Socket(path) => {
                    assert!(!path.as_os_str().as_bytes().iter().any(u8::is_ascii_control));
                    assert!(path.as_os_str().as_bytes().len() <= 4096);
                }
                AgentSetting::Variable(name) => assert!(valid_environment_name(&name)),
                AgentSetting::Inherited | AgentSetting::Disabled => {}
            }
        }
    }

    #[test]
    fn exact_host_key_line_is_required() {
        let host = "vm-0123456789abcdef0123456789abcdef.apps.ghuntley.dev";
        let line = format!("{host} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFh\n");
        assert_eq!(valid_host_key(host, line.as_bytes()).unwrap(), line);
        assert!(valid_host_key("other.apps.ghuntley.dev", line.as_bytes()).is_err());
        assert!(valid_host_key(host, format!("{line}extra\n").as_bytes()).is_err());
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_host_key_bytes_cannot_add_lines_or_hosts(tc: TestCase) {
        let host = "vm-0123456789abcdef0123456789abcdef.apps.ghuntley.dev";
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        if let Ok(line) = valid_host_key(host, &bytes) {
            assert!(line.starts_with(&format!("{host} ssh-ed25519 ")));
            assert!(line.ends_with('\n'));
            assert_eq!(line.bytes().filter(|byte| *byte == b'\n').count(), 1);
            assert!(!line.contains('\r'));
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_key_lines_bind_one_exact_host(tc: TestCase) {
        let host = "vm-0123456789abcdef0123456789abcdef.apps.ghuntley.dev";
        let key = tc.draw(gs::integers::<u128>());
        let line = format!("{host} ssh-ed25519 {key:032x}\n");
        assert_eq!(valid_host_key(host, line.as_bytes()).unwrap(), line);
        assert!(valid_host_key("other.apps.ghuntley.dev", line.as_bytes()).is_err());
        assert!(valid_host_key(host, format!("{line}{line}").as_bytes()).is_err());
        assert!(valid_host_key(host, line.replace("ssh-ed25519", "ssh-rsa").as_bytes()).is_err());
    }

    #[hegel::test(test_cases = 100)]
    fn generated_gateway_key_sets_reject_extra_hosts_and_duplicates(tc: TestCase) {
        let host = "gateway.vm-0123456789abcdef0123456789abcdef.inception.apps.ghuntley.dev";
        let first = tc.draw(gs::integers::<u128>());
        let second = first.wrapping_add(1);
        let one = format!("{host} ssh-ed25519 {first:032x}\n");
        let two = format!("{host} ssh-ed25519 {second:032x}\n");
        let set = format!("{one}{two}");
        assert_eq!(valid_host_keys(host, set.as_bytes(), true).unwrap(), set);
        assert!(valid_host_keys(host, set.as_bytes(), false).is_err());
        assert!(valid_host_keys(host, format!("{one}{one}").as_bytes(), true).is_err());
        assert!(valid_host_keys(
            host,
            format!("{one}other.example ssh-ed25519 {second:032x}\n").as_bytes(),
            true
        )
        .is_err());
        assert!(valid_host_keys(host, format!("{one}{two}extra").as_bytes(), true).is_err());
        let many = (0..17)
            .map(|offset| format!("{host} ssh-ed25519 {:032x}\n", first.wrapping_add(offset)))
            .collect::<Vec<_>>()
            .concat();
        assert!(valid_host_keys(host, many.as_bytes(), true).is_err());
    }
}
