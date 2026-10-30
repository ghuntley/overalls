use crate::RuntimeError;

/// Platform custody selected by the native wrapper; private key bytes never
/// cross this boundary. The associated handle is intentionally opaque.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyCustody {
    SecureEnclave,
    StrongBox,
    PlatformKeystore,
    OwnerOnlyFile,
}
pub trait DeviceKeyProvider {
    type Handle;
    fn custody(&self) -> KeyCustody;
    fn key_for(&self, deployment: &str) -> Result<Self::Handle, RuntimeError>;
}
