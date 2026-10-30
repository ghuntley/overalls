use std::os::fd::BorrowedFd;

pub(super) fn control() -> BorrowedFd<'static> {
    // SAFETY: the Erlang port ABI opens fd 3 for this process before exec
    // and it stays open for the process lifetime; it is only ever borrowed.
    unsafe { BorrowedFd::borrow_raw(3) }
}

pub(super) fn ack() -> BorrowedFd<'static> {
    // SAFETY: as for fd 3, the port ABI keeps fd 4 open for the process
    // lifetime; it is only ever borrowed.
    unsafe { BorrowedFd::borrow_raw(4) }
}
