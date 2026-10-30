use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
use std::os::unix::process::CommandExt;
use std::process::Command;

/// @cc [owner:ghuntley,label:security] serve-child-pins-and-purges
/// The fixed worker resets dispositions and gains a parent-death fence;
/// every other descriptor the helper owns either is CLOEXEC'd at receipt
/// time or arrives through the std Stdio mapping only. Unsafe-declared
/// calls stay confined to this hook.
pub(super) fn serve_child(command: &mut Command, parent: Pid) {
    let hook = move || {
        if set_parent_process_death_signal(Some(Signal::KILL)).is_err() || getppid() != Some(parent)
        {
            return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        }
        // SAFETY: SIG_DFL installs no handler; signal is async-signal-safe.
        unsafe { libc::signal(libc::SIGTERM, libc::SIG_DFL) };
        // SAFETY: as above.
        unsafe { libc::signal(libc::SIGINT, libc::SIG_DFL) };
        // SAFETY: as above.
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
        Ok(())
    };
    // SAFETY: the hook runs in the forked child before exec. It captures one
    // integer, allocates nothing, takes no locks and makes only
    // async-signal-safe system calls (prctl, getppid, signal).
    unsafe { command.pre_exec(hook) };
}
