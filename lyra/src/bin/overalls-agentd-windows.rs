//! Windows guest agent tool executor (ADR-0171 gate 5).
//!
//! Runs the shared `lyra::agent` control loop as a SYSTEM task: it registers a
//! fence with the private agent endpoint (`llm.internal`, resolved to the local
//! Audi through the bootstrap's name-resolution rule and verified against the
//! roots the trust daemon installed), claims one command at a time and runs
//! `exec_command` through Windows PowerShell 5.1 in a kill-on-close Job
//! Object. There is no self-update on Windows: the digest is the image's own
//! binary and a new executor ships with a rebuilt image. Diagnostics are
//! closed lines in `C:\overalls\logs\agentd.log`; command text, tool output and
//! response bodies never enter them. Exits 64 on other operating systems.

#[cfg(windows)]
mod daemon {
    use lyra::agent::{self, FetchEvent, Host};
    use lyra::platform::windows::log::Logger;
    use sha2::{Digest, Sha256};
    use std::io;
    use std::path::Path;
    use std::time::Duration;

    const RUN_DIR: &str = "C:\\overalls\\run";
    const STOP_FILE: &str = "C:\\overalls\\run\\agent-stop";
    const READY_FILE: &str = "C:\\overalls\\run\\agent-ready";

    struct Windows {
        logger: Logger,
    }

    impl Host for Windows {
        fn digest(&self) -> io::Result<String> {
            let bytes = std::fs::read(std::env::current_exe()?)?;
            Ok(hex::encode(Sha256::digest(bytes)))
        }

        fn tool_result(&self, _command_id: &str, completed: bool, duration: Duration) {
            self.logger.log(&format!(
                "tool_result completed={completed} ms={}",
                duration.as_millis()
            ));
        }

        fn fetch_event(&self, event: FetchEvent) {
            self.logger.log(match event {
                FetchEvent::Started => "fetch_started",
                FetchEvent::Completed => "fetch_completed",
                FetchEvent::Failed => "fetch_failed",
            });
        }

        fn stop_requested(&self) -> bool {
            Path::new(STOP_FILE).exists()
        }

        fn ready(&self, digest: &str) {
            let _ = std::fs::create_dir_all(RUN_DIR);
            let _ = std::fs::write(READY_FILE, digest.as_bytes());
            self.logger.log("registered");
            self.logger.publish();
        }
    }

    pub(crate) fn run() -> i32 {
        let host = Windows {
            logger: Logger::new("agentd"),
        };
        host.logger.log("start");
        host.logger.publish();
        if let Ok(code) = agent::run(&host) {
            code
        } else {
            host.logger.log("executor_unavailable");
            host.logger.publish();
            1
        }
    }
}

#[cfg(windows)]
fn main() {
    if let Some(code) = lyra::agent::maintenance::run_tool() {
        std::process::exit(code);
    }
    if let Some(code) = lyra::agent::maintenance::bootstrap_invocation() {
        std::process::exit(code);
    }
    std::process::exit(daemon::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-agentd-windows runs inside Windows guests only");
    std::process::exit(64);
}
