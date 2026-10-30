#![forbid(unsafe_code)]

use lilly_hostd::exec::{prepare_cgroup, start_reaper, Custody};
use lilly_hostd::leases::Leases;
use lilly_hostd::session::{serve, Daemon};
use lilly_hostd::utilities::Table;
use lilly_hostd::{own_cgroup, parse_options};
use rustix::net::{
    accept_with, bind, listen, socket_with, AddressFamily, SocketAddrUnix, SocketFlags, SocketType,
};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixDatagram;
use std::process::ExitCode;
use std::sync::Arc;

const EXIT_USAGE: u8 = 64;
/// Distinct setup failures, so a failed unit start names its cause.
const EXIT_SETUP: u8 = 71;
const EXIT_CGROUP: u8 = 72;
const EXIT_REAPER: u8 = 73;
const EXIT_SOCKET: u8 = 74;

#[expect(
    clippy::too_many_lines,
    reason = "the startup sequence maps each failure to its own exit code in one linear function"
)]
fn run() -> u8 {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    let Some(options) = parse_options(&arguments) else {
        return EXIT_USAGE;
    };
    let custody = match &options.cgroup {
        None => Custody::ProcessGroup,
        Some(path) => {
            let Some(base) = path.clone().or_else(own_cgroup) else {
                return EXIT_CGROUP;
            };
            if prepare_cgroup(&base).is_err() {
                return EXIT_CGROUP;
            }
            Custody::Cgroup(base)
        }
    };
    if start_reaper().is_err() {
        return EXIT_REAPER;
    }
    // A private daemon (no --peer-uid) serves only its own uid. Lilly's state
    // belongs to the service uid: the peer's own, or the one a root tool's
    // private daemon is given (ADR-0182).
    let peer_uid = options
        .peer_uid
        .unwrap_or_else(|| rustix::process::geteuid().as_raw());
    let service_uid = options.service_uid.unwrap_or(peer_uid);
    let Ok(leases) = Leases::new(&options.roots).map(|leases| leases.with_owner(service_uid))
    else {
        return EXIT_SETUP;
    };
    let utilities = Table::resolve(&std::env::var_os("PATH").unwrap_or_default());
    // Detached ingress bridges (ADR-0187) need Audi's uid, which is dynamic,
    // and systemd-run to place each bridge in its own scope.
    let ingress = match &options.ingress {
        None => None,
        Some((user, slice)) => {
            let Some(peer_uid) = std::fs::read("/etc/passwd")
                .ok()
                .and_then(|passwd| lilly_hostd::passwd_uid(&passwd, user))
            else {
                return EXIT_SETUP;
            };
            let Some(launcher) = utilities.get(lilly_hostd::utilities::Utility::SystemdRun) else {
                return EXIT_SETUP;
            };
            Some(lilly_hostd::ingress::Config {
                peer_uid,
                slice: slice.clone(),
                cgroup: std::path::Path::new("/sys/fs/cgroup").join(slice),
                launcher: Some(launcher.to_path_buf()),
            })
        }
    };
    let socket_roots = options.socket_roots.clone();
    let pools = options.pools();
    let mut daemon = Daemon::new(leases, utilities, custody, peer_uid, options.peer_cgroups);
    daemon.service_uid = service_uid;
    daemon.socket_roots = socket_roots;
    daemon.vm_tools.clone_from(&options.vm_tools);
    daemon.ingress = ingress;
    daemon.roots.clone_from(&options.roots);
    daemon.pool_datasets.clone_from(&options.pool_datasets);
    daemon.pools = pools;
    daemon.private_dir = options.socket.parent().map(std::path::Path::to_path_buf);
    daemon.file_roots = if options.file_roots.is_empty() {
        options.roots.clone()
    } else {
        options.file_roots.clone()
    };
    let daemon = Arc::new(daemon);
    let _ = std::fs::remove_file(&options.socket);
    let Ok(listener) = socket_with(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    ) else {
        return EXIT_SOCKET;
    };
    let Ok(address) = SocketAddrUnix::new(&options.socket) else {
        return EXIT_SOCKET;
    };
    // @cc [owner:ghuntley,label:security] hostd-socket-owned-by-peer
    // The control socket MUST be mode 0600, owned by hostd's own uid or,
    // when the configured peer uid differs (an unprivileged Lilly, ADR-0182),
    // by exactly that uid; SO_PEERCRED still authenticates every session.
    let socket_owner = options
        .peer_uid
        .filter(|uid| *uid != rustix::process::geteuid().as_raw());
    if bind(&listener, &address).is_err()
        || std::fs::set_permissions(&options.socket, std::fs::Permissions::from_mode(0o600))
            .is_err()
        || socket_owner
            .is_some_and(|uid| std::os::unix::fs::chown(&options.socket, Some(uid), None).is_err())
        || listen(&listener, 64).is_err()
    {
        return EXIT_SOCKET;
    }
    if options.stdin_lifetime {
        // The owner closed our stdin: remove the private socket and its
        // directory (the owner created it for this daemon alone) and exit.
        let socket = options.socket.clone();
        std::thread::spawn(move || {
            let mut sink = [0_u8; 64];
            while matches!(std::io::Read::read(&mut std::io::stdin(), &mut sink), Ok(n) if n > 0) {}
            let _ = std::fs::remove_file(&socket);
            if let Some(directory) = socket.parent() {
                let _ = std::fs::remove_dir(directory);
            }
            std::process::exit(0);
        });
    }
    notify_ready();
    loop {
        match accept_with(&listener, SocketFlags::CLOEXEC) {
            Ok(connection) => {
                let daemon = Arc::clone(&daemon);
                // A thread that cannot be created (resource exhaustion)
                // drops this connection, closing it; the daemon keeps
                // accepting.
                let _ = std::thread::Builder::new().spawn(move || serve(daemon, connection));
            }
            Err(rustix::io::Errno::INTR | rustix::io::Errno::CONNABORTED) => {}
            Err(_) => return EXIT_SETUP,
        }
    }
}

/// Tell systemd (Type=notify) the socket is listening.
fn notify_ready() {
    if let Some(path) = std::env::var_os("NOTIFY_SOCKET") {
        if let Ok(socket) = UnixDatagram::unbound() {
            let _ = socket.send_to(b"READY=1", path);
        }
    }
}

fn main() -> ExitCode {
    // No logging: replies carry closed status codes only, and Lilly emits the
    // reviewed events. Utility arguments and output never reach a log here.
    ExitCode::from(run())
}
