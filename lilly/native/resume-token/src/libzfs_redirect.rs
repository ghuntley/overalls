use std::os::fd::{AsRawFd, OwnedFd};
pub(crate) fn silence_stderr(null: OwnedFd) -> Result<(), ()> {
    match unsafe { libc::dup2(null.as_raw_fd(), 2) } {
        2 => Ok(()),
        _ => Err(()),
    }
}
