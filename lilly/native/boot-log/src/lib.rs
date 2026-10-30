#![deny(unsafe_code)]
#![doc = "Drain a child's combined stdout/stderr while retaining a bounded, line-timestamped"]
#![doc = "boot log. No shell, environment lookup, payload diagnostics or text decoding."]

/// Retained boot log bytes, counted into the output file only.
pub const BOOT_LOG_LIMIT: usize = 1024 * 1024;

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_CHILD_SETUP: u8 = 71;
pub const EXIT_CUSTODY: u8 = 74;

mod cli;
mod log;
mod run;
#[allow(
    unsafe_code,
    reason = "signal_reraise restores a default disposition and raises the child's signal through libc"
)]
mod signal_reraise;
mod stamp;

pub use cli::{parse_cli, Request, READER_UIDS};
pub use run::run;
pub use stamp::{push_prefix, Drained, LineState, Retention, Stamper};

#[cfg(test)]
mod tests;
