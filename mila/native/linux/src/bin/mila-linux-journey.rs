//! Headless Linux live-journey entrypoint.
//!
//! Usage: `mila-linux-journey --descriptor <path> [--workdir <empty-dir>]`
//!
//! Reads the hermetic fixture descriptor (v1), runs the GTK-independent Linux
//! client modules against it and prints a JSON report of step outcome codes.
//! Exits 0 only when every step passed, 2 for usage or descriptor errors.

use mila_native_linux::journey::{run, JourneyDescriptor};
use std::path::PathBuf;
use std::process::ExitCode;

const MAX_DESCRIPTOR_BYTES: u64 = 256 * 1024;

fn usage() -> ExitCode {
    eprintln!("usage: mila-linux-journey --descriptor <path> [--workdir <empty-dir>]");
    ExitCode::from(2)
}

fn private_workdir(requested: Option<PathBuf>) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let path = match requested {
        Some(path) => path,
        None => {
            let mut suffix = [0_u8; 8];
            std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut suffix)?;
            std::env::temp_dir().join(format!(
                "mila-linux-journey-{:016x}",
                u64::from_le_bytes(suffix)
            ))
        }
    };
    std::fs::DirBuilder::new().mode(0o700).create(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?;
    Ok(path)
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
    let bytes = match std::fs::File::open(&descriptor_path).and_then(|file| {
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(
            &mut std::io::Read::take(file, MAX_DESCRIPTOR_BYTES + 1),
            &mut bytes,
        )
        .map(|_| bytes)
    }) {
        Ok(bytes) => bytes,
        Err(_) => {
            eprintln!("mila-linux-journey: descriptor unreadable");
            return ExitCode::from(2);
        }
    };
    let descriptor = match JourneyDescriptor::parse(&bytes) {
        Ok(descriptor) => descriptor,
        Err(error) => {
            // The error names a field, never its value.
            eprintln!("mila-linux-journey: descriptor rejected: {error:?}");
            return ExitCode::from(2);
        }
    };
    let workdir = match private_workdir(workdir) {
        Ok(path) => path,
        Err(_) => {
            eprintln!("mila-linux-journey: work directory must be new and private");
            return ExitCode::from(2);
        }
    };
    let report = run(&descriptor, &workdir);
    let _ = std::fs::remove_dir_all(&workdir);
    println!(
        "{}",
        serde_json::to_string(&report).expect("report serializes")
    );
    if report.ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
