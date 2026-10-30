//! The machine's trusted root store through `CryptoAPI` (ADR-0171).
//!
//! Lilly's delivered public CA roots become trusted for every Windows TLS
//! client (Schannel) by entering `LocalMachine\Root`. `CryptoAPI` parses the DER
//! itself and refuses anything that is not a certificate, so the store add is
//! also the validation.

use super::{last_error, wide};
use std::io;
use std::ptr::null_mut;
use windows_sys::Win32::Security::Cryptography::{
    CertAddEncodedCertificateToStore, CertCloseStore, CertOpenStore,
    CERT_STORE_ADD_REPLACE_EXISTING, CERT_STORE_PROV_SYSTEM_W, CERT_SYSTEM_STORE_LOCAL_MACHINE,
    HCERTSTORE, X509_ASN_ENCODING,
};

struct Store(HCERTSTORE);

impl Store {
    fn open_machine_root() -> io::Result<Self> {
        let name = wide("Root");
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
}

impl Drop for Store {
    fn drop(&mut self) {
        // SAFETY: the store handle is closed exactly once with no flags.
        unsafe {
            CertCloseStore(self.0, 0);
        }
    }
}

/// @cc [owner:ghuntley,label:security] windows-root-store-der-only
/// `install_roots` MUST add each DER certificate to `LocalMachine\Root` and MUST
/// fail on the first certificate `CryptoAPI` refuses, leaving the caller to
/// withhold its receipt; it adds nothing else and never removes a root.
pub fn install_roots(certificates: &[Vec<u8>]) -> io::Result<()> {
    let store = Store::open_machine_root()?;
    for der in certificates {
        let length =
            u32::try_from(der.len()).map_err(|_| io::Error::other("oversized certificate"))?;
        // SAFETY: `der` is readable for `length` bytes; no context is requested back.
        let added = unsafe {
            CertAddEncodedCertificateToStore(
                store.0,
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
    }
    Ok(())
}
