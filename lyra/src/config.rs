use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;

#[derive(Clone, Deserialize, Serialize)]
pub struct Config {
    pub origin: String,
    pub zone: String,
    /// The OpenSSH client `config-ssh` verified (Windows: an absolute
    /// `ssh.exe`, because the in-box client may predate 9.6). Absent means the
    /// `ssh` on PATH, as Linux and macOS have always used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_program: Option<String>,
}

pub fn home() -> io::Result<PathBuf> {
    let value = env::var_os("HOME")
        .or_else(|| {
            if cfg!(windows) {
                env::var_os("USERPROFILE")
            } else {
                None
            }
        })
        .ok_or_else(|| io::Error::other("home unavailable"))?;
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(io::Error::other("invalid home"));
    }
    Ok(path)
}

pub fn state_dir() -> io::Result<PathBuf> {
    if guest_root() {
        return Ok(PathBuf::from("/var/lib/overalls"));
    }
    if cfg!(target_os = "macos") {
        return Ok(home()?.join("Library/Logs/Overalls"));
    }
    if cfg!(windows) {
        return Ok(windows_folder("LOCALAPPDATA")?
            .join("Overalls")
            .join("state"));
    }
    match env::var_os("XDG_STATE_HOME") {
        Some(value) if PathBuf::from(&value).is_absolute() => {
            Ok(PathBuf::from(value).join("overalls"))
        }
        _ => Ok(home()?.join(".local/state/overalls")),
    }
}

pub fn config_dir() -> io::Result<PathBuf> {
    if cfg!(windows) {
        return Ok(windows_folder("APPDATA")?.join("Overalls"));
    }
    match env::var_os("XDG_CONFIG_HOME") {
        Some(value) if PathBuf::from(&value).is_absolute() => {
            Ok(PathBuf::from(value).join("overalls"))
        }
        _ => Ok(home()?.join(".config/overalls")),
    }
}

pub fn managed_bin() -> io::Result<PathBuf> {
    if guest_root() {
        return Ok(PathBuf::from("/var/lib/overalls/bin/overalls"));
    }
    if cfg!(windows) {
        return Ok(windows_folder("LOCALAPPDATA")?
            .join("Overalls")
            .join("bin")
            .join("overalls.exe"));
    }
    Ok(home()?.join(".local/bin/overalls"))
}

/// A Windows known-folder environment variable (`LOCALAPPDATA`, `APPDATA`),
/// which MUST be an absolute path.
fn windows_folder(name: &str) -> io::Result<PathBuf> {
    let path = PathBuf::from(
        env::var_os(name).ok_or_else(|| io::Error::other("profile folder unavailable"))?,
    );
    if !path.is_absolute() {
        return Err(io::Error::other("invalid profile folder"));
    }
    Ok(path)
}

#[cfg(target_os = "linux")]
pub fn guest_root() -> bool {
    (unsafe { libc::geteuid() } == 0) && std::path::Path::new("/etc/overalls/guest-agent").is_file()
}

/// Managed guests are Linux; a macOS or Windows workstation never is one.
#[cfg(not(target_os = "linux"))]
pub fn guest_root() -> bool {
    false
}

/// @cc [owner:ghuntley,label:security] workstation-ssh-program
/// A recorded OpenSSH client MUST be an absolute path to an existing file
/// named `ssh` or `ssh.exe`; otherwise the CLI uses `ssh` from PATH.
pub fn ssh_program(config: Option<&Config>) -> std::ffi::OsString {
    config
        .and_then(|config| config.ssh_program.as_deref())
        .map(PathBuf::from)
        .filter(|path| valid_ssh_program(path))
        .map(PathBuf::into_os_string)
        .unwrap_or_else(|| "ssh".into())
}

pub fn valid_ssh_program(path: &std::path::Path) -> bool {
    path.is_absolute()
        && path.is_file()
        && matches!(
            path.file_name().and_then(|name| name.to_str()),
            Some("ssh" | "ssh.exe")
        )
}

pub fn valid_zone(value: &str) -> bool {
    valid_dns_name(value, 189)
}

pub fn valid_host(value: &str) -> bool {
    valid_dns_name(value, 253)
}

// @cc [owner:ghuntley,label:security] lyra-identity-selector-one-component
// The identity selected by setup MUST remain one bounded .ssh filename; it may
// not turn the outer proxy's identity option into a path or SSH token expansion.
pub fn valid_ssh_identity_name(value: &str) -> bool {
    (1..=255).contains(&value.len())
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn valid_dns_name(value: &str, maximum: usize) -> bool {
    (1..=maximum).contains(&value.len())
        && value.split('.').all(|part| {
            (1..=63).contains(&part.len())
                && !part.starts_with('-')
                && !part.ends_with('-')
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}

pub fn valid_origin(value: &str) -> bool {
    let Some(authority) = value.strip_prefix("https://") else {
        return false;
    };
    let (host, valid_port) = match authority.split_once(':') {
        Some((host, port)) => (host, port.parse::<u16>().is_ok_and(|value| value > 0)),
        None => (authority, true),
    };
    !host.is_empty() && valid_zone(host) && valid_port && !authority.contains('@')
}

pub fn valid_label(value: &str) -> bool {
    let Some((prefix, id)) = value.rsplit_once('-') else {
        return false;
    };
    (34..=63).contains(&value.len())
        && prefix.starts_with(|c: char| c.is_ascii_lowercase())
        && prefix
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn label_for<'a>(host: &'a str, zone: &str) -> Option<&'a str> {
    let suffix = format!(".{zone}");
    let label = host.strip_suffix(&suffix)?;
    valid_label(label).then_some(label)
}

pub fn save(config: &Config) -> io::Result<()> {
    if !valid_origin(&config.origin) || !valid_zone(&config.zone) {
        return Err(io::Error::other("invalid configuration"));
    }
    let dir = config_dir()?;
    fs::create_dir_all(&dir)?;
    lyra::platform::restrict_directory(&dir)?;
    let path = dir.join("config.json");
    let mut file = tempfile::NamedTempFile::new_in(&dir)?;
    file.write_all(&serde_json::to_vec(config).map_err(io::Error::other)?)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|error| error.error)?;
    Ok(())
}

pub fn load() -> io::Result<Config> {
    let bytes = fs::read(config_dir()?.join("config.json"))?;
    if bytes.len() > 4096 {
        return Err(io::Error::other("configuration too large"));
    }
    let config: Config = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if !valid_origin(&config.origin) || !valid_zone(&config.zone) {
        return Err(io::Error::other("invalid configuration"));
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    #[test]
    fn labels_are_canonical() {
        let id = "0123456789abcdef0123456789abcdef";
        assert!(valid_label(&format!("a-{id}")));
        assert!(!valid_label(&format!("A-{id}")));
        assert!(!valid_label(&format!("a;touch-{id}")));
        assert_eq!(
            label_for(&format!("a-{id}.vm.example"), "vm.example"),
            Some(&format!("a-{id}")[..])
        );
        assert!(!valid_origin("https://example.com:"));
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_host_never_escapes_validated_label(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let host = String::from_utf8_lossy(&bytes);
        if let Some(label) = label_for(&host, "vm.example") {
            assert!(valid_label(label));
            assert_eq!(host.as_ref(), format!("{label}.vm.example"));
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_vm_identity_round_trips_and_rejects_suffixes(tc: TestCase) {
        let id = tc.draw(gs::integers::<u128>());
        let label = format!("vm-{id:032x}");
        let host = format!("{label}.vm.example");
        assert_eq!(label_for(&host, "vm.example"), Some(label.as_str()));
        assert_eq!(label_for(&format!("{host}.evil"), "vm.example"), None);
        assert_eq!(label_for(&host, "other.example"), None);
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_origin_cannot_contain_url_metacharacters(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let origin = String::from_utf8_lossy(&bytes);
        if valid_origin(&origin) {
            assert!(!origin
                .trim_start_matches("https://")
                .contains(['/', '?', '#', '@', '%', ' ', '\n']));
        }
    }

    #[hegel::test(test_cases = 100)]
    fn generated_hostnames_keep_dns_labels_and_a_fixed_length_bound(tc: TestCase) {
        let value = tc.draw(gs::integers::<u128>());
        let host = format!("vm-{value:032x}.apps.example.test");
        assert!(valid_host(&host));
        assert!(!valid_host(&format!("{host}.invalid/route")));
        assert!(!valid_host(&format!("{host}\nother")));
        assert!(!valid_host(&"a".repeat(254)));
    }

    #[hegel::test(test_cases = 100)]
    fn arbitrary_identity_names_cannot_escape_ssh_directory(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let name = String::from_utf8_lossy(&bytes);
        if valid_ssh_identity_name(&name) {
            assert!(name.len() <= 255);
            assert!(!name.contains(['/', '%', ' ', '\n', '\r', '\0']));
            assert_ne!(name, ".");
            assert_ne!(name, "..");
        }
        assert!(!valid_ssh_identity_name("../id_ed25519"));
        assert!(!valid_ssh_identity_name("id_ed25519%h"));
        let suffix = tc.draw(gs::integers::<u128>());
        let selected = format!("work_{suffix:x}");
        assert!(valid_ssh_identity_name(&selected));
        assert!(!valid_ssh_identity_name(&format!("../{selected}")));
        assert!(!valid_ssh_identity_name(&format!("{selected}\nother")));
    }
}
