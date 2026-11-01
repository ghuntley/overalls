//! Device signers for certificate-authenticated sessions.

use crate::adapter::RuntimeError;
use p256::ecdsa::{signature::Signer, Signature, SigningKey};

/// A signer supplied by the Linux host. Private key bytes never enter this API.
pub trait DeviceSigner: Send + Sync {
    fn public_key(&self) -> &str;
    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError>;
}

/// @cc [owner:ghuntley,label:security] linux-file-signer-custody
/// A file-backed Linux signer MUST reject symlinks and any group/world
/// permission bits before reading key material, and MUST expose only signatures
/// and the configured public key to the session boundary.
///
/// A Linux software signer backed by an owner-only raw P-256 key file.
/// Hardware-backed desktop signers can implement [`DeviceSigner`] directly;
/// this adapter exists for the Linux development and release bundle where the
/// key is provisioned outside the GTK process.
pub struct FileDeviceSigner {
    pub(super) key: SigningKey,
    public_key: String,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for FileDeviceSigner {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FileDeviceSigner")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignerError {
    Unavailable,
    InsecurePermissions,
    InvalidKey,
}

impl FileDeviceSigner {
    /// Loads exactly 32 raw key bytes and refuses symlinks or group/world access.
    pub fn load(path: &std::path::Path, public_key: String) -> Result<Self, SignerError> {
        use std::{fs, os::unix::fs::PermissionsExt};
        let metadata = fs::symlink_metadata(path).map_err(|_| SignerError::Unavailable)?;
        if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(SignerError::InsecurePermissions);
        }
        if public_key.is_empty() || public_key.len() > 1024 {
            return Err(SignerError::InvalidKey);
        }
        let bytes = fs::read(path).map_err(|_| SignerError::Unavailable)?;
        let key = SigningKey::from_slice(&bytes).map_err(|_| SignerError::InvalidKey)?;
        Ok(Self { key, public_key })
    }
}

impl DeviceSigner for FileDeviceSigner {
    fn public_key(&self) -> &str {
        &self.public_key
    }

    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError> {
        let signature: Signature = self.key.sign(message);
        let mut output = [0_u8; 64];
        output.copy_from_slice(&signature.to_bytes());
        Ok(output)
    }
}

pub(super) unsafe extern "C" fn sign_trampoline<S: DeviceSigner>(
    context: usize,
    message: *const u8,
    length: usize,
    signature: *mut u8,
) -> i32 {
    if context == 0 || message.is_null() || signature.is_null() || length == 0 || length > 65_536 {
        return -1;
    }
    // SAFETY: `mila_session_connect` invokes this callback synchronously with
    // the non-zero context it was given, which is a live `&S` borrowed for the
    // whole connect call.
    let signer = unsafe { &*(context as *const S) };
    // SAFETY: the caller promises `message` is non-null (checked above) and
    // valid for `length` readable bytes for the duration of the callback.
    let message = unsafe { std::slice::from_raw_parts(message, length) };
    let Ok(value) = signer.sign(message) else {
        return -1;
    };
    // SAFETY: the caller promises `signature` is non-null (checked above) and
    // points to a writable 64-byte buffer that does not alias `message`.
    unsafe { std::slice::from_raw_parts_mut(signature, 64) }.copy_from_slice(&value);
    0
}
