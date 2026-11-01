//! Deployment trust storage, fetching and enrollment.

use super::{validate_session_endpoint, MAX_TRUST_BYTES};
use crate::adapter::RuntimeError;
use mila_ffi::{MilaFfiStatus, MilaRouteOutput};
use std::fmt::Write as _;

/// Storage used by enrollment. Implementations must use owner-only, atomic files.
pub trait TrustStore {
    fn read(&self, host: &str) -> Result<Option<Vec<u8>>, RuntimeError>;
    fn write(&self, host: &str, document: &[u8]) -> Result<(), RuntimeError>;
}

/// Owner-only trust store used by the GTK host. Files are keyed by a reversible
/// hexadecimal encoding of the authority, so deployment input can never become
/// a path component or traversal sequence.
#[derive(Clone, Debug, Default)]
pub struct XdgTrustStore;

impl XdgTrustStore {
    fn path(host: &str) -> Result<std::path::PathBuf, RuntimeError> {
        validate_session_endpoint(host, 443, 1_000)?;
        let root = std::env::var_os("XDG_CONFIG_HOME")
            .map(std::path::PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(".config"))
            })
            .ok_or(RuntimeError::Unavailable)?;
        let mut key = String::with_capacity(host.len() * 2);
        for byte in host.bytes() {
            write!(key, "{byte:02x}").map_err(|_| RuntimeError::Unavailable)?;
        }
        Ok(root.join("mila").join("trust").join(key))
    }
}

impl TrustStore for XdgTrustStore {
    fn read(&self, host: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
        let path = Self::path(host)?;
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(RuntimeError::Unavailable),
        };
        if !metadata.file_type().is_file() {
            return Err(RuntimeError::InvalidInput);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if metadata.permissions().mode() & 0o077 != 0 {
                return Err(RuntimeError::InvalidInput);
            }
        }
        let bytes = std::fs::read(path).map_err(|_| RuntimeError::Unavailable)?;
        if bytes.is_empty() || bytes.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(Some(bytes))
    }

    fn write(&self, host: &str, document: &[u8]) -> Result<(), RuntimeError> {
        if document.is_empty() || document.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        let path = Self::path(host)?;
        let parent = path.parent().ok_or(RuntimeError::Unavailable)?;
        std::fs::create_dir_all(parent).map_err(|_| RuntimeError::Unavailable)?;
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, document).map_err(|_| RuntimeError::Unavailable)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| RuntimeError::Unavailable)?;
        }
        std::fs::rename(temporary, path).map_err(|_| RuntimeError::Unavailable)
    }
}

/// Fetches `/bin/ssh-trust.json` over HTTPS with redirects refused.
pub trait TrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError>;
}

/// Production Linux HTTPS trust fetcher.  `curl` is used from the host image so
/// certificate validation, proxy policy, and CA updates remain owned by the
/// distribution.  Redirects are explicitly disabled: a deployment authority
/// may only serve its trust document from its own HTTPS origin.
#[derive(Clone, Copy, Debug, Default)]
pub struct CurlTrustFetcher {
    pub timeout_seconds: u32,
}

impl TrustFetcher for CurlTrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError> {
        if host.contains(['/', '?', '#', ':']) {
            return Err(RuntimeError::InvalidInput);
        }
        validate_session_endpoint(
            host,
            443,
            self.timeout_seconds.saturating_mul(1_000).max(1_000),
        )?;
        let timeout = self.timeout_seconds.clamp(1, 120);
        let url = format!("https://{host}/bin/ssh-trust.json");
        let output = std::process::Command::new("curl")
            .args([
                "--fail",
                "--silent",
                "--show-error",
                "--proto",
                "=https",
                "--max-redirs",
                "0",
                "--max-time",
                &timeout.to_string(),
                &url,
            ])
            .output()
            .map_err(|_| RuntimeError::Unavailable)?;
        if !output.status.success() {
            return Err(RuntimeError::Unavailable);
        }
        if output.stdout.is_empty() || output.stdout.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(output.stdout)
    }
}

/// HTTPS trust fetch for a deployment on an explicit port, optionally with a
/// private CA bundle (connection profiles and the hermetic fixture).
/// Redirects are refused and only `https` is allowed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpsTrustFetcher {
    pub ca_path: Option<std::path::PathBuf>,
    pub server_name: String,
    pub host: String,
    pub https_port: u16,
}

impl HttpsTrustFetcher {
    /// curl arguments; contains no credential.
    pub fn arguments(&self) -> Vec<String> {
        let port = self.https_port;
        let mut arguments = [
            "--fail",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--max-redirs",
            "0",
            "--max-time",
            "20",
        ]
        .map(str::to_owned)
        .to_vec();
        if let Some(ca_path) = &self.ca_path {
            arguments.push("--cacert".to_owned());
            arguments.push(ca_path.display().to_string());
        }
        if self.server_name != self.host {
            arguments.push("--connect-to".to_owned());
            arguments.push(format!("{}:{port}:{}:{port}", self.server_name, self.host));
        }
        arguments.push(format!(
            "https://{}:{port}/bin/ssh-trust.json",
            self.server_name
        ));
        arguments
    }
}

impl TrustFetcher for HttpsTrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError> {
        if host != self.host || self.https_port == 0 {
            return Err(RuntimeError::InvalidInput);
        }
        let output = std::process::Command::new("curl")
            .args(self.arguments())
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|_| RuntimeError::Unavailable)?;
        if !output.status.success() {
            return Err(RuntimeError::Unavailable);
        }
        if output.stdout.is_empty() || output.stdout.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(output.stdout)
    }
}

/// Rust-owned trust enrollment. Only canonical bytes selected by the FFI are persisted.
pub struct TrustEnrollment<S, F> {
    pub store: S,
    pub fetcher: F,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl<S, F> std::fmt::Debug for TrustEnrollment<S, F> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TrustEnrollment")
            .finish_non_exhaustive()
    }
}

impl<S: TrustStore, F: TrustFetcher> TrustEnrollment<S, F> {
    /// @cc [owner:ghuntley,label:security] linux-trust-enrollment-order
    /// Enrollment MUST reconcile fetched and pinned documents in Rust and persist
    /// only the canonical result. A failed fetch may use a current pin; malformed
    /// or conflicting fetched bytes MUST fail closed. Only an unavailable HTTPS
    /// transport may fall back to a current pin; fetch validation errors MUST
    /// be returned.
    pub fn resolve(&self, host: &str, now: u64) -> Result<Vec<u8>, RuntimeError> {
        let pinned = self.store.read(host)?;
        let fetched = match self.fetcher.fetch(host) {
            Ok(document) => Some(document),
            Err(RuntimeError::Unavailable) => None,
            Err(RuntimeError::InvalidInput) => return Err(RuntimeError::InvalidInput),
        };
        let mut output = vec![0_u8; MAX_TRUST_BYTES];
        let mut written = 0_usize;
        let origin = std::ffi::CString::new(host).map_err(|_| RuntimeError::InvalidInput)?;
        // SAFETY: the optional documents are live Rust slices or null with length
        // zero, `origin` is NUL-terminated, and `output`/`written` are writable
        // locals of the declared capacity that outlive this synchronous call.
        let status = unsafe {
            mila_ffi::mila_trust_document_reconcile(
                pinned.as_deref().map_or(std::ptr::null(), <[u8]>::as_ptr),
                pinned.as_ref().map_or(0, Vec::len),
                fetched.as_deref().map_or(std::ptr::null(), <[u8]>::as_ptr),
                fetched.as_ref().map_or(0, Vec::len),
                origin.as_ptr(),
                now,
                MilaRouteOutput {
                    bytes: output.as_mut_ptr(),
                    capacity: output.len(),
                    written: &raw mut written,
                },
            )
        };
        if status != MilaFfiStatus::Ok || written == 0 || written > output.len() {
            return Err(RuntimeError::InvalidInput);
        }
        output.truncate(written);
        if pinned.as_deref() != Some(output.as_slice()) {
            self.store.write(host, &output)?;
        }
        Ok(output)
    }
}
