//! Windows virtio-vsock transport probe (Phase 3 gate 1, ADR-0171).
//!
//! Runs as a SYSTEM scheduled task in spike images. It discovers the address
//! family the virtio-win `viosock` Winsock provider registers, listens on vsock
//! port 1024 and answers every host connection with one JSON line naming the
//! family, how it was found and the peer's CID and port. It listens on port
//! 1099 so the readiness daemon owns 1024. Its log goes to
//! `C:\overalls\logs\winprobe.log` and is published on the EFI system partition
//! so the host reads it from the raw disk without logging in, like the
//! bootstrap log. It ships only until the real agents replace it and never
//! carries credentials or identity material.
//!
//! On any other operating system the binary exits 64 so the shared crate's
//! Linux checks still build every bin.

#[cfg(windows)]
mod probe {
    use lyra::platform::windows::vsock::{self, Family, Listener};
    use std::fs::{self, OpenOptions};
    use std::io::Write;
    use std::path::Path;
    use std::process::Command;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    /// Probe port; the host dials it through Firecracker's `CONNECT 1099`.
    const PORT: u32 = 1099;
    /// The viosock driver binds at first boot through `PnP` and its Winsock
    /// provider service starts afterwards; wait for it generously.
    const DISCOVERY_BUDGET: Duration = Duration::from_mins(10);
    const LOG_DIR: &str = "C:\\overalls\\logs";
    const LOG: &str = "C:\\overalls\\logs\\winprobe.log";
    const PUBLISHED_DIR: &str = "S:\\overalls\\logs";
    const PUBLISHED: &str = "S:\\overalls\\logs\\winprobe.log";

    fn now() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs())
    }

    fn log(line: &str) {
        let _ = fs::create_dir_all(LOG_DIR);
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(LOG) {
            let _ = writeln!(file, "{} {}", now(), line);
        }
    }

    /// Copy the log onto the EFI system partition; best effort, retried
    /// because the bootstrap task may hold the S: mount for a moment.
    fn publish() {
        for _ in 0..5 {
            let mounted = Command::new("mountvol.exe")
                .args(["S:", "/S"])
                .status()
                .is_ok_and(|status| status.success());
            if mounted || Path::new("S:\\").exists() {
                let copied = fs::create_dir_all(PUBLISHED_DIR)
                    .and_then(|()| fs::copy(LOG, PUBLISHED))
                    .is_ok();
                let _ = Command::new("mountvol.exe").args(["S:", "/D"]).status();
                if copied {
                    return;
                }
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        log("publish skipped: EFI system partition unavailable");
    }

    fn answer(connection: &mut vsock::Connection, family: Family, count: u64) {
        let body = format!(
            "{{\"probe\":\"overalls-winprobe\",\"version\":\"{}\",\"address_family\":{},\"source\":\"{}\",\"peer_cid\":{},\"peer_port\":{},\"connection\":{}}}\n",
            env!("CARGO_PKG_VERSION"),
            family.number,
            family.source.name(),
            connection.peer_cid,
            connection.peer_port,
            count
        );
        let sent = connection.write_all(body.as_bytes()).is_ok();
        log(&format!(
            "answered connection {count} peer_cid={} peer_port={} sent={sent}",
            connection.peer_cid, connection.peer_port
        ));
    }

    pub(crate) fn run() -> i32 {
        log(&format!("start version {}", env!("CARGO_PKG_VERSION")));
        if let Err(error) = vsock::startup() {
            log(&format!("WSAStartup failed: {error}"));
            publish();
            return 1;
        }
        let mut last_report: Option<std::time::Instant> = None;
        let family = match vsock::discover(DISCOVERY_BUDGET, |error| {
            if last_report.is_none_or(|reported| reported.elapsed() >= Duration::from_secs(30)) {
                log(&format!("vsock provider not ready: {error}"));
                if let Ok(providers) = vsock::catalog() {
                    for provider in providers {
                        log(&format!(
                            "catalog provider family={} type={} protocol={} name={:?}",
                            provider.family, provider.socket_type, provider.protocol, provider.name
                        ));
                    }
                }
                last_report = Some(std::time::Instant::now());
            }
        }) {
            Ok(family) => family,
            Err(error) => {
                log(&format!(
                    "no vsock address family within the discovery budget: {error}"
                ));
                publish();
                return 2;
            }
        };
        log(&format!(
            "vsock address family {} via {}",
            family.number,
            family.source.name()
        ));
        let listener = match Listener::bind(family, PORT, 1) {
            Ok(listener) => listener,
            Err(error) => {
                log(&format!("bind/listen on port {PORT} failed: {error}"));
                publish();
                return 3;
            }
        };
        log(&format!("listening on vsock port {PORT}"));
        publish();
        let mut count = 0u64;
        loop {
            match listener.accept(Duration::from_secs(5)) {
                Ok(mut connection) => {
                    count += 1;
                    answer(&mut connection, family, count);
                    publish();
                }
                Err(error) => {
                    log(&format!("accept failed: {error}"));
                    std::thread::sleep(Duration::from_millis(500));
                }
            }
        }
    }
}

#[cfg(windows)]
fn main() {
    std::process::exit(probe::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-winprobe runs inside Windows guests only");
    std::process::exit(64);
}
