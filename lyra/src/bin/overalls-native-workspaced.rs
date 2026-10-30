//! Boot-bound source-v2 workspace receiver for native guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
#[expect(
    clippy::too_many_lines,
    reason = "one ordered boot-bound receiver loop; recovery precedes listening"
)]
fn main() -> ! {
    use lyra::native_guest;
    use lyra::native_vsock::Listener;
    use lyra::workspace_receiver::{self as receiver, Binding, Paths, Receiver, Retry, SystemGit};
    use lyra::workspace_source::WorkspaceSource;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;

    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    let Ok((boot, _, _)) = native_guest::identity() else {
        std::process::exit(1);
    };
    let identity =
        lyra::guest::mmds::fetch(std::time::Duration::from_secs(5)).and_then(|document| {
            if document.placement != boot.placement_id
                || document.execution_epoch != boot.execution_epoch
                || document.boot_challenge != boot.boot_challenge
            {
                return Err(std::io::Error::other("git identity boot mismatch"));
            }
            lyra::guest::git_identity::install(
                std::path::Path::new("/run/overalls-workspace/git-identity"),
                document.git_identity.as_ref(),
            )
        });
    if identity.is_err() {
        std::process::exit(1);
    }
    let binding = Binding {
        placement_id: boot.placement_id,
        execution_epoch: boot.execution_epoch,
        boot_challenge: boot.boot_challenge,
    };
    let state = match Receiver::new(Paths::guest()).map(Receiver::with_shared_git_configuration) {
        Ok(value) => Arc::new(value),
        Err(_) => std::process::exit(2),
    };
    let cloning = Arc::new(AtomicBool::new(false));
    let (git_program, ca) = if os == "freebsd" {
        (
            PathBuf::from("/usr/local/bin/git"),
            PathBuf::from("/etc/ssl/cert.pem"),
        )
    } else {
        (
            PathBuf::from("/usr/bin/git"),
            PathBuf::from("/etc/ssl/cacert.pem"),
        )
    };
    let system_configuration = Some(PathBuf::from(if os == "freebsd" {
        "/usr/local/etc/gitconfig"
    } else {
        "/etc/gitconfig"
    }));
    let spawn = |state: &Arc<Receiver>, cloning: &Arc<AtomicBool>, source: WorkspaceSource| {
        if cloning.swap(true, Ordering::SeqCst) {
            return;
        }
        let state = Arc::clone(state);
        let flag = Arc::clone(cloning);
        let git_program = git_program.clone();
        let ca = ca.clone();
        let system_configuration = system_configuration.clone();
        let _ = thread::Builder::new()
            .name("workspace-clone".into())
            .spawn(move || {
                let mut git = SystemGit {
                    program: git_program,
                    ca_bundle: ca,
                    home: state.paths().state.clone(),
                    system_configuration,
                };
                let _ = state.clone_with_retry(
                    &source,
                    &mut git,
                    Retry::GUEST,
                    &mut thread::sleep,
                    || {},
                );
                flag.store(false, Ordering::SeqCst);
            });
    };
    match state.start() {
        Ok(Some(source)) => spawn(&state, &cloning, source),
        Ok(None) => {}
        Err(_) => std::process::exit(4),
    }
    let Ok(listener) = Listener::bind(receiver::PORT, 4) else {
        std::process::exit(3);
    };
    loop {
        let Ok(mut connection) = listener.accept() else {
            continue;
        };
        match receiver::answer(&mut connection, &binding, &state) {
            Ok((decision, source)) if decision.clone => spawn(&state, &cloning, source),
            Ok(_) | Err(_) => {}
        }
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}
