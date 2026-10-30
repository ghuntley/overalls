//! Guest account reconciler and sshd key callback over Audi's private TLS route.

use lyra::guest::ssh_platform::{Invocation, Platform};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

const STATE: &str = "/var/lib/overalls-ssh/accounts.json";
const MAX_ROSTER: usize = 64 * 1024;
const ORIGIN: &str = "https://ssh.integration.internal/ssh/v1/";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Route {
    Roster,
    Authorize,
    Login,
}

impl Route {
    fn path(self) -> &'static str {
        match self {
            Self::Roster => "roster",
            Self::Authorize => "authorize",
            Self::Login => "login",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Account {
    username: String,
    uid: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Roster {
    version: u64,
    accounts: Vec<Account>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct State {
    version: u64,
    digest: String,
    accounts: Vec<Account>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Authorization {
    public_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginReceipt {
    login_id: String,
}

fn roster_digest(roster: &Roster) -> io::Result<String> {
    let mut accounts = roster.accounts.clone();
    accounts.sort_by(|left, right| left.username.cmp(&right.username));
    let bytes = serde_json::to_vec(&(roster.version, accounts)).map_err(io::Error::other)?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 32
        && (bytes[0].is_ascii_lowercase() || bytes[0] == b'_')
        && (bytes[bytes.len() - 1].is_ascii_lowercase()
            || bytes[bytes.len() - 1].is_ascii_digit()
            || bytes[bytes.len() - 1] == b'_')
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_.-".contains(byte))
        && ![
            "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp",
            "proxy", "www-data", "backup", "list", "irc", "gnats", "nobody", "ubuntu", "sshd",
            "sudo", "postgres",
        ]
        .contains(&name)
        && !name.starts_with("systemd-")
        && !name.starts_with("nixbld")
}

// @cc [owner:ghuntley,label:security] ssh-roster-unique-identity
// A roster MUST have a positive version, bounded size, safe unique names and
// unique non-system UIDs. Invalid data MUST cause no account mutation.
fn validate(roster: &Roster) -> io::Result<()> {
    let mut names = HashSet::new();
    let mut ids = HashSet::new();
    if roster.version == 0 || roster.accounts.len() > 512 {
        return Err(io::Error::other("invalid roster"));
    }
    for account in &roster.accounts {
        if !valid_name(&account.username)
            || !(200_000..=999_999).contains(&account.uid)
            || !names.insert(&account.username)
            || !ids.insert(account.uid)
        {
            return Err(io::Error::other("invalid roster"));
        }
    }
    Ok(())
}

fn run(program: &str, args: &[&str]) -> io::Result<()> {
    let status = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if status.success() {
        Ok(())
    } else {
        let event = match program {
            "groupadd" => "ssh.group_create_failed",
            "useradd" => "ssh.account_create_failed",
            "chown" => "ssh.home_ownership_failed",
            "usermod" => "ssh.account_state_failed",
            _ => "ssh.account_operation_failed",
        };
        emit(event, "warning");
        Err(io::Error::other("account operation failed"))
    }
}

fn existing(name: &str) -> io::Result<Option<(u32, u32, String)>> {
    let output = Command::new("getent")
        .args(["passwd", name])
        .stdin(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Ok(None);
    }
    if output.stdout.len() > 4096 {
        return Err(io::Error::other("invalid existing account"));
    }
    let line = std::str::from_utf8(&output.stdout).map_err(io::Error::other)?;
    let fields: Vec<&str> = line.trim_end().split(':').collect();
    if fields.len() != 7 || fields[0] != name {
        return Err(io::Error::other("invalid existing account"));
    }
    let uid = fields[2].parse::<u32>().map_err(io::Error::other)?;
    let gid = fields[3].parse::<u32>().map_err(io::Error::other)?;
    Ok(Some((uid, gid, fields[5].to_owned())))
}

fn existing_group(name: &str) -> io::Result<Option<u32>> {
    let output = Command::new("getent")
        .args(["group", name])
        .stdin(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Ok(None);
    }
    if output.stdout.len() > 4096 {
        return Err(io::Error::other("invalid existing group"));
    }
    let line = std::str::from_utf8(&output.stdout).map_err(io::Error::other)?;
    let fields: Vec<&str> = line.trim_end().split(':').collect();
    if fields.len() != 4 || fields[0] != name {
        return Err(io::Error::other("invalid existing group"));
    }
    Ok(Some(fields[2].parse::<u32>().map_err(io::Error::other)?))
}

fn home(account: &Account) -> PathBuf {
    Platform::current().home(&account.username)
}

// @cc [owner:ghuntley,label:security] guest-sudo-policy-filename
// Managed sudo policies MUST have filenames accepted by sudo's includedir,
// including for usernames containing dots. Retiring an account removes its
// uid-named policy.
fn sudo_policy(account: &Account) -> PathBuf {
    Path::new(Platform::current().sudoers()).join(format!("overalls_uid_{}", account.uid))
}

fn remove_policy(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// @cc [owner:ghuntley,label:product] guest-default-bash-shell
/// The managed shell MUST be /run/current-system/sw/bin/bash on NixOS and
/// /usr/local/bin/bash on FreeBSD and /bin/bash on other supported guests.
/// Missing or non-executable Bash MUST
/// fail selection without falling back to another shell or distribution path.
fn guest_shell(root: &Path) -> io::Result<PathBuf> {
    let shell = root.join(if root.join("etc/NIXOS").exists() {
        "run/current-system/sw/bin/bash"
    } else {
        Platform::current().shell()
    });
    let metadata = fs::metadata(&shell)?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(io::Error::other("guest Bash is not executable"));
    }
    Ok(shell)
}

fn activate(account: &Account, shell: &str) -> io::Result<()> {
    let platform = Platform::current();
    prepare_home_root(Path::new(platform.home_root()))?;
    let directory = home(account);
    let expected = directory
        .to_str()
        .ok_or_else(|| io::Error::other("invalid home"))?;
    match existing(&account.username)
        .inspect_err(|_| emit("ssh.account_lookup_failed", "warning"))?
    {
        Some((uid, gid, path)) if uid == account.uid && gid == account.uid && path == expected => {}
        Some(_) => return Err(io::Error::other("conflicting guest account")),
        None => {
            match existing_group(&account.username)? {
                Some(gid) if gid == account.uid => {}
                Some(_) => return Err(io::Error::other("conflicting guest group")),
                None => invoke(&platform.create_group(&account.username, account.uid))?,
            }
            invoke(&platform.create_user(&account.username, account.uid, expected, shell))?;
        }
    }
    let metadata = fs::symlink_metadata(&directory)
        .inspect_err(|_| emit("ssh.home_lookup_failed", "warning"))?;
    if !metadata.file_type().is_dir() {
        return Err(io::Error::other("invalid guest home"));
    }
    prepare_home(&directory, account.uid, account.uid)?;
    for action in platform.activate(&account.username, shell) {
        invoke(&action)?;
    }
    let body = format!("{} ALL=(ALL:ALL) NOPASSWD: ALL\n", account.username);
    write_atomic(&sudo_policy(account), body.as_bytes(), 0o440)
        .inspect_err(|_| emit("ssh.sudo_policy_failed", "warning"))?;
    Ok(())
}

fn deactivate(account: &Account) -> io::Result<()> {
    remove_policy(&sudo_policy(account))?;
    if existing(&account.username)?.is_some() {
        let nologin = if Path::new("/usr/sbin/nologin").exists() {
            "/usr/sbin/nologin"
        } else if Path::new("/run/current-system/sw/bin/nologin").exists() {
            "/run/current-system/sw/bin/nologin"
        } else {
            "/bin/sh"
        };
        for action in Platform::current().deactivate(&account.username, nologin) {
            invoke(&action)?;
        }
    }
    Ok(())
}

fn invoke(action: &Invocation) -> io::Result<()> {
    let arguments: Vec<&str> = action.arguments.iter().map(String::as_str).collect();
    run(action.program, &arguments)
}

/// @cc [owner:ghuntley,label:security] guest-managed-home-parent
/// The managed home parent MUST exist as a root-owned directory without group
/// or other write access before account creation. A trusted system symlink
/// such as FreeBSD's /home may resolve to that directory; managed user homes
/// themselves MUST still be opened without following a final symlink.
fn prepare_home_root(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    fs::create_dir_all(path)?;
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = directory.metadata()?;
    if metadata.uid() != 0 || metadata.permissions().mode() & 0o022 != 0 {
        return Err(io::Error::other("invalid managed home parent"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] guest-home-descriptor-ownership
/// Home ownership and mode changes MUST operate on the same opened directory,
/// refuse a final symlink/non-directory and retain mode 0700. They MUST NOT
/// follow a substituted home or recursively change user-owned contents.
fn prepare_home(path: &Path, uid: u32, gid: u32) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    // SAFETY: this is the live, no-follow directory descriptor, and the
    // validated roster UID is also its dedicated primary GID.
    if unsafe { libc::fchown(directory.as_raw_fd(), uid, gid) } != 0 {
        emit("ssh.home_ownership_failed", "warning");
        return Err(io::Error::last_os_error());
    }
    directory
        .set_permissions(fs::Permissions::from_mode(0o700))
        .inspect_err(|_| emit("ssh.home_permissions_failed", "warning"))
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("invalid state path"))?;
    fs::create_dir_all(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(mode))?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    temporary.persist(path).map_err(|error| error.error)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

// @cc [owner:ghuntley,label:security;concurrency] guest-account-reconciliation-lock
// Timer, stdin and on-demand reconciliation MUST hold the same root-owned
// exclusive lock through state validation, account changes and state commit.
fn account_lock() -> io::Result<File> {
    // SAFETY: geteuid has no preconditions and cannot fail.
    if unsafe { libc::geteuid() } != 0 {
        return Err(io::Error::other("account reconciliation requires root"));
    }
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(Platform::current().lock())?;
    fs2::FileExt::lock_exclusive(&lock)?;
    Ok(lock)
}

fn reconcile(roster: Roster) -> io::Result<()> {
    let _lock = account_lock()?;
    reconcile_locked(roster)
}

/// @cc [owner:ghuntley,label:product] guest-account-bash-reconciliation
/// Reconciliation MUST validate the distribution's executable Bash before
/// changing state or accounts, and MUST apply that shell on both creation and
/// refresh of every active managed account.
fn reconcile_locked(roster: Roster) -> io::Result<()> {
    validate(&roster).inspect_err(|_| emit("ssh.roster_invalid", "warning"))?;
    let digest = roster_digest(&roster)?;
    let previous: State = match fs::read(STATE) {
        Ok(bytes) if bytes.len() <= MAX_ROSTER => {
            serde_json::from_slice(&bytes).inspect_err(|_| emit("ssh.state_invalid", "warning"))?
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => State {
            version: 0,
            digest: String::new(),
            accounts: Vec::new(),
        },
        _ => {
            emit("ssh.state_invalid", "warning");
            return Err(io::Error::other("invalid previous state"));
        }
    };
    if roster.version < previous.version
        || (roster.version == previous.version && digest != previous.digest)
    {
        emit("ssh.roster_stale", "warning");
        return Err(io::Error::other("stale roster"));
    }
    let shell = guest_shell(Path::new("/"))
        .inspect_err(|_| emit("ssh.account_activate_failed", "warning"))?;
    let shell = shell
        .to_str()
        .ok_or_else(|| io::Error::other("invalid guest shell"))?;
    let mut journal = previous.accounts.clone();
    for account in &roster.accounts {
        if !journal.iter().any(|old| old.username == account.username) {
            journal.push(account.clone());
        }
    }
    write_atomic(
        Path::new(STATE),
        &serde_json::to_vec(&State {
            version: roster.version,
            digest: digest.clone(),
            accounts: journal,
        })
        .map_err(io::Error::other)?,
        0o600,
    )
    .inspect_err(|_| emit("ssh.state_stage_failed", "warning"))?;
    let desired: HashSet<&str> = roster
        .accounts
        .iter()
        .map(|account| account.username.as_str())
        .collect();
    for account in &previous.accounts {
        if !desired.contains(account.username.as_str()) {
            deactivate(account).inspect_err(|_| emit("ssh.account_disable_failed", "warning"))?;
        }
    }
    for account in &roster.accounts {
        activate(account, shell).inspect_err(|_| emit("ssh.account_activate_failed", "warning"))?;
    }
    write_atomic(
        Path::new(STATE),
        &serde_json::to_vec(&State {
            version: roster.version,
            digest,
            accounts: roster.accounts,
        })
        .map_err(io::Error::other)?,
        0o600,
    )
    .inspect_err(|_| emit("ssh.state_commit_failed", "warning"))
}

// @cc [owner:ghuntley,label:security] ssh-helper-private-authority
// SSH eligibility and rosters MUST come from verified private TLS with a short
// deadline and bounded response. Failure MUST never print an authorized key.
fn bounded_body(reader: impl Read, maximum: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.take((maximum + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > maximum {
        return Err(io::Error::other("private authority response too large"));
    }
    Ok(bytes)
}

fn private_client() -> io::Result<reqwest::blocking::Client> {
    lyra::private_http::client()
}

fn private_request(route: Route, body: Option<&[u8]>, maximum: usize) -> io::Result<Vec<u8>> {
    if (route == Route::Roster) != body.is_none() {
        return Err(io::Error::other("invalid private request"));
    }
    let client = private_client().inspect_err(|_| emit("ssh.tls_trust_failed", "warning"))?;
    let url = format!("{ORIGIN}{}", route.path());
    let request = match body {
        Some(bytes) => client
            .post(url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(bytes.to_vec()),
        None => client.get(url),
    };
    let response = request.send().map_err(|error| {
        let event = if error.is_timeout() {
            "ssh.authority_timeout"
        } else if error.is_connect() {
            "ssh.authority_connect_failed"
        } else {
            "ssh.authority_transport_failed"
        };
        emit(event, "warning");
        io::Error::other("private authority unavailable")
    })?;
    if !accepted_status(response.status()) {
        emit("ssh.authority_denied", "warning");
        return Err(io::Error::other("private authority unavailable"));
    }
    bounded_body(response, maximum).inspect_err(|_| {
        emit("ssh.authority_response_too_large", "warning");
    })
}

fn accepted_status(status: reqwest::StatusCode) -> bool {
    status == reqwest::StatusCode::OK
}

// @cc [owner:ghuntley,label:security] terminal-account-current-roster
// An on-demand account MUST appear in a fresh verified roster and MUST be
// reconciled by the same implementation as SSH before a terminal may open.
// Missing authority, unsafe names and reconciliation failure MUST deny access.
fn sync_roster(required_user: Option<&str>) -> io::Result<()> {
    if required_user.is_some_and(|user| !valid_name(user)) {
        return Err(io::Error::other("invalid username"));
    }
    let _lock = account_lock()?;
    let bytes = private_request(Route::Roster, None, MAX_ROSTER).inspect_err(|_| {
        emit("ssh.roster_fetch_failed", "warning");
    })?;
    let roster: Roster = serde_json::from_slice(&bytes).inspect_err(|_| {
        emit("ssh.roster_parse_failed", "warning");
    })?;
    require_account(&roster, required_user)?;
    reconcile_locked(roster).inspect_err(|_| {
        emit("ssh.roster_reconcile_failed", "warning");
    })
}

fn require_account(roster: &Roster, required_user: Option<&str>) -> io::Result<()> {
    validate(roster)?;
    if required_user.is_some_and(|user| {
        !roster
            .accounts
            .iter()
            .any(|account| account.username == user)
    }) {
        return Err(io::Error::other("account not authorized"));
    }
    Ok(())
}

fn offered_key(algorithm: &str, encoded: &str) -> io::Result<String> {
    if !matches!(
        algorithm,
        "ssh-ed25519"
            | "ssh-rsa"
            | "ecdsa-sha2-nistp256"
            | "ecdsa-sha2-nistp384"
            | "ecdsa-sha2-nistp521"
    ) || encoded.is_empty()
        || encoded.len() > 4096
        || !encoded
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
    {
        return Err(io::Error::other("invalid offered key"));
    }
    Ok(format!("{algorithm} {encoded}"))
}

fn authorize(username: &str, algorithm: &str, encoded: &str) -> io::Result<()> {
    if !valid_name(username) {
        return Err(io::Error::other("invalid username"));
    }
    let offered = offered_key(algorithm, encoded)?;
    let request = serde_json::to_vec(&serde_json::json!({
        "username": username,
        "public_key": offered,
    }))?;
    let response = private_request(Route::Authorize, Some(&request), 8192)?;
    let authorized: Authorization = serde_json::from_slice(&response)
        .inspect_err(|_| emit("ssh.authorization_parse_failed", "warning"))?;
    if authorized.public_key != offered {
        emit("ssh.authorization_key_mismatch", "warning");
        return Err(io::Error::other("key mismatch"));
    }
    println!("{}", authorized.public_key);
    Ok(())
}

fn pam_key(info: &str) -> io::Result<String> {
    if info.len() > 8192 || info.lines().count() != 1 {
        return Err(io::Error::other("invalid SSH authentication proof"));
    }
    let mut fields = info.split_whitespace();
    if fields.next() != Some("publickey") {
        return Err(io::Error::other("invalid SSH authentication proof"));
    }
    let algorithm = fields
        .next()
        .ok_or_else(|| io::Error::other("missing key algorithm"))?;
    let encoded = fields
        .next()
        .ok_or_else(|| io::Error::other("missing key bytes"))?;
    offered_key(algorithm, encoded)
}

fn login() -> io::Result<()> {
    if std::env::var("PAM_TYPE").as_deref() != Ok("open_session")
        || std::env::var("PAM_SERVICE").as_deref() != Ok("sshd")
    {
        return Err(io::Error::other("invalid PAM phase"));
    }
    let username = std::env::var("PAM_USER").map_err(io::Error::other)?;
    if !valid_name(&username) {
        return Err(io::Error::other("invalid PAM user"));
    }
    let info = std::env::var("SSH_AUTH_INFO_0").map_err(io::Error::other)?;
    let public_key = pam_key(&info)?;
    report_login(&username, &public_key)
}

fn report_login(username: &str, public_key: &str) -> io::Result<()> {
    let request = serde_json::to_vec(&serde_json::json!({
        "username": username,
        "public_key": public_key,
    }))?;
    let response = private_request(Route::Login, Some(&request), 8192)?;
    let receipt: LoginReceipt = serde_json::from_slice(&response)?;
    if receipt.login_id.len() != 36 {
        return Err(io::Error::other("invalid login receipt"));
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] native-ssh-session-authority-before-shell
/// A native forced SSH session MUST validate its real roster UID and private
/// regular OpenSSH authentication-info file, obtain a fresh successful private
/// login receipt for the exact offered public key, then replace itself with
/// the validated Bash. Failure MUST NOT launch a shell. Original SSH command
/// bytes MUST remain opaque arguments to a nonlogin Bash and MUST NOT enter
/// diagnostics. Sessions without an original command MUST use a login Bash.
#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn native_session() -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::process::CommandExt;

    let username = std::env::var("USER").map_err(|_| io::Error::other("missing SSH identity"))?;
    if !valid_name(&username) {
        return Err(io::Error::other("invalid SSH identity"));
    }
    // SAFETY: obtaining the current effective UID has no pointer arguments.
    let uid = unsafe { libc::geteuid() };
    let (account_uid, _, _) =
        existing(&username)?.ok_or_else(|| io::Error::other("missing SSH account"))?;
    if uid != account_uid || !(200_000..=999_999).contains(&uid) {
        return Err(io::Error::other("invalid SSH account"));
    }
    let path = std::env::var_os("SSH_USER_AUTH")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("missing SSH authentication proof"))?;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::other("invalid SSH authentication proof"));
    }
    let bytes = bounded_body(file, 8192)?;
    let info = std::str::from_utf8(&bytes)
        .map_err(|_| io::Error::other("invalid SSH authentication proof"))?;
    report_login(&username, &pam_key(info)?)?;
    emit("ssh.login_recorded", "info");
    let shell = guest_shell(Path::new("/"))?;
    let mut command = Command::new(shell);
    // sshd protects its initial Bash -c against startup files before this
    // receipt. The actual Bash can now apply the user's startup files. Match
    // OpenSSH's nonlogin -c command semantics so login profiles cannot corrupt
    // command output; interactive sessions retain their login profile.
    command
        .env_remove("SHLVL")
        .env_remove("BASH_ENV")
        .env_remove("ENV");
    if let Some(original) =
        std::env::var_os("SSH_ORIGINAL_COMMAND").filter(|value| !value.is_empty())
    {
        command.arg("-c").arg(original);
    } else {
        command.arg("-l");
    }
    Err(command.exec())
}

fn execute() -> io::Result<()> {
    // Native callbacks cannot reuse a previous boot's local account state as
    // authority. Every invocation obtains fresh validated MMDSv2 identity;
    // Audi still supplies the current VM/account/key authorization over TLS.
    #[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
    lyra::guest::mmds::fetch(std::time::Duration::from_secs(3))?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        #[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
        [command] if command == "session" => return native_session(),
        [command] if command == "sync" => return sync_roster(None),
        [command, user] if command == "ensure" => return sync_roster(Some(user)),
        [command] if command == "login" => return login(),
        [command, user, algorithm, encoded] if command == "authorize" => {
            return authorize(user, algorithm, encoded);
        }
        [command] if command == "reconcile" => {}
        _ => return Err(io::Error::other("unsupported command")),
    }
    let mut bytes = Vec::new();
    io::stdin()
        .take((MAX_ROSTER + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_ROSTER {
        return Err(io::Error::other("roster too large"));
    }
    let roster: Roster = serde_json::from_slice(&bytes)?;
    reconcile(roster)
}

// @cc [owner:ghuntley,label:observability] ssh-helper-closed-diagnostics
// Diagnostics MUST use fixed JSON events and MUST NOT include account names,
// keys, roster bytes, command arguments, or arbitrary error text.
fn emit(event: &str, severity: &str) {
    let message = format!(
        "{{\"service\":\"overalls-ssh-authorize\",\"event\":\"{event}\",\"severity\":\"{severity}\"}}"
    );
    eprintln!("{message}");
    if let Ok(socket) = UnixDatagram::unbound() {
        let priority = if severity == "warning" { "4" } else { "6" };
        let syslog = format!("<{priority}>overalls-ssh-authorize: {message}");
        let native = format!(
            "PRIORITY={priority}\nSYSLOG_IDENTIFIER=overalls-ssh-authorize\nMESSAGE={message}\n"
        );
        if socket.send_to(syslog.as_bytes(), "/dev/log").is_err() {
            let _ = socket.send_to(native.as_bytes(), "/run/systemd/journal/socket");
        }
    }
}

fn main() -> ExitCode {
    let command = std::env::args().nth(1);
    if execute().is_ok() {
        let event = match command.as_deref() {
            Some("authorize") => "ssh.key_eligible",
            Some("login") => "ssh.login_recorded",
            _ => "ssh.roster_reconciled",
        };
        emit(event, "info");
        ExitCode::SUCCESS
    } else {
        let event = match command.as_deref() {
            Some("authorize") => "ssh.key_denied",
            Some("login" | "session") => "ssh.login_denied",
            _ => "ssh.roster_rejected",
        };
        emit(event, "warning");
        ExitCode::FAILURE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    use std::io::Cursor;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn home_preparation_uses_real_directory_descriptor_and_rejects_symlinks() {
        use std::os::unix::fs::MetadataExt;
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("home");
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("retained"), b"retained").unwrap();
        let metadata = directory.metadata().unwrap();
        prepare_home(&directory, metadata.uid(), metadata.gid()).unwrap();
        let prepared = directory.metadata().unwrap();
        assert_eq!(prepared.permissions().mode() & 0o777, 0o700);
        assert_eq!(
            (prepared.uid(), prepared.gid()),
            (metadata.uid(), metadata.gid())
        );
        assert_eq!(fs::read(directory.join("retained")).unwrap(), b"retained");
        let link = root.path().join("substituted");
        std::os::unix::fs::symlink(&directory, &link).unwrap();
        assert!(prepare_home(&link, metadata.uid(), metadata.gid()).is_err());
        assert!(prepare_home(&directory.join("retained"), metadata.uid(), metadata.gid()).is_err());
    }

    #[test]
    fn nixos_requires_current_system_bash_without_distribution_fallback() {
        let root = tempfile::tempdir().unwrap();
        let ubuntu_bash = root.path().join("bin/bash");
        fs::create_dir_all(ubuntu_bash.parent().unwrap()).unwrap();
        fs::write(&ubuntu_bash, b"#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&ubuntu_bash, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(guest_shell(root.path()).unwrap(), ubuntu_bash);

        fs::create_dir_all(root.path().join("etc")).unwrap();
        fs::write(root.path().join("etc/NIXOS"), b"").unwrap();
        assert!(guest_shell(root.path()).is_err());

        let nixos_bash = root.path().join("run/current-system/sw/bin/bash");
        fs::create_dir_all(nixos_bash.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&ubuntu_bash, &nixos_bash).unwrap();
        assert_eq!(guest_shell(root.path()).unwrap(), nixos_bash);
        fs::set_permissions(&ubuntu_bash, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(guest_shell(root.path()).is_err());
    }

    #[test]
    fn ubuntu_requires_bash_to_be_an_executable_regular_file() {
        let root = tempfile::tempdir().unwrap();
        assert!(guest_shell(root.path()).is_err());
        let bash = root.path().join("bin/bash");
        fs::create_dir_all(&bash).unwrap();
        assert!(guest_shell(root.path()).is_err());

        fs::remove_dir(&bash).unwrap();
        fs::write(&bash, b"#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&bash, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(guest_shell(root.path()).is_err());
        fs::set_permissions(&bash, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(guest_shell(root.path()).unwrap(), bash);
    }

    #[hegel::test(test_cases = 100)]
    fn on_demand_accounts_require_exact_roster_membership(tc: TestCase) {
        let suffix = tc.draw(gs::integers::<u16>());
        let name = format!("guest.{suffix}");
        let account = Account {
            username: name.clone(),
            uid: 200_000 + u32::from(suffix),
        };
        let roster = Roster {
            version: 1,
            accounts: vec![account],
        };
        assert!(require_account(&roster, Some(&name)).is_ok());
        assert!(require_account(&roster, Some("root")).is_err());
        assert!(require_account(&roster, Some(&format!("other{suffix}"))).is_err());
        assert_eq!(home(&roster.accounts[0]), Path::new("/home").join(&name));
        let policy = sudo_policy(&roster.accounts[0]);
        let filename = policy.file_name().unwrap().to_str().unwrap();
        assert!(!filename.contains('.') && !filename.ends_with('~'));
        assert!(!filename.starts_with("overalls-"));
        assert!(require_account(
            &Roster {
                version: 0,
                accounts: roster.accounts
            },
            Some(&name)
        )
        .is_err());
    }

    #[test]
    fn rejects_duplicate_names_and_uids() {
        let account = Account {
            username: "geoffrey.huntley".into(),
            uid: 200_000,
        };
        assert!(validate(&Roster {
            version: 1,
            accounts: vec![account.clone()]
        })
        .is_ok());
        assert!(validate(&Roster {
            version: 1,
            accounts: vec![account.clone(), account]
        })
        .is_err());
    }

    #[test]
    fn authenticated_key_info_requires_publickey_and_canonical_fields() {
        let key =
            "ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAAIE10h2nLdSYgJPONwlhCys6F4ZgL1Qnc09ncBUr9NQnx";
        assert_eq!(
            pam_key(&format!("publickey {key} signature count = 1\n")).unwrap(),
            key
        );
        assert!(pam_key(&format!("password {key}\n")).is_err());
        assert!(pam_key(&format!("publickey {key}\npublickey {key}\n")).is_err());
        assert!(pam_key("publickey ssh-ed25519 invalid;payload").is_err());
    }

    #[test]
    fn roster_version_is_bound_to_names_and_uids() {
        let first = Roster {
            version: 7,
            accounts: vec![
                Account {
                    username: "alice".into(),
                    uid: 200_000,
                },
                Account {
                    username: "bob".into(),
                    uid: 200_001,
                },
            ],
        };
        let reversed = Roster {
            version: 7,
            accounts: first.accounts.iter().rev().cloned().collect(),
        };
        let changed = Roster {
            version: 7,
            accounts: vec![Account {
                username: "alice".into(),
                uid: 200_002,
            }],
        };
        assert_eq!(
            roster_digest(&first).unwrap(),
            roster_digest(&reversed).unwrap()
        );
        assert_ne!(
            roster_digest(&first).unwrap(),
            roster_digest(&changed).unwrap()
        );
    }

    #[test]
    fn private_client_rejects_redirects() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut connection, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1024];
            connection.read_exact(&mut request[..1]).unwrap();
            connection
                .write_all(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/leak\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .unwrap();
        });
        let response = private_client()
            .unwrap()
            .get(format!("http://{address}/"))
            .send()
            .unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::FOUND);
        server.join().unwrap();
    }

    #[test]
    fn private_request_rejects_method_body_mismatch_before_network() {
        assert!(private_request(Route::Roster, Some(b"{}"), 64).is_err());
        assert!(private_request(Route::Authorize, None, 64).is_err());
        assert!(private_request(Route::Login, None, 64).is_err());
    }

    #[hegel::test(test_cases = 100)]
    fn bounded_responses_preserve_exact_bytes_and_reject_overflow(tc: TestCase) {
        let bytes: Vec<u8> = tc
            .draw(gs::vecs(gs::integers::<u8>()))
            .into_iter()
            .take(512)
            .collect();
        let maximum = usize::from(tc.draw(gs::integers::<u8>()));
        let result = bounded_body(Cursor::new(&bytes), maximum);
        if bytes.len() <= maximum {
            assert_eq!(result.unwrap(), bytes);
        } else {
            assert!(result.is_err());
        }
    }

    #[hegel::test(test_cases = 100)]
    fn only_http_200_is_authorized(tc: TestCase) {
        let code = tc.draw(gs::integers::<u16>());
        if let Ok(status) = reqwest::StatusCode::from_u16(code) {
            assert_eq!(accepted_status(status), code == 200);
        }
    }

    #[hegel::test(test_cases = 100)]
    fn duplicate_guest_identity_is_always_rejected(tc: TestCase) {
        let uid = 200_000 + u32::from(tc.draw(gs::integers::<u16>()));
        let suffix = tc.draw(gs::integers::<u16>());
        let account = Account {
            username: format!("guest{suffix}"),
            uid,
        };
        assert!(validate(&Roster {
            version: 1,
            accounts: vec![account.clone()],
        })
        .is_ok());
        assert!(validate(&Roster {
            version: 1,
            accounts: vec![account.clone(), account],
        })
        .is_err());
    }

    #[hegel::test(test_cases = 100)]
    fn publickey_proof_preserves_only_the_offered_key(tc: TestCase) {
        let bytes: Vec<u8> = tc
            .draw(gs::vecs(gs::integers::<u8>()))
            .into_iter()
            .take(128)
            .collect();
        let encoded: String = bytes
            .iter()
            .map(|byte| char::from(b'A' + (byte % 26)))
            .collect();
        if encoded.is_empty() {
            return;
        }
        let offered = offered_key("ssh-ed25519", &encoded).unwrap();
        assert_eq!(
            pam_key(&format!("publickey {offered} signature count = 1")).unwrap(),
            offered
        );
        assert!(pam_key(&format!("publickey {offered}\npublickey {offered}")).is_err());
        assert!(pam_key(&format!("publickey ssh-ed25519 {encoded};inject")).is_err());
    }

    #[hegel::test(test_cases = 100)]
    fn any_accepted_name_stays_within_one_home_component(tc: TestCase) {
        let bytes = tc.draw(gs::vecs(gs::integers::<u8>()));
        let suffix: String = bytes
            .iter()
            .take(30)
            .map(|byte| char::from(b'a' + (byte % 26)))
            .collect();
        let name = format!("u{suffix}");
        assert!(valid_name(&name));
        assert_eq!(
            home(&Account {
                username: name,
                uid: 200_000
            })
            .parent(),
            Some(Path::new("/home"))
        );
    }
}
