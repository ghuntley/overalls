//! Session engine: PTY sessions, viewers, pumps and control operations.
use crate::frame::{self, Reader};
use crate::log;
use crate::pty;
use crate::ring::Ring;
use std::collections::{HashMap, VecDeque};
use crate::conn::{self, Conn};
use std::sync::atomic::{AtomicUsize, Ordering};
#[cfg(feature = "antithesis-observer")]
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Condvar, Mutex};

pub const PORT_DEFAULT: u32 = 1075;

#[derive(Clone)]
pub struct Config {
  pub account_helper: Option<std::path::PathBuf>,
  pub port: u32,
  pub sessions_max: usize,
  pub ring_default: usize,
  pub ring_max: usize,
  pub ring_total_max: usize,
  pub viewer_hwm: usize,
  pub idle_ttl_ms: u64,
}

impl Default for Config {
  fn default() -> Self {
    Config {
      account_helper: None,
      port: PORT_DEFAULT,
      sessions_max: 64,
      ring_default: 1 << 20,
      ring_max: 8 << 20,
      ring_total_max: 64 << 20,
      viewer_hwm: 1 << 20,
      idle_ttl_ms: 24 * 60 * 60 * 1000,
    }
  }
}

struct Queue {
  chunks: VecDeque<Vec<u8>>,
  bytes: usize,
  closed: bool,
  aborted: bool,
  #[cfg(feature = "antithesis-observer")]
  blocked_write: bool,
  _permit: ViewerPermit,
}

struct ViewerPermit(Arc<AtomicUsize>);

impl Drop for ViewerPermit {
  fn drop(&mut self) {
    self.0.fetch_sub(1, Ordering::SeqCst);
  }
}

type SharedQueue = Arc<(Mutex<Queue>, Condvar)>;

struct Viewer {
  fd: Conn,
  queue: SharedQueue,
}

struct SessionInner {
  user: String,
  token: [u8; 16],
  ring: Ring,
  cols: u16,
  rows: u16,
  created_ms: u64,
  last_ms: u64,
  alive: bool,
  slave_opened: bool,
  viewers: Vec<Viewer>,
}

pub struct Session {
  pub id: u64,
  master: pty::Master,
  pid: i32,
  inner: Mutex<SessionInner>,
  #[cfg(feature = "antithesis-observer")]
  input_write_since_ms: AtomicU64,
}

pub type SessionEntry = (u64, String, u16, u16, usize, bool, u64, u64);

pub struct AttachRequest {
  pub id: u64,
  pub token: Vec<u8>,
  pub mode: u8,
  pub cursor: u64,
  pub cols: u16,
  pub rows: u16,
}

struct Drain {
  counter: Mutex<u64>,
  cond: Condvar,
}

pub struct Daemon {
  cfg: Config,
  key: [u8; 32],
  placement: String,
  epoch: String,
  sessions: Mutex<HashMap<u64, Arc<Session>>>,
  ring_total: AtomicUsize,
  viewers: Arc<AtomicUsize>,
  drain: Arc<Drain>,
  creations: Mutex<HashMap<[u8; 16], Creation>>,
  #[cfg(feature = "antithesis-observer")]
  births: AtomicU64,
  #[cfg(feature = "antithesis-observer")]
  deaths: AtomicU64,
}

struct Creation {
  session_id: Option<u64>,
  token: [u8; 16],
  user: String,
  term: String,
  cols: u16,
  rows: u16,
  cancelled: bool,
  recorded: std::time::Instant,
}

impl Daemon {
  pub fn new(cfg: Config, key: [u8; 32], placement: String, epoch: String) -> Arc<Daemon> {
    Arc::new(Daemon {
      cfg,
      key,
      placement,
      epoch,
      sessions: Mutex::new(HashMap::new()),
      ring_total: AtomicUsize::new(0),
      viewers: Arc::new(AtomicUsize::new(0)),
      drain: Arc::new(Drain { counter: Mutex::new(0), cond: Condvar::new() }),
      creations: Mutex::new(HashMap::new()),
      #[cfg(feature = "antithesis-observer")]
      births: AtomicU64::new(0),
      #[cfg(feature = "antithesis-observer")]
      deaths: AtomicU64::new(0),
    })
  }

  pub fn port(&self) -> u32 {
    self.cfg.port
  }

  /// @cc [owner:ghuntley,label:verification;security] antithesis-physical-snapshot
  /// The harness-only snapshot MUST report live PTY process and actual ring and
  /// viewer allocation facts without copying terminal bytes, tokens or commands.
  /// The result MUST fit one bounded control frame.
  #[cfg(feature = "antithesis-observer")]
  pub fn antithesis_snapshot(&self) -> Option<Vec<u8>> {
    let ledger = crate::observer::read_ledger()?;
    let guard = self.sessions.try_lock().ok()?;
    if guard.len() > 64 { return None; }
    let mut sessions: Vec<Arc<Session>> = guard.values().cloned().collect();
    drop(guard);
    sessions.sort_unstable_by_key(|session| session.id);
    let mut payload = Vec::with_capacity(128 + sessions.len() * 100);
    payload.push(1);
    payload.push(u8::try_from(sessions.len()).ok()?);
    payload.extend_from_slice(&self.births.load(Ordering::SeqCst).to_be_bytes());
    payload.extend_from_slice(&self.deaths.load(Ordering::SeqCst).to_be_bytes());
    payload.extend_from_slice(&u32::try_from(self.ring_total.load(Ordering::SeqCst)).ok()?.to_be_bytes());
    payload.extend_from_slice(&u16::try_from(self.viewers.load(Ordering::SeqCst)).ok()?.to_be_bytes());
    let daemon_pid = std::process::id();
    payload.extend_from_slice(&daemon_pid.to_be_bytes());
    payload.extend_from_slice(&proc_start_ticks(i32::try_from(daemon_pid).ok()?).to_be_bytes());
    payload.push(u8::try_from(ledger.len()).ok()?);
    for digest in ledger { payload.extend_from_slice(&digest); }
    for session in sessions {
      let inner = session.inner.try_lock().ok()?;
      if inner.viewers.len() > 8 { return None; }
      payload.extend_from_slice(&session.id.to_be_bytes());
      payload.extend_from_slice(&u32::try_from(session.pid).ok()?.to_be_bytes());
      payload.extend_from_slice(&proc_start_ticks(session.pid).to_be_bytes());
      payload.push(u8::from(inner.alive));
      payload.extend_from_slice(&inner.ring.base().to_be_bytes());
      payload.extend_from_slice(&inner.ring.tail().to_be_bytes());
      payload.extend_from_slice(&u32::try_from(inner.ring.capacity()).ok()?.to_be_bytes());
      payload.extend_from_slice(&u32::try_from(inner.ring.allocated_capacity()).ok()?.to_be_bytes());
      payload.push(u8::try_from(inner.viewers.len()).ok()?);
      for viewer in &inner.viewers {
        let queue = viewer.queue.0.try_lock().ok()?;
        payload.extend_from_slice(&u32::try_from(queue.bytes).ok()?.to_be_bytes());
        payload.push(u8::from(queue.blocked_write));
      }
    }
    (payload.len() <= frame::MAX_PAYLOAD).then_some(payload)
  }

  /// @cc [owner:ghuntley,label:verification] input-stall-witness-no-inner-lock
  /// The harness-only input witness MUST read the master-write interval
  /// without waiting for the session mutex held by that write.
  #[cfg(feature = "antithesis-observer")]
  pub fn antithesis_input_stall(&self, id: u64) -> Option<[u8; 13]> {
    let session = self.sessions.try_lock().ok()?.get(&id)?.clone();
    let since = session.input_write_since_ms.load(Ordering::SeqCst);
    let elapsed = if since == 0 { 0 } else { monotonic_ms().saturating_sub(since) };
    let mut payload = [0u8; 13];
    payload[0] = u8::from(since != 0);
    payload[1..9].copy_from_slice(&elapsed.to_be_bytes());
    payload[9..13].copy_from_slice(&u32::try_from(session.pid).ok()?.to_be_bytes());
    Some(payload)
  }

  /// @cc [owner:ghuntley,label:recovery] create-retry-identity
  /// Repeated creates with the same request ID and parameters MUST return the
  /// same live PTY. Cancelled or exited requests MUST NOT create another PTY.
  /// Receipts are bounded and retained for at least 24 hours or the PTY lifetime.
  pub fn create_once(self: &Arc<Self>, request: [u8; 16], user: &str, term: &str, cols: u16, rows: u16)
      -> Result<(u64, [u8; 16]), u8> {
    let mut creations = self.creations.lock().unwrap();
    self.prune_creations(&mut creations);
    if let Some(previous) = creations.get(&request) {
      if previous.cancelled { return Err(frame::ERR_DEAD); }
      if previous.user != user || previous.term != term || previous.cols != cols || previous.rows != rows {
        return Err(frame::ERR_BAD_REQUEST);
      }
      let id = previous.session_id.ok_or(frame::ERR_NOT_FOUND)?;
      self.live_session(id)?;
      return Ok((id, previous.token));
    }
    if creations.len() >= 4096 { return Err(frame::ERR_LIMIT); }
    let (id, token) = self.create(user, term, cols, rows)?;
    creations.insert(request, Creation { session_id: Some(id), token, user: user.to_owned(),
      term: term.to_owned(), cols, rows, cancelled: false, recorded: std::time::Instant::now() });
    Ok((id, token))
  }

  pub fn creation_status(&self, request: &[u8; 16]) -> Option<(u64, bool)> {
    let creations = self.creations.lock().unwrap();
    let previous = creations.get(request)?;
    let id = previous.session_id?;
    Some((id, !previous.cancelled && self.live_session(id).is_ok()))
  }

  pub fn cancel_creation(&self, request: [u8; 16]) -> Result<(), u8> {
    let mut creations = self.creations.lock().unwrap();
    self.prune_creations(&mut creations);
    if let Some(previous) = creations.get_mut(&request) {
      previous.cancelled = true;
      previous.recorded = std::time::Instant::now();
      if let Some(id) = previous.session_id { let _ = self.kill(id); }
      return Ok(());
    }
    if creations.len() >= 4096 { return Err(frame::ERR_LIMIT); }
    creations.insert(request, Creation { session_id: None, token: [0; 16], user: String::new(),
      term: String::new(), cols: 0, rows: 0, cancelled: true, recorded: std::time::Instant::now() });
    Ok(())
  }

  fn prune_creations(&self, creations: &mut HashMap<[u8; 16], Creation>) {
    creations.retain(|_, receipt| receipt.recorded.elapsed().as_secs() < 86400 ||
      receipt.session_id.is_some_and(|id| self.live_session(id).is_ok()));
  }

  /// @cc [owner:ghuntley,label:security] hello-proof-binding
  /// `verify_hello` MUST accept only the exact tag for this nonce, placement
  /// and epoch under this boot's key, in constant time, and `hello_tag` exists
  /// solely so tests can mint valid proofs.
  pub fn verify_hello(&self, nonce: &[u8], tag: &[u8]) -> bool {
    if nonce.len() != 16 || tag.len() != 32 {
      return false;
    }
    crate::crypto::constant_time_equal(&self.hello_tag(nonce), tag)
  }

  pub fn hello_tag(&self, nonce: &[u8]) -> [u8; 32] {
    crate::crypto::tag(
      &self.key,
      &[
        b"terminald-hello-v1",
        nonce,
        self.placement.as_bytes(),
        self.epoch.as_bytes(),
      ],
    )
  }

  /**
   * @cc [owner:ghuntley,label:capacity] create-shared-ring-reservation
   * For a positive configured initial ring capacity, creation MUST atomically
   * reserve that capacity within the aggregate ring budget before PTY spawn.
   * Budget refusal MUST preserve the live session inventory and reservations;
   * failed PTY spawn MUST return its reservation.
   */
  /// @cc [owner:ghuntley,label:recovery] create-registers-then-replies
  /// `create` MUST register a live session with a fresh 128-bit random token
  /// and a running pump before replying; any failure MUST leave no registered
  /// session behind.
  pub fn create(self: &Arc<Self>, user: &str, term: &str, cols: u16, rows: u16) -> Result<(u64, [u8; 16]), u8> {
    if cols == 0 || rows == 0 || term.is_empty() || term.len() > 32 || user.is_empty() || user.len() > 64 {
      return Err(frame::ERR_BAD_REQUEST);
    }
    // Explicit privileged host operations retain their root PTY. Browser
    // authority always supplies its durable personal identity, never root.
    if let Some(helper) = self.cfg.account_helper.as_ref().filter(|_| user != "root") {
      ensure_account(helper, user).map_err(|_| frame::ERR_BAD_REQUEST)?;
    }
    let info = pty::resolve(user).ok_or(frame::ERR_BAD_REQUEST)?;
    if info.name.is_empty() || info.name.len() > 64 {
      return Err(frame::ERR_BAD_REQUEST);
    }
    let mut guard = self.sessions.lock().unwrap();
    if guard.len() >= self.cfg.sessions_max {
      return Err(frame::ERR_LIMIT);
    }
    let token = random_token().map_err(|_| frame::ERR_LIMIT)?;
    // A daemon restart during the same guest boot must not restart the ID
    // sequence. IDs use independent entropy; exposing an ID reveals no token bits.
    let identity = random_token().map_err(|_| frame::ERR_LIMIT)?;
    let id = u64::from_be_bytes(identity[..8].try_into().unwrap()) & ((1u64 << 63) - 1);
    if id == 0 || guard.contains_key(&id) {
      return Err(frame::ERR_LIMIT);
    }
    if !reserve(&self.ring_total, self.cfg.ring_default, self.cfg.ring_total_max) {
      return Err(frame::ERR_LIMIT);
    }
    let spawned = match pty::spawn(&info, term, cols, rows) {
      Ok(spawned) => spawned,
      Err(_) => {
        self.ring_total.fetch_sub(self.cfg.ring_default, Ordering::SeqCst);
        return Err(frame::ERR_LIMIT);
      }
    };
    let now = log::now_ms();
    let session = Arc::new(Session {
      id,
      master: spawned.master,
      pid: spawned.pid,
      #[cfg(feature = "antithesis-observer")]
      input_write_since_ms: AtomicU64::new(0),
      inner: Mutex::new(SessionInner {
        user: info.name.clone(),
        token,
        ring: Ring::new(self.cfg.ring_default),
        cols,
        rows,
        created_ms: now,
        last_ms: now,
        alive: true,
        slave_opened: false,
        viewers: Vec::new(),
      }),
    });
    guard.insert(id, session.clone());
    #[cfg(feature = "antithesis-observer")]
    self.births.fetch_add(1, Ordering::SeqCst);
    drop(guard);
    log::event(log::Event::SessionCreated {
      context: self.log_context(),
      session_id: id,
      cols,
      rows,
    });
    self.start_pump(session)?;
    Ok((id, token))
  }

  pub fn list(&self) -> Vec<SessionEntry> {
    let guard = self.sessions.lock().unwrap();
    let mut entries: Vec<_> = guard
      .values()
      .map(|session| {
        let inner = session.inner.lock().unwrap();
        (
          session.id,
          inner.user.clone(),
          inner.cols,
          inner.rows,
          inner.viewers.len(),
          inner.alive,
          inner.created_ms,
          inner.last_ms,
        )
      })
      .collect();
    entries.sort_unstable_by_key(|entry| entry.0);
    entries
  }

  /// @cc [owner:ghuntley,label:security] token-recovery-requires-control-authentication
  /// Token recovery MUST be reachable only through the boot-authenticated control
  /// connection, return authority for live sessions only, and never log the token.
  pub fn recover_token(&self, id: u64) -> Result<[u8; 16], u8> {
    let session = self.live_session(id)?;
    let inner = session.inner.lock().unwrap();
    if !inner.alive { return Err(frame::ERR_NOT_FOUND); }
    Ok(inner.token)
  }

  /// @cc [owner:ghuntley,label:recovery;security] explicit-kill-retires-credit-stalls
  /// Explicit kill MUST revoke viewer writers and release a stalled PTY pump
  /// without awaiting peer read credit. Signals MUST be sent while holding the
  /// session lifetime lock, before retirement can reap and release its PID.
  /// Natural child EOF retains the separate queued-output drain guarantee.
  pub fn kill(&self, id: u64) -> Result<(), u8> {
    let session = self.live_session(id)?;
    {
      let mut inner = session.inner.lock().unwrap();
      if !inner.alive { return Err(frame::ERR_NOT_FOUND); }
      inner.alive = false;
      for viewer in &inner.viewers {
        let (mutex, cond) = &*viewer.queue;
        let mut queue = mutex.lock().unwrap();
        queue.aborted = true;
        queue.closed = true;
        cond.notify_all();
        conn::shutdown(viewer.fd);
      }
      pty::kill(&session.master, session.pid);
    }
    self.drain.cond.notify_all();
    log::event(log::Event::SessionKilled { context: self.log_context(), session_id: id });
    Ok(())
  }

  pub fn resize(&self, id: u64, cols: u16, rows: u16) -> Result<(), u8> {
    if cols == 0 || rows == 0 {
      return Err(frame::ERR_BAD_REQUEST);
    }
    let session = self.live_session(id)?;
    pty::set_winsize(&session.master, cols, rows).map_err(|_| frame::ERR_DEAD)?;
    {
      let mut inner = session.inner.lock().unwrap();
      inner.cols = cols;
      inner.rows = rows;
    }
    log::event(log::Event::SessionResized {
      context: self.log_context(),
      session_id: id,
      cols,
      rows,
    });
    Ok(())
  }

  fn live_session(&self, id: u64) -> Result<Arc<Session>, u8> {
    self
      .sessions
      .lock()
      .unwrap()
      .get(&id)
      .cloned()
      .filter(|session| session.inner.lock().unwrap().alive)
      .ok_or(frame::ERR_NOT_FOUND)
  }

  /// @cc [owner:ghuntley,label:security] attach-token-and-gap-reporting
  /// `attach` MUST verify the session token before registering the viewer,
  /// MUST replay the retained suffix and then stream live bytes with neither
  /// overlap nor loss, and MUST report the actual replay start cursor so
  /// scrollback truncation is explicit. On replay failure the connection is
  /// closed without a reply (`Attached::Closed`).
  pub fn attach(self: &Arc<Self>, request: &AttachRequest, fd: Conn) -> Attached {
    let id = request.id;
    let mode = request.mode;
    let cursor = request.cursor;
    let cols = request.cols;
    let rows = request.rows;
    let token = &request.token[..];
    if mode > 1 {
      return Attached::Failed(frame::ERR_BAD_REQUEST);
    }
    let Ok(session) = self.live_session(id) else {
      return Attached::Failed(frame::ERR_NOT_FOUND);
    };
    if !reserve(&self.viewers, 1, 128) {
      return Attached::Failed(frame::ERR_LIMIT);
    }
    let queue: SharedQueue = Arc::new((
      Mutex::new(Queue { chunks: VecDeque::new(), bytes: 0, closed: false, aborted: false,
        #[cfg(feature = "antithesis-observer")]
        blocked_write: false,
        _permit: ViewerPermit(self.viewers.clone()) }),
      Condvar::new(),
    ));
    let (replay_start, replay) = {
      let mut inner = session.inner.lock().unwrap();
      if !inner.alive {
        return Attached::Failed(frame::ERR_DEAD);
      }
      if !crate::crypto::constant_time_equal(token, &inner.token) {
        return Attached::Failed(frame::ERR_BAD_TOKEN);
      }
      if inner.viewers.len() >= 8 {
        return Attached::Failed(frame::ERR_LIMIT);
      }
      let snapshot = inner.ring.replay_from(cursor);
      inner.viewers.push(Viewer { fd, queue: queue.clone() });
      inner.last_ms = log::now_ms();
      if mode == 1 && cols != 0 && rows != 0 && (cols != inner.cols || rows != inner.rows) {
        inner.cols = cols;
        inner.rows = rows;
        drop(inner);
        let _ = pty::set_winsize(&session.master, cols, rows);
        snapshot
      } else {
        snapshot
      }
    };
    let mut ok = Vec::with_capacity(20);
    frame::put_u64(&mut ok, replay_start);
    frame::put_u32(&mut ok, replay.len() as u32);
    if write_frame(fd, frame::OP_OK, &ok).is_err() || write_all(fd, &replay).is_err() {
      self.remove_viewer(&session, fd);
      conn::shutdown(fd);
      conn::close(fd);
      return Attached::Closed;
    }
    log::event(log::Event::SessionAttached {
      context: self.log_context(),
      session_id: id,
      writable: mode == 1,
      replay_bytes: replay.len(),
      replay_from: replay_start,
    });
    // Reader and writer own distinct descriptors. Shutting down either socket
    // wakes both workers, but closing one cannot reuse the other's descriptor.
    let Ok(reader_fd) = conn::duplicate(fd) else {
      self.remove_viewer(&session, fd);
      conn::close(fd);
      return Attached::Closed;
    };
    if conn::prepare_viewer(fd).is_err() {
      self.remove_viewer(&session, fd);
      conn::close(reader_fd);
      conn::close(fd);
      return Attached::Closed;
    }
    let writer = std::thread::Builder::new().spawn({
      let queue = queue.clone();
      let drain = self.drain.clone();
      let session = session.clone();
      let placement = self.placement.clone();
      let epoch = self.epoch.clone();
      move || Self::writer_loop(fd, queue, drain, session, placement, epoch)
    });
    if writer.is_err() {
      self.remove_viewer(&session, fd);
      conn::shutdown(fd);
      conn::close(fd);
      conn::close(reader_fd);
      return Attached::Closed;
    }
    let reader = std::thread::Builder::new().spawn({
      let session = session.clone();
      let queue = queue.clone();
      move || {
        Self::reader_loop(reader_fd, mode, session);
        conn::shutdown(reader_fd);
        conn::close(reader_fd);
        let (mutex, cond) = &*queue;
        let mut guard = mutex.lock().unwrap();
        guard.closed = true;
        guard.aborted = true;
        cond.notify_all();
      }
    });
    if reader.is_err() {
      let (mutex, cond) = &*queue;
      mutex.lock().unwrap().closed = true;
      cond.notify_all();
      conn::shutdown(reader_fd);
      conn::close(reader_fd);
      return Attached::Closed;
    }
    Attached::Streams
  }

  fn remove_viewer(&self, session: &Arc<Session>, fd: Conn) {
    session.inner.lock().unwrap().viewers.retain(|viewer| viewer.fd != fd);
  }

  fn reader_loop(fd: Conn, mode: u8, session: Arc<Session>) {
    let mut scratch = vec![0u8; 16 << 10];
    loop {
      let read = match conn::read(fd, &mut scratch) {
        Ok(0) => break,
        Ok(read) => read,
        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
        Err(_) => break,
      };
      if mode == 1 {
        let mut inner = session.inner.lock().unwrap();
        if !inner.alive { break; }
        #[cfg(feature = "antithesis-observer")]
        session.input_write_since_ms.store(monotonic_ms().max(1), Ordering::SeqCst);
        let written = pty::write_input(&session.master, &scratch[..read]);
        #[cfg(feature = "antithesis-observer")]
        session.input_write_since_ms.store(0, Ordering::SeqCst);
        if written.is_err() {
          break;
        }
        inner.last_ms = log::now_ms();
      }
    }
  }

  /// @cc [owner:ghuntley,label:concurrency] viewer-queue-drain-lock-order
  /// A writer MUST release its queue mutex before acquiring the drain counter
  /// mutex. The pump holds the drain counter while inspecting queues, so the
  /// reverse order can deadlock every reader and viewer on the guest.
  fn writer_loop(
    fd: Conn,
    queue: SharedQueue,
    drain: Arc<Drain>,
    session: Arc<Session>,
    placement: String,
    epoch: String,
  ) {
    loop {
      let chunk = {
        let (mutex, cond) = &*queue;
        let mut guard = mutex.lock().unwrap();
        loop {
          if let Some(chunk) = guard.chunks.pop_front() {
            guard.bytes -= chunk.len();
            break Some(chunk);
          }
          if guard.closed {
            break None;
          }
          guard = cond.wait(guard).unwrap();
        }
      };
      let Some(chunk) = chunk else { break };
      if Self::write_viewer(fd, &chunk, &queue).is_err() {
        break;
      }
      let drained = {
        let (mutex, _) = &*queue;
        let guard = mutex.lock().unwrap();
        guard.bytes <= 256 << 10
      };
      // The pump takes the drain lock before inspecting viewer queues. Release
      // the queue lock before taking drain, including during viewer teardown.
      if drained {
        let mut counter = drain.counter.lock().unwrap();
        *counter += 1;
        drain.cond.notify_all();
      }
    }
    {
      let (mutex, cond) = &*queue;
      let mut guard = mutex.lock().unwrap();
      guard.closed = true;
      guard.chunks.clear();
      guard.bytes = 0;
      cond.notify_all();
    }
    conn::shutdown(fd);
    let was_last = {
      let mut inner = session.inner.lock().unwrap();
      inner.viewers.retain(|viewer| viewer.fd != fd);
      inner.viewers.is_empty()
    };
    if was_last {
      log::event(log::Event::SessionDetachedLast {
        context: log::Context { placement_id: &placement, execution_epoch: &epoch },
        session_id: session.id,
      });
    }
    conn::close(fd);
  }

  /// @cc [owner:ghuntley,label:recovery] guest-viewer-credit-pause-is-not-disconnection
  /// A healthy viewer withholding read credit MUST pause its writer rather than
  /// lose bytes at the socket send timeout. Peer departure MUST interrupt that
  /// wait; ordinary PTY EOF MUST still drain the queued suffix.
  fn write_viewer(fd: Conn, mut bytes: &[u8], queue: &SharedQueue) -> std::io::Result<()> {
    while !bytes.is_empty() {
      if queue.0.lock().unwrap().aborted {
        return Err(std::io::ErrorKind::BrokenPipe.into());
      }
      match conn::write(fd, bytes) {
        Ok(written) => {
          #[cfg(feature = "antithesis-observer")]
          { queue.0.lock().unwrap().blocked_write = false; }
          bytes = &bytes[written..];
        }
        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
          #[cfg(feature = "antithesis-observer")]
          { queue.0.lock().unwrap().blocked_write = true; }
          conn::wait_writable(fd, 100);
        }
        Err(error) => return Err(error),
      }
    }
    Ok(())
  }

  fn start_pump(self: &Arc<Self>, session: Arc<Session>) -> Result<(), u8> {
    let daemon = self.clone();
    let pumping = session.clone();
    let spawned = std::thread::Builder::new().spawn(move || daemon.pump_loop(pumping));
    if spawned.is_err() {
      self.session_ended(&session, true);
      return Err(frame::ERR_LIMIT);
    }
    Ok(())
  }

  /**
   * @cc [owner:ghuntley,label:recovery] pump-pressure-is-session-local
   * Waiting for one session's viewer credit MUST NOT retain the daemon's shared
   * drain mutex. Distinct live session pumps and writers MUST remain able to
   * deliver output while that viewer remains stalled.
   */
  /// @cc [owner:ghuntley,label:recovery] pump-delivery-and-backpressure
  /// The pump MUST deliver every master read to every registered viewer
  /// exactly once in order while alive, and while any current viewer queue is
  /// above the high watermark it MUST pause reading instead of dropping bytes.
  /// Explicit kill cancels this delivery obligation and MUST stop the pump
  /// independently of peer credit or descendant-held slave descriptors; on master
  /// EOF it MUST retire the session and let each writer drain queued output
  /// before closing its socket; failed socket writes may close that viewer,
  /// but credit-induced stalls MUST wait without dropping bytes. EIO before
  /// the child has ever opened the slave is a startup race, not an exit: the
  /// pump MUST keep retrying within a bounded grace window.
  fn pump_loop(self: Arc<Self>, session: Arc<Session>) {
    let mut scratch = vec![0u8; 32 << 10];
    let spawned_at = std::time::Instant::now();
    loop {
      if !session.inner.lock().unwrap().alive { break; }
      // This pump is the master's only reader. A bounded readiness wait keeps
      // explicit cancellation observable even if another process holds a quiet
      // slave; no shared nonblocking flag is imposed on the input writer.
      match pty::wait_readable(&session.master, 100) {
        pty::Ready::Data => {}
        pty::Ready::Timeout | pty::Ready::Interrupted => continue,
        pty::Ready::Failed => break,
      }
      let read = match pty::read(&session.master, &mut scratch) {
        pty::Read::Data(read) => read,
        pty::Read::Eof | pty::Read::Failed => break,
        pty::Read::Interrupted => continue,
        pty::Read::WouldBlock => {
          let _ = pty::wait_readable(&session.master, 1000);
          continue;
        }
        pty::Read::SlaveClosed => {
          let (opened, alive) = {
            let inner = session.inner.lock().unwrap();
            (inner.slave_opened, inner.alive)
          };
          if !opened && alive && spawned_at.elapsed() < std::time::Duration::from_secs(10) {
            let _ = pty::wait_readable(&session.master, 50);
            continue;
          }
          break;
        }
      };
      let bytes = scratch[..read].to_vec();
      {
        let mut inner = session.inner.lock().unwrap();
        inner.slave_opened = true;
        inner.last_ms = log::now_ms();
        self.grow_ring(&mut inner);
        inner.ring.push(&bytes);
        for viewer in &inner.viewers {
          let (mutex, cond) = &*viewer.queue;
          let mut guard = mutex.lock().unwrap();
          guard.chunks.push_back(bytes.clone());
          guard.bytes += bytes.len();
          cond.notify_all();
        }
      }
      let mut counter = self.drain.counter.lock().unwrap();
      loop {
        let over = {
          let inner = session.inner.lock().unwrap();
          inner.alive && inner
            .viewers
            .iter()
            .any(|viewer| viewer.queue.0.lock().unwrap().bytes > self.cfg.viewer_hwm)
        };
        if !over {
          break;
        }
        let (guard, _) = self
          .drain
          .cond
          .wait_timeout(counter, std::time::Duration::from_millis(100))
          .unwrap();
        counter = guard;
      }
      drop(counter);
    }
    self.session_ended(&session, false);
  }

  /// @cc [owner:ghuntley,label:capacity] growth-reserves-before-retention-limit
  /// Growth MUST reserve the exact limit increase before changing the ring;
  /// failed aggregate admission MUST preserve the current retention limit.
  fn grow_ring(&self, inner: &mut SessionInner) {
    let current = inner.ring.capacity();
    if current >= self.cfg.ring_max || inner.ring.tail() - inner.ring.base() != current as u64 {
      return;
    }
    let target = (current * 2).min(self.cfg.ring_max);
    if !reserve(&self.ring_total, target - current, self.cfg.ring_total_max) {
      return;
    }
    inner.ring.set_capacity(target);
  }

  /// @cc [owner:ghuntley,label:capacity;recovery] retired-scrollback-releases-before-quota
  /// Retirement MUST drop the scrollback backing allocation before returning
  /// its reservation, even while viewer threads retain the session. Natural
  /// EOF MUST preserve independent queued output for the viewer's final drain.
  fn session_ended(&self, session: &Arc<Session>, pump_spawn_failed: bool) {
    let capacity;
    {
      let mut inner = session.inner.lock().unwrap();
      inner.alive = false;
      capacity = inner.ring.capacity();
      inner.ring = Ring::new(0);
      for viewer in &inner.viewers {
        let (mutex, cond) = &*viewer.queue;
        let mut guard = mutex.lock().unwrap();
        guard.closed = true;
        cond.notify_all();
      }
      inner.viewers.clear();
    }
    pty::retire(&session.master, session.pid);
    self.ring_total.fetch_sub(capacity, Ordering::SeqCst);
    self.sessions.lock().unwrap().remove(&session.id);
    #[cfg(feature = "antithesis-observer")]
    self.deaths.fetch_add(1, Ordering::SeqCst);
    let event = if pump_spawn_failed {
      log::Event::PumpSpawnFailed { context: self.log_context(), session_id: session.id }
    } else {
      log::Event::SessionExited { context: self.log_context(), session_id: session.id }
    };
    log::event(event);
  }

  pub fn sweep_idle(&self) {
    let now = log::now_ms();
    let candidates: Vec<u64> = {
      let guard = self.sessions.lock().unwrap();
      guard
        .values()
        .filter(|session| {
          let inner = session.inner.lock().unwrap();
          inner.alive && inner.viewers.is_empty() && now.saturating_sub(inner.last_ms) > self.cfg.idle_ttl_ms
        })
        .map(|session| session.id)
        .collect()
    };
    for id in candidates {
      let _ = self.kill(id);
      log::event(log::Event::SessionIdleExpired { context: self.log_context(), session_id: id });
    }
  }

  fn log_context(&self) -> log::Context<'_> {
    log::Context { placement_id: &self.placement, execution_epoch: &self.epoch }
  }
}

#[derive(Debug)]
pub enum Attached {
  Streams,
  Failed(u8),
  Closed,
}

/// @cc [owner:ghuntley,label:security] terminal-account-before-passwd
/// Personal accounts in configured guests MUST successfully run the shared
/// account reconciler before resolving passwd or spawning a PTY. Failure MUST
/// NOT fall back to another user. Explicit root PTYs remain host-admin operations.
/// The helper and its children MUST be stopped on timeout; output is discarded.
#[cfg(unix)]
fn ensure_account(helper: &std::path::Path, user: &str) -> std::io::Result<()> {
  use std::os::unix::process::CommandExt;
  use std::process::{Command, Stdio};
  use std::time::{Duration, Instant};
  if !helper.is_absolute() { return Err(std::io::Error::other("invalid helper path")); }
  let mut child = Command::new(helper).args(["ensure", user])
    .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
    .process_group(0).spawn()?;
  let deadline = Instant::now() + Duration::from_secs(10);
  loop {
    match child.try_wait() {
      Ok(Some(status)) if status.success() => return Ok(()),
      Ok(Some(_)) => return Err(std::io::Error::other("account unavailable")),
      Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
      _ => {
        unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL); }
        let _ = child.wait();
        return Err(std::io::Error::other("account unavailable"));
      }
    }
  }
}

#[cfg(feature = "antithesis-observer")]
fn proc_start_ticks(pid: i32) -> u64 {
  // Field 22 follows the parenthesized comm field; an unavailable proc record
  // is unknown (zero), never evidence that the child did not start.
  std::fs::read_to_string(format!("/proc/{pid}/stat"))
    .ok()
    .and_then(|body| body.rsplit_once(") ").and_then(|(_, fields)|
      fields.split_whitespace().nth(19)?.parse().ok()))
    .unwrap_or(0)
}

#[cfg(feature = "antithesis-observer")]
fn monotonic_ms() -> u64 {
  let mut time: libc::timespec = unsafe { std::mem::zeroed() };
  if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } != 0 { return 0; }
  u64::try_from(time.tv_sec).unwrap_or(0).saturating_mul(1000)
    .saturating_add(u64::try_from(time.tv_nsec).unwrap_or(0) / 1_000_000)
}

/// Windows guests configure no account helper: the roster agent reconciles
/// accounts itself and `pty::resolve` admits only enabled local accounts.
#[cfg(windows)]
fn ensure_account(_helper: &std::path::Path, _user: &str) -> std::io::Result<()> {
  Err(std::io::Error::other("account helper unsupported"))
}

pub(crate) fn reserve(total: &AtomicUsize, amount: usize, limit: usize) -> bool {
  let mut current = total.load(Ordering::SeqCst);
  loop {
    let Some(next) = current.checked_add(amount).filter(|next| *next <= limit) else {
      return false;
    };
    match total.compare_exchange_weak(current, next, Ordering::SeqCst, Ordering::SeqCst) {
      Ok(_) => return true,
      Err(actual) => current = actual,
    }
  }
}

#[cfg(unix)]
fn random_token() -> std::io::Result<[u8; 16]> {
  let mut token = [0u8; 16];
  std::fs::File::open("/dev/urandom")
    .and_then(|mut source| std::io::Read::read_exact(&mut source, &mut token))?;
  Ok(token)
}

#[cfg(windows)]
fn random_token() -> std::io::Result<[u8; 16]> {
  use windows_sys::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
  let mut token = [0u8; 16];
  // SAFETY: `token` is writable for its full length; no algorithm handle is
  // needed with the system-preferred RNG flag.
  let status = unsafe { BCryptGenRandom(std::ptr::null_mut(), token.as_mut_ptr(), token.len() as u32,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
  if status != 0 { return Err(std::io::Error::other("system RNG unavailable")); }
  Ok(token)
}

pub fn write_frame(fd: Conn, op: u8, payload: &[u8]) -> std::io::Result<()> {
  write_all(fd, &frame::encode(op, payload))
}

/// Write every byte to a connection, retrying interrupted writes. A socket in
/// non-blocking viewer mode (Windows) waits for send space instead of failing.
pub fn write_all(fd: Conn, mut data: &[u8]) -> std::io::Result<()> {
  while !data.is_empty() {
    match conn::write(fd, data) {
      Ok(written) => data = &data[written..],
      Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
      #[cfg(windows)]
      Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => conn::wait_writable(fd, 100),
      Err(error) => return Err(error),
    }
  }
  Ok(())
}

pub fn read_frame(fd: Conn, buffer: &mut Vec<u8>) -> Option<Result<frame::Frame, ()>> {
  loop {
    if let Some(result) = frame::decode(buffer) {
      let consumed = frame::consumed(match &result {
        Ok(message) => message.payload.len(),
        Err(()) => 0,
      });
      buffer.drain(..consumed);
      return Some(result);
    }
    if buffer.len() > 4 + frame::MAX_PAYLOAD {
      buffer.clear();
      return Some(Err(()));
    }
    let mut scratch = [0u8; 4096];
    let read = match conn::read(fd, &mut scratch) {
      Ok(0) => return None,
      Ok(read) => read,
      Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
      Err(_) => return None,
    };
    buffer.extend_from_slice(&scratch[..read]);
  }
}

pub fn decode_hello(payload: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
  let mut reader = Reader::new(payload);
  let nonce = reader.bytes(16)?.to_vec();
  let tag = reader.bytes(32)?.to_vec();
  if reader.remaining() != 0 {
    return None;
  }
  Some((nonce, tag))
}

pub fn decode_create(payload: &[u8]) -> Option<(String, String, u16, u16)> {
  let mut reader = Reader::new(payload);
  let user_len = reader.u8()? as usize;
  let user = reader.string(user_len)?;
  let term_len = reader.u8()? as usize;
  let term = reader.string(term_len)?;
  let cols = reader.u16()?;
  let rows = reader.u16()?;
  if reader.remaining() != 0 {
    return None;
  }
  Some((user, term, cols, rows))
}

pub fn decode_kill(payload: &[u8]) -> Option<u64> {
  let mut reader = Reader::new(payload);
  let id = reader.u64()?;
  if reader.remaining() != 0 {
    return None;
  }
  Some(id)
}

pub fn decode_resize(payload: &[u8]) -> Option<(u64, u16, u16)> {
  let mut reader = Reader::new(payload);
  let id = reader.u64()?;
  let cols = reader.u16()?;
  let rows = reader.u16()?;
  if reader.remaining() != 0 {
    return None;
  }
  Some((id, cols, rows))
}

pub fn decode_attach(payload: &[u8]) -> Option<AttachRequest> {
  let mut reader = Reader::new(payload);
  let id = reader.u64()?;
  let token = reader.bytes(16)?.to_vec();
  let mode = reader.u8()?;
  let cursor = reader.u64()?;
  let cols = reader.u16()?;
  let rows = reader.u16()?;
  if reader.remaining() != 0 {
    return None;
  }
  Some(AttachRequest { id, token, mode, cursor, cols, rows })
}

pub fn encode_list(entries: &[SessionEntry]) -> Vec<u8> {
  let mut out = Vec::new();
  frame::put_u16(&mut out, entries.len() as u16);
  for (id, user, cols, rows, viewers, alive, created_ms, last_ms) in entries {
    frame::put_u64(&mut out, *id);
    out.push(user.len() as u8);
    frame::put_bytes(&mut out, user.as_bytes());
    frame::put_u16(&mut out, *cols);
    frame::put_u16(&mut out, *rows);
    frame::put_u16(&mut out, *viewers as u16);
    out.push(u8::from(*alive));
    frame::put_u64(&mut out, *created_ms);
    frame::put_u64(&mut out, *last_ms);
  }
  out
}

#[cfg(all(test, unix))]
#[path = "retired_ring_tests.rs"]
mod retired_ring_tests;

#[cfg(all(test, unix))]
#[path = "growth_property_tests.rs"]
mod growth_property_tests;

#[cfg(all(test, unix))]
#[path = "mixed_growth_tests.rs"]
mod mixed_growth_tests;

#[cfg(all(test, unix))]
mod tests {
  #[test]
  fn account_helper_failure_prevents_even_an_existing_passwd_user_from_opening() {
    let cfg = super::Config { account_helper: Some("/no-such-account-helper".into()), ..super::Config::default() };
    let daemon = super::Daemon::new(cfg, [3u8; 32], "p".into(), "1".into());
    assert_eq!(daemon.create("nobody", "xterm-256color", 80, 24), Err(crate::frame::ERR_BAD_REQUEST));
    assert!(daemon.list().is_empty());
    assert!(super::ensure_account(std::path::Path::new("relative-helper"), "root").is_err());
  }

  #[test]
  fn concurrent_reservations_never_exceed_budget() {
    let total = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let workers: Vec<_> = (0..32).map(|_| {
      let total = total.clone();
      std::thread::spawn(move || super::reserve(&total, 1, 8))
    }).collect();
    let accepted = workers.into_iter().filter_map(|worker| worker.join().ok()).filter(|ok| *ok).count();
    assert_eq!(accepted, 8);
    assert_eq!(total.load(std::sync::atomic::Ordering::SeqCst), 8);
  }

  use super::*;

  #[test]
  fn concurrent_create_retries_share_one_pty_and_cancellation_fences_replay() {
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let user = pty::current_user_name();
    let request = [42u8; 16];
    let workers: Vec<_> = (0..8).map(|_| {
      let daemon = daemon.clone();
      let user = user.clone();
      std::thread::spawn(move || daemon.create_once(request, &user, "xterm-256color", 80, 24))
    }).collect();
    let replies: Vec<_> = workers.into_iter().map(|worker| worker.join().unwrap().unwrap()).collect();
    let id = replies[0].0;
    let count = daemon.list().len();
    let changed = daemon.create_once(request, &user, "xterm-256color", 100, 24);
    assert_eq!(daemon.creation_status(&request), Some((id, true)));
    daemon.cancel_creation(request).unwrap();
    assert_eq!(count, 1);
    assert!(replies.iter().all(|reply| reply == &replies[0]));
    assert_eq!(changed, Err(frame::ERR_BAD_REQUEST));
    assert_eq!(daemon.creation_status(&request), Some((id, false)));
    assert!(daemon.create_once(request, &user, "xterm-256color", 80, 24).is_err());
  }

  #[test]
  fn cancellation_before_create_leaves_a_tombstone() {
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let request = [43u8; 16];
    daemon.cancel_creation(request).unwrap();
    daemon.cancel_creation(request).unwrap();
    assert!(daemon.create_once(request, &pty::current_user_name(), "xterm-256color", 80, 24).is_err());
    assert!(daemon.list().is_empty());
  }

  #[test]
  fn daemon_restart_does_not_reuse_guest_session_identity_for_the_same_boot() {
    let first = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let second = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let user = pty::current_user_name();
    let (old, _) = first.create(&user, "xterm-256color", 80, 24).unwrap();
    first.kill(old).unwrap();
    let (new, _) = second.create(&user, "xterm-256color", 80, 24).unwrap();
    second.kill(new).unwrap();
    assert_ne!(old, new);
  }

  #[test]
  fn fifty_sessions_persist_without_viewers() {
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let user = pty::current_user_name();
    let mut ids = Vec::new();
    for _ in 0..50 {
      match daemon.create(&user, "xterm-256color", 80, 24) {
        Ok((id, _token)) => ids.push(id),
        Err(reason) => {
          for id in ids { daemon.kill(id).ok(); }
          panic!("session creation failed: {reason}");
        }
      }
    }
    let listed = daemon.list();
    let count = listed.len();
    let all_detached = listed.iter().all(|entry| entry.4 == 0);
    for id in ids { daemon.kill(id).ok(); }
    assert_eq!(count, 50);
    assert!(all_detached);
  }

  #[test]
  fn natural_shell_exit_drains_final_output_before_viewer_eof() {
    use std::io::{Read, Write};
    use std::os::fd::IntoRawFd;
    use std::os::unix::net::UnixStream;

    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let (id, token) = daemon.create(&pty::current_user_name(), "xterm-256color", 80, 24).unwrap();
    let (mut viewer, server) = UnixStream::pair().unwrap();
    viewer.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    let request = AttachRequest { id, token: token.to_vec(), mode: 1, cursor: 0, cols: 0, rows: 0 };
    assert!(matches!(daemon.attach(&request, server.into_raw_fd()), Attached::Streams));
    let mut header = [0u8; 16];
    viewer.read_exact(&mut header).unwrap();
    assert_eq!(&header[..4], &[frame::MAGIC, frame::OP_OK, 0, 12]);
    let replay_len = u32::from_be_bytes(header[12..16].try_into().unwrap()) as usize;
    let mut replay = vec![0u8; replay_len];
    viewer.read_exact(&mut replay).unwrap();
    viewer.write_all(b"printf 'TERMINAL_%s\\n' FINAL_BYTES; exit\n").unwrap();
    let mut output = Vec::new();
    viewer.read_to_end(&mut output).unwrap();
    assert!(output.windows(b"TERMINAL_FINAL_BYTES".len()).any(|part| part == b"TERMINAL_FINAL_BYTES"));
  }

  #[test]
  fn hello_binding_covers_placement_and_epoch() {
    let daemon = Daemon::new(Config::default(), [7u8; 32], "placement-a".to_string(), "3".to_string());
    let nonce = [9u8; 16];
    let tag = daemon.hello_tag(&nonce);
    assert!(daemon.verify_hello(&nonce, &tag));
    let mut wrong = tag;
    wrong[0] ^= 1;
    assert!(!daemon.verify_hello(&nonce, &wrong));
    assert!(!daemon.verify_hello(&[0u8; 16], &tag));
    let other = Daemon::new(Config::default(), [7u8; 32], "placement-b".to_string(), "3".to_string());
    assert!(!other.verify_hello(&nonce, &tag));
    let older = Daemon::new(Config::default(), [7u8; 32], "placement-a".to_string(), "2".to_string());
    assert!(!older.verify_hello(&nonce, &tag));
  }

  #[test]
  fn create_rejects_unresolved_users_and_geometry() {
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    assert_eq!(daemon.create("no-such-user-xyz", "xterm-256color", 80, 24), Err(frame::ERR_BAD_REQUEST));
    let user = pty::current_user_name();
    assert_eq!(daemon.create(&user, "xterm-256color", 0, 24), Err(frame::ERR_BAD_REQUEST));
    assert_eq!(daemon.create(&user, "", 80, 24), Err(frame::ERR_BAD_REQUEST));
  }

  #[test]
  fn session_limit_is_enforced() {
    let cfg = Config { sessions_max: 2, ..Config::default() };
    let daemon = Daemon::new(cfg, [3u8; 32], "p".to_string(), "1".to_string());
    let user = pty::current_user_name();
    let first = daemon.create(&user, "xterm-256color", 80, 24).expect("first");
    let second = daemon.create(&user, "xterm-256color", 80, 24).expect("second");
    assert_ne!(first.0, second.0);
    assert_eq!(daemon.create(&user, "xterm-256color", 80, 24), Err(frame::ERR_LIMIT));
    daemon.kill(first.0).ok();
    daemon.kill(second.0).ok();
  }

  /// @cc [owner:ghuntley,label:verification;recovery] explicit-kill-credit-stall-property
  /// For viewer watermarks around 1 KiB, 32 KiB and 1 MiB, with or without a
  /// descendant holding the PTY, explicit kill MUST retire a session whose
  /// viewer withholds read credit.
  #[hegel::test(test_cases = 100)]
  fn explicit_kill_retires_a_session_with_a_credit_stalled_viewer(tc: hegel::TestCase) {
    let watermarks = [1_usize, 1023, 1024, 1025, 32767, 32768, 32769,
      (1 << 20) - 1, 1 << 20, (1 << 20) + 1];
    let watermark = tc.draw(hegel::generators::sampled_from(&watermarks));
    verify_credit_stalled_kill(watermark, tc.draw(hegel::generators::booleans()));
  }

  #[test]
  fn configured_viewer_high_watermark_allows_explicit_kill_retirement() {
    verify_credit_stalled_kill(Config::default().viewer_hwm, false);
    verify_credit_stalled_kill(Config::default().viewer_hwm, true);
  }

  #[test]
  fn explicit_kill_retires_while_an_independent_owner_holds_a_quiet_slave() {
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".into(), "1".into());
    let (id, _) = daemon.create(&pty::current_user_name(), "xterm-256color", 80, 24).unwrap();
    let session = daemon.live_session(id).unwrap();
    let mut name: [libc::c_char; 128] = [0; 128];
    assert_eq!(unsafe { libc::ptsname_r(session.master, name.as_mut_ptr(), name.len()) }, 0);
    let slave = unsafe { libc::open(name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC) };
    assert!(slave >= 0);
    let slave = unsafe { OwnedFd::from_raw_fd(slave) };
    std::thread::sleep(Duration::from_millis(200));
    daemon.kill(id).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while daemon.sessions.lock().unwrap().contains_key(&id) && Instant::now() < deadline {
      std::thread::sleep(Duration::from_millis(10));
    }
    let retired = !daemon.sessions.lock().unwrap().contains_key(&id);
    let remaining = daemon.ring_total.load(Ordering::SeqCst);
    drop(slave);
    assert!(retired, "a quiet independent slave holder must not pin retirement");
    assert_eq!(remaining, 0);
  }

  fn verify_credit_stalled_kill(watermark: usize, descendant: bool) {
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, IntoRawFd};
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    let cfg = Config { viewer_hwm: watermark, ..Config::default() };
    let daemon = Daemon::new(cfg, [3u8; 32], "p".into(), "1".into());
    let (id, token) = daemon.create(&pty::current_user_name(), "xterm-256color", 80, 24).unwrap();
    let (mut viewer, server) = UnixStream::pair().unwrap();
    viewer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let send_bytes: libc::c_int = 1024;
    assert_eq!(unsafe { libc::setsockopt(server.as_raw_fd(), libc::SOL_SOCKET,
      libc::SO_SNDBUF, &send_bytes as *const _ as *const libc::c_void,
      std::mem::size_of_val(&send_bytes) as libc::socklen_t) }, 0);
    let request = AttachRequest { id, token: token.to_vec(), mode: 1, cursor: 0, cols: 0, rows: 0 };
    assert!(matches!(daemon.attach(&request, server.into_raw_fd()), Attached::Streams));
    let mut header = [0u8; 16];
    viewer.read_exact(&mut header).unwrap();
    let replay_len = u32::from_be_bytes(header[12..16].try_into().unwrap()) as usize;
    viewer.read_exact(&mut vec![0u8; replay_len]).unwrap();
    let command: &[u8] = if descendant {
      b"set +m; (trap '' HUP; while :; do printf 'credit_stall_output_0123456789\\n'; done) & wait\n"
    } else {
      b"while :; do printf 'credit_stall_output_0123456789\\n'; done\n"
    };
    viewer.write_all(command).unwrap();
    let session = daemon.live_session(id).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let stalled = loop {
      let inner = session.inner.lock().unwrap();
      let full = inner.viewers.iter().any(|entry| entry.queue.0.lock().unwrap().bytes > watermark);
      drop(inner);
      if full { break true; }
      if Instant::now() >= deadline { break false; }
      std::thread::sleep(Duration::from_millis(10));
    };
    let descendant_in_group = if descendant {
      std::fs::read_to_string(format!("/proc/{}/task/{}/children", session.pid, session.pid))
        .ok().is_some_and(|children| children.split_whitespace().filter_map(|id|
          id.parse::<libc::pid_t>().ok()).any(|pid| unsafe { libc::getpgid(pid) } == session.pid))
    } else { true };
    daemon.kill(id).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while daemon.sessions.lock().unwrap().contains_key(&id) && Instant::now() < deadline {
      std::thread::sleep(Duration::from_millis(10));
    }
    let retired = !daemon.sessions.lock().unwrap().contains_key(&id);
    let remaining = daemon.ring_total.load(Ordering::SeqCst);
    let deadline = Instant::now() + Duration::from_secs(2);
    while daemon.viewers.load(Ordering::SeqCst) != 0 && Instant::now() < deadline {
      std::thread::sleep(Duration::from_millis(10));
    }
    let remaining_viewers = daemon.viewers.load(Ordering::SeqCst);
    drop(viewer);
    assert!(stalled, "fixture must witness actual queue pressure");
    assert!(descendant_in_group, "fixture descendant must share the owned signal group");
    assert!(retired, "explicit kill must retire a credit-stalled session");
    assert_eq!(remaining, 0, "retirement must return the ring reservation");
    assert_eq!(remaining_viewers, 0, "kill must revoke writers before peer departure");
  }

  #[test]
  fn kill_terminates_and_lists_shrink() {
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let user = pty::current_user_name();
    let (id, token) = daemon.create(&user, "xterm-256color", 80, 24).expect("create");
    assert_eq!(daemon.recover_token(id), Ok(token));
    assert!(daemon.list().iter().any(|entry| entry.0 == id));
    daemon.kill(id).expect("kill");
    assert_eq!(daemon.recover_token(id), Err(frame::ERR_NOT_FOUND));
    std::thread::sleep(std::time::Duration::from_millis(200));
    assert!(!daemon.list().iter().any(|entry| entry.0 == id));
    assert_eq!(daemon.resize(id, 100, 30), Err(frame::ERR_NOT_FOUND));
    assert_eq!(token.len(), 16);
  }

  #[test]
  fn bad_attach_token_is_rejected() {
    let daemon = Daemon::new(Config::default(), [3u8; 32], "p".to_string(), "1".to_string());
    let user = pty::current_user_name();
    let (id, _token) = daemon.create(&user, "xterm-256color", 80, 24).expect("create");
    let fake = [0u8; 16];
    let request = |token: &[u8], mode: u8| AttachRequest { id, token: token.to_vec(), mode, cursor: 0, cols: 80, rows: 24 };
    match daemon.attach(&request(&fake, 1), -1) {
      Attached::Failed(code) => assert_eq!(code, frame::ERR_BAD_TOKEN),
      other => panic!("expected token failure, got {other:?}"),
    }
    assert!(matches!(daemon.attach(&request(&fake, 1), -1), Attached::Failed(frame::ERR_BAD_TOKEN)));
    assert!(matches!(daemon.attach(&AttachRequest { id: 999, token: fake.to_vec(), mode: 1, cursor: 0, cols: 80, rows: 24 }, -1), Attached::Failed(frame::ERR_NOT_FOUND)));
    assert!(matches!(daemon.attach(&request(&fake, 5), -1), Attached::Failed(frame::ERR_BAD_REQUEST)));
    daemon.kill(id).ok();
  }

  #[test]
  #[allow(clippy::print_stderr)]
  fn end_to_end_vsock_session_round_trip() {
    if !crate::vsock::available() {
      eprintln!("skipping: AF_VSOCK unavailable in this environment");
      return;
    }
    let daemon = Daemon::new(Config::default(), [5u8; 32], "placement-e2e".to_string(), "7".to_string());
    let listener = crate::vsock::listen(0).expect("bind vsock listener");
    let port = crate::vsock::bound_port(listener).expect("discover bound port");
    let acceptor = daemon.clone();
    let server = std::thread::spawn(move || crate::handle_connections(acceptor, listener));
    let client = unsafe { libc::socket(crate::vsock::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    assert!(client >= 0);
    let address = crate::vsock::address(crate::vsock::CID_LOCAL, port);
    assert_eq!(
      unsafe { libc::connect(client, &address as *const _ as *const libc::sockaddr, 16) },
      0,
      "vsock loopback connect"
    );
    let nonce = [0xabu8; 16];
    let tag = daemon.hello_tag(&nonce);
    let mut hello = Vec::new();
    hello.extend_from_slice(&nonce);
    hello.extend_from_slice(&tag);
    write_frame(client, frame::OP_HELLO, &hello).expect("send hello");
    let mut buffer = Vec::new();
    match read_frame(client, &mut buffer).expect("hello reply") {
      Ok(reply) => assert_eq!(reply.op, frame::OP_OK),
      Err(()) => panic!("hello rejected"),
    }
    let mut create = Vec::new();
    let user = pty::current_user_name();
    create.push(user.len() as u8);
    create.extend_from_slice(user.as_bytes());
    create.push(14);
    create.extend_from_slice(b"xterm-256color");
    frame::put_u16(&mut create, 80);
    frame::put_u16(&mut create, 24);
    write_frame(client, frame::OP_CREATE, &create).expect("send create");
    let reply = read_frame(client, &mut buffer).expect("create reply").expect("valid frame");
    assert_eq!(reply.op, frame::OP_OK);
    let (session_id, session_token) = {
      let mut reader = Reader::new(&reply.payload);
      (reader.u64().unwrap(), reader.bytes(16).unwrap().to_vec())
    };
    let data = unsafe { libc::socket(crate::vsock::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    assert_eq!(unsafe { libc::connect(data, &address as *const _ as *const libc::sockaddr, 16) }, 0);
    let mut attach = Vec::new();
    frame::put_u64(&mut attach, session_id);
    attach.extend_from_slice(&session_token);
    attach.push(1);
    frame::put_u64(&mut attach, 0);
    frame::put_u16(&mut attach, 80);
    frame::put_u16(&mut attach, 24);
    assert!(decode_attach(&attach).is_some());
    write_frame(data, frame::OP_HELLO, &hello).expect("send attach hello");
    let mut data_buffer = Vec::new();
    assert_eq!(read_frame(data, &mut data_buffer).unwrap().unwrap().op, frame::OP_OK);
    write_frame(data, frame::OP_ATTACH, &attach).expect("send attach");
    let marker = b"terminald-e2e-marker";
    let script = format!("printf '%s\\n' {} ; exit 0\n", String::from_utf8_lossy(marker));
    write_all(data, script.as_bytes()).expect("send script");
    let mut tail = Vec::new();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(25);
    loop {
      let mut poller = libc::pollfd { fd: data, events: libc::POLLIN, revents: 0 };
      unsafe { libc::poll(&mut poller, 1, 250) };
      let mut scratch = [0u8; 4096];
      let read = unsafe { libc::read(data, scratch.as_mut_ptr() as *mut libc::c_void, scratch.len()) };
      if read > 0 {
        tail.extend_from_slice(&scratch[..read as usize]);
        assert_eq!(tail[0], frame::MAGIC);
        assert_eq!(tail[1], frame::OP_OK);
        if tail.windows(marker.len()).any(|window| window == marker) {
          break;
        }
      }
      assert!(
        std::time::Instant::now() < deadline,
        "marker never arrived, saw: {:?}",
        String::from_utf8_lossy(&tail)
      );
    }
    daemon.kill(session_id).ok();
    unsafe { libc::close(data) };
    unsafe { libc::close(client) };
    unsafe { libc::close(listener) };
    server.join().ok();
  }
}

#[cfg(all(test, unix))]
#[path = "budget_property_tests.rs"]
mod budget_property_tests;

#[cfg(all(test, unix))]
#[path = "neighbor_property_tests.rs"]
mod neighbor_property_tests;
