//! Device-key primitives. Private material never leaves this crate's typed API.

use p256::ecdsa::{
    signature::{Signer, Verifier},
    Signature, SigningKey, VerifyingKey,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// A P-256 device key backed by a caller-owned key provider.
#[derive(Clone)]
pub struct DeviceKey(SigningKey);

/// Formats only the type name; the private scalar is never printed.
impl std::fmt::Debug for DeviceKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("DeviceKey").finish_non_exhaustive()
    }
}

impl DeviceKey {
    /// @cc [owner:ghuntley,label:security] mila-crypto-device-key-custody
    /// Creates a key from exactly 32 bytes supplied by a platform key provider.
    ///
    /// This API MUST accept private material only as an explicit provider input and
    /// MUST never expose or log the private scalar; callers retain custody of it.
    pub fn from_seed(seed: [u8; 32]) -> Result<Self, CryptoError> {
        SigningKey::from_bytes((&seed).into())
            .map(Self)
            .map_err(|_| CryptoError::InvalidKey)
    }

    /// Returns the compressed SEC1 public point for registration.
    pub fn public_key_sec1(&self) -> [u8; 33] {
        let encoded = self.0.verifying_key().to_encoded_point(true);
        let mut output = [0u8; 33];
        output.copy_from_slice(encoded.as_bytes());
        output
    }

    /// Signs a message and returns DER-encoded ECDSA bytes.
    pub fn sign(&self, message: &[u8]) -> Vec<u8> {
        let signature: Signature = self.0.sign(message);
        signature.to_der().as_bytes().to_vec()
    }

    /// Verifies a signature against this key's public point.
    pub fn verify(&self, message: &[u8], signature: &[u8]) -> bool {
        Signature::from_der(signature)
            .is_ok_and(|signature| self.0.verifying_key().verify(message, &signature).is_ok())
    }
}

/// Verifies a DER signature against a compressed SEC1 P-256 point.
pub fn verify_public_key(
    public_key: &[u8],
    message: &[u8],
    signature: &[u8],
) -> Result<bool, CryptoError> {
    let verifying_key =
        VerifyingKey::from_sec1_bytes(public_key).map_err(|_| CryptoError::InvalidKey)?;
    let signature = Signature::from_der(signature).map_err(|_| CryptoError::InvalidSignature)?;
    Ok(verifying_key.verify(message, &signature).is_ok())
}

/// Hashes bytes for stable fixture fingerprints.
pub fn sha256(value: &[u8]) -> [u8; 32] {
    let digest = Sha256::digest(value);
    digest.into()
}

/// Fail-closed key and signature errors.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CryptoError {
    #[error("invalid P-256 key")]
    InvalidKey,
    #[error("invalid ECDSA signature")]
    InvalidSignature,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_signatures_round_trip() {
        let key = DeviceKey::from_seed([7; 32]).expect("valid test key");
        let signature = key.sign(b"mila");
        assert!(key.verify(b"mila", &signature));
        assert!(!key.verify(b"changed", &signature));
        assert!(
            verify_public_key(&key.public_key_sec1(), b"mila", &signature).expect("valid point")
        );
    }
}
