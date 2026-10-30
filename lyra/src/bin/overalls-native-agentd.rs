//! Native POSIX guest executor for FreeBSD and illumos.
//!
//! The executor deliberately reuses Lyra's fenced control loop. Only the
//! filesystem paths and closed diagnostics differ from the Windows wrapper.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
mod daemon {
    use lyra::agent::{self, FetchEvent, Host};
    use sha2::{Digest, Sha256};
    use std::io;
    use std::path::Path;
    use std::time::Duration;

    const RUN_DIR: &str = "/var/run/overalls";
    const STOP_FILE: &str = "/var/run/overalls/agent-stop";
    const READY_FILE: &str = "/var/run/overalls/agent-ready";

    struct Native;

    impl Host for Native {
        fn digest(&self) -> io::Result<String> {
            let bytes = std::fs::read(std::env::current_exe()?)?;
            Ok(hex::encode(Sha256::digest(bytes)))
        }

        fn tool_result(&self, _command_id: &str, completed: bool, duration: Duration) {
            eprintln!(
                "{{\"service\":\"agentd\",\"event\":\"tool_result\",\"completed\":{},\"duration_ms\":{}}}",
                completed,
                duration.as_millis()
            );
        }

        fn fetch_event(&self, event: FetchEvent) {
            let name = match event {
                FetchEvent::Started => "fetch_started",
                FetchEvent::Completed => "fetch_completed",
                FetchEvent::Failed => "fetch_failed",
            };
            eprintln!("{{\"service\":\"agentd\",\"event\":\"{name}\"}}");
        }

        fn stop_requested(&self) -> bool {
            Path::new(STOP_FILE).exists()
        }

        fn ready(&self, digest: &str) {
            let _ = std::fs::create_dir_all(RUN_DIR);
            let _ = std::fs::write(READY_FILE, digest.as_bytes());
            eprintln!("{{\"service\":\"agentd\",\"event\":\"registered\"}}");
        }
    }

    pub(crate) fn run() -> i32 {
        agent::run(&Native).unwrap_or(1)
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    if let Some(code) = lyra::agent::maintenance::run_tool() {
        std::process::exit(code);
    }
    if let Some(code) = lyra::agent::maintenance::bootstrap_invocation() {
        std::process::exit(code);
    }
    std::process::exit(daemon::run());
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}
