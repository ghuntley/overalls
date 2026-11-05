//! Private durable accounting for authorized, parsed inference requests.
//! Provider effects are never replayed. Only fixed numeric snapshots leave this journal.

use futures::StreamExt;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const CAPACITY: i64 = 4096;
const MAX_COUNTER: u64 = (1_u64 << 63) - 1;
/// Journal file name. The unified 15-bound totals start a fresh journal; no code
/// reads or migrates the retired seven-bound `slo.sqlite` (ADR-0159).
const JOURNAL_FILE: &str = "slo-totals.sqlite";
const BOUNDS_US: [u64; 15] = [
    10_000,
    50_000,
    100_000,
    500_000,
    1_000_000,
    5_000_000,
    10_000_000,
    30_000_000,
    60_000_000,
    120_000_000,
    300_000_000,
    900_000_000,
    3_600_000_000,
    21_600_000_000,
    86_400_000_000,
];

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid accounting state")]
    Invalid,
    #[error("accounting is unavailable")]
    Unavailable,
    #[error("accounting capacity exhausted")]
    Full,
    #[error("accounting journal already owned")]
    Locked,
    #[error("accounting storage failure")]
    Io(#[from] std::io::Error),
    #[error("accounting transaction failure")]
    Sql(#[from] rusqlite::Error),
    #[error("accounting schema failure")]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Totals {
    started_at_unix_nano: u64,
    incarnation: String,
    requests: u64,
    successes: u64,
    failures: u64,
    duration_count: u64,
    duration_sum_us: u64,
    bucket_counts: [u64; 16],
}

impl Totals {
    fn new() -> Result<Self, Error> {
        Ok(Self {
            started_at_unix_nano: now_ns()?,
            incarnation: uuid::Uuid::new_v4().simple().to_string(),
            requests: 0,
            successes: 0,
            failures: 0,
            duration_count: 0,
            duration_sum_us: 0,
            bucket_counts: [0; 16],
        })
    }

    fn valid(&self) -> Result<(), Error> {
        let counters = [
            self.requests,
            self.successes,
            self.failures,
            self.duration_count,
            self.duration_sum_us,
        ];
        let sum = self
            .bucket_counts
            .iter()
            .try_fold(0_u64, |sum, value| sum.checked_add(*value));
        if counters
            .iter()
            .chain(self.bucket_counts.iter())
            .any(|value| *value > MAX_COUNTER)
            || self.successes.checked_add(self.failures) != Some(self.requests)
            || sum != Some(self.duration_count)
            || self.duration_count > self.requests
            || self.started_at_unix_nano == 0
            || self.started_at_unix_nano > now_ns()?.saturating_add(2_000_000_000)
            || self.incarnation.len() != 32
            || !self
                .incarnation
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }

    fn record(&mut self, success: bool, duration_us: Option<u64>) -> Result<(), Error> {
        let add = |old: u64, amount: u64| {
            old.checked_add(amount)
                .filter(|value| *value <= MAX_COUNTER)
                .ok_or(Error::Invalid)
        };
        self.requests = add(self.requests, 1)?;
        if success {
            self.successes = add(self.successes, 1)?;
        } else {
            self.failures = add(self.failures, 1)?;
        }
        if let Some(duration) = duration_us {
            let index = BOUNDS_US
                .iter()
                .position(|bound| duration <= *bound)
                .unwrap_or(15);
            self.duration_count = add(self.duration_count, 1)?;
            self.duration_sum_us = add(self.duration_sum_us, duration)?;
            self.bucket_counts[index] = add(self.bucket_counts[index], 1)?;
        }
        self.valid()
    }

    fn snapshot(&self) -> Result<serde_json::Value, Error> {
        self.valid()?;
        Ok(serde_json::json!({
            "version": 1, "service": "underclass_proxy", "sampled_at_unix_nano": now_ns()?,
            "started_at_unix_nano": self.started_at_unix_nano,
            "incarnation": self.incarnation, "invocation_id": self.incarnation,
            "requests": self.requests, "successes": self.successes, "failures": self.failures,
            "duration": { "count": self.duration_count, "sum_us": self.duration_sum_us,
                "explicit_bounds_us": BOUNDS_US, "bucket_counts": self.bucket_counts }
        }))
    }
}

pub struct Journal {
    conn: Mutex<Connection>,
    fenced: AtomicBool,
    _lock: File,
}

impl Journal {
    /// @cc [owner:ghuntley,label:security;recovery] underclass-private-journal-recovery
    /// Restore only an owned private bounded journal. A second process MUST NOT
    /// recover another live process's admissions. Restart MUST turn each pending
    /// admission into one failure with unknown duration without provider replay.
    pub fn open(directory: &Path) -> Result<Arc<Self>, Error> {
        // systemd DynamicUser may expose StateDirectory through its owned symlink.
        let directory = fs::canonicalize(directory)?;
        let directory_meta = fs::symlink_metadata(&directory)?;
        if !directory_meta.is_dir() || !private(&directory_meta)? {
            return Err(Error::Invalid);
        }
        let lock_path = directory.join("slo.lock");
        let lock = private_file(&lock_path)?;
        lock.try_lock().map_err(|_| Error::Locked)?;
        let db_path = directory.join(JOURNAL_FILE);
        let _db_file = private_file(&db_path)?;
        if _db_file.metadata()?.len() > 32 * 1024 * 1024 {
            return Err(Error::Invalid);
        }
        let mut conn = Connection::open(&db_path)?;
        conn.busy_timeout(std::time::Duration::from_secs(1))?;
        conn.execute_batch("PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS slo_totals (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=1), totals TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS slo_pending (id TEXT PRIMARY KEY NOT NULL);")?;
        let tx = conn.transaction()?;
        let pending: i64 =
            tx.query_row("SELECT count(*) FROM slo_pending", [], |row| row.get(0))?;
        if !(0..=CAPACITY).contains(&pending) {
            return Err(Error::Invalid);
        }
        let invalid: i64 = tx.query_row(
            "SELECT count(*) FROM slo_pending WHERE typeof(id) != 'text' OR length(id) != 36",
            [],
            |row| row.get(0),
        )?;
        if invalid != 0 {
            return Err(Error::Invalid);
        }
        {
            let mut rows = tx.prepare("SELECT id FROM slo_pending")?;
            for row in rows.query_map([], |row| row.get::<_, String>(0))? {
                let id = row?;
                if uuid::Uuid::parse_str(&id)
                    .map_err(|_| Error::Invalid)?
                    .to_string()
                    != id
                {
                    return Err(Error::Invalid);
                }
            }
        }
        let mut totals = match read_totals(&tx)? {
            Some(totals) => totals,
            None if pending == 0 => Totals::new()?,
            None => return Err(Error::Invalid),
        };
        for _ in 0..pending {
            totals.record(false, None)?;
        }
        save_totals(&tx, &totals)?;
        tx.execute("DELETE FROM slo_pending", [])?;
        tx.commit()?;
        File::open(&directory)?.sync_all()?;
        Ok(Arc::new(Self {
            conn: Mutex::new(conn),
            fenced: AtomicBool::new(false),
            _lock: lock,
        }))
    }

    /// @cc [owner:ghuntley,label:durability;reliability] underclass-admit-before-provider
    /// Admission MUST commit before any provider effect. Full or uncertain
    /// accounting MUST refuse new effects. Payload, model, account and caller
    /// identifiers MUST NOT enter the journal or exported metrics.
    pub fn admit(self: &Arc<Self>) -> Result<Admission, Error> {
        if self.fenced.load(Ordering::SeqCst) {
            return Err(Error::Unavailable);
        }
        let id = uuid::Uuid::new_v4().to_string();
        let mut conn = self.conn.lock().map_err(|_| Error::Unavailable)?;
        if self.fenced.load(Ordering::SeqCst) {
            return Err(Error::Unavailable);
        }
        let result = (|| {
            let tx = conn.transaction()?;
            let count: i64 =
                tx.query_row("SELECT count(*) FROM slo_pending", [], |row| row.get(0))?;
            if count >= CAPACITY {
                let mut totals = read_totals(&tx)?.ok_or(Error::Invalid)?;
                totals.record(false, None)?;
                save_totals(&tx, &totals)?;
                tx.commit()?;
                return Err(Error::Full);
            }
            tx.execute("INSERT INTO slo_pending(id) VALUES (?1)", [&id])?;
            tx.commit()?;
            Ok(Admission {
                journal: Arc::clone(self),
                id: Some(id),
                started: Instant::now(),
            })
        })();
        if result.is_err() && !matches!(result, Err(Error::Full)) {
            self.fenced.store(true, Ordering::SeqCst);
        }
        result
    }

    /// @cc [owner:ghuntley,label:durability;recovery] underclass-terminal-once
    /// An admitted terminal outcome MUST update fixed aggregate totals and remove
    /// its pending identity in one durable transaction. Repeated finalization MUST
    /// NOT count twice. Uncertain persistence MUST fence admission and publication.
    fn finish(&self, id: &str, success: bool, duration_us: Option<u64>) -> Result<(), Error> {
        if self.fenced.load(Ordering::SeqCst) {
            return Err(Error::Unavailable);
        }
        let mut conn = self.conn.lock().map_err(|_| Error::Unavailable)?;
        if self.fenced.load(Ordering::SeqCst) {
            return Err(Error::Unavailable);
        }
        let result = (|| {
            let tx = conn.transaction()?;
            if tx.execute("DELETE FROM slo_pending WHERE id=?1", [id])? == 0 {
                return Ok(());
            }
            let mut totals = read_totals(&tx)?.ok_or(Error::Invalid)?;
            totals.record(success, duration_us)?;
            save_totals(&tx, &totals)?;
            tx.commit()?;
            Ok(())
        })();
        if result.is_err() {
            self.fenced.store(true, Ordering::SeqCst);
        }
        result
    }

    pub fn publish(&self, path: &Path) -> Result<(), Error> {
        self.publish_with_group(path, false)
    }

    /// @cc [owner:ghuntley,label:security] underclass-source-group-snapshot
    /// Group-readable snapshots MUST remain in an owned mode-0750 directory
    /// and use mode 0640 with that directory's source group. The independent
    /// exporter MUST NOT share the producer UID or receive provider credentials.
    pub fn publish_group(&self, path: &Path) -> Result<(), Error> {
        let directory = path.parent().ok_or(Error::Invalid)?;
        match fs::DirBuilder::new().mode(0o750).create(directory) {
            Ok(()) => fs::set_permissions(directory, fs::Permissions::from_mode(0o750))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        self.publish_with_group(path, true)
    }

    fn publish_with_group(&self, path: &Path, group_readable: bool) -> Result<(), Error> {
        if self.fenced.load(Ordering::SeqCst) {
            return Err(Error::Unavailable);
        }
        let conn = self.conn.lock().map_err(|_| Error::Unavailable)?;
        if self.fenced.load(Ordering::SeqCst) {
            return Err(Error::Unavailable);
        }
        let snapshot = read_totals(&conn)?.ok_or(Error::Invalid)?.snapshot()?;
        let bytes = serde_json::to_vec(&snapshot)?;
        let parent = fs::symlink_metadata(path.parent().ok_or(Error::Invalid)?)?;
        let process = fs::metadata("/proc/self")?;
        if group_readable
            && (!parent.is_dir()
                || parent.mode() & 0o777 != 0o750
                || parent.uid() != process.uid()
                || parent.gid() != process.gid())
        {
            return Err(Error::Invalid);
        }
        let stage: PathBuf = path.with_extension("pending");
        if let Ok(meta) = fs::symlink_metadata(&stage) {
            let custody = if group_readable {
                meta.uid() == process.uid()
                    && meta.gid() == parent.gid()
                    && matches!(meta.mode() & 0o777, 0o600 | 0o640)
            } else {
                private(&meta)?
            };
            if !meta.is_file() || meta.nlink() != 1 || !custody {
                return Err(Error::Invalid);
            }
            fs::remove_file(&stage)?;
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&stage)?;
        file.write_all(&bytes)?;
        if group_readable {
            if file.metadata()?.gid() != parent.gid() {
                return Err(Error::Invalid);
            }
            file.set_permissions(fs::Permissions::from_mode(0o640))?;
        }
        fs::rename(&stage, path)?;
        Ok(())
    }
}

pub struct Admission {
    journal: Arc<Journal>,
    id: Option<String>,
    started: Instant,
}

impl Admission {
    pub fn finish(mut self, success: bool) -> Result<(), Error> {
        let id = self.id.take().ok_or(Error::Invalid)?;
        let elapsed =
            u64::try_from(self.started.elapsed().as_micros()).map_err(|_| Error::Invalid)?;
        self.journal.finish(&id, success, Some(elapsed))
    }

    /// @cc [owner:ghuntley,label:reliability;proxy] underclass-complete-stream-outcome
    /// A successful status MUST NOT become success before body EOF. SSE success
    /// additionally requires a provider terminal completion marker and no error
    /// marker. Transport errors and dropped bodies MUST finalize one failure;
    /// retries within one admitted request MUST NOT create additional outcomes.
    pub fn wrap_response(self, response: axum::response::Response) -> axum::response::Response {
        let (parts, body) = response.into_parts();
        let event_stream = parts
            .headers
            .get(axum::http::header::CONTENT_TYPE)
            .is_some_and(|value| value.as_bytes().starts_with(b"text/event-stream"));
        let state = BodyState {
            stream: body.into_data_stream(),
            admission: Some(self),
            tap: TerminalTap::default(),
            event_stream,
            success_status: parts.status.is_success(),
            finished: false,
        };
        let stream = futures::stream::unfold(state, |mut state| async move {
            if state.finished {
                return None;
            }
            match state.stream.next().await {
                Some(Ok(chunk)) => {
                    if state.event_stream {
                        state.tap.feed(&chunk);
                    }
                    Some((Ok::<_, std::io::Error>(chunk), state))
                }
                Some(Err(_)) => {
                    state.finished = true;
                    if let Some(admission) = state.admission.take() {
                        let _ = admission.finish(false);
                    }
                    Some((Err(std::io::Error::other("upstream stream failed")), state))
                }
                None => {
                    state.finished = true;
                    let success = state.success_status
                        && (!state.event_stream || state.tap.completed)
                        && !state.tap.failed;
                    match state
                        .admission
                        .take()
                        .map(|admission| admission.finish(success))
                    {
                        Some(Err(_)) => Some((
                            Err(std::io::Error::other("accounting completion unavailable")),
                            state,
                        )),
                        _ => None,
                    }
                }
            }
        });
        axum::response::Response::from_parts(parts, axum::body::Body::from_stream(stream))
    }
}

struct BodyState {
    stream: axum::body::BodyDataStream,
    admission: Option<Admission>,
    tap: TerminalTap,
    event_stream: bool,
    success_status: bool,
    finished: bool,
}

#[derive(Default)]
struct TerminalTap {
    line: Vec<u8>,
    overlong: bool,
    event_completed: bool,
    data_seen: bool,
    completed: bool,
    failed: bool,
}

impl TerminalTap {
    /// @cc [owner:ghuntley,label:security;reliability] underclass-bounded-terminal-tap
    /// Chunk boundaries MUST NOT change terminal classification. Retain at most
    /// 128 KiB of an SSE line and no payload after classification. Completion
    /// markers MUST require a dispatched frame; errors remain sticky through EOF.
    /// Overlong or malformed data MUST prevent a later marker hiding uncertainty.
    fn feed(&mut self, bytes: &[u8]) {
        for byte in bytes {
            if *byte == b'\n' {
                self.line();
                self.line.clear();
                self.overlong = false;
            } else if self.line.len() < 128 * 1024 {
                self.line.push(*byte);
            } else {
                self.overlong = true;
            }
        }
    }

    fn line(&mut self) {
        if self.overlong {
            self.failed = true;
            return;
        }
        let line = self.line.strip_suffix(b"\r").unwrap_or(&self.line);
        if line.is_empty() && !self.overlong {
            self.completed |= self.event_completed && self.data_seen;
            self.event_completed = false;
            self.data_seen = false;
        } else if let Some(event) = line.strip_prefix(b"event:") {
            let event = event.strip_prefix(b" ").unwrap_or(event);
            self.event_completed = event == b"response.completed";
            self.failed |= matches!(
                event,
                b"error" | b"response.failed" | b"response.incomplete"
            );
        } else if let Some(data) = line.strip_prefix(b"data:") {
            self.data_seen = true;
            let data = data.strip_prefix(b" ").unwrap_or(data);
            if data == b"[DONE]" {
                self.event_completed = true;
            } else if let Ok(value) = serde_json::from_slice::<serde_json::Value>(data) {
                self.event_completed |= value.get("type").and_then(serde_json::Value::as_str)
                    == Some("response.completed");
                self.failed |= value.get("error").is_some_and(|error| !error.is_null())
                    || matches!(
                        value.get("type").and_then(serde_json::Value::as_str),
                        Some("error" | "response.failed" | "response.incomplete")
                    );
            } else {
                self.failed = true;
            }
        }
    }
}

impl Drop for Admission {
    fn drop(&mut self) {
        if let Some(id) = self.id.take() {
            let elapsed = u64::try_from(self.started.elapsed().as_micros()).ok();
            let _ = self.journal.finish(&id, false, elapsed);
        }
    }
}

fn now_ns() -> Result<u64, Error> {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| Error::Invalid)?
            .as_nanos(),
    )
    .map_err(|_| Error::Invalid)
}

fn private(meta: &fs::Metadata) -> Result<bool, Error> {
    Ok(meta.uid() == fs::metadata("/proc/self")?.uid() && meta.mode() & 0o077 == 0)
}

fn private_file(path: &Path) -> Result<File, Error> {
    match fs::symlink_metadata(path) {
        Ok(meta) if !meta.is_file() || meta.nlink() != 1 || !private(&meta)? => {
            return Err(Error::Invalid);
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.nlink() != 1 || !private(&meta)? {
        return Err(Error::Invalid);
    }
    Ok(file)
}

fn read_totals(conn: &Connection) -> Result<Option<Totals>, Error> {
    let stored: Option<(i64, String)> = conn.query_row("SELECT version, CASE WHEN typeof(totals)='text' AND length(totals)<=4096 THEN totals ELSE NULL END FROM slo_totals WHERE id=1", [], |row| Ok((row.get(0)?, row.get(1)?))).optional()?;
    stored
        .map(|(version, bytes)| {
            if version != 1 || bytes.len() > 4096 {
                return Err(Error::Invalid);
            }
            let totals: Totals = serde_json::from_str(&bytes)?;
            totals.valid()?;
            Ok(totals)
        })
        .transpose()
}

fn save_totals(conn: &Connection, totals: &Totals) -> Result<(), Error> {
    totals.valid()?;
    conn.execute("INSERT INTO slo_totals(id, version, totals) VALUES (1, 1, ?1) ON CONFLICT(id) DO UPDATE SET totals=excluded.totals", params![serde_json::to_string(totals)?])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{TestCase, generators as gs};
    use std::os::unix::fs::DirBuilderExt;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("underclass-slo-{}", uuid::Uuid::new_v4()));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn totals(journal: &Journal) -> Totals {
        read_totals(&journal.conn.lock().unwrap()).unwrap().unwrap()
    }

    /// @cc [owner:ghuntley,label:verification] underclass-generated-outcome-arithmetic
    /// Generated terminal histories MUST preserve closed outcome arithmetic,
    /// optional duration, exact 15-bound histogram partitioning (including
    /// day-scale durations and overflow) and durable schema roundtrip.
    #[hegel::test]
    fn generated_outcomes_preserve_closed_arithmetic(tc: TestCase) {
        let outcomes: Vec<(u8, u64)> = tc.draw(
            gs::vecs(gs::tuples!(
                gs::integers::<u8>().min_value(0).max_value(2),
                gs::integers::<u64>()
                    .min_value(0)
                    .max_value(100_000_000_000)
            ))
            .max_size(40),
        );
        let mut actual = Totals::new().unwrap();
        let mut expected = [0_u64; 16];
        let mut sum = 0_u64;
        for (kind, duration) in &outcomes {
            actual
                .record(*kind == 0, (*kind != 2).then_some(*duration))
                .unwrap();
            if *kind != 2 {
                sum += duration;
                expected[BOUNDS_US
                    .iter()
                    .position(|bound| duration <= bound)
                    .unwrap_or(15)] += 1;
            }
        }
        assert_eq!(actual.bucket_counts, expected);
        assert_eq!(actual.duration_sum_us, sum);
        assert_eq!(actual.requests, u64::try_from(outcomes.len()).unwrap());
        assert_eq!(
            actual.successes,
            u64::try_from(outcomes.iter().filter(|(kind, _)| *kind == 0).count()).unwrap()
        );
        assert_eq!(
            actual.duration_count,
            u64::try_from(outcomes.iter().filter(|(kind, _)| *kind != 2).count()).unwrap()
        );
        assert_eq!(
            actual.bucket_counts.iter().sum::<u64>(),
            actual.duration_count
        );
        assert_eq!(
            serde_json::from_slice::<Totals>(&serde_json::to_vec(&actual).unwrap()).unwrap(),
            actual
        );
    }

    /// @cc [owner:ghuntley,label:verification] underclass-generated-terminal-framing
    /// Arbitrary chunk splits MUST preserve terminal and sticky-error recognition.
    /// A marker without a dispatched SSE frame MUST NOT establish completion.
    #[hegel::test]
    fn generated_chunk_boundaries_preserve_terminal_evidence(tc: TestCase) {
        let kind: u8 = tc.draw(gs::integers::<u8>().min_value(0).max_value(4));
        let splits: Vec<usize> =
            tc.draw(gs::vecs(gs::integers::<usize>().min_value(1).max_value(40)).max_size(40));
        let body = match kind {
            0 => "event: response.completed\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n",
            1 => "data: [DONE]\n\n",
            2 => "data: [DONE]\n\ndata: {\"type\":\"error\"}\n\n",
            3 => "event: response.completed\ndata: {}\n",
            _ => "data: {broken\n\ndata: [DONE]\n\n",
        };
        let mut tap = TerminalTap::default();
        let mut position = 0_usize;
        for size in splits {
            let end = position.saturating_add(size).min(body.len());
            tap.feed(&body.as_bytes()[position..end]);
            position = end;
        }
        tap.feed(&body.as_bytes()[position..]);
        assert_eq!(tap.completed, kind != 3);
        assert_eq!(tap.failed, kind == 2 || kind == 4);
        assert!(tap.line.len() <= 128 * 1024);
    }

    /// @cc [owner:ghuntley,label:verification;durability] underclass-unified-journal
    /// The journal MUST persist one totals record in its own file and publish
    /// exactly one 15-bound duration histogram. A retired journal file in the
    /// same directory MUST be neither read nor modified.
    #[test]
    fn unified_journal_publishes_one_histogram_and_ignores_retired_file() {
        let directory = TestDirectory::new();
        let retired = directory.0.join("slo.sqlite");
        fs::write(&retired, b"retired").unwrap();
        fs::set_permissions(&retired, fs::Permissions::from_mode(0o644)).unwrap();
        let journal = Journal::open(&directory.0).unwrap();
        journal.admit().unwrap().finish(true).unwrap();
        let path = directory.0.join("snapshot.json");
        journal.publish(&path).unwrap();
        let snapshot: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let keys: Vec<&str> = snapshot
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert!(!keys.iter().any(|key| key.starts_with("latency")));
        assert_eq!(
            snapshot["duration"]["explicit_bounds_us"],
            serde_json::json!(BOUNDS_US)
        );
        assert_eq!(
            snapshot["duration"]["bucket_counts"]
                .as_array()
                .unwrap()
                .len(),
            16
        );
        assert_eq!(snapshot["duration"]["count"], 1);
        assert_eq!(fs::read(&retired).unwrap(), b"retired");
        assert!(directory.0.join(JOURNAL_FILE).is_file());
    }

    #[test]
    fn source_group_snapshot_requires_private_source_directory() {
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        let source = directory.0.join("source");
        fs::create_dir(&source).unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o750)).unwrap();
        let path = source.join("slo.json");
        journal.publish_group(&path).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o640);
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(journal.publish_group(&path), Err(Error::Invalid)));
    }

    #[test]
    fn oversized_data_cannot_hide_failure_before_terminal_marker() {
        let mut tap = TerminalTap::default();
        tap.feed(b"data: ");
        tap.feed(&vec![b'x'; 128 * 1024 + 1]);
        assert!(tap.line.len() <= 128 * 1024);
        tap.feed(b"\n\ndata: [DONE]\n\n");
        assert!(tap.completed);
        assert!(tap.failed);
    }

    /// @cc [owner:ghuntley,label:verification;recovery] underclass-generated-durable-histories
    /// Generated completion/interruption histories MUST retain aggregate totals
    /// and source lifetime after reopening. Duplicate finalization MUST NOT add
    /// another outcome; pending admissions recover once with unknown duration.
    #[hegel::test]
    fn generated_journal_restart_preserves_exact_totals(tc: TestCase) {
        let outcomes: Vec<u8> =
            tc.draw(gs::vecs(gs::integers::<u8>().min_value(0).max_value(2)).max_size(20));
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        let lifetime = totals(&journal);
        let mut completed = 0_u64;
        for kind in &outcomes {
            let mut admission = journal.admit().unwrap();
            let id = admission.id.take().unwrap();
            if *kind != 2 {
                journal.finish(&id, *kind == 0, Some(100)).unwrap();
                journal.finish(&id, *kind == 0, Some(100)).unwrap();
                completed += 1;
            }
        }
        assert_eq!(totals(&journal).requests, completed);
        drop(journal);
        let recovered = Journal::open(&directory.0).unwrap();
        let expected = totals(&recovered);
        assert_eq!(expected.requests, u64::try_from(outcomes.len()).unwrap());
        assert_eq!(
            expected.successes,
            u64::try_from(outcomes.iter().filter(|kind| **kind == 0).count()).unwrap()
        );
        assert_eq!(expected.duration_count, completed);
        assert_eq!(expected.incarnation, lifetime.incarnation);
        assert_eq!(expected.started_at_unix_nano, lifetime.started_at_unix_nano);
        drop(recovered);
        let recovered = Journal::open(&directory.0).unwrap();
        assert_eq!(totals(&recovered), expected);
    }

    #[tokio::test]
    async fn response_headers_and_terminal_bytes_do_not_count_before_body_eof() {
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        let admission = journal.admit().unwrap();
        let response = axum::response::Response::builder()
            .status(200)
            .header("content-type", "text/event-stream")
            .body(axum::body::Body::from("data: [DONE]\n\n"))
            .unwrap();
        let response = admission.wrap_response(response);
        assert_eq!(totals(&journal).requests, 0);
        let mut stream = response.into_body().into_data_stream();
        assert!(stream.next().await.unwrap().is_ok());
        assert_eq!(totals(&journal).requests, 0);
        assert!(stream.next().await.is_none());
        assert_eq!(totals(&journal).successes, 1);
    }

    #[tokio::test]
    async fn dropped_or_unterminated_body_is_one_failure() {
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        for consume in [false, true] {
            let admission = journal.admit().unwrap();
            let response = axum::response::Response::builder()
                .status(200)
                .header("content-type", "text/event-stream")
                .body(axum::body::Body::from(
                    "data: {\"type\":\"response.output_text.delta\"}\n\n",
                ))
                .unwrap();
            let response = admission.wrap_response(response);
            if consume {
                axum::body::to_bytes(response.into_body(), 4096)
                    .await
                    .unwrap();
            }
        }
        assert_eq!(totals(&journal).requests, 2);
        assert_eq!(totals(&journal).failures, 2);
    }

    #[test]
    fn live_owner_and_public_file_modes_refuse_recovery() {
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        assert!(matches!(Journal::open(&directory.0), Err(Error::Locked)));
        drop(journal);
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            directory.0.join(JOURNAL_FILE),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        assert!(matches!(Journal::open(&directory.0), Err(Error::Invalid)));
    }

    #[test]
    fn full_journal_records_valid_request_refusal_without_provider_admission() {
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        {
            let mut conn = journal.conn.lock().unwrap();
            let tx = conn.transaction().unwrap();
            for _ in 0..CAPACITY {
                tx.execute(
                    "INSERT INTO slo_pending(id) VALUES (?1)",
                    [uuid::Uuid::new_v4().to_string()],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        assert!(matches!(journal.admit(), Err(Error::Full)));
        assert_eq!(totals(&journal).requests, 1);
        assert_eq!(totals(&journal).failures, 1);
        assert_eq!(totals(&journal).duration_count, 0);
        assert!(!journal.fenced.load(Ordering::SeqCst));
        drop(journal);
        let recovered = Journal::open(&directory.0).unwrap();
        assert_eq!(
            totals(&recovered).requests,
            u64::try_from(CAPACITY).unwrap() + 1
        );
        assert_eq!(
            totals(&recovered).failures,
            u64::try_from(CAPACITY).unwrap() + 1
        );
        assert_eq!(totals(&recovered).duration_count, 0);
    }

    #[test]
    fn uncertain_completion_fences_admission_and_publication_then_recovers_once() {
        let directory = TestDirectory::new();
        let journal = Journal::open(&directory.0).unwrap();
        let admission = journal.admit().unwrap();
        journal.conn.lock().unwrap().execute_batch("CREATE TRIGGER reject_totals BEFORE UPDATE ON slo_totals BEGIN SELECT RAISE(ABORT, 'synthetic uncertainty'); END").unwrap();
        assert!(admission.finish(true).is_err());
        assert!(matches!(journal.admit(), Err(Error::Unavailable)));
        assert!(matches!(
            journal.publish(&directory.0.join("snapshot.json")),
            Err(Error::Unavailable)
        ));
        journal
            .conn
            .lock()
            .unwrap()
            .execute_batch("DROP TRIGGER reject_totals")
            .unwrap();
        drop(journal);
        let recovered = Journal::open(&directory.0).unwrap();
        assert_eq!(totals(&recovered).requests, 1);
        assert_eq!(totals(&recovered).failures, 1);
        assert_eq!(totals(&recovered).duration_count, 0);
    }
}
