use std::env;
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    delegate("OVERALLS_LOGGING_HEALTH_SCRIPT")
}

fn delegate(variable: &str) -> ExitCode {
    let Ok(script) = env::var(variable) else {
        eprintln!("observability runtime is not configured");
        return ExitCode::from(78);
    };
    let status = Command::new("/usr/bin/env")
        .arg("python3")
        .arg(script)
        .args(env::args().skip(1))
        .status();
    match status {
        Ok(status) => {
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "on Unix ExitStatus::code is WEXITSTATUS, always within 0..=255"
            )]
            let code = status.code().unwrap_or(1) as u8;
            ExitCode::from(code)
        }
        Err(_) => ExitCode::from(127),
    }
}
