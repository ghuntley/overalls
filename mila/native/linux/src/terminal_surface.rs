//! GTK-independent lifecycle of the Linux terminal surface.
//!
//! The GTK shell owns one [`TerminalSurface`] per window. It calls
//! [`TerminalSurface::tick`] from a main-loop timer and copies
//! [`TerminalSurface::text`] into its text view; every attach, read, input,
//! resize, reconnect and kill decision is made here against the authenticated
//! [`AuthenticatedPty`] reducer, so the widget never interprets PTY bytes.

use crate::terminal::{
    AuthenticatedPty, PtyAttachRequest, PtyError, PtyRead, PtyTransport, RenderError,
    SessionAuthority,
};
use crate::terminal_text::{encode_key, TerminalKey};

/// Reads drained per timer tick, bounding main-loop work per frame.
pub const MAX_READS_PER_TICK: usize = 8;

/// The presentation-relevant result of one timer tick.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TickOutcome {
    /// No terminal is attached; the timer should stop.
    Detached,
    /// The channel is open and nothing new was rendered.
    Unchanged,
    /// New text was rendered; the view should refresh.
    Updated,
    /// The host closed the channel; the view keeps its last text.
    Ended,
    /// Authority was lost or the transport failed; the generation was fenced.
    Failed(PtyError),
}

impl TickOutcome {
    /// Whether the GTK timer source should remain installed.
    pub const fn keeps_polling(self) -> bool {
        matches!(self, Self::Unchanged | Self::Updated)
    }
}

/// @cc [owner:ghuntley,label:security;terminal] linux-terminal-surface-lifecycle
/// The surface MUST hold at most one live generation, MUST stop polling after
/// end-of-stream, sign-out, kill or a failed read, and MUST fence the live
/// generation locally whenever the host close fails, so no input, resize or
/// output is accepted for a generation the surface no longer presents.
pub struct TerminalSurface<A: SessionAuthority, T: PtyTransport> {
    pty: AuthenticatedPty<A, T>,
    live: Option<u64>,
    request: Option<PtyAttachRequest>,
}

impl<A: SessionAuthority, T: PtyTransport> TerminalSurface<A, T> {
    pub fn new(authority: A, transport: T, columns: u16, rows: u16) -> Result<Self, RenderError> {
        Ok(Self {
            pty: AuthenticatedPty::new(authority, transport, columns, rows)?,
            live: None,
            request: None,
        })
    }

    /// Attaches a new read-write channel. A live channel must be killed or
    /// reconnected first; the surface never opens a second concurrent one.
    pub fn attach(&mut self, session_id: &str, columns: u16, rows: u16) -> Result<u64, PtyError> {
        if self.live.is_some() {
            return Err(PtyError::Transport);
        }
        let request = PtyAttachRequest {
            session_id: session_id.to_owned(),
            from: self.pty.state().resume_cursor().unwrap_or(0),
            columns,
            rows,
            read_write: true,
        };
        let generation = self.pty.attach(request.clone())?;
        self.live = Some(generation);
        self.request = Some(request);
        Ok(generation)
    }

    /// Fences the current generation and attaches again with the last request.
    pub fn reconnect(&mut self) -> Result<u64, PtyError> {
        let request = self.request.clone().ok_or(PtyError::InvalidRequest)?;
        if let Some(generation) = self.live.take() {
            self.pty.abandon(generation);
        }
        self.attach(&request.session_id, request.columns, request.rows)
    }

    /// Drains up to [`MAX_READS_PER_TICK`] chunks from the live generation.
    pub fn tick(&mut self) -> TickOutcome {
        let Some(generation) = self.live else {
            return TickOutcome::Detached;
        };
        let mut updated = false;
        for _ in 0..MAX_READS_PER_TICK {
            match self.pty.read_output(generation) {
                Ok(PtyRead::Text(_)) => updated = true,
                Ok(PtyRead::Idle) => break,
                Ok(PtyRead::Eof) => {
                    self.live = None;
                    return TickOutcome::Ended;
                }
                Err(error) => {
                    self.live = None;
                    self.pty.abandon(generation);
                    return TickOutcome::Failed(error);
                }
            }
        }
        if updated {
            TickOutcome::Updated
        } else {
            TickOutcome::Unchanged
        }
    }

    pub fn send(&mut self, input: &[u8]) -> Result<(), PtyError> {
        let generation = self.live.ok_or(PtyError::InvalidRequest)?;
        self.pty.send_input(generation, input)
    }

    pub fn send_key(&mut self, key: TerminalKey) -> Result<(), PtyError> {
        let bytes = encode_key(key).ok_or(PtyError::InvalidRequest)?;
        self.send(&bytes)
    }

    pub fn resize(&mut self, columns: u16, rows: u16) -> Result<(), PtyError> {
        let generation = self.live.ok_or(PtyError::InvalidRequest)?;
        self.pty.resize(generation, columns, rows)?;
        if let Some(request) = self.request.as_mut() {
            request.columns = columns;
            request.rows = rows;
        }
        Ok(())
    }

    /// Closes the live channel. A failed host close still fences the generation.
    pub fn kill(&mut self) -> Result<(), PtyError> {
        let generation = self.live.take().ok_or(PtyError::InvalidRequest)?;
        let result = self.pty.kill(generation);
        if result.is_err() {
            self.pty.abandon(generation);
        }
        result
    }

    /// Sign-out or deployment switch: fence any live generation and forget
    /// the reconnect request so a later session cannot reuse it.
    pub fn sign_out(&mut self) {
        if let Some(generation) = self.live.take() {
            self.pty.abandon(generation);
        }
        self.request = None;
    }

    pub const fn live_generation(&self) -> Option<u64> {
        self.live
    }

    /// The bounded viewport text shown by the GTK view.
    pub fn text(&self) -> String {
        self.pty.renderer().lines().join("\n")
    }

    pub fn transport_mut(&mut self) -> &mut T {
        self.pty.transport_mut()
    }
}

#[cfg(test)]
mod tests {
    use super::{TerminalSurface, TickOutcome, MAX_READS_PER_TICK};
    use crate::terminal::{PtyAttachRequest, PtyError, PtyRead, PtyTransport, SessionAuthority};
    use crate::terminal_text::TerminalKey;
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::rc::Rc;

    #[derive(Clone, Default)]
    struct Authority(Rc<Cell<bool>>);
    impl SessionAuthority for Authority {
        fn is_authenticated(&self) -> bool {
            self.0.get()
        }
    }

    #[derive(Default)]
    struct Script {
        reads: VecDeque<Result<PtyRead, PtyError>>,
        inputs: Vec<Vec<u8>>,
        attaches: usize,
        kills: usize,
        fail_kill: bool,
        resizes: Vec<(u16, u16)>,
    }

    #[derive(Clone, Default)]
    struct Transport(Rc<RefCell<Script>>);
    impl PtyTransport for Transport {
        fn attach(&mut self, _: &PtyAttachRequest) -> Result<(), PtyError> {
            self.0.borrow_mut().attaches += 1;
            Ok(())
        }
        fn read_output(&mut self, _: u64) -> Result<PtyRead, PtyError> {
            self.0
                .borrow_mut()
                .reads
                .pop_front()
                .unwrap_or(Ok(PtyRead::Idle))
        }
        fn send_input(&mut self, _: u64, input: &[u8]) -> Result<(), PtyError> {
            self.0.borrow_mut().inputs.push(input.to_vec());
            Ok(())
        }
        fn resize(&mut self, _: u64, columns: u16, rows: u16) -> Result<(), PtyError> {
            self.0.borrow_mut().resizes.push((columns, rows));
            Ok(())
        }
        fn kill(&mut self, _: u64) -> Result<(), PtyError> {
            let mut script = self.0.borrow_mut();
            script.kills += 1;
            if script.fail_kill {
                Err(PtyError::Transport)
            } else {
                Ok(())
            }
        }
    }

    fn surface() -> (TerminalSurface<Authority, Transport>, Authority, Transport) {
        let authority = Authority(Rc::new(Cell::new(true)));
        let transport = Transport::default();
        let surface = TerminalSurface::new(authority.clone(), transport.clone(), 20, 4).unwrap();
        (surface, authority, transport)
    }

    fn text(value: &str) -> Result<PtyRead, PtyError> {
        Ok(PtyRead::Text(value.to_owned()))
    }

    #[test]
    fn tick_renders_stream_until_end_of_stream() {
        let (mut surface, _, transport) = surface();
        assert_eq!(surface.tick(), TickOutcome::Detached);
        surface.attach("session-1", 20, 4).unwrap();
        transport
            .0
            .borrow_mut()
            .reads
            .extend([text("$ echo hi\r\n"), text("hi\r\n")]);
        assert_eq!(surface.tick(), TickOutcome::Updated);
        assert_eq!(surface.text(), "$ echo hi\nhi\n");
        assert_eq!(surface.tick(), TickOutcome::Unchanged);
        transport.0.borrow_mut().reads.push_back(Ok(PtyRead::Eof));
        assert_eq!(surface.tick(), TickOutcome::Ended);
        assert!(!TickOutcome::Ended.keeps_polling());
        assert_eq!(surface.tick(), TickOutcome::Detached);
        assert_eq!(surface.send(b"x"), Err(PtyError::InvalidRequest));
        assert_eq!(surface.text(), "$ echo hi\nhi\n");
    }

    #[test]
    fn tick_work_is_bounded() {
        let (mut surface, _, transport) = surface();
        surface.attach("session-1", 20, 4).unwrap();
        transport
            .0
            .borrow_mut()
            .reads
            .extend((0..MAX_READS_PER_TICK + 3).map(|_| text("x")));
        assert_eq!(surface.tick(), TickOutcome::Updated);
        assert_eq!(transport.0.borrow().reads.len(), 3);
    }

    #[test]
    fn input_keys_and_resize_reach_transport_only_while_live() {
        let (mut surface, _, transport) = surface();
        assert_eq!(
            surface.send_key(TerminalKey::Enter),
            Err(PtyError::InvalidRequest)
        );
        surface.attach("session-1", 20, 4).unwrap();
        surface.send(b"ls").unwrap();
        surface.send_key(TerminalKey::Enter).unwrap();
        surface.send_key(TerminalKey::Control('c')).unwrap();
        assert_eq!(
            surface.send_key(TerminalKey::Text('\u{1b}')),
            Err(PtyError::InvalidRequest)
        );
        surface.resize(100, 30).unwrap();
        assert_eq!(surface.resize(0, 30), Err(PtyError::InvalidRequest));
        let script = transport.0.borrow();
        assert_eq!(script.inputs, vec![b"ls".to_vec(), b"\r".to_vec(), vec![3]]);
        assert_eq!(script.resizes, vec![(100, 30)]);
    }

    #[test]
    fn lost_authority_fences_the_generation_and_stops_polling() {
        let (mut surface, authority, transport) = surface();
        surface.attach("session-1", 20, 4).unwrap();
        authority.0.set(false);
        assert_eq!(
            surface.tick(),
            TickOutcome::Failed(PtyError::Unauthenticated)
        );
        assert_eq!(surface.live_generation(), None);
        assert_eq!(surface.send(b"x"), Err(PtyError::InvalidRequest));
        assert_eq!(transport.0.borrow().inputs.len(), 0);
        authority.0.set(true);
        assert_eq!(surface.tick(), TickOutcome::Detached);
    }

    #[test]
    fn reconnect_replaces_generation_and_refuses_stale_output() {
        let (mut surface, _, transport) = surface();
        let first = surface.attach("session-1", 20, 4).unwrap();
        assert_eq!(surface.attach("session-1", 20, 4), Err(PtyError::Transport));
        let second = surface.reconnect().unwrap();
        assert!(second > first);
        assert_eq!(transport.0.borrow().attaches, 2);
        transport.0.borrow_mut().reads.push_back(text("again"));
        assert_eq!(surface.tick(), TickOutcome::Updated);
        assert_eq!(surface.live_generation(), Some(second));
    }

    #[test]
    fn failed_kill_and_sign_out_still_fence() {
        let (mut surface, _, transport) = surface();
        surface.attach("session-1", 20, 4).unwrap();
        transport.0.borrow_mut().fail_kill = true;
        assert_eq!(surface.kill(), Err(PtyError::Transport));
        assert_eq!(surface.live_generation(), None);
        assert_eq!(surface.send(b"x"), Err(PtyError::InvalidRequest));
        transport.0.borrow_mut().fail_kill = false;
        surface.attach("session-1", 20, 4).unwrap();
        surface.sign_out();
        assert_eq!(surface.live_generation(), None);
        assert_eq!(surface.reconnect(), Err(PtyError::InvalidRequest));
    }

    #[test]
    fn transport_failure_fences_and_reports() {
        let (mut surface, _, transport) = surface();
        surface.attach("session-1", 20, 4).unwrap();
        transport
            .0
            .borrow_mut()
            .reads
            .push_back(Err(PtyError::Transport));
        assert_eq!(surface.tick(), TickOutcome::Failed(PtyError::Transport));
        assert!(transport.0.borrow().kills >= 1);
    }
}
