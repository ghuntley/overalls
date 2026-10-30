use std::os::fd::RawFd;

/// @cc [owner:ghuntley,label:security] namespace-setns-shim-only-unsafe
/// setns is unsafe-signatured in libc. Confinement: the raw descriptor is
/// a live /proc namespace handle obtained by the caller mid-sweep, the
/// namespace class is fixed to mount, and nothing else crosses the
/// boundary.
pub(super) fn enter(ns: RawFd) -> Result<(), ()> {
    // SAFETY: setns only reads the integer descriptor and namespace class;
    // an invalid or closed descriptor fails with EBADF/EINVAL, never UB.
    match unsafe { libc::setns(ns, libc::CLONE_NEWNS) } {
        0 => Ok(()),
        _ => Err(()),
    }
}
