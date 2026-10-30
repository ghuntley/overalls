/// @cc [owner:ghuntley,label:recovery] boot-log-signal-reraise-shim
/// Terminating by the child's signal requires restoring the default
/// disposition and raising it; libc declares both calls unsafe-signatured
/// so the confinement is exactly this two-call shim with the raw signal
/// number as the only input.
pub(super) fn re_raise(signal: libc::c_int) {
    // SAFETY: signal takes an integer signal number and the SIG_DFL constant;
    // no Rust handler or memory is involved, and an invalid number only fails.
    unsafe {
        libc::signal(signal, libc::SIG_DFL);
    }
    // SAFETY: raise takes an integer signal number and touches no memory.
    unsafe {
        libc::raise(signal);
    }
}
