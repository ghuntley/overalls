//! Independent durable custody for reviewed host OpenTelemetry trace batches.

use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;

pub const BODY_LIMIT: usize = 262_144;
const NS_PER_SECOND: u64 = 1_000_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Foreign,
    Capacity,
    Storage,
    Poisoned,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Schema {
    pub services: BTreeMap<String, BTreeSet<String>>,
    pub uuid_attributes: BTreeSet<String>,
    pub enum_attributes: BTreeSet<String>,
    pub numeric_attributes: BTreeSet<String>,
    pub enum_values: BTreeSet<String>,
}

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if [8, 13, 18, 23].contains(&i) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn attribute(key: &str, value: &str) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(any_value::Value::StringValue(value.to_owned())),
        }),
    }
}

impl Schema {
    pub fn load(path: &Path) -> Result<Self, Error> {
        let bytes = std::fs::read(path).map_err(|_| Error::Storage)?;
        if bytes.len() > 1_048_576 {
            return Err(Error::Invalid);
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)
    }

    /// @cc [owner:ghuntley,label:security] trace-schema-closes-provenance
    /// Unreviewed names/attributes MUST refuse. Producer resources, events,
    /// baggage and status messages MUST be discarded before durable storage.
    /// The resource MUST be exactly the configured service, host, application
    /// origin and deployment revision; the revision comes from the host build,
    /// never from the producer.
    pub fn sanitize(
        &self,
        body: &[u8],
        service: &str,
        host: &str,
        revision: &str,
    ) -> Result<Vec<u8>, Error> {
        if body.len() > BODY_LIMIT {
            return Err(Error::Capacity);
        }
        let names = self.services.get(service).ok_or(Error::Invalid)?;
        let mut request = ExportTraceServiceRequest::decode(body).map_err(|_| Error::Invalid)?;
        if request.resource_spans.len() != 1 {
            return Err(Error::Invalid);
        }
        let mut count = 0;
        for resource in &mut request.resource_spans {
            resource.resource = Some(Resource {
                attributes: vec![
                    attribute("service.name", service),
                    attribute("host.name", host),
                    attribute("overalls.telemetry.origin", "application"),
                    attribute("service.version", revision),
                    attribute("overalls.deployment.revision", revision),
                ],
                dropped_attributes_count: 0,
                ..Resource::default()
            });
            resource.schema_url.clear();
            if resource.scope_spans.len() > 8 {
                return Err(Error::Capacity);
            }
            for scope in &mut resource.scope_spans {
                scope.schema_url.clear();
                if let Some(instrumentation) = &mut scope.scope {
                    instrumentation.name = "overalls-reviewed".into();
                    instrumentation.version = "1".into();
                    instrumentation.attributes.clear();
                    instrumentation.dropped_attributes_count = 0;
                }
                for span in &mut scope.spans {
                    count += 1;
                    if count > 128
                        || !names.contains(&span.name)
                        || span.attributes.len() > 32
                        || span.trace_id.len() != 16
                        || span.span_id.len() != 8
                        || span.trace_id.iter().all(|byte| *byte == 0)
                        || span.span_id.iter().all(|byte| *byte == 0)
                        || (!span.parent_span_id.is_empty() && span.parent_span_id.len() != 8)
                        || span.start_time_unix_nano == 0
                        || span.end_time_unix_nano > i64::MAX as u64
                        || span.end_time_unix_nano < span.start_time_unix_nano
                        || !(0..=5).contains(&span.kind)
                        || span
                            .status
                            .as_ref()
                            .is_some_and(|status| !(0..=2).contains(&status.code))
                    {
                        return Err(Error::Invalid);
                    }
                    let mut keys = BTreeSet::new();
                    for attr in &span.attributes {
                        if !keys.insert(&attr.key) {
                            return Err(Error::Invalid);
                        }
                        let value = attr
                            .value
                            .as_ref()
                            .and_then(|v| v.value.as_ref())
                            .ok_or(Error::Invalid)?;
                        let valid = match value {
                            any_value::Value::StringValue(value)
                                if self.uuid_attributes.contains(&attr.key) =>
                            {
                                uuid(value)
                            }
                            any_value::Value::StringValue(value)
                                if self.enum_attributes.contains(&attr.key) =>
                            {
                                self.enum_values.contains(value)
                            }
                            any_value::Value::IntValue(value)
                                if self.numeric_attributes.contains(&attr.key) =>
                            {
                                *value >= 0
                            }
                            _ => false,
                        };
                        if !valid {
                            return Err(Error::Invalid);
                        }
                    }
                    span.attributes.sort_by(|a, b| a.key.cmp(&b.key));
                    span.events.clear();
                    span.links.clear();
                    span.trace_state.clear();
                    span.flags &= 1;
                    span.dropped_events_count = 0;
                    span.dropped_links_count = 0;
                    if let Some(status) = &mut span.status {
                        status.message.clear();
                    }
                }
            }
        }
        if count == 0 {
            return Err(Error::Invalid);
        }
        let bytes = request.encode_to_vec();
        if bytes.len() > BODY_LIMIT {
            return Err(Error::Capacity);
        }
        Ok(bytes)
    }
}

#[derive(Debug, Clone)]
pub struct Batch {
    pub id: String,
    pub accepted_at_ns: u64,
    pub expires_at_ns: u64,
    pub bytes: u64,
    pub delivered: bool,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Health {
    pub accepted: u64,
    pub refused: u64,
    pub storage_failures: u64,
    pub export_failures: u64,
    pub exported: u64,
}

pub struct Store {
    _lock: File,
    db: rusqlite::Connection,
    quota: u64,
    retention_ns: u64,
    pending_quota: u64,
    bytes: u64,
    batches: u64,
    pending_bytes: u64,
    pending_batches: u64,
    poisoned: bool,
    pub health: Health,
}

fn private(file: &File) -> Result<(), Error> {
    let m = file.metadata().map_err(|_| Error::Storage)?;
    if m.is_file()
        && m.uid() == unsafe { libc::geteuid() }
        && m.mode() & 0o777 == 0o600
        && m.nlink() == 1
    {
        Ok(())
    } else {
        Err(Error::Storage)
    }
}

fn open_private(path: &Path) -> Result<File, Error> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| Error::Storage)?;
    private(&file)?;
    Ok(file)
}

fn digest(body: &[u8]) -> String {
    format!("{:x}", Sha256::digest(body))
}

fn sql(value: u64) -> Result<i64, Error> {
    i64::try_from(value).map_err(|_| Error::Invalid)
}
fn number(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}

impl Store {
    pub fn open(directory: &Path, quota: u64, retention_seconds: u64) -> Result<Self, Error> {
        use rusqlite::OptionalExtension;
        let metadata = std::fs::symlink_metadata(directory).map_err(|_| Error::Storage)?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
            || quota < 4_194_304
            || quota > i64::MAX as u64
            || !(60..=31_536_000).contains(&retention_seconds)
        {
            return Err(Error::Storage);
        }
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("writer.lock"))
            .map_err(|_| Error::Storage)?;
        private(&lock)?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(Error::Storage);
        }
        let database = directory.join("archive.sqlite");
        let initialized = directory.join("custody.initialized");
        let exists = database.try_exists().map_err(|_| Error::Storage)?;
        if initialized.try_exists().map_err(|_| Error::Storage)? {
            let marker = std::fs::read(&initialized).map_err(|_| Error::Storage)?;
            open_private(&initialized)?;
            if marker != b"overalls-trace-custody-v1\n" {
                return Err(Error::Storage);
            }
            if !exists {
                return Err(Error::Storage);
            }
        }
        for entry in std::fs::read_dir(directory).map_err(|_| Error::Storage)? {
            let path = entry.map_err(|_| Error::Storage)?.path();
            let name = path
                .file_name()
                .and_then(|s| s.to_str())
                .ok_or(Error::Storage)?;
            if ![
                "writer.lock",
                "archive.sqlite",
                "archive.sqlite-wal",
                "archive.sqlite-shm",
                "custody.initialized",
            ]
            .contains(&name)
            {
                return Err(Error::Storage);
            }
            open_private(&path)?;
        }
        if !exists {
            let dbfile = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&database)
                .map_err(|_| Error::Storage)?;
            private(&dbfile)?;
            dbfile.sync_all().map_err(|_| Error::Storage)?;
        }
        let db = rusqlite::Connection::open_with_flags(
            &database,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|_| Error::Storage)?;
        db.busy_timeout(std::time::Duration::from_millis(250))
            .map_err(|_| Error::Storage)?;
        if initialized.try_exists().map_err(|_| Error::Storage)? {
            let tables: u64 = db.query_row(
                "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN ('custody','batches','pending')", [], |row| number(row, 0)
            ).map_err(|_| Error::Storage)?;
            if tables != 3 {
                return Err(Error::Storage);
            }
        }
        db.execute_batch(
            "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
          PRAGMA wal_autocheckpoint=64; PRAGMA journal_size_limit=1048576;
          PRAGMA cache_size=-8192; PRAGMA mmap_size=0;
          CREATE TABLE IF NOT EXISTS custody (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
          CREATE TABLE IF NOT EXISTS batches (
            id TEXT PRIMARY KEY, accepted_ns INTEGER NOT NULL CHECK(accepted_ns>0),
            expires_ns INTEGER NOT NULL CHECK(expires_ns>accepted_ns),
            bytes INTEGER NOT NULL CHECK(bytes>0), body BLOB NOT NULL,
            UNIQUE(id,accepted_ns,bytes)) STRICT;
          CREATE TABLE IF NOT EXISTS pending (
            id TEXT PRIMARY KEY REFERENCES batches(id), accepted_ns INTEGER NOT NULL, bytes INTEGER NOT NULL) STRICT;
          CREATE INDEX IF NOT EXISTS pending_order ON pending(accepted_ns,id);
          CREATE INDEX IF NOT EXISTS batches_expiry ON batches(expires_ns,id);",
        )
        .map_err(|_| Error::Storage)?;
        db.pragma_update(None, "max_page_count", sql((quota - 2_097_152) / 4096)?)
            .map_err(|_| Error::Storage)?;
        let check: String = db
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .map_err(|_| Error::Storage)?;
        if check != "ok" {
            return Err(Error::Storage);
        }
        let inconsistent: u64 = db.query_row(
            "SELECT count(*) FROM pending LEFT JOIN batches ON pending.id=batches.id WHERE batches.id IS NULL OR pending.accepted_ns!=batches.accepted_ns OR pending.bytes!=batches.bytes", [], |row| number(row, 0)
        ).map_err(|_| Error::Storage)?;
        let foreign_keys: u64 = db
            .query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
                number(row, 0)
            })
            .map_err(|_| Error::Storage)?;
        if inconsistent != 0 || foreign_keys != 0 {
            return Err(Error::Storage);
        }
        let version: Option<String> = db
            .query_row("SELECT value FROM custody WHERE key='version'", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| Error::Storage)?;
        match version.as_deref() {
            None if !initialized.try_exists().map_err(|_| Error::Storage)? => {
                db.execute("INSERT INTO custody VALUES ('version','1')", [])
                    .map_err(|_| Error::Storage)?;
            }
            Some("1") => {}
            _ => return Err(Error::Storage),
        }
        if !initialized.try_exists().map_err(|_| Error::Storage)? {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&initialized)
                .map_err(|_| Error::Storage)?;
            file.write_all(b"overalls-trace-custody-v1\n")
                .map_err(|_| Error::Storage)?;
            file.sync_all().map_err(|_| Error::Storage)?;
        }
        File::open(directory)
            .and_then(|f| f.sync_all())
            .map_err(|_| Error::Storage)?;
        let (batches, bytes, pending_batches, pending_bytes): (u64,u64,u64,u64) = db.query_row(
            "SELECT (SELECT count(*) FROM batches),(SELECT coalesce(sum(bytes),0) FROM batches),(SELECT count(*) FROM pending),(SELECT coalesce(sum(bytes),0) FROM pending)",
            [], |r| Ok((number(r,0)?,number(r,1)?,number(r,2)?,number(r,3)?))).map_err(|_| Error::Storage)?;
        // Stream retained bodies through checksum verification. Cold startup
        // deliberately refuses to advertise healthy custody before full review;
        // delivered archives remain protected even when no batch is pending.
        {
            let mut statement = db
                .prepare("SELECT id,body,bytes,accepted_ns,expires_ns FROM batches")
                .map_err(|_| Error::Storage)?;
            let mut rows = statement.query([]).map_err(|_| Error::Storage)?;
            while let Some(row) = rows.next().map_err(|_| Error::Storage)? {
                let id: String = row.get(0).map_err(|_| Error::Storage)?;
                let body: Vec<u8> = row.get(1).map_err(|_| Error::Storage)?;
                let bytes = number(row, 2).map_err(|_| Error::Storage)?;
                let accepted = number(row, 3).map_err(|_| Error::Storage)?;
                let expires = number(row, 4).map_err(|_| Error::Storage)?;
                if body.is_empty()
                    || body.len() > BODY_LIMIT
                    || digest(&body) != id
                    || bytes != body.len() as u64 + 512
                    || accepted == 0
                    || expires <= accepted
                {
                    return Err(Error::Storage);
                }
            }
        }
        Ok(Self {
            _lock: lock,
            db,
            quota,
            retention_ns: retention_seconds * NS_PER_SECOND,
            pending_quota: quota,
            bytes,
            batches,
            pending_bytes,
            pending_batches,
            poisoned: false,
            health: Health::default(),
        })
    }

    pub fn set_pending_quota(&mut self, quota: u64) -> Result<(), Error> {
        if quota < BODY_LIMIT as u64 || quota > self.quota {
            return Err(Error::Invalid);
        }
        self.pending_quota = quota;
        Ok(())
    }

    pub fn bind(
        &mut self,
        service: &str,
        host: &str,
        user: &str,
        unit: &str,
        cgroup: &str,
    ) -> Result<(), Error> {
        use rusqlite::OptionalExtension;
        let identity = serde_json::to_string(&(service, host, user, unit, cgroup))
            .map_err(|_| Error::Invalid)?;
        let stored: Option<String> = self
            .db
            .query_row("SELECT value FROM custody WHERE key='producer'", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| self.poison())?;
        match stored {
            Some(value) if value == identity => Ok(()),
            None => self
                .db
                .execute("INSERT INTO custody VALUES ('producer',?1)", [&identity])
                .map(|_| ())
                .map_err(|_| self.poison()),
            _ => Err(Error::Foreign),
        }
    }

    pub fn poison(&mut self) -> Error {
        self.poisoned = true;
        self.health.storage_failures += 1;
        Error::Storage
    }

    /// @cc [owner:ghuntley,label:recovery] trace-spool-sqlite-custody
    /// ACK MUST follow SQLite WAL FULL synchronous commit. Indexed immutable
    /// payloads MUST survive delivery ACKs and retention policy changes. Capacity
    /// exhaustion MUST refuse new data without deleting accepted custody.
    pub fn accept(&mut self, body: &[u8], now_ns: u64) -> Result<String, Error> {
        use rusqlite::OptionalExtension;
        if self.poisoned {
            self.health.refused += 1;
            return Err(Error::Poisoned);
        }
        if body.is_empty()
            || body.len() > BODY_LIMIT
            || now_ns == 0
            || now_ns > i64::MAX as u64 - self.retention_ns
        {
            self.health.refused += 1;
            return Err(Error::Invalid);
        }
        let id = digest(body);
        let existing: Option<Vec<u8>> = self
            .db
            .query_row("SELECT body FROM batches WHERE id=?1", [&id], |r| r.get(0))
            .optional()
            .map_err(|_| self.poison())?;
        if let Some(existing) = existing {
            if existing != body {
                return Err(self.poison());
            }
            return Ok(id);
        }
        // Conservative row/index reserve and fixed SQLite/WAL budget. SQLite's
        // max_page_count additionally limits DB growth; physical ENOSPC poisons.
        let bytes = body.len() as u64 + 512;
        if self.bytes.saturating_add(bytes).saturating_add(2_097_152) > self.quota
            || self.pending_bytes.saturating_add(bytes) > self.pending_quota
        {
            self.health.refused += 1;
            return Err(Error::Capacity);
        }
        let result = (|| -> rusqlite::Result<()> {
            let transaction = self.db.transaction()?;
            transaction.execute(
                "INSERT INTO batches VALUES (?1,?2,?3,?4,?5)",
                rusqlite::params![
                    id,
                    sql(now_ns).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    sql(now_ns + self.retention_ns).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    sql(bytes).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    body
                ],
            )?;
            transaction.execute(
                "INSERT INTO pending VALUES (?1,?2,?3)",
                rusqlite::params![
                    id,
                    sql(now_ns).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    sql(bytes).map_err(|_| rusqlite::Error::InvalidQuery)?
                ],
            )?;
            transaction.commit()
        })();
        if result.is_err() {
            return Err(self.poison());
        }
        self.bytes += bytes;
        self.batches += 1;
        self.pending_bytes += bytes;
        self.pending_batches += 1;
        self.health.accepted += 1;
        Ok(id)
    }

    pub fn pending(&mut self) -> Result<Option<Batch>, Error> {
        use rusqlite::OptionalExtension;
        if self.poisoned {
            return Err(Error::Poisoned);
        }
        self.db.query_row("SELECT pending.id,pending.accepted_ns,batches.expires_ns,pending.bytes FROM pending JOIN batches USING(id) ORDER BY pending.accepted_ns,pending.id LIMIT 1", [], |r|Ok(Batch {
            id:r.get(0)?,accepted_at_ns:number(r,1)?,expires_at_ns:number(r,2)?,bytes:number(r,3)?,delivered:false
        })).optional().map_err(|_|self.poison())
    }

    pub fn body(&mut self, batch: &Batch) -> Result<Vec<u8>, Error> {
        let body: Vec<u8> = self
            .db
            .query_row("SELECT body FROM batches WHERE id=?1", [&batch.id], |r| {
                r.get(0)
            })
            .map_err(|_| self.poison())?;
        if body.is_empty()
            || body.len() > BODY_LIMIT
            || digest(&body) != batch.id
            || body.len() as u64 + 512 != batch.bytes
        {
            return Err(self.poison());
        }
        Ok(body)
    }

    pub fn delivered(&mut self, id: &str) -> Result<(), Error> {
        use rusqlite::OptionalExtension;
        if self.poisoned {
            return Err(Error::Poisoned);
        }
        let bytes: Option<u64> = self
            .db
            .query_row("SELECT bytes FROM pending WHERE id=?1", [id], |r| {
                number(r, 0)
            })
            .optional()
            .map_err(|_| self.poison())?;
        if let Some(bytes) = bytes {
            self.db
                .execute("DELETE FROM pending WHERE id=?1", [id])
                .map_err(|_| self.poison())?;
            self.pending_batches -= 1;
            self.pending_bytes -= bytes;
            self.health.exported += 1;
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:recovery] trace-archive-replay
    /// Replay MUST preserve accepted bytes and identity after upstream ACK.
    pub fn replay(&mut self) -> Result<(), Error> {
        if self.poisoned {
            return Err(Error::Poisoned);
        }
        // Small index-only commits bound WAL growth; immutable bodies are never
        // rewritten during replay. Interrupted replay safely leaves a subset due.
        loop {
            let result=self.db.execute("INSERT OR IGNORE INTO pending SELECT id,accepted_ns,bytes FROM batches WHERE id NOT IN (SELECT id FROM pending) LIMIT 128",[]);
            match result {
                Ok(0) => break,
                Ok(_) => {}
                Err(_) => return Err(self.poison()),
            }
        }
        self.pending_batches = self.batches;
        self.pending_bytes = self.bytes;
        Ok(())
    }

    pub fn expire(&mut self, now_ns: u64) -> Result<(), Error> {
        if self.poisoned {
            return Err(Error::Poisoned);
        }
        // Four maximum-sized rows per transaction keep WAL work below reserved
        // custody overhead. Page reuse bounds the DB without authority-changing
        // VACUUM or expensive rewrites of the full retained archive.
        loop {
            let result = (|| -> rusqlite::Result<Option<(u64, u64, u64, u64)>> {
                let transaction = self.db.transaction()?;
                let totals:(u64,u64,u64,u64)=transaction.query_row(
                    "SELECT count(*),coalesce(sum(bytes),0),coalesce(sum(id IN (SELECT id FROM pending)),0),coalesce(sum(CASE WHEN id IN (SELECT id FROM pending) THEN bytes ELSE 0 END),0) FROM batches WHERE id IN (SELECT id FROM batches WHERE expires_ns<=?1 ORDER BY expires_ns,id LIMIT 4)",
                    [sql(now_ns).map_err(|_|rusqlite::Error::InvalidQuery)?],|r|Ok((number(r,0)?,number(r,1)?,number(r,2)?,number(r,3)?)))?;
                if totals.0 == 0 {
                    return Ok(None);
                }
                transaction.execute("DELETE FROM pending WHERE id IN (SELECT id FROM batches WHERE expires_ns<=?1 ORDER BY expires_ns,id LIMIT 4)",[sql(now_ns).map_err(|_|rusqlite::Error::InvalidQuery)?])?;
                transaction.execute("DELETE FROM batches WHERE id IN (SELECT id FROM batches WHERE expires_ns<=?1 ORDER BY expires_ns,id LIMIT 4)",[sql(now_ns).map_err(|_|rusqlite::Error::InvalidQuery)?])?;
                transaction.commit()?;
                Ok(Some(totals))
            })();
            match result {
                Ok(None) => break,
                Ok(Some((count, bytes, pending, pending_bytes))) => {
                    self.batches -= count;
                    self.bytes -= bytes;
                    self.pending_batches -= pending;
                    self.pending_bytes -= pending_bytes;
                }
                Err(_) => return Err(self.poison()),
            }
        }
        Ok(())
    }

    pub fn metrics(&mut self, now_ns: u64) -> String {
        let oldest = match self.pending() {
            Ok(Some(batch)) => now_ns.saturating_sub(batch.accepted_at_ns) / NS_PER_SECOND,
            _ => 0,
        };
        let values = [
            ("accepted_total", self.health.accepted),
            ("refused_total", self.health.refused),
            ("storage_failures_total", self.health.storage_failures),
            ("export_failed_total", self.health.export_failures),
            ("exported_total", self.health.exported),
            ("pending_batches", self.pending_batches),
            ("pending_bytes", self.pending_bytes),
            ("oldest_pending_seconds", oldest),
            ("retained_batches", self.batches),
            ("retained_bytes", self.bytes),
            ("quota_bytes", self.quota),
            ("pending_quota_bytes", self.pending_quota),
            ("poisoned", u64::from(self.poisoned)),
            ("sample_time", now_ns / NS_PER_SECOND),
        ];
        values
            .iter()
            .map(|(name, value)| format!("overalls_trace_spool_{name} {value}\n"))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    use opentelemetry_proto::tonic::trace::v1::{ResourceSpans, ScopeSpans, Span, Status};
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn schema_request() -> (Schema, ExportTraceServiceRequest) {
        let schema = Schema {
            services: BTreeMap::from([(
                "galileo".into(),
                BTreeSet::from(["galileo.request_denied".into()]),
            )]),
            uuid_attributes: BTreeSet::from(["request_id".into()]),
            enum_attributes: BTreeSet::from(["reason".into()]),
            numeric_attributes: BTreeSet::from(["duration_us".into()]),
            enum_values: BTreeSet::from(["unauthorized".into()]),
        };
        let request = ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: Some(Resource {
                    attributes: vec![attribute("service.name", "foreign-secret")],
                    ..Resource::default()
                }),
                scope_spans: vec![ScopeSpans {
                    spans: vec![Span {
                        name: "galileo.request_denied".into(),
                        trace_id: vec![1; 16],
                        span_id: vec![2; 8],
                        start_time_unix_nano: 1,
                        end_time_unix_nano: 2,
                        attributes: vec![attribute("reason", "unauthorized")],
                        status: Some(Status {
                            message: "secret-exception".into(),
                            code: 2,
                        }),
                        trace_state: "secret-baggage".into(),
                        flags: u32::MAX,
                        ..Span::default()
                    }],
                    ..ScopeSpans::default()
                }],
                ..ResourceSpans::default()
            }],
        };
        (schema, request)
    }

    #[test]
    fn schema_replaces_origin_and_discards_unreviewed_context() {
        let (schema, request) = schema_request();
        let clean = schema
            .sanitize(
                &request.encode_to_vec(),
                "galileo",
                "trusted-host",
                "0123abc",
            )
            .unwrap();
        let decoded = ExportTraceServiceRequest::decode(clean.as_slice()).unwrap();
        let resource = &decoded.resource_spans[0];
        assert_eq!(
            resource.resource.as_ref().unwrap().attributes,
            vec![
                attribute("service.name", "galileo"),
                attribute("host.name", "trusted-host"),
                attribute("overalls.telemetry.origin", "application"),
                attribute("service.version", "0123abc"),
                attribute("overalls.deployment.revision", "0123abc")
            ]
        );
        let span = &resource.scope_spans[0].spans[0];
        assert!(span.trace_state.is_empty());
        assert!(span.status.as_ref().unwrap().message.is_empty());
        assert_eq!(span.flags, 1);
        assert!(!String::from_utf8_lossy(&clean).contains("secret"));
    }

    /// @cc [owner:ghuntley,label:verification;security] trace-spool-unreviewed-attribute-refusal
    /// An unreviewed attribute key MUST refuse the batch whatever its string value.
    #[hegel::test(test_cases = 64)]
    fn arbitrary_unreviewed_attribute_bytes_never_pass(tc: TestCase) {
        let value = tc.draw(gs::text().max_size(256));
        let (schema, mut request) = schema_request();
        request.resource_spans[0].scope_spans[0].spans[0]
            .attributes
            .push(attribute("payload", &value));
        assert_eq!(
            schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev"),
            Err(Error::Invalid)
        );
    }

    #[test]
    fn schema_refuses_duplicates_unknown_enums_invalid_ids_and_negative_numbers() {
        let (schema, template) = schema_request();
        for invalid in [
            attribute("reason", "unreviewed"),
            attribute("request_id", "secret"),
            KeyValue {
                key: "duration_us".into(),
                value: Some(AnyValue {
                    value: Some(any_value::Value::IntValue(-1)),
                }),
            },
        ] {
            let mut request = template.clone();
            request.resource_spans[0].scope_spans[0].spans[0].attributes = vec![invalid];
            assert_eq!(
                schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev"),
                Err(Error::Invalid)
            );
        }
        let mut request = template;
        request.resource_spans[0].scope_spans[0].spans[0]
            .attributes
            .push(attribute("reason", "unauthorized"));
        assert_eq!(
            schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev"),
            Err(Error::Invalid)
        );
    }
    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "overalls-trace-spool-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir(&path).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            Self(path)
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    /// @cc [owner:ghuntley,label:verification;recovery] trace-spool-archive-survives-ack-loss
    /// ACK loss, delivery, reopen under a shorter retention policy and replay MUST
    /// preserve every accepted body until its original expiry.
    #[hegel::test(test_cases = 32)]
    fn ack_loss_delivery_reopen_and_policy_change_preserve_archive(tc: TestCase) {
        let bodies = tc.draw(
            gs::vecs(gs::binary().min_size(1).max_size(511))
                .min_size(1)
                .max_size(23),
        );
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
        let mut accepted = BTreeMap::new();
        for body in bodies {
            let id = store.accept(&body, NS_PER_SECOND).unwrap();
            assert_eq!(&store.accept(&body, 2 * NS_PER_SECOND).unwrap(), &id);
            store.delivered(&id).unwrap();
            accepted.insert(id, body);
        }
        drop(store);
        let mut store = Store::open(&directory.0, 8_388_608, 60).unwrap();
        assert!(store.pending().unwrap().is_none());
        store.replay().unwrap();
        while let Some(batch) = store.pending().unwrap() {
            assert_eq!(&store.body(&batch).unwrap(), &accepted[&batch.id]);
            store.delivered(&batch.id).unwrap();
        }
        assert_eq!(store.batches, accepted.len() as u64);
        store.expire(3599 * NS_PER_SECOND).unwrap();
        assert_eq!(store.batches, accepted.len() as u64);
        store.expire(3601 * NS_PER_SECOND).unwrap();
        assert_eq!(store.batches, 0);
    }

    /// Independent UUID oracle: five hyphen-separated hex groups of 8-4-4-4-12.
    fn uuid_oracle(value: &str) -> bool {
        let groups: Vec<&str> = value.split('-').collect();
        groups.len() == 5
            && groups.iter().zip([8, 4, 4, 4, 12]).all(|(group, len)| {
                group.len() == len && group.chars().all(|c| c.is_ascii_hexdigit())
            })
    }

    /// Draws a string value that is near the UUID shape often enough to exercise
    /// both acceptance and refusal of uuid attributes.
    fn draw_text_value(tc: &TestCase) -> String {
        match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => tc.draw(gs::text().max_size(48)),
            1 => tc.draw(
                gs::text()
                    .alphabet("0123456789abcdefABCDEF-g")
                    .min_size(36)
                    .max_size(36),
            ),
            2 => tc.draw(gs::sampled_from(vec![
                "unauthorized".to_owned(),
                "unreviewed".to_owned(),
                String::new(),
            ])),
            _ => {
                let mut value: String = (0..32)
                    .map(|_| {
                        let nibble = tc.draw(gs::integers::<u32>().max_value(15));
                        char::from_digit(nibble, 16).unwrap()
                    })
                    .collect();
                for index in [8, 13, 18, 23] {
                    value.insert(index, '-');
                }
                value
            }
        }
    }

    /// @cc [owner:ghuntley,label:verification;security] trace-spool-schema-attribute-closure
    /// Over arbitrary keys and values, sanitize MUST accept exactly the reviewed
    /// closure: uuid keys with an oracle-valid UUID string, enum keys with a
    /// reviewed value and numeric keys with a non-negative integer. Every other
    /// key, value type or value MUST refuse as invalid.
    #[hegel::test(test_cases = 128)]
    fn schema_attribute_closure_over_arbitrary_keys(tc: TestCase) {
        let (schema, mut request) = schema_request();
        let key = if tc.draw(gs::booleans()) {
            tc.draw(gs::sampled_from(vec![
                "request_id".to_owned(),
                "reason".to_owned(),
                "duration_us".to_owned(),
            ]))
        } else {
            tc.draw(gs::text().max_size(24))
        };
        let (value, expected) = if tc.draw(gs::booleans()) {
            let number = tc.draw(gs::integers::<i64>());
            let valid = key == "duration_us" && number >= 0;
            (any_value::Value::IntValue(number), valid)
        } else {
            let text = draw_text_value(&tc);
            let valid = match key.as_str() {
                "request_id" => uuid_oracle(&text),
                "reason" => text == "unauthorized",
                _ => false,
            };
            (any_value::Value::StringValue(text), valid)
        };
        request.resource_spans[0].scope_spans[0].spans[0].attributes = vec![KeyValue {
            key,
            value: Some(AnyValue { value: Some(value) }),
        }];
        let result = schema.sanitize(&request.encode_to_vec(), "galileo", "host", "rev");
        if expected {
            assert!(result.is_ok());
        } else {
            assert_eq!(result, Err(Error::Invalid));
        }
    }

    /// Independent FIPS 180-4 SHA-256, used only as a test oracle for `digest`.
    fn sha256_oracle(message: &[u8]) -> String {
        const K: [u32; 64] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
            0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
            0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
            0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
            0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
            0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
            0xc67178f2,
        ];
        let mut state: [u32; 8] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
            0x5be0cd19,
        ];
        let mut padded = message.to_vec();
        padded.push(0x80);
        while padded.len() % 64 != 56 {
            padded.push(0);
        }
        padded.extend_from_slice(&(message.len() as u64 * 8).to_be_bytes());
        for block in padded.chunks_exact(64) {
            let mut w = [0u32; 64];
            for (word, bytes) in w.iter_mut().zip(block.chunks_exact(4)) {
                *word = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            }
            for t in 16..64 {
                let s0 = w[t - 15].rotate_right(7) ^ w[t - 15].rotate_right(18) ^ (w[t - 15] >> 3);
                let s1 = w[t - 2].rotate_right(17) ^ w[t - 2].rotate_right(19) ^ (w[t - 2] >> 10);
                w[t] = w[t - 16]
                    .wrapping_add(s0)
                    .wrapping_add(w[t - 7])
                    .wrapping_add(s1);
            }
            let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
            for t in 0..64 {
                let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
                let ch = (e & f) ^ (!e & g);
                let t1 = h
                    .wrapping_add(s1)
                    .wrapping_add(ch)
                    .wrapping_add(K[t])
                    .wrapping_add(w[t]);
                let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
                let maj = (a & b) ^ (a & c) ^ (b & c);
                let t2 = s0.wrapping_add(maj);
                h = g;
                g = f;
                f = e;
                e = d.wrapping_add(t1);
                d = c;
                c = b;
                b = a;
                a = t1.wrapping_add(t2);
            }
            for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
                *slot = slot.wrapping_add(value);
            }
        }
        state.iter().map(|word| format!("{word:08x}")).collect()
    }

    #[test]
    fn sha256_oracle_matches_published_vectors() {
        assert_eq!(
            sha256_oracle(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_oracle(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_oracle(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    /// @cc [owner:ghuntley,label:verification;recovery] trace-spool-digest-identity
    /// The batch identity MUST equal an independent SHA-256 lower-case hex digest
    /// of the accepted body, and accept MUST return that identity.
    #[hegel::test(test_cases = 64)]
    fn digest_matches_independent_sha256_and_accept_returns_it(tc: TestCase) {
        let body = tc.draw(gs::binary().min_size(1).max_size(1024));
        let expected = sha256_oracle(&body);
        assert_eq!(digest(&body), expected);
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
        assert_eq!(store.accept(&body, NS_PER_SECOND), Ok(expected));
    }

    /// @cc [owner:ghuntley,label:verification;capacity] trace-spool-admission-bounds
    /// Oversized bodies MUST refuse in sanitize (capacity) and accept (invalid);
    /// empty bodies MUST refuse in both; accept MUST refuse a zero clock and any
    /// clock whose expiry would overflow the signed SQLite range. Refusal MUST
    /// count once and leave custody unchanged; in-range admission MUST succeed.
    #[hegel::test(test_cases = 48)]
    fn body_clock_and_retention_bounds_refuse_before_custody(tc: TestCase) {
        let retention_seconds = tc.draw(gs::integers::<u64>().min_value(60).max_value(31_536_000));
        let boundary = i64::MAX as u64 - retention_seconds * NS_PER_SECOND;
        let length = match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => 0,
            1 => BODY_LIMIT + 1 + tc.draw(gs::integers::<usize>().max_value(4096)),
            2 => BODY_LIMIT,
            _ => tc.draw(gs::integers::<usize>().min_value(1).max_value(512)),
        };
        let fill = tc.draw(gs::integers::<u8>());
        let body = vec![fill; length];
        let offset = tc.draw(gs::integers::<u64>().max_value(1 << 20));
        let now_ns = match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => 0,
            1 => boundary - offset,
            2 => boundary.saturating_add(1 + offset),
            _ => tc.draw(gs::integers::<u64>()),
        };
        let sanitized = Schema {
            services: BTreeMap::new(),
            uuid_attributes: BTreeSet::new(),
            enum_attributes: BTreeSet::new(),
            numeric_attributes: BTreeSet::new(),
            enum_values: BTreeSet::new(),
        }
        .sanitize(&body, "galileo", "host", "rev");
        let (schema, _) = schema_request();
        if length > BODY_LIMIT {
            assert_eq!(sanitized, Err(Error::Capacity));
            assert_eq!(
                schema.sanitize(&body, "galileo", "host", "rev"),
                Err(Error::Capacity)
            );
        } else if length == 0 {
            assert_eq!(
                schema.sanitize(&body, "galileo", "host", "rev"),
                Err(Error::Invalid)
            );
        }
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, 8_388_608, retention_seconds).unwrap();
        let admissible = (1..=BODY_LIMIT).contains(&length) && now_ns != 0 && now_ns <= boundary;
        let result = store.accept(&body, now_ns);
        if admissible {
            assert_eq!(result, Ok(sha256_oracle(&body)));
            assert_eq!((store.batches, store.health.refused), (1, 0));
            let batch = store.pending().unwrap().unwrap();
            assert_eq!(batch.accepted_at_ns, now_ns);
            assert_eq!(
                batch.expires_at_ns,
                now_ns + retention_seconds * NS_PER_SECOND
            );
        } else {
            assert_eq!(result, Err(Error::Invalid));
            assert_eq!((store.batches, store.health.refused), (0, 1));
            assert!(store.pending().unwrap().is_none());
        }
    }

    /// @cc [owner:ghuntley,label:verification;recovery] trace-spool-sql-integer-roundtrip
    /// `sql` MUST accept exactly the values representable as a signed SQLite
    /// integer and preserve them; `number` MUST read them back unchanged and
    /// refuse negative stored integers.
    #[hegel::test(test_cases = 64)]
    fn sql_accepts_exactly_signed_range_and_roundtrips_through_sqlite(tc: TestCase) {
        let value = match tc.draw(gs::integers::<u8>().max_value(3)) {
            0 => i64::MAX as u64 - tc.draw(gs::integers::<u64>().max_value(16)),
            1 => i64::MAX as u64 + 1 + tc.draw(gs::integers::<u64>().max_value(16)),
            2 => tc.draw(gs::integers::<u64>().max_value(16)),
            _ => tc.draw(gs::integers::<u64>()),
        };
        let converted = sql(value);
        if value <= i64::MAX as u64 {
            assert_eq!(converted.map(|signed| signed as u64), Ok(value));
        } else {
            assert_eq!(converted, Err(Error::Invalid));
            return;
        }
        let directory = Directory::new();
        let database = rusqlite::Connection::open(directory.0.join("roundtrip.sqlite")).unwrap();
        database
            .execute_batch("CREATE TABLE numbers (value INTEGER NOT NULL) STRICT")
            .unwrap();
        database
            .execute("INSERT INTO numbers VALUES (?1)", [converted.unwrap()])
            .unwrap();
        let read: u64 = database
            .query_row("SELECT value FROM numbers", [], |row| number(row, 0))
            .unwrap();
        assert_eq!(read, value);
        let negative = -1 - tc.draw(gs::integers::<i64>().min_value(0));
        let refused = database.query_row("SELECT ?1", [negative], |row| number(row, 0));
        assert!(matches!(
            refused,
            Err(rusqlite::Error::IntegralValueOutOfRange(0, stored)) if stored == negative
        ));
    }

    #[test]
    fn full_archive_refuses_without_evicting_and_corruption_poisons() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, 4_194_304, 3600).unwrap();
        let body = vec![1; BODY_LIMIT];
        let id = store.accept(&body, NS_PER_SECOND).unwrap();
        for n in 2u8..8 {
            store
                .accept(&vec![n; BODY_LIMIT], NS_PER_SECOND + u64::from(n))
                .unwrap();
        }
        assert_eq!(
            store.accept(&vec![8; BODY_LIMIT], NS_PER_SECOND),
            Err(Error::Capacity)
        );
        let batch = store.pending().unwrap().unwrap();
        assert_eq!(store.body(&batch).unwrap(), body);
        store
            .db
            .execute("UPDATE batches SET body=X'00' WHERE id=?1", [id])
            .unwrap();
        assert_eq!(store.body(&batch), Err(Error::Storage));
        assert_eq!(store.accept(b"new", NS_PER_SECOND), Err(Error::Poisoned));
    }
    #[test]
    fn concurrent_writer_missing_database_and_foreign_producer_refuse() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
        assert!(Store::open(&directory.0, 8_388_608, 3600).is_err());
        store
            .bind(
                "lilly",
                "node",
                "root",
                "lilly.service",
                "/system.slice/lilly.service",
            )
            .unwrap();
        assert_eq!(
            store.bind(
                "ziggy",
                "node",
                "root",
                "lilly.service",
                "/system.slice/lilly.service"
            ),
            Err(Error::Foreign)
        );
        store.accept(b"accepted", NS_PER_SECOND).unwrap();
        drop(store);
        std::fs::remove_file(directory.0.join("archive.sqlite")).unwrap();
        assert!(Store::open(&directory.0, 8_388_608, 3600).is_err());
    }

    #[test]
    fn startup_refuses_orphan_pending_mismatched_index_and_missing_tables() {
        for mutation in [
            "UPDATE pending SET id='orphan-reference'",
            "UPDATE pending SET bytes=bytes+1",
            "UPDATE pending SET accepted_ns=accepted_ns+1",
            "DROP TABLE pending",
        ] {
            let directory = Directory::new();
            let mut store = Store::open(&directory.0, 8_388_608, 3600).unwrap();
            store.accept(b"immutable-accepted", NS_PER_SECOND).unwrap();
            drop(store);
            let database = rusqlite::Connection::open(directory.0.join("archive.sqlite")).unwrap();
            database.execute_batch("PRAGMA foreign_keys=OFF").unwrap();
            database.execute_batch(mutation).unwrap();
            drop(database);
            assert!(
                matches!(
                    Store::open(&directory.0, 8_388_608, 3600),
                    Err(Error::Storage)
                ),
                "{mutation}"
            );
        }
    }
}
