//! Durable, deployment-bound offline machine snapshots. Cached rows are read-only.
use crate::machine_view::{project_snapshot, MachineRow};
use mila_runtime::{MachineSnapshot, MAX_SNAPSHOT_BYTES};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::{
    fmt::Write as _,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotError {
    Unavailable,
    UnsafeStorage,
    Invalid,
}

#[derive(Debug, Default)]
struct Binding {
    generation: u64,
    target: Option<(String, u16)>,
}

/// @cc [owner:ghuntley,label:security;privacy] mila-linux-durable-snapshot
/// Only complete Rust-validated snapshots for this management host and SSH port
/// may persist. Binding invalidates prior writers. Atomic owner-only regular
/// files retain the newest timestamp; all offline permission flags are false.
#[derive(Debug)]
pub struct SnapshotCache {
    directory: PathBuf,
    binding: Mutex<Binding>,
}

impl SnapshotCache {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            binding: Mutex::default(),
        }
    }

    pub fn from_environment() -> Option<Self> {
        let root = std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))?;
        Some(Self::new(root.join("mila").join("snapshots")))
    }

    pub fn bind(&self, target: Option<(&str, u16)>) -> u64 {
        let mut binding = self
            .binding
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        binding.generation = binding.generation.wrapping_add(1);
        binding.target = target.map(|(host, port)| (host.to_owned(), port));
        binding.generation
    }

    pub fn load(&self, host: &str, port: u16) -> Result<Option<Vec<MachineRow>>, SnapshotError> {
        let _binding = self
            .binding
            .lock()
            .map_err(|_| SnapshotError::Unavailable)?;
        let Some(bytes) = self.read(host, port)? else {
            return Ok(None);
        };
        let snapshot = MachineSnapshot::decode(&bytes, host, Some(port))
            .map_err(|_| SnapshotError::Invalid)?;
        let bounded = snapshot.encode().map_err(|_| SnapshotError::Invalid)?;
        let mut rows = project_snapshot(&bounded).map_err(|_| SnapshotError::Invalid)?;
        for row in &mut rows {
            row.can_read = false;
            row.can_write = false;
            row.can_manage = false;
        }
        Ok(Some(rows))
    }

    pub fn save(
        &self,
        bytes: &[u8],
        host: &str,
        port: u16,
        generation: u64,
    ) -> Result<bool, SnapshotError> {
        let binding = self
            .binding
            .lock()
            .map_err(|_| SnapshotError::Unavailable)?;
        if binding.generation != generation
            || binding.target.as_ref().map(|(h, p)| (h.as_str(), *p)) != Some((host, port))
        {
            return Ok(false);
        }
        let fresh =
            MachineSnapshot::decode(bytes, host, Some(port)).map_err(|_| SnapshotError::Invalid)?;
        if let Some(existing) = self.read(host, port)? {
            let previous = MachineSnapshot::decode(&existing, host, Some(port))
                .map_err(|_| SnapshotError::Invalid)?;
            if previous.saved_at >= fresh.saved_at {
                return Ok(false);
            }
        }
        let mut builder = fs::DirBuilder::new();
        builder
            .recursive(true)
            .mode(0o700)
            .create(&self.directory)
            .map_err(|_| SnapshotError::Unavailable)?;
        require_owner_only(&self.directory, true)?;
        let path = self.path(host, port);
        let temporary = path.with_extension(format!("{}.{}.new", std::process::id(), generation));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(NO_FOLLOW)
                .open(&temporary)
                .map_err(|_| SnapshotError::Unavailable)?;
            file.write_all(bytes)
                .and_then(|()| file.sync_all())
                .map_err(|_| SnapshotError::Unavailable)?;
            fs::rename(&temporary, &path).map_err(|_| SnapshotError::Unavailable)?;
            fs::File::open(&self.directory)
                .and_then(|file| file.sync_all())
                .map_err(|_| SnapshotError::Unavailable)?;
            Ok(true)
        })();
        let _ = fs::remove_file(temporary);
        result
    }

    pub fn forget(&self, host: &str, port: u16) -> Result<(), SnapshotError> {
        let mut binding = self
            .binding
            .lock()
            .map_err(|_| SnapshotError::Unavailable)?;
        if binding.target.as_ref().map(|(h, p)| (h.as_str(), *p)) == Some((host, port)) {
            binding.generation = binding.generation.wrapping_add(1);
        }
        if !self.directory.exists() {
            return Ok(());
        }
        require_owner_only(&self.directory, true)?;
        match fs::remove_file(self.path(host, port)) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(SnapshotError::Unavailable),
        }
    }

    fn path(&self, host: &str, port: u16) -> PathBuf {
        let digest = Sha256::digest(format!("{host}:{port}").as_bytes());
        let mut name = String::with_capacity(digest.len() * 2);
        for byte in digest {
            let _ = write!(&mut name, "{byte:02x}");
        }
        self.directory.join(format!("{name}.json"))
    }

    fn read(&self, host: &str, port: u16) -> Result<Option<Vec<u8>>, SnapshotError> {
        if !self.directory.exists() {
            return Ok(None);
        }
        require_owner_only(&self.directory, true)?;
        let path = self.path(host, port);
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(SnapshotError::Unavailable),
            Ok(_) => {}
        }
        require_owner_only(&path, false)?;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(NO_FOLLOW)
            .open(path)
            .map_err(|_| SnapshotError::Unavailable)?;
        let mut bytes = Vec::new();
        file.take((MAX_SNAPSHOT_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| SnapshotError::Unavailable)?;
        MachineSnapshot::decode(&bytes, host, Some(port)).map_err(|_| SnapshotError::Invalid)?;
        Ok(Some(bytes))
    }
}

// Linux O_NOFOLLOW: keep symlinks refused even if a path changes after metadata.
const NO_FOLLOW: i32 = 0o400_000;
unsafe extern "C" {
    fn geteuid() -> u32;
}
fn require_owner_only(path: &Path, directory: bool) -> Result<(), SnapshotError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| SnapshotError::Unavailable)?;
    // SAFETY: geteuid takes no arguments and returns the process's effective uid.
    let owner = unsafe { geteuid() };
    if metadata.uid() != owner
        || metadata.permissions().mode() & 0o077 != 0
        || (if directory {
            !metadata.is_dir()
        } else {
            !metadata.is_file() || metadata.len() > MAX_SNAPSHOT_BYTES as u64
        })
    {
        return Err(SnapshotError::UnsafeStorage);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(saved_at: u64) -> Vec<u8> {
        format!(r#"{{"version":1,"host":"mgmt.example.test","port":22,"saved_at":{saved_at},"machines":[{{"id":"11111111-1111-1111-1111-111111111111","name":"vm","desired_state":"running","observed_state":null,"pinned":false,"owner":null,"read":true,"write":true,"manage":true}}]}}"#).into_bytes()
    }
    fn directory() -> PathBuf {
        std::env::temp_dir().join(format!(
            "mila-snapshots-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
    #[test]
    fn restart_newest_generation_deployment_and_read_only() {
        let directory = directory();
        let cache = SnapshotCache::new(directory.clone());
        let generation = cache.bind(Some(("mgmt.example.test", 22)));
        assert!(cache
            .save(&fixture(20), "mgmt.example.test", 22, generation)
            .unwrap());
        assert!(!cache
            .save(&fixture(10), "mgmt.example.test", 22, generation)
            .unwrap());
        assert!(cache
            .save(&fixture(30), "other.example.test", 22, generation)
            .is_ok_and(|saved| !saved));
        cache.bind(Some(("other.example.test", 22)));
        assert!(!cache
            .save(&fixture(40), "mgmt.example.test", 22, generation)
            .unwrap());
        let restarted = SnapshotCache::new(directory.clone());
        let rows = restarted.load("mgmt.example.test", 22).unwrap().unwrap();
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].can_read && !rows[0].can_write && !rows[0].can_manage);
        assert!(restarted.load("mgmt.example.test", 2222).unwrap().is_none());
        restarted.forget("mgmt.example.test", 22).unwrap();
        assert!(restarted.load("mgmt.example.test", 22).unwrap().is_none());
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn restart_retains_every_machine_in_the_complete_window() {
        let directory = directory();
        let cache = SnapshotCache::new(directory.clone());
        let generation = cache.bind(Some(("mgmt.example.test", 22)));
        let mut snapshot =
            MachineSnapshot::decode(&fixture(20), "mgmt.example.test", Some(22)).unwrap();
        let template = snapshot.machines[0].clone();
        snapshot.machines = (0..500)
            .map(|index| {
                let mut machine = template.clone();
                machine.id = format!("00000000-0000-0000-0000-{index:012x}");
                machine
            })
            .collect();
        cache
            .save(
                &snapshot.encode().unwrap(),
                "mgmt.example.test",
                22,
                generation,
            )
            .unwrap();
        let rows = SnapshotCache::new(directory.clone())
            .load("mgmt.example.test", 22)
            .unwrap()
            .unwrap();
        assert_eq!(rows.len(), 500);
        assert!(rows
            .iter()
            .all(|row| !row.can_read && !row.can_write && !row.can_manage));
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn refuses_malformed_shared_and_symlinked_storage() {
        let directory = directory();
        let cache = SnapshotCache::new(directory.clone());
        let generation = cache.bind(Some(("mgmt.example.test", 22)));
        assert_eq!(
            cache.save(b"{}", "mgmt.example.test", 22, generation),
            Err(SnapshotError::Invalid)
        );
        cache
            .save(&fixture(20), "mgmt.example.test", 22, generation)
            .unwrap();
        let path = cache.path("mgmt.example.test", 22);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        assert_eq!(
            cache.load("mgmt.example.test", 22),
            Err(SnapshotError::UnsafeStorage)
        );
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", &path).unwrap();
        assert_eq!(
            cache.load("mgmt.example.test", 22),
            Err(SnapshotError::UnsafeStorage)
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
