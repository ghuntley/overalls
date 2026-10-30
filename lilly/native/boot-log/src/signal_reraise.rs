/// @cc [owner:ghuntley,label:recovery] boot-log-signal-reraise-shim
/// Terminating by the child's signal requires restoring the default
/// disposition and raising it; libc declares both calls unsafe-signatured
/// so the confinement is exactly this two-call shim with the raw signal
/// number as the only input.
pub(super) fn re_raise(signal: libc::c_int) {
    unsafe {
        libc::signal(signal, libc::SIG_DFL);
        libc::raise(signal);
    }
}
