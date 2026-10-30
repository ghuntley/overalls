/// The C boundary kept a plain process-level alarm as the hard stop; no
/// re-locking handler exists here, so a bounded `alarm(2)` stays cheapest.
pub(super) fn alarm_after_two_seconds() {
    unsafe {
        libc::alarm(2);
    }
}
