//! Boot-bound guest receiver that clones one public provider repository (ADR-0157).
//!
//! Lilly delivers a single JSON line on vsock port 1031 after guest trust is
//! installed. This process persists the source once, replies immediately and
//! runs plain `git` in a background thread. Readiness never depends on it.
use lyra::workspace_receiver::{
    self as receiver, Binding, Paths, Receiver, Retry, SystemGit, PORT,
};
use lyra::workspace_source::WorkspaceSource;
use std::fs::{self, File};
use std::io;
use std::os::fd::{FromRawFd, RawFd};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

const UBUNTU_CA_BUNDLE: &str = "/etc/ssl/certs/ca-certificates.crt";
const UBUNTU_GIT: &str = "/usr/bin/git";

/// Image-specific locations of the trusted CA bundle and `git`.
struct Image {
    ca_bundle: PathBuf,
    git: PathBuf,
}

// Closed event names only: no URL, owner, repository, ref or git output.
fn event(name: &'static str) {
    eprintln!("{{\"event\":\"guest_workspace.{name}\"}}");
}

fn listener() -> io::Result<RawFd> {
    // SAFETY: socket takes only integer arguments and returns a new descriptor
    // or -1; no memory is shared with the kernel.
    let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "AF_VSOCK (40) fits sa_family_t (u16)"
    )]
    let address = libc::sockaddr_vm {
        svm_family: libc::AF_VSOCK as libc::sa_family_t,
        svm_reserved1: 0,
        svm_port: PORT,
        svm_cid: libc::VMADDR_CID_ANY,
        svm_zero: [0; 4],
    };
    #[expect(
        clippy::cast_possible_truncation,
        reason = "sockaddr_vm is 16 bytes, far below socklen_t::MAX"
    )]
    // SAFETY: `address` is a fully initialised sockaddr_vm that outlives the
    // call, and the length passed is its exact size.
    let result = unsafe {
        libc::bind(
            fd,
            (&raw const address).cast(),
            size_of_val(&address) as libc::socklen_t,
        )
    };
    // SAFETY: `fd` is the socket created above and is still owned here.
    if result < 0 || unsafe { libc::listen(fd, 4) } < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: `fd` is owned here and is closed exactly once before return.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(fd)
}

fn set_timeouts(connection: RawFd) -> bool {
    let timeout = libc::timeval {
        tv_sec: 5,
        tv_usec: 0,
    };
    [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO].iter().all(|option| {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "timeval is 16 bytes, far below socklen_t::MAX"
        )]
        // SAFETY: `timeout` is initialised, outlives the call and the length
        // is its exact size; the caller owns `connection`.
        let result = unsafe {
            libc::setsockopt(
                connection,
                libc::SOL_SOCKET,
                *option,
                (&raw const timeout).cast(),
                size_of_val(&timeout) as libc::socklen_t,
            )
        };
        result == 0
    })
}

fn spawn_clone(
    state: &Arc<Receiver>,
    cloning: &Arc<AtomicBool>,
    image: &Arc<Image>,
    source: WorkspaceSource,
) {
    if cloning.swap(true, Ordering::SeqCst) {
        return;
    }
    let state = Arc::clone(state);
    let flag = Arc::clone(cloning);
    let image = Arc::clone(image);
    let spawned = thread::Builder::new()
        .name("workspace-clone".into())
        .spawn(move || {
            event("cloning");
            let mut git = SystemGit {
                program: image.git.clone(),
                ca_bundle: image.ca_bundle.clone(),
                home: state.paths().state.clone(),
                system_configuration: None,
            };
            let outcome =
                state.clone_with_retry(&source, &mut git, Retry::GUEST, &mut thread::sleep, || {
                    event("clone_retry");
                });
            match outcome {
                Ok(receiver::Status::Done) => event("cloned"),
                _ => event("clone_failed"),
            }
            flag.store(false, Ordering::SeqCst);
        });
    if spawned.is_err() {
        cloning.store(false, Ordering::SeqCst);
        event("clone_failed");
    }
}

fn serve(binding: &Binding, image: Image) -> io::Result<()> {
    let state = Arc::new(Receiver::new(Paths::guest())?);
    let cloning = Arc::new(AtomicBool::new(false));
    let image = Arc::new(image);
    match state.start()? {
        Some(source) => {
            event("resuming");
            spawn_clone(&state, &cloning, &image, source);
        }
        None if state.done() => event("done"),
        None => {}
    }
    let fd = listener()?;
    event("awaiting");
    loop {
        // SAFETY: sockaddr_vm is plain old data; all-zero bytes are valid.
        let mut peer: libc::sockaddr_vm = unsafe { std::mem::zeroed() };
        #[expect(
            clippy::cast_possible_truncation,
            reason = "sockaddr_vm is 16 bytes, far below socklen_t::MAX"
        )]
        let mut size = size_of_val(&peer) as libc::socklen_t;
        // SAFETY: `peer` and `size` are live, writable and correctly sized for
        // the address accept4 stores; `fd` is the listening socket.
        let connection = unsafe {
            libc::accept4(
                fd,
                (&raw mut peer).cast(),
                &raw mut size,
                libc::SOCK_CLOEXEC,
            )
        };
        if connection < 0 {
            continue;
        }
        // SAFETY: accept4 returned a new descriptor that nothing else owns;
        // the File takes sole ownership and closes it on drop.
        let mut stream = unsafe { File::from_raw_fd(connection) };
        if !set_timeouts(connection)
            || i32::from(peer.svm_family) != libc::AF_VSOCK
            || peer.svm_cid != libc::VMADDR_CID_HOST
        {
            event("rejected");
            continue;
        }
        match receiver::answer(&mut stream, binding, &state) {
            Ok((decision, source)) => {
                drop(stream);
                match decision.reply {
                    receiver::Reply::Accepted => event("accepted"),
                    receiver::Reply::Conflict => event("conflict"),
                }
                if decision.clone {
                    spawn_clone(&state, &cloning, &image, source);
                }
            }
            Err(_) => event("rejected"),
        }
    }
}

/// @cc [owner:ghuntley,label:security] workspaced-image-mode-closed
/// The workspace receiver MUST accept only the explicit NixOS, Ubuntu or
/// generic Linux image mode and MUST require absolute CA and Git paths before
/// opening its vsock listener.
fn parse_image(args: &[String]) -> Option<Image> {
    let image = match args {
        [_, mode, bundle, git] if mode == "nixos" || mode == "linux" => Image {
            ca_bundle: PathBuf::from(bundle),
            git: PathBuf::from(git),
        },
        [_, mode] if mode == "ubuntu" => Image {
            ca_bundle: PathBuf::from(UBUNTU_CA_BUNDLE),
            git: PathBuf::from(UBUNTU_GIT),
        },
        _ => return None,
    };
    (image.ca_bundle.is_absolute() && image.git.is_absolute()).then_some(image)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(image) = parse_image(&args) else {
        std::process::exit(2);
    };
    let result = fs::read_to_string("/proc/cmdline")
        .and_then(|line| {
            let identity = lyra::guest::git_identity::from_command_line(&line)?;
            lyra::guest::git_identity::install(
                std::path::Path::new("/run/overalls-workspace/git-identity"),
                identity.as_ref(),
            )?;
            receiver::parse_binding(&line)
        })
        .and_then(|binding| serve(&binding, image));
    if result.is_err() {
        event("unavailable");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_linux_mode_requires_absolute_paths() {
        let args = vec![
            "workspaced".into(),
            "linux".into(),
            "/etc/ssl/certs/ca-certificates.crt".into(),
            "/usr/bin/git".into(),
        ];
        let image = parse_image(&args).expect("generic Linux mode");
        assert_eq!(
            image.ca_bundle,
            PathBuf::from("/etc/ssl/certs/ca-certificates.crt")
        );
        assert_eq!(image.git, PathBuf::from("/usr/bin/git"));
        assert!(parse_image(&[
            "workspaced".into(),
            "linux".into(),
            "relative".into(),
            "/usr/bin/git".into()
        ])
        .is_none());
        assert!(parse_image(&[
            "workspaced".into(),
            "linux".into(),
            "/etc/ssl/certs/ca-certificates.crt".into(),
            "git".into()
        ])
        .is_none());
    }

    #[test]
    fn unknown_and_malformed_modes_are_refused() {
        assert!(parse_image(&["workspaced".into(), "unknown".into()]).is_none());
        assert!(parse_image(&["workspaced".into(), "linux".into()]).is_none());
    }
}
