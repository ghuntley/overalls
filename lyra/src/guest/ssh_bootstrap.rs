//! Windows SSH listener bootstrap, separate from ordinary key authority.

use std::fs;
use std::io;
use std::path::Path;

pub const READY: &str = "C:\\overalls\\run\\ssh-ready";
pub const CERTIFICATE_READY: &str = "C:\\overalls\\run\\ssh-host-certificate-ready";

/// @cc [owner:ghuntley,label:security;recovery] windows-readiness-current-ssh-bootstrap
/// Windows readiness MUST require current-boot SSH bootstrap and verified
/// host-certificate receipts plus a live sshd service on every poll. A missing,
/// stale or unreadable receipt MUST withhold readiness even if sshd runs;
/// service probe errors MUST NOT authorize a response.
pub fn ready(
    marker_current: bool,
    certificate_current: bool,
    sshd_running: impl FnOnce() -> io::Result<bool>,
) -> io::Result<bool> {
    if !marker_current || !certificate_current {
        return Ok(false);
    }
    sshd_running()
}

/// The operating-system effects required before readiness can break the
/// completed-start dependency of the ordinary authorized-key route.
pub trait Host {
    fn bootstrap_current(&self) -> bool;
    fn certificate_current(&self) -> bool;
    fn stop_listener(&mut self) -> io::Result<()>;
    fn clear_keys(&mut self) -> io::Result<()>;
    fn start_listener(&mut self) -> io::Result<()>;
    fn publish_ready(&mut self) -> io::Result<()>;
}

/// @cc [owner:ghuntley,label:security;recovery] windows-ssh-bootstrap-before-key-authority
/// A new boot MUST stop sshd and remove prior authorized-key files before
/// starting its listener or publishing readiness. A current verified host
/// certificate is required. Ordinary key retrieval MUST remain after this
/// bootstrap and retain its completed-start authority; same-boot recovery
/// MUST preserve current keys rather than erase them on every retry.
pub fn ensure(host: &mut impl Host) -> io::Result<bool> {
    let current = host.bootstrap_current();
    if !current {
        host.stop_listener()?;
        host.clear_keys()?;
    }
    if !host.certificate_current() {
        return Ok(false);
    }
    host.start_listener()?;
    if !current {
        host.publish_ready()?;
    }
    Ok(true)
}

fn plain(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return false;
        }
    }
    !metadata.file_type().is_symlink()
}

/// @cc [owner:ghuntley,label:security] windows-stale-key-directory-contained
/// Bootstrap cleanup MUST remove only regular files directly in the managed
/// key directory, refuse reparse points and unexpected directories, and never
/// recursively follow a path. Any refusal MUST prevent listener bootstrap.
pub fn clear_keys(directory: &Path) -> io::Result<()> {
    match fs::symlink_metadata(directory) {
        Ok(metadata) if plain(&metadata) && metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid authorized key directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(directory)?;
        }
        Err(error) => return Err(error),
    }
    for (count, entry) in fs::read_dir(directory)?.enumerate() {
        if count >= 2048 {
            return Err(io::Error::other("oversized authorized key directory"));
        }
        let path = entry?.path();
        let metadata = fs::symlink_metadata(&path)?;
        if !plain(&metadata) || !metadata.is_file() {
            return Err(io::Error::other("invalid authorized key entry"));
        }
        fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{clear_keys, ensure, ready, Host};
    use crate::guest::readiness::{self, Boot, Probe};
    use std::{fs, io};

    #[derive(Default)]
    #[expect(
        clippy::struct_excessive_bools,
        reason = "independent fixture switches for each platform outcome"
    )]
    struct Fixture {
        current: bool,
        certificate: bool,
        clear_fails: bool,
        running: bool,
        events: Vec<&'static str>,
    }

    impl Host for Fixture {
        fn bootstrap_current(&self) -> bool {
            self.current
        }
        fn certificate_current(&self) -> bool {
            self.certificate
        }
        fn stop_listener(&mut self) -> io::Result<()> {
            self.events.push("stop");
            self.running = false;
            Ok(())
        }
        fn clear_keys(&mut self) -> io::Result<()> {
            self.events.push("clear");
            if self.clear_fails {
                Err(io::ErrorKind::PermissionDenied.into())
            } else {
                Ok(())
            }
        }
        fn start_listener(&mut self) -> io::Result<()> {
            self.events.push("start");
            self.running = true;
            Ok(())
        }
        fn publish_ready(&mut self) -> io::Result<()> {
            self.events.push("ready");
            self.current = true;
            Ok(())
        }
    }

    impl Probe for Fixture {
        fn ready(&mut self) -> io::Result<bool> {
            ready(self.current, self.certificate, || Ok(self.running))
        }
    }

    fn ordinary_keys(host: &mut Fixture, completed_start: bool) -> io::Result<()> {
        if !completed_start {
            host.events.push("ordinary_keys_denied");
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        host.events.push("ordinary_keys");
        Ok(())
    }

    #[test]
    fn new_boot_clears_stale_authority_before_listener_and_ordinary_keys() {
        let mut host = Fixture {
            certificate: true,
            ..Fixture::default()
        };
        let boot = Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap();
        assert!(readiness::answer(2, 2, &boot, &mut host).unwrap().is_none());
        // The production bootstrap must finish while the ordinary key route
        // still refuses the not-yet-completed start. The actual readiness
        // answer can then complete that start before the next key fetch.
        assert!(ensure(&mut host).unwrap());
        assert_eq!(
            ordinary_keys(&mut host, false).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(
            readiness::answer(2, 2, &boot, &mut host).unwrap(),
            Some(boot.response().unwrap())
        );
        ordinary_keys(&mut host, true).unwrap();
        assert_eq!(
            host.events,
            [
                "stop",
                "clear",
                "start",
                "ready",
                "ordinary_keys_denied",
                "ordinary_keys"
            ]
        );
        host.events.clear();
        assert!(ensure(&mut host).unwrap());
        assert_eq!(host.events, ["start"]);
    }

    #[test]
    fn absent_certificate_and_failed_cleanup_withhold_listener_and_receipt() {
        let mut host = Fixture::default();
        assert!(!ensure(&mut host).unwrap());
        assert_eq!(host.events, ["stop", "clear"]);
        assert!(!host.current);
        host.events.clear();
        host.certificate = true;
        host.clear_fails = true;
        assert_eq!(
            ensure(&mut host).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(host.events, ["stop", "clear"]);
        assert!(!host.current);
    }

    #[test]
    fn cleanup_removes_stale_and_partial_files_but_preserves_other_paths() {
        let root = tempfile::tempdir().unwrap();
        let keys = root.path().join("keys");
        fs::create_dir(&keys).unwrap();
        fs::write(keys.join("u200001"), b"stale-key\n").unwrap();
        fs::write(keys.join(".u200001.next"), b"partial-key\n").unwrap();
        fs::write(root.path().join("outside"), b"preserved").unwrap();
        clear_keys(&keys).unwrap();
        assert_eq!(fs::read_dir(&keys).unwrap().count(), 0);
        assert_eq!(fs::read(root.path().join("outside")).unwrap(), b"preserved");
        fs::create_dir(keys.join("unexpected")).unwrap();
        assert!(clear_keys(&keys).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_refuses_linked_directories_and_entries() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("preserved"), b"preserved").unwrap();
        let keys = root.path().join("keys");
        symlink(&target, &keys).unwrap();
        assert!(clear_keys(&keys).is_err());
        fs::remove_file(&keys).unwrap();
        fs::create_dir(&keys).unwrap();
        symlink(target.join("preserved"), keys.join("u200001")).unwrap();
        assert!(clear_keys(&keys).is_err());
        assert_eq!(fs::read(target.join("preserved")).unwrap(), b"preserved");
    }
}
