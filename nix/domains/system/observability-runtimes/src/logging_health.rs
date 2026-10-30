use std::env;
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    delegate(
        "OVERALLS_LOGGING_HEALTH_PYTHON",
        "OVERALLS_LOGGING_HEALTH_SCRIPT",
    )
}

/// @cc [owner:ghuntley,label:reliability;deployment] logging-health-pinned-interpreter
/// The health runtime MUST execute its script with the interpreter path the module
/// pins in the unit environment, never by searching `PATH`: `NixOS` service units
/// carry no Python on `PATH`. A missing interpreter or script setting MUST fail
/// closed with `EX_CONFIG` (78) instead of exporting fabricated health.
fn delegate(interpreter: &str, variable: &str) -> ExitCode {
    let (Ok(python), Ok(script)) = (env::var(interpreter), env::var(variable)) else {
        eprintln!("observability runtime is not configured");
        return ExitCode::from(78);
    };
    let status = Command::new(python)
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
