use std::os::fd::{FromRawFd, OwnedFd};

/// Take ownership of an inherited descriptor after checking it is open.
pub(super) fn adopt(fd: i32) -> Option<OwnedFd> {
    // SAFETY: F_GETFD only inspects the descriptor table entry.
    if unsafe { libc::fcntl(fd, libc::F_GETFD) } == -1 {
        return None;
    }
    // SAFETY: the descriptor is open, was inherited for this process
    // alone, and nothing else in this process refers to it.
    Some(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Drop every supplementary group, then the gid and uid, then set
/// `no_new_privs`. The process is single-threaded here, so the libc
/// wrappers change the whole process's credentials.
pub(super) fn drop_to(uid: u32) -> std::io::Result<()> {
    // SAFETY: a zero count means setgroups reads nothing through the null list.
    let failed = unsafe { libc::setgroups(0, std::ptr::null()) } != 0
        // SAFETY: setresgid takes plain integer ids and no pointers.
        || unsafe { libc::setresgid(uid, uid, uid) } != 0
        // SAFETY: setresuid takes plain integer ids and no pointers.
        || unsafe { libc::setresuid(uid, uid, uid) } != 0
        // SAFETY: PR_SET_NO_NEW_PRIVS takes integer arguments and no pointers.
        || unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0;
    if failed {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}
