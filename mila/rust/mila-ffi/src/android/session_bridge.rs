//! JNI bridge for the live session: connect, the Android signer, and every
//! session read and mutation.

use super::{jni_session_bytes, jni_session_bytes_bounded, jni_string_bytes};
use crate::session;

/// JNI bridge for the bounded live-session ABI. The signer object is held only for
/// the synchronous connect call and must expose `sign(byte[]) -> byte[]`.
struct AndroidSigner {
    vm: jni::JavaVM,
    signer: jni::objects::GlobalRef,
}
/// @cc [owner:ghuntley,label:security] jni-android-signer-no-pending-exception
/// The Android signer callback MUST return failure, never a pending Java exception, to the
/// Rust thread that invoked it; a signing failure becomes a refused connect, not a crash.
unsafe extern "C" fn android_sign(
    context: usize,
    message: *const u8,
    length: usize,
    output: *mut u8,
) -> i32 {
    let state = &*(context as *const AndroidSigner);
    let mut env = match state.vm.attach_current_thread() {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let bytes = if message.is_null() || output.is_null() || length == 0 || length > 65_536 {
        return -1;
    } else {
        std::slice::from_raw_parts(message, length)
    };
    let signature = android_sign_bytes(&mut env, &state.signer, bytes);
    // A Java exception left pending on this attached Rust thread would be dispatched as
    // uncaught when the thread detaches (killing the app), or abort the next JNI call.
    if env.exception_check().unwrap_or(true) {
        let _ = env.exception_clear();
        return -1;
    }
    match signature {
        Some(signature) => {
            std::ptr::copy_nonoverlapping(signature.as_ptr(), output, 64);
            0
        }
        None => -1,
    }
}

fn android_sign_bytes(
    env: &mut jni::JNIEnv<'_>,
    signer: &jni::objects::GlobalRef,
    bytes: &[u8],
) -> Option<Vec<u8>> {
    let input = env.byte_array_from_slice(bytes).ok()?;
    let value = env
        .call_method(
            signer,
            "sign",
            "([B)[B",
            &[jni::objects::JValue::Object(&input.into())],
        )
        .ok()?;
    let array = jni::objects::JByteArray::from(value.l().ok()?);
    env.convert_byte_array(array)
        .ok()
        .filter(|signature| signature.len() == 64)
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionConnect(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    trust: jni::objects::JByteArray<'_>,
    host: jni::objects::JString<'_>,
    public_key: jni::objects::JString<'_>,
    port: jni::sys::jint,
    timeout_ms: jni::sys::jint,
    signer: jni::objects::JObject<'_>,
) -> jni::sys::jlong {
    if port <= 0 || port > u16::MAX as i32 || timeout_ms <= 0 {
        return 0;
    }
    let trust = match env.convert_byte_array(trust) {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let host = match env.get_string(&host) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return 0,
    };
    let public_key = match env.get_string(&public_key) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return 0,
    };
    let global = match env.new_global_ref(signer) {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let vm = match env.get_java_vm() {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let state = Box::new(AndroidSigner { vm, signer: global });
    let context = Box::into_raw(state) as usize;
    let mut handle = 0u64;
    let status = unsafe {
        session::mila_session_connect(
            trust.as_ptr(),
            trust.len(),
            host.as_ptr(),
            host.len(),
            public_key.as_ptr(),
            public_key.len(),
            port as u16,
            timeout_ms as u32,
            Some(android_sign),
            context,
            &mut handle,
        )
    };
    unsafe {
        drop(Box::from_raw(context as *mut AndroidSigner));
    }
    if status == session::SessionStatus::Ok {
        handle as jni::sys::jlong
    } else {
        0
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionRead(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    more: jni::sys::jboolean,
) -> jni::sys::jint {
    session::mila_session_read_machines(handle as u64, more) as jni::sys::jint
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionMachineAction(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    action: jni::objects::JString<'_>,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let machine = match env.get_string(&machine) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let action = match env.get_string(&action) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let request_id = match env.get_string(&request_id) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    unsafe {
        session::mila_session_machine_action(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            action.as_ptr(),
            action.len(),
            request_id.as_ptr(),
            request_id.len(),
        ) as jni::sys::jint
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionMachineResize(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    cpu: jni::sys::jint,
    memory: jni::sys::jint,
    disk: jni::sys::jint,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let machine = match env.get_string(&machine) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let request_id = match env.get_string(&request_id) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    unsafe {
        session::mila_session_machine_resize(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            cpu as u32,
            memory as u64,
            disk as u64,
            request_id.as_ptr(),
            request_id.len(),
        ) as jni::sys::jint
    }
}

/// @cc [owner:ghuntley,label:security;protocol] jni-session-machine-create
/// Android machine creation MUST reach `mila_session_machine_create` on the
/// caller's authenticated handle with the caller-minted request id; negative
/// JNI resource values are refused before the C ABI, which keeps the Rust
/// session bounds authoritative.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionMachineCreate(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    name: jni::objects::JString<'_>,
    cpu: jni::sys::jint,
    memory: jni::sys::jint,
    disk: jni::sys::jint,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jint {
    if cpu < 0 || memory < 0 || disk < 0 {
        return -4;
    }
    let name = match env.get_string(&name) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let request_id = match env.get_string(&request_id) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    unsafe {
        session::mila_session_machine_create(
            handle as u64,
            name.as_ptr(),
            name.len(),
            cpu as u32,
            memory as u64,
            disk as u64,
            request_id.as_ptr(),
            request_id.len(),
        ) as jni::sys::jint
    }
}

/// @cc [owner:ghuntley,label:security;protocol] jni-session-share-mutation
/// Android sharing MUST reach `mila_session_share_mutation` on the caller's
/// authenticated handle. A null role selects removal; the C ABI and session
/// still validate the closed role set, principal bounds and request id.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionShareMutation(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    email: jni::objects::JString<'_>,
    role: jni::objects::JString<'_>,
    add: jni::sys::jboolean,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let machine = match env.get_string(&machine) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let email = match env.get_string(&email) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let role = if role.is_null() {
        Vec::new()
    } else {
        match env.get_string(&role) {
            Ok(v) => v.to_bytes().to_vec(),
            Err(_) => return -4,
        }
    };
    let request_id = match env.get_string(&request_id) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    unsafe {
        session::mila_session_share_mutation(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            email.as_ptr(),
            email.len(),
            role.as_ptr(),
            role.len(),
            u8::from(add != 0),
            request_id.as_ptr(),
            request_id.len(),
        ) as jni::sys::jint
    }
}

/// @cc [owner:ghuntley,label:security;protocol] jni-session-device-register
/// Android device registration MUST pass Susan's key-issuance reply and the
/// device encryption public key to `mila_session_device_register`, which
/// validates both before the push key reaches Porsche on stdin only.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionDeviceRegister(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    platform: jni::sys::jint,
    susan_reply: jni::objects::JString<'_>,
    enc_pubkey: jni::objects::JString<'_>,
    label: jni::objects::JString<'_>,
    now: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    if !(0..=3).contains(&platform) || now < 0 {
        return std::ptr::null_mut();
    }
    let (Some(reply), Some(enc)) = (
        jni_string_bytes(&mut env, &susan_reply),
        jni_string_bytes(&mut env, &enc_pubkey),
    ) else {
        return std::ptr::null_mut();
    };
    let label = jni_string_bytes(&mut env, &label).unwrap_or_default();
    jni_session_bytes(&mut env, |out, capacity, written| unsafe {
        session::mila_session_device_register(
            handle as u64,
            platform as u8,
            reply.as_ptr(),
            reply.len(),
            enc.as_ptr(),
            enc.len(),
            if label.is_empty() {
                std::ptr::null()
            } else {
                label.as_ptr()
            },
            label.len(),
            now as u64,
            out,
            capacity,
            written,
        )
    })
}

/// Closed refusal code recorded by the session's last Porsche error envelope.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionLastRefusal(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    jni_session_bytes(&mut env, |out, capacity, written| unsafe {
        session::mila_session_last_refusal(handle as u64, out, capacity, written)
    })
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWebShow(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
) -> jni::sys::jbyteArray {
    let machine = match env.get_string(&machine) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return std::ptr::null_mut(),
    };
    jni_session_bytes_bounded(&mut env, 1 << 20, |out, capacity, written| unsafe {
        session::mila_session_web_show(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            out,
            capacity,
            written,
        )
    })
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWebSet(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    port: jni::sys::jint,
    public: jni::sys::jboolean,
    revision: jni::sys::jlong,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jint {
    if !(1..=65535).contains(&port) || revision < 0 {
        return -4;
    }
    let machine = match env.get_string(&machine) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    let request_id = match env.get_string(&request_id) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -4,
    };
    unsafe {
        session::mila_session_web_set(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            port as u16,
            u8::from(public != 0),
            revision as u64,
            request_id.as_ptr(),
            request_id.len(),
        ) as jni::sys::jint
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionThreadAction(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    thread: jni::objects::JString<'_>,
    command: jni::objects::JString<'_>,
    secondary: jni::sys::jobject,
    input: jni::sys::jobject,
    request_id: jni::sys::jobject,
) -> jni::sys::jbyteArray {
    let mut text = |s: jni::objects::JString<'_>| env.get_string(&s).map(|v| v.to_bytes().to_vec());
    let thread = match text(thread) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let command = match text(command) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let mut optional = |obj: jni::sys::jobject| -> Option<Vec<u8>> {
        if obj.is_null() {
            None
        } else {
            env.get_string(&unsafe { jni::objects::JString::from_raw(obj) })
                .ok()
                .map(|v| v.to_bytes().to_vec())
        }
    };
    let secondary = optional(secondary);
    let input = optional(input);
    let request = optional(request_id);
    jni_session_bytes_bounded(&mut env, 256 * 1024, |out, capacity, written| unsafe {
        session::mila_session_thread_action(
            handle as u64,
            thread.as_ptr(),
            thread.len(),
            command.as_ptr(),
            command.len(),
            secondary.as_ref().map_or(std::ptr::null(), |v| v.as_ptr()),
            secondary.as_ref().map_or(0, Vec::len),
            input.as_ref().map_or(std::ptr::null(), |v| v.as_ptr()),
            input.as_ref().map_or(0, Vec::len),
            request.as_ref().map_or(std::ptr::null(), |v| v.as_ptr()),
            request.as_ref().map_or(0, Vec::len),
            out,
            capacity,
            written,
        )
    })
}

/// Copy the bounded authenticated SSH-key listing from an existing session.
/// The listing is validated by `mila-session` before any bytes cross JNI.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionSshKeys(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    jni_session_bytes_bounded(&mut env, 256 * 1024, |out, capacity, written| unsafe {
        session::mila_session_ssh_keys(handle as u64, out, capacity, written)
    })
}

/// Copy the bounded `whoami --json` envelope from an existing session. Approval
/// links cross JNI only after Rust has validated the JSON framing and bounds.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWhoami(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    // `whoami` executes remotely, so it runs once into a bounded buffer.
    jni_session_bytes_bounded(&mut env, 64 * 1024, |out, capacity, written| unsafe {
        session::mila_session_whoami(handle as u64, out, capacity, written)
    })
}

/// Revoke one opaque approved-key identity on the already authenticated session.
/// Request IDs are generated and bounded by the Kotlin adapter; Rust validates both
/// identifiers before constructing the Porsche command.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionSshKeyRevoke(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    key: jni::objects::JString<'_>,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let key = match env.get_string(&key) {
        Ok(value) => value.to_bytes().to_vec(),
        Err(_) => return session::SessionStatus::Invalid as jni::sys::jint,
    };
    let request = match env.get_string(&request_id) {
        Ok(value) => value.to_bytes().to_vec(),
        Err(_) => return session::SessionStatus::Invalid as jni::sys::jint,
    };
    unsafe {
        session::mila_session_ssh_key_revoke(
            handle as u64,
            key.as_ptr(),
            key.len(),
            request.as_ptr(),
            request.len(),
        ) as jni::sys::jint
    }
}

fn session_copy(env: &mut jni::JNIEnv<'_>, handle: u64, snapshot: bool) -> jni::sys::jbyteArray {
    // One bounded call: a size probe followed by a read would execute the
    // listing/snapshot twice and could return a different second result.
    jni_session_bytes_bounded(env, 8 * 1024 * 1024, |out, capacity, written| unsafe {
        if snapshot {
            session::mila_session_snapshot(handle, 0, out, capacity, written)
        } else {
            session::mila_session_listing(handle, out, capacity, written)
        }
    })
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionListing(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    session_copy(&mut env, handle as u64, false)
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionSnapshot(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    session_copy(&mut env, handle as u64, true)
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionDeviceList(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    jni_session_bytes_bounded(&mut env, 256 * 1024, |out, capacity, written| unsafe {
        session::mila_session_device_ls(handle as u64, out, capacity, written)
    })
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionDeviceRemove(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    device: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let value = match env.get_string(&device) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -2,
    };
    unsafe {
        session::mila_session_device_rm(handle as u64, value.as_ptr(), value.len())
            as jni::sys::jint
    }
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionDevicePreferences(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    device: jni::objects::JString<'_>,
    enabled: jni::sys::jboolean,
) -> jni::sys::jint {
    let value = match env.get_string(&device) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return -2,
    };
    unsafe {
        session::mila_session_device_prefs(
            handle as u64,
            value.as_ptr(),
            value.len(),
            if enabled == 0 { 0 } else { 1 },
        ) as jni::sys::jint
    }
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionClose(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jint {
    session::mila_session_close(handle as u64) as jni::sys::jint
}
