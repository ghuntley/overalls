//! Raw-byte scrollback ring with absolute cursors and explicit truncation.
pub struct Ring {
    buffer: std::collections::VecDeque<u8>,
    base: u64,
    capacity: usize,
}

impl Ring {
    pub fn new(capacity: usize) -> Self {
        Ring {
            buffer: std::collections::VecDeque::with_capacity(capacity),
            base: 0,
            capacity: capacity.max(1),
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// @cc [owner:ghuntley,label:verification] ring-reports-allocated-backing
    /// The test oracle MUST report the backing deque's allocated capacity,
    /// independently of the ring's logical retention limit.
    #[cfg(any(all(test, unix), feature = "antithesis-observer"))]
    pub fn allocated_capacity(&self) -> usize {
        self.buffer.capacity()
    }

    pub fn set_capacity(&mut self, capacity: usize) {
        self.capacity = capacity.max(1);
        self.truncate_to_capacity();
    }

    pub fn tail(&self) -> u64 {
        self.base + self.buffer.len() as u64
    }

    pub fn base(&self) -> u64 {
        self.base
    }

    /// @cc [owner:ghuntley,label:recovery] ring-append-truncates-oldest-only
    /// Appending past capacity MUST drop only the oldest bytes, advance `base`
    /// by exactly the number of dropped bytes, and preserve order of the rest.
    /**
     * @cc [owner:ghuntley,label:capacity] ring-overwrite-reuses-backing
     * If allocated backing is at least the logical limit, appends MUST NOT
     * grow that backing allocation, including while overwriting a full ring.
     */
    pub fn push(&mut self, data: &[u8]) {
        for byte in data {
            if self.buffer.len() == self.capacity {
                self.buffer.pop_front();
                self.base += 1;
            }
            self.buffer.push_back(*byte);
        }
        self.truncate_to_capacity();
    }

    fn truncate_to_capacity(&mut self) {
        let excess = self.buffer.len().saturating_sub(self.capacity);
        if excess > 0 {
            self.buffer.drain(..excess);
            self.base += excess as u64;
        }
    }

    /// @cc [owner:ghuntley,label:recovery] ring-replay-reports-gaps
    /// Replay MUST return the retained suffix starting at or after the requested
    /// cursor; when older bytes were truncated it MUST report the actual start so
    /// callers can expose the skipped range explicitly.
    pub fn replay_from(&self, cursor: u64) -> (u64, Vec<u8>) {
        let start = cursor.max(self.base);
        if start >= self.tail() {
            return (self.tail(), Vec::new());
        }
        let offset = (start - self.base) as usize;
        (start, self.buffer.iter().skip(offset).copied().collect())
    }
}

#[cfg(test)]
mod tests {
    /// @cc [owner:ghuntley,label:verification;capacity] overwrite-keeps-backing-within-limit
    /// With a positive initial capacity and no resize, appends MUST keep backing
    /// within that limit while preserving exactly the newest bytes and cursors.
    #[hegel::test(test_cases = 3)]
    fn overwriting_a_full_ring_preserves_bounded_backing(tc: hegel::TestCase) {
        use hegel::generators as gs;
        let cfg = crate::session::Config::default();
        let capacity = tc.draw(gs::sampled_from(&[
            1_usize, 2, 3, 7, 8, 9, 32767, 32768, 32769,
        ]));
        let chunk = tc.draw(gs::sampled_from(&[0_usize, 1, 2, 32767, 32768, 32769]));
        for (capacity, chunk) in [
            (cfg.ring_default, 1),
            (cfg.ring_max, 32768),
            (capacity, chunk),
        ] {
            let mut ring = super::Ring::new(capacity);
            let original: Vec<u8> = (0..capacity)
                .map(|index| u8::try_from(index % 251).expect("bounded original pattern"))
                .collect();
            let appended: Vec<u8> = (0..chunk)
                .map(|index| u8::try_from(index % 239).expect("bounded appended pattern"))
                .collect();
            ring.push(&original);
            ring.push(&appended);
            assert!(
                ring.buffer.capacity() <= capacity,
                "overwriting must not retain unreserved backing"
            );
            let (start, replay) = ring.replay_from(0);
            let complete: Vec<u8> = original.into_iter().chain(appended).collect();
            let retained = complete.len().min(capacity);
            assert_eq!(
                start,
                u64::try_from(complete.len() - retained).expect("bounded cursor")
            );
            assert_eq!(
                ring.tail(),
                u64::try_from(complete.len()).expect("bounded tail")
            );
            assert!(
                replay == complete[complete.len() - retained..],
                "overwrite must preserve exact newest byte sequence"
            );
        }
    }

    use super::*;

    #[test]
    fn preserves_order_under_wraps() {
        let mut ring = Ring::new(8);
        for i in 0u8..40 {
            ring.push(&[i]);
        }
        assert_eq!(ring.base(), 32);
        assert_eq!(ring.tail(), 40);
        let (start, bytes) = ring.replay_from(0);
        assert_eq!(start, 32);
        assert_eq!(bytes, (32u8..40).collect::<Vec<u8>>());
    }

    #[test]
    fn replay_from_interior_cursor() {
        let mut ring = Ring::new(1024);
        ring.push(&[1, 2, 3, 4, 5]);
        let (start, bytes) = ring.replay_from(2);
        assert_eq!((start, bytes.as_slice()), (2, &[3u8, 4, 5][..]));
        let (start, bytes) = ring.replay_from(5);
        assert_eq!((start, bytes.as_slice()), (5, &[][..]));
        let (start, bytes) = ring.replay_from(9);
        assert_eq!((start, bytes.as_slice()), (5, &[][..]));
    }

    #[test]
    fn capacity_can_shrink() {
        let mut ring = Ring::new(16);
        ring.push(&[9u8; 32]);
        assert_eq!(ring.base(), 16);
        ring.set_capacity(4);
        assert_eq!(ring.buffer.len(), 4);
        assert_eq!(ring.base(), 28);
        let (start, bytes) = ring.replay_from(0);
        assert_eq!(start, 28);
        assert_eq!(bytes, vec![9, 9, 9, 9]);
    }

    #[test]
    fn random_pushes_match_model() {
        let mut state: u64 = 0x9e3779b97f4a7c15;
        let mut ring = Ring::new(37);
        let mut model: std::collections::VecDeque<u8> = std::collections::VecDeque::new();
        for step in 0..500 {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(step);
            let len = 1 + (state >> 40) as usize % 9;
            let chunk: Vec<u8> = (0..len).map(|i| (state >> (i % 32)) as u8).collect();
            ring.push(&chunk);
            for byte in &chunk {
                model.push_back(*byte);
            }
            while model.len() > 37 {
                model.pop_front();
            }
            assert_eq!(ring.tail(), ring.base() + ring.buffer.len() as u64);
            let (_, replay) = ring.replay_from(ring.base());
            let expected: Vec<u8> = model.iter().copied().collect();
            assert_eq!(replay, expected, "divergence at step {step}");
        }
    }
}
