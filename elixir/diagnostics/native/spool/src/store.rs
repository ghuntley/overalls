//! Durable SQLite custody: admission, delivery, replay and expiry.

use crate::{sys, Error, BODY_LIMIT, NS_PER_SECOND};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

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
    pub(crate) db: rusqlite::Connection,
    quota: u64,
    retention_ns: u64,
    pending_quota: u64,
    bytes: u64,
    pub(crate) batches: u64,
    pending_bytes: u64,
    pending_batches: u64,
    poisoned: bool,
    pub health: Health,
}

fn private(file: &File) -> Result<(), Error> {
    let m = file.metadata().map_err(|_| Error::Storage)?;
    if m.is_file() && m.uid() == sys::geteuid() && m.mode() & 0o777 == 0o600 && m.nlink() == 1 {
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

pub(crate) fn digest(body: &[u8]) -> String {
    format!("{:x}", Sha256::digest(body))
}

pub(crate) fn sql(value: u64) -> Result<i64, Error> {
    i64::try_from(value).map_err(|_| Error::Invalid)
}
pub(crate) fn number(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}

impl Store {
    pub fn open(directory: &Path, quota: u64, retention_seconds: u64) -> Result<Self, Error> {
        use rusqlite::OptionalExtension;
        let metadata = std::fs::symlink_metadata(directory).map_err(|_| Error::Storage)?;
        if !metadata.is_dir()
            || metadata.uid() != sys::geteuid()
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
        if !sys::try_lock_exclusive(&lock) {
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
