use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
use std::os::unix::process::CommandExt;
use std::process::Command;

/// @cc [owner:ghuntley,label:security] transfer-pins-children-to-owner
/// Producer and consumer must not outlive the helper: set the parent-death
/// signal and verify the recorded parent before exec. A side given a uid
/// MUST drop every supplementary group, then its gid and uid (both that
/// uid), and set `no_new_privs` before exec; the parent-death signal MUST be
/// set after that credential change (which may clear it). Any failure aborts
/// the spawn.
/// The closure performs only async-signal-safe system calls.
pub(super) fn to_caller(command: &mut Command, parent: Pid, uid: Option<u32>) {
    let hook = move || {
        // Credentials change first, so the death signal is set on the
        // final credentials (a credential change may clear it).
        if let Some(uid) = uid {
            // SAFETY: a zero-length group list is never read, so the null
            // pointer is not dereferenced; setgroups is async-signal-safe.
            if unsafe { libc::setgroups(0, std::ptr::null()) } != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: setresgid takes plain integers and is async-signal-safe.
            if unsafe { libc::setresgid(uid, uid, uid) } != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: setresuid takes plain integers and is async-signal-safe.
            if unsafe { libc::setresuid(uid, uid, uid) } != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: PR_SET_NO_NEW_PRIVS takes integer arguments only and
            // prctl is async-signal-safe.
            if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
                return Err(std::io::Error::last_os_error());
            }
        }
        if set_parent_process_death_signal(Some(Signal::KILL)).is_err() || getppid() != Some(parent)
        {
            return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        }
        // SAFETY: SIG_DFL installs no handler, and signal is
        // async-signal-safe.
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
        Ok(())
    };
    // SAFETY: the hook runs in the forked child before exec. It captures only
    // two integers, allocates nothing, takes no locks and makes only
    // async-signal-safe system calls (setgroups, setresgid, setresuid, prctl,
    // getppid, signal).
    unsafe { command.pre_exec(hook) };
}
