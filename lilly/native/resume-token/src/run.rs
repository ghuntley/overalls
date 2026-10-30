use crate::libzfs_redirect;
use crate::pairs;
use crate::{bounded, matches, Request, EXIT_INVALID, EXIT_IO, EXIT_SETUP};
use rustix::fs::{Mode as FileMode, OFlags};

pub(crate) fn veil_stderr() -> Result<(), ()> {
    let null = rustix::fs::open(
        "/dev/null",
        OFlags::WRONLY | OFlags::CLOEXEC,
        FileMode::empty(),
    )
    .map_err(|_| ())?;
    let stderr = std::io::stderr();
    let _ = null;
    let _ = stderr;
    // std has no access to fd-based dup2 without unsafe helpers; the pause and
    // silence boundary is the entire surface relocated to the shim.
    libzfs_redirect::silence_stderr(null)
}

/// The production evaluator: bounds first, library second, questions never echo.
pub fn matches_current(request: &Request) -> Result<bool, u8> {
    debug_assert!(bounded(&request.token), "selectors keep bounded tokens");
    veil_stderr().map_err(|()| EXIT_SETUP)?;
    let library = pairs::Library::init().ok_or(EXIT_INVALID)?;
    let Some(list) = library.decode_token(&request.token) else {
        return Ok(false);
    };
    Ok(matches(&list.pairs(), &request.name, request.to))
}

pub fn run(request: &Request) -> u8 {
    match matches_current(request) {
        Ok(true) => {
            let stdout = std::io::stdout();
            match rustix::io::write(stdout, b"ok\n") {
                Ok(3) => 0,
                _ => EXIT_IO,
            }
        }
        Ok(false) => EXIT_INVALID,
        Err(code) => code,
    }
}
