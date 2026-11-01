//! `CryptoAPI` certificate stores.

use super::error::last_error;
use super::wide;
use std::io;
use std::ptr::null_mut;
use windows_sys::Win32::Security::Cryptography::{
    CertAddEncodedCertificateToStore, CertCloseStore, CertOpenStore,
    CERT_STORE_ADD_REPLACE_EXISTING, CERT_STORE_PROV_SYSTEM_W, CERT_SYSTEM_STORE_LOCAL_MACHINE,
    HCERTSTORE, X509_ASN_ENCODING,
};

/// One open certificate store, closed exactly once on drop.
#[derive(Debug)]
pub struct CertStore(HCERTSTORE);

impl CertStore {
    /// Open the named `LocalMachine` system store, such as `Root`.
    pub fn open_local_machine(name: &str) -> io::Result<Self> {
        let name = wide(name);
        // SAFETY: the system-store provider takes the store name as a wide
        // string in `pvpara`; no legacy provider handle is used.
        let handle = unsafe {
            CertOpenStore(
                CERT_STORE_PROV_SYSTEM_W,
                0,
                0,
                CERT_SYSTEM_STORE_LOCAL_MACHINE,
                name.as_ptr().cast(),
            )
        };
        if handle.is_null() {
            return Err(last_error());
        }
        Ok(Self(handle))
    }

    /// Add one DER X.509 certificate, replacing an existing copy. `CryptoAPI`
    /// parses the DER and refuses anything that is not a certificate.
    pub fn add_der_certificate(&self, der: &[u8]) -> io::Result<()> {
        let length =
            u32::try_from(der.len()).map_err(|_| io::Error::other("oversized certificate"))?;
        // SAFETY: `der` is readable for `length` bytes; no context is requested back.
        let added = unsafe {
            CertAddEncodedCertificateToStore(
                self.0,
                X509_ASN_ENCODING,
                der.as_ptr(),
                length,
                CERT_STORE_ADD_REPLACE_EXISTING,
                null_mut(),
            )
        };
        if added == 0 {
            return Err(last_error());
        }
        Ok(())
    }
}

impl Drop for CertStore {
    fn drop(&mut self) {
        // SAFETY: the store handle is closed exactly once with no flags.
        unsafe {
            CertCloseStore(self.0, 0);
        }
    }
}
