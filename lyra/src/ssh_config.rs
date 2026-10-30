use crate::config::{self, Config};
use crate::log::{self, Event};
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(serde::Deserialize)]
struct AccountResponse {
    version: u8,
    status: String,
    result: AccountIdentity,
}

#[derive(serde::Deserialize)]
struct AccountIdentity {
    guest_username: String,
    public_key: String,
}

fn valid_guest_username(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 32
        && (bytes[0].is_ascii_lowercase() || bytes[0] == b'_')
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_.-".contains(byte))
        && (bytes[bytes.len() - 1].is_ascii_lowercase()
            || bytes[bytes.len() - 1].is_ascii_digit()
            || bytes[bytes.len() - 1] == b'_')
        && ![
            "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp",
            "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody", "ubuntu", "sshd",
            "sudo", "postgres",
        ]
        .contains(&value)
        && !value.starts_with("systemd-")
        && !value.starts_with("nixbld")
}

fn parse_account(bytes: &[u8]) -> io::Result<AccountIdentity> {
    if bytes.len() > 8192 {
        return Err(io::Error::other("account response too large"));
    }
    let response: AccountResponse = serde_json::from_slice(bytes).map_err(io::Error::other)?;
    let identity = response.result;
    if response.version != 1
        || response.status != "succeeded"
        || !valid_guest_username(&identity.guest_username)
        || identity.public_key.len() > 4096
        || !identity.public_key.starts_with("ssh-")
        || identity.public_key.contains(['\n', '\r'])
    {
        return Err(io::Error::other("invalid account response"));
    }
    Ok(identity)
}

/**
 * @cc [owner:ghuntley,label:security] lyra-proved-guest-account
 * The OS local username is only an SSH alias. Porsche's signed-key session
 * determines the Marshall account and returns its remote name and exact key.
 */
/**
 * @cc [owner:ghuntley,label:security] lyra-strict-management-trust
 * Management SSH MUST require an ED25519 certificate from the installed CA; it MUST NOT ask to
 * accept a new host key or silently accept one during account proof.
 */
fn resolve_account(origin: &str, ssh: &OsStr) -> io::Result<AccountIdentity> {
    let host = origin
        .strip_prefix("https://")
        .and_then(|value| value.split_once(':').map(|(host, _)| host).or(Some(value)))
        .ok_or_else(|| io::Error::other("invalid origin"))?;
    let local = lyra::platform::local_user_name()?;
    let known_hosts = config::home()?.join(".ssh").join("known_hosts");
    let username = local.as_str();
    if username.len() > 255 || username.chars().any(|character| character.is_control()) {
        return Err(io::Error::other("invalid local username"));
    }
    let response = Command::new(ssh)
        .args([
            "-T",
            "-p",
            "22",
            "-o",
            &format!("UserKnownHostsFile={}", known_hosts.display()),
        ])
        .args([
            "-o",
            &format!(
                "GlobalKnownHostsFile={}",
                lyra::platform::null_device()
            ),
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
            "-l",
            username,
            "--",
            host,
            "whoami",
            "--json",
        ])
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()?;
    if !response.status.success() {
        return Err(io::Error::other("account proof failed"));
    }
    parse_account(&response.stdout)
}

fn quote_shell(value: &str) -> io::Result<String> {
    if value.chars().any(|c| c == '\n' || c == '\r' || c == '\0') {
        return Err(io::Error::other("invalid executable path"));
    }
    Ok(format!(
        "'{}'",
        value.replace('%', "%%").replace('\'', "'\\''")
    ))
}

/// @cc [owner:ghuntley,label:security] lyra-windows-proxy-command-quoting
/// Win32-OpenSSH starts ProxyCommand with `CreateProcess`, not `sh -c`, so the
/// executable MUST be one double-quoted absolute path with `%` doubled; a path
/// containing `"`, a control character or a NUL MUST be refused.
fn quote_windows(value: &str) -> io::Result<String> {
    if value.chars().any(|c| c == '"' || c.is_control()) {
        return Err(io::Error::other("invalid executable path"));
    }
    Ok(format!("\"{}\"", value.replace('%', "%%")))
}

fn quote_command(value: &str) -> io::Result<String> {
    if cfg!(windows) {
        quote_windows(value)
    } else {
        quote_shell(value)
    }
}

fn supported_ssh(ssh: &OsStr) -> bool {
    Command::new(ssh)
        .args([
            "-F",
            lyra::platform::null_device(),
            "-G",
            "invalid;hostname",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| !status.success())
}

fn same_public_key(registered: &str, derived: &[u8]) -> bool {
    if derived.len() > 4096 {
        return false;
    }
    let mut expected = registered.split_whitespace();
    let (Some(kind), Some(key)) = (expected.next(), expected.next()) else {
        return false;
    };
    std::str::from_utf8(derived).is_ok_and(|value| {
        let mut actual = value.split_whitespace();
        actual.next() == Some(kind) && actual.next() == Some(key)
    })
}

// @cc [owner:ghuntley,label:security] lyra-matched-private-identity
// Both the guest IdentityFile and outer Audi proxy MUST select a local private
// key whose derived public key equals Porsche's proved key. Missing .pub
// siblings MUST NOT force a public-key-only profile when the private key exists.
// Encrypted private keys MUST be matched through their bounded .pub sibling;
// agent-only keys use the exact registered public key as a fallback.
/// `ssh-keygen` beside the selected client (Win32-OpenSSH ships both in one
/// directory), or `ssh-keygen` from PATH.
fn keygen_program(ssh: &OsStr) -> PathBuf {
    let ssh = Path::new(ssh);
    match ssh.parent() {
        Some(parent) if ssh.is_absolute() => parent.join(if cfg!(windows) {
            "ssh-keygen.exe"
        } else {
            "ssh-keygen"
        }),
        _ => PathBuf::from("ssh-keygen"),
    }
}

fn local_identity(ssh_dir: &std::path::Path, registered: &str, keygen: &Path) -> String {
    if registered.split_whitespace().take(2).count() != 2 {
        return "overalls-identity.pub".into();
    }
    let Ok(entries) = fs::read_dir(ssh_dir) else {
        return "overalls-identity.pub".into();
    };
    let mut matches = Vec::new();
    for entry in entries.flatten().take(128) {
        let path = entry.path();
        if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            continue;
        }
        let Some(filename) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if filename.ends_with(".pub")
            || !config::valid_ssh_identity_name(filename)
            || !fs::metadata(&path).is_ok_and(|metadata| metadata.len() <= 65_536)
        {
            continue;
        }
        let derived = Command::new(keygen)
            .args(["-y", "-P", "", "-f"])
            .arg(&path)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .and_then(|output| {
                if output.status.success() {
                    Ok(output.stdout)
                } else {
                    Err(io::Error::other("identity unavailable"))
                }
            });
        let sibling = ssh_dir.join(format!("{filename}.pub"));
        let sibling_matches = fs::metadata(&sibling)
            .is_ok_and(|metadata| metadata.is_file() && metadata.len() <= 4096)
            && fs::read(&sibling).is_ok_and(|public| same_public_key(registered, &public));
        let matched = match derived {
            Ok(public) => same_public_key(registered, &public),
            Err(_) => sibling_matches,
        };
        if matched {
            matches.push(filename.to_owned());
        }
    }
    matches.sort();
    matches
        .first()
        .cloned()
        .unwrap_or_else(|| "overalls-identity.pub".into())
}

const START: &str = "# BEGIN OVERALLS SSH\n";
const END: &str = "# END OVERALLS SSH\n";

fn managed_block(zone: &str, username: &str, identity_name: &str, command: &str) -> String {
    let macos_keychain = if cfg!(target_os = "macos") {
        "  IgnoreUnknown UseKeychain\n  UseKeychain yes\n"
    } else {
        ""
    };
    format!("{START}Host *.{zone}\n  User {username}\n  IdentityFile ~/.ssh/{identity_name}\n  IdentitiesOnly yes\n{macos_keychain}  Port 22\n  StrictHostKeyChecking yes\n  HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com\n  AddressFamily inet\n  ProxyCommand {command} proxy --host %h --identity {identity_name}\n{END}")
}

// @cc [owner:ghuntley,label:security;recovery] lyra-managed-block-preservation
// Setup MUST preserve every byte outside its marker-delimited managed block.
// Pre-existing and adversarial near-marker content is unmanaged and MUST
// survive install and reinstall byte-identically, with exactly one pair of
// markers in every successful result.
// @cc [owner:ghuntley,label:security] lyra-managed-block-refusal
// Setup MUST refuse a config containing anything other than zero managed
// marker pairs or exactly one well-ordered pair, leaving the prior bytes
// untouched; an ambiguous configuration MUST NOT be silently rewritten.
fn splice(prior: &str, block: &str) -> io::Result<String> {
    let content = match (prior.matches(START).count(), prior.matches(END).count()) {
        (0, 0) => prior.to_owned(),
        (1, 1) => {
            let begin = prior.find(START).expect("counted begin marker");
            let finish = prior.find(END).expect("counted end marker");
            if begin >= finish {
                return Err(io::Error::other("invalid managed SSH block"));
            }
            let mut content = prior[..begin].to_owned();
            content.push_str(&prior[finish + END.len()..]);
            content
        }
        _ => return Err(io::Error::other("invalid managed SSH block")),
    };
    let result = format!("{block}{content}");
    // Splicing MUST NOT promote unmanaged bytes into a second marker pair at
    // a glue joint; such configurations are refused before any write.
    if result.matches(START).count() == 1 && result.matches(END).count() == 1 {
        Ok(result)
    } else {
        Err(io::Error::other("invalid managed SSH block"))
    }
}

// @cc [owner:ghuntley,label:security;recovery] lyra-config-atomic-publish
// The user config MUST be written through a named temporary file in the SSH
// directory that is fsynced and renamed; symlinked or nonregular targets MUST
// be refused beforehand. A refusal or a dropped temporary file MUST leave the
// pre-existing file and directory listing byte-identical.
fn install_block(ssh_dir: &std::path::Path, block: &str) -> io::Result<()> {
    let path = ssh_dir.join("config");
    if fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(io::Error::other("symlinked SSH config unsupported"));
    }
    let prior = match fs::read_to_string(&path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error),
    };
    let result = splice(&prior, block)?;
    let mut file = tempfile::NamedTempFile::new_in(ssh_dir)?;
    file.write_all(result.as_bytes())?;
    file.as_file().sync_all()?;
    file.persist(&path).map_err(|error| error.error)?;
    Ok(())
}

/// @cc [owner:ghuntley,label:security] lyra-wildcard-proxy-command
/// Setup MUST reject unsafe OpenSSH clients before placing a hostname token in
/// ProxyCommand. It MUST modify only Lyra's managed block in the user config.
pub fn install(origin: String, zone: String, ssh: Option<PathBuf>) -> io::Result<()> {
    let ssh_program = match ssh {
        Some(path) if config::valid_ssh_program(&path) => Some(path),
        Some(_) => return Err(io::Error::other("invalid OpenSSH client path")),
        None => None,
    };
    let config = Config {
        origin,
        zone,
        ssh_program: ssh_program
            .as_ref()
            .map(|path| path.to_string_lossy().into_owned()),
    };
    if !config::valid_origin(&config.origin) || !config::valid_zone(&config.zone) {
        return Err(io::Error::other("invalid setup settings"));
    }
    let ssh = config::ssh_program(Some(&config));
    if !supported_ssh(&ssh) {
        return Err(io::Error::other("OpenSSH 9.6 hostname protection required"));
    }
    crate::trust::install(&config.origin, &config.zone)?;
    let executable = config::managed_bin()?;
    let identity = resolve_account(&config.origin, &ssh)?;
    let command = quote_command(&executable.to_string_lossy())?;
    let ssh_dir = config::home()?.join(".ssh");
    fs::create_dir_all(&ssh_dir)?;
    lyra::platform::restrict_directory(&ssh_dir)?;
    let identity_name = local_identity(&ssh_dir, &identity.public_key, &keygen_program(&ssh));
    let identity_path = ssh_dir.join("overalls-identity.pub");
    let mut identity_file = tempfile::NamedTempFile::new_in(&ssh_dir)?;
    identity_file.write_all(identity.public_key.as_bytes())?;
    identity_file.write_all(b"\n")?;
    identity_file.as_file().sync_all()?;
    lyra::platform::restrict_file(identity_file.as_file())?;
    identity_file
        .persist(&identity_path)
        .map_err(|error| error.error)?;
    let block = managed_block(
        &config.zone,
        &identity.guest_username,
        &identity_name,
        &command,
    );
    install_block(&ssh_dir, &block)?;
    config::save(&config)?;
    let _ = log::emit(Event::Configured, None);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_proxy_command_is_one_double_quoted_path() {
        assert_eq!(
            quote_windows(r"C:\Users\Ann Lee\AppData\Local\Overalls\bin\overalls.exe").unwrap(),
            r#""C:\Users\Ann Lee\AppData\Local\Overalls\bin\overalls.exe""#
        );
        assert_eq!(
            quote_windows(r"C:\100%\overalls.exe").unwrap(),
            r#""C:\100%%\overalls.exe""#
        );
        assert!(quote_windows("C:\\a\"b.exe").is_err());
        assert!(quote_windows("C:\\a\nb.exe").is_err());
    }
    use hegel::{generators as gs, TestCase};
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn account_response_selects_remote_name_independent_of_local_alias() {
        let identity = parse_account(br#"{"version":1,"status":"succeeded","result":{"guest_username":"geoffrey.huntley","public_key":"ssh-ed25519 AAAA"}}"#).unwrap();
        assert_eq!(identity.guest_username, "geoffrey.huntley");
        assert!(parse_account(br#"{"version":1,"status":"succeeded","result":{"guest_username":"root","public_key":"ssh-ed25519 AAAA"}}"#).is_err());
    }

    #[test]
    fn configured_identity_uses_matching_disk_key_or_agent_public_key() {
        let directory = tempfile::tempdir().unwrap();
        let private = directory.path().join("id_rsa");
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-f"])
            .arg(&private)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success());
        let public_path = directory.path().join("id_rsa.pub");
        let key = fs::read_to_string(&public_path).unwrap();
        assert_eq!(
            local_identity(
                directory.path(),
                "ssh-ed25519 unrelated",
                Path::new("ssh-keygen")
            ),
            "overalls-identity.pub"
        );
        assert_eq!(
            local_identity(directory.path(), &key, Path::new("ssh-keygen")),
            "id_rsa"
        );
        fs::remove_file(&public_path).unwrap();
        assert_eq!(
            local_identity(directory.path(), &key, Path::new("ssh-keygen")),
            "id_rsa"
        );
    }

    #[test]
    fn encrypted_private_key_is_selected_by_its_public_sibling() {
        let directory = tempfile::tempdir().unwrap();
        let private = directory.path().join("id_work");
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "test-passphrase", "-f"])
            .arg(&private)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success());
        let public = fs::read_to_string(directory.path().join("id_work.pub")).unwrap();
        assert_eq!(
            local_identity(directory.path(), &public, Path::new("ssh-keygen")),
            "id_work"
        );
        assert_eq!(
            local_identity(
                directory.path(),
                "ssh-ed25519 unrelated",
                Path::new("ssh-keygen")
            ),
            "overalls-identity.pub"
        );
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_remote_name_cannot_escape_one_user_token(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let name = String::from_utf8_lossy(&bytes);
        if valid_guest_username(&name) {
            assert!(!name.contains(['\n', '\r', ' ', '@', '/']));
            assert!(name.len() <= 32);
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_remote_names_accept_local_parts_and_reject_account_escape(tc: TestCase) {
        let suffix = tc.draw(gs::integers::<u64>());
        let name = format!("user.{suffix:x}");
        assert!(valid_guest_username(&name));
        assert!(!valid_guest_username(&format!("{name}@example.com")));
        assert!(!valid_guest_username(&format!("/{name}")));
        assert!(!valid_guest_username(&format!("{name}\nroot")));
    }

    #[hegel::test(test_cases = 100)]
    fn generated_public_keys_require_exact_type_and_blob(tc: TestCase) {
        let key = tc.draw(gs::integers::<u128>());
        let registered = format!("ssh-ed25519 {key:032x} account-comment");
        let derived = format!("ssh-ed25519 {key:032x} local-comment\n");
        assert!(same_public_key(&registered, derived.as_bytes()));
        assert!(!same_public_key(
            &registered,
            format!("ssh-rsa {key:032x}\n").as_bytes()
        ));
        assert!(!same_public_key(
            &registered,
            format!("ssh-ed25519 {key:032x}0\n").as_bytes()
        ));
        assert!(!same_public_key(&registered, b"\xff\xfe"));
    }

    // Adversarial near-marker content that MUST be treated as unmanaged bytes:
    // marker text lacks the trailing newline, carries extra spacing/case, or
    // belongs to the known-hosts trust block rather than the config block.
    const UNMANAGED: &[&str] = &[
        "",
        "Host bastion\n  User ops\n  Port 22\n",
        "# operator note\n",
        "Include ~/.ssh/other.conf\n",
        "# BEGIN OVERALLS SSH TRUST gateway.example\n@cert-authority *.example ssh-ed25519 AAAA\n# END OVERALLS SSH TRUST gateway.example\n",
        "# BEGIN OVERALLS SSH",
        "# END OVERALLS SSH",
        "# BEGIN OVERALLS SSH \n# END OVERALLS SSH \n",
        "#  BEGIN OVERALLS SSH\n#  END OVERALLS SSH\n",
        "# begin overalls ssh\n# end overalls ssh\n",
        "# BEGIN OVERALLS SSH\r\n# END OVERALLS SSH\r\n",
    ];

    fn inventory(directory: &std::path::Path) -> Vec<(String, Vec<u8>)> {
        let mut entries = Vec::new();
        for entry in fs::read_dir(directory).unwrap() {
            let entry = entry.unwrap();
            let kind = entry.file_type().unwrap();
            let bytes = if kind.is_file() {
                fs::read(entry.path()).unwrap()
            } else if kind.is_symlink() {
                let mut tag = b"link:".to_vec();
                tag.extend(
                    fs::read_link(entry.path())
                        .unwrap()
                        .as_os_str()
                        .as_encoded_bytes(),
                );
                tag
            } else {
                b"other".to_vec()
            };
            entries.push((entry.file_name().to_string_lossy().into_owned(), bytes));
        }
        entries.sort();
        entries
    }

    // Independent byte-level oracle: remove the single well-ordered managed
    // region recognized by a first marker scan. Acceptance cases in these
    // tests construct prior content with at most one exact pair, so this does
    // not reimplement the production splice.
    fn strip_managed(text: &str) -> String {
        match (text.find(START), text.find(END)) {
            (Some(begin), Some(finish)) if begin < finish => {
                format!("{}{}", &text[..begin], &text[finish + END.len()..])
            }
            _ => text.to_owned(),
        }
    }

    fn fresh_block(number: u64) -> String {
        managed_block(
            &format!("z{number:x}.example"),
            &format!("user{number:x}"),
            "overalls-identity.pub",
            "'/opt/overalls/bin/overalls'",
        )
    }

    fn one_pair(result: &str) {
        assert_eq!(result.matches(START).count(), 1);
        assert_eq!(result.matches(END).count(), 1);
        assert!(result.find(START).unwrap() < result.find(END).unwrap());
    }

    #[test]
    fn empty_directory_install_places_exactly_one_managed_block() {
        let directory = tempfile::tempdir().unwrap();
        let block = fresh_block(7);
        install_block(directory.path(), &block).unwrap();
        let result = fs::read_to_string(directory.path().join("config")).unwrap();
        assert_eq!(result, block);
        one_pair(&result);
        assert_eq!(inventory(directory.path()).len(), 1);
        assert_eq!(
            fs::metadata(directory.path().join("config"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn symlinked_or_directory_config_is_refused_without_mutation() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("elsewhere"), "Host x\n").unwrap();
        let path = directory.path().join("config");
        std::os::unix::fs::symlink(directory.path().join("elsewhere"), &path).unwrap();
        let before = inventory(directory.path());
        assert!(install_block(directory.path(), &fresh_block(1)).is_err());
        assert_eq!(inventory(directory.path()), before);
        fs::remove_file(&path).unwrap();
        fs::create_dir(directory.path().join("config")).unwrap();
        let before = inventory(directory.path());
        assert!(install_block(directory.path(), &fresh_block(1)).is_err());
        assert_eq!(inventory(directory.path()), before);
    }

    #[test]
    fn interrupted_install_drops_temporary_file_and_reinstall_converges() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(
            directory.path().join("config"),
            "Host bastion\n  User ops\n",
        )
        .unwrap();
        let before = inventory(directory.path());
        {
            let mut file = tempfile::NamedTempFile::new_in(directory.path()).unwrap();
            file.write_all(b"# BEGIN OVERALLS SSH\nHost never\n")
                .unwrap();
            file.as_file().sync_all().unwrap();
            // Crash before persist: dropping the named temporary file unlinks it.
        }
        assert_eq!(inventory(directory.path()), before);
        let block = fresh_block(3);
        install_block(directory.path(), &block).unwrap();
        let first = fs::read_to_string(directory.path().join("config")).unwrap();
        assert_eq!(strip_managed(&first), "Host bastion\n  User ops\n");
        install_block(directory.path(), &block).unwrap();
        assert_eq!(
            fs::read_to_string(directory.path().join("config")).unwrap(),
            first
        );
    }

    #[test]
    fn spliced_glue_never_promotes_unmanaged_bytes_into_markers() {
        // The dangling marker tail and the following blank line are preserved
        // unmanaged bytes; splicing them together must not manufacture a
        // second managed block that wedges every later install.
        let prior =
            format!("# BEGIN OVERALLS SSH{START}Host old\n{END}\nHost bastion\n  User ops\n");
        assert!(splice(&prior, &fresh_block(1)).is_err());
        assert!(splice(&prior, &fresh_block(2)).is_err());
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("config"), &prior).unwrap();
        let before = inventory(directory.path());
        assert!(install_block(directory.path(), &fresh_block(1)).is_err());
        assert_eq!(inventory(directory.path()), before);
        // Without the joint newline the same tail remains ordinary content
        // and is preserved byte-identically.
        let plain = format!("# BEGIN OVERALLS SSH{START}Host old\n{END}Host bastion\n  User ops\n");
        let block = fresh_block(3);
        assert_eq!(
            splice(&plain, &block).unwrap(),
            format!("{block}# BEGIN OVERALLS SSHHost bastion\n  User ops\n")
        );
    }

    // @cc [owner:ghuntley,label:verification] installer-generated-config-preservation
    // Generated pre-existing local SSH configurations MUST survive installation
    // with every unmanaged byte preserved and exactly one managed marker pair;
    // reinstalling over real installer output MUST converge byte-identically.
    #[hegel::test(test_cases = 64)]
    fn generated_configurations_preserve_unmanaged_bytes(tc: TestCase) {
        let above = tc.draw(gs::sampled_from(UNMANAGED));
        let below = tc.draw(gs::sampled_from(UNMANAGED));
        let reinstall = tc.draw(gs::booleans());
        let number = tc.draw(gs::integers::<u64>());
        let block = fresh_block(number);
        let prior = if reinstall {
            format!("{above}{}{below}", fresh_block(number.wrapping_add(1)))
        } else {
            format!("{above}{below}")
        };
        let expected = format!("{block}{above}{below}");
        assert_eq!(splice(&prior, &block).unwrap(), expected);
        one_pair(&expected);
        assert_eq!(strip_managed(&expected), format!("{above}{below}"));
        assert_eq!(splice(&expected, &block).unwrap(), expected);
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("config"), &prior).unwrap();
        install_block(directory.path(), &block).unwrap();
        assert_eq!(
            fs::read_to_string(directory.path().join("config")).unwrap(),
            expected
        );
        assert_eq!(inventory(directory.path()).len(), 1);
    }

    // @cc [owner:ghuntley,label:verification] installer-generated-config-refusal
    // Generated ambiguous marker arrangements (duplicated begin or end markers,
    // reversed or unpaired markers) MUST be refused, leaving the whole SSH
    // directory byte-identical with no temporary-file residue.
    #[hegel::test(test_cases = 64)]
    fn generated_marker_ambiguity_is_refused_and_preserves_every_byte(tc: TestCase) {
        #[derive(Clone, Copy, Debug)]
        enum Ambiguity {
            TwoBegins,
            TwoEnds,
            TwoPairs,
            Reversed,
            LoneBegin,
            LoneEnd,
        }
        let ambiguity = tc.draw(gs::sampled_from(&[
            Ambiguity::TwoBegins,
            Ambiguity::TwoEnds,
            Ambiguity::TwoPairs,
            Ambiguity::Reversed,
            Ambiguity::LoneBegin,
            Ambiguity::LoneEnd,
        ]));
        let above = tc.draw(gs::sampled_from(UNMANAGED));
        let below = tc.draw(gs::sampled_from(UNMANAGED));
        let interior = fresh_block(9);
        let prior = match ambiguity {
            Ambiguity::TwoBegins => format!("{above}{START}{START}{interior}{below}"),
            Ambiguity::TwoEnds => format!("{above}{interior}{END}{END}{below}"),
            Ambiguity::TwoPairs => format!("{above}{interior}{interior}{below}"),
            Ambiguity::Reversed => format!("{above}{END}{below}{START}"),
            Ambiguity::LoneBegin => format!("{above}{START}{below}"),
            Ambiguity::LoneEnd => format!("{above}{END}{below}"),
        };
        assert!(splice(&prior, &fresh_block(4)).is_err());
        assert!(splice(&prior, &fresh_block(5)).is_err());
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("config"), &prior).unwrap();
        let before = inventory(directory.path());
        assert!(install_block(directory.path(), &fresh_block(4)).is_err());
        assert_eq!(inventory(directory.path()), before);
    }
}
