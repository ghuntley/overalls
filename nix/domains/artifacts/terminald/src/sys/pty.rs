//! PTY allocation, passwd lookup and the post-fork session child on Unix
//! guests. `crate::pty` keeps the policy (identity resolution, environment,
//! status-pipe handling); this module holds only the calls that need `unsafe`.
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};

/// A passwd entry, copied out of the `getpwnam_r` buffer.
pub(crate) struct Passwd {
    pub(crate) name: Vec<u8>,
    pub(crate) uid: u32,
    pub(crate) gid: u32,
    pub(crate) shell: Vec<u8>,
    pub(crate) home: Vec<u8>,
}

/// `getpwnam_r` for `name`; `None` when the lookup fails or finds nothing.
pub(crate) fn lookup_passwd(name: &CStr) -> Option<Passwd> {
    let mut buffer = vec![0u8; 4096];
    // SAFETY: passwd is plain C data; all-zero (null pointers) is valid.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: `name` is NUL-terminated; `entry`, `result` and the
    // `buffer.len()`-byte `buffer` are live locals getpwnam_r may write.
    let status = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            &raw mut entry,
            buffer.as_mut_ptr().cast::<libc::c_char>(),
            buffer.len(),
            &raw mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    let copy = |pointer: *const libc::c_char| -> Vec<u8> {
        if pointer.is_null() {
            Vec::new()
        } else {
            // SAFETY: a successful getpwnam_r points each non-null field at a
            // NUL-terminated string inside `buffer`, which is still alive.
            unsafe { CStr::from_ptr(pointer) }.to_bytes().to_vec()
        }
    };
    Some(Passwd {
        name: copy(entry.pw_name),
        uid: entry.pw_uid,
        gid: entry.pw_gid,
        shell: copy(entry.pw_shell),
        home: copy(entry.pw_dir),
    })
}

/// The test runner's own passwd name.
#[cfg(test)]
pub(crate) fn current_user_name() -> String {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    // SAFETY: getpwuid takes an integer; the test harness reads the result
    // before any other passwd call can reuse its static storage.
    let entry = unsafe { libc::getpwuid(uid) };
    assert!(!entry.is_null(), "current uid must have a passwd entry");
    // SAFETY: `entry` is non-null and points at getpwuid's live passwd record.
    let name = unsafe { (*entry).pw_name };
    // SAFETY: pw_name is a NUL-terminated string in that same live record.
    unsafe { CStr::from_ptr(name) }
        .to_string_lossy()
        .into_owned()
}

/// `posix_openpt(flags)`, owned.
pub(crate) fn open_master(flags: libc::c_int) -> io::Result<OwnedFd> {
    // SAFETY: posix_openpt takes flags only and touches no memory.
    let master = unsafe { libc::posix_openpt(flags) };
    if master < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `master` is a freshly opened descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(master) })
}

/// `grantpt(master)`.
pub(crate) fn grantpt(master: RawFd) -> libc::c_int {
    // SAFETY: grantpt takes the master descriptor only and touches no caller
    // memory.
    unsafe { libc::grantpt(master) }
}

/// `unlockpt(master)`.
pub(crate) fn unlockpt(master: RawFd) -> libc::c_int {
    // SAFETY: unlockpt takes the master descriptor only and touches no caller
    // memory.
    unsafe { libc::unlockpt(master) }
}

#[cfg(not(target_os = "illumos"))]
pub(crate) fn slave_name(master: RawFd) -> io::Result<CString> {
    let mut buffer = [0_u8; 128];
    // SAFETY: ptsname_r writes at most `buffer.len()` bytes into `buffer`, a
    // live local array.
    let status = unsafe { libc::ptsname_r(master, buffer.as_mut_ptr().cast(), buffer.len()) };
    if status > 0 {
        return Err(io::Error::from_raw_os_error(status));
    }
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a successful ptsname_r leaves a NUL-terminated name in `buffer`.
    Ok(unsafe { CStr::from_ptr(buffer.as_ptr().cast()) }.to_owned())
}

/// @cc [owner:ghuntley,label:security] illumos-terminal-slave-name
/// The pinned illumos libc lacks `ptsname_r`. Its ptsname buffer MUST be copied
/// while holding the daemon's shared ptsname mutex before fork; no other daemon
/// call site may use ptsname without that same lock.
#[cfg(target_os = "illumos")]
pub(crate) fn slave_name(master: RawFd) -> io::Result<CString> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = LOCK
        .lock()
        .map_err(|_| io::Error::other("slave name lock unavailable"))?;
    // SAFETY: ptsname takes the open master only; `_guard` serializes every
    // daemon use of its static result buffer.
    let pointer = unsafe { libc::ptsname(master) };
    if pointer.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a non-null ptsname result is a NUL-terminated string in a
    // static buffer that no other caller can overwrite while `_guard` lives.
    Ok(unsafe { CStr::from_ptr(pointer) }.to_owned())
}

/// `getrlimit(RLIMIT_NOFILE)`: the hard descriptor limit.
#[cfg(target_os = "illumos")]
pub(crate) fn descriptor_hard_limit() -> io::Result<libc::rlim_t> {
    // SAFETY: rlimit is plain integer data; all-zero is valid.
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    // SAFETY: getrlimit(2) writes one rlimit to `limit`, a live local.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(limit.rlim_max)
}

/// `pipe2(2)` into `fds`.
pub(crate) fn pipe2(fds: &mut [libc::c_int; 2], flags: libc::c_int) -> libc::c_int {
    // SAFETY: pipe2(2) writes two descriptors into `fds`, a live exclusive
    // two-element array.
    unsafe { libc::pipe2(fds.as_mut_ptr(), flags) }
}

/// A NULL-terminated `char *` array (argv or envp) borrowing its strings.
pub(crate) struct CStringArray<'a> {
    pointers: Vec<*const libc::c_char>,
    strings: std::marker::PhantomData<&'a CStr>,
}

impl<'a> CStringArray<'a> {
    pub(crate) fn new(strings: &'a [CString]) -> Self {
        Self {
            pointers: strings
                .iter()
                .map(|a| a.as_ptr())
                .chain(std::iter::once(std::ptr::null()))
                .collect(),
            strings: std::marker::PhantomData,
        }
    }
}

/// The supplementary groups `setgroups` applies, with the count in the
/// platform's argument type.
pub(crate) struct Groups<'a> {
    groups: &'a [libc::gid_t],
    #[cfg(target_os = "linux")]
    count: usize,
    #[cfg(any(target_os = "freebsd", target_os = "illumos"))]
    count: libc::c_int,
}

impl<'a> Groups<'a> {
    #[cfg(target_os = "linux")]
    pub(crate) fn new(groups: &'a [libc::gid_t]) -> Self {
        Self {
            groups,
            count: groups.len(),
        }
    }

    #[cfg(any(target_os = "freebsd", target_os = "illumos"))]
    pub(crate) fn new(groups: &'a [libc::gid_t]) -> io::Result<Self> {
        let count: libc::c_int = groups.len().try_into().map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "too many supplementary groups")
        })?;
        Ok(Self { groups, count })
    }
}

/// Everything the post-fork child uses, all built before fork.
pub(crate) struct Child<'a> {
    /// The status pipe's read end, which the child closes.
    pub(crate) status_read: RawFd,
    /// The status pipe's CLOEXEC write end, which reports a pre-exec errno.
    pub(crate) status_write: RawFd,
    pub(crate) descriptor_bound: i32,
    pub(crate) slave: &'a CStr,
    pub(crate) master: RawFd,
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) groups: Groups<'a>,
    pub(crate) gid: u32,
    pub(crate) uid: u32,
    pub(crate) home: &'a CStr,
    pub(crate) shell: &'a CStr,
    pub(crate) argv: &'a CStringArray<'a>,
    pub(crate) envp: &'a CStringArray<'a>,
}

/// `fork(2)`. Returns the child's PID (or -1) in the parent; the child runs
/// `child` to execve, or reports errno on the status pipe and `_exit`s, and
/// never returns.
pub(crate) fn fork_session(child: &Child<'_>) -> libc::pid_t {
    // SAFETY: every value the child uses (identity, argv, envp, slave name,
    // descriptor bound) was built before fork; the child below makes only
    // async-signal-safe calls until execve or _exit.
    let pid = unsafe { libc::fork() };
    if pid == 0 {
        // SAFETY: this is the post-fork child, as `run_child` requires.
        unsafe { run_child(child) }
    }
    pid
}

/// # Safety
///
/// Call only in the post-fork child of `fork_session`.
#[expect(
    clippy::multiple_unsafe_ops_per_block,
    reason = "the post-fork child is one async-signal-safe sequence ending in \
              execve or _exit, with one shared invariant"
)]
unsafe fn run_child(child: &Child<'_>) -> ! {
    let status = child.status_write;
    // SAFETY: this is the post-fork child of a multithreaded parent. Every
    // call is async-signal-safe and allocates nothing: the argv, envp,
    // group and path pointers were built before fork and stay valid in
    // this copy of the address space; `empty` is a live local sigset;
    // every failure reports errno through the CLOEXEC status pipe and
    // ends the child with _exit, so control never returns to the parent's
    // Rust code.
    unsafe {
        libc::close(child.status_read);
        // The child may not inherit another session's transport or future daemon
        // descriptors, even if a library opened one without O_CLOEXEC.
        if protect_child_descriptors(child.descriptor_bound) != 0 || libc::setsid() < 0 {
            child_failed(status);
        }
        let slave_fd = libc::open(child.slave.as_ptr(), libc::O_RDWR);
        if slave_fd < 0 {
            child_failed(status);
        }
        if !prepare_slave(slave_fd, child.cols, child.rows)
            || !controlling_terminal(slave_fd)
            || libc::dup2(slave_fd, 0) < 0
            || libc::dup2(slave_fd, 1) < 0
            || libc::dup2(slave_fd, 2) < 0
        {
            child_failed(status);
        }
        if slave_fd > 2 {
            libc::close(slave_fd);
        }
        libc::close(child.master);
        let empty: libc::sigset_t = std::mem::zeroed();
        let mask_error =
            libc::pthread_sigmask(libc::SIG_SETMASK, &raw const empty, std::ptr::null_mut());
        if mask_error != 0 {
            child_failed_with(status, mask_error);
        }
        for signal in 1..=31 {
            if signal != libc::SIGKILL
                && signal != libc::SIGSTOP
                && libc::signal(signal, libc::SIG_DFL) == libc::SIG_ERR
            {
                child_failed(status);
            }
        }
        if libc::geteuid() == 0 {
            if libc::setgroups(child.groups.count, child.groups.groups.as_ptr()) != 0
                || libc::setgid(child.gid) != 0
                || libc::setuid(child.uid) != 0
            {
                child_failed(status);
            }
        } else if libc::getuid() != child.uid || libc::getgid() != child.gid {
            child_failed_with(status, libc::EPERM);
        }
        if libc::chdir(child.home.as_ptr()) != 0 {
            child_failed(status);
        }
        libc::execve(
            child.shell.as_ptr(),
            child.argv.pointers.as_ptr(),
            child.envp.pointers.as_ptr(),
        );
        child_failed(status);
    }
}

/// The illumos STREAMS slave is acquired by opening it after setsid without
/// `O_NOCTTY`; TIOCSCTTY is unsupported. Every native child MUST verify that the
/// slave belongs to its own session before applying credentials or executing.
unsafe fn controlling_terminal(fd: RawFd) -> bool {
    #[cfg(not(target_os = "illumos"))]
    {
        let steal: libc::c_ulong = 0;
        // SAFETY: TIOCSCTTY takes an integer argument and touches no caller
        // memory; an invalid descriptor only makes the ioctl fail.
        if unsafe { libc::ioctl(fd, libc::TIOCSCTTY, steal) } < 0 {
            return false;
        }
    }
    // SAFETY: tcgetsid only inspects the descriptor and reports failure as -1.
    let session = unsafe { libc::tcgetsid(fd) };
    // SAFETY: getpid has no preconditions and is async-signal-safe.
    session == unsafe { libc::getpid() }
}

#[cfg(target_os = "linux")]
#[expect(
    clippy::cast_possible_truncation,
    reason = "close_range returns only 0 or -1"
)]
unsafe fn protect_child_descriptors(_bound: i32) -> libc::c_int {
    // SAFETY: close_range with CLOSE_RANGE_CLOEXEC only sets descriptor flags
    // in this process and reads no caller memory.
    unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3u32,
            u32::MAX,
            libc::CLOSE_RANGE_CLOEXEC,
        ) as libc::c_int
    }
}

#[cfg(target_os = "freebsd")]
unsafe fn protect_child_descriptors(_bound: i32) -> libc::c_int {
    // SAFETY: close_range with CLOSE_RANGE_CLOEXEC only sets descriptor flags
    // in this process and reads no caller memory.
    unsafe { libc::close_range(3, u32::MAX, libc::CLOSE_RANGE_CLOEXEC.cast_signed()) }
}

#[cfg(target_os = "illumos")]
unsafe fn protect_child_descriptors(bound: i32) -> libc::c_int {
    for fd in 3..bound {
        // SAFETY: F_GETFD reads only descriptor flags; a closed descriptor
        // reports EBADF.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        if flags < 0 {
            // SAFETY: this runs in the same thread that just failed fcntl, so
            // the thread-local errno is that call's result.
            if unsafe { child_errno() } == libc::EBADF {
                continue;
            }
            return -1;
        }
        // SAFETY: F_SETFD only updates descriptor flags of a descriptor that
        // F_GETFD has just shown to be open.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } != 0 {
            return -1;
        }
    }
    0
}

#[cfg(not(target_os = "illumos"))]
unsafe fn prepare_slave(_fd: RawFd, _cols: u16, _rows: u16) -> bool {
    true
}

/// @cc [owner:ghuntley,label:security] illumos-terminal-streams-setup
/// The illumos slave MUST have ptem, ldterm and ttcompat pushed once, with the
/// requested window size set after those modules exist. Every ioctl failure
/// MUST refuse the session before credentials change or exec occurs.
#[cfg(target_os = "illumos")]
unsafe fn prepare_slave(fd: RawFd, cols: u16, rows: u16) -> bool {
    for module in [c"ptem", c"ldterm", c"ttcompat"] {
        // SAFETY: I_FIND reads the NUL-terminated module name from a static
        // C string literal that outlives the call.
        match unsafe { libc::ioctl(fd, libc::I_FIND, module.as_ptr()) } {
            1 => {}
            // SAFETY: I_PUSH reads the same static NUL-terminated module name.
            0 if unsafe { libc::ioctl(fd, libc::I_PUSH, module.as_ptr()) } == 0 => {}
            _ => return false,
        }
    }
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ reads one winsize from `size`, a live local.
    unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &size) == 0 }
}

#[cfg(target_os = "linux")]
unsafe fn child_errno() -> libc::c_int {
    // SAFETY: __errno_location has no preconditions.
    let slot = unsafe { libc::__errno_location() };
    // SAFETY: `slot` is this thread's errno, valid for reads for the life of
    // the thread.
    unsafe { *slot }
}
#[cfg(target_os = "freebsd")]
unsafe fn child_errno() -> libc::c_int {
    // SAFETY: __error has no preconditions.
    let slot = unsafe { libc::__error() };
    // SAFETY: `slot` is this thread's errno, valid for reads for the life of
    // the thread.
    unsafe { *slot }
}
#[cfg(target_os = "illumos")]
unsafe fn child_errno() -> libc::c_int {
    // SAFETY: ___errno has no preconditions.
    let slot = unsafe { libc::___errno() };
    // SAFETY: `slot` is this thread's errno, valid for reads for the life of
    // the thread.
    unsafe { *slot }
}

unsafe fn child_failed(fd: RawFd) -> ! {
    // SAFETY: the caller is the post-fork child, whose thread-local errno
    // holds the failed call's result.
    let errno = unsafe { child_errno() };
    // SAFETY: the caller is the post-fork child, so exiting with _exit is the
    // intended end of this process.
    unsafe { child_failed_with(fd, errno) }
}

unsafe fn child_failed_with(fd: RawFd, errno: libc::c_int) -> ! {
    // SAFETY: write reads exactly size_of::<c_int>() bytes from `errno`, a live
    // local of that size; write is async-signal-safe after fork.
    unsafe {
        libc::write(
            fd,
            (&raw const errno).cast::<libc::c_void>(),
            size_of::<libc::c_int>(),
        )
    };
    // SAFETY: _exit ends only the post-fork child without running parent
    // destructors or atexit handlers, as the caller's contract requires.
    unsafe { libc::_exit(127) }
}
