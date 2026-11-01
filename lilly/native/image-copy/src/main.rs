#![forbid(unsafe_code)]

use lilly_image_copy::{
    identity, materialize, materialize_leased, materialize_snapshot, parse_size,
    parse_snapshot_size, write_result, Error, Mode,
};
use std::path::Path;
use std::process::ExitCode;

/// The validated operation's single result line.
fn run() -> Result<String, Error> {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match arguments.as_slice() {
        [mode, path] if mode == "identity" => Ok(format!("{:?}", identity(Path::new(path))?.0)),
        [mode, source, target, size, uid] if mode == "snapshot" => {
            let size = parse_snapshot_size(size.to_str().ok_or(Error::Arguments)?)?;
            let uid = uid
                .to_str()
                .and_then(|uid| uid.parse::<u32>().ok())
                .ok_or(Error::Arguments)?;
            let result = materialize_snapshot(Path::new(source), Path::new(target), size, uid)?;
            Ok(result.wire().to_string())
        }
        [mode, source, target, size, lease @ ..] if lease.len() <= 1 => {
            let mode = match mode.to_str() {
                Some("auto") => Mode::Auto,
                Some("copy") => Mode::Copy,
                _ => return Err(Error::Arguments),
            };
            let size = parse_size(size.to_str().ok_or(Error::Arguments)?)?;
            let result = match lease.first() {
                Some(lease) => materialize_leased(
                    mode,
                    Path::new(source),
                    Path::new(target),
                    size,
                    Path::new(lease),
                ),
                None => materialize(mode, Path::new(source), Path::new(target), size),
            }?;
            Ok(result.wire().to_string())
        }
        _ => Err(Error::Arguments),
    }
}

fn main() -> ExitCode {
    // The parent emits reviewed catalog events. Neither arguments nor native
    // error strings are exposed through an unstructured helper log stream.
    // A closed or failing stdout is a typed Error::Output, never a println!
    // panic (which would abort the hardened helper).
    match run().and_then(|line| write_result(&mut std::io::stdout().lock(), &line)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Error::Arguments) => ExitCode::from(2),
        Err(Error::Source) => ExitCode::from(3),
        Err(Error::Destination) => ExitCode::from(4),
        Err(_) => ExitCode::from(5),
    }
}
