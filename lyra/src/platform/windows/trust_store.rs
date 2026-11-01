//! The machine's trusted root store through `CryptoAPI` (ADR-0171).
//!
//! Lilly's delivered public CA roots become trusted for every Windows TLS
//! client (Schannel) by entering `LocalMachine\Root`. `CryptoAPI` parses the DER
//! itself and refuses anything that is not a certificate, so the store add is
//! also the validation.

use crate::sys::windows::trust::CertStore;
use std::io;

/// @cc [owner:ghuntley,label:security] windows-root-store-der-only
/// `install_roots` MUST add each DER certificate to `LocalMachine\Root` and MUST
/// fail on the first certificate `CryptoAPI` refuses, leaving the caller to
/// withhold its receipt; it adds nothing else and never removes a root.
pub fn install_roots(certificates: &[Vec<u8>]) -> io::Result<()> {
    let store = CertStore::open_local_machine("Root")?;
    for der in certificates {
        store.add_der_certificate(der)?;
    }
    Ok(())
}
