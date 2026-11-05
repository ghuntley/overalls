//! Android receives only closed watch outcome and hint tags.
use crate::{session, MilaFfiStatus, MilaWatchEventKind};

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWatchOpen(
    env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    filters: jni::objects::JByteArray<'_>,
) -> jni::sys::jlong {
    if handle <= 0 {
        return 0;
    }
    let Ok(filters) = env.convert_byte_array(filters) else {
        return 0;
    };
    let mut watch = 0;
    // SAFETY: the Vec is live for its stated length; the output is a writable local.
    let status = unsafe {
        session::mila_session_watch_open(
            handle.cast_unsigned(),
            filters.as_ptr(),
            filters.len(),
            &raw mut watch,
        )
    };
    if status == session::SessionStatus::Ok {
        watch.cast_signed()
    } else {
        0
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWatchRead(
    env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    wait_ms: jni::sys::jint,
) -> jni::sys::jbyteArray {
    if handle <= 0 || !(0..=1000).contains(&wait_ms) {
        return std::ptr::null_mut();
    }
    let mut output = vec![0; session::MILA_WATCH_READ_CAPACITY];
    let mut written = 0;
    let mut event = session::WatchReadEvent::Idle;
    // SAFETY: caller-owned Vec and writable locals meet the C ABI extent contracts.
    let status = unsafe {
        session::mila_session_watch_read_within(
            handle.cast_unsigned(),
            wait_ms.cast_unsigned(),
            output.as_mut_ptr(),
            output.len(),
            &raw mut written,
            &raw mut event,
        )
    };
    if status != session::SessionStatus::Ok || written > output.len() {
        return std::ptr::null_mut();
    }
    let mut kind = MilaWatchEventKind::Unknown;
    if event == session::WatchReadEvent::Event {
        // SAFETY: successful watch reads return `written` valid bytes in this Vec.
        let status =
            unsafe { crate::mila_watch_event_kind(output.as_ptr(), written, &raw mut kind) };
        if status != MilaFfiStatus::Ok {
            return std::ptr::null_mut();
        }
    }
    let outcome = if event == session::WatchReadEvent::Event
        && matches!(
            kind,
            MilaWatchEventKind::Heartbeat | MilaWatchEventKind::Unknown
        ) {
        session::WatchReadEvent::Idle
    } else {
        event
    };
    env.byte_array_from_slice(&[outcome as u8, kind as u8])
        .map_or(
            std::ptr::null_mut(),
            jni::objects::JPrimitiveArray::into_raw,
        )
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWatchReconnect(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jlong {
    if handle <= 0 {
        return 0;
    }
    let mut next = 0;
    // SAFETY: `next` is writable handle storage.
    let status =
        unsafe { session::mila_session_watch_reconnect(handle.cast_unsigned(), &raw mut next) };
    if status == session::SessionStatus::Ok {
        next.cast_signed()
    } else {
        0
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionWatchClose(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jint {
    if handle <= 0 {
        return session::SessionStatus::Invalid as jni::sys::jint;
    }
    session::mila_session_watch_close(handle.cast_unsigned()) as jni::sys::jint
}
