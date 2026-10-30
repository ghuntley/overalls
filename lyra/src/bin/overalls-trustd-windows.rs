//! Windows guest trust daemon (ADR-0171, gate 2): the counterpart of the Linux
//! `overalls-trustd`.
//!
//! Lilly dials vsock port 1030 once per boot with the public CA roots the
//! platform's private services use. The daemon validates the request against
//! this boot (MMDS identity plus the volatile boot UUID), installs the roots
//! into `LocalMachine\Root` through `CryptoAPI` so Schannel clients trust them,
//! writes the PEM bundle Git and the agents' HTTP clients read
//! (`C:\overalls\trust\bundle-<digest>\ca-bundle.pem`, named by
//! `C:\overalls\trust\current`), and only then answers with the `installed`
//! receipt. A refused or failed installation answers nothing. Runs as a SYSTEM
//! task; exits 64 on other operating systems.

#[cfg(windows)]
mod daemon {
    use lyra::guest::mmds;
    use lyra::guest::readiness::Boot;
    use lyra::guest::trust::{self, Request};
    use lyra::platform::windows::log::Logger;
    use lyra::platform::windows::vsock::{self, Connection, Listener};
    use lyra::platform::windows::{boot_id, trust_store};
    use std::fs::{self, File};
    use std::io::{self, Write};
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    const IDENTITY_BUDGET: Duration = Duration::from_mins(10);
    const TRUST_DIR: &str = "C:\\overalls\\trust";
    const BASE_BUNDLE: &str = "C:\\overalls\\trust\\base-ca-bundle.pem";

    fn identity() -> io::Result<Boot> {
        let started = Instant::now();
        let document = loop {
            match mmds::fetch(Duration::from_secs(5)) {
                Ok(document) => break document,
                Err(_) if started.elapsed() < IDENTITY_BUDGET => {
                    std::thread::sleep(Duration::from_secs(2));
                }
                Err(error) => return Err(error),
            }
        };
        Boot::new(
            document.placement,
            document.execution_epoch,
            document.boot_challenge,
            boot_id::boot_id()?,
        )
    }

    fn write_sync(path: &Path, bytes: &[u8]) -> io::Result<()> {
        let mut file = File::create(path)?;
        file.write_all(bytes)?;
        file.sync_all()
    }

    /// @cc [owner:ghuntley,label:security;recovery] windows-trust-bundle-published-once
    /// The PEM bundle for a digest MUST be written whole under a staging name and
    /// renamed into `bundle-<digest>` before `current` names it; an existing
    /// bundle for the same digest MUST be byte-identical or the installation
    /// fails; `current` is replaced atomically and never points at a partial bundle.
    fn publish_bundle(request: &Request) -> io::Result<()> {
        let directory = Path::new(TRUST_DIR);
        fs::create_dir_all(directory)?;
        let base = fs::read(BASE_BUNDLE)?;
        let bytes = trust::bundle(&base, &request.roots)?;
        let name = format!("bundle-{}", request.bundle_digest);
        let destination: PathBuf = directory.join(&name);
        let bundle_path = destination.join("ca-bundle.pem");
        if destination.exists() {
            if fs::read(&bundle_path)? != bytes {
                return Err(io::Error::other("trust bundle conflict"));
            }
        } else {
            let staging = directory.join(format!(".{name}.next"));
            if staging.exists() {
                fs::remove_dir_all(&staging)?;
            }
            fs::create_dir_all(&staging)?;
            write_sync(&staging.join("ca-bundle.pem"), &bytes)?;
            fs::rename(&staging, &destination)?;
        }
        let pointer = directory.join("current.next");
        write_sync(&pointer, name.as_bytes())?;
        fs::rename(&pointer, directory.join("current"))?;
        Ok(())
    }

    /// @cc [owner:ghuntley,label:security] windows-trust-install-before-receipt
    /// A receipt MUST follow a successful root-store installation and bundle
    /// publication of a validated host request for this exact boot; any
    /// failure, another peer or an invalid request answers nothing.
    fn serve_one(connection: &mut Connection, boot: &Boot, logger: &Logger) -> io::Result<()> {
        if !connection.from_host() {
            return Err(io::Error::other("peer is not the host"));
        }
        let request = trust::read_frame(connection)?;
        let ders = trust::validate(&request, boot)?;
        trust_store::install_roots(&ders)?;
        publish_bundle(&request)?;
        logger.log(&format!("installed roots={}", ders.len()));
        trust::write_frame(connection, &trust::receipt(&request, boot))
    }

    pub(crate) fn run() -> i32 {
        let logger = Logger::new("trustd");
        logger.log("start");
        if vsock::startup().is_err() {
            logger.log("winsock_unavailable");
            logger.publish();
            return 1;
        }
        let boot = match identity() {
            Ok(boot) => boot,
            Err(error) => {
                logger.log(&format!("identity_unavailable kind={:?}", error.kind()));
                logger.publish();
                return 2;
            }
        };
        logger.log("identity_bound");
        let Ok(family) = vsock::discover(IDENTITY_BUDGET, |_| {}) else {
            logger.log("vsock_unavailable");
            logger.publish();
            return 3;
        };
        let listener = match Listener::bind(family, trust::PORT, 1) {
            Ok(listener) => listener,
            Err(error) => {
                logger.log(&format!(
                    "bind_failed code={}",
                    error.raw_os_error().unwrap_or(0)
                ));
                logger.publish();
                return 4;
            }
        };
        logger.log(&format!("listening port={}", trust::PORT));
        logger.publish();
        loop {
            let Ok(mut connection) = listener.accept(Duration::from_secs(10)) else {
                std::thread::sleep(Duration::from_millis(200));
                continue;
            };
            match serve_one(&mut connection, &boot, &logger) {
                Ok(()) => {
                    logger.log("receipt_sent");
                    logger.publish();
                }
                Err(error) => {
                    logger.log(&format!("request_refused kind={:?}", error.kind()));
                }
            }
        }
    }
}

#[cfg(windows)]
fn main() {
    std::process::exit(daemon::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-trustd-windows runs inside Windows guests only");
    std::process::exit(64);
}
