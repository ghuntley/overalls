//! JNI validation and projection bridges over the C ABI validators.

use crate::{
    mila_machine_command_kind, mila_push_registration_validate, mila_snapshot_machine_actions,
    mila_thread_command_kind, mila_trust_document_reconcile, MilaFfiStatus, MilaMachineActions,
    MilaMachineCommandKind, MilaRouteOutput, MilaThreadCommandKind,
};
use mila_model::MilaRoute;
use std::ffi::CString;

/// JNI trust enrollment bridge. Rust owns validation and pinned-authority
/// reconciliation; only canonical JSON returns to the platform store.
#[allow(clippy::not_unsafe_ptr_arg_deref)]
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTrustDocumentReconcile(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    pinned: jni::sys::jbyteArray,
    fetched: jni::sys::jbyteArray,
    host: jni::objects::JString<'_>,
    now: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    if now < 0 {
        return std::ptr::null_mut();
    }
    let pinned = if pinned.is_null() {
        None
    } else {
        let array = unsafe { jni::objects::JByteArray::from_raw(pinned) };
        match env.convert_byte_array(array) {
            Ok(bytes) => Some(bytes),
            Err(_) => return std::ptr::null_mut(),
        }
    };
    let fetched = if fetched.is_null() {
        None
    } else {
        let array = unsafe { jni::objects::JByteArray::from_raw(fetched) };
        match env.convert_byte_array(array) {
            Ok(bytes) => Some(bytes),
            Err(_) => return std::ptr::null_mut(),
        }
    };
    let host = match env.get_string(&host) {
        Ok(value) => match std::ffi::CString::new(value.to_bytes()) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        },
        Err(_) => return std::ptr::null_mut(),
    };
    let mut output = vec![0_u8; 8192];
    let mut written = 0_usize;
    let status = unsafe {
        mila_trust_document_reconcile(
            pinned.as_ref().map_or(std::ptr::null(), Vec::as_ptr),
            pinned.as_ref().map_or(0, Vec::len),
            fetched.as_ref().map_or(std::ptr::null(), Vec::as_ptr),
            fetched.as_ref().map_or(0, Vec::len),
            host.as_ptr(),
            now as u64,
            MilaRouteOutput {
                bytes: output.as_mut_ptr(),
                capacity: output.len(),
                written: &mut written,
            },
        )
    };
    if status != MilaFfiStatus::Ok || written == 0 || written > output.len() {
        return std::ptr::null_mut();
    }
    env.byte_array_from_slice(&output[..written])
        .map_or(std::ptr::null_mut(), |array| array.into_raw())
}

/// JNI ABI version for the Android native client.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeAbiVersion(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
) -> jni::sys::jint {
    1
}

/// Validate provider registration metadata without retaining the provider token.
#[allow(clippy::not_unsafe_ptr_arg_deref)]
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativePushRegistrationValidate(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    provider: jni::sys::jint,
    environment: jni::sys::jint,
    token: jni::objects::JString<'_>,
    app_id: jni::objects::JString<'_>,
    deployment: jni::objects::JString<'_>,
    endpoint: jni::sys::jobject,
) -> jni::sys::jint {
    if !(0..=2).contains(&provider) || !(0..=1).contains(&environment) {
        return MilaFfiStatus::InvalidRequest as jni::sys::jint;
    }
    let mut text = |value: jni::objects::JString<'_>| -> Option<CString> {
        let bytes = env.get_string(&value).ok()?.to_bytes().to_vec();
        CString::new(bytes).ok()
    };
    let token = match text(token) {
        Some(value) => value,
        None => return MilaFfiStatus::InvalidRequest as jni::sys::jint,
    };
    let app_id = match text(app_id) {
        Some(value) => value,
        None => return MilaFfiStatus::InvalidRequest as jni::sys::jint,
    };
    let deployment = match text(deployment) {
        Some(value) => value,
        None => return MilaFfiStatus::InvalidRequest as jni::sys::jint,
    };
    let endpoint = if endpoint.is_null() {
        None
    } else {
        match text(unsafe { jni::objects::JString::from_raw(endpoint) }) {
            Some(value) => Some(value),
            None => return MilaFfiStatus::InvalidRequest as jni::sys::jint,
        }
    };
    unsafe {
        mila_push_registration_validate(
            provider as u8,
            environment as u8,
            token.as_ptr(),
            app_id.as_ptr(),
            deployment.as_ptr(),
            endpoint
                .as_ref()
                .map_or(std::ptr::null(), |value| value.as_ptr()),
        ) as jni::sys::jint
    }
}

/// JNI route canonicalization delegated to the Rust route parser.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeCanonicalRoute(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    value: jni::objects::JString<'_>,
) -> jni::sys::jstring {
    let input: String = match env.get_string(&value) {
        Ok(v) => v.into(),
        Err(_) => return std::ptr::null_mut(),
    };
    let route = match MilaRoute::parse(&input) {
        Ok(route) => route.format(),
        Err(_) => return std::ptr::null_mut(),
    };
    match env.new_string(route) {
        Ok(output) => output.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// JNI projection of the closed thread command catalogue. Only the stable
/// operation tag crosses the boundary; arguments and payloads remain Rust
/// owned. Returns -1 for malformed or unknown commands.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeThreadCommandKind(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    value: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let input = match env.get_string(&value) {
        Ok(value) => match std::ffi::CString::new(value.to_bytes()) {
            Ok(value) => value,
            Err(_) => return -1,
        },
        Err(_) => return -1,
    };
    let mut kind = MilaThreadCommandKind::Unknown;
    let status = unsafe { mila_thread_command_kind(input.as_ptr(), &mut kind) };
    if status != MilaFfiStatus::Ok {
        return -1;
    }
    kind as jni::sys::jint
}

/// JNI projection of the closed machine-command catalog. Returns -1 for
/// malformed or unknown commands; command arguments remain Rust-owned.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeMachineCommandKind(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    value: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let input = match env.get_string(&value) {
        Ok(value) => match std::ffi::CString::new(value.to_bytes()) {
            Ok(value) => value,
            Err(_) => return -1,
        },
        Err(_) => return -1,
    };
    let mut kind = MilaMachineCommandKind::Unknown;
    let status = unsafe { mila_machine_command_kind(input.as_ptr(), &mut kind) };
    if status != MilaFfiStatus::Ok {
        return -1;
    }
    kind as jni::sys::jint
}

/// JNI projection of the bounded machine action policy.  The returned value is
/// a bit mask (one bit per `MachineAction` discriminant), or `-1` when the
/// snapshot, deployment, or index is invalid.  Machine records never cross
/// this boundary; Android receives only the closed policy result.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeMachineActions(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    bytes: jni::objects::JByteArray<'_>,
    host: jni::objects::JString<'_>,
    port: jni::sys::jint,
    has_port: jni::sys::jboolean,
    index: jni::sys::jint,
) -> jni::sys::jint {
    if port < 0 || port > u16::MAX as jni::sys::jint || index < 0 || has_port > 1 {
        return -1;
    }
    let bytes = match env.convert_byte_array(bytes) {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let host = match env.get_string(&host) {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let host = match std::ffi::CString::new(host.to_bytes()) {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let mut actions = MilaMachineActions { bits: 0 };
    let status = unsafe {
        mila_snapshot_machine_actions(
            bytes.as_ptr(),
            bytes.len(),
            host.as_ptr(),
            port as u16,
            has_port,
            index as u32,
            &mut actions,
        )
    };
    if status == MilaFfiStatus::Ok {
        actions.bits as jni::sys::jint
    } else {
        -1
    }
}
