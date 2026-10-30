#![deny(unsafe_code)]
#![doc = "Pipeline owner run by lilly-hostd. Disk bytes stay in kernel pipes."]

mod cli;
#[allow(
    unsafe_code,
    reason = "pre_exec credential and parent-death hook; the only unsafe surface"
)]
mod pin;
mod run;

pub use cli::*;
pub use run::*;

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_IO: u8 = 74;

/// Byte total cap for the producer + consumer argument vector.
pub const ARGV_TOTAL_LIMIT: usize = 65536;
/// Maximum consumer argv entries.
pub const CONSUMER_ARGS_LIMIT: usize = 128;
/// Producer argv entries live between 1 and 128 inclusive.
pub const PRODUCER_ARGS_LIMIT: usize = 128;
/// Largest transferred diagnostics window in bytes.
pub const DIAGNOSTICS_LIMIT: usize = 65536;
/// Rate credit quantum, in byte-milliseconds (64 KiB per second of credit).
pub const CREDIT_CAP_MS: i64 = 65_536_000;
/// Per-iteration splice ceiling in bytes.
pub const SPLICE_WINDOW: usize = 65536;
/// Largest accepted byte rate.
pub const RATE_LIMIT: i64 = 1_073_741_824;

#[cfg(test)]
mod tests;
