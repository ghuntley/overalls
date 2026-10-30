#![deny(unsafe_code)]
#![doc = "Byte bridge lilly-hostd runs between a client socket and a guest connection (ADR-0184, ADR-0187)."]

use std::ops::RangeInclusive;

pub const EXIT_OK: u8 = 0;
pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_IO: u8 = 74;

/// Bytes one direction holds in its kernel pipe at most.
pub const WINDOW: usize = 65_536;
/// Accepted inherited descriptors: never stdio.
pub const FDS: RangeInclusive<i64> = 3..=1023;
/// Accepted uids to drop to: never root, never the overflow uid.
pub const UIDS: RangeInclusive<i64> = 1..=4_294_967_294;

/// The byte a detached bridge sends hostd once it holds both connections.
pub const READY: u8 = b'R';
/// The byte hostd answers once the client's greeting is written.
pub const GO: u8 = b'G';

mod cli;
mod direction;
#[allow(
    unsafe_code,
    reason = "the native shim adopts inherited descriptors and drops credentials through libc"
)]
mod native;
mod run;

pub use cli::{parse_cli, Request};
pub use direction::{finished, half_close_due, Direction};
pub use run::{handshake, run};

#[cfg(test)]
mod tests;
