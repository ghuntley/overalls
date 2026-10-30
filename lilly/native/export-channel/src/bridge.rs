use crate::{
    cancelled, encode, install_cancel_handlers, BridgeRequest, Request, EXIT_FAILED, WIRE_BYTES,
};
use rustix::event::{PollFd, PollFlags};
use rustix::io::Errno;
use rustix::net::sockopt::socket_peercred;
use rustix::net::{sendmsg, RecvFlags, SendAncillaryBuffer, SendAncillaryMessage, SendFlags};
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt};

/// @cc [owner:ghuntley,label:security] export-channel-authenticated-descriptor
/// The bridge runs only as the dedicated SSH account with a server-selected key
/// argv. It sends one bounded request + inherited stdout descriptor to the
/// configured local socket, verifies the server matches that socket's owner,
/// and reports success only from the separate completion byte.
pub fn bridge(request: &BridgeRequest) -> u8 {
    install_cancel_handlers();
    let metadata = match std::fs::symlink_metadata(&request.socket) {
        Err(_) => return EXIT_FAILED,
        Ok(metadata) => metadata,
    };
    if !metadata.file_type().is_socket() {
        return EXIT_FAILED;
    }
    let socket = match rustix::net::socket_with(
        rustix::net::AddressFamily::UNIX,
        rustix::net::SocketType::STREAM,
        rustix::net::SocketFlags::CLOEXEC | rustix::net::SocketFlags::NONBLOCK,
        None,
    ) {
        Err(_) => return EXIT_FAILED,
        Ok(fd) => fd,
    };
    let address = match rustix::net::SocketAddrUnix::new(&request.socket) {
        Err(_) => return EXIT_FAILED,
        Ok(addr) => addr,
    };
    // A nonblocking stream connect returns at once for local listeners;
    // anything that comes back is a refused boundary, matching C's `||` shape.
    if rustix::net::connect(&socket, &address).is_err() {
        return EXIT_FAILED;
    }
    let creds = match socket_peercred(&socket) {
        Err(_) => return EXIT_FAILED,
        Ok(creds) => creds,
    };
    if creds.uid.as_raw() != metadata.uid() {
        return EXIT_FAILED;
    }
    let wire = encode(&Request {
        key: request.key.clone(),
        command: request.command.clone(),
    });
    let mut space = [std::mem::MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
    let mut ancillary = SendAncillaryBuffer::new(&mut space);
    let stdout_fd = std::io::stdout();
    let stdout_borrow = stdout_fd.as_fd();
    let rights = [stdout_borrow];
    if !ancillary.push(SendAncillaryMessage::ScmRights(&rights)) {
        return EXIT_FAILED;
    }
    match sendmsg(
        &socket,
        &[std::io::IoSlice::new(&wire)],
        &mut ancillary,
        SendFlags::NOSIGNAL,
    ) {
        Ok(sent) if sent == WIRE_BYTES => {}
        Ok(_) => return EXIT_FAILED,
        Err(_) => return EXIT_FAILED,
    }
    bridge_await(socket.as_fd())
}

fn bridge_await(socket: BorrowedFd<'_>) -> u8 {
    loop {
        if cancelled() {
            return EXIT_FAILED;
        }
        let mut fds = [PollFd::from_borrowed_fd(
            socket,
            PollFlags::IN | PollFlags::HUP,
        )];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 100_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return EXIT_FAILED,
            Ok(_) => {}
        }
        if fds[0].revents().is_empty() {
            continue;
        }
        let mut status = [0_u8; 1];
        match rustix::net::recv(socket, &mut status, RecvFlags::empty()) {
            Ok((1, _)) => return if status[0] == 0 { 0 } else { EXIT_FAILED },
            _ => return EXIT_FAILED,
        }
    }
}
