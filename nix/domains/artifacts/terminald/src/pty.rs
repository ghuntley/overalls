//! PTY session processes with full passwd-identity execution.
use crate::sys::pty::{self as sys_pty, Passwd};
use crate::sys::unix as sys;
use std::ffi::CString;
use std::io;
use std::os::unix::io::{AsRawFd, IntoRawFd, RawFd};

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
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "shares the platform-neutral signature of the Windows ConPTY master"
)]
pub(crate) fn wait_readable(master: &Master, millis: i32) -> Ready {
    let mut ready = libc::pollfd {
        fd: *master,
        events: libc::POLLIN,
        revents: 0,
    };
    let polled = sys::poll_one(&mut ready, millis);
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
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "shares the platform-neutral signature of the Windows ConPTY master"
)]
pub(crate) fn read(master: &Master, buf: &mut [u8]) -> Read {
    let read = sys::read(*master, buf);
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
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "shares the platform-neutral signature of the Windows ConPTY master"
)]
pub(crate) fn write_input(master: &Master, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        let written = sys::write(*master, data);
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
    // The leader stays unreaped until retirement, so `pid` cannot have been
    // reused.
    sys::kill(-pid, libc::SIGKILL);
    sys::kill(pid, libc::SIGKILL);
}

/// Retirement: hang up the group, kill and reap the leader, close the master.
/// The PID stays reserved until this reap, so earlier signals cannot hit reuse.
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "shares the platform-neutral signature of the Windows ConPTY master"
)]
pub(crate) fn retire(master: &Master, pid: i32) {
    // The leader stays unreaped until the waitpid below, so `pid` cannot have
    // been reused.
    sys::kill(-pid, libc::SIGHUP);
    sys::kill(pid, libc::SIGKILL);
    let mut status = 0;
    loop {
        let waited = sys::waitpid(pid, Some(&mut status), 0);
        if waited >= 0 || io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            break;
        }
    }
    // Retirement runs once per session, so the master is closed exactly once.
    sys::close(*master);
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

fn lookup_passwd(name: &str) -> Option<Passwd> {
    let cname = CString::new(name).ok()?;
    sys_pty::lookup_passwd(&cname)
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
    sys_pty::current_user_name()
}

/// @cc [owner:ghuntley,label:security] session-credentials-and-environment
/// The child MUST become a session leader with the slave as its controlling
/// terminal, apply every resolved credential before exec, and start in the home
/// directory with TERM from the client, COLORTERM=truecolor and a UTF-8 locale.
/// Every PTY setup call MUST be checked and descriptors other than stdio MUST
/// close on exec. EOF alone confirms exec; interrupted status reads MUST retry.
pub(crate) fn spawn(user: &UserInfo, term: &str, cols: u16, rows: u16) -> io::Result<Spawned> {
    let owned_master = sys_pty::open_master(libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC)?;
    let master = owned_master.as_raw_fd();
    if sys_pty::grantpt(master) != 0 || sys_pty::unlockpt(master) != 0 {
        let error = io::Error::last_os_error();
        return Err(error);
    }
    let slave = sys_pty::slave_name(master)?;
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
    let argv = sys_pty::CStringArray::new(&arguments);
    let envp = sys_pty::CStringArray::new(&env_c);
    let groups = user.groups.clone();
    #[cfg(target_os = "linux")]
    let child_groups = sys_pty::Groups::new(&groups);
    #[cfg(any(target_os = "freebsd", target_os = "illumos"))]
    let child_groups = sys_pty::Groups::new(&groups)?;
    let descriptor_bound = child_descriptor_bound()?;
    let gid = user.gid;
    let uid = user.uid;
    let mut status_pipe = [0; 2];
    if sys_pty::pipe2(&mut status_pipe, libc::O_CLOEXEC) != 0 {
        let error = io::Error::last_os_error();
        return Err(error);
    }
    let pid = sys_pty::fork_session(&sys_pty::Child {
        status_read: status_pipe[0],
        status_write: status_pipe[1],
        descriptor_bound,
        slave: &slave,
        master,
        cols,
        rows,
        groups: child_groups,
        gid,
        uid,
        home: &home,
        shell: &user.shell,
        argv: &argv,
        envp: &envp,
    });
    if pid < 0 {
        let error = io::Error::last_os_error();
        // No child exists to share the pipe.
        sys::close(status_pipe[0]);
        sys::close(status_pipe[1]);
        return Err(error);
    }
    // The parent closes its copy of the write end once so EOF can confirm exec.
    sys::close(status_pipe[1]);
    let mut child_errno: libc::c_int = 0;
    let read = loop {
        let result = sys::read_c_int(status_pipe[0], &mut child_errno);
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
    // The read end is closed once here.
    sys::close(status_pipe[0]);
    if read != 0 {
        // `pid` is our unreaped child.
        sys::kill(pid, libc::SIGKILL);
        loop {
            let waited = sys::waitpid(pid, None, 0);
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
    let limit = sys_pty::descriptor_hard_limit()?;
    if limit > 1_048_576 {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "unbounded descriptor limit",
        ));
    }
    i32::try_from(limit)
        .map_err(|_| io::Error::new(io::ErrorKind::Unsupported, "invalid descriptor limit"))
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
    if sys::set_winsize(master, &size) < 0 {
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
        let mut size = libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        assert_eq!(sys::get_winsize(spawned.master, &mut size), 0);
        assert_eq!((size.ws_row, size.ws_col), (31, 97));
        let script = "printf 'MARK1=%s %s %s\\n' \"$TERM\" \"$COLORTERM\" \"$HOME\"; exit 0\n";
        write_all(spawned.master, script.as_bytes());
        let output = read_until_closed(spawned.master);
        let mut status = 0;
        sys::waitpid(spawned.pid, Some(&mut status), 0);
        // The test owns the master.
        sys::close(spawned.master);
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
        let guard = sys::duplicate_inheritable(private.as_raw_fd(), 200).unwrap();
        let inherited = guard.as_raw_fd();
        assert!(inherited >= 200);
        assert_eq!(sys::descriptor_flags(inherited) & libc::FD_CLOEXEC, 0);
        let user = resolve(&current_user_name()).unwrap();
        let spawned = spawn(&user, "xterm-256color", 80, 24).unwrap();
        let script = format!(
            "test ! -e /proc/self/fd/{inherited} && printf 'DESCRIPTOR_%s\\n' CLOSED; exit\n"
        );
        write_all(spawned.master, script.as_bytes());
        let output = read_until_closed(spawned.master);
        sys::waitpid(spawned.pid, None, 0);
        // The test owns the master.
        sys::close(spawned.master);
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
        if sys::geteuid() == 0 {
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
            let written = sys::write(fd, data);
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
            sys::poll_one(&mut poller, 250);
            let read = sys::read(fd, &mut scratch);
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
