//! Deployment trust document validation and reconciliation.

use crate::{MilaFfiStatus, MilaRouteOutput};
use std::ffi::{c_char, CStr};

/// Validates a trust document fetched for `origin_host`. The document is
/// parsed and checked entirely in Rust; no certificate or token is returned.
///
/// # Safety
/// `document` must point to `length` readable bytes and `origin_host` must be
/// a valid NUL-terminated UTF-8 string for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn mila_trust_document_validate(
    document: *const u8,
    length: usize,
    origin_host: *const c_char,
    now: u64,
) -> MilaFfiStatus {
    if document.is_null() || origin_host.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: callers provide a readable byte buffer of `length` bytes.
    let bytes = unsafe { std::slice::from_raw_parts(document, length) };
    // SAFETY: caller provides a NUL-terminated host string.
    let Ok(host) = unsafe { CStr::from_ptr(origin_host) }.to_str() else {
        return MilaFfiStatus::InvalidRequest;
    };
    mila_transport::decode_trust_document(bytes, host, now)
        .map_or(MilaFfiStatus::InvalidRequest, |_| MilaFfiStatus::Ok)
}

/// @cc [owner:ghuntley,label:security] mila-trust-enrollment-reconciles
/// Enrollment MUST persist only the document selected by Rust after HTTPS
/// validation and pinned-authority reconciliation; a malformed or conflicting
/// document MUST return no output.
///
/// Validates and selects a deployment trust document for native enrollment.
///
/// `fetched` is the bounded HTTPS response. `pinned` is the previously persisted
/// document, or an empty slice when no pin exists. A missing fetched document is
/// treated as a transport failure and may use a still-current pin; a malformed
/// fetched document is refused. The selected document is serialized into the
/// caller-owned output buffer so Android and Windows persist exactly the bytes
/// that Rust accepted.
///
/// # Safety
/// All non-null input pointers reference their declared readable lengths,
/// `origin_host` is NUL-terminated UTF-8, and `output` points to writable
/// caller-owned storage for `capacity` bytes plus one `written` value.
#[no_mangle]
pub unsafe extern "C" fn mila_trust_document_reconcile(
    pinned: *const u8,
    pinned_len: usize,
    fetched: *const u8,
    fetched_len: usize,
    origin_host: *const c_char,
    now: u64,
    output: MilaRouteOutput,
) -> MilaFfiStatus {
    if origin_host.is_null() || output.bytes.is_null() || output.written.is_null() {
        return MilaFfiStatus::NullInput;
    }
    if (pinned_len > 0 && pinned.is_null()) || (fetched_len > 0 && fetched.is_null()) {
        return MilaFfiStatus::NullInput;
    }
    if pinned_len > 8192 || fetched_len > 8192 {
        return MilaFfiStatus::InvalidRequest;
    }
    // SAFETY: `origin_host` is non-null and the caller guarantees NUL-terminated UTF-8.
    let Ok(host) = unsafe { CStr::from_ptr(origin_host) }.to_str() else {
        return MilaFfiStatus::InvalidRequest;
    };
    let pinned = if pinned_len == 0 {
        None
    } else {
        // A malformed local pin is discarded as unavailable. It never expands
        // authority; a valid fetched document can establish a new first pin.
        // SAFETY: `pinned` is non-null when `pinned_len > 0` and references that many bytes.
        let bytes = unsafe { std::slice::from_raw_parts(pinned, pinned_len) };
        mila_transport::decode_trust_document(bytes, host, 0).ok()
    };
    let fetched = if fetched_len == 0 {
        None
    } else {
        // SAFETY: `fetched` is non-null when `fetched_len > 0` and references that many bytes.
        let bytes = unsafe { std::slice::from_raw_parts(fetched, fetched_len) };
        match mila_transport::decode_trust_document(bytes, host, now) {
            Ok(document) => Some(document),
            Err(_) => return MilaFfiStatus::InvalidRequest,
        }
    };
    let selected = match fetched {
        Some(document) => mila_transport::reconcile_trust(pinned.as_ref(), document).ok(),
        None => pinned.filter(|document| document.retirement > now),
    };
    let Some(selected) = selected else {
        return MilaFfiStatus::InvalidRequest;
    };
    let Ok(bytes) = serde_json::to_vec(&selected) else {
        return MilaFfiStatus::InvalidRequest;
    };
    // SAFETY: `output.written` is non-null and the caller guarantees one writable `usize`.
    unsafe { *output.written = bytes.len() };
    if bytes.len() > output.capacity {
        return MilaFfiStatus::OutputTooSmall;
    }
    // SAFETY: `output.bytes` is non-null with `capacity` writable bytes, and
    // `bytes.len() <= capacity`; a fresh Vec cannot overlap caller storage.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.bytes, bytes.len()) };
    MilaFfiStatus::Ok
}
