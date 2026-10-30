//! Audited libc shim. Every `unsafe` call in the trace spool library and its
//! binary lives here behind a safe signature; callers keep their own refusal
//! decisions so behaviour is unchanged.

use std::ffi::CStr;
use std::os::fd::AsRawFd;

/// Effective user ID of this process.
pub fn geteuid() -> libc::uid_t {
    // SAFETY: geteuid(2) takes no arguments, always succeeds and reads or
    // writes no memory owned by Rust.
    unsafe { libc::geteuid() }
}

/// Attempts an exclusive, non-blocking `flock(2)` on `file`; returns whether
/// the lock was acquired.
pub fn try_lock_exclusive(file: &impl AsRawFd) -> bool {
    // SAFETY: the descriptor is borrowed from a live open file for the whole
    // call, and flock(2) only operates on that descriptor without touching
    // Rust-owned memory.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

/// Kernel `SO_PEERCRED` credentials of a connected Unix socket peer, or `None`
/// when the query fails or returns a truncated structure.
pub fn peer_credentials(stream: &impl AsRawFd) -> Option<libc::ucred> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "size_of::<ucred>() is 12 bytes, far below socklen_t::MAX"
    )]
    let mut size = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the descriptor is borrowed from a live socket for the call;
    // `credentials` is a valid, writable `ucred` and `size` holds its exact
    // byte length, so the kernel writes at most `size` bytes into it.
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &raw mut size,
        )
    };
    (status == 0 && size as usize == size_of::<libc::ucred>()).then_some(credentials)
}

/// UID of the named local account, or `None` when no such account exists.
///
/// `getpwnam(3)` returns process-wide static storage, so callers must not
/// invoke any `getpw*` function concurrently; the spool calls this only from
/// its single listener thread.
pub fn user_uid(user: &CStr) -> Option<libc::uid_t> {
    // SAFETY: `user` is a valid NUL-terminated string that outlives the call.
    let account = unsafe { libc::getpwnam(user.as_ptr()) };
    if account.is_null() {
        return None;
    }
    // SAFETY: `account` is non-null and points to the static passwd record
    // just returned by getpwnam; no other getpw* call runs before this read
    // (single listener thread), and only the copied UID escapes.
    Some(unsafe { (*account).pw_uid })
}
