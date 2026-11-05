//! Payload-free port of the former terminal attachment reducer.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachPhase {
    Idle,
    Attaching,
    Attached,
    Waiting,
    Ended,
}
pub use mila_protocol::{AttachError, AttachHeader, AttachMode, AttachOutcome};
pub const MAXIMUM_ATTACH_ATTEMPTS: u32 = 8;

/// @cc [owner:ghuntley,label:security] mila-runtime-terminal-state
/// Terminal state MUST retain only counters and closed values, never output bytes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalAttach {
    phase: AttachPhase,
    generation: u64,
    attempts: u32,
    cursor: u64,
    cursor_known: bool,
    read_only_requested: bool,
    jumps: u64,
    reset_pending: bool,
    mode: Option<AttachMode>,
    outcome: Option<AttachOutcome>,
    error: Option<AttachError>,
}
impl TerminalAttach {
    pub const fn initial() -> Self {
        Self {
            phase: AttachPhase::Idle,
            generation: 0,
            attempts: 0,
            cursor: 0,
            cursor_known: false,
            read_only_requested: false,
            jumps: 0,
            reset_pending: false,
            mode: None,
            outcome: None,
            error: None,
        }
    }
    pub const fn phase(&self) -> AttachPhase {
        self.phase
    }
    pub const fn generation(&self) -> u64 {
        self.generation
    }
    pub const fn attempts(&self) -> u32 {
        self.attempts
    }
    pub const fn cursor(&self) -> u64 {
        self.cursor
    }
    /// None asks for the server's whole replay buffer on the first attach.
    pub const fn resume_cursor(&self) -> Option<u64> {
        if self.cursor_known {
            Some(self.cursor)
        } else {
            None
        }
    }
    pub const fn jumps(&self) -> u64 {
        self.jumps
    }
    pub const fn reset_pending(&self) -> bool {
        self.reset_pending
    }
    pub const fn mode(&self) -> Option<AttachMode> {
        self.mode
    }
    pub const fn outcome(&self) -> Option<AttachOutcome> {
        self.outcome
    }
    pub const fn error(&self) -> Option<AttachError> {
        self.error
    }
    pub const fn read_only_requested(&self) -> bool {
        self.read_only_requested
    }
    pub fn read_only(&self) -> bool {
        self.read_only_requested || self.mode == Some(AttachMode::ReadOnly)
    }
    /// @cc [owner:ghuntley,label:security] mila-runtime-terminal-write-grant
    /// Input and resize MUST require a current read-write grant and no user read-only restriction.
    pub fn can_send_input(&self) -> bool {
        self.phase == AttachPhase::Attached
            && self.mode == Some(AttachMode::ReadWrite)
            && !self.read_only_requested
    }
    pub fn can_resize(&self) -> bool {
        self.can_send_input()
    }
    pub fn accepts_output(&self, generation: u64) -> bool {
        self.phase == AttachPhase::Attached && self.generation == generation
    }
    fn current(&self, generation: u64) -> bool {
        self.generation == generation
            && matches!(self.phase, AttachPhase::Attaching | AttachPhase::Attached)
    }
    pub fn request(&mut self) -> bool {
        if matches!(self.phase, AttachPhase::Attaching | AttachPhase::Attached) {
            return false;
        }
        // Never reuse a channel generation, even at the integer boundary.
        let Some(next) = self.generation.checked_add(1) else {
            return false;
        };
        self.generation = next;
        if self.phase == AttachPhase::Ended {
            self.attempts = 0;
        }
        self.phase = AttachPhase::Attaching;
        self.mode = None;
        self.outcome = None;
        self.error = None;
        true
    }
    /// @cc [owner:ghuntley,label:protocol] mila-runtime-terminal-header
    /// Only the current opening channel may set a cursor; a changed known cursor MUST request a screen reset.
    pub fn header(&mut self, generation: u64, header: Option<AttachHeader>) -> bool {
        if self.phase != AttachPhase::Attaching || self.generation != generation {
            return false;
        }
        match header {
            Some(AttachHeader::Attached { from, mode }) => {
                if self.cursor_known && from != self.cursor {
                    self.jumps = self.jumps.saturating_add(1);
                    self.reset_pending = true;
                }
                self.cursor = from;
                self.cursor_known = true;
                self.mode = Some(mode);
                self.phase = AttachPhase::Attached;
                self.attempts = 0;
            }
            Some(AttachHeader::Refused(error)) => self.fail(error.outcome(), Some(error)),
            None => self.fail(AttachOutcome::Invalid, None),
        }
        true
    }
    pub fn connected(&mut self, generation: u64, cursor: u64) -> bool {
        self.header(
            generation,
            Some(AttachHeader::Attached {
                from: cursor,
                mode: AttachMode::ReadWrite,
            }),
        )
    }
    pub fn output(&mut self, generation: u64, bytes: usize) -> bool {
        if !self.accepts_output(generation) || bytes == 0 {
            return false;
        }
        let Ok(bytes) = u64::try_from(bytes) else {
            return false;
        };
        let Some(cursor) = self.cursor.checked_add(bytes) else {
            self.fail(AttachOutcome::Invalid, None);
            return false;
        };
        self.cursor = cursor;
        true
    }
    pub fn ended(&mut self, generation: u64, outcome: AttachOutcome) -> bool {
        if !self.current(generation) {
            return false;
        }
        self.fail(outcome, self.error);
        true
    }
    fn fail(&mut self, outcome: AttachOutcome, error: Option<AttachError>) {
        self.attempts += 1;
        self.phase =
            if outcome == AttachOutcome::Transport && self.attempts < MAXIMUM_ATTACH_ATTEMPTS {
                AttachPhase::Waiting
            } else {
                AttachPhase::Ended
            };
        self.outcome = Some(outcome);
        self.error = error;
        self.mode = None;
    }
    pub fn screen_reset(&mut self) {
        self.reset_pending = false;
    }
    pub fn set_read_only(&mut self, value: bool) {
        self.read_only_requested = value;
    }
    pub fn detach(&mut self) {
        if self.phase != AttachPhase::Ended {
            self.phase = AttachPhase::Ended;
            self.outcome = Some(AttachOutcome::Closed);
            self.mode = None;
        }
    }
}
