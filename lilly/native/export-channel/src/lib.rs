#![deny(unsafe_code)]
#![doc = "Non-setuid local export channel. Data FD and completion channel stay separate."]

mod bridge;
mod cli;
#[allow(
    unsafe_code,
    reason = "worker pre_exec credential and parent-death hook"
)]
mod pins;
#[allow(unsafe_code, reason = "getpwnam account lookup")]
mod posix;
mod record;
mod serve;

pub use bridge::*;
pub use cli::*;
pub use record::*;
pub use serve::*;

use std::sync::atomic::{AtomicBool, Ordering};

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_FAILED: u8 = 1;

/// One authenticated export request: exactly one 8456-byte record plus an
/// SCM_RIGHTS descriptor on any path.
pub const MAGIC: &[u8; 4] = b"LEX3";
pub const KEY_BYTES: usize = 128;
pub const COMMAND_BYTES: usize = 8320;
pub const WIRE_BYTES: usize = MAGIC.len() + 2 + 2 + KEY_BYTES + COMMAND_BYTES;

static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn cancel_handler(_signal: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

/// @cc [owner:ghuntley,label:recovery] export-cancel-signal-shim
/// TERM/INT registration via libc is unsafe-signatured; the handler records
/// an atomic flag and nothing else. No data crosses the boundary.
pub fn install_cancel_handlers() {
    #[allow(unsafe_code)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(
            libc::SIGTERM,
            cancel_handler as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            cancel_handler as *const () as libc::sighandler_t,
        );
    }
}

pub fn cancelled() -> bool {
    CANCELLED.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests;
