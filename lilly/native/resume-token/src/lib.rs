#![deny(unsafe_code)]
#![doc = "Typed resume-token validation only; this helper never sends disk data."]

pub const TOKEN_MAX_BYTES: usize = 8192;
pub const UNPACKED_MAX_BYTES: u64 = 16384;
pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_INVALID: u8 = 1;
pub const EXIT_IO: u8 = 74;

mod cli;
#[allow(
    unsafe_code,
    reason = "libzfs_redirect points stderr at /dev/null with dup2"
)]
mod libzfs_redirect;
mod lineage;
/// The libzfs boundary, paired and typed end to end.
#[allow(
    unsafe_code,
    reason = "pairs is the typed FFI shim over libzfs and libnvpair"
)]
mod pairs;
mod run;

pub use cli::{parse_cli, Request};
pub use lineage::{bounded, matches, Envelope, Pair};
pub use run::{matches_current, run};

#[cfg(test)]
mod tests;
