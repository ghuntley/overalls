//! Owner-only Linux device key used to authenticate SSH sessions.
//!
//! The key is a raw P-256 scalar in an owner-only file under the user's data
//! directory. It is created once on first sign-in and then only read; the
//! GTK process never displays or exports private material, only the OpenSSH
//! public line (sent to the deployment) and its `SHA256:` fingerprint (shown
//! for approval comparison and used to mark this device's key in settings).

use crate::session::FileDeviceSigner;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// Why the device key could not be opened. No path or key bytes are carried.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeviceKeyError {
    Unavailable,
    InsecurePermissions,
    InvalidKey,
}

/// A loaded device key: the signer and its public identity.
pub struct DeviceKey {
    pub signer: FileDeviceSigner,
    pub fingerprint: String,
}

impl std::fmt::Debug for DeviceKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DeviceKey")
            .field("fingerprint", &self.fingerprint)
            .finish_non_exhaustive()
    }
}

/// `$MILA_DEVICE_KEY_PATH`, else `$XDG_DATA_HOME/mila/device-key`, else
/// `$HOME/.local/share/mila/device-key`.
pub fn default_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("MILA_DEVICE_KEY_PATH") {
        return Some(PathBuf::from(path));
    }
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .map(|root| root.join("mila").join("device-key"))
}

/// OpenSSH `ecdsa-sha2-nistp256` public key line and `SHA256:` fingerprint.
pub fn openssh_identity(key: &p256::ecdsa::SigningKey) -> (String, String) {
    use base64::Engine;
    use sha2::Digest;
    let point = key.verifying_key().to_encoded_point(false);
    let mut blob = Vec::new();
    for field in [
        b"ecdsa-sha2-nistp256".as_slice(),
        b"nistp256",
        point.as_bytes(),
    ] {
        // Every field is far below u32::MAX bytes.
        #[expect(
            clippy::cast_possible_truncation,
            reason = "fields are a 19-byte name, an 8-byte curve and a 65-byte SEC1 point"
        )]
        blob.extend_from_slice(&(field.len() as u32).to_be_bytes());
        blob.extend_from_slice(field);
    }
    let public = format!(
        "ecdsa-sha2-nistp256 {}",
        base64::engine::general_purpose::STANDARD.encode(&blob)
    );
    let fingerprint = format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(sha2::Sha256::digest(&blob))
    );
    (public, fingerprint)
}

/// Creates `path` exclusively with mode 0600 and writes `bytes`.
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn read_scalar(path: &Path) -> Result<p256::ecdsa::SigningKey, DeviceKeyError> {
    use std::os::unix::fs::PermissionsExt;
    let metadata = std::fs::symlink_metadata(path).map_err(|_| DeviceKeyError::Unavailable)?;
    if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o077 != 0 {
        return Err(DeviceKeyError::InsecurePermissions);
    }
    if metadata.len() != 32 {
        return Err(DeviceKeyError::InvalidKey);
    }
    let bytes = std::fs::read(path).map_err(|_| DeviceKeyError::Unavailable)?;
    p256::ecdsa::SigningKey::from_slice(&bytes).map_err(|_| DeviceKeyError::InvalidKey)
}

fn generate(path: &Path) -> Result<(), DeviceKeyError> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|_| DeviceKeyError::Unavailable)?;
        let mode = std::fs::metadata(parent)
            .map_err(|_| DeviceKeyError::Unavailable)?
            .permissions()
            .mode();
        if mode & 0o022 != 0 {
            return Err(DeviceKeyError::InsecurePermissions);
        }
    }
    let mut source =
        std::fs::File::open("/dev/urandom").map_err(|_| DeviceKeyError::Unavailable)?;
    for _ in 0..8 {
        let mut bytes = [0_u8; 32];
        source
            .read_exact(&mut bytes)
            .map_err(|_| DeviceKeyError::Unavailable)?;
        if p256::ecdsa::SigningKey::from_slice(&bytes).is_err() {
            continue;
        }
        return match write_private(path, &bytes) {
            Ok(()) => Ok(()),
            // Another process created the key first; use theirs.
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(_) => Err(DeviceKeyError::Unavailable),
        };
    }
    Err(DeviceKeyError::Unavailable)
}

/// @cc [owner:ghuntley,label:security] linux-device-key-owner-only
/// The device key MUST be created exclusively with mode 0600 in a directory
/// not writable by group or others, MUST be refused when it is a symlink, has
/// group/world permission bits or is not exactly 32 bytes, and an existing key
/// MUST never be overwritten. Only the public line and fingerprint leave this
/// module.
///
/// Opens the device key at `path`, creating it on first use.
pub fn load_or_create(path: &Path) -> Result<DeviceKey, DeviceKeyError> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => generate(path)?,
        Err(_) => return Err(DeviceKeyError::Unavailable),
    }
    let key = read_scalar(path)?;
    let (public, fingerprint) = openssh_identity(&key);
    let signer = FileDeviceSigner::load(path, public).map_err(|error| match error {
        crate::session::SignerError::Unavailable => DeviceKeyError::Unavailable,
        crate::session::SignerError::InsecurePermissions => DeviceKeyError::InsecurePermissions,
        crate::session::SignerError::InvalidKey => DeviceKeyError::InvalidKey,
    })?;
    Ok(DeviceKey {
        signer,
        fingerprint,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::DeviceSigner;
    use std::os::unix::fs::PermissionsExt;

    fn scratch(name: &str) -> PathBuf {
        let mut suffix = [0_u8; 8];
        std::fs::File::open("/dev/urandom")
            .unwrap()
            .read_exact(&mut suffix)
            .unwrap();
        let path = std::env::temp_dir().join(format!(
            "mila-device-key-{name}-{:016x}",
            u64::from_le_bytes(suffix)
        ));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[test]
    fn creates_once_and_reloads_the_same_identity() {
        let dir = scratch("reload");
        let path = dir.join("nested").join("device-key");
        let first = load_or_create(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let second = load_or_create(&path).unwrap();
        assert_eq!(first.fingerprint, second.fingerprint);
        assert_eq!(first.signer.public_key(), second.signer.public_key());
        assert!(first.fingerprint.starts_with("SHA256:"));
        assert!(!format!("{first:?}").contains(first.signer.public_key()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refuses_shared_symlinked_or_malformed_keys() {
        let dir = scratch("refuse");
        let path = dir.join("device-key");
        load_or_create(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        assert_eq!(
            load_or_create(&path).unwrap_err(),
            DeviceKeyError::InsecurePermissions
        );
        let link = dir.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert_eq!(
            load_or_create(&link).unwrap_err(),
            DeviceKeyError::InsecurePermissions
        );
        let short = dir.join("short");
        write_private(&short, &[1; 31]).unwrap();
        assert_eq!(
            load_or_create(&short).unwrap_err(),
            DeviceKeyError::InvalidKey
        );
        let zero = dir.join("zero");
        write_private(&zero, &[0; 32]).unwrap();
        assert_eq!(
            load_or_create(&zero).unwrap_err(),
            DeviceKeyError::InvalidKey
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn openssh_identity_matches_wire_format() {
        let key = p256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
        let (public, fingerprint) = openssh_identity(&key);
        assert!(public.starts_with("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY"));
        assert!(fingerprint.starts_with("SHA256:"));
        assert_eq!(fingerprint.len(), 7 + 43);
    }
}
