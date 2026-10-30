#![deny(unsafe_code)]
#![doc = "Non-setuid ZFS exporter. FD 3/4 carry private control; stdout carries disk bytes."]

mod cli;
/// The Erlang port ABI (`:nouse_stdio`) places the control channel at fd 3
/// and the acknowledgement channel at fd 4 of the spawned child. Borrowing
/// the two fixed numbers is the entire unsafe surface; nothing beyond file
/// descriptor identity crosses it.
#[allow(
    unsafe_code,
    reason = "borrowing the fixed port-ABI descriptors 3 and 4"
)]
mod fd_abi;
#[allow(unsafe_code, reason = "sender pre_exec parent-death hook")]
mod pin_sender;
mod run;

pub use cli::*;
pub use run::*;

use std::sync::atomic::{AtomicBool, Ordering};

/// Startup control line and main-loop renewals are bounded to 128 bytes.
pub const CONTROL_FRAME_LIMIT: usize = 128;
/// Diagnostics are discarded with this bound.
pub const DIAGNOSTICS_LIMIT: usize = 65536;
/// argv sizing bound inherited from the C protocol.
pub const ARGV_TOTAL_LIMIT: usize = 65536;
pub const MAX_ARGV: usize = 128;

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_SENDER_FAILED: u8 = 1;
pub const EXIT_DEADLINE: u8 = 2;
pub const EXIT_DIAGNOSTICS: u8 = 3;
pub const EXIT_REVOKED: u8 = 4;
pub const EXIT_INSECURE_LOCK: u8 = 73;
pub const EXIT_IO: u8 = 74;

static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn cancel_handler(_signal: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

/// @cc [owner:ghuntley,label:recovery] source-export-signal-shim
/// The TERM/INT cancellation handler only records into an atomic flag read by
/// the lease loop; libc's signal registration is unsafe-signatured, so this is
/// the entire confinement surface. No data, sender pid or path crosses it.
pub fn install_cancel_handlers() {
    install_cancel_handlers_impl()
}

#[allow(unsafe_code)]
fn install_cancel_handlers_impl() {
    // signal() with a plain extern-C handler storing an AtomicBool is
    // async-signal-safe and bounded; no relocking, allocation or IO.
    let lock = unsafe {
        libc::signal(
            libc::SIGTERM,
            cancel_handler as *const () as libc::sighandler_t,
        )
    };
    let _ = lock;
    let ignore = unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let _ = ignore;
    let cancel = unsafe {
        libc::signal(
            libc::SIGINT,
            cancel_handler as *const () as libc::sighandler_t,
        )
    };
    let _ = cancel;
}

#[cfg(test)]
mod tests;
