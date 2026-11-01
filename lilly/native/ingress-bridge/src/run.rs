use crate::native;
use crate::{finished, half_close_due, Direction, Overrun, Request};
use crate::{EXIT_IO, EXIT_OK, EXIT_SETUP, GO, READY};
use rustix::event::{PollFd, PollFlags};
use rustix::fs::OFlags;
use rustix::io::Errno;
use rustix::net::Shutdown;
use rustix::pipe::{pipe_with, splice, PipeFlags, SpliceFlags};
use std::os::fd::{AsFd, OwnedFd};

/// @cc [owner:ghuntley,label:security;isolation] bridge-custody
/// Before any byte moves, every descriptor MUST be a socket, and a given uid
/// MUST be applied (no supplementary groups, that gid and uid, `no_new_privs`).
/// An attached bridge then sets the parent-death signal and verifies the
/// recorded parent. A detached bridge (bridge-detached-handshake) sets none,
/// so it outlives hostd. Bytes move only between the two sockets through this
/// process's kernel pipes, never to stdout, stderr or a diagnostic. Any read
/// or write error closes both connections and exits nonzero.
pub fn run(request: &Request) -> u8 {
    let parent = rustix::process::getppid();
    let (Some(client), Some(guest)) = (native::adopt(request.client), native::adopt(request.guest))
    else {
        return EXIT_SETUP;
    };
    let control = match request.control {
        Some(fd) => match native::adopt(fd) {
            Some(control) if socket(&control) => Some(control),
            _ => return EXIT_SETUP,
        },
        None => None,
    };
    if !socket(&client) || !socket(&guest) {
        return EXIT_SETUP;
    }
    if let Some(uid) = request.uid {
        if native::drop_to(uid).is_err() {
            return EXIT_SETUP;
        }
    }
    if control.is_none()
        && (rustix::process::set_parent_process_death_signal(Some(rustix::process::Signal::KILL))
            .is_err()
            || rustix::process::getppid() != parent)
    {
        return EXIT_SETUP;
    }
    for descriptor in [&client, &guest] {
        let Ok(flags) = rustix::fs::fcntl_getfl(descriptor) else {
            return EXIT_SETUP;
        };
        if rustix::fs::fcntl_setfl(descriptor, flags | OFlags::NONBLOCK).is_err() {
            return EXIT_SETUP;
        }
    }
    let pipes = (
        pipe_with(PipeFlags::CLOEXEC | PipeFlags::NONBLOCK),
        pipe_with(PipeFlags::CLOEXEC | PipeFlags::NONBLOCK),
    );
    let (Ok(outbound_pipe), Ok(inbound_pipe)) = pipes else {
        return EXIT_SETUP;
    };
    if let Some(control) = control {
        if !handshake(control) {
            return EXIT_SETUP;
        }
    }
    bridge(&client, &guest, &outbound_pipe, &inbound_pipe)
}

/// @cc [owner:ghuntley,label:security;recovery] bridge-detached-handshake
/// A detached bridge MUST, once it holds both connections, has dropped
/// privileges and has its pipes, send hostd exactly READY on the control
/// socket and then move no byte until it reads exactly GO, which hostd sends
/// only after writing the client's greeting. Any other byte, end of stream
/// or error exits with `EXIT_SETUP`, so guest bytes can never precede the
/// greeting and a bridge hostd abandoned mid-start never runs. The control
/// socket is closed before any byte moves.
#[expect(
    clippy::needless_pass_by_value,
    reason = "handshake takes ownership so the control socket closes before any byte moves"
)]
pub fn handshake(control: OwnedFd) -> bool {
    loop {
        match rustix::io::write(&control, &[READY]) {
            Ok(1) => break,
            Err(Errno::INTR) => {}
            _ => return false,
        }
    }
    let mut answer = [0_u8; 1];
    loop {
        match rustix::io::read(&control, &mut answer) {
            Ok(1) => return answer[0] == GO,
            Err(Errno::INTR) => {}
            _ => return false,
        }
    }
}

fn socket(descriptor: &OwnedFd) -> bool {
    rustix::fs::fstat(descriptor).is_ok_and(|stat| stat.st_mode & libc::S_IFMT == libc::S_IFSOCK)
}

/// Move `room` or `pending` bytes; None is an error that ends the bridge.
#[expect(
    clippy::option_option,
    reason = "the three splice outcomes (count, retry, fatal) are matched exhaustively in `applied`"
)]
pub(crate) fn moved(result: rustix::io::Result<usize>) -> Option<Option<usize>> {
    match result {
        Ok(count) => Some(Some(count)),
        Err(Errno::AGAIN | Errno::INTR) => Some(None),
        Err(_) => None,
    }
}

/// Apply one splice outcome to a direction's accounting: a retry changes
/// nothing; false (an errno or an `Overrun` count) ends the bridge.
fn applied(
    result: rustix::io::Result<usize>,
    record: impl FnOnce(usize) -> Result<(), Overrun>,
) -> bool {
    match moved(result) {
        None => false,
        Some(Some(count)) => record(count).is_ok(),
        Some(None) => true,
    }
}

fn bridge(
    client: &OwnedFd,
    guest: &OwnedFd,
    (outbound_reader, outbound_writer): &(OwnedFd, OwnedFd),
    (inbound_reader, inbound_writer): &(OwnedFd, OwnedFd),
) -> u8 {
    let flags = SpliceFlags::NONBLOCK | SpliceFlags::MOVE;
    let mut outbound = Direction::default();
    let mut inbound = Direction::default();
    loop {
        if finished(&outbound) {
            let _ = rustix::net::shutdown(guest, Shutdown::Write);
            return EXIT_OK;
        }
        if half_close_due(&inbound) {
            let _ = rustix::net::shutdown(client, Shutdown::Write);
            inbound.shut = true;
        }
        let interest = |reads: bool, writes: bool| {
            let mut flags = PollFlags::empty();
            if reads {
                flags |= PollFlags::IN;
            }
            if writes {
                flags |= PollFlags::OUT;
            }
            flags
        };
        let client_interest = interest(outbound.wants_read(), inbound.wants_write());
        let guest_interest = interest(inbound.wants_read(), outbound.wants_write());
        // A side with nothing to do is left out, so a hung-up peer cannot
        // spin the loop while the other side is still delivering.
        let mut fds = Vec::with_capacity(2);
        if !client_interest.is_empty() {
            fds.push(PollFd::from_borrowed_fd(client.as_fd(), client_interest));
        }
        if !guest_interest.is_empty() {
            fds.push(PollFd::from_borrowed_fd(guest.as_fd(), guest_interest));
        }
        if fds.is_empty() {
            // Both sources ended with nothing pending; finished() decides.
            continue;
        }
        match rustix::event::poll(&mut fds, None) {
            Ok(_) | Err(Errno::INTR) => {}
            Err(_) => return EXIT_IO,
        }
        drop(fds);
        if outbound.wants_read() {
            let result = splice(client, None, outbound_writer, None, outbound.room(), flags);
            if !applied(result, |count| outbound.read(count)) {
                return EXIT_IO;
            }
        }
        if outbound.wants_write() {
            let result = splice(outbound_reader, None, guest, None, outbound.pending, flags);
            if !applied(result, |count| outbound.wrote(count)) {
                return EXIT_IO;
            }
        }
        if inbound.wants_read() {
            let result = splice(guest, None, inbound_writer, None, inbound.room(), flags);
            if !applied(result, |count| inbound.read(count)) {
                return EXIT_IO;
            }
        }
        if inbound.wants_write() {
            let result = splice(inbound_reader, None, client, None, inbound.pending, flags);
            if !applied(result, |count| inbound.wrote(count)) {
                return EXIT_IO;
            }
        }
    }
}
