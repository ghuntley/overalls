use std::env;
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let Ok(script) = env::var("OVERALLS_FLEET_EXPORTER_SCRIPT") else {
        eprintln!("observability runtime is not configured");
        return ExitCode::from(78);
    };
    let python =
        env::var("OVERALLS_FLEET_EXPORTER_PYTHON").unwrap_or_else(|_| "python3".to_owned());
    match Command::new(python)
        .arg(script)
        .args(env::args().skip(1))
        .status()
    {
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
