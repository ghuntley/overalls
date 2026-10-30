//! JNI terminal bridge: named sessions, PTY handles and scalar validation.

use super::{jni_session_bytes, jni_string_bytes};
use crate::session;
use crate::{
    mila_terminal_attach_validate, mila_terminal_input_validate, mila_terminal_resize_validate,
    MilaFfiStatus,
};

/// @cc [owner:ghuntley,label:security;protocol] jni-session-terminal-named
/// Android terminals MUST open the caller's named Porsche terminal session
/// (`terminal new`) and attach to that machine and session id; the unnamed
/// legacy attach is not used because real Porsche refuses it.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalNew(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jbyteArray {
    let (Some(machine), Some(request_id)) = (
        jni_string_bytes(&mut env, &machine),
        jni_string_bytes(&mut env, &request_id),
    ) else {
        return std::ptr::null_mut();
    };
    jni_session_bytes(&mut env, |out, capacity, written| unsafe {
        session::mila_session_terminal_new(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            request_id.as_ptr(),
            request_id.len(),
            out,
            capacity,
            written,
        )
    })
}

/// @cc [owner:ghuntley,label:security;protocol] jni-session-terminal-end
/// Android MUST end a named terminal session only through `terminal kill` for that
/// machine and session id, submitted once with the caller's request id; the bounded
/// receipt is returned unchanged for the adapter to read `closed` from.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalEnd(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    terminal: jni::objects::JString<'_>,
    request_id: jni::objects::JString<'_>,
) -> jni::sys::jbyteArray {
    let (Some(machine), Some(terminal), Some(request_id)) = (
        jni_string_bytes(&mut env, &machine),
        jni_string_bytes(&mut env, &terminal),
        jni_string_bytes(&mut env, &request_id),
    ) else {
        return std::ptr::null_mut();
    };
    jni_session_bytes(&mut env, |out, capacity, written| unsafe {
        session::mila_session_terminal_end(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            terminal.as_ptr(),
            terminal.len(),
            request_id.as_ptr(),
            request_id.len(),
            out,
            capacity,
            written,
        )
    })
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalAttachSession(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    machine: jni::objects::JString<'_>,
    terminal: jni::objects::JString<'_>,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
) -> jni::sys::jlong {
    if handle <= 0 || columns <= 0 || rows <= 0 {
        return 0;
    }
    let (Some(machine), Some(terminal)) = (
        jni_string_bytes(&mut env, &machine),
        jni_string_bytes(&mut env, &terminal),
    ) else {
        return 0;
    };
    let mut out = 0_u64;
    let status = unsafe {
        session::mila_session_terminal_attach_session(
            handle as u64,
            machine.as_ptr(),
            machine.len(),
            terminal.as_ptr(),
            terminal.len(),
            columns as u32,
            rows as u32,
            &mut out,
        )
    };
    if status == session::SessionStatus::Ok {
        out as jni::sys::jlong
    } else {
        0
    }
}

fn terminal_status(status: MilaFfiStatus) -> jni::sys::jint {
    status as jni::sys::jint
}

/// Open an authenticated PTY and return its opaque handle.  Terminal bytes
/// remain in Rust; Android receives only bounded output chunks through the
/// poll call below.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalOpen(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
) -> jni::sys::jlong {
    if handle <= 0 || columns <= 0 || rows <= 0 {
        return 0;
    }
    let mut terminal = 0_u64;
    let status = session::mila_session_terminal_attach(
        handle as u64,
        columns as u32,
        rows as u32,
        &mut terminal,
    );
    if status == session::SessionStatus::Ok {
        terminal as jni::sys::jlong
    } else {
        0
    }
}

/// Poll one bounded PTY output chunk.  A null result means the call failed;
/// an empty array is a valid no-data/EOF result.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalPoll(
    env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    terminal: jni::sys::jlong,
    capacity: jni::sys::jint,
) -> jni::sys::jbyteArray {
    if terminal <= 0 || !(1..=65_536).contains(&capacity) {
        return std::ptr::null_mut();
    }
    let mut output = vec![0_u8; capacity as usize];
    let mut written = 0_usize;
    let status = unsafe {
        session::mila_session_terminal_poll(
            terminal as u64,
            output.as_mut_ptr(),
            output.len(),
            &mut written,
        )
    };
    if status != session::SessionStatus::Ok || written > output.len() {
        return std::ptr::null_mut();
    }
    match env.byte_array_from_slice(&output[..written]) {
        Ok(array) => array.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Write bounded UTF-8/input bytes to an authenticated PTY.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalInputBytes(
    env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    terminal: jni::sys::jlong,
    input: jni::objects::JByteArray<'_>,
) -> jni::sys::jint {
    if terminal <= 0 {
        return session::SessionStatus::Invalid as jni::sys::jint;
    }
    let bytes = match env.convert_byte_array(&input) {
        Ok(value) => value,
        Err(_) => return session::SessionStatus::Invalid as jni::sys::jint,
    };
    let status = unsafe {
        session::mila_session_terminal_input(terminal as u64, bytes.as_ptr(), bytes.len())
    };
    status as jni::sys::jint
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalResizeHandle(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    terminal: jni::sys::jlong,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
) -> jni::sys::jint {
    if terminal <= 0 || columns <= 0 || rows <= 0 {
        return session::SessionStatus::Invalid as jni::sys::jint;
    }
    session::mila_session_terminal_resize(terminal as u64, columns as u32, rows as u32)
        as jni::sys::jint
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalClose(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    terminal: jni::sys::jlong,
) -> jni::sys::jint {
    if terminal <= 0 {
        return session::SessionStatus::Invalid as jni::sys::jint;
    }
    session::mila_session_terminal_kill(terminal as u64) as jni::sys::jint
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTerminalAttach(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    from: jni::sys::jlong,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
    read_write: jni::sys::jboolean,
) -> jni::sys::jint {
    if from < 0
        || columns < 0
        || rows < 0
        || columns > u16::MAX as i32
        || rows > u16::MAX as i32
        || read_write > 1
    {
        return -4;
    }
    terminal_status(mila_terminal_attach_validate(
        from as u64,
        columns as u16,
        rows as u16,
        read_write,
    ))
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTerminalInput(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    length: jni::sys::jint,
    read_write: jni::sys::jboolean,
) -> jni::sys::jint {
    if length < 0 || read_write > 1 {
        return -4;
    }
    terminal_status(mila_terminal_input_validate(length as usize, read_write))
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTerminalResize(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
    read_write: jni::sys::jboolean,
) -> jni::sys::jint {
    if columns < 0
        || rows < 0
        || columns > u16::MAX as i32
        || rows > u16::MAX as i32
        || read_write > 1
    {
        return -4;
    }
    terminal_status(mila_terminal_resize_validate(
        columns as u16,
        rows as u16,
        read_write,
    ))
}

/// Session-scoped terminal validation. The PTY transport remains owned by the
/// authenticated session; this JNI seam rejects detached or malformed requests.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalAttach(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    from: jni::sys::jlong,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
    read_write: jni::sys::jboolean,
) -> jni::sys::jint {
    if handle <= 0 {
        return -4;
    }
    Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTerminalAttach(
        _env, _class, from, columns, rows, read_write,
    )
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalInput(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    length: jni::sys::jint,
    read_write: jni::sys::jboolean,
) -> jni::sys::jint {
    if handle <= 0 {
        return -4;
    }
    Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTerminalInput(
        _env, _class, length, read_write,
    )
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionTerminalResize(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    columns: jni::sys::jint,
    rows: jni::sys::jint,
    read_write: jni::sys::jboolean,
) -> jni::sys::jint {
    if handle <= 0 {
        return -4;
    }
    Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeTerminalResize(
        _env, _class, columns, rows, read_write,
    )
}
