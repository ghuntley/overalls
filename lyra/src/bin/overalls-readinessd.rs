//! Windows guest boot readiness daemon (ADR-0171, gate 2).
//!
//! The Windows counterpart of the Linux `lilly-readiness` service: it binds
//! this boot's identity from MMDS and the volatile boot UUID, listens on vsock
//! port 1024 and answers Lilly's poll with the closed six-key `ready` line only
//! when the live probes pass: the delivered `/32` and routes are configured,
//! every required service is RUNNING, the SSH agent has published this boot's
//! `ssh-ready` marker, `sshd` is RUNNING, and `C:` accepts a durable write. It has
//! no execution, transfer or cleanup authority and ingests nothing from the
//! peer. Runs as a SYSTEM task; exits 64 on other operating systems.

#[cfg(any(windows, test))]
use lyra::guest::ssh_bootstrap::ready as ssh_bootstrap_ready;

#[cfg(windows)]
mod daemon {
    use super::ssh_bootstrap_ready;
    use lyra::guest::readiness::{self, Boot, Probe};
    use lyra::guest::{mmds, ssh_bootstrap};
    use lyra::platform::windows::log::Logger;
    use lyra::platform::windows::vsock::{self, Listener, HOST_CID};
    use lyra::platform::windows::{boot_id, net, services};
    use std::fs::{self, OpenOptions};
    use std::io::{self, Write};
    use std::net::Ipv4Addr;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    const IDENTITY_BUDGET: Duration = Duration::from_mins(10);
    const RUN_DIR: &str = "C:\\overalls\\run";
    const SSHD: &str = "sshd";
    /// Services that must be RUNNING before the guest is ready, besides sshd:
    /// the network store and the TCP/IP stack. The DHCP client is not required
    /// because the bootstrap task configures the address statically.
    const REQUIRED: &[&str] = &["nsi", "Tcpip"];

    struct Live {
        address: Ipv4Addr,
        gateway: Ipv4Addr,
        logger: Logger,
    }

    impl Live {
        /// @cc [owner:ghuntley,label:recovery] windows-readiness-live-probes
        /// Every answer MUST re-check the delivered /32 and routes, every required
        /// service, a current-boot SSH bootstrap marker, a running sshd service,
        /// and a synced write on C:; a failed or erroring probe withholds the answer.
        fn probe(&mut self) -> io::Result<bool> {
            if !net::configured(self.address, self.gateway)? {
                self.logger.log("probe_network_pending");
                return Ok(false);
            }
            for name in REQUIRED {
                if !services::running(name)? {
                    self.logger.log("probe_service_pending");
                    return Ok(false);
                }
            }
            if !ssh_bootstrap_ready(
                boot_id::marker_is_current(Path::new(ssh_bootstrap::READY)),
                boot_id::marker_is_current(Path::new(ssh_bootstrap::CERTIFICATE_READY)),
                || services::running(SSHD),
            )? {
                self.logger.log("probe_sshd_pending");
                return Ok(false);
            }
            writable_root()?;
            Ok(true)
        }
    }

    impl Probe for Live {
        fn ready(&mut self) -> io::Result<bool> {
            self.probe()
        }
    }

    /// Create, sync and remove a file on the system volume itself.
    fn writable_root() -> io::Result<()> {
        fs::create_dir_all(RUN_DIR)?;
        let path: PathBuf = Path::new(RUN_DIR).join(format!(".readiness-{}", std::process::id()));
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;
        file.write_all(b"ready\n")?;
        file.sync_all()?;
        drop(file);
        fs::remove_file(&path)
    }

    fn identity(logger: &Logger) -> io::Result<(Boot, Ipv4Addr, Ipv4Addr)> {
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
        let address: Ipv4Addr = document
            .ipv4
            .parse()
            .map_err(|_| io::Error::other("invalid address"))?;
        let gateway: Ipv4Addr = document
            .gateway
            .parse()
            .map_err(|_| io::Error::other("invalid gateway"))?;
        let boot = Boot::new(
            document.placement,
            document.execution_epoch,
            document.boot_challenge,
            boot_id::boot_id()?,
        )?;
        logger.log("identity_bound");
        Ok((boot, address, gateway))
    }

    pub(crate) fn run() -> i32 {
        let logger = Logger::new("readinessd");
        logger.log("start");
        if let Err(error) = vsock::startup() {
            logger.log(&format!(
                "winsock_unavailable code={}",
                error.raw_os_error().unwrap_or(0)
            ));
            logger.publish();
            return 1;
        }
        let (boot, address, gateway) = match identity(&logger) {
            Ok(identity) => identity,
            Err(error) => {
                logger.log(&format!("identity_unavailable kind={:?}", error.kind()));
                logger.publish();
                return 2;
            }
        };
        let family = match vsock::discover(IDENTITY_BUDGET, |_| {}) {
            Ok(family) => family,
            Err(error) => {
                logger.log(&format!("vsock_unavailable kind={:?}", error.kind()));
                logger.publish();
                return 3;
            }
        };
        let listener = match Listener::bind(family, readiness::PORT, 4) {
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
        logger.log(&format!(
            "listening port={} family={}",
            readiness::PORT,
            family.number
        ));
        logger.publish();
        let mut live = Live {
            address,
            gateway,
            logger: logger.clone(),
        };
        let mut answered = false;
        loop {
            let Ok(mut connection) = listener.accept(Duration::from_secs(2)) else {
                std::thread::sleep(Duration::from_millis(200));
                continue;
            };
            match readiness::answer(connection.peer_cid, HOST_CID, &boot, &mut live) {
                Ok(Some(answer)) => {
                    if connection.write_all(&answer).is_ok() && !answered {
                        answered = true;
                        logger.log("ready_answered");
                        logger.publish();
                    }
                }
                Ok(None) => {}
                Err(error) => logger.log(&format!("probe_error kind={:?}", error.kind())),
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
    eprintln!("overalls-readinessd runs inside Windows guests only");
    std::process::exit(64);
}

#[cfg(test)]
mod tests {
    use super::ssh_bootstrap_ready;
    use lyra::guest::readiness::{self, Boot, Probe};
    use std::io;

    struct SshEvidence {
        current_receipt: bool,
        current_certificate: bool,
        service: Result<bool, io::ErrorKind>,
        service_queries: usize,
    }

    impl Probe for SshEvidence {
        fn ready(&mut self) -> io::Result<bool> {
            ssh_bootstrap_ready(self.current_receipt, self.current_certificate, || {
                self.service_queries += 1;
                self.service.map_err(io::Error::from)
            })
        }
    }

    fn boot() -> Boot {
        Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap()
    }

    #[test]
    fn absent_or_stale_ssh_receipts_withhold_ready_even_when_sshd_runs() {
        // marker_is_current maps absent, prior-boot and unreadable files to
        // false. None may authorize a host response through this live gate.
        let mut probe = SshEvidence {
            current_receipt: false,
            current_certificate: true,
            service: Ok(true),
            service_queries: 0,
        };
        assert!(readiness::answer(2, 2, &boot(), &mut probe)
            .unwrap()
            .is_none());
        assert_eq!(probe.service_queries, 0);

        probe.service = Err(io::ErrorKind::PermissionDenied);
        assert!(readiness::answer(2, 2, &boot(), &mut probe)
            .unwrap()
            .is_none());
        assert_eq!(probe.service_queries, 0);
    }

    #[test]
    fn each_host_poll_requires_current_receipt_and_live_sshd() {
        let mut probe = SshEvidence {
            current_receipt: true,
            current_certificate: true,
            service: Ok(false),
            service_queries: 0,
        };
        let boot = boot();
        assert!(readiness::answer(2, 2, &boot, &mut probe)
            .unwrap()
            .is_none());

        probe.service = Ok(true);
        assert_eq!(
            readiness::answer(2, 2, &boot, &mut probe).unwrap(),
            Some(boot.response().unwrap())
        );

        probe.service = Ok(false);
        assert!(readiness::answer(2, 2, &boot, &mut probe)
            .unwrap()
            .is_none());
        assert_eq!(probe.service_queries, 3);

        probe.service = Ok(true);
        probe.current_receipt = false;
        assert!(readiness::answer(2, 2, &boot, &mut probe)
            .unwrap()
            .is_none());
        assert_eq!(probe.service_queries, 3);
    }

    #[test]
    fn service_errors_and_foreign_peers_cannot_receive_ready() {
        let mut probe = SshEvidence {
            current_receipt: true,
            current_certificate: true,
            service: Err(io::ErrorKind::PermissionDenied),
            service_queries: 0,
        };
        assert_eq!(
            readiness::answer(2, 2, &boot(), &mut probe)
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(probe.service_queries, 1);

        probe.service = Ok(true);
        assert!(readiness::answer(3, 2, &boot(), &mut probe)
            .unwrap()
            .is_none());
        assert_eq!(probe.service_queries, 1);
    }

    #[test]
    fn host_certificate_replacement_withholds_ready_until_verified_install() {
        let mut probe = SshEvidence {
            current_receipt: true,
            current_certificate: false,
            service: Ok(true),
            service_queries: 0,
        };
        assert!(readiness::answer(2, 2, &boot(), &mut probe)
            .unwrap()
            .is_none());
        assert_eq!(probe.service_queries, 0);
        probe.current_certificate = true;
        assert!(readiness::answer(2, 2, &boot(), &mut probe)
            .unwrap()
            .is_some());
        assert_eq!(probe.service_queries, 1);
    }
}
