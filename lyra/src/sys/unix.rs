//! POSIX shims shared by every Unix target (Linux, macOS, FreeBSD, illumos).

use std::io;
use std::os::fd::{AsRawFd, BorrowedFd};

/// The calling process's effective user ID.
pub fn geteuid() -> u32 {
    // SAFETY: geteuid takes no arguments, touches no caller memory and cannot fail.
    unsafe { libc::geteuid() }
}

/// Send `SIGKILL` to the process group `group`.
///
/// Precondition: `group` is the positive PID of a child this process started
/// as the leader of its own new process group, so the signal reaches only that
/// child's tree. The result is ignored: the group may already be gone.
pub fn kill_process_group(group: libc::pid_t) {
    // SAFETY: killpg takes plain integers and accesses no memory; the caller
    // guarantees `group` names a process group it owns.
    unsafe {
        libc::killpg(group, libc::SIGKILL);
    }
}

/// Send `signal` to `pid`; signal zero only checks existence and permission.
/// Returns the OS error when the call fails.
pub fn kill(pid: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
    // SAFETY: kill takes plain integers and accesses no memory.
    if unsafe { libc::kill(pid, signal) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Reap `pid` without blocking (`WNOHANG`), discarding its status.
/// Returns the reaped PID, zero while it still runs, or the OS error.
pub fn waitpid_nohang(pid: libc::pid_t) -> io::Result<libc::pid_t> {
    // SAFETY: a null status pointer is permitted and WNOHANG never blocks.
    let reaped = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
    if reaped < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(reaped)
    }
}

/// Add `O_NONBLOCK` to the status flags of the borrowed descriptor.
pub fn set_nonblocking(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: the borrow keeps the descriptor open; F_GETFL reads only its
    // status flags.
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above; F_SETFL only adds O_NONBLOCK to the same descriptor.
    if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Make `command`'s child start a new session (`setsid`) between fork and exec,
/// detaching it from the caller's terminal; spawning fails if `setsid` does.
pub fn new_session_before_exec(command: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    let hook = || {
        // SAFETY: setsid takes no arguments and is async-signal-safe.
        if unsafe { libc::setsid() } < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    };
    // SAFETY: the hook runs between fork and exec and only calls the
    // async-signal-safe setsid and reads errno; it neither allocates nor locks.
    unsafe {
        command.pre_exec(hook);
    }
}

/// The fields Lyra reads from one account database (`passwd`) record.
#[derive(Debug)]
pub struct Passwd {
    /// The account's user ID.
    pub uid: libc::uid_t,
    /// Its home directory, when the record has one.
    pub home: Option<std::path::PathBuf>,
}

/// Look `name` up in the account database with the reentrant `getpwnam_r`
/// and a 64 KiB record buffer. `None` when the lookup fails or finds nothing.
pub fn passwd_by_name(name: &std::ffi::CStr) -> Option<Passwd> {
    use std::ffi::CStr;
    use std::mem::MaybeUninit;
    use std::os::unix::ffi::OsStrExt;
    let mut account = MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0u8; 65_536];
    let mut result = std::ptr::null_mut();
    // SAFETY: name is NUL-terminated; account, result and the fixed-size buffer
    // remain alive for the call. Fields are read only after a successful lookup.
    let status = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            account.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &raw mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    // SAFETY: getpwnam_r initialized account and its pointers reference buffer.
    let account = unsafe { account.assume_init() };
    let home = (!account.pw_dir.is_null()).then(|| {
        // SAFETY: pw_dir is a non-null NUL-terminated field of the successful
        // record and points into `buffer`, which is still alive here.
        let bytes = unsafe { CStr::from_ptr(account.pw_dir) }.to_bytes();
        std::path::PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
    });
    Some(Passwd {
        uid: account.pw_uid,
        home,
    })
}
