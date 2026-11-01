//! FreeBSD and illumos shims for the firmware guest agents: fixed disk and
//! filesystem ioctls, and the isolated transport probe's kernel checks.
//!
//! Each ioctl request number is paired here with the exact output object its
//! pinned kernel header defines, so callers cannot mismatch them.

use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;

fn check(result: libc::c_int) -> io::Result<()> {
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// `statfs("/")`.
#[cfg(target_os = "freebsd")]
pub fn statfs_root() -> io::Result<libc::statfs> {
    use std::mem::MaybeUninit;
    let mut root = MaybeUninit::<libc::statfs>::uninit();
    // SAFETY: the fixed NUL-terminated path and writable statfs storage are
    // valid for the call; the output is read only after success.
    if unsafe { libc::statfs(c"/".as_ptr(), root.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful statfs initialized this structure.
    Ok(unsafe { root.assume_init() })
}

/// UFSSUSPEND on an open `/dev/ufssuspend`: flush and suspend the filesystem
/// `identity` names. Closing `device` invokes the kernel's resume cleanup,
/// including on errors or process death.
#[cfg(target_os = "freebsd")]
pub fn ufs_suspend(device: &File, identity: libc::fsid_t) -> io::Result<()> {
    // FreeBSD14.3 sys/ufs/ffs/fs.h: _IOW('U', 1, fsid_t). Stock growfs uses the
    // same root-fsid suspension. Its kernel path waits for
    // VFS_SYNC(MNT_SUSPEND), including UFS softdep dependencies.
    const SUSPEND: libc::c_ulong =
        0x8000_5501 | ((size_of::<libc::fsid_t>() as libc::c_ulong) << 16);
    let mut identity = identity;
    // SAFETY: the ioctl receives a live fsid_t of the exact size its request
    // encodes, on the borrowed open device; no filesystem write occurs here.
    if unsafe { libc::ioctl(device.as_raw_fd(), SUSPEND, &mut identity) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// UFSRESUME on the device that holds a successful suspension.
#[cfg(target_os = "freebsd")]
pub fn ufs_resume(device: &File) -> io::Result<()> {
    // FreeBSD14.3 sys/ufs/ffs/fs.h: _IO('U', 2).
    const RESUME: libc::c_ulong = 0x2000_5502;
    // SAFETY: UFSRESUME takes no argument; the descriptor that owns the
    // suspension stays open for the call.
    if unsafe { libc::ioctl(device.as_raw_fd(), RESUME) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// DIOCGFLUSH: send one `BIO_FLUSH` to the provider's disk.
#[cfg(target_os = "freebsd")]
pub fn flush_disk(disk: &File) -> io::Result<()> {
    // FreeBSD14.3 sys/sys/disk.h: DIOCGFLUSH _IO('d', 135); checked by the
    // native-growth ABI gate.
    const DIOCGFLUSH: libc::c_ulong = 0x2000_6487;
    // SAFETY: DIOCGFLUSH takes no argument and only issues BIO_FLUSH to the
    // provider's disk; the borrowed descriptor stays open for the call.
    if unsafe { libc::ioctl(disk.as_raw_fd(), DIOCGFLUSH) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// DIOCGMEDIASIZE: the provider's size in bytes.
#[cfg(target_os = "freebsd")]
pub fn media_size(disk: &File) -> io::Result<libc::off_t> {
    let mut bytes: libc::off_t = 0;
    // SAFETY: pinned FreeBSD disk.h defines this read-only ioctl with the exact
    // off_t output object supplied here; no disk bytes are written.
    check(unsafe { libc::ioctl(disk.as_raw_fd(), 0x4008_6481, &mut bytes) })?;
    Ok(bytes)
}

/// DIOCGSECTORSIZE: the provider's sector size in bytes.
#[cfg(target_os = "freebsd")]
pub fn sector_size(disk: &File) -> io::Result<libc::c_uint> {
    let mut sector: libc::c_uint = 0;
    // SAFETY: as above; DIOCGSECTORSIZE writes only the supplied u_int.
    check(unsafe { libc::ioctl(disk.as_raw_fd(), 0x4004_6480, &mut sector) })?;
    Ok(sector)
}

/// `dk_minfo` from illumos dkio.h.
#[cfg(any(target_os = "illumos", target_os = "solaris"))]
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Media {
    pub media_type: u32,
    pub sector_bytes: u32,
    pub sectors: u64,
}

/// DKIOCGMEDIAINFO: the disk's media description.
#[cfg(any(target_os = "illumos", target_os = "solaris"))]
pub fn media_info(disk: &File) -> io::Result<Media> {
    let mut media = Media::default();
    // SAFETY: pinned dkio.h defines DKIOCGMEDIAINFO and this C-layout output;
    // the read-only ioctl receives a live device descriptor and writable object.
    check(unsafe { libc::ioctl(disk.as_raw_fd(), 0x42a, &mut media) })?;
    Ok(media)
}

/// `sync(2)`. The pinned illumos ZFS `zfs_sync(NULL, 0)` calls
/// `spa_sync_allpools()`, which waits for dirty pool commits.
#[cfg(any(target_os = "illumos", target_os = "solaris"))]
pub fn sync() {
    // SAFETY: sync takes no input and accesses no caller memory.
    unsafe { libc::sync() };
}

/// Write `value` to the sysctl `name` without reading its old value.
#[cfg(target_os = "freebsd")]
pub fn sysctl_write(name: &std::ffi::CStr, value: &[u8]) -> io::Result<()> {
    // SAFETY: the OID name is NUL-terminated; value is a live input buffer of
    // the length passed and no output buffer is requested.
    let result = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            value.as_ptr().cast(),
            value.len(),
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Poll one descriptor for `events` for at most `timeout_ms`. Returns the
/// number of ready descriptors and the returned events.
#[cfg(target_os = "freebsd")]
pub fn poll_one(
    fd: std::os::fd::BorrowedFd<'_>,
    events: libc::c_short,
    timeout_ms: libc::c_int,
) -> io::Result<(libc::c_int, libc::c_short)> {
    let mut poll = libc::pollfd {
        fd: fd.as_raw_fd(),
        events,
        revents: 0,
    };
    // SAFETY: poll is one live descriptor record for this bounded wait.
    let ready = unsafe { libc::poll(&raw mut poll, 1, timeout_ms) };
    if ready < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((ready, poll.revents))
}

/// Fork a child that drops every supplementary group, sets its group and
/// user IDs to `id`, then tries `socket(domain, SOCK_STREAM, 0)` and exits:
/// 0 when the socket is refused with `EPERM`/`EACCES`, 2 when dropping
/// privileges fails, 3 when the socket opens and 4 on another refusal.
/// Returns the child's raw wait status.
///
/// Precondition: the calling process has not created threads, so the child
/// may run between fork and `_exit`; the child calls only native credential
/// and socket syscalls, without Rust I/O, allocation or destructors.
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
pub fn unprivileged_socket_status(domain: libc::c_int, id: libc::uid_t) -> io::Result<libc::c_int> {
    // SAFETY: the caller guarantees a single-threaded process; the child uses
    // only async-signal-safe syscalls followed by _exit.
    let child = unsafe { libc::fork() };
    if child < 0 {
        return Err(io::Error::last_os_error());
    }
    if child == 0 {
        fn child_exit(code: libc::c_int) -> ! {
            // SAFETY: _exit ends the forked child immediately, without
            // running destructors or flushing state shared with the parent.
            unsafe { libc::_exit(code) }
        }
        // No supplementary groups are retained; setuid permanently drops
        // root. The child never returns into the parent test process.
        // SAFETY: a null list with zero length clears every supplementary group.
        if unsafe { libc::setgroups(0, std::ptr::null()) } != 0 {
            child_exit(2);
        }
        // SAFETY: setgid takes only an integer group ID.
        if unsafe { libc::setgid(id) } != 0 {
            child_exit(2);
        }
        // SAFETY: setuid takes only an integer user ID.
        if unsafe { libc::setuid(id) } != 0 {
            child_exit(2);
        }
        // SAFETY: socket takes only integer arguments.
        let unprivileged = unsafe { libc::socket(domain, libc::SOCK_STREAM, 0) };
        if unprivileged >= 0 {
            // SAFETY: the child owns the descriptor it just created.
            unsafe { libc::close(unprivileged) };
            child_exit(3);
        }
        // SAFETY: the errno accessor has no preconditions and returns this
        // thread's errno location.
        #[cfg(target_os = "freebsd")]
        let location = unsafe { libc::__error() };
        // SAFETY: as above.
        #[cfg(any(target_os = "illumos", target_os = "solaris"))]
        let location = unsafe { libc::___errno() };
        // SAFETY: the errno location is valid for the current thread.
        let error = unsafe { *location };
        child_exit(if error == libc::EPERM || error == libc::EACCES {
            0
        } else {
            4
        });
    }
    let mut status: libc::c_int = 0;
    loop {
        // SAFETY: child is the owned fork result; status is writable.
        if unsafe { libc::waitpid(child, &raw mut status, 0) } == child {
            break;
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(status)
}
