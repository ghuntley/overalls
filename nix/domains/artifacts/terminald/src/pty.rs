//! PTY session processes with full passwd-identity execution.
use std::ffi::CString;
use std::io;
use std::os::unix::io::{FromRawFd, IntoRawFd, OwnedFd, RawFd};

pub struct UserInfo {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub groups: Vec<u32>,
    pub shell: CString,
    pub home: CString,
}

/// The PTY master descriptor a session pumps and writes.
pub type Master = RawFd;

pub struct Spawned {
    pub master: Master,
    pub pid: i32,
}

/// Outcome of a bounded master readiness wait.
pub enum Ready {
    Data,
    Timeout,
    Interrupted,
    Failed,
}

/// Outcome of one master read.
pub enum Read {
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
pub fn wait_readable(master: &Master, millis: i32) -> Ready {
    let mut ready = libc::pollfd {
        fd: *master,
        events: libc::POLLIN,
        revents: 0,
    };
    let polled = unsafe { libc::poll(&mut ready, 1, millis) };
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
pub fn read(master: &Master, buf: &mut [u8]) -> Read {
    let read = unsafe { libc::read(*master, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
    if read == 0 {
        return Read::Eof;
    }
    if read > 0 {
        return Read::Data(read as usize);
    }
    match io::Error::last_os_error().raw_os_error().unwrap_or(0) {
        libc::EINTR => Read::Interrupted,
        error if error == libc::EAGAIN || error == libc::EWOULDBLOCK => Read::WouldBlock,
        libc::EIO => Read::SlaveClosed,
        _ => Read::Failed,
    }
}

/// Write all input bytes to the master, retrying interrupted writes.
pub fn write_input(master: &Master, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        let written =
            unsafe { libc::write(*master, data.as_ptr() as *const libc::c_void, data.len()) };
        if written > 0 {
            data = &data[written as usize..];
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
pub fn kill(_master: &Master, pid: i32) {
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    unsafe { libc::kill(pid, libc::SIGKILL) };
}

/// Retirement: hang up the group, kill and reap the leader, close the master.
/// The PID stays reserved until this reap, so earlier signals cannot hit reuse.
pub fn retire(master: &Master, pid: i32) {
    unsafe { libc::kill(-pid, libc::SIGHUP) };
    unsafe { libc::kill(pid, libc::SIGKILL) };
    let mut status = 0;
    loop {
        let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
        if waited >= 0 || io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            break;
        }
    }
    unsafe { libc::close(*master) };
}

/// @cc [owner:ghuntley,label:security;capacity] terminal-user-inventory-bounded
/// User inventory MUST contain only existing passwd names with usable shells;
/// it MUST NOT create accounts, expose password fields or read unbounded files.
pub fn users() -> io::Result<Vec<String>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open("/etc/passwd")?
        .take(262145)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 262144 {
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
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    let status = unsafe {
        libc::getpwnam_r(
            cname.as_ptr(),
            &mut entry,
            buffer.as_mut_ptr() as *mut libc::c_char,
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    unsafe {
        let copy = |pointer: *const libc::c_char| -> Vec<u8> {
            if pointer.is_null() {
                Vec::new()
            } else {
                std::ffi::CStr::from_ptr(pointer).to_bytes().to_vec()
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
}

fn supplementary_groups(name: &str, primary: u32) -> Vec<u32> {
    let body = match std::fs::read_to_string("/etc/group") {
        Ok(body) => body,
        Err(_) => return vec![primary],
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
pub fn resolve(name: &str) -> Option<UserInfo> {
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
pub fn current_user_name() -> String {
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        assert!(!entry.is_null(), "current uid must have a passwd entry");
        std::ffi::CStr::from_ptr((*entry).pw_name)
            .to_string_lossy()
            .into_owned()
    }
}

/// @cc [owner:ghuntley,label:security] session-credentials-and-environment
/// The child MUST become a session leader with the slave as its controlling
/// terminal, apply every resolved credential before exec, and start in the home
/// directory with TERM from the client, COLORTERM=truecolor and a UTF-8 locale.
/// Every PTY setup call MUST be checked and descriptors other than stdio MUST
/// close on exec. EOF alone confirms exec; interrupted status reads MUST retry.
pub fn spawn(user: &UserInfo, term: &str, cols: u16, rows: u16) -> io::Result<Spawned> {
    let master = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    if master < 0 {
        return Err(io::Error::last_os_error());
    }
    let owned_master = unsafe { OwnedFd::from_raw_fd(master) };
    if unsafe { libc::grantpt(master) } != 0 || unsafe { libc::unlockpt(master) } != 0 {
        let error = io::Error::last_os_error();
        return Err(error);
    }
    let slave = slave_name(master)?;
    #[cfg(not(target_os = "illumos"))]
    set_winsize(&master, cols, rows)?;
    let argv0 = login_name(&user.shell);
    let home = user.home.clone();
    let args = [argv0.clone()];
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
    let argv: Vec<*const libc::c_char> = args
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
    if unsafe { libc::pipe2(status_pipe.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        let error = io::Error::last_os_error();
        return Err(error);
    }
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        let error = io::Error::last_os_error();
        unsafe {
            libc::close(status_pipe[0]);
            libc::close(status_pipe[1]);
        }
        return Err(error);
    }
    if pid == 0 {
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
            let mask_error = libc::pthread_sigmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
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
    unsafe { libc::close(status_pipe[1]) };
    let mut child_errno: libc::c_int = 0;
    let read = loop {
        let result = unsafe {
            libc::read(
                status_pipe[0],
                &mut child_errno as *mut libc::c_int as *mut libc::c_void,
                std::mem::size_of::<libc::c_int>(),
            )
        };
        if result < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        break result;
    };
    let error = if read < 0 {
        io::Error::last_os_error()
    } else if read as usize == std::mem::size_of::<libc::c_int>() {
        io::Error::from_raw_os_error(child_errno)
    } else {
        io::Error::new(io::ErrorKind::InvalidData, "incomplete child status")
    };
    unsafe { libc::close(status_pipe[0]) };
    if read != 0 {
        unsafe { libc::kill(pid, libc::SIGKILL) };
        loop {
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
/// O_NOCTTY; TIOCSCTTY is unsupported. Every native child MUST verify that the
/// slave belongs to its own session before applying credentials or executing.
unsafe fn controlling_terminal(fd: RawFd) -> bool {
    #[cfg(not(target_os = "illumos"))]
    if libc::ioctl(fd, libc::TIOCSCTTY, 0 as libc::c_ulong) < 0 {
        return false;
    }
    libc::tcgetsid(fd) == libc::getpid()
}

#[cfg(not(target_os = "illumos"))]
fn slave_name(master: RawFd) -> io::Result<CString> {
    let mut buffer = [0_u8; 128];
    let status = unsafe { libc::ptsname_r(master, buffer.as_mut_ptr().cast(), buffer.len()) };
    if status > 0 {
        return Err(io::Error::from_raw_os_error(status));
    }
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr().cast()) }.to_owned())
}

/// @cc [owner:ghuntley,label:security] illumos-terminal-slave-name
/// The pinned illumos libc lacks ptsname_r. Its ptsname buffer MUST be copied
/// while holding the daemon's shared ptsname mutex before fork; no other daemon
/// call site may use ptsname without that same lock.
#[cfg(target_os = "illumos")]
fn slave_name(master: RawFd) -> io::Result<CString> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = LOCK
        .lock()
        .map_err(|_| io::Error::other("slave name lock unavailable"))?;
    let pointer = unsafe { libc::ptsname(master) };
    if pointer.is_null() {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { std::ffi::CStr::from_ptr(pointer) }.to_owned())
}

#[cfg(not(target_os = "illumos"))]
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
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
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
unsafe fn protect_child_descriptors(_bound: i32) -> libc::c_int {
    libc::syscall(
        libc::SYS_close_range,
        3u32,
        u32::MAX,
        libc::CLOSE_RANGE_CLOEXEC,
    ) as libc::c_int
}

#[cfg(target_os = "freebsd")]
unsafe fn protect_child_descriptors(_bound: i32) -> libc::c_int {
    libc::close_range(3, u32::MAX, libc::CLOSE_RANGE_CLOEXEC as libc::c_int)
}

#[cfg(target_os = "illumos")]
unsafe fn protect_child_descriptors(bound: i32) -> libc::c_int {
    for fd in 3..bound {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags < 0 {
            if child_errno() == libc::EBADF {
                continue;
            }
            return -1;
        }
        if libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) != 0 {
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
        match libc::ioctl(fd, libc::I_FIND, module.as_ptr()) {
            1 => {}
            0 if libc::ioctl(fd, libc::I_PUSH, module.as_ptr()) == 0 => {}
            _ => return false,
        }
    }
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    libc::ioctl(fd, libc::TIOCSWINSZ, &size) == 0
}

#[cfg(target_os = "linux")]
unsafe fn child_errno() -> libc::c_int {
    *libc::__errno_location()
}
#[cfg(target_os = "freebsd")]
unsafe fn child_errno() -> libc::c_int {
    *libc::__error()
}
#[cfg(target_os = "illumos")]
unsafe fn child_errno() -> libc::c_int {
    *libc::___errno()
}

unsafe fn child_failed(fd: RawFd) -> ! {
    let errno = child_errno();
    child_failed_with(fd, errno)
}

unsafe fn child_failed_with(fd: RawFd, errno: libc::c_int) -> ! {
    libc::write(
        fd,
        &errno as *const libc::c_int as *const libc::c_void,
        std::mem::size_of::<libc::c_int>(),
    );
    libc::_exit(127)
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

pub fn set_winsize(master: &Master, cols: u16, rows: u16) -> io::Result<()> {
    let master = *master;
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
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
        assert!(!root.shell.to_bytes().is_empty());
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
    #[allow(clippy::print_stderr)]
    fn spawn_runs_login_shell_with_environment() {
        let user = resolve(&current_user_name()).expect("current user");
        let spawned = spawn(&user, "xterm-test", 97, 31).expect("spawn pty session");
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { libc::ioctl(spawned.master, libc::TIOCGWINSZ, &mut size) },
            0
        );
        assert_eq!((size.ws_row, size.ws_col), (31, 97));
        let script = "printf 'MARK1=%s %s %s\\n' \"$TERM\" \"$COLORTERM\" \"$HOME\"; exit 0\n";
        write_all(spawned.master, script.as_bytes());
        let output = read_until_closed(spawned.master);
        let mut status = 0;
        unsafe { libc::waitpid(spawned.pid, &mut status, 0) };
        unsafe { libc::close(spawned.master) };
        if libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 127 {
            eprintln!(
                "skipping: user shell {} is not executable in this environment",
                user.shell.to_string_lossy()
            );
            return;
        }
        let text = String::from_utf8_lossy(&output);
        assert!(text.contains("xterm-test truecolor"), "saw: {text:?}");
        assert!(
            text.contains(&user.home.to_string_lossy().to_string()),
            "saw: {text:?}"
        );
    }

    #[test]
    fn login_shell_does_not_inherit_unmarked_daemon_descriptors() {
        use std::os::fd::AsRawFd;
        let private = std::fs::File::open("/dev/null").unwrap();
        let inherited = unsafe { libc::fcntl(private.as_raw_fd(), libc::F_DUPFD, 200) };
        assert!(inherited >= 200);
        let guard = unsafe { OwnedFd::from_raw_fd(inherited) };
        assert_eq!(
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
        unsafe {
            libc::waitpid(spawned.pid, std::ptr::null_mut(), 0);
            libc::close(spawned.master);
        }
        drop(guard);
        assert!(output
            .windows(b"DESCRIPTOR_CLOSED".len())
            .any(|part| part == b"DESCRIPTOR_CLOSED"));
    }

    #[test]
    #[allow(clippy::print_stderr)]
    fn non_root_cannot_spawn_as_another_identity() {
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
        let error = match spawn(&target, "xterm", 80, 24) {
            Ok(_) => panic!("credential transition unexpectedly succeeded"),
            Err(error) => error,
        };
        assert_eq!(error.raw_os_error(), Some(libc::EPERM));
    }

    #[test]
    fn pre_exec_failure_is_reported_to_parent() {
        let mut user = resolve(&current_user_name()).expect("current user");
        user.shell = CString::new("/no/such/terminald-shell").unwrap();
        let error = match spawn(&user, "xterm", 80, 24) {
            Ok(_) => panic!("exec unexpectedly succeeded"),
            Err(error) => error,
        };
        assert_eq!(error.raw_os_error(), Some(libc::ENOENT));
    }

    fn write_all(fd: RawFd, mut data: &[u8]) {
        while !data.is_empty() {
            let written =
                unsafe { libc::write(fd, data.as_ptr() as *const libc::c_void, data.len()) };
            if written <= 0 {
                return;
            }
            data = &data[written as usize..];
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
            unsafe { libc::poll(&mut poller, 1, 250) };
            let read =
                unsafe { libc::read(fd, scratch.as_mut_ptr() as *mut libc::c_void, scratch.len()) };
            if read > 0 {
                opened = true;
                out.extend_from_slice(&scratch[..read as usize]);
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
