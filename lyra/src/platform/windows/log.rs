//! Append-only agent logs under `C:\overalls\logs`, published on the EFI system
//! partition so the host can read them from the raw disk without logging in
//! (the pattern `overalls-bootstrap.ps1` set). Lines are closed event names and
//! numbers only: never tokens, challenges, certificates or terminal bytes.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const LOG_DIR: &str = "C:\\overalls\\logs";
const PUBLISHED_DIR: &str = "S:\\overalls\\logs";

/// One agent's log file.
#[derive(Clone, Debug)]
pub struct Logger {
    name: &'static str,
    path: PathBuf,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

impl Logger {
    /// `name` is the agent, e.g. `readinessd`; the file is `C:\overalls\logs\<name>.log`.
    pub fn new(name: &'static str) -> Self {
        let _ = fs::create_dir_all(LOG_DIR);
        Self {
            name,
            path: Path::new(LOG_DIR).join(format!("{name}.log")),
        }
    }

    /// @cc [owner:ghuntley,label:security] windows-agent-log-closed-lines
    /// Callers MUST pass only closed event names and numeric facts; the logger
    /// never receives tokens, challenges, key or certificate material.
    pub fn log(&self, line: &str) {
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
        {
            let _ = writeln!(file, "{} {} {}", now(), self.name, line);
        }
    }

    /// Copy the log onto the EFI system partition; best effort, retried
    /// because another agent or the bootstrap task may hold the S: mount.
    pub fn publish(&self) {
        for _ in 0..5 {
            let mounted = Command::new("mountvol.exe")
                .args(["S:", "/S"])
                .status()
                .is_ok_and(|status| status.success());
            if mounted || Path::new("S:\\").exists() {
                let target = Path::new(PUBLISHED_DIR).join(format!("{}.log", self.name));
                let copied = fs::create_dir_all(PUBLISHED_DIR)
                    .and_then(|()| fs::copy(&self.path, target))
                    .is_ok();
                let _ = Command::new("mountvol.exe").args(["S:", "/D"]).status();
                if copied {
                    return;
                }
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        self.log("publish_skipped");
    }
}
