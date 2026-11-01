//! The authenticated PTY on a live session and its host backend.

use super::{
    copy_output, terminal_closed, valid_request_id, validate_session_identifier, LiveSession,
    SessionBinding, SessionError,
};
use mila_ffi::session::TerminalReadEvent;

/// One bounded terminal read. Bytes stay inside the host transport; the GTK
/// surface only receives text decoded by `PtyTextDecoder`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalChunk {
    Data(Vec<u8>),
    Idle,
    Closed,
}

impl LiveSession {
    /// Open one authenticated PTY on a named terminal session of `machine_id`.
    /// Without `session_id`, `terminal new` first opens or rejoins the
    /// caller's personal session; Porsche refuses an unnamed attach.
    pub fn terminal_attach(
        &mut self,
        machine_id: &str,
        session_id: Option<&str>,
        columns: u16,
        rows: u16,
    ) -> Result<u64, SessionError> {
        validate_session_identifier(machine_id)?;
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return Err(SessionError::InvalidInput);
        }
        if self.terminal.is_some() {
            return Err(SessionError::Busy);
        }
        let session_id = match session_id {
            Some(session_id) => {
                validate_session_identifier(session_id)?;
                session_id.to_owned()
            }
            None => self.terminal_new(machine_id)?,
        };
        let handle = self.handle()?;
        let mut terminal = 0_u64;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call, each out-pointer is a writable local (or owned buffer
        // of the declared length) that outlives it, and the C ABI retains none.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_attach_session(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                session_id.as_bytes().as_ptr(),
                session_id.len(),
                u32::from(columns),
                u32::from(rows),
                &raw mut terminal,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || terminal == 0 {
            return Err(status.into());
        }
        self.terminal = Some(terminal);
        Ok(terminal)
    }

    /// `terminal new MACHINE`: the id of the caller's personal session,
    /// opened or rejoined.
    pub fn terminal_new(&mut self, machine_id: &str) -> Result<String, SessionError> {
        validate_session_identifier(machine_id)?;
        let request_id = crate::adapter::new_request_id().ok_or(SessionError::Unavailable)?;
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_terminal_new(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
                out,
                capacity,
                written,
            )
        })?;
        let result =
            crate::porsche_results::result_value(&bytes).map_err(|_| SessionError::InvalidInput)?;
        let session_id = result
            .get("session_id")
            .and_then(serde_json::Value::as_str)
            .ok_or(SessionError::InvalidInput)?;
        validate_session_identifier(session_id)?;
        Ok(session_id.to_owned())
    }

    /// @cc [owner:ghuntley,label:security;protocol] linux-session-terminal-end
    /// `terminal kill MACHINE SESSION`: Marshall closes the named server
    /// session for everyone attached and ends its programs. Returns `true`
    /// only when Marshall reports that exact session closed. Any local PTY
    /// on this session is closed first, so no stale channel outlives it.
    pub fn terminal_end(
        &mut self,
        machine_id: &str,
        session_id: &str,
        request_id: &str,
    ) -> Result<bool, SessionError> {
        validate_session_identifier(machine_id)?;
        validate_session_identifier(session_id)?;
        if !valid_request_id(request_id) {
            return Err(SessionError::InvalidInput);
        }
        if !self.submitted_mutations.insert(request_id.to_owned()) {
            return Err(SessionError::Busy);
        }
        let _ = self.terminal_kill();
        let handle = self.handle()?;
        // SAFETY: `copy_output` passes `out` writable for `capacity` bytes and a
        // writable `written`; every input pointer/length pair borrows a live Rust
        // slice for this synchronous call, and the C ABI retains none of them.
        let bytes = copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_terminal_end(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                session_id.as_bytes().as_ptr(),
                session_id.len(),
                request_id.as_bytes().as_ptr(),
                request_id.len(),
                out,
                capacity,
                written,
            )
        })?;
        Ok(terminal_closed(&bytes, session_id))
    }

    /// Poll a bounded output chunk from the authenticated PTY.
    pub fn terminal_poll(&mut self) -> Result<Vec<u8>, SessionError> {
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        let mut output = vec![0_u8; 65_536];
        let mut written = 0_usize;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call, each out-pointer is a writable local (or owned buffer
        // of the declared length) that outlives it, and the C ABI retains none.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_poll(
                terminal,
                output.as_mut_ptr(),
                output.len(),
                &raw mut written,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || written > output.len() {
            return Err(status.into());
        }
        output.truncate(written);
        Ok(output)
    }

    /// The PTY handle opened by [`Self::terminal_attach`], if still open.
    pub const fn terminal_handle(&self) -> Option<u64> {
        self.terminal
    }

    /// Reads at most one chunk, waiting no longer than `wait_ms` (at most
    /// 1000). A closed channel releases its handle so a new attach can follow.
    pub fn terminal_read(&mut self, wait_ms: u32) -> Result<TerminalChunk, SessionError> {
        if wait_ms > 1_000 {
            return Err(SessionError::InvalidInput);
        }
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        let capacity = mila_ffi::session::MILA_TERMINAL_READ_CAPACITY;
        if self.read_buffer.len() != capacity {
            self.read_buffer = vec![0_u8; capacity];
        }
        let mut written = 0_usize;
        let mut event = TerminalReadEvent::Idle;
        // SAFETY: every input pointer/length pair borrows a live Rust slice for this
        // synchronous call, each out-pointer is a writable local (or owned buffer
        // of the declared length) that outlives it, and the C ABI retains none.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_read_within(
                terminal,
                wait_ms,
                self.read_buffer.as_mut_ptr(),
                self.read_buffer.len(),
                &raw mut written,
                &raw mut event,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || written > capacity {
            return Err(status.into());
        }
        match event {
            TerminalReadEvent::Data if written > 0 => {
                Ok(TerminalChunk::Data(self.read_buffer[..written].to_vec()))
            }
            TerminalReadEvent::Data | TerminalReadEvent::Idle => Ok(TerminalChunk::Idle),
            TerminalReadEvent::Closed => {
                let _ = self.terminal_kill();
                Ok(TerminalChunk::Closed)
            }
        }
    }

    pub fn terminal_input(&mut self, input: &[u8]) -> Result<(), SessionError> {
        if input.len() > (1 << 20) {
            return Err(SessionError::InvalidInput);
        }
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        // SAFETY: every pointer/length pair borrows a live Rust slice for this
        // synchronous call, and the C ABI copies its inputs without retaining them.
        let status = unsafe {
            mila_ffi::session::mila_session_terminal_input(terminal, input.as_ptr(), input.len())
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn terminal_resize(&mut self, columns: u16, rows: u16) -> Result<(), SessionError> {
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return Err(SessionError::InvalidInput);
        }
        let terminal = self.terminal.ok_or(SessionError::StaleHandle)?;
        let status = mila_ffi::session::mila_session_terminal_resize(
            terminal,
            u32::from(columns),
            u32::from(rows),
        );
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn terminal_kill(&mut self) -> Result<(), SessionError> {
        let Some(terminal) = self.terminal.take() else {
            return Ok(());
        };
        let status = mila_ffi::session::mila_session_terminal_kill(terminal);
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }
}

/// @cc [owner:ghuntley,label:security;terminal] linux-session-pty-backend
/// The backend MUST operate only on the PTY handle it opened through the
/// currently bound authenticated session, MUST refuse every channel operation
/// when no session is bound or the handle differs, and MUST decode PTY bytes
/// into display text before they leave the backend.
///
/// [`HostPtyBackend`](crate::terminal::HostPtyBackend) over the authenticated
/// FFI session held by the GTK window or the headless journey driver.
pub struct SessionPtyBackend {
    binding: std::rc::Rc<std::cell::RefCell<SessionBinding>>,
    decoder: crate::terminal_text::PtyTextDecoder,
    wait_ms: u32,
}

/// Opaque: fields may hold credentials, key material or terminal bytes.
impl std::fmt::Debug for SessionPtyBackend {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionPtyBackend")
            .finish_non_exhaustive()
    }
}

impl SessionPtyBackend {
    /// `wait_ms` bounds how long one read may block the caller (at most 1000).
    pub fn new(binding: std::rc::Rc<std::cell::RefCell<SessionBinding>>, wait_ms: u32) -> Self {
        Self {
            binding,
            decoder: crate::terminal_text::PtyTextDecoder::new(),
            wait_ms: wait_ms.min(1_000),
        }
    }

    fn with_channel<R>(
        &mut self,
        channel: u64,
        operation: impl FnOnce(&mut LiveSession) -> Result<R, SessionError>,
    ) -> Result<R, crate::terminal::PtyError> {
        use crate::terminal::PtyError;
        let mut binding = self
            .binding
            .try_borrow_mut()
            .map_err(|_| PtyError::Transport)?;
        let live = binding.session_mut().ok_or(PtyError::Unauthenticated)?;
        if live.terminal_handle() != Some(channel) {
            return Err(PtyError::InvalidRequest);
        }
        operation(live).map_err(|error| match error {
            SessionError::InvalidInput => PtyError::InvalidRequest,
            SessionError::StaleHandle => PtyError::Unauthenticated,
            _ => PtyError::Transport,
        })
    }
}

impl crate::terminal::HostPtyBackend for SessionPtyBackend {
    fn attach(
        &mut self,
        request: &crate::terminal::PtyAttachRequest,
    ) -> Result<u64, crate::terminal::PtyError> {
        use crate::terminal::PtyError;
        let mut binding = self
            .binding
            .try_borrow_mut()
            .map_err(|_| PtyError::Transport)?;
        let live = binding.session_mut().ok_or(PtyError::Unauthenticated)?;
        if !live.is_open() {
            return Err(PtyError::Unauthenticated);
        }
        let session = (!request.session_id.is_empty()).then_some(request.session_id.as_str());
        let channel = live
            .terminal_attach(&request.machine_id, session, request.columns, request.rows)
            .map_err(|error| match error {
                SessionError::InvalidInput => PtyError::InvalidRequest,
                _ => PtyError::Transport,
            })?;
        self.decoder = crate::terminal_text::PtyTextDecoder::new();
        Ok(channel)
    }

    fn read_output(
        &mut self,
        channel: u64,
    ) -> Result<crate::terminal::PtyRead, crate::terminal::PtyError> {
        use crate::terminal::PtyRead;
        let wait_ms = self.wait_ms;
        match self.with_channel(channel, |live| live.terminal_read(wait_ms))? {
            TerminalChunk::Data(bytes) => Ok(PtyRead::Text(self.decoder.decode(&bytes))),
            TerminalChunk::Idle => Ok(PtyRead::Idle),
            TerminalChunk::Closed => Ok(PtyRead::Eof),
        }
    }

    fn send_input(&mut self, channel: u64, input: &[u8]) -> Result<(), crate::terminal::PtyError> {
        self.with_channel(channel, |live| live.terminal_input(input))
    }

    fn resize(
        &mut self,
        channel: u64,
        columns: u16,
        rows: u16,
    ) -> Result<(), crate::terminal::PtyError> {
        self.with_channel(channel, |live| live.terminal_resize(columns, rows))
    }

    fn kill(&mut self, channel: u64) -> Result<(), crate::terminal::PtyError> {
        self.with_channel(channel, LiveSession::terminal_kill)
    }
}
