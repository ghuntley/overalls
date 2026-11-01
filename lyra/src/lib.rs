//! Shared certificate and trust primitives for the client and guest/gateway helpers.
#![deny(unsafe_code)]
pub mod agent;
pub mod durable;
pub mod guest;
pub mod http;
#[cfg(any(
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris",
    all(test, unix)
))]
pub mod native_bootstrap;
#[cfg(any(
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris",
    all(test, unix)
))]
pub mod native_growth;
#[cfg(any(
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris",
    all(test, unix)
))]
pub mod native_guest;
#[cfg(any(
    target_os = "freebsd",
    target_os = "illumos",
    target_os = "solaris",
    all(test, unix)
))]
pub mod native_vsock;
pub mod platform;
pub mod private_http;
pub mod ssh_certificate;
pub mod ssh_files;
#[doc(hidden)]
#[allow(
    unsafe_code,
    reason = "the FFI shims are the crate's audited unsafe surface (ADR-0265)"
)]
pub mod sys;
pub mod workspace_checkout;
pub mod workspace_receiver;
pub mod workspace_source;
