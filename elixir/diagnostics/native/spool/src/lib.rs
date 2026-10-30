//! Independent durable custody for reviewed host OpenTelemetry trace batches.
#![deny(unsafe_code)]

mod schema;
mod store;
#[allow(
    unsafe_code,
    reason = "audited libc shim: the only unsafe code in the trace spool library and binary"
)]
pub mod sys;
#[cfg(test)]
mod tests;

pub use schema::Schema;
pub use store::{Batch, Health, Store};

pub const BODY_LIMIT: usize = 262_144;
const NS_PER_SECOND: u64 = 1_000_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Foreign,
    Capacity,
    Storage,
    Poisoned,
}
