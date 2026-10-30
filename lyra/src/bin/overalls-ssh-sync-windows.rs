//! Windows roster synchroniser (ADR-0171, gate 3): the counterpart of the
//! Linux `overalls-ssh-authorize` reconciler for a sshd that cannot ask per
//! connection.
//!
//! Every two seconds it fetches the guest's roster and the roster writers'
//! registered keys over Audi's private TLS route, reconciles local accounts
//! through the Net API (create, enable, disable; never delete), writes one
//! `AuthorizedKeysFile` per account under `C:\overalls\ssh\authorized_keys`
//! (SYSTEM-owned, readable by that account only) and, after the first applied
//! roster and a current host certificate, starts `sshd` with prior-boot keys
//! removed and publishes the `ssh-ready` marker. Ordinary key retrieval follows
//! readiness under its existing completed-start authority. It retires the
//! image's bootstrap Administrator after applying the keys. It also tails
//! sshd's file log and reports each accepted public-key login to the authority,
//! as the Linux PAM hook does. Logs are closed event names; no key, name or
//! token is written. Runs as a SYSTEM task; exits 64 on other operating systems.

#[cfg(windows)]
mod sync {
    use lyra::guest::ssh_bootstrap;
    use lyra::guest::ssh_login;
    use lyra::guest::ssh_roster::{self, Account, Roster, Route, State, StateStore, ORIGIN};
    use lyra::platform::windows::accounts::{self, NetAccounts};
    use lyra::platform::windows::log::Logger;
    use lyra::platform::windows::{boot_id, services};
    use serde::Deserialize;
    use std::collections::HashMap;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Read, Seek, SeekFrom, Write};
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    const TRUST_DIR: &str = "C:\\overalls\\trust";
    const SSH_DIR: &str = "C:\\overalls\\ssh";
    const KEYS_DIR: &str = "C:\\overalls\\ssh\\authorized_keys";
    const STATE: &str = "C:\\overalls\\ssh\\accounts.json";
    const LOCK: &str = "C:\\overalls\\ssh\\accounts.lock";
    const RUN_DIR: &str = "C:\\overalls\\run";
    const ADMINISTRATOR_RETIRED: &str = "C:\\overalls\\run\\administrator-retired";
    const INTERVAL: Duration = Duration::from_secs(2);
    const MAX_KEYS_BODY: usize = 1024 * 1024;
    const MAX_LOG_CHUNK: u64 = 1024 * 1024;

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct KeyedAccount {
        username: String,
        uid: u32,
        keys: Vec<String>,
    }

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct AuthorizedKeys {
        version: u64,
        accounts: Vec<KeyedAccount>,
    }

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LoginReceipt {
        login_id: String,
    }

    /// The PEM bundle the trust daemon last published, if any.
    fn bundle_path() -> Option<String> {
        let current = fs::read_to_string(Path::new(TRUST_DIR).join("current")).ok()?;
        let name = current.trim();
        if name.is_empty() || name.contains(['\\', '/', ':']) {
            return None;
        }
        Some(format!("{TRUST_DIR}\\{name}\\ca-bundle.pem"))
    }

    fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("invalid path"))?;
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(
            ".{}.next",
            path.file_name().and_then(|n| n.to_str()).unwrap_or("state")
        ));
        let mut file = File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        if path.exists() {
            fs::remove_file(path)?;
        }
        fs::rename(&temporary, path)
    }

    struct FileStore(PathBuf);

    /// @cc [owner:ghuntley,label:security;concurrency] windows-roster-single-writer
    /// The daemon and on-demand reconciler MUST hold the same no-follow file
    /// lock through fetching, checking and committing the roster. Lock failure
    /// or a five-second contention deadline MUST refuse without account changes.
    fn roster_lock() -> io::Result<File> {
        let file = lyra::platform::open_private(
            Path::new(LOCK),
            OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false),
        )?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match fs2::FileExt::try_lock_exclusive(&file) {
                Ok(()) => return Ok(file),
                Err(error)
                    if error.raw_os_error() == fs2::lock_contended_error().raw_os_error()
                        && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => return Err(io::Error::other("account reconciliation unavailable")),
            }
        }
    }

    impl StateStore for FileStore {
        fn load(&self) -> io::Result<Option<State>> {
            match fs::read(&self.0) {
                Ok(bytes) if bytes.len() <= ssh_roster::MAX_ROSTER => {
                    serde_json::from_slice(&bytes)
                        .map(Some)
                        .map_err(io::Error::other)
                }
                Ok(_) => Err(io::Error::other("oversized state")),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error),
            }
        }

        fn store(&mut self, state: &State) -> io::Result<()> {
            write_atomic(&self.0, &serde_json::to_vec(state)?)
        }
    }

    fn bounded(response: reqwest::blocking::Response, maximum: usize) -> io::Result<Vec<u8>> {
        if response.status() != reqwest::StatusCode::OK {
            return Err(io::Error::other("private authority denied"));
        }
        let mut bytes = Vec::new();
        response.take(maximum as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > maximum {
            return Err(io::Error::other("private authority response too large"));
        }
        Ok(bytes)
    }

    fn fetch(
        client: &reqwest::blocking::Client,
        route: Route,
        maximum: usize,
    ) -> io::Result<Vec<u8>> {
        let response = client
            .get(format!("{ORIGIN}{}", route.path()))
            .send()
            .map_err(|_| io::Error::other("private authority unavailable"))?;
        bounded(response, maximum)
    }

    /// @cc [owner:ghuntley,label:security;observability] windows-login-receipt-exact-key
    /// A login is reported only for an sshd-accepted public-key authentication
    /// whose fingerprint matches one of the keys this agent pulled for that very
    /// account; the report names the account and that key and nothing else from
    /// the log line, and a refused report is logged, never retried with other data.
    fn report_login(
        client: &reqwest::blocking::Client,
        username: &str,
        public_key: &str,
    ) -> io::Result<()> {
        let body = serde_json::to_vec(&serde_json::json!({
            "username": username,
            "public_key": public_key,
        }))?;
        let response = client
            .post(format!("{ORIGIN}{}", Route::Login.path()))
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .map_err(|_| io::Error::other("private authority unavailable"))?;
        let receipt: LoginReceipt = serde_json::from_slice(&bounded(response, 8192)?)
            .map_err(|_| io::Error::other("invalid login receipt"))?;
        if receipt.login_id.len() != 36 {
            return Err(io::Error::other("invalid login receipt"));
        }
        Ok(())
    }

    fn tool(program: &str, arguments: &[&str]) -> io::Result<bool> {
        let system = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        let path = Path::new(&system).join("System32").join(program);
        Ok(Command::new(path)
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?
            .success())
    }

    /// @cc [owner:ghuntley,label:security] windows-authorized-keys-file-acl
    /// Each account's key file MUST be rewritten whole, hold only that account's
    /// keys one per line, and carry an ACL of SYSTEM and Administrators full
    /// control plus read for the account itself and nobody else, so sshd's
    /// strict-modes check and the identity binding both hold.
    fn write_keys(account: &Account, keys: &[String]) -> io::Result<()> {
        let path = Path::new(KEYS_DIR).join(&account.username);
        let mut body = String::new();
        for key in keys {
            if key.len() > 8192 || key.contains('\n') || key.contains('\r') {
                return Err(io::Error::other("invalid authorized key"));
            }
            body.push_str(key);
            body.push('\n');
        }
        write_atomic(&path, body.as_bytes())?;
        let grant_user = format!("{}:(R)", account.username);
        let file = path.to_string_lossy().into_owned();
        if !tool(
            "icacls.exe",
            &[
                &file,
                "/inheritance:r",
                "/grant:r",
                "SYSTEM:(F)",
                "Administrators:(F)",
                &grant_user,
            ],
        )? {
            return Err(io::Error::other("authorized keys ACL failed"));
        }
        Ok(())
    }

    /// Keys per account as last applied, for matching login fingerprints.
    type KeyIndex = HashMap<String, Vec<String>>;

    fn apply_keys(state: &State, listing: &AuthorizedKeys) -> io::Result<KeyIndex> {
        fs::create_dir_all(KEYS_DIR)?;
        let mut index = KeyIndex::new();
        for account in &state.accounts {
            let keys = listing
                .accounts
                .iter()
                .find(|entry| entry.username == account.username && entry.uid == account.uid)
                .map(|entry| entry.keys.clone())
                .unwrap_or_default();
            write_keys(account, &keys)?;
            index.insert(account.username.clone(), keys);
        }
        Ok(index)
    }

    fn start_sshd() -> io::Result<()> {
        if services::running("sshd")? {
            return Ok(());
        }
        let _ = tool("sc.exe", &["start", "sshd"])?;
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(10) {
            if services::running("sshd")? {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Err(io::Error::other("sshd start failed"))
    }

    fn stop_sshd() -> io::Result<()> {
        if services::stopped("sshd")? {
            return Ok(());
        }
        let _ = tool("sc.exe", &["stop", "sshd"])?;
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(10) {
            if services::stopped("sshd")? {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Err(io::Error::other("sshd stop failed"))
    }

    struct Bootstrap;

    impl ssh_bootstrap::Host for Bootstrap {
        fn bootstrap_current(&self) -> bool {
            boot_id::marker_is_current(Path::new(ssh_bootstrap::READY))
        }

        fn certificate_current(&self) -> bool {
            boot_id::marker_is_current(Path::new(ssh_bootstrap::CERTIFICATE_READY))
        }

        fn stop_listener(&mut self) -> io::Result<()> {
            stop_sshd()
        }

        fn clear_keys(&mut self) -> io::Result<()> {
            ssh_bootstrap::clear_keys(Path::new(KEYS_DIR))
        }

        fn start_listener(&mut self) -> io::Result<()> {
            start_sshd()
        }

        fn publish_ready(&mut self) -> io::Result<()> {
            boot_id::write_marker(Path::new(ssh_bootstrap::READY))
        }
    }

    fn roster_pass(
        client: &reqwest::blocking::Client,
        store: &mut FileStore,
        accounts: &mut NetAccounts,
    ) -> io::Result<State> {
        let _lock = roster_lock()?;
        let roster: Roster =
            serde_json::from_slice(&fetch(client, Route::Roster, ssh_roster::MAX_ROSTER)?)
                .map_err(|_| io::Error::other("invalid roster"))?;
        ssh_roster::reconcile(roster, store, accounts)
    }

    /// @cc [owner:ghuntley,label:security] windows-editor-account-current-authority
    /// An editor account MUST be fetched over fresh verified private TLS and
    /// match both requested name and UID before the shared reconciler runs.
    /// Missing trust, stale roster or reconciliation failure MUST return failure
    /// with no credentials, identity, response body or arguments in diagnostics.
    pub(crate) fn ensure_account(username: &str, uid: u32) -> io::Result<()> {
        if !ssh_roster::valid_name(username) || !ssh_roster::UID_RANGE.contains(&uid) {
            return Err(io::Error::other("invalid account"));
        }
        let _lock = roster_lock()?;
        let bundle = bundle_path().ok_or_else(|| io::Error::other("trust unavailable"))?;
        std::env::set_var("OVERALLS_SSH_CA_BUNDLE", bundle);
        let client = lyra::private_http::client()?;
        let roster: Roster =
            serde_json::from_slice(&fetch(&client, Route::Roster, ssh_roster::MAX_ROSTER)?)
                .map_err(|_| io::Error::other("invalid roster"))?;
        ssh_roster::require_identity(&roster, username, uid)?;
        let mut store = FileStore(PathBuf::from(STATE));
        ssh_roster::reconcile(roster, &mut store, &mut NetAccounts)?;
        Ok(())
    }

    fn keys_pass(client: &reqwest::blocking::Client, state: &State) -> io::Result<KeyIndex> {
        let listing: AuthorizedKeys =
            serde_json::from_slice(&fetch(client, Route::AuthorizedKeys, MAX_KEYS_BODY)?)
                .map_err(|_| io::Error::other("invalid authorized keys"))?;
        if listing.version == 0 {
            return Err(io::Error::other("invalid authorized keys"));
        }
        apply_keys(state, &listing)
    }

    /// @cc [owner:ghuntley,label:security;recovery] windows-key-fetch-after-bootstrap
    /// Ordinary authorized-key retrieval MUST occur only after current-boot
    /// roster reconciliation and keyless listener bootstrap. A denied fetch
    /// MUST retain the last current-boot key index for login receipts and MUST
    /// NOT prevent the already-published bootstrap from completing readiness.
    fn advance_ssh(
        client: &reqwest::blocking::Client,
        state: &State,
        index: &mut KeyIndex,
        logger: &Logger,
    ) -> io::Result<()> {
        let was_current = boot_id::marker_is_current(Path::new(ssh_bootstrap::READY));
        if !ssh_bootstrap::ensure(&mut Bootstrap)? {
            logger.log("host_certificate_pending");
            return Ok(());
        }
        if !was_current {
            logger.log("sshd_started");
            logger.publish();
        }
        *index = keys_pass(client, state)?;
        if !state.accounts.is_empty() && !Path::new(ADMINISTRATOR_RETIRED).exists() {
            match accounts::retire_bootstrap_administrator()
                .and_then(|()| fs::write(ADMINISTRATOR_RETIRED, b"retired\n"))
            {
                Ok(()) => {
                    logger.log("administrator_retired");
                    logger.publish();
                }
                Err(error) => logger.log(&format!(
                    "administrator_retire_failed kind={:?}",
                    error.kind()
                )),
            }
        }
        Ok(())
    }

    /// Tail sshd's file log from the last offset; return the new complete lines.
    struct LogTail {
        path: PathBuf,
        offset: u64,
        partial: String,
    }

    impl LogTail {
        fn new() -> Self {
            let program_data =
                std::env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into());
            Self {
                path: Path::new(&program_data)
                    .join("ssh")
                    .join("logs")
                    .join("sshd.log"),
                offset: 0,
                partial: String::new(),
            }
        }

        fn new_lines(&mut self) -> Vec<String> {
            let Ok(mut file) = File::open(&self.path) else {
                return Vec::new();
            };
            let length = file.metadata().map_or(0, |m| m.len());
            if length < self.offset {
                // Rotated or truncated: start over.
                self.offset = 0;
                self.partial.clear();
            }
            if file.seek(SeekFrom::Start(self.offset)).is_err() {
                return Vec::new();
            }
            let mut chunk = Vec::new();
            if (&mut file)
                .take(MAX_LOG_CHUNK)
                .read_to_end(&mut chunk)
                .is_err()
            {
                return Vec::new();
            }
            self.offset += chunk.len() as u64;
            self.partial.push_str(&String::from_utf8_lossy(&chunk));
            let mut lines = Vec::new();
            while let Some((line, rest)) = self.partial.split_once('\n') {
                let line = line.trim_end_matches('\r').to_owned();
                self.partial = rest.to_owned();
                lines.push(line);
            }
            lines
        }
    }

    fn report_logins(
        client: &reqwest::blocking::Client,
        tail: &mut LogTail,
        index: &KeyIndex,
        logger: &Logger,
    ) {
        for line in tail.new_lines() {
            let Some(accepted) = ssh_login::parse_accepted(&line) else {
                continue;
            };
            let matched = index
                .get(&accepted.username)
                .and_then(|keys| ssh_login::matching_key(keys, &accepted));
            match matched {
                Some(public_key) => match report_login(client, &accepted.username, public_key) {
                    Ok(()) => logger.log("login_recorded"),
                    Err(_) => logger.log("login_report_refused"),
                },
                None => logger.log("login_key_unmatched"),
            }
        }
    }

    pub(crate) fn run() -> i32 {
        let logger = Logger::new("ssh-sync");
        logger.log("start");
        let _ = fs::create_dir_all(SSH_DIR);
        let _ = fs::create_dir_all(RUN_DIR);
        let mut store = FileStore(PathBuf::from(STATE));
        let mut accounts = NetAccounts;
        let mut client: Option<reqwest::blocking::Client> = None;
        let mut tail = LogTail::new();
        let mut index = KeyIndex::new();
        let mut announced = false;
        let mut last_version = 0u64;
        loop {
            if client.is_none() {
                match bundle_path() {
                    Some(bundle) => {
                        std::env::set_var("OVERALLS_SSH_CA_BUNDLE", &bundle);
                        match lyra::private_http::client() {
                            Ok(built) => {
                                logger.log("private_client_ready");
                                client = Some(built);
                            }
                            Err(_) => logger.log("private_client_unavailable"),
                        }
                    }
                    None => {
                        if !announced {
                            logger.log("trust_bundle_pending");
                            announced = true;
                        }
                    }
                }
            }
            if let Some(ready) = client.as_ref() {
                match roster_pass(ready, &mut store, &mut accounts) {
                    Ok(state) => {
                        if state.version != last_version {
                            last_version = state.version;
                            logger.log(&format!(
                                "roster_applied version={} accounts={}",
                                state.version,
                                state.accounts.len()
                            ));
                        }
                        if let Err(error) = advance_ssh(ready, &state, &mut index, &logger) {
                            logger.log(&format!("pass_failed kind={:?}", error.kind()));
                        }
                    }
                    Err(error) => logger.log(&format!("pass_failed kind={:?}", error.kind())),
                }
                report_logins(ready, &mut tail, &index, &logger);
            }
            std::thread::sleep(INTERVAL);
        }
    }
}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).take(4).collect();
    let status = match arguments.as_slice() {
        [] => sync::run(),
        [operation, username, uid] if operation == "--ensure-account" => match uid.parse::<u32>() {
            Ok(parsed) if parsed.to_string() == *uid => {
                i32::from(sync::ensure_account(username, parsed).is_err())
            }
            _ => 64,
        },
        _ => 64,
    };
    std::process::exit(status);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-ssh-sync-windows runs inside Windows guests only");
    std::process::exit(64);
}
