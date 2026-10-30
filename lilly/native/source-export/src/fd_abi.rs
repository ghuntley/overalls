use std::os::fd::BorrowedFd;

pub(super) fn control() -> BorrowedFd<'static> {
    unsafe { BorrowedFd::borrow_raw(3) }
}

pub(super) fn ack() -> BorrowedFd<'static> {
    unsafe { BorrowedFd::borrow_raw(4) }
}
