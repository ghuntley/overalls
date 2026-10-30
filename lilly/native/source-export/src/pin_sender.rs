use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
use std::os::unix::process::CommandExt;
use std::process::Command;

/// @cc [owner:ghuntley,label:recovery] source-export-pins-parent-fencing
/// The sender must not outlive its lease owner: set the parent-death signal
/// and verify the recorded parent before exec. The only unsafe-declared API
/// used is std's `pre_exec`; its body stays in safe typed rustix calls.
pub(super) fn pin(command: &mut Command, parent: Pid) {
    let hook = move || {
        if set_parent_process_death_signal(Some(Signal::KILL)).is_err() || getppid() != Some(parent)
        {
            return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        }
        // Runtime-ignored SIGPIPE must not outlive exec into senders.
        // SAFETY: SIG_DFL installs no handler; signal is async-signal-safe.
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
        Ok(())
    };
    // SAFETY: the hook runs in the forked child before exec. It captures one
    // integer, allocates nothing, takes no locks and makes only
    // async-signal-safe system calls (prctl, getppid, signal).
    unsafe { command.pre_exec(hook) };
}
