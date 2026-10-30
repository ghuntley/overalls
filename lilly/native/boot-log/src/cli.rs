use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

/// A validated invocation: an optional reader uid, an absolute private log
/// path and an absolute command.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub reader: Option<u32>,
    pub log: PathBuf,
    pub program: PathBuf,
    pub arguments: Vec<OsString>,
}

/// Uids a log may be handed to: never root (the writer's own default) nor
/// the `-1` "unchanged" sentinel of chown(2).
pub const READER_UIDS: std::ops::RangeInclusive<u32> = 1..=4_294_967_294;

/// @cc [owner:ghuntley,label:security] boot-log-cli-reader
/// `parse_cli` MUST accept `[--reader-uid N] LOG PROGRAM ARGS...` only, with N
/// a decimal uid in `READER_UIDS` and LOG and PROGRAM absolute; any other
/// shape, including a repeated or misplaced `--reader-uid`, MUST be None.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let (reader, arguments) = match arguments {
        [flag, uid, rest @ ..] if flag.as_os_str().as_bytes() == b"--reader-uid" => {
            let uid = std::str::from_utf8(uid.as_os_str().as_bytes()).ok()?;
            if !uid.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            let uid: u32 = uid.parse().ok()?;
            if !READER_UIDS.contains(&uid) {
                return None;
            }
            (Some(uid), rest)
        }
        rest => (None, rest),
    };
    let [log, program, rest @ ..] = arguments else {
        return None;
    };
    for absolute in [log, program] {
        if !absolute.as_os_str().as_bytes().starts_with(b"/") {
            return None;
        }
    }
    Some(Request {
        reader,
        log: PathBuf::from(log),
        program: PathBuf::from(program),
        arguments: rest.to_vec(),
    })
}
