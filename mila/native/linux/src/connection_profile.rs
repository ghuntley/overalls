//! Per-deployment connection profiles.
//!
//! A deployment authority from the deployment list is, by default, reached
//! over SSH on port 22 with its trust document on HTTPS port 443 verified by
//! the system trust store. An optional owner-only profile file can override
//! the ports and name a private CA bundle for a deployment, for example a
//! self-hosted or hermetic test deployment. Profiles never carry credentials.

use crate::deployments::DeploymentHost;
use crate::signin_driver::SignInTarget;
use serde::Deserialize;
use std::path::{Path, PathBuf};

const MAX_PROFILE_BYTES: u64 = 64 * 1024;
const MAX_PROFILES: usize = 32;
pub const DEFAULT_SSH_PORT: u16 = 22;
pub const DEFAULT_HTTPS_PORT: u16 = 443;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProfileError {
    Unavailable,
    InsecurePermissions,
    Invalid,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ConnectionProfile {
    pub host: String,
    #[serde(default = "default_ssh_port")]
    pub ssh_port: u16,
    #[serde(default = "default_https_port")]
    pub https_port: u16,
    #[serde(default)]
    pub ca_file: Option<PathBuf>,
}

fn default_ssh_port() -> u16 {
    DEFAULT_SSH_PORT
}

fn default_https_port() -> u16 {
    DEFAULT_HTTPS_PORT
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProfileFile {
    version: u32,
    profiles: Vec<ConnectionProfile>,
}

/// Validated profiles keyed by canonical deployment authority.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ConnectionProfiles {
    profiles: Vec<ConnectionProfile>,
}

impl ConnectionProfiles {
    /// `$MILA_CONNECTIONS_PATH`, else `$XDG_CONFIG_HOME/mila/connections.json`,
    /// else `$HOME/.config/mila/connections.json`.
    pub fn default_path() -> Option<PathBuf> {
        if let Some(path) = std::env::var_os("MILA_CONNECTIONS_PATH") {
            return Some(PathBuf::from(path));
        }
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
            .map(|root| root.join("mila").join("connections.json"))
    }

    /// @cc [owner:ghuntley,label:security] linux-connection-profile-validated
    /// Profiles MUST come from a bounded owner-only regular file (no symlink),
    /// version 1 with no unknown fields, at most 32 entries with unique
    /// canonical deployment hosts, non-zero ports and absolute CA paths. A
    /// missing file MUST mean defaults; any invalid file MUST fail closed.
    pub fn load(path: &Path) -> Result<Self, ProfileError> {
        use std::os::unix::fs::PermissionsExt;
        let metadata = match std::fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default())
            }
            Err(_) => return Err(ProfileError::Unavailable),
        };
        if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(ProfileError::InsecurePermissions);
        }
        if metadata.len() > MAX_PROFILE_BYTES {
            return Err(ProfileError::Invalid);
        }
        let bytes = std::fs::read(path).map_err(|_| ProfileError::Unavailable)?;
        Self::parse(&bytes)
    }

    pub fn parse(bytes: &[u8]) -> Result<Self, ProfileError> {
        if bytes.len() as u64 > MAX_PROFILE_BYTES {
            return Err(ProfileError::Invalid);
        }
        let file: ProfileFile = serde_json::from_slice(bytes).map_err(|_| ProfileError::Invalid)?;
        if file.version != 1 || file.profiles.len() > MAX_PROFILES {
            return Err(ProfileError::Invalid);
        }
        let mut profiles: Vec<ConnectionProfile> = Vec::with_capacity(file.profiles.len());
        for profile in file.profiles {
            let host = DeploymentHost::parse(&profile.host).map_err(|_| ProfileError::Invalid)?;
            if host.as_str() != profile.host
                || profile.ssh_port == 0
                || profile.https_port == 0
                || profile
                    .ca_file
                    .as_ref()
                    .is_some_and(|path| !path.is_absolute())
                || profiles
                    .iter()
                    .any(|existing| existing.host == profile.host)
            {
                return Err(ProfileError::Invalid);
            }
            profiles.push(profile);
        }
        Ok(Self { profiles })
    }

    /// The connection for `deployment`: its profile, or the defaults. An
    /// authority with an explicit port and no profile uses that port for HTTPS.
    pub fn resolve(&self, deployment: &DeploymentHost) -> Result<SignInTarget, ProfileError> {
        let authority = deployment.as_str();
        let (host, authority_port) = match authority.rsplit_once(':') {
            Some((host, port)) => (
                host,
                Some(port.parse::<u16>().map_err(|_| ProfileError::Invalid)?),
            ),
            None => (authority, None),
        };
        let (ssh_port, https_port, ca_file) = match self
            .profiles
            .iter()
            .find(|profile| profile.host == authority)
        {
            Some(profile) => (
                profile.ssh_port,
                profile.https_port,
                profile.ca_file.clone(),
            ),
            None => (
                DEFAULT_SSH_PORT,
                authority_port.unwrap_or(DEFAULT_HTTPS_PORT),
                None,
            ),
        };
        let target =
            SignInTarget::new(host, ssh_port, https_port).map_err(|_| ProfileError::Invalid)?;
        match ca_file {
            Some(path) => target.with_ca_file(path).map_err(|_| ProfileError::Invalid),
            None => Ok(target),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(value: &str) -> DeploymentHost {
        DeploymentHost::parse(value).unwrap()
    }

    #[test]
    fn defaults_without_a_profile() {
        let resolved = ConnectionProfiles::default()
            .resolve(&host("mila.example"))
            .unwrap();
        assert_eq!(resolved.host(), "mila.example");
        assert_eq!(resolved.ssh_port(), 22);
        assert_eq!(resolved.https_authority(), "mila.example");
        assert_eq!(resolved.ca_file(), None);
    }

    #[test]
    fn profile_overrides_ports_and_ca() {
        let profiles = ConnectionProfiles::parse(
            br#"{"version":1,"profiles":[{"host":"localhost","ssh_port":2222,"https_port":8443,"ca_file":"/private/ca.pem"}]}"#,
        )
        .unwrap();
        let resolved = profiles.resolve(&host("localhost")).unwrap();
        assert_eq!(resolved.ssh_port(), 2222);
        assert_eq!(resolved.https_authority(), "localhost:8443");
        assert_eq!(resolved.ca_file(), Some(Path::new("/private/ca.pem")));
        let other = profiles.resolve(&host("mila.example")).unwrap();
        assert_eq!(other.ssh_port(), 22);
    }

    #[test]
    fn invalid_profiles_fail_closed() {
        for raw in [
            r#"{"version":2,"profiles":[]}"#,
            r#"{"version":1,"profiles":[],"extra":1}"#,
            r#"{"version":1,"profiles":[{"host":"LOCALHOST"}]}"#,
            r#"{"version":1,"profiles":[{"host":"localhost","ssh_port":0}]}"#,
            r#"{"version":1,"profiles":[{"host":"localhost","https_port":0}]}"#,
            r#"{"version":1,"profiles":[{"host":"localhost","ca_file":"relative.pem"}]}"#,
            r#"{"version":1,"profiles":[{"host":"localhost","token":"x"}]}"#,
            r#"{"version":1,"profiles":[{"host":"localhost"},{"host":"localhost"}]}"#,
            "{",
        ] {
            assert_eq!(
                ConnectionProfiles::parse(raw.as_bytes()),
                Err(ProfileError::Invalid),
                "{raw}"
            );
        }
        let many = (0..=MAX_PROFILES)
            .map(|index| format!(r#"{{"host":"h{index}.example"}}"#))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(
            ConnectionProfiles::parse(format!(r#"{{"version":1,"profiles":[{many}]}}"#).as_bytes()),
            Err(ProfileError::Invalid)
        );
    }

    #[test]
    fn missing_file_means_defaults_and_shared_files_are_refused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("mila-profiles-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("connections.json");
        assert_eq!(
            ConnectionProfiles::load(&path),
            Ok(ConnectionProfiles::default())
        );
        std::fs::write(&path, br#"{"version":1,"profiles":[]}"#).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            ConnectionProfiles::load(&path),
            Err(ProfileError::InsecurePermissions)
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            ConnectionProfiles::load(&path),
            Ok(ConnectionProfiles::default())
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
