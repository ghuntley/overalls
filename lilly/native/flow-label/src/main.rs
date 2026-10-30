#![deny(unsafe_code)]

use lilly_flow_label::{lookup, parse_cli, EXIT_FAILED};
use std::io::Write as _;
use std::process::ExitCode;

fn main() -> ExitCode {
    // Usage failures exit 1 like the C helper: the selector never distinguished
    // usage from lookup failure. Stdout carries only the hex label plus newline.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::FAILURE,
        Some(query) => match lookup(query) {
            Err(_) | Ok(None) => ExitCode::from(EXIT_FAILED),
            Ok(Some(label)) => {
                let hex = label.to_hex();
                writeln!(std::io::stdout(), "{hex}")
                    .map(|()| ExitCode::SUCCESS)
                    .unwrap_or_else(|_| ExitCode::from(EXIT_FAILED))
            }
        },
    }
}
