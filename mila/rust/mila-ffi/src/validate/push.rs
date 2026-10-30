//! Push registration, key request and poke validation.

use crate::{MilaFfiStatus, MilaRouteOutput};
use mila_runtime::{PokeEnvelope, PushEnvironment, PushProvider, PushRegistrationRequest};
use std::ffi::{c_char, CStr};

/// Validates a push registration request without carrying a platform secret
/// across the ABI. `provider`: 0=APNs, 1=FCM, 2=WNS; `environment`: 0=dev,
/// 1=production. WNS requires a channel endpoint; other providers reject one.
///
/// # Safety
/// `token`, `app_id`, and `deployment` must be valid NUL-terminated UTF-8
/// strings. If supplied, `endpoint` must meet the same requirements.
#[no_mangle]
pub unsafe extern "C" fn mila_push_registration_validate(
    provider: u8,
    environment: u8,
    token: *const c_char,
    app_id: *const c_char,
    deployment: *const c_char,
    endpoint: *const c_char,
) -> MilaFfiStatus {
    // SAFETY: the caller upholds this function's contract, which is the
    // contract of `push_registration_request`.
    match unsafe {
        push_registration_request(provider, environment, token, app_id, deployment, endpoint)
    } {
        Ok(_) => MilaFfiStatus::Ok,
        Err(status) => status,
    }
}

/// # Safety
/// `token`, `app_id` and `deployment` must be null or valid NUL-terminated
/// strings, and `endpoint` null or a valid NUL-terminated string.
unsafe fn push_registration_request(
    provider: u8,
    environment: u8,
    token: *const c_char,
    app_id: *const c_char,
    deployment: *const c_char,
    endpoint: *const c_char,
) -> Result<PushRegistrationRequest, MilaFfiStatus> {
    if token.is_null() || app_id.is_null() || deployment.is_null() {
        return Err(MilaFfiStatus::NullInput);
    }
    let text = |value: *const c_char| {
        // SAFETY: only non-null arguments reach this closure, and the caller
        // guarantees each is a NUL-terminated string.
        unsafe { CStr::from_ptr(value) }
            .to_str()
            .map(str::to_owned)
            .map_err(|_| MilaFfiStatus::InvalidRequest)
    };
    let token = text(token)?;
    let deployment = text(deployment)?;
    let app_id = text(app_id)?;
    let endpoint = if endpoint.is_null() {
        None
    } else {
        Some(text(endpoint)?)
    };
    let provider = match provider {
        0 => PushProvider::Apns,
        1 => PushProvider::Fcm,
        2 => PushProvider::Wns,
        _ => return Err(MilaFfiStatus::InvalidRequest),
    };
    let environment = match environment {
        0 => PushEnvironment::Development,
        1 => PushEnvironment::Production,
        _ => return Err(MilaFfiStatus::InvalidRequest),
    };
    PushRegistrationRequest::new(provider, token, app_id, environment, deployment, endpoint)
        .map_err(|_| MilaFfiStatus::InvalidRequest)
}

/// Copies bytes into caller storage, reporting the required length first.
///
/// # Safety
/// Non-null `output` pointers must reference one writable `usize` and
/// `capacity` writable bytes respectively.
unsafe fn write_output(bytes: &[u8], output: &MilaRouteOutput) -> MilaFfiStatus {
    if output.written.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: `output.written` is non-null and the caller guarantees one writable `usize`.
    unsafe { *output.written = bytes.len() };
    if bytes.len() > output.capacity {
        return MilaFfiStatus::OutputTooSmall;
    }
    if output.bytes.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: `output.bytes` is non-null with `capacity` writable bytes and
    // `bytes.len() <= capacity`; Rust-owned `bytes` cannot overlap caller storage.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.bytes, bytes.len()) };
    MilaFfiStatus::Ok
}

/// Encodes Susan's closed key-issuance body for a validated push registration.
/// Arguments are those of [`mila_push_registration_validate`]; the body is
/// written to caller storage only after the same validation succeeds.
///
/// # Safety
/// String arguments follow [`mila_push_registration_validate`]; `output`
/// references caller-owned writable storage of `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn mila_push_key_request_encode(
    provider: u8,
    environment: u8,
    token: *const c_char,
    app_id: *const c_char,
    deployment: *const c_char,
    endpoint: *const c_char,
    output: MilaRouteOutput,
) -> MilaFfiStatus {
    // SAFETY: the caller upholds the string contract of `push_registration_request`.
    let request = match unsafe {
        push_registration_request(provider, environment, token, app_id, deployment, endpoint)
    } {
        Ok(request) => request,
        Err(status) => return status,
    };
    // SAFETY: the caller guarantees `output` references writable caller storage.
    unsafe { write_output(&request.susan_body(), &output) }
}

/// Validates a Susan push poke envelope without exposing its ciphertext to a UI.
/// The deployment is checked by the Rust runtime and the caller receives only
/// the stable status code.
///
/// # Safety
/// `envelope` must point to `length` readable UTF-8 JSON bytes.
#[no_mangle]
pub unsafe extern "C" fn mila_push_poke_validate(
    envelope: *const u8,
    length: usize,
    now: u64,
) -> MilaFfiStatus {
    if envelope.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: callers provide a readable byte buffer of `length` bytes.
    let bytes = unsafe { std::slice::from_raw_parts(envelope, length) };
    let Ok(value) = serde_json::from_slice::<PokeEnvelope>(bytes) else {
        return MilaFfiStatus::InvalidRequest;
    };
    value
        .validate(now)
        .map_or(MilaFfiStatus::InvalidRequest, |()| MilaFfiStatus::Ok)
}
