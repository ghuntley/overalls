use crate::{
    cancelled, decode, install_cancel_handlers, pins, posix, Request, ServeRequest, EXIT_FAILED,
    WIRE_BYTES,
};
use rustix::event::{PollFd, PollFlags};
use rustix::io::Errno;
use rustix::net::sockopt::{set_socket_timeout, socket_peercred, Timeout};
use rustix::net::{
    recvmsg, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags, ReturnFlags, SendFlags,
};
use rustix::process::{getpid, kill_process, kill_process_group, set_child_subreaper};
use rustix::process::{waitid, Pid, Signal, WaitId, WaitIdOptions};
use std::os::fd::{BorrowedFd, OwnedFd};
use std::os::unix::process::CommandExt as _;
use std::process::{Command as Process, Stdio};
use std::time::Duration;

/// @cc [owner:ghuntley,label:security;recovery] export-channel-private-service-boundary
/// serve requires a root-owned systemd socket restricted to the dedicated
/// transfer account, a trusted account name and fixed worker argv. Peer creds
/// are verified; one writable FD + bounded frame; only the selected key/request
/// reach the fixed worker environment. The worker MUST recheck native permit
/// authority. Disconnect cancels the worker. Completion waits for reaping; data
/// EOF or a disconnected requester never confirm successful export or
/// quiescence.
pub fn serve(request: &ServeRequest, channel: BorrowedFd<'_>) -> u8 {
    install_cancel_handlers();
    let Some(account_uid) = posix::account_uid(&request.account) else {
        return EXIT_FAILED;
    };
    let Ok(creds) = socket_peercred(channel) else {
        return EXIT_FAILED;
    };
    if creds.uid.as_raw() != account_uid {
        return EXIT_FAILED;
    }
    if set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_FAILED;
    }
    if set_socket_timeout(channel, Timeout::Recv, Some(Duration::from_secs(5))).is_err() {
        return EXIT_FAILED;
    }
    let mut wire = [0_u8; WIRE_BYTES];
    let mut space = [std::mem::MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
    let mut ancillary = RecvAncillaryBuffer::new(&mut space);
    let received: Option<OwnedFd> = (|| {
        let outcome = recvmsg(
            channel,
            &mut [std::io::IoSliceMut::new(&mut wire)],
            &mut ancillary,
            RecvFlags::WAITALL | RecvFlags::CMSG_CLOEXEC,
        )
        .ok()?;
        if outcome.bytes != WIRE_BYTES
            || outcome
                .flags
                .contains(ReturnFlags::TRUNC | ReturnFlags::CTRUNC)
        {
            return None;
        }
        let mut received: Option<OwnedFd> = None;
        for message in ancillary.drain() {
            if let RecvAncillaryMessage::ScmRights(fds) = message {
                let mut fds = fds;
                if received.is_some() || fds.len() != 1 {
                    return None;
                }
                received = fds.next();
            }
        }
        received
    })();
    let Some(received) = received else {
        return EXIT_FAILED;
    };
    if cancelled() {
        return EXIT_FAILED;
    }
    let Some(record) = decode(&wire) else {
        return EXIT_FAILED;
    };
    let Ok(mode) = rustix::fs::fcntl_getfl(&received) else {
        return EXIT_FAILED;
    };
    if mode & rustix::fs::OFlags::ACCMODE == rustix::fs::OFlags::RDONLY {
        return EXIT_FAILED;
    }
    serve_worker(request, &record, &received, channel)
}

fn serve_worker(
    request: &ServeRequest,
    record: &Request,
    received: &OwnedFd,
    channel: BorrowedFd<'_>,
) -> u8 {
    let Ok(duplicate) = received.try_clone() else {
        return EXIT_FAILED;
    };
    let forwarded = std::fs::File::from(duplicate);
    let mut builder = Process::new(&request.worker[0]);
    builder
        .args(&request.worker[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::from(forwarded))
        .stderr(Stdio::inherit())
        .env("LILLY_EXPORT_KEY", &record.key)
        .env("LILLY_EXPORT_REQUEST", &record.command);
    builder.process_group(0);
    pins::serve_child(&mut builder, getpid());
    let Ok(mut worker) = builder.spawn() else {
        return EXIT_FAILED;
    };
    let mut status = 1_u8;
    loop {
        if cancelled() {
            break;
        }
        match child_status(&worker) {
            Err(()) => break,
            Ok(Some(ok)) => {
                status = u8::from(!ok);
                break;
            }
            Ok(None) => {}
        }
        let mut fds = [PollFd::from_borrowed_fd(
            channel,
            PollFlags::IN | PollFlags::HUP,
        )];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 25_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => break,
            Ok(_) => {}
        }
        if !fds[0].revents().is_empty() {
            break;
        }
    }
    // Completion is confirmed only after reaping: data EOF or a disconnected
    // requester never confirmed successful export.
    finish(&mut worker);
    match rustix::net::send(channel, &[status], SendFlags::NOSIGNAL) {
        Ok(1) => status,
        _ => EXIT_FAILED,
    }
}

fn child_status(child: &std::process::Child) -> Result<Option<bool>, ()> {
    let pid = i32::try_from(child.id())
        .ok()
        .and_then(Pid::from_raw)
        .ok_or(())?;
    match waitid(
        WaitId::Pid(pid),
        WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
    ) {
        Err(_) => Err(()),
        Ok(None) => Ok(None),
        Ok(Some(status)) => Ok(Some(status.exited() && status.exit_status() == Some(0))),
    }
}

fn finish(worker: &mut std::process::Child) {
    if let Some(pid) = i32::try_from(worker.id()).ok().and_then(Pid::from_raw) {
        let _ = kill_process_group(pid, Signal::KILL);
        let _ = kill_process(pid, Signal::KILL);
    }
    let _ = worker.wait();
    loop {
        match waitid(WaitId::All, WaitIdOptions::EXITED) {
            Err(_) | Ok(None) => return,
            Ok(Some(_)) => {}
        }
    }
}
