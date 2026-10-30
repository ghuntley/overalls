use crate::BOOT_LOG_LIMIT;
use std::time::Duration;

/// Console line-start state. The only state is whether the next byte begins a
/// line, so the stamped output is independent of how the pipe chunks bytes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LineState {
    /// The next byte other than CR/LF begins a new line and receives a prefix.
    LineStart,
    /// The current line already carries its prefix.
    MidLine,
}

/// @cc [owner:ghuntley,label:recovery] boot-log-line-timestamps
/// Every console line that contains a byte other than CR/LF MUST be prefixed
/// with exactly one `[+S.mmm] ` host-monotonic offset from writer start, taken
/// when the line's first byte is read. CR and LF both end a line, so CRLF and
/// carriage-return redraws never split or duplicate a prefix; empty lines get
/// none. Payload bytes are copied unchanged and, for a fixed clock reading, the
/// output is independent of read chunking.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Stamper {
    state: LineState,
}

impl Default for Stamper {
    fn default() -> Self {
        Self::new()
    }
}

impl Stamper {
    pub const fn new() -> Self {
        Self {
            state: LineState::LineStart,
        }
    }

    pub const fn state(&self) -> LineState {
        self.state
    }

    /// Append `chunk` to `out`, inserting the `now` prefix at every line start.
    pub fn feed(&mut self, chunk: &[u8], now: Duration, out: &mut Vec<u8>) {
        for &byte in chunk {
            let terminator = byte == b'\n' || byte == b'\r';
            self.state = match (self.state, terminator) {
                (_, true) => LineState::LineStart,
                (LineState::LineStart, false) => {
                    push_prefix(now, out);
                    LineState::MidLine
                }
                (LineState::MidLine, false) => LineState::MidLine,
            };
            out.push(byte);
        }
    }
}

/// Append `[+S.mmm] `: whole seconds unbounded, milliseconds truncated.
pub fn push_prefix(now: Duration, out: &mut Vec<u8>) {
    use std::io::Write as _;
    // Formatting into a Vec cannot fail.
    let _ = write!(out, "[+{}.{:03}] ", now.as_secs(), now.subsec_millis());
}

/// Bounded retention of the stamped stream. Once BOOT_LOG_LIMIT stamped bytes
/// are retained, later input is discarded without stamping.
#[derive(Debug)]
pub struct Retention {
    stamper: Stamper,
    retained: usize,
    scratch: Vec<u8>,
}

impl Default for Retention {
    fn default() -> Self {
        Self::new()
    }
}

impl Retention {
    pub fn new() -> Self {
        Self {
            stamper: Stamper::new(),
            retained: 0,
            scratch: Vec::new(),
        }
    }

    /// The stamped bytes of `chunk` (read at `now`) that still fit the limit.
    pub fn admit(&mut self, chunk: &[u8], now: Duration) -> &[u8] {
        self.scratch.clear();
        let available = BOOT_LOG_LIMIT - self.retained;
        if available > 0 {
            self.stamper.feed(chunk, now, &mut self.scratch);
            self.scratch.truncate(available);
            self.retained += self.scratch.len();
        }
        &self.scratch
    }

    pub const fn retained(&self) -> usize {
        self.retained
    }
}

/// The observed drain ending.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Drained {
    /// Child's writers reached EOF only after exiting.
    Complete,
    /// Reading the child channel failed.
    ReadFailed,
    /// Persisting the retained prefix failed.
    WriteFailed,
}
