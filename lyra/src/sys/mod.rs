//! The crate's only unsafe code: thin FFI shims with safe wrappers
//! (ADR-0265 decision 4).
//!
//! Every unsafe block below carries a `// SAFETY:` comment stating the
//! invariant it relies on. The rest of the crate denies `unsafe_code` and calls
//! these wrappers, whose signatures either make misuse impossible or document
//! the remaining precondition. The library and every binary share this one
//! audit surface; it is public only so the binaries can reach it.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
pub mod native;
#[cfg(unix)]
pub mod socket;
#[cfg(unix)]
pub mod unix;
