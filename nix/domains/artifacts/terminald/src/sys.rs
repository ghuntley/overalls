//! The crate's only `unsafe` code (ADR-0265): thin FFI shims with safe
//! signatures. Each platform's shims sit behind the same `cfg` as the code
//! that calls them; callers elsewhere are compiled with `deny(unsafe_code)`.
#[cfg(windows)]
pub(crate) mod conpty;
#[cfg(unix)]
pub(crate) mod pty;
#[cfg(unix)]
pub(crate) mod unix;
#[cfg(windows)]
pub(crate) mod windows;
