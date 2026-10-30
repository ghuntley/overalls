//! JNI exports for the Android native client and their shared helpers.

mod session_bridge;
mod terminal;
mod validation;

pub use session_bridge::*;
pub use terminal::*;
pub use validation::*;

use crate::session;

/// Copies one bounded session JSON result into a Java byte array; any refusal
/// yields null. The call runs exactly once with the ABI's 1 MiB output bound,
/// so a mutation is never resubmitted to learn its result size.
fn jni_session_bytes(
    env: &mut jni::JNIEnv<'_>,
    call: impl FnOnce(*mut u8, usize, *mut usize) -> session::SessionStatus,
) -> jni::sys::jbyteArray {
    jni_session_bytes_bounded(env, 1 << 20, call)
}

/// @cc [owner:ghuntley,label:protocol] jni-session-single-read
/// Android session reads and mutations MUST invoke the session ABI exactly once
/// into a caller-bounded buffer; a size probe followed by a read would run the
/// Porsche command twice.
///
/// [jni_session_bytes] with an explicit output bound.
fn jni_session_bytes_bounded(
    env: &mut jni::JNIEnv<'_>,
    bound: usize,
    call: impl FnOnce(*mut u8, usize, *mut usize) -> session::SessionStatus,
) -> jni::sys::jbyteArray {
    let mut data = vec![0u8; bound];
    let mut size = 0usize;
    let status = call(data.as_mut_ptr(), data.len(), &mut size);
    if status != session::SessionStatus::Ok || size > data.len() {
        return std::ptr::null_mut();
    }
    env.byte_array_from_slice(&data[..size])
        .map_or(std::ptr::null_mut(), |a| a.into_raw())
}

fn jni_string_bytes(
    env: &mut jni::JNIEnv<'_>,
    value: &jni::objects::JString<'_>,
) -> Option<Vec<u8>> {
    if value.is_null() {
        return None;
    }
    env.get_string(value).ok().map(|v| v.to_bytes().to_vec())
}
