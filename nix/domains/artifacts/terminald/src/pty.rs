//! PTY session processes with full passwd-identity execution.
use std::ffi::CString;
use std::io;
use std::os::unix::io::{FromRawFd, IntoRawFd, OwnedFd, RawFd};

pub(crate) struct UserInfo {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub groups: Vec<u32>,
    pub shell: CString,
    pub home: CString,
}

/// The PTY master descriptor a session pumps and writes.
pub(crate) type Master = RawFd;

pub(crate) struct Spawned {
    pub master: Master,
    pub pid: i32,
}

/// Outcome of a bounded master readiness wait.
pub(crate) enum Ready {
    Data,
    Timeout,
    Interrupted,
    Failed,
}

/// Outcome of one master read.
pub(crate) enum Read {
    Data(usize),
    Eof,
    Interrupted,
    WouldBlock,
    /// EIO: the slave is not (or no longer) open. Before the child has opened it
    /// this is the startup race the pump retries.
    SlaveClosed,
    Failed,
}

/// Wait up to `millis` for master output.
pub(crate) fn wait_readable(master: &Master, millis: i32) -> Ready {
    let mut ready = libc::pollfd {
        fd: *master,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: poll(2) reads and updates exactly one pollfd (nfds = 1) at
    // `ready`, a live local.
    let polled = unsafe { libc::poll(&raw mut ready, 1, millis) };
    if polled == 0 {
        return Ready::Timeout;
    }
    if polled < 0 {
        if io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            return Ready::Interrupted;
        }
        return Ready::Failed;
    }
    Ready::Data
}

/// One master read.
pub(crate) fn read(master: &Master, buf: &mut [u8]) -> Read {
    // SAFETY: `buf` is a live exclusive slice, so read(2) may store up to
    // `buf.len()` bytes at its start.
    let read = unsafe { libc::read(*master, buf.as_mut_ptr().cast::<libc::c_void>(), buf.len()) };
    if read == 0 {
        return Read::Eof;
    }
    if read > 0 {
        return Read::Data(read.cast_unsigned());
    }
    match io::Error::last_os_error().raw_os_error().unwrap_or(0) {
        libc::EINTR => Read::Interrupted,
        error if error == libc::EAGAIN || error == libc::EWOULDBLOCK => Read::WouldBlock,
        libc::EIO => Read::SlaveClosed,
        _ => Read::Failed,
    }
}

/// Write all input bytes to the master, retrying interrupted writes.
pub(crate) fn write_input(master: &Master, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        // SAFETY: `data` is a live slice, so write(2) may read `data.len()` bytes.
        let written =
            unsafe { libc::write(*master, data.as_ptr().cast::<libc::c_void>(), data.len()) };
        if written > 0 {
            data = &data[written.cast_unsigned()..];
            continue;
        }
        if written < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Explicit kill: SIGKILL the session's process group and leader.
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "shares the platform-neutral signature of the Windows ConPTY master"
)]
pub(crate) fn kill(_master: &Master, pid: i32) {
    // SAFETY: kill(2) takes integers only and touches no memory; the leader
    // stays unreaped until retirement, so `pid` cannot have been reused.
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    // SAFETY: as above, `pid` is this session's still-unreaped leader.
    unsafe { libc::kill(pid, libc::SIGKILL) };
}

/// Retirement: hang up the group, kill and reap the leader, close the master.
/// The PID stays reserved until this reap, so earlier signals cannot hit reuse.
pub(crate) fn retire(master: &Master, pid: i32) {
    // SAFETY: kill(2) takes integers only and touches no memory; the leader
    // stays unreaped until the waitpid below, so `pid` cannot have been reused.
    unsafe { libc::kill(-pid, libc::SIGHUP) };
    // SAFETY: as above, `pid` is this session's still-unreaped leader.
    unsafe { libc::kill(pid, libc::SIGKILL) };
    let mut status = 0;
    loop {
        // SAFETY: waitpid(2) writes one int to `status`, a live local.
        let waited = unsafe { libc::waitpid(pid, &raw mut status, 0) };
        if waited >= 0 || io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            break;
        }
    }
    // SAFETY: close(2) touches no memory; retirement runs once per session,
    // so the master is closed exactly once.
    unsafe { libc::close(*master) };
}

/// @cc [owner:ghuntley,label:security;capacity] terminal-user-inventory-bounded
/// User inventory MUST contain only existing passwd names with usable shells;
/// it MUST NOT create accounts, expose password fields or read unbounded files.
pub(crate) fn users() -> io::Result<Vec<String>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open("/etc/passwd")?
        .take(262_145)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 262_144 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| io::ErrorKind::InvalidData)?;
    let mut users: Vec<String> = text
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split(':').collect();
            if fields.len() != 7 || fields[0].is_empty() || fields[0].len() > 64 {
                return None;
            }
            let shell = fields[6];
            if !shell.starts_with('/') || shell.ends_with("/nologin") || shell.ends_with("/false") {
                return None;
            }
            Some(fields[0].to_owned())
        })
        .collect();
    users.sort();
    users.dedup();
    if let Some(index) = users.iter().position(|name| name == "root") {
        users.swap(0, index);
    }
    users.truncate(64);
    Ok(users)
}

struct Passwd {
    name: Vec<u8>,
    uid: u32,
    gid: u32,
    shell: Vec<u8>,
    home: Vec<u8>,
}

fn lookup_passwd(name: &str) -> Option<Passwd> {
    let cname = CString::new(name).ok()?;
    let mut buffer = vec![0u8; 4096];
    // SAFETY: passwd is plain C data; all-zero (null pointers) is valid.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: `cname` is NUL-terminated; `entry`, `result` and the
    // `buffer.len()`-byte `buffer` are live locals getpwnam_r may write.
    let status = unsafe {
        libc::getpwnam_r(
            cname.as_ptr(),
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
            unsafe { std::ffi::CStr::from_ptr(pointer) }
                .to_bytes()
                .to_vec()
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

fn supplementary_groups(name: &str, primary: u32) -> Vec<u32> {
    let Ok(body) = std::fs::read_to_string("/etc/group") else {
        return vec![primary];
    };
    let mut groups = vec![primary];
    for line in body.lines() {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 4 {
            continue;
        }
        let Ok(gid) = fields[2].parse::<u32>() else {
            continue;
        };
        if gid == primary {
            continue;
        }
        if fields[3].split(',').any(|member| member == name) {
            groups.push(gid);
        }
    }
    groups.sort_unstable();
    groups.dedup();
    groups
}

/// @cc [owner:ghuntley,label:security] resolved-identity-before-fork
/// `resolve` MUST fully resolve uid, gid, supplementary groups, shell and home
/// before any fork; the child MUST only issue async-signal-safe calls between
/// fork and execve.
pub(crate) fn resolve(name: &str) -> Option<UserInfo> {
    let entry = lookup_passwd(name)?;
    #[cfg(test)]
    let entry = {
        let mut test_entry = entry;
        if name == current_user_name() {
            if let Ok(shell) = std::env::var("TERMINALD_TEST_SHELL") {
                test_entry.shell = shell.into_bytes();
            }
            test_entry.home = b"/tmp".to_vec();
        }
        test_entry
    };
    if entry.shell.is_empty() || entry.home.is_empty() {
        return None;
    }
    Some(UserInfo {
        name: String::from_utf8(entry.name.clone()).ok()?,
        uid: entry.uid,
        gid: entry.gid,
        groups: supplementary_groups(name, entry.gid),
        shell: CString::new(entry.shell).ok()?,
        home: CString::new(entry.home).ok()?,
    })
}

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
    unsafe { std::ffi::CStr::from_ptr(name) }
        .to_string_lossy()
        .into_owned()
}

/// @cc [owner:ghuntley,label:security] session-credentials-and-environment
/// The child MUST become a session leader with the slave as its controlling
/// terminal, apply every resolved credential before exec, and start in the home
/// directory with TERM from the client, COLORTERM=truecolor and a UTF-8 locale.
/// Every PTY setup call MUST be checked and descriptors other than stdio MUST
/// close on exec. EOF alone confirms exec; interrupted status reads MUST retry.
#[expect(
    clippy::too_many_lines,
    reason = "fork and the async-signal-safe child sequence must stay in one frame"
)]
pub(crate) fn spawn(user: &UserInfo, term: &str, cols: u16, rows: u16) -> io::Result<Spawned> {
    // SAFETY: posix_openpt takes flags only and touches no memory.
    let master = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    if master < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `master` is a freshly opened descriptor that nothing else owns.
    let owned_master = unsafe { OwnedFd::from_raw_fd(master) };
    // SAFETY: grantpt and unlockpt take the open master descriptor only.
    if unsafe { libc::grantpt(master) } != 0 || unsafe { libc::unlockpt(master) } != 0 {
        let error = io::Error::last_os_error();
        return Err(error);
    }
    let slave = slave_name(master)?;
    #[cfg(not(target_os = "illumos"))]
    set_winsize(&master, cols, rows)?;
    let argv0 = login_name(&user.shell);
    let home = user.home.clone();
    let arguments = [argv0.clone()];
    let mut environment = vec![
        format!("TERM={term}"),
        "COLORTERM=truecolor".to_string(),
        "LANG=C.UTF-8".to_string(),
        format!("HOME={}", home.to_string_lossy()),
        format!("USER={}", user.name),
        format!("LOGNAME={}", user.name),
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin".to_string(),
    ];
    let env_c: Vec<CString> = environment
        .drain(..)
        .map(|entry| {
            CString::new(entry)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "environment"))
        })
        .collect::<Result<_, _>>()?;
    let argv: Vec<*const libc::c_char> = arguments
        .iter()
        .map(|a| a.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    let envp: Vec<*const libc::c_char> = env_c
        .iter()
        .map(|e| e.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    let groups = user.groups.clone();
    #[cfg(target_os = "linux")]
    let group_count = groups.len();
    #[cfg(any(target_os = "freebsd", target_os = "illumos"))]
    let group_count: libc::c_int = groups.len().try_into().map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidInput, "too many supplementary groups")
    })?;
    let descriptor_bound = child_descriptor_bound()?;
    let gid = user.gid;
    let uid = user.uid;
    let mut status_pipe = [0; 2];
    // SAFETY: pipe2(2) writes two descriptors into `status_pipe`, a live
    // two-element array.
    if unsafe { libc::pipe2(status_pipe.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        let error = io::Error::last_os_error();
        return Err(error);
    }
    // SAFETY: every value the child uses (identity, argv, envp, slave name,
    // descriptor bound) was built before fork; the child below makes only
    // async-signal-safe calls until execve or _exit.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: close(2) touches no memory; no child exists to share the pipe.
        unsafe { libc::close(status_pipe[0]) };
        // SAFETY: close(2) touches no memory; no child exists to share the pipe.
        unsafe { libc::close(status_pipe[1]) };
        return Err(error);
    }
    if pid == 0 {
        #[expect(
            clippy::multiple_unsafe_ops_per_block,
            reason = "the post-fork child is one async-signal-safe sequence ending in \
                      execve or _exit, with one shared invariant"
        )]
        // SAFETY: this is the post-fork child of a multithreaded parent. Every
        // call is async-signal-safe and allocates nothing: the argv, envp,
        // group and path pointers were built before fork and stay valid in
        // this copy of the address space; `empty` is a live local sigset;
        // every failure reports errno through the CLOEXEC status pipe and
        // ends the child with _exit, so control never returns to the parent's
        // Rust code.
        unsafe {
            libc::close(status_pipe[0]);
            // The child may not inherit another session's transport or future daemon
            // descriptors, even if a library opened one without O_CLOEXEC.
            if protect_child_descriptors(descriptor_bound) != 0 || libc::setsid() < 0 {
                child_failed(status_pipe[1]);
            }
            let slave_fd = libc::open(slave.as_ptr(), libc::O_RDWR);
            if slave_fd < 0 {
                child_failed(status_pipe[1]);
            }
            if !prepare_slave(slave_fd, cols, rows)
                || !controlling_terminal(slave_fd)
                || libc::dup2(slave_fd, 0) < 0
                || libc::dup2(slave_fd, 1) < 0
                || libc::dup2(slave_fd, 2) < 0
            {
                child_failed(status_pipe[1]);
            }
            if slave_fd > 2 {
                libc::close(slave_fd);
            }
            libc::close(master);
            let empty: libc::sigset_t = std::mem::zeroed();
            let mask_error =
                libc::pthread_sigmask(libc::SIG_SETMASK, &raw const empty, std::ptr::null_mut());
            if mask_error != 0 {
                child_failed_with(status_pipe[1], mask_error);
            }
            for signal in 1..=31 {
                if signal != libc::SIGKILL
                    && signal != libc::SIGSTOP
                    && libc::signal(signal, libc::SIG_DFL) == libc::SIG_ERR
                {
                    child_failed(status_pipe[1]);
                }
            }
            if libc::geteuid() == 0 {
                if libc::setgroups(group_count, groups.as_ptr()) != 0
                    || libc::setgid(gid) != 0
                    || libc::setuid(uid) != 0
                {
                    child_failed(status_pipe[1]);
                }
            } else if libc::getuid() != uid || libc::getgid() != gid {
                child_failed_with(status_pipe[1], libc::EPERM);
            }
            if libc::chdir(home.as_ptr()) != 0 {
                child_failed(status_pipe[1]);
            }
            libc::execve(user.shell.as_ptr(), argv.as_ptr(), envp.as_ptr());
            child_failed(status_pipe[1]);
        }
    }
    // SAFETY: close(2) touches no memory; the parent closes its copy of the
    // write end once so EOF can confirm exec.
    unsafe { libc::close(status_pipe[1]) };
    let mut child_errno: libc::c_int = 0;
    let read = loop {
        // SAFETY: read(2) stores at most size_of::<c_int>() bytes into
        // `child_errno`, a live c_int.
        let result = unsafe {
            libc::read(
                status_pipe[0],
                (&raw mut child_errno).cast::<libc::c_void>(),
                size_of::<libc::c_int>(),
            )
        };
        if result < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        break result;
    };
    let error = if read < 0 {
        io::Error::last_os_error()
    } else if read.cast_unsigned() == size_of::<libc::c_int>() {
        io::Error::from_raw_os_error(child_errno)
    } else {
        io::Error::new(io::ErrorKind::InvalidData, "incomplete child status")
    };
    // SAFETY: close(2) touches no memory; the read end is closed once here.
    unsafe { libc::close(status_pipe[0]) };
    if read != 0 {
        // SAFETY: kill(2) touches no memory; `pid` is our unreaped child.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        loop {
            // SAFETY: waitpid(2) with a null status pointer writes nothing.
            let waited = unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) };
            if waited >= 0 || io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                break;
            }
        }
        return Err(error);
    }
    Ok(Spawned {
        master: owned_master.into_raw_fd(),
        pid,
    })
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

#[cfg(not(target_os = "illumos"))]
fn slave_name(master: RawFd) -> io::Result<CString> {
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
    Ok(unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr().cast()) }.to_owned())
}

/// @cc [owner:ghuntley,label:security] illumos-terminal-slave-name
/// The pinned illumos libc lacks `ptsname_r`. Its ptsname buffer MUST be copied
/// while holding the daemon's shared ptsname mutex before fork; no other daemon
/// call site may use ptsname without that same lock.
#[cfg(target_os = "illumos")]
fn slave_name(master: RawFd) -> io::Result<CString> {
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
    Ok(unsafe { std::ffi::CStr::from_ptr(pointer) }.to_owned())
}

#[cfg(not(target_os = "illumos"))]
#[expect(
    clippy::unnecessary_wraps,
    reason = "shares the signature of the illumos variant, which can refuse a limit"
)]
fn child_descriptor_bound() -> io::Result<i32> {
    Ok(0)
}

/// @cc [owner:ghuntley,label:security] illumos-terminal-descriptor-limit
/// illumos PTY creation MUST reject an infinite or larger-than-1048576 hard
/// descriptor limit before fork. The child MUST mark every descriptor below
/// the inherited hard limit close-on-exec using async-signal-safe calls only;
/// libc closefrom/fdwalk MUST NOT run in a multithreaded post-fork child.
#[cfg(target_os = "illumos")]
fn child_descriptor_bound() -> io::Result<i32> {
    // SAFETY: rlimit is plain integer data; all-zero is valid.
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    // SAFETY: getrlimit(2) writes one rlimit to `limit`, a live local.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &raw mut limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if limit.rlim_max > 1_048_576 {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "unbounded descriptor limit",
        ));
    }
    i32::try_from(limit.rlim_max)
        .map_err(|_| io::Error::new(io::ErrorKind::Unsupported, "invalid descriptor limit"))
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

fn login_name(shell: &CString) -> CString {
    let bytes = shell.to_bytes();
    let base = match bytes.iter().rposition(|b| *b == b'/') {
        Some(index) => &bytes[index + 1..],
        None => bytes,
    };
    let mut name = Vec::with_capacity(base.len() + 1);
    name.push(b'-');
    name.extend_from_slice(base);
    CString::new(name).unwrap_or_else(|_| shell.clone())
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "shares the platform-neutral signature of the Windows ConPTY master"
)]
pub(crate) fn set_winsize(master: &Master, cols: u16, rows: u16) -> io::Result<()> {
    let master = *master;
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ reads one winsize from `size`, a live local.
    if unsafe { libc::ioctl(master, libc::TIOCSWINSZ, &size) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_root_and_groups() {
        let root = resolve("root").expect("root exists in build environments");
        assert_eq!(root.uid, 0);
        assert_eq!(root.gid, 0);
        assert!(root.groups.contains(&0));
        assert!(!root.shell.to_bytes().is_empty(), "root has a login shell");
    }

    #[test]
    fn unknown_users_resolve_to_none() {
        assert!(resolve("no-such-terminald-user-xyz").is_none());
    }

    #[test]
    fn group_parsing_finds_membership() {
        let groups = supplementary_groups("root", 0);
        assert!(groups.contains(&0));
        assert!(groups.iter().all(|gid| *gid != 4_294_967_295));
    }

    #[test]
    #[allow(
        clippy::print_stderr,
        reason = "the skip notice explains why the test passed without its environment"
    )]
    fn spawn_runs_login_shell_with_environment() {
        let user = resolve(&current_user_name()).expect("current user");
        let spawned = spawn(&user, "xterm-test", 97, 31).expect("spawn pty session");
        // SAFETY: winsize is plain integer data; all-zero is valid.
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        assert_eq!(
            // SAFETY: TIOCGWINSZ writes one winsize to `size`, a live local.
            unsafe { libc::ioctl(spawned.master, libc::TIOCGWINSZ, &mut size) },
            0
        );
        assert_eq!((size.ws_row, size.ws_col), (31, 97));
        let script = "printf 'MARK1=%s %s %s\\n' \"$TERM\" \"$COLORTERM\" \"$HOME\"; exit 0\n";
        write_all(spawned.master, script.as_bytes());
        let output = read_until_closed(spawned.master);
        let mut status = 0;
        // SAFETY: waitpid(2) writes one int to `status`, a live local.
        unsafe { libc::waitpid(spawned.pid, &raw mut status, 0) };
        // SAFETY: close(2) touches no memory; the test owns the master.
        unsafe { libc::close(spawned.master) };
        if libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 127 {
            eprintln!(
                "skipping: user shell {} is not executable in this environment",
                user.shell.to_string_lossy()
            );
            return;
        }
        let text = String::from_utf8_lossy(&output);
        assert!(
            text.contains("xterm-test truecolor"),
            "PTY output lacks TERM and COLORTERM ({} bytes, contents withheld)",
            output.len()
        );
        assert!(
            text.contains(&user.home.to_string_lossy().to_string()),
            "PTY output lacks HOME ({} bytes, contents withheld)",
            output.len()
        );
    }

    #[test]
    fn login_shell_does_not_inherit_unmarked_daemon_descriptors() {
        use std::os::fd::AsRawFd;
        let private = std::fs::File::open("/dev/null").unwrap();
        // SAFETY: F_DUPFD takes integer arguments only and touches no memory.
        let inherited = unsafe { libc::fcntl(private.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(inherited >= 200);
        // SAFETY: `inherited` is a fresh duplicate that nothing else owns.
        let guard = unsafe { OwnedFd::from_raw_fd(inherited) };
        assert_eq!(
            // SAFETY: F_GETFD reads descriptor flags only.
            unsafe { libc::fcntl(inherited, libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        let user = resolve(&current_user_name()).unwrap();
        let spawned = spawn(&user, "xterm-256color", 80, 24).unwrap();
        let script = format!(
            "test ! -e /proc/self/fd/{inherited} && printf 'DESCRIPTOR_%s\\n' CLOSED; exit\n"
        );
        write_all(spawned.master, script.as_bytes());
        let output = read_until_closed(spawned.master);
        // SAFETY: waitpid(2) with a null status pointer writes nothing.
        unsafe { libc::waitpid(spawned.pid, std::ptr::null_mut(), 0) };
        // SAFETY: close(2) touches no memory; the test owns the master.
        unsafe { libc::close(spawned.master) };
        drop(guard);
        assert!(output
            .windows(b"DESCRIPTOR_CLOSED".len())
            .any(|part| part == b"DESCRIPTOR_CLOSED"));
    }

    #[test]
    #[allow(
        clippy::print_stderr,
        reason = "the skip notice explains why the test passed without its environment"
    )]
    fn non_root_cannot_spawn_as_another_identity() {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipping: test requires a non-root runner");
            return;
        }
        let target = UserInfo {
            name: "root".to_string(),
            uid: 0,
            gid: 0,
            groups: vec![0],
            shell: CString::new("/bin/sh").unwrap(),
            home: CString::new("/").unwrap(),
        };
        let Err(error) = spawn(&target, "xterm", 80, 24) else {
            panic!("credential transition unexpectedly succeeded")
        };
        assert_eq!(error.raw_os_error(), Some(libc::EPERM));
    }

    #[test]
    fn pre_exec_failure_is_reported_to_parent() {
        let mut user = resolve(&current_user_name()).expect("current user");
        user.shell = CString::new("/no/such/terminald-shell").unwrap();
        let Err(error) = spawn(&user, "xterm", 80, 24) else {
            panic!("exec unexpectedly succeeded")
        };
        assert_eq!(error.raw_os_error(), Some(libc::ENOENT));
    }

    fn write_all(fd: RawFd, mut data: &[u8]) {
        while !data.is_empty() {
            // SAFETY: `data` is a live slice, so write(2) may read `data.len()` bytes.
            let written =
                unsafe { libc::write(fd, data.as_ptr().cast::<libc::c_void>(), data.len()) };
            if written <= 0 {
                return;
            }
            data = &data[written.cast_unsigned()..];
        }
    }

    fn read_until_closed(fd: RawFd) -> Vec<u8> {
        let mut out = Vec::new();
        let mut scratch = [0u8; 4096];
        let mut opened = false;
        let started = std::time::Instant::now();
        loop {
            let mut poller = libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: poll(2) reads and updates one pollfd at `poller`, a live local.
            unsafe { libc::poll(&raw mut poller, 1, 250) };
            // SAFETY: read(2) stores at most `scratch.len()` bytes into
            // `scratch`, a live local array.
            let read = unsafe {
                libc::read(
                    fd,
                    scratch.as_mut_ptr().cast::<libc::c_void>(),
                    scratch.len(),
                )
            };
            if read > 0 {
                opened = true;
                out.extend_from_slice(&scratch[..read.cast_unsigned()]);
                continue;
            }
            let grace = !opened && started.elapsed() < std::time::Duration::from_secs(10);
            if read == 0 && grace {
                continue;
            }
            if read < 0 {
                let error = io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if error == libc::EINTR || (error == libc::EIO && grace) {
                    continue;
                }
            }
            break;
        }
        out
    }
}
