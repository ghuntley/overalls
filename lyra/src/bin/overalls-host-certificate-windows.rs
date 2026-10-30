//! Windows guest SSH host certificate agent (ADR-0171, gate 3): the counterpart
//! of the Linux `overalls-host-certificate` guest mode.
//!
//! Each boot gets a fresh ed25519 host key (old material is deleted first) in
//! Win32-OpenSSH's `%ProgramData%\ssh`, asks Audi's private route for a host
//! certificate, verifies the issued certificate against its CA and principal
//! with the shared rules, installs it beside the key and restarts `sshd` when
//! it is running so the new identity is served. It then renews within the
//! shared renewal window once an hour. Runs as a SYSTEM task; exits 64 on
//! other operating systems.

#[cfg(windows)]
mod agent {
    use lyra::guest::ssh_bootstrap;
    use lyra::platform::windows::boot_id;
    use lyra::platform::windows::log::Logger;
    use lyra::platform::windows::services;
    use lyra::private_http;
    use lyra::ssh_certificate::{self, Issued, RENEWAL_WINDOW};
    use lyra::ssh_files;
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    const TRUST_DIR: &str = "C:\\overalls\\trust";
    const ROUTE: &str = "https://ssh.integration.internal/ssh/v1/host-certificate";

    fn now() -> io::Result<u64> {
        Ok(SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ssh_certificate::invalid())?
            .as_secs())
    }

    fn program_data() -> PathBuf {
        PathBuf::from(std::env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into()))
    }

    fn keygen() -> PathBuf {
        let system = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        Path::new(&system)
            .join("System32")
            .join("OpenSSH")
            .join("ssh-keygen.exe")
    }

    fn bundle_path() -> Option<String> {
        let current = fs::read_to_string(Path::new(TRUST_DIR).join("current")).ok()?;
        let name = current.trim();
        if name.is_empty() || name.contains(['\\', '/', ':']) {
            return None;
        }
        Some(format!("{TRUST_DIR}\\{name}\\ca-bundle.pem"))
    }

    /// @cc [owner:ghuntley,label:security] windows-host-key-per-boot
    /// The boot's host key MUST be generated fresh after deleting the previous
    /// key, public key and certificate, with the in-box ssh-keygen and an empty
    /// passphrase, so a certificate never outlives the boot it was issued for.
    fn fresh_key(directory: &Path) -> io::Result<String> {
        let private = directory.join("ssh_host_ed25519_key");
        for stale in [
            private.clone(),
            directory.join("ssh_host_ed25519_key.pub"),
            directory.join("ssh_host_ed25519_key-cert.pub"),
            directory.join("certificate.json"),
        ] {
            match fs::remove_file(&stale) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        let status = Command::new(keygen())
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
            .arg(&private)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if !status.success() {
            return Err(ssh_certificate::invalid());
        }
        let output = Command::new(keygen())
            .args(["-y", "-f"])
            .arg(&private)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()?;
        if !output.status.success() || output.stdout.len() > 4096 {
            return Err(ssh_certificate::invalid());
        }
        let public = String::from_utf8(output.stdout)
            .map_err(|_| ssh_certificate::invalid())?
            .split_whitespace()
            .take(2)
            .collect::<Vec<_>>()
            .join(" ");
        ssh_certificate::public_key(&public)?;
        Ok(public)
    }

    fn current(directory: &Path, key: &str, time: u64) -> bool {
        (|| -> io::Result<bool> {
            let value: Issued = serde_json::from_slice(&ssh_files::read(
                &directory.join("certificate.json"),
                20_000,
            )?)?;
            let line = String::from_utf8(ssh_files::read(
                &directory.join("ssh_host_ed25519_key-cert.pub"),
                16_384,
            )?)
            .map_err(|_| ssh_certificate::invalid())?;
            if value.version != 1 || value.certificate != line {
                return Err(ssh_certificate::invalid());
            }
            let cert = ssh_certificate::verify(&line, &value.ca, key, &value.principal, time)?;
            Ok(cert.valid_before() > time + RENEWAL_WINDOW)
        })()
        .unwrap_or(false)
    }

    /// @cc [owner:ghuntley,label:security;recovery] windows-host-certificate-verified-install
    /// An issued certificate MUST verify against its CA, this boot's key and its
    /// principal before it replaces the installed one, and sshd MUST be restarted
    /// only after both files are written whole.
    fn renew(directory: &Path, key: &str) -> io::Result<()> {
        let client = private_http::client()?;
        let response = client
            .post(ROUTE)
            .header("content-type", "application/json")
            .body(serde_json::to_vec(
                &serde_json::json!({ "public_key": key }),
            )?)
            .send()
            .map_err(|_| ssh_certificate::invalid())?;
        if !response.status().is_success() {
            return Err(ssh_certificate::invalid());
        }
        let body = private_http::read_bounded(response, 20_000)?;
        let issued: Issued = serde_json::from_slice(&body)?;
        if issued.version != 1 {
            return Err(ssh_certificate::invalid());
        }
        ssh_certificate::verify(
            &issued.certificate,
            &issued.ca,
            key,
            &issued.principal,
            now()?,
        )?;
        ssh_files::atomic(
            &directory.join("ssh_host_ed25519_key-cert.pub"),
            issued.certificate.as_bytes(),
        )?;
        ssh_files::atomic(
            &directory.join("certificate.json"),
            &serde_json::to_vec(&issued)?,
        )?;
        restart_sshd_if_running()?;
        boot_id::write_marker(Path::new(ssh_bootstrap::CERTIFICATE_READY))
    }

    fn restart_sshd_if_running() -> io::Result<()> {
        if !services::running("sshd")? {
            return Ok(());
        }
        let system = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        let sc = Path::new(&system).join("System32").join("sc.exe");
        for action in ["stop", "start"] {
            let _ = Command::new(&sc)
                .args([action, "sshd"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;
            let started = Instant::now();
            loop {
                let settled = if action == "stop" {
                    services::stopped("sshd")?
                } else {
                    services::running("sshd")?
                };
                if settled {
                    break;
                }
                if started.elapsed() >= Duration::from_secs(10) {
                    return Err(io::Error::other("sshd transition failed"));
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        Ok(())
    }

    pub(crate) fn run() -> i32 {
        let logger = Logger::new("host-certificate");
        logger.log("start");
        let directory = program_data().join("ssh");
        if let Err(error) = fs::create_dir_all(&directory) {
            logger.log(&format!("key_dir_unavailable kind={:?}", error.kind()));
            return 1;
        }
        // A same-boot task restart also replaces the host key. Its previous
        // installation receipt must not authorize the replacement prematurely.
        match fs::remove_file(ssh_bootstrap::CERTIFICATE_READY) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => {
                logger.log("certificate_receipt_unavailable");
                return 2;
            }
        }
        if fs::create_dir_all("C:\\overalls\\run").is_err() {
            logger.log("certificate_receipt_unavailable");
            return 2;
        }
        let key = match fresh_key(&directory) {
            Ok(key) => key,
            Err(error) => {
                logger.log(&format!("host_key_failed kind={:?}", error.kind()));
                logger.publish();
                return 2;
            }
        };
        logger.log("host_key_generated");
        let mut installed = false;
        loop {
            if let Some(bundle) = bundle_path() {
                std::env::set_var("OVERALLS_SSH_CA_BUNDLE", &bundle);
            } else {
                std::thread::sleep(Duration::from_secs(5));
                continue;
            }
            let time = now().unwrap_or(0);
            if current(&directory, &key, time) {
                if !boot_id::marker_is_current(Path::new(ssh_bootstrap::CERTIFICATE_READY)) {
                    let receipt = restart_sshd_if_running().and_then(|()| {
                        boot_id::write_marker(Path::new(ssh_bootstrap::CERTIFICATE_READY))
                    });
                    if receipt.is_err() {
                        logger.log("certificate_receipt_unavailable");
                        std::thread::sleep(Duration::from_secs(10));
                        continue;
                    }
                }
                std::thread::sleep(Duration::from_hours(1));
                continue;
            }
            if renew(&directory, &key).is_ok() {
                if installed {
                    logger.log("certificate_renewed");
                } else {
                    installed = true;
                    logger.log("certificate_installed");
                    logger.publish();
                }
                std::thread::sleep(Duration::from_hours(1));
            } else {
                logger.log("certificate_unavailable");
                std::thread::sleep(Duration::from_secs(if installed { 600 } else { 10 }));
            }
        }
    }
}

#[cfg(windows)]
fn main() {
    std::process::exit(agent::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-host-certificate-windows runs inside Windows guests only");
    std::process::exit(64);
}
