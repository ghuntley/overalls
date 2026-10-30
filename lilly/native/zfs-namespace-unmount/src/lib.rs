#![deny(unsafe_code)]
#![doc = "Namespace sweep: unmount the exact owned ZFS root from every foreign"]
#![doc = "mount namespace. Runs inside PID 1's mount namespace only."]

#[allow(
    unsafe_code,
    reason = "setns into a retained mount-namespace descriptor; the only unsafe surface"
)]
mod namespace_ops;
mod plan;
mod sweep;

pub use plan::*;
pub use sweep::*;

pub const MAX_NAMESPACES: usize = 512;
pub const MAX_PROCESSES: usize = 32768;
pub const MAX_DESCRIPTORS: usize = 131072;
pub const MAX_LINE: usize = 65536;

#[cfg(test)]
mod tests;
