use std::os::fd::{AsRawFd, OwnedFd};
#[expect(
    clippy::needless_pass_by_value,
    reason = "taking the /dev/null descriptor by value closes it once it is duplicated onto stderr"
)]
pub(crate) fn silence_stderr(null: OwnedFd) -> Result<(), ()> {
    // SAFETY: dup2 takes two integer descriptors; null is open for the call
    // and replacing fd 2 affects no Rust-owned descriptor.
    match unsafe { libc::dup2(null.as_raw_fd(), 2) } {
        2 => Ok(()),
        _ => Err(()),
    }
}
