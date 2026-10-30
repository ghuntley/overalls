//! Typed, durable deployment list for the Linux client.
//!
//! Only validated deployment authorities and the selected authority are
//! persisted. Trust documents, device keys and session material live elsewhere
//! and are never written by this module. The model is GTK-independent so the
//! headless journey driver and the GTK window share one implementation.

use crate::route::ActivationRoute;
use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path, path::PathBuf};

/// Most deployments retained; adding beyond this is refused, never evicted.
pub const MAX_DEPLOYMENTS: usize = 32;
const MAX_PERSISTED_BYTES: usize = 64 * 1024;
const FORMAT_VERSION: u32 = 1;

/// A canonical deployment authority (`host` or `host:port`).
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct DeploymentHost(String);

impl DeploymentHost {
    /// Validates through the bounded `overalls://` route grammar so the
    /// stored authority is exactly what deep links compare against.
    pub fn parse(value: &str) -> Result<Self, DeploymentError> {
        let host = value.trim().to_ascii_lowercase();
        if host.is_empty() || host.len() > 512 || host.contains(['/', '?', '#']) {
            return Err(DeploymentError::InvalidHost);
        }
        let parsed = ActivationRoute::parse(&format!("overalls://{host}/machines"))
            .map_err(|_| DeploymentError::InvalidHost)?;
        let canonical = parsed.canonical();
        let authority = canonical
            .strip_prefix("overalls://")
            .and_then(|value| value.strip_suffix("/machines"))
            .ok_or(DeploymentError::InvalidHost)?;
        Ok(Self(authority.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The navigation-only landing route for this deployment.
    pub fn route(&self) -> String {
        format!("overalls://{}/machines", self.0)
    }
}

#[derive(Debug)]
pub enum DeploymentError {
    InvalidHost,
    Full,
    Unknown,
    InvalidData,
    Io(io::Error),
}

impl From<io::Error> for DeploymentError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// The observable effect of [`DeploymentList::forget`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ForgetOutcome {
    pub removed: bool,
    /// The forgotten deployment was selected; the caller MUST drop its session.
    pub was_selected: bool,
}

/// One row shown by the deployment list UI.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeploymentRow {
    pub host: String,
    pub selected: bool,
}

/// @cc [owner:ghuntley,label:security;desktop] linux-deployment-list-bounded
/// The list MUST hold at most `MAX_DEPLOYMENTS` distinct canonical hosts,
/// MUST select only a host it contains, and forgetting the selected host MUST
/// leave no selection rather than implicitly selecting another deployment.
/// Decoding MUST fail closed on any invalid host, duplicate, or a selection
/// outside the list, and MUST accept the legacy single-host file as a
/// one-entry selected list.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DeploymentList {
    hosts: Vec<DeploymentHost>,
    selected: Option<DeploymentHost>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StoredList {
    version: u32,
    selected: Option<String>,
    deployments: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacySelection {
    host: String,
}

impl DeploymentList {
    pub fn hosts(&self) -> &[DeploymentHost] {
        &self.hosts
    }

    pub fn selected(&self) -> Option<&DeploymentHost> {
        self.selected.as_ref()
    }

    pub fn rows(&self) -> Vec<DeploymentRow> {
        self.hosts
            .iter()
            .map(|host| DeploymentRow {
                host: host.as_str().to_owned(),
                selected: self.selected.as_ref() == Some(host),
            })
            .collect()
    }

    /// Adds a host without selecting it. Re-adding an existing host is a no-op.
    pub fn add(&mut self, host: &str) -> Result<DeploymentHost, DeploymentError> {
        let host = DeploymentHost::parse(host)?;
        if !self.hosts.contains(&host) {
            if self.hosts.len() >= MAX_DEPLOYMENTS {
                return Err(DeploymentError::Full);
            }
            self.hosts.push(host.clone());
        }
        Ok(host)
    }

    /// Selects a host already in the list. Returns whether the selection
    /// changed, in which case the caller MUST drop any authenticated session.
    pub fn select(&mut self, host: &str) -> Result<bool, DeploymentError> {
        let host = DeploymentHost::parse(host)?;
        if !self.hosts.contains(&host) {
            return Err(DeploymentError::Unknown);
        }
        let changed = self.selected.as_ref() != Some(&host);
        self.selected = Some(host);
        Ok(changed)
    }

    /// Adds then selects; the combined effect of the former client's Add.
    pub fn add_and_select(&mut self, host: &str) -> Result<bool, DeploymentError> {
        let host = self.add(host)?;
        self.select(host.as_str())
    }

    /// Removes a host. Idempotent; malformed input removes nothing.
    pub fn forget(&mut self, host: &str) -> ForgetOutcome {
        let Ok(host) = DeploymentHost::parse(host) else {
            return ForgetOutcome {
                removed: false,
                was_selected: false,
            };
        };
        let before = self.hosts.len();
        self.hosts.retain(|candidate| candidate != &host);
        let was_selected = self.selected.as_ref() == Some(&host);
        if was_selected {
            self.selected = None;
        }
        ForgetOutcome {
            removed: self.hosts.len() != before,
            was_selected,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(&StoredList {
            version: FORMAT_VERSION,
            selected: self.selected.as_ref().map(|host| host.0.clone()),
            deployments: self.hosts.iter().map(|host| host.0.clone()).collect(),
        })
        .expect("deployment list serializes")
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DeploymentError> {
        if bytes.len() > MAX_PERSISTED_BYTES {
            return Err(DeploymentError::InvalidData);
        }
        if let Ok(legacy) = serde_json::from_slice::<LegacySelection>(bytes) {
            let mut list = Self::default();
            list.add_and_select(&legacy.host)
                .map_err(|_| DeploymentError::InvalidData)?;
            return Ok(list);
        }
        let stored: StoredList =
            serde_json::from_slice(bytes).map_err(|_| DeploymentError::InvalidData)?;
        if stored.version != FORMAT_VERSION || stored.deployments.len() > MAX_DEPLOYMENTS {
            return Err(DeploymentError::InvalidData);
        }
        let mut list = Self::default();
        for host in &stored.deployments {
            let parsed = DeploymentHost::parse(host).map_err(|_| DeploymentError::InvalidData)?;
            if list.hosts.contains(&parsed) {
                return Err(DeploymentError::InvalidData);
            }
            list.hosts.push(parsed);
        }
        if let Some(selected) = stored.selected {
            list.select(&selected)
                .map_err(|_| DeploymentError::InvalidData)?;
        }
        Ok(list)
    }
}

/// Owner-only, atomically replaced file holding one [`DeploymentList`].
#[derive(Clone, Debug)]
pub struct DeploymentStore {
    path: PathBuf,
}

impl DeploymentStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// `MILA_DEPLOYMENT_PATH`, else `$XDG_CONFIG_HOME/mila/deployment.json`,
    /// else `$HOME/.config/mila/deployment.json`. The file name is kept from
    /// the single-deployment format so existing selections migrate in place.
    pub fn from_environment() -> Option<Self> {
        if let Some(path) = std::env::var_os("MILA_DEPLOYMENT_PATH") {
            return Some(Self::new(PathBuf::from(path)));
        }
        let root = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
        Some(Self::new(root.join("mila").join("deployment.json")))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// A missing file is an empty list; a group/world-accessible, oversized
    /// or malformed file is refused rather than partially trusted.
    pub fn load(&self) -> Result<DeploymentList, DeploymentError> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(DeploymentList::default())
            }
            Err(error) => return Err(error.into()),
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let metadata = fs::symlink_metadata(&self.path)?;
            if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o077 != 0 {
                return Err(DeploymentError::InvalidData);
            }
        }
        DeploymentList::decode(&bytes)
    }

    pub fn save(&self, list: &DeploymentList) -> Result<(), DeploymentError> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid path"))?;
        fs::create_dir_all(parent)?;
        let temporary = self.path.with_extension("json.tmp");
        {
            use std::io::Write;
            let mut options = fs::OpenOptions::new();
            options.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
            }
            file.write_all(&list.encode())?;
            file.sync_all()?;
        }
        fs::rename(temporary, &self.path)?;
        Ok(())
    }

    /// Load, apply one change, and persist only when the change succeeded.
    pub fn update<R>(
        &self,
        change: impl FnOnce(&mut DeploymentList) -> Result<R, DeploymentError>,
    ) -> Result<(DeploymentList, R), DeploymentError> {
        let mut list = self.load()?;
        let result = change(&mut list)?;
        self.save(&list)?;
        Ok((list, result))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str) -> DeploymentStore {
        let directory = std::env::temp_dir().join(format!(
            "mila-deployments-{}-{name}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        DeploymentStore::new(directory.join("deployment.json"))
    }

    #[test]
    fn host_validation_matches_route_grammar() {
        assert_eq!(
            DeploymentHost::parse("Example.COM:443").unwrap().as_str(),
            "example.com:443"
        );
        assert_eq!(
            DeploymentHost::parse("localhost").unwrap().as_str(),
            "localhost"
        );
        for invalid in [
            "https://example.com",
            "example.com/",
            "example.com:0",
            "",
            "a b",
            "user@x",
        ] {
            assert!(DeploymentHost::parse(invalid).is_err(), "{invalid}");
        }
        assert_eq!(
            DeploymentHost::parse("example.com:443").unwrap().route(),
            "overalls://example.com:443/machines"
        );
    }

    #[test]
    fn add_select_forget_semantics() {
        let mut list = DeploymentList::default();
        assert!(list.add_and_select("one.example").unwrap());
        list.add("TWO.example").unwrap();
        list.add("two.example").unwrap();
        assert_eq!(list.hosts().len(), 2);
        assert!(matches!(
            list.select("three.example"),
            Err(DeploymentError::Unknown)
        ));
        assert!(!list.select("one.example").unwrap());
        assert!(list.select("two.example").unwrap());
        assert_eq!(
            list.rows(),
            vec![
                DeploymentRow {
                    host: "one.example".into(),
                    selected: false
                },
                DeploymentRow {
                    host: "two.example".into(),
                    selected: true
                },
            ]
        );
        let outcome = list.forget("two.example");
        assert_eq!(
            outcome,
            ForgetOutcome {
                removed: true,
                was_selected: true
            }
        );
        assert_eq!(
            list.selected(),
            None,
            "forget never auto-selects another host"
        );
        assert_eq!(
            list.forget("two.example"),
            ForgetOutcome {
                removed: false,
                was_selected: false
            }
        );
        assert_eq!(
            list.forget("bad host"),
            ForgetOutcome {
                removed: false,
                was_selected: false
            }
        );
    }

    #[test]
    fn list_is_bounded_without_eviction() {
        let mut list = DeploymentList::default();
        for index in 0..MAX_DEPLOYMENTS {
            list.add(&format!("host{index}.example")).unwrap();
        }
        assert!(matches!(
            list.add("overflow.example"),
            Err(DeploymentError::Full)
        ));
        list.add("host0.example").unwrap();
        assert_eq!(list.hosts().len(), MAX_DEPLOYMENTS);
        assert_eq!(list.hosts()[0].as_str(), "host0.example");
    }

    /// Every sequence of operations over a small host alphabet round-trips
    /// through the codec and keeps the selection inside the list.
    #[test]
    fn operation_sequences_preserve_invariants_and_round_trip() {
        let hosts = ["a.example", "b.example", "c.example:8443", "bad host"];
        for seed in 0_u32..4_096 {
            let mut list = DeploymentList::default();
            let mut value = seed;
            for _ in 0..6 {
                let host = hosts[(value % 4) as usize];
                match (value / 4) % 3 {
                    0 => {
                        let _ = list.add(host);
                    }
                    1 => {
                        let _ = list.select(host);
                    }
                    _ => {
                        list.forget(host);
                    }
                }
                value /= 12;
                if let Some(selected) = list.selected() {
                    assert!(list.hosts().contains(selected));
                }
                let mut unique = list.hosts().to_vec();
                unique.sort();
                unique.dedup();
                assert_eq!(unique.len(), list.hosts().len());
                assert_eq!(DeploymentList::decode(&list.encode()).unwrap(), list);
            }
        }
    }

    #[test]
    fn decode_migrates_legacy_and_fails_closed() {
        let legacy = DeploymentList::decode(br#"{"host":"Example.com:443"}"#).unwrap();
        assert_eq!(legacy.selected().unwrap().as_str(), "example.com:443");
        assert_eq!(legacy.hosts().len(), 1);
        for invalid in [
            &br#"{"host":"https://x"}"#[..],
            br#"{"version":2,"selected":null,"deployments":[]}"#,
            br#"{"version":1,"selected":"z.example","deployments":["a.example"]}"#,
            br#"{"version":1,"selected":null,"deployments":["a.example","A.example"]}"#,
            br#"{"version":1,"selected":null,"deployments":["bad host"]}"#,
            br#"{"version":1,"selected":null,"deployments":[],"token":"x"}"#,
            b"not json",
        ] {
            assert!(DeploymentList::decode(invalid).is_err());
        }
        assert!(DeploymentList::decode(&vec![b' '; MAX_PERSISTED_BYTES + 1]).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn store_is_owner_only_atomic_and_migrates_in_place() {
        use std::os::unix::fs::PermissionsExt;
        let store = store("roundtrip");
        assert_eq!(store.load().unwrap(), DeploymentList::default());
        fs::create_dir_all(store.path().parent().unwrap()).unwrap();
        fs::write(store.path(), br#"{"host":"legacy.example"}"#).unwrap();
        fs::set_permissions(store.path(), fs::Permissions::from_mode(0o600)).unwrap();
        let (list, changed) = store
            .update(|list| list.add_and_select("new.example"))
            .unwrap();
        assert!(changed);
        assert_eq!(list.hosts().len(), 2);
        assert_eq!(
            fs::metadata(store.path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(store.load().unwrap(), list);
        assert!(store.update(|list| list.select("missing.example")).is_err());
        assert_eq!(
            store.load().unwrap(),
            list,
            "failed change is not persisted"
        );
        fs::set_permissions(store.path(), fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(store.load(), Err(DeploymentError::InvalidData)));
        let _ = fs::remove_dir_all(store.path().parent().unwrap());
    }
}
