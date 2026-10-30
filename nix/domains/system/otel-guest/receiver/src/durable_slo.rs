//! Durable accounting for admitted host application requests, without payloads.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const MAXIMUM: u64 = i64::MAX as u64;
/// The only accepted checkpoint format.
pub const VERSION: u8 = 3;
pub const MAX_PENDING: usize = 4096;
pub const BOUNDS_US: [u64; 7] = [
    10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000,
];
pub const BROWSER_BOUNDS_US: [u64; 7] = [
    100_000, 500_000, 1_000_000, 5_000_000, 10_000_000, 30_000_000, 60_000_000,
];

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    MarshallWeb,
    MarshallLive,
    Galileo,
    Enrico,
    Brady,
    Porsche,
    AudiPrivate,
    AudiDns,
    AudiSsh,
    VscodeBrowserNixos,
    VscodeBrowserUbuntu,
}

impl Source {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "marshall_web" => Some(Self::MarshallWeb),
            "marshall_live" => Some(Self::MarshallLive),
            "galileo" => Some(Self::Galileo),
            "enrico" => Some(Self::Enrico),
            "brady" => Some(Self::Brady),
            "porsche" => Some(Self::Porsche),
            "audi_private" => Some(Self::AudiPrivate),
            "audi_dns" => Some(Self::AudiDns),
            "audi_ssh" => Some(Self::AudiSsh),
            "vscode_browser_nixos" => Some(Self::VscodeBrowserNixos),
            "vscode_browser_ubuntu" => Some(Self::VscodeBrowserUbuntu),
            _ => None,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::MarshallWeb => "marshall_web",
            Self::MarshallLive => "marshall_live",
            Self::Galileo => "galileo",
            Self::Enrico => "enrico",
            Self::Brady => "brady",
            Self::Porsche => "porsche",
            Self::AudiPrivate => "audi_private",
            Self::AudiDns => "audi_dns",
            Self::AudiSsh => "audi_ssh",
            Self::VscodeBrowserNixos => "vscode_browser_nixos",
            Self::VscodeBrowserUbuntu => "vscode_browser_ubuntu",
        }
    }
    /// Browser journeys MUST use their reviewed minute deadline histogram;
    /// existing request sources MUST retain their accepted bounds.
    pub fn bounds_us(self) -> [u64; 7] {
        match self {
            Self::VscodeBrowserNixos | Self::VscodeBrowserUbuntu => BROWSER_BOUNDS_US,
            _ => BOUNDS_US,
        }
    }
}

/// Linux process identity; the runtime must verify this against peer credentials.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(deny_unknown_fields)]
pub struct Producer {
    pub pid: u32,
    pub start_ticks: u64,
    pub boot_id: String,
}

impl Producer {
    fn valid(&self) -> bool {
        self.pid > 0
            && self.pid <= i32::MAX as u32
            && self.start_ticks > 0
            && self.boot_id.len() == 36
            && self.boot_id.bytes().enumerate().all(|(index, byte)| {
                if [8, 13, 18, 23].contains(&index) {
                    byte == b'-'
                } else {
                    byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()
                }
            })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Admission {
    pub producer: Producer,
    pub admitted_at_ns: u64,
    pub deadline_ns: u64,
    pub crossed_gap: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Totals {
    pub requests: u64,
    pub successes: u64,
    pub failures: u64,
    pub duration_count: u64,
    pub duration_sum_us: u64,
    pub bucket_counts: [u64; 8],
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub version: u8,
    pub source: Source,
    pub started_at_ns: u64,
    pub coverage_started_at_ns: u64,
    pub incarnation: String,
    pub next_id: u64,
    pub excluded: u64,
    pub totals: Totals,
    pub pending: BTreeMap<u64, Admission>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Success,
    Failure,
    Exclude,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    /// A checkpoint whose version is not [`VERSION`]; no upgrade path exists.
    Version,
    Capacity,
    Overflow,
    Unknown,
    Foreign,
    Expired,
    Storage,
    Poisoned,
}

impl State {
    pub fn new(source: Source, started_at_ns: u64, incarnation: String) -> Result<Self, Error> {
        let state = Self {
            version: VERSION,
            source,
            started_at_ns,
            coverage_started_at_ns: started_at_ns,
            incarnation,
            next_id: 1,
            excluded: 0,
            totals: Totals {
                requests: 0,
                successes: 0,
                failures: 0,
                duration_count: 0,
                duration_sum_us: 0,
                bucket_counts: [0; 8],
            },
            pending: BTreeMap::new(),
        };
        state.validate()?;
        Ok(state)
    }

    /// @cc [owner:ghuntley,label:reliability;security] durable-request-state-validation
    /// Restored state MUST conserve admitted requests as terminal, excluded or
    /// pending; reject malformed identities, overflow, excessive pending entries,
    /// duration arithmetic drift and admissions outside the permanent lifetime.
    pub fn validate(&self) -> Result<(), Error> {
        let totals = &self.totals;
        let values = [
            self.next_id,
            self.excluded,
            totals.requests,
            totals.successes,
            totals.failures,
            totals.duration_count,
            totals.duration_sum_us,
        ];
        if self.version != VERSION
            || self.started_at_ns == 0
            || self.started_at_ns > MAXIMUM
            || self.coverage_started_at_ns < self.started_at_ns
            || self.coverage_started_at_ns > MAXIMUM
            || self.next_id == 0
            || self.incarnation.len() != 32
            || !self
                .incarnation
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            || values.into_iter().any(|v| v > MAXIMUM)
            || totals.bucket_counts.iter().any(|v| *v > MAXIMUM)
            || self.pending.len() > MAX_PENDING
            || totals.successes.checked_add(totals.failures) != Some(totals.requests)
            || totals.duration_count > totals.requests
            || (totals.duration_count == 0 && totals.duration_sum_us != 0)
            || totals
                .bucket_counts
                .iter()
                .try_fold(0_u64, |a, b| a.checked_add(*b))
                != Some(totals.duration_count)
            || totals
                .requests
                .checked_add(self.excluded)
                .and_then(|v| v.checked_add(self.pending.len() as u64))
                != Some(self.next_id - 1)
            || self.pending.iter().any(|(id, admission)| {
                *id == 0
                    || *id >= self.next_id
                    || !admission.producer.valid()
                    || admission.admitted_at_ns < self.started_at_ns
                    || admission.deadline_ns <= admission.admitted_at_ns
            })
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:reliability;capacity] durable-request-admission
    /// Admission MUST allocate a never-reused sequence and immutable deadline.
    /// Invalid or capacity-refused admissions MUST leave state unchanged. The
    /// runtime MUST persist this transition before acknowledging admission.
    pub fn admit(
        &mut self,
        producer: Producer,
        now_ns: u64,
        deadline_ns: u64,
    ) -> Result<u64, Error> {
        if !producer.valid() || now_ns < self.started_at_ns || deadline_ns <= now_ns {
            return Err(Error::Invalid);
        }
        if self.pending.len() >= MAX_PENDING {
            return Err(Error::Capacity);
        }
        let next = self
            .next_id
            .checked_add(1)
            .filter(|v| *v <= MAXIMUM)
            .ok_or(Error::Overflow)?;
        let id = self.next_id;
        self.pending.insert(
            id,
            Admission {
                producer,
                admitted_at_ns: now_ns,
                deadline_ns,
                crossed_gap: false,
            },
        );
        self.next_id = next;
        Ok(id)
    }

    /// @cc [owner:ghuntley,label:reliability;security] durable-request-terminal-fence
    /// Only the admission's exact producer MAY settle it, once. Late success
    /// MUST be refused. Exclusions MUST retain admission conservation without
    /// incrementing completion counters. Refusals MUST leave state unchanged.
    pub fn finish(
        &mut self,
        id: u64,
        producer: &Producer,
        now_ns: u64,
        outcome: Outcome,
        duration_us: u64,
    ) -> Result<(), Error> {
        let admission = self.pending.get(&id).ok_or(Error::Unknown)?;
        if &admission.producer != producer {
            return Err(Error::Foreign);
        }
        if now_ns < admission.admitted_at_ns {
            return Err(Error::Invalid);
        }
        if now_ns >= admission.deadline_ns {
            return Err(Error::Expired);
        }
        self.settle(id, outcome, Some(duration_us), now_ns)
    }

    /// @cc [owner:ghuntley,label:reliability] request-recording-gap-preserves-history
    /// A recording gap MUST advance coverage and mark existing admissions as
    /// crossing unknown coverage, without changing identity, lifetime, counters,
    /// producer fences or deadlines. Backward clocks MUST refuse.
    pub fn mark_gap(&mut self, now_ns: u64) -> Result<(), Error> {
        if now_ns < self.coverage_started_at_ns || now_ns > MAXIMUM {
            return Err(Error::Invalid);
        }
        self.coverage_started_at_ns = now_ns;
        for admission in self.pending.values_mut() {
            admission.crossed_gap = true;
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:reliability] gap-crossing-settlement-coverage
    /// A countable admission crossing a recording gap MUST withhold windows
    /// through its settlement. Settlement MUST NOT mark later unaffected work
    /// uncertain or reset lifetime/counters; exclusions stay outside the budget.
    fn settle(
        &mut self,
        id: u64,
        outcome: Outcome,
        duration_us: Option<u64>,
        now_ns: u64,
    ) -> Result<(), Error> {
        let admission = self.pending.get(&id).ok_or(Error::Unknown)?;
        let mut candidate = self.clone();
        if outcome != Outcome::Exclude && admission.crossed_gap {
            candidate.coverage_started_at_ns = candidate.coverage_started_at_ns.max(now_ns);
        }
        candidate.pending.remove(&id);
        if outcome == Outcome::Exclude {
            candidate.excluded = add(candidate.excluded, 1)?;
        } else {
            let totals = &mut candidate.totals;
            totals.requests = add(totals.requests, 1)?;
            if outcome == Outcome::Success {
                totals.successes = add(totals.successes, 1)?;
            } else {
                totals.failures = add(totals.failures, 1)?;
            }
            if let Some(duration) = duration_us {
                totals.duration_count = add(totals.duration_count, 1)?;
                totals.duration_sum_us = add(totals.duration_sum_us, duration)?;
                let bucket = self
                    .source
                    .bounds_us()
                    .iter()
                    .position(|bound| duration <= *bound)
                    .unwrap_or(7);
                totals.bucket_counts[bucket] = add(totals.bucket_counts[bucket], 1)?;
            }
        }
        candidate.validate()?;
        *self = candidate;
        Ok(())
    }

    /// @cc [owner:ghuntley,label:reliability;recovery] durable-request-loss-accounting
    /// Expired admissions and admissions belonging to proven-dead producers
    /// MUST settle as failures exactly once. Missing completion duration MUST
    /// NOT be fabricated from recorder downtime. Reconciliation MUST NOT modify
    /// execution, authorization, permanent source identity or its lifetime.
    pub fn reconcile(&mut self, now_ns: u64, dead: &[Producer]) -> Result<usize, Error> {
        let ids: Vec<u64> = self
            .pending
            .iter()
            .filter_map(|(id, admission)| {
                (now_ns >= admission.deadline_ns || dead.contains(&admission.producer))
                    .then_some(*id)
            })
            .collect();
        let mut candidate = self.clone();
        for id in &ids {
            candidate.settle(*id, Outcome::Failure, None, now_ns)?;
        }
        *self = candidate;
        Ok(ids.len())
    }
}

fn add(left: u64, right: u64) -> Result<u64, Error> {
    left.checked_add(right)
        .filter(|value| *value <= MAXIMUM)
        .ok_or(Error::Overflow)
}

const STATE_LIMIT: u64 = 1_048_576;

/// Exclusive private checkpoint owner. A failed durability operation poisons
/// the instance until reopen; callers must never publish a fresh poisoned state.
pub struct Store {
    directory: PathBuf,
    state: State,
    poisoned: bool,
    _lock: File,
}

impl Store {
    /// @cc [owner:ghuntley,label:security;durability] durable-request-checkpoint-custody
    /// Open MUST refuse symlinks, foreign ownership, nonprivate state, concurrent
    /// writers, corrupt state and disappearance of an initialized checkpoint.
    /// It MUST NOT silently start a new lifetime after losing acknowledged state.
    /// Only checkpoint `VERSION` is accepted; any other version refuses with
    /// `Error::Version` and leaves the file unchanged, with no upgrade path.
    pub fn open(
        directory: &Path,
        source: Source,
        now_ns: u64,
        incarnation: String,
    ) -> Result<Self, Error> {
        let metadata = std::fs::symlink_metadata(directory).map_err(|_| Error::Storage)?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
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
            .open(directory.join("lock"))
            .map_err(|_| Error::Storage)?;
        private_file(&lock)?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(Error::Storage);
        }
        let path = directory.join("state.json");
        let state = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => {
                private_file(&file)?;
                if file.metadata().map_err(|_| Error::Storage)?.len() > STATE_LIMIT {
                    return Err(Error::Invalid);
                }
                let mut bytes = Vec::new();
                file.take(STATE_LIMIT + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|_| Error::Storage)?;
                if bytes.len() as u64 > STATE_LIMIT {
                    return Err(Error::Invalid);
                }
                let state: State = serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)?;
                // Only the current checkpoint format is accepted (ADR-0159).
                if state.version != VERSION {
                    return Err(Error::Version);
                }
                state.validate()?;
                if state.source != source || now_ns < state.started_at_ns {
                    return Err(Error::Invalid);
                }
                state
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match std::fs::symlink_metadata(directory.join("initialized")) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    _ => return Err(Error::Storage),
                }
                State::new(source, now_ns, incarnation)?
            }
            Err(_) => return Err(Error::Storage),
        };
        // An interrupted stage is never a substitute for committed state.
        let stage = directory.join("state.new");
        match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&stage)
        {
            Ok(file) => {
                private_file(&file)?;
                std::fs::remove_file(stage).map_err(|_| Error::Storage)?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Error::Storage),
        }
        let mut store = Self {
            directory: directory.into(),
            state,
            poisoned: false,
            _lock: lock,
        };
        store.persist(&store.state)?;
        let marker = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("initialized"))
            .map_err(|_| Error::Storage)?;
        private_file(&marker)?;
        marker.sync_all().map_err(|_| Error::Storage)?;
        File::open(directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::Storage)?;
        store.poisoned = false;
        Ok(store)
    }

    pub fn state(&self) -> Result<&State, Error> {
        if self.poisoned {
            Err(Error::Poisoned)
        } else {
            Ok(&self.state)
        }
    }

    /// @cc [owner:ghuntley,label:durability;reliability] durable-request-before-ack
    /// A successful transition MUST fsync its private stage, atomically replace
    /// the checkpoint and fsync the directory before returning. Failed writes
    /// MUST forbid further acknowledgments or fresh snapshots until reopen.
    pub fn transition<T>(
        &mut self,
        apply: impl FnOnce(&mut State) -> Result<T, Error>,
    ) -> Result<T, Error> {
        if self.poisoned {
            return Err(Error::Poisoned);
        }
        let mut candidate = self.state.clone();
        let result = apply(&mut candidate)?;
        candidate.validate()?;
        if candidate.source != self.state.source
            || candidate.started_at_ns != self.state.started_at_ns
            || candidate.incarnation != self.state.incarnation
            || candidate.coverage_started_at_ns < self.state.coverage_started_at_ns
            || candidate.next_id < self.state.next_id
            || candidate.excluded < self.state.excluded
            || candidate.totals.requests < self.state.totals.requests
            || candidate.totals.successes < self.state.totals.successes
            || candidate.totals.failures < self.state.totals.failures
            || candidate.totals.duration_count < self.state.totals.duration_count
            || candidate.totals.duration_sum_us < self.state.totals.duration_sum_us
            || candidate
                .totals
                .bucket_counts
                .iter()
                .zip(self.state.totals.bucket_counts)
                .any(|(new, old)| *new < old)
            || self.state.pending.iter().any(|(id, admission)| {
                candidate.pending.get(id).is_some_and(|current| {
                    current.producer != admission.producer
                        || current.admitted_at_ns != admission.admitted_at_ns
                        || current.deadline_ns != admission.deadline_ns
                        || (admission.crossed_gap && !current.crossed_gap)
                })
            })
        {
            return Err(Error::Invalid);
        }
        if self.persist(&candidate).is_err() {
            self.poisoned = true;
            return Err(Error::Storage);
        }
        self.state = candidate;
        Ok(result)
    }

    fn persist(&self, state: &State) -> Result<(), Error> {
        let bytes = serde_json::to_vec(state).map_err(|_| Error::Invalid)?;
        if bytes.len() as u64 > STATE_LIMIT {
            return Err(Error::Capacity);
        }
        let stage = self.directory.join("state.new");
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&stage)
            .map_err(|_| Error::Storage)?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Error::Storage)?;
        std::fs::rename(stage, self.directory.join("state.json")).map_err(|_| Error::Storage)?;
        File::open(&self.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::Storage)
    }
}

fn private_file(file: &File) -> Result<(), Error> {
    let metadata = file.metadata().map_err(|_| Error::Storage)?;
    if metadata.is_file()
        && metadata.uid() == unsafe { libc::geteuid() }
        && metadata.mode() & 0o777 == 0o600
        && metadata.nlink() == 1
    {
        Ok(())
    } else {
        Err(Error::Storage)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "overalls-durable-slo-{}-{}",
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

    fn producer() -> Producer {
        Producer {
            pid: 42,
            start_ticks: 1,
            boot_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".into(),
        }
    }
    fn state() -> State {
        State::new(Source::MarshallWeb, 1, "a".repeat(32)).unwrap()
    }

    /// @cc [owner:ghuntley,label:verification;durability] otel-receiver-checkpoint-history-property
    /// Generated admit/finish histories MUST survive every reopen unchanged and
    /// settle pending loss exactly once, keeping the original lifetime.
    #[hegel::test(test_cases = 32)]
    fn checkpoint_histories_preserve_lifetime_and_recover_pending_loss(tc: TestCase) {
        let operations = tc.draw(
            gs::vecs(gs::tuples!(
                gs::booleans(),
                gs::integers::<u64>().max_value(999_999)
            ))
            .max_size(11),
        );
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, Source::AudiSsh, 1, "a".repeat(32)).unwrap();
        let mut completed = 0;
        for (finish, duration) in operations {
            let id = store
                .transition(|state| state.admit(producer(), 2, 100))
                .unwrap();
            if finish {
                store
                    .transition(|state| {
                        state.finish(id, &producer(), 3, Outcome::Success, duration)
                    })
                    .unwrap();
                completed += 1;
            }
            let committed = store.state().unwrap().clone();
            drop(store);
            store = Store::open(&directory.0, Source::AudiSsh, 4, "b".repeat(32)).unwrap();
            assert_eq!(store.state().unwrap(), &committed);
        }
        let admitted = store.state().unwrap().next_id - 1;
        store
            .transition(|state| state.reconcile(4, &[producer()]))
            .unwrap();
        drop(store);
        let mut store = Store::open(&directory.0, Source::AudiSsh, 5, "c".repeat(32)).unwrap();
        assert_eq!(store.state().unwrap().totals.requests, admitted);
        assert_eq!(store.state().unwrap().totals.successes, completed);
        assert_eq!(store.state().unwrap().totals.failures, admitted - completed);
        assert_eq!(store.state().unwrap().totals.duration_count, completed);
        assert_eq!(store.state().unwrap().started_at_ns, 1);
        assert_eq!(&store.state().unwrap().incarnation, &"a".repeat(32));
        assert_eq!(
            store.transition(|state| state.reconcile(100, &[producer()])),
            Ok(0)
        );
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-gap-settlement-property
    /// For generated gap times and every terminal kind, a gap-crossing
    /// settlement MUST withhold coverage through settlement without cascading.
    #[hegel::test(test_cases = 256)]
    fn gap_crossing_terminals_withhold_through_settlement_without_cascading(tc: TestCase) {
        let gap = tc.draw(gs::integers::<u64>().min_value(3).max_value(99));
        let terminal = tc.draw(gs::integers::<u8>().max_value(4));
        let mut state = state();
        let old = state.admit(producer(), 2, 1_000).unwrap();
        state.mark_gap(gap).unwrap();
        let later_producer = Producer {
            start_ticks: 2,
            ..producer()
        };
        let later = state.admit(later_producer.clone(), gap + 1, 2_000).unwrap();
        let expected = match terminal {
            0 => {
                state
                    .finish(old, &producer(), gap + 2, Outcome::Success, 10)
                    .unwrap();
                gap + 2
            }
            1 => {
                state
                    .finish(old, &producer(), gap + 2, Outcome::Failure, 10)
                    .unwrap();
                gap + 2
            }
            2 => {
                state.reconcile(1_000, &[]).unwrap();
                1_000
            }
            3 => {
                state.reconcile(gap + 2, &[producer()]).unwrap();
                gap + 2
            }
            _ => {
                state
                    .finish(old, &producer(), gap + 2, Outcome::Exclude, 0)
                    .unwrap();
                gap
            }
        };
        assert_eq!(state.coverage_started_at_ns, expected);
        state
            .finish(later, &later_producer, expected + 3, Outcome::Success, 5)
            .unwrap();
        assert_eq!(state.coverage_started_at_ns, expected);
        assert_eq!(state.started_at_ns, 1);
        assert_eq!(state.next_id, 3);
        assert_eq!(state.totals.requests + state.excluded, 2);
        state.validate().unwrap();
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-gap-history-property
    /// Generated gap sequences MUST only advance coverage and mark crossings;
    /// backward gaps MUST refuse without changing state.
    #[hegel::test(test_cases = 256)]
    fn recording_gaps_preserve_admissions_counters_and_lifetime(tc: TestCase) {
        let gaps =
            tc.draw(gs::vecs(gs::integers::<u64>().min_value(3).max_value(999_999)).max_size(63));
        let mut state = state();
        state.admit(producer(), 2, 2_000_000).unwrap();
        let original = state.clone();
        for gap in gaps {
            let before = state.clone();
            if gap < state.coverage_started_at_ns {
                assert_eq!(state.mark_gap(gap), Err(Error::Invalid));
                assert_eq!(state.clone(), before);
            } else {
                state.mark_gap(gap).unwrap();
                assert!(state
                    .pending
                    .values()
                    .all(|admission| admission.crossed_gap));
            }
            let mut without_coverage_change = state.clone();
            without_coverage_change.coverage_started_at_ns = original.coverage_started_at_ns;
            for (id, admission) in &mut without_coverage_change.pending {
                admission.crossed_gap = original.pending[id].crossed_gap;
            }
            assert_eq!(&without_coverage_change, &original);
            state.validate().unwrap();
        }
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-admission-conservation-property
    /// Generated histories MUST conserve every admission across serde
    /// round-trips and settle all remaining work exactly once.
    #[hegel::test(test_cases = 256)]
    fn histories_conserve_every_admission(tc: TestCase) {
        let steps = tc.draw(
            gs::vecs(gs::tuples!(
                gs::integers::<u8>().max_value(4),
                gs::integers::<u64>().max_value(19_999_999)
            ))
            .max_size(127),
        );
        let mut state = state();
        for (operation, duration) in steps {
            let id = state.admit(producer(), 2, 100).unwrap();
            match operation {
                0 => state
                    .finish(id, &producer(), 3, Outcome::Success, duration)
                    .unwrap(),
                1 => state
                    .finish(id, &producer(), 3, Outcome::Failure, duration)
                    .unwrap(),
                2 => state
                    .finish(id, &producer(), 3, Outcome::Exclude, duration)
                    .unwrap(),
                3 => {
                    state.reconcile(3, &[producer()]).unwrap();
                }
                _ => {}
            }
            state.validate().unwrap();
            let wire = serde_json::to_vec(&state).unwrap();
            let restored: State = serde_json::from_slice(&wire).unwrap();
            assert_eq!(&state, &restored);
            state = restored;
        }
        let before = state.clone();
        state.reconcile(100, &[]).unwrap();
        assert!(state.pending.is_empty());
        assert_eq!(state.totals.requests + state.excluded, state.next_id - 1);
        assert_eq!(state.totals.duration_count, before.totals.duration_count);
        let settled = state.clone();
        assert_eq!(state.reconcile(101, &[producer()]).unwrap(), 0);
        assert_eq!(state, settled);
    }

    /// @cc [owner:ghuntley,label:verification;security] otel-receiver-terminal-fence-property
    /// For generated durations, foreign, late and duplicate results MUST refuse
    /// without changing totals.
    #[hegel::test(test_cases = 256)]
    fn foreign_late_and_duplicate_results_cannot_change_totals(tc: TestCase) {
        let duration = tc.draw(gs::integers::<u64>().max_value(MAXIMUM - 1));
        let mut state = state();
        let id = state.admit(producer(), 2, 100).unwrap();
        let before = state.clone();
        let foreign = Producer {
            start_ticks: 2,
            ..producer()
        };
        assert_eq!(
            state.finish(id, &foreign, 3, Outcome::Success, duration),
            Err(Error::Foreign)
        );
        assert_eq!(
            state.finish(id, &producer(), 100, Outcome::Success, duration),
            Err(Error::Expired)
        );
        assert_eq!(&state, &before);
        state
            .finish(id, &producer(), 3, Outcome::Success, duration)
            .unwrap();
        let terminal = state.clone();
        assert_eq!(
            state.finish(id, &producer(), 4, Outcome::Failure, duration),
            Err(Error::Unknown)
        );
        assert_eq!(state, terminal);
    }

    const SOURCES: [Source; 11] = [
        Source::MarshallWeb,
        Source::MarshallLive,
        Source::Galileo,
        Source::Enrico,
        Source::Brady,
        Source::Porsche,
        Source::AudiPrivate,
        Source::AudiDns,
        Source::AudiSsh,
        Source::VscodeBrowserNixos,
        Source::VscodeBrowserUbuntu,
    ];

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-source-name-roundtrip
    /// Every source MUST round-trip through `name`/`from_name` and serialize as
    /// its name; any accepted string MUST be exactly the accepted source's name.
    #[hegel::test(test_cases = 256)]
    fn source_names_round_trip(tc: TestCase) {
        let source = tc.draw(gs::sampled_from(SOURCES.to_vec()));
        assert_eq!(Source::from_name(source.name()), Some(source));
        assert_eq!(
            serde_json::to_string(&source).unwrap(),
            format!("\"{}\"", source.name())
        );
        let candidate = if tc.draw(gs::booleans()) {
            let name = source.name();
            match tc.draw(gs::integers::<u8>().max_value(2)) {
                0 => format!("{name}_"),
                1 => name.to_uppercase(),
                _ => name[1..].to_owned(),
            }
        } else {
            tc.draw(gs::text().alphabet("abcdeghilnoprstuvwxyz_").max_size(24))
        };
        match Source::from_name(&candidate) {
            Some(parsed) => assert_eq!(parsed.name(), candidate),
            None => assert!(SOURCES.iter().all(|known| known.name() != candidate)),
        }
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-source-bounds-increasing
    /// Every source's histogram bounds MUST be strictly increasing, and only the
    /// browser sources MAY use the browser bound set.
    #[hegel::test(test_cases = 64)]
    fn source_bounds_strictly_increase(tc: TestCase) {
        let source = tc.draw(gs::sampled_from(SOURCES.to_vec()));
        let bounds = source.bounds_us();
        assert!(bounds.windows(2).all(|pair| pair[0] < pair[1]));
        let browser = matches!(
            source,
            Source::VscodeBrowserNixos | Source::VscodeBrowserUbuntu
        );
        assert_eq!(
            bounds,
            if browser {
                BROWSER_BOUNDS_US
            } else {
                BOUNDS_US
            }
        );
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-add-overflow-oracle
    /// `add` MUST return the exact sum when it is at most `MAXIMUM` and
    /// `Overflow` exactly when the mathematical sum exceeds `MAXIMUM`.
    #[hegel::test(test_cases = 512)]
    fn add_errs_exactly_past_maximum(tc: TestCase) {
        let anchors = vec![0, 1, MAXIMUM / 2, MAXIMUM - 1, MAXIMUM, u64::MAX - 1];
        let operand = || {
            if tc.draw(gs::booleans()) {
                tc.draw(gs::integers::<u64>())
            } else {
                tc.draw(gs::sampled_from(anchors.clone()))
                    .saturating_add(tc.draw(gs::integers::<u64>().max_value(2)))
            }
        };
        let left = operand();
        let right = operand();
        let sum = u128::from(left) + u128::from(right);
        let expected = if sum <= u128::from(MAXIMUM) {
            Ok(u64::try_from(sum).unwrap())
        } else {
            Err(Error::Overflow)
        };
        assert_eq!(add(left, right), expected);
    }

    /// @cc [owner:ghuntley,label:verification;reliability] otel-receiver-transitions-preserve-validity
    /// Every state reached from a new state through generated admit, finish,
    /// mark_gap and reconcile calls MUST pass `validate`, and every refused
    /// transition MUST leave the state unchanged.
    #[hegel::test(test_cases = 256)]
    fn transitions_preserve_validity(tc: TestCase) {
        let producers = vec![
            producer(),
            Producer {
                start_ticks: 2,
                ..producer()
            },
            Producer {
                pid: 0,
                ..producer()
            },
        ];
        let source = tc.draw(gs::sampled_from(SOURCES.to_vec()));
        let started = tc.draw(gs::integers::<u64>().min_value(1).max_value(5));
        let mut state = State::new(source, started, "a".repeat(32)).unwrap();
        let steps = tc.draw(gs::integers::<usize>().max_value(48));
        for _ in 0..steps {
            let before = state.clone();
            let now = tc.draw(gs::integers::<u64>().max_value(400));
            let result: Result<(), Error> = match tc.draw(gs::integers::<u8>().max_value(3)) {
                0 => {
                    let who = tc.draw(gs::sampled_from(producers.clone()));
                    let deadline = now + tc.draw(gs::integers::<u64>().max_value(200));
                    state.admit(who, now, deadline).map(drop)
                }
                1 => {
                    let id = tc.draw(gs::integers::<u64>().max_value(state.next_id + 1));
                    let who = tc.draw(gs::sampled_from(producers.clone()));
                    let outcome = tc.draw(gs::sampled_from(vec![
                        Outcome::Success,
                        Outcome::Failure,
                        Outcome::Exclude,
                    ]));
                    let duration = if tc.draw(gs::booleans()) {
                        tc.draw(gs::integers::<u64>().max_value(100_000_000))
                    } else {
                        tc.draw(gs::integers::<u64>())
                    };
                    state.finish(id, &who, now, outcome, duration)
                }
                2 => state.mark_gap(now),
                _ => {
                    let dead: Vec<Producer> = producers
                        .iter()
                        .filter(|_| tc.draw(gs::booleans()))
                        .cloned()
                        .collect();
                    state.reconcile(now, &dead).map(drop)
                }
            };
            if result.is_err() {
                assert_eq!(state, before);
            }
            assert_eq!(state.validate(), Ok(()));
        }
    }

    #[test]
    fn admission_capacity_and_corrupt_restore_refuse_without_reset() {
        let mut state = state();
        for _ in 0..MAX_PENDING {
            state.admit(producer(), 2, 100).unwrap();
        }
        let before = state.clone();
        assert_eq!(state.admit(producer(), 2, 100), Err(Error::Capacity));
        assert_eq!(state, before);
        state.next_id += 1;
        assert_eq!(state.validate(), Err(Error::Invalid));
    }

    #[test]
    fn acknowledged_admission_survives_reopen_and_is_counted_once_after_death() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, Source::Galileo, 1, "a".repeat(32)).unwrap();
        let id = store
            .transition(|state| state.admit(producer(), 2, 100))
            .unwrap();
        let admitted = store.state().unwrap().clone();
        assert!(Store::open(&directory.0, Source::Galileo, 3, "b".repeat(32)).is_err());
        drop(store);
        let mut store = Store::open(&directory.0, Source::Galileo, 3, "b".repeat(32)).unwrap();
        assert_eq!(store.state().unwrap(), &admitted);
        assert_eq!(
            store.transition(|state| state.reconcile(3, &[producer()])),
            Ok(1)
        );
        assert_eq!(store.state().unwrap().totals.requests, 1);
        assert_eq!(store.state().unwrap().totals.failures, 1);
        assert_eq!(store.state().unwrap().totals.duration_count, 0);
        assert_eq!(
            store.transition(|state| state.finish(id, &producer(), 4, Outcome::Success, 1)),
            Err(Error::Unknown)
        );
        drop(store);
        let store = Store::open(&directory.0, Source::Galileo, 4, "c".repeat(32)).unwrap();
        assert_eq!(store.state().unwrap().started_at_ns, 1);
        assert_eq!(store.state().unwrap().incarnation, "a".repeat(32));
        assert_eq!(store.state().unwrap().totals.failures, 1);
    }

    #[test]
    fn interrupted_stage_never_replaces_committed_state_and_missing_state_refuses_reset() {
        let directory = Directory::new();
        let store = Store::open(&directory.0, Source::Brady, 1, "a".repeat(32)).unwrap();
        let before = store.state().unwrap().clone();
        drop(store);
        let mut stage = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(directory.0.join("state.new"))
            .unwrap();
        stage.write_all(b"incomplete checkpoint").unwrap();
        stage.sync_all().unwrap();
        let store = Store::open(&directory.0, Source::Brady, 2, "b".repeat(32)).unwrap();
        assert_eq!(store.state().unwrap(), &before);
        drop(store);
        std::fs::remove_file(directory.0.join("state.json")).unwrap();
        assert!(Store::open(&directory.0, Source::Brady, 3, "c".repeat(32)).is_err());
    }

    #[test]
    fn durability_failure_forbids_fresh_state_and_later_acknowledgments() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, Source::Enrico, 1, "a".repeat(32)).unwrap();
        // Occupied staging path models an interrupted or refused storage write.
        std::fs::create_dir(directory.0.join("state.new")).unwrap();
        assert_eq!(
            store.transition(|state| state.admit(producer(), 2, 100)),
            Err(Error::Storage)
        );
        assert_eq!(store.state(), Err(Error::Poisoned));
        assert_eq!(
            store.transition(|state| state.admit(producer(), 2, 100)),
            Err(Error::Poisoned)
        );
    }

    #[test]
    fn corrupt_foreign_source_and_symlink_state_are_never_reset() {
        let directory = Directory::new();
        drop(Store::open(&directory.0, Source::AudiDns, 1, "a".repeat(32)).unwrap());
        assert!(Store::open(&directory.0, Source::AudiPrivate, 2, "b".repeat(32)).is_err());
        std::fs::write(directory.0.join("state.json"), b"{}").unwrap();
        assert!(Store::open(&directory.0, Source::AudiDns, 2, "b".repeat(32)).is_err());
        std::fs::remove_file(directory.0.join("state.json")).unwrap();
        std::os::unix::fs::symlink("initialized", directory.0.join("state.json")).unwrap();
        assert!(Store::open(&directory.0, Source::AudiDns, 2, "b".repeat(32)).is_err());
    }

    #[test]
    fn writer_refuses_lifetime_reset_and_admission_rebinding() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, Source::Porsche, 1, "a".repeat(32)).unwrap();
        let id = store
            .transition(|state| state.admit(producer(), 2, 100))
            .unwrap();
        let before = store.state().unwrap().clone();
        assert_eq!(
            store.transition(|state| {
                state.incarnation = "b".repeat(32);
                Ok(())
            }),
            Err(Error::Invalid)
        );
        assert_eq!(
            store.transition(|state| {
                state.pending.get_mut(&id).unwrap().producer.start_ticks = 2;
                Ok(())
            }),
            Err(Error::Invalid)
        );
        assert_eq!(store.state().unwrap(), &before);
    }

    #[test]
    fn earlier_checkpoint_versions_are_refused_without_replacing_history() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, Source::Porsche, 1, "a".repeat(32)).unwrap();
        store
            .transition(|state| state.admit(producer(), 2, 100))
            .unwrap();
        let current = serde_json::to_string(store.state().unwrap()).unwrap();
        drop(store);
        for version in [1, 2, 4] {
            let wire = current.replace("\"version\":3", &format!("\"version\":{version}"));
            std::fs::write(directory.0.join("state.json"), &wire).unwrap();
            assert!(matches!(
                Store::open(&directory.0, Source::Porsche, 4, "b".repeat(32)),
                Err(Error::Version)
            ));
            assert_eq!(
                std::fs::read_to_string(directory.0.join("state.json")).unwrap(),
                wire
            );
        }
    }

    #[test]
    fn missing_current_gap_metadata_refuses_without_replacing_history() {
        let directory = Directory::new();
        let mut store = Store::open(&directory.0, Source::Brady, 1, "a".repeat(32)).unwrap();
        store
            .transition(|state| state.admit(producer(), 2, 100))
            .unwrap();
        let current = serde_json::to_string(store.state().unwrap()).unwrap();
        drop(store);
        for wire in [
            current.replace(",\"crossed_gap\":false", ""),
            current.replace(",\"coverage_started_at_ns\":1", ""),
        ] {
            assert_ne!(wire, current);
            std::fs::write(directory.0.join("state.json"), &wire).unwrap();
            assert!(matches!(
                Store::open(&directory.0, Source::Brady, 4, "b".repeat(32)),
                Err(Error::Invalid)
            ));
            assert_eq!(
                std::fs::read_to_string(directory.0.join("state.json")).unwrap(),
                wire
            );
        }
    }
}
