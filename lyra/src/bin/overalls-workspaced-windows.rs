//! Windows guest workspace receiver (ADR-0157, ADR-0171 gate 5).
//!
//! The Windows counterpart of `overalls-workspaced`: Lilly delivers one JSON
//! line on vsock port 1031 after guest trust is installed; this process
//! persists the source once, replies immediately and clones in a background
//! thread with the image's winget-installed Git for Windows (ADR-0173), trusting exactly the bundle the trust daemon
//! published. Validation, persistence, the reply and the git argument vectors
//! are the shared `workspace_receiver` code; only the transport, the boot
//! binding (MMDS instead of the kernel command line) and the paths differ.
//! Readiness never depends on it. Runs as a SYSTEM task; exits 64 elsewhere.

#[cfg(windows)]
mod daemon {
    use lyra::guest::mmds;
    use lyra::platform::windows::log::Logger;
    use lyra::platform::windows::vsock::{self, Listener};
    use lyra::workspace_receiver::{
        self as receiver, Binding, Paths, Receiver, Retry, SystemGit, PORT,
    };
    use lyra::workspace_source::WorkspaceSource;
    use std::fs;
    use std::io;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    const IDENTITY_BUDGET: Duration = Duration::from_mins(10);
    /// Git for Windows' launcher, installed machine-wide by winget from the pinned manifest (ADR-0173).
    const GIT: &str = "C:\\Program Files\\Git\\cmd\\git.exe";
    const TRUST_DIR: &str = "C:\\overalls\\trust";

    fn binding() -> io::Result<Binding> {
        let started = Instant::now();
        loop {
            match mmds::fetch(Duration::from_secs(5)) {
                Ok(document) => {
                    lyra::guest::git_identity::install(
                        std::path::Path::new(r"C:\overalls\git-identity"),
                        document.git_identity.as_ref(),
                    )?;
                    let status = std::process::Command::new(GIT)
                        .args([
                            "config",
                            "--system",
                            "--fixed-value",
                            "--replace-all",
                            "include.path",
                            "C:/overalls/git-identity/gitconfig",
                            "C:/overalls/git-identity/gitconfig",
                        ])
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status()?;
                    if !status.success() {
                        return Err(io::Error::other("git identity unavailable"));
                    }

                    return Ok(Binding {
                        placement_id: document.placement,
                        execution_epoch: document.execution_epoch,
                        boot_challenge: document.boot_challenge,
                    });
                }
                Err(_) if started.elapsed() < IDENTITY_BUDGET => {
                    thread::sleep(Duration::from_secs(2));
                }
                Err(error) => return Err(error),
            }
        }
    }

    /// @cc [owner:ghuntley,label:security] windows-workspace-trusts-published-bundle
    /// Git MUST trust only the bundle `overalls-trustd-windows` last published
    /// for this guest: `current` must name `bundle-<64 lowercase hex>` and the
    /// named bundle must exist; otherwise the clone attempt fails and retries.
    fn ca_bundle() -> io::Result<PathBuf> {
        let name = fs::read_to_string(PathBuf::from(TRUST_DIR).join("current"))?;
        let name = name.trim();
        let digest = name.strip_prefix("bundle-").unwrap_or("");
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(io::Error::other("invalid trust pointer"));
        }
        let bundle = PathBuf::from(TRUST_DIR).join(name).join("ca-bundle.pem");
        fs::metadata(&bundle)?;
        Ok(bundle)
    }

    fn spawn_clone(state: &Arc<Receiver>, cloning: &Arc<AtomicBool>, source: WorkspaceSource) {
        if cloning.swap(true, Ordering::SeqCst) {
            return;
        }
        let state = Arc::clone(state);
        let flag = Arc::clone(cloning);
        let spawned = thread::Builder::new()
            .name("workspace-clone".into())
            .spawn(move || {
                let logger = Logger::new("workspaced");
                logger.log("cloning");
                let outcome = match ca_bundle() {
                    Ok(bundle) => {
                        let mut git = SystemGit {
                            program: PathBuf::from(GIT),
                            ca_bundle: bundle,
                            home: state.paths().state.clone(),
                            system_configuration: None,
                        };
                        let _ = fs::create_dir_all(state.paths().state.join("tmp"));
                        state.clone_with_retry(
                            &source,
                            &mut git,
                            Retry::GUEST,
                            &mut thread::sleep,
                            || logger.log("clone_retry"),
                        )
                    }
                    Err(error) => Err(error),
                };
                match outcome {
                    Ok(receiver::Status::Done) => logger.log("cloned"),
                    _ => logger.log("clone_failed"),
                }
                logger.publish();
                flag.store(false, Ordering::SeqCst);
            });
        if spawned.is_err() {
            cloning.store(false, Ordering::SeqCst);
        }
    }

    pub(crate) fn run() -> i32 {
        let logger = Logger::new("workspaced");
        logger.log("start");
        if vsock::startup().is_err() {
            logger.log("winsock_unavailable");
            logger.publish();
            return 1;
        }
        let binding = match binding() {
            Ok(binding) => binding,
            Err(error) => {
                logger.log(&format!("identity_unavailable kind={:?}", error.kind()));
                logger.publish();
                return 2;
            }
        };
        let state = match Receiver::new(Paths::windows()) {
            Ok(state) => Arc::new(state),
            Err(error) => {
                logger.log(&format!(
                    "state_unavailable stage=open kind={:?}",
                    error.kind()
                ));
                logger.publish();
                return 5;
            }
        };
        let cloning = Arc::new(AtomicBool::new(false));
        match state.start() {
            Ok(Some(source)) => {
                logger.log("resuming");
                spawn_clone(&state, &cloning, source);
            }
            Ok(None) if state.done() => logger.log("done"),
            Ok(None) => {}
            Err(error) => {
                logger.log(&format!(
                    "state_unavailable stage=start kind={:?}",
                    error.kind()
                ));
                logger.publish();
                return 5;
            }
        }
        let Ok(family) = vsock::discover(IDENTITY_BUDGET, |_| {}) else {
            logger.log("vsock_unavailable");
            logger.publish();
            return 3;
        };
        let listener = match Listener::bind(family, PORT, 4) {
            Ok(listener) => listener,
            Err(error) => {
                logger.log(&format!(
                    "bind_failed code={}",
                    error.raw_os_error().unwrap_or(0)
                ));
                logger.publish();
                return 4;
            }
        };
        logger.log(&format!("listening port={PORT}"));
        logger.publish();
        loop {
            let Ok(mut connection) = listener.accept(Duration::from_secs(5)) else {
                thread::sleep(Duration::from_millis(200));
                continue;
            };
            if !connection.from_host() {
                logger.log("rejected");
                continue;
            }
            match receiver::answer(&mut connection, &binding, &state) {
                Ok((decision, source)) => {
                    drop(connection);
                    match decision.reply {
                        receiver::Reply::Accepted => logger.log("accepted"),
                        receiver::Reply::Conflict => logger.log("conflict"),
                    }
                    logger.publish();
                    if decision.clone {
                        spawn_clone(&state, &cloning, source);
                    }
                }
                Err(_) => logger.log("rejected"),
            }
        }
    }
}

#[cfg(windows)]
fn main() {
    std::process::exit(daemon::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-workspaced-windows runs inside Windows guests only");
    std::process::exit(64);
}
