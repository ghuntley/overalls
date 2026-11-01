use crate::WINDOW;

/// One direction's custody: bytes read from its source wait in its pipe
/// until they are written to its sink.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Direction {
    /// Bytes in the pipe, read but not yet written.
    pub pending: usize,
    /// The source reported end of stream.
    pub eof: bool,
    /// The sink was shut down for writing.
    pub shut: bool,
}

impl Direction {
    pub fn wants_read(&self) -> bool {
        !self.eof && self.pending < WINDOW
    }

    pub fn wants_write(&self) -> bool {
        self.pending > 0
    }

    /// Free window space; zero (never an underflow) if `pending` exceeds it.
    pub fn room(&self) -> usize {
        WINDOW.saturating_sub(self.pending)
    }

    /// Every byte the source sent was delivered.
    pub fn drained(&self) -> bool {
        self.eof && self.pending == 0
    }

    /// @cc [owner:ghuntley,label:recovery] bridge-direction-refuses-overrun
    /// Record a source read of `count` bytes; zero is end of stream. A read count beyond `room()` or a write count beyond `pending` MUST be
    /// refused with `Overrun` and leave the direction unchanged, so a kernel
    /// count that broke the splice contract ends the bridge with `EXIT_IO`
    /// instead of wrapping the accounting or aborting the hardened helper.
    pub fn read(&mut self, count: usize) -> Result<(), Overrun> {
        if count == 0 {
            self.eof = true;
        } else if count <= self.room() {
            self.pending += count;
        } else {
            return Err(Overrun);
        }
        Ok(())
    }

    /// Record a sink write of `count` pending bytes.
    pub fn wrote(&mut self, count: usize) -> Result<(), Overrun> {
        self.pending = self.pending.checked_sub(count).ok_or(Overrun)?;
        Ok(())
    }
}

/// A splice reported more bytes than the direction asked it to move.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Overrun;

/// @cc [owner:ghuntley,label:recovery] bridge-ends-with-lilly
/// The bridge MUST finish once the client's side (Lilly's socket, or Audi's
/// connection when detached) reached end of stream and every byte it sent
/// was delivered to the guest: clients close only whole sockets, so a silent
/// guest cannot keep a bridge alive. A guest end of stream only shuts the
/// client's side for writing, after the guest's bytes were delivered.
pub fn finished(outbound: &Direction) -> bool {
    outbound.drained()
}

/// Whether the guest's end of stream may now be passed to Lilly's side.
pub fn half_close_due(inbound: &Direction) -> bool {
    inbound.drained() && !inbound.shut
}
