//! Narrow C ABI for native platform bridges.
//!
//! The first migration slice exposes validation only. Ownership of all strings remains
//! with the caller; no secret or private key crosses this boundary.

pub mod session;

mod abi;
mod actions;
mod android;
mod commands;
mod validate;

pub use abi::*;
pub use actions::*;
pub use android::*;
pub use commands::*;
pub use validate::*;

#[cfg(test)]
mod tests;
