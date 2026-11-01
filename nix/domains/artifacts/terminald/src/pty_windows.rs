//! Terminal sessions on Windows guests through `ConPTY` (ADR-0171).
//!
//! The session engine treats a `Master` like a Linux PTY master: a bounded
//! readiness wait, reads of raw output, input writes, resize, kill and
//! retirement. `ConPTY` renders through conhost, which re-encodes the screen as
//! VT sequences; the engine still never drops, reorders or interprets the
//! bytes it receives (`fidelity-passthrough`), but byte-for-byte fidelity with
//! the program's own output is not possible on Windows and is recorded.
//!
//! Identities: `root` keeps its Linux meaning, the host-admin session, and
//! runs as the daemon's own `LocalSystem` token. Any other name must be an
//! enabled local account (the roster agent creates, enables and disables
//! them) and runs under an S4U logon of that account, as Win32-OpenSSH does
//! for key logins. Every session's processes live in a kill-on-close job.
use crate::sys::conpty as sys;
use crate::sys::windows::{close_handle, last_error as last_error_code};
use std::io;
use std::ptr::null_mut;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{ERROR_BROKEN_PIPE, HANDLE, WAIT_OBJECT_0};
use windows_sys::Win32::NetworkManagement::NetManagement::UF_ACCOUNTDISABLE;
use windows_sys::Win32::System::Console::{COORD, HPCON};

const ROOT: &str = "root";
const NAME_MAX: usize = 20;

fn last_error() -> io::Error {
    io::Error::from_raw_os_error(last_error_code().cast_signed())
}

/// A resolved session identity.
pub(crate) struct UserInfo {
    pub name: String,
    system: bool,
}

/// Roster account names: what the roster agent creates (`u<uid>` and the
/// like), bounded by the SAM limit; never a path, domain or quoted form.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= NAME_MAX
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn enabled_local_account(name: &str) -> bool {
    sys::local_account_flags(name).is_some_and(|flags| flags & UF_ACCOUNTDISABLE == 0)
}

/// @cc [owner:ghuntley,label:security;capacity] windows-terminal-user-inventory
/// The inventory MUST list `root` first and then only enabled normal local
/// accounts with valid roster names, at most 64 entries; it MUST NOT create
/// accounts or expose any password field.
pub(crate) fn users() -> io::Result<Vec<String>> {
    let mut users = vec![ROOT.to_owned()];
    let Some(accounts) = sys::local_accounts() else {
        return Err(io::Error::other("account inventory unavailable"));
    };
    for (name, flags) in accounts {
        if flags & UF_ACCOUNTDISABLE == 0 && valid_name(&name) && name != ROOT {
            users.push(name);
        }
    }
    users[1..].sort();
    users.dedup();
    users.truncate(64);
    Ok(users)
}

/// @cc [owner:ghuntley,label:security] windows-terminal-roster-accounts
/// `resolve` MUST return the `LocalSystem` identity only for `root` and
/// otherwise only an existing, enabled local account with a valid roster name;
/// disabled, missing or malformed names MUST resolve to nothing, and no
/// account is created or enabled here (the roster agent owns that).
pub(crate) fn resolve(name: &str) -> Option<UserInfo> {
    if name == ROOT {
        return Some(UserInfo {
            name: ROOT.to_owned(),
            system: true,
        });
    }
    (valid_name(name) && enabled_local_account(name)).then(|| UserInfo {
        name: name.to_owned(),
        system: false,
    })
}

/// Shared `ConPTY` state for one session.
pub(crate) struct Console {
    /// The pseudo console until it is closed; resize and close serialize here.
    pseudo: Mutex<Option<HPCON>>,
    closing: AtomicBool,
    output: usize,
    input: usize,
    process: usize,
    job: usize,
    token: usize,
    profile: usize,
}

impl Console {
    fn handle(value: usize) -> HANDLE {
        value as HANDLE
    }

    #[expect(
        clippy::unwrap_used,
        reason = "release builds use panic = abort, so a panicking holder ends the process \
                  before any thread can observe poison"
    )]
    fn close_pseudo(&self) {
        if let Some(pseudo) = self.pseudo.lock().unwrap().take() {
            // The pseudo console is closed exactly once (taken from the slot).
            sys::close_pseudo_console(pseudo);
        }
    }

    /// Once the shell has exited, close the pseudo console off the pump thread:
    /// conhost then flushes and closes its output pipe, so the pump drains the
    /// final bytes and reads end of stream. Closing on the pump thread could
    /// deadlock against conhost blocked on a full output pipe.
    fn begin_close(self: &Arc<Self>) {
        if self.closing.swap(true, Ordering::SeqCst) {
            return;
        }
        let console = self.clone();
        if std::thread::Builder::new()
            .spawn(move || console.close_pseudo())
            .is_err()
        {
            self.closing.store(false, Ordering::SeqCst);
        }
    }
}

/// The session's `ConPTY` master.
pub(crate) type Master = Arc<Console>;

pub(crate) struct Spawned {
    pub master: Master,
    pub pid: i32,
}

/// Outcome of a bounded master readiness wait.
#[expect(
    dead_code,
    reason = "shares the Unix variants; ConPTY never reports an interrupted wait"
)]
pub(crate) enum Ready {
    Data,
    Timeout,
    Interrupted,
    Failed,
}

/// Outcome of one master read.
#[expect(
    dead_code,
    reason = "shares the Unix variants; ConPTY reads never report these outcomes"
)]
pub(crate) enum Read {
    Data(usize),
    Eof,
    Interrupted,
    WouldBlock,
    SlaveClosed,
    Failed,
}

/// Wait up to `millis` for `ConPTY` output, or for end of stream.
pub(crate) fn wait_readable(master: &Master, millis: i32) -> Ready {
    let deadline = Instant::now() + Duration::from_millis(u64::try_from(millis).unwrap_or(0));
    loop {
        let mut available = 0u32;
        let peeked = sys::peek_available(Console::handle(master.output), &mut available);
        if peeked == 0 {
            return if last_error_code() == ERROR_BROKEN_PIPE {
                Ready::Data
            } else {
                Ready::Failed
            };
        }
        if available > 0 {
            return Ready::Data;
        }
        if sys::wait_for(Console::handle(master.process), 0) == WAIT_OBJECT_0 {
            master.begin_close();
        }
        if Instant::now() >= deadline {
            return Ready::Timeout;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// One read of `ConPTY` output; a closed pipe is end of stream.
pub(crate) fn read(master: &Master, buf: &mut [u8]) -> Read {
    let mut read = 0u32;
    let ok = sys::read_file(Console::handle(master.output), buf, &mut read);
    if ok == 0 {
        return if last_error_code() == ERROR_BROKEN_PIPE {
            Read::Eof
        } else {
            Read::Failed
        };
    }
    if read == 0 {
        Read::Eof
    } else {
        Read::Data(read as usize)
    }
}

/// Write all input bytes to the pseudo console.
pub(crate) fn write_input(master: &Master, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        let mut written = 0u32;
        if sys::write_file(Console::handle(master.input), data, &mut written) == 0 {
            return Err(last_error());
        }
        if written == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        data = &data[written as usize..];
    }
    Ok(())
}

pub(crate) fn set_winsize(master: &Master, cols: u16, rows: u16) -> io::Result<()> {
    let size = coord(cols, rows)?;
    #[expect(
        clippy::unwrap_used,
        reason = "release builds use panic = abort, so a panicking holder ends the process \
                  before any thread can observe poison"
    )]
    let guard = master.pseudo.lock().unwrap();
    let Some(pseudo) = *guard else {
        return Err(io::ErrorKind::BrokenPipe.into());
    };
    // The pseudo console is live while its slot holds it under the lock.
    if sys::resize_pseudo_console(pseudo, size) < 0 {
        return Err(io::Error::other("resize refused"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:recovery;security] windows-terminal-kill-job
/// Explicit kill MUST terminate every process in the session's job, which
/// also ends descendants that detached from the console, and MUST NOT wait
/// for viewer credit.
pub(crate) fn kill(master: &Master, _pid: i32) {
    sys::terminate_job(Console::handle(master.job), 1);
}

/// Retirement: end the job, release conhost (closing our read end first so a
/// blocked conhost write fails instead of deadlocking the close), and release
/// every handle and the loaded profile exactly once.
pub(crate) fn retire(master: &Master, _pid: i32) {
    // The job and process handles stay open until they are closed below.
    sys::terminate_job(Console::handle(master.job), 1);
    sys::wait_for(Console::handle(master.process), 5000);
    // Retirement runs once per session, so each handle is closed exactly once.
    close_handle(Console::handle(master.output));
    if !master.closing.swap(true, Ordering::SeqCst) {
        master.close_pseudo();
    }
    close_handle(Console::handle(master.input));
    close_handle(Console::handle(master.process));
    close_handle(Console::handle(master.job));
    if master.token != 0 {
        if master.profile != 0 {
            // The profile was loaded for this token by spawn and is unloaded
            // exactly once, before the token closes.
            sys::unload_user_profile(
                Console::handle(master.token),
                Console::handle(master.profile),
            );
        }
        close_handle(Console::handle(master.token));
    }
}

fn coord(cols: u16, rows: u16) -> io::Result<COORD> {
    Ok(COORD {
        X: i16::try_from(cols).map_err(|_| io::Error::other("columns out of range"))?,
        Y: i16::try_from(rows).map_err(|_| io::Error::other("rows out of range"))?,
    })
}

/// The child's environment: the account's own block (or the daemon's for
/// root) with TERM from the client and COLORTERM=truecolor, UTF-16 encoded.
fn environment(token: HANDLE, term: &str) -> io::Result<(sys::EnvironmentBlock, String)> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    if token.is_null() {
        pairs.extend(std::env::vars());
    } else {
        pairs.extend(sys::token_environment(token)?);
    }
    pairs.retain(|(key, _)| {
        !key.eq_ignore_ascii_case("TERM") && !key.eq_ignore_ascii_case("COLORTERM")
    });
    pairs.push(("TERM".to_owned(), term.to_owned()));
    pairs.push(("COLORTERM".to_owned(), "truecolor".to_owned()));
    let home = pairs
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("USERPROFILE"))
        .map_or_else(|| r"C:\".to_owned(), |(_, value)| value.clone());
    let block = sys::EnvironmentBlock::new(pairs);
    Ok((block, home))
}

struct Handles(Vec<HANDLE>);

impl Drop for Handles {
    fn drop(&mut self) {
        for handle in &self.0 {
            if !handle.is_null() {
                // Each recorded handle is owned by this guard alone and closed
                // exactly once, here.
                close_handle(*handle);
            }
        }
    }
}

/// @cc [owner:ghuntley,label:security] windows-terminal-session-identity
/// A session MUST run its shell under the resolved identity only: `LocalSystem`
/// for `root`, otherwise an S4U token of that enabled account with its profile
/// loaded and its own window station; the shell MUST be attached to a fresh
/// pseudo console, assigned to a kill-on-close job before it runs, and given
/// TERM from the client and COLORTERM=truecolor. Any failed step MUST release
/// what it created and return an error without starting the shell.
pub(crate) fn spawn(user: &UserInfo, term: &str, cols: u16, rows: u16) -> io::Result<Spawned> {
    let size = coord(cols, rows)?;
    let mut owned = Handles(Vec::new());
    let (mut input_read, mut input_write, mut output_read, mut output_write) =
        (null_mut(), null_mut(), null_mut(), null_mut());
    // Anonymous pipes without inheritance; handles recorded for cleanup.
    if sys::create_pipe(&mut input_read, &mut input_write) == 0 {
        return Err(last_error());
    }
    owned.0.extend([input_read, input_write]);
    if sys::create_pipe(&mut output_read, &mut output_write) == 0 {
        return Err(last_error());
    }
    owned.0.extend([output_read, output_write]);
    let mut pseudo: HPCON = 0;
    if sys::create_pseudo_console(size, input_read, output_write, &mut pseudo) < 0 {
        return Err(io::Error::other("pseudo console unavailable"));
    }
    let pseudo_guard = PseudoGuard(Some(pseudo));
    let token = if user.system {
        null_mut()
    } else {
        sys::enable_privilege(&sys::Privilege::AssignPrimaryToken)?;
        sys::enable_privilege(&sys::Privilege::IncreaseQuota)?;
        sys::s4u_token(&user.name)?
    };
    let mut token_guard = Handles(if token.is_null() {
        Vec::new()
    } else {
        vec![token]
    });
    let mut profile: HANDLE = null_mut();
    if !token.is_null() {
        profile = sys::load_user_profile(token, &user.name)?;
    }
    let unload = |profile: HANDLE| {
        if !profile.is_null() {
            // `profile` was loaded for `token` above, which is still open;
            // each failure path unloads it once.
            sys::unload_user_profile(token, profile);
        }
    };
    let (mut environment, home) = match environment(token, term) {
        Ok(value) => value,
        Err(error) => {
            unload(profile);
            return Err(error);
        }
    };
    let job = sys::create_job();
    if job.is_null() {
        unload(profile);
        return Err(last_error());
    }
    if sys::set_kill_on_close(job) == 0 {
        let error = last_error();
        // `job` was created above and is closed once on this path.
        close_handle(job);
        unload(profile);
        return Err(error);
    }
    let spawned = sys::launch(token, pseudo, &mut environment, &home, user.system);
    let (process, thread, pid) = match spawned {
        Ok(value) => value,
        Err(error) => {
            // `job` was created above and is closed once on this path.
            close_handle(job);
            unload(profile);
            return Err(error);
        }
    };
    // The suspended process joins the job before its first instruction;
    // `thread` is its suspended primary thread.
    if sys::assign_to_job(job, process) == 0 || sys::resume_thread(thread) == u32::MAX {
        let error = last_error();
        // `job` and `process` stay open until they are closed below; the
        // thread, process and job handles are each closed exactly once.
        sys::terminate_job(job, 1);
        sys::terminate_process(process, 1);
        close_handle(thread);
        close_handle(process);
        close_handle(job);
        unload(profile);
        return Err(error);
    }
    // The thread handle from launch is closed exactly once.
    close_handle(thread);
    // conhost holds its own copies of the console-side pipe ends.
    owned.0.clear();
    // The guard no longer owns these pipe ends, so each is closed once.
    close_handle(input_read);
    close_handle(output_write);
    token_guard.0.clear();
    let console = Arc::new(Console {
        pseudo: Mutex::new(pseudo_guard.release()),
        closing: AtomicBool::new(false),
        output: output_read as usize,
        input: input_write as usize,
        process: process as usize,
        job: job as usize,
        token: token as usize,
        profile: profile as usize,
    });
    Ok(Spawned {
        master: console,
        pid: i32::try_from(pid).unwrap_or(i32::MAX),
    })
}

struct PseudoGuard(Option<HPCON>);

impl PseudoGuard {
    fn release(mut self) -> Option<HPCON> {
        self.0.take()
    }
}

impl Drop for PseudoGuard {
    fn drop(&mut self) {
        if let Some(pseudo) = self.0.take() {
            // Taking the slot makes this the only close of `pseudo`.
            sys::close_pseudo_console(pseudo);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::valid_name;

    #[test]
    fn roster_names_are_bounded_and_plain() {
        assert!(valid_name("u200000"));
        assert!(!valid_name(""));
        assert!(!valid_name("a".repeat(21).as_str()));
        assert!(!valid_name(r"DOMAIN\u1"));
        assert!(!valid_name("u1@host"));
    }
}
