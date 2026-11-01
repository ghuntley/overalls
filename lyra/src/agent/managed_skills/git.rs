//! The bounded system `git` client and its process-tree ownership.

#[cfg(windows)]
use super::materialize::read_bounded;
use super::storage::linked;
#[cfg(windows)]
use super::storage::regular_file;
use super::validate::checkpoint;
#[cfg(windows)]
use super::validate::sha256;
use super::{Failure, Result, MAX_FETCH, TIMEOUT};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[cfg(unix)]
fn ca_bundle() -> Result<PathBuf> {
    #[cfg(test)]
    if let Some(path) = option_env!("OVERALLS_TEST_CA_BUNDLE") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
    }
    let path = PathBuf::from(crate::private_http::SYSTEM_CA_BUNDLE);
    if path.is_file() {
        Ok(path)
    } else {
        Err(Failure("git_unavailable"))
    }
}
#[cfg(windows)]
fn ca_bundle() -> Result<PathBuf> {
    let root = PathBuf::from(r"C:\overalls\trust");
    let pointer = read_bounded(&root.join("current"), 128)?;
    let name = std::str::from_utf8(&pointer)
        .map_err(|_| Failure("git_unavailable"))?
        .trim();
    if !name.strip_prefix("bundle-").is_some_and(sha256) {
        return Err(Failure("git_unavailable"));
    }
    let path = root.join(name).join("ca-bundle.pem");
    regular_file(&path, 4 * 1024 * 1024)?;
    Ok(path)
}
#[cfg(unix)]
pub(super) fn git_program() -> Result<PathBuf> {
    #[cfg(test)]
    if let Some(path) = option_env!("OVERALLS_TEST_GIT") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
    }
    let candidates: &[&str] = if cfg!(target_os = "freebsd") {
        &["/usr/local/bin/git"]
    } else {
        &["/run/current-system/sw/bin/git", "/usr/bin/git", "/bin/git"]
    };
    candidates
        .iter()
        .map(PathBuf::from)
        .find(|path| path.is_file())
        .ok_or(Failure("git_unavailable"))
}
#[cfg(windows)]
pub(super) fn git_program() -> Result<PathBuf> {
    let path = PathBuf::from(r"C:\Program Files\Git\cmd\git.exe");
    if path.is_file() {
        Ok(path)
    } else {
        Err(Failure("git_unavailable"))
    }
}
pub(super) struct Git<'a, H: FnMut() -> bool> {
    pub(super) program: PathBuf,
    pub(super) root: &'a Path,
    pub(super) home: &'a Path,
    pub(super) started: Instant,
    pub(super) heartbeat: &'a mut H,
}
impl<H: FnMut() -> bool> Git<'_, H> {
    fn command(&self, arguments: &[&str]) -> Result<Command> {
        let bundle = ca_bundle()?;
        let mut command = Command::new(&self.program);
        command
            .env_clear()
            .current_dir(self.root)
            .env("HOME", self.home)
            .env("LANG", "C")
            .env("GIT_SSL_CAINFO", &bundle)
            .env("SSL_CERT_FILE", &bundle)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_LFS_SKIP_SMUDGE", "1")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .args([
                "-c",
                "credential.helper=",
                "-c",
                "credential.interactive=false",
                "-c",
                "protocol.allow=never",
                "-c",
                "protocol.https.allow=always",
                "-c",
                "http.followRedirects=false",
                "-c",
                "http.sslVerify=true",
                "-c",
                "http.lowSpeedLimit=1024",
                "-c",
                "http.lowSpeedTime=15",
                "-c",
                "fetch.fsckObjects=true",
                "-c",
                "transfer.fsckObjects=true",
                "-c",
                "fetch.recurseSubmodules=false",
                "-c",
                "submodule.recurse=false",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "gc.auto=0",
            ])
            .arg("-c")
            .arg(format!("core.hooksPath={}", self.home.display()))
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            let mut path = std::ffi::OsString::new();
            #[cfg(test)]
            if let Some(extra) = option_env!("OVERALLS_TEST_PATH") {
                path.push(extra);
                path.push(":");
            }
            path.push("/run/current-system/sw/bin:/usr/bin:/bin");
            command
                .process_group(0)
                .env("PATH", path)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("TMPDIR", self.home);
        }
        #[cfg(windows)]
        {
            command
                .env("SystemRoot", r"C:\Windows")
                .env(
                    "PATH",
                    r"C:\Program Files\Git\cmd;C:\Windows\System32;C:\Windows",
                )
                .env("GIT_CONFIG_GLOBAL", "NUL")
                .env("GIT_CONFIG_COUNT", "1")
                .env("GIT_CONFIG_KEY_0", "http.sslBackend")
                .env("GIT_CONFIG_VALUE_0", "openssl")
                .env("TEMP", self.home)
                .env("TMP", self.home);
        }
        Ok(command)
    }
    pub(super) fn run(&mut self, arguments: &[&str], limit: usize) -> Result<Vec<u8>> {
        checkpoint(self.heartbeat)?;
        if self.started.elapsed() >= TIMEOUT {
            return Err(Failure("operation_timeout"));
        }
        let mut child = self
            .command(arguments)?
            .spawn()
            .map_err(|_| Failure("git_unavailable"))?;
        let group = match ProcessGroup::attach(&child) {
            Ok(group) => group,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let stdout = child.stdout.take().ok_or(Failure("fetch_failed"))?;
        let (sender, receiver) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = stdout
                .take(limit as u64 + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = sender.send(result);
        });
        let mut captured = None;
        let result = loop {
            if let Err(error) = checkpoint(self.heartbeat) {
                break Err(error);
            }
            if self.started.elapsed() >= TIMEOUT {
                break Err(Failure("operation_timeout"));
            }
            if !scratch_within_limit(self.root) {
                break Err(Failure("fetch_too_large"));
            }
            if captured.is_none() {
                match receiver.try_recv() {
                    Ok(Ok(bytes)) if bytes.len() <= limit => captured = Some(bytes),
                    Ok(_) => break Err(Failure("fetch_too_large")),
                    Err(std::sync::mpsc::TryRecvError::Empty) => (),
                    Err(_) => break Err(Failure("fetch_failed")),
                }
            }
            match child.try_wait() {
                Ok(Some(status)) if !status.success() => break Err(Failure("fetch_failed")),
                Ok(Some(_)) if captured.is_some() => break Ok(captured.take().unwrap_or_default()),
                Ok(_) => (),
                Err(_) => break Err(Failure("fetch_failed")),
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        group.kill();
        let _ = child.wait();
        let _ = reader.join();
        result
    }
}
fn scratch_within_limit(root: &Path) -> bool {
    let mut pending = vec![root.to_path_buf()];
    let mut bytes = 0_u64;
    let mut count = 0_usize;
    while let Some(path) = pending.pop() {
        let Ok(entries) = fs::read_dir(path) else {
            return false;
        };
        for entry in entries {
            let Ok(entry) = entry else {
                return false;
            };
            let Ok(metadata) = fs::symlink_metadata(entry.path()) else {
                continue;
            };
            if linked(&metadata) {
                return false;
            }
            count += 1;
            if count > 20000 {
                return false;
            }
            if metadata.is_dir() {
                pending.push(entry.path());
            } else if metadata.is_file() {
                bytes = bytes.saturating_add(metadata.len());
            } else {
                return false;
            }
            if bytes > MAX_FETCH {
                return false;
            }
        }
    }
    true
}
#[cfg(unix)]
struct ProcessGroup(i32);
#[cfg(unix)]
impl ProcessGroup {
    fn attach(child: &std::process::Child) -> Result<Self> {
        i32::try_from(child.id())
            .map(Self)
            .map_err(|_| Failure("fetch_failed"))
    }
    fn kill(&self) {
        // The child starts in its own group; the validated PID belongs only to
        // this invocation, including its HTTPS helper descendants.
        crate::sys::unix::kill_process_group(self.0);
    }
}
#[cfg(windows)]
struct ProcessGroup(crate::platform::windows::job::Job);
#[cfg(windows)]
impl ProcessGroup {
    fn attach(child: &std::process::Child) -> Result<Self> {
        crate::platform::windows::job::Job::attach(child)
            .map(Self)
            .map_err(|_| Failure("fetch_failed"))
    }
    fn kill(&self) {
        self.0.terminate();
    }
}
