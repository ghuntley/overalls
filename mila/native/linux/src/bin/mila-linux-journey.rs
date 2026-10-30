//! Headless Linux live-journey entrypoint.
//!
//! Usage: `mila-linux-journey --descriptor <path> [--workdir <empty-dir>]`
//!
//! Reads the hermetic fixture descriptor (v1), runs the GTK-independent Linux
//! client modules against it and prints a JSON report of step outcome codes.
//! Exits 0 only when every step passed, 2 for usage or descriptor errors.

use mila_native_linux::journey::{create_private_workdir, read_descriptor, run};
use std::path::PathBuf;
use std::process::ExitCode;

fn usage() -> ExitCode {
    eprintln!("usage: mila-linux-journey --descriptor <path> [--workdir <empty-dir>]");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    let mut descriptor_path = None;
    let mut workdir = None;
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--descriptor") => descriptor_path = arguments.next().map(PathBuf::from),
            Some("--workdir") => workdir = arguments.next().map(PathBuf::from),
            _ => return usage(),
        }
    }
    let Some(descriptor_path) = descriptor_path else {
        return usage();
    };
    let descriptor = match read_descriptor(&descriptor_path) {
        Ok(descriptor) => descriptor,
        Err(error) => {
            // The error names a field, never its value.
            eprintln!("mila-linux-journey: descriptor rejected: {error:?}");
            return ExitCode::from(2);
        }
    };
    let Ok(workdir) = create_private_workdir(workdir) else {
        eprintln!("mila-linux-journey: work directory must be new and private");
        return ExitCode::from(2);
    };
    let report = run(&descriptor, &workdir);
    let _ = std::fs::remove_dir_all(&workdir);
    #[expect(
        clippy::expect_used,
        reason = "JourneyReport derives Serialize over integers, booleans and strings only, which serde_json always encodes"
    )]
    let encoded = serde_json::to_string(&report).expect("report serializes");
    println!("{encoded}");
    if report.ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
