//! Leases: `flock`s on Lilly's lock inodes, granted in FIFO order.
//!
//! hostd holds every lease's descriptor itself. Waiters queue per lock inode
//! inside hostd instead of polling from Lilly; a lease held by some other
//! process is retried every few milliseconds without spawning anything.

use crate::protocol::{Mode, Refusal};
use rustix::fs::{flock, fstat, openat2, FlockOperation, Mode as FileMode, OFlags, ResolveFlags};
use rustix::io::Errno;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, VecDeque};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// How often a waiter blocked only by another process retries its `flock`.
const EXTERNAL_RETRY: Duration = Duration::from_millis(10);

/// A lock inode's identity.
type Key = (u64, u64);

/// One granted lease.
#[derive(Debug)]
pub struct Lease {
    pub id: u64,
    pub session: u64,
    pub mode: Mode,
    pub descriptor: Arc<OwnedFd>,
    key: Key,
    /// The lock directory, as validated at acquisition.
    directory: PathBuf,
}

#[derive(Default)]
struct Inode {
    exclusive: bool,
    shared: usize,
    queue: VecDeque<(u64, Mode)>,
}

#[derive(Default)]
struct State {
    next_lease: u64,
    next_ticket: u64,
    inodes: HashMap<Key, Inode>,
    held: HashMap<u64, Lease>,
}

/// One permitted root for lock directories. It is opened at each
/// acquisition, so a root mounted or created after startup (a pool, the
/// transfer state directory) is usable as soon as it exists.
struct Root {
    path: PathBuf,
}

/// The host-wide lease table.
pub struct Leases {
    roots: Vec<Root>,
    state: Mutex<State>,
    changed: Condvar,
    /// The admitted service uid when it is not hostd's own: lock inodes are
    /// handed to it so Lilly's own helpers can flock them too.
    owner: Option<u32>,
}

impl std::fmt::Debug for Leases {
    /// The lease table's state stays opaque; only the root count is shown.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Leases")
            .field("roots", &self.roots.len())
            .finish_non_exhaustive()
    }
}

impl Leases {
    /// Record the permitted roots. Each must be absolute; it need not exist yet.
    pub fn new(roots: &[PathBuf]) -> std::io::Result<Leases> {
        if roots.iter().any(|root| !root.is_absolute()) {
            return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput));
        }
        Ok(Leases {
            roots: roots
                .iter()
                .map(|path| Root { path: path.clone() })
                .collect(),
            state: Mutex::new(State {
                next_lease: 1,
                next_ticket: 1,
                ..State::default()
            }),
            changed: Condvar::new(),
            owner: None,
        })
    }

    /// Hand lock inodes to `uid` when it differs from hostd's own uid.
    #[must_use]
    pub fn with_owner(mut self, uid: u32) -> Leases {
        self.owner = (uid != rustix::process::geteuid().as_raw()).then_some(uid);
        self
    }

    /// @cc [owner:ghuntley,label:security] hostd-lock-inode-beneath-root
    /// `open_lock` MUST resolve `<directory>/owner.lock` beneath one configured
    /// root with `RESOLVE_BENEATH` and `RESOLVE_NO_SYMLINKS`, creating it 0600 if
    /// absent, and MUST refuse a non-regular, multiply linked, wrong-owner or
    /// group/world-writable inode; the right owner is hostd's uid or, when a
    /// distinct service uid is admitted, that uid, to which hostd hands any
    /// inode it still owns. It never unlinks a lock inode.
    fn open_lock(&self, directory: &Path) -> Result<OwnedFd, Refusal> {
        self.open_private(directory, "owner.lock", 0o600)
    }

    /// Open (creating with `mode`) `<directory>/<name>` beneath its root and
    /// apply `open_lock`'s inode checks and ownership hand-over.
    fn open_private(&self, directory: &Path, name: &str, mode: u32) -> Result<OwnedFd, Refusal> {
        let root = self
            .roots
            .iter()
            .filter(|root| directory.starts_with(&root.path))
            .max_by_key(|root| root.path.as_os_str().len())
            .ok_or(Refusal::Unavailable)?;
        let relative = directory
            .strip_prefix(&root.path)
            .map_err(|_| Refusal::Unavailable)?
            .join(name);
        let base = rustix::fs::open(
            &root.path,
            OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC,
            FileMode::empty(),
        )
        .map_err(|_| Refusal::Unavailable)?;
        let descriptor = openat2(
            &base,
            &relative,
            OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            FileMode::from_raw_mode(mode),
            ResolveFlags::BENEATH | ResolveFlags::NO_SYMLINKS | ResolveFlags::NO_MAGICLINKS,
        )
        .map_err(|_| Refusal::Unavailable)?;
        let stat = fstat(&descriptor).map_err(|_| Refusal::Unavailable)?;
        let own = rustix::process::geteuid().as_raw();
        if stat.st_mode & libc::S_IFMT != libc::S_IFREG
            || stat.st_nlink != 1
            || (stat.st_uid != own && Some(stat.st_uid) != self.owner)
            || stat.st_mode & 0o022 != 0
        {
            return Err(Refusal::Unavailable);
        }
        if let (Some(owner), true) = (self.owner, stat.st_uid == own) {
            rustix::fs::fchown(
                &descriptor,
                Some(rustix::process::Uid::from_raw(owner)),
                Some(rustix::process::Gid::from_raw(owner)),
            )
            .map_err(|_| Refusal::Unavailable)?;
        }
        Ok(descriptor)
    }

    /// @cc [owner:ghuntley,label:concurrency;recovery] lease-queue-fifo-per-inode
    /// acquire MUST grant leases on one lock inode in arrival order: an
    /// exclusive waiter is granted only at the head of its inode's queue, and
    /// a shared waiter only when every earlier waiter is shared. A grant
    /// requires both compatibility with leases hostd already holds and a
    /// successful nonblocking `flock` (other processes still contend on the
    /// same inode). A zero wait is one attempt. The waiter leaves the queue
    /// when its wait ends, when `cancelled` is set or on refusal, and never
    /// holds a lease it did not report as granted.
    pub fn acquire(
        &self,
        session: u64,
        mode: Mode,
        directory: &Path,
        wait: Duration,
        cancelled: &AtomicBool,
    ) -> Result<(u64, Arc<OwnedFd>), Refusal> {
        let descriptor = self.open_lock(directory)?;
        let stat = fstat(&descriptor).map_err(|_| Refusal::Unavailable)?;
        let key: Key = (stat.st_dev, stat.st_ino);
        let deadline = Instant::now() + wait;
        let mut state = self.state.lock().map_err(|_| Refusal::Unavailable)?;
        let ticket = state.next_ticket;
        state.next_ticket += 1;
        state
            .inodes
            .entry(key)
            .or_default()
            .queue
            .push_back((ticket, mode));
        loop {
            // Our queued ticket keeps the inode entry alive (`leave` and
            // `release` remove it only once its queue is empty).
            let Some(inode) = state.inodes.get(&key) else {
                return Err(Refusal::Unavailable);
            };
            let mut pause = deadline.saturating_duration_since(Instant::now());
            if eligible(inode, ticket, mode) {
                let operation = match mode {
                    Mode::Exclusive => FlockOperation::NonBlockingLockExclusive,
                    Mode::Shared => FlockOperation::NonBlockingLockShared,
                };
                match flock(&descriptor, operation) {
                    Ok(()) => {
                        let id = state.next_lease;
                        state.next_lease += 1;
                        let Some(inode) = state.inodes.get_mut(&key) else {
                            return Err(Refusal::Unavailable);
                        };
                        inode.queue.retain(|(queued, _)| *queued != ticket);
                        match mode {
                            Mode::Exclusive => inode.exclusive = true,
                            Mode::Shared => inode.shared += 1,
                        }
                        let descriptor = Arc::new(descriptor);
                        state.held.insert(
                            id,
                            Lease {
                                id,
                                session,
                                mode,
                                descriptor: Arc::clone(&descriptor),
                                key,
                                directory: directory.to_path_buf(),
                            },
                        );
                        self.changed.notify_all();
                        return Ok((id, descriptor));
                    }
                    Err(Errno::AGAIN) => pause = pause.min(EXTERNAL_RETRY),
                    Err(_) => {
                        leave(&mut state, key, ticket);
                        self.changed.notify_all();
                        return Err(Refusal::Unavailable);
                    }
                }
            }
            if cancelled.load(Ordering::SeqCst) || Instant::now() >= deadline {
                leave(&mut state, key, ticket);
                self.changed.notify_all();
                return Err(Refusal::Contended);
            }
            // Bound every sleep so a closing session is noticed promptly.
            let pause = pause.min(Duration::from_millis(50));
            state = self
                .changed
                .wait_timeout(state, pause)
                .map_err(|_| Refusal::Unavailable)?
                .0;
        }
    }

    /// The session that holds a lease, if it is held.
    pub fn holder(&self, lease: u64) -> Option<u64> {
        let state = self.state.lock().ok()?;
        state.held.get(&lease).map(|held| held.session)
    }

    /// The descriptor of a held lease, for inheritance by a utility.
    pub fn descriptor(&self, session: u64, lease: u64) -> Option<Arc<OwnedFd>> {
        let state = self.state.lock().ok()?;
        state
            .held
            .get(&lease)
            .filter(|held| held.session == session)
            .map(|held| Arc::clone(&held.descriptor))
    }

    /// @cc [owner:ghuntley,label:security] lease-progress-file-beneath-root
    /// progress MUST open only `<lease directory>/progress` of a lease this
    /// session holds, resolved like the lock inode (beneath its root, no
    /// symbolic links, regular, singly linked, not group/world-writable,
    /// handed to the service uid), creating it 0644; anything else is
    /// Unavailable or `UnknownLease`.
    pub fn progress(&self, session: u64, lease: u64) -> Result<OwnedFd, Refusal> {
        let directory = {
            let state = self.state.lock().map_err(|_| Refusal::Unavailable)?;
            state
                .held
                .get(&lease)
                .filter(|held| held.session == session)
                .map(|held| held.directory.clone())
                .ok_or(Refusal::UnknownLease)?
        };
        self.open_private(&directory, "progress", 0o644)
    }

    /// @cc [owner:ghuntley,label:recovery] lease-release-closes-descriptor
    /// release MUST drop hostd's descriptor (never `LOCK_UN`, which would
    /// also unlock copies inherited by still-running utilities) and wake every
    /// waiter. Callers MUST first kill and reap the lease's commands.
    pub fn release(&self, session: u64, lease: u64) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        let held = match state.held.entry(lease) {
            Entry::Occupied(held) if held.get().session == session => held.remove(),
            _ => return false,
        };
        if let Some(inode) = state.inodes.get_mut(&held.key) {
            match held.mode {
                Mode::Exclusive => inode.exclusive = false,
                Mode::Shared => inode.shared = inode.shared.saturating_sub(1),
            }
            if !inode.exclusive && inode.shared == 0 && inode.queue.is_empty() {
                state.inodes.remove(&held.key);
            }
        }
        drop(held);
        self.changed.notify_all();
        true
    }

    /// Every lease a session holds.
    pub fn held_by(&self, session: u64) -> Vec<u64> {
        self.state
            .lock()
            .map(|state| {
                state
                    .held
                    .values()
                    .filter(|held| held.session == session)
                    .map(|held| held.id)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// How many acquisitions are queued on all lock inodes (tests use it to
    /// establish arrival order without timing assumptions).
    pub fn waiting(&self) -> usize {
        self.state.lock().map_or(0, |state| {
            state.inodes.values().map(|inode| inode.queue.len()).sum()
        })
    }

    /// Wake every waiter (a session closed).
    pub fn wake(&self) {
        self.changed.notify_all();
    }
}

fn eligible(inode: &Inode, ticket: u64, mode: Mode) -> bool {
    let ahead = inode
        .queue
        .iter()
        .take_while(|(queued, _)| *queued != ticket);
    match mode {
        Mode::Exclusive => {
            inode.queue.front().map(|(queued, _)| *queued) == Some(ticket)
                && !inode.exclusive
                && inode.shared == 0
        }
        Mode::Shared => {
            !inode.exclusive && ahead.into_iter().all(|(_, queued)| *queued == Mode::Shared)
        }
    }
}

fn leave(state: &mut State, key: Key, ticket: u64) {
    if let Some(inode) = state.inodes.get_mut(&key) {
        inode.queue.retain(|(queued, _)| *queued != ticket);
        if !inode.exclusive && inode.shared == 0 && inode.queue.is_empty() {
            state.inodes.remove(&key);
        }
    }
}
