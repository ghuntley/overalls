/// The C boundary kept a plain process-level alarm as the hard stop; no
/// re-locking handler exists here, so a bounded `alarm(2)` stays cheapest.
pub(super) fn alarm_after_two_seconds() {
    // SAFETY: alarm takes one integer, touches no memory and only arms the
    // process timer.
    unsafe {
        libc::alarm(2);
    }
}
