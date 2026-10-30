//! Sanitization boundary for telemetry from user controlled VMs.

pub mod browser_probe;
pub mod durable_slo;
pub mod request_recorder;
pub mod slo;
pub mod underclass_probe;

mod binding;
mod intake;
mod sanitize;

pub use binding::{parse_binding, Binding};
pub use intake::IntakeLimit;
pub use sanitize::{sanitize_metrics, sanitize_traces};

#[cfg(test)]
mod tests;
