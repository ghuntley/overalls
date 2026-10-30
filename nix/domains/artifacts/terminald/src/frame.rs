//! Length-prefixed control frames: [magic u8][op u8][len u16 BE][payload].
pub const MAGIC: u8 = 0x4c;
// A 64-session listing includes up to 64 bytes of username per entry.
pub const MAX_PAYLOAD: usize = 8192;

pub const OP_HELLO: u8 = 1;
pub const OP_CREATE: u8 = 2;
pub const OP_LIST: u8 = 3;
pub const OP_KILL: u8 = 4;
pub const OP_RESIZE: u8 = 5;
pub const OP_PING: u8 = 6;
pub const OP_ATTACH: u8 = 10;
pub const OP_RECOVER_TOKEN: u8 = 11;
pub const OP_CREATE_ONCE: u8 = 12;
pub const OP_CREATION_STATUS: u8 = 13;
pub const OP_CANCEL_CREATION: u8 = 14;
pub const OP_USERS: u8 = 15;
pub const OP_OK: u8 = 0x80;
pub const OP_ERR: u8 = 0x81;

pub const ERR_AUTH: u8 = 1;
pub const ERR_NOT_FOUND: u8 = 2;
pub const ERR_BAD_TOKEN: u8 = 3;
pub const ERR_LIMIT: u8 = 4;
pub const ERR_BAD_REQUEST: u8 = 5;
pub const ERR_DEAD: u8 = 6;

#[derive(Debug, PartialEq, Eq)]
pub struct Frame {
    pub op: u8,
    pub payload: Vec<u8>,
}

pub fn encode(op: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 4);
    out.push(MAGIC);
    out.push(op);
    out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// @cc [owner:ghuntley,label:protocol] frame-decode-bounds
/// Decoding MUST reject bad magic and oversized declared payloads once the
/// complete header is available. Incomplete headers or payloads MUST yield
/// `None`. A complete first frame MUST decode only its declared payload;
/// following bytes belong to subsequent frames and remain for the caller.
pub fn decode(buffer: &[u8]) -> Option<Result<Frame, ()>> {
    if buffer.len() < 4 {
        return None;
    }
    if buffer[0] != MAGIC {
        return Some(Err(()));
    }
    let len = u16::from_be_bytes([buffer[2], buffer[3]]) as usize;
    if len > MAX_PAYLOAD {
        return Some(Err(()));
    }
    if buffer.len() < 4 + len {
        return None;
    }
    Some(Ok(Frame {
        op: buffer[1],
        payload: buffer[4..4 + len].to_vec(),
    }))
}

pub fn consumed(payload_len: usize) -> usize {
    payload_len + 4
}

pub struct Reader<'a> {
    buffer: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    pub fn new(payload: &'a [u8]) -> Self {
        Reader {
            buffer: payload,
            offset: 0,
        }
    }

    pub fn remaining(&self) -> usize {
        self.buffer.len() - self.offset
    }

    pub fn u8(&mut self) -> Option<u8> {
        if self.remaining() < 1 {
            return None;
        }
        let value = self.buffer[self.offset];
        self.offset += 1;
        Some(value)
    }

    pub fn u16(&mut self) -> Option<u16> {
        if self.remaining() < 2 {
            return None;
        }
        let value = u16::from_be_bytes([self.buffer[self.offset], self.buffer[self.offset + 1]]);
        self.offset += 2;
        Some(value)
    }

    pub fn u64(&mut self) -> Option<u64> {
        if self.remaining() < 8 {
            return None;
        }
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&self.buffer[self.offset..self.offset + 8]);
        self.offset += 8;
        Some(u64::from_be_bytes(bytes))
    }

    pub fn bytes(&mut self, len: usize) -> Option<&'a [u8]> {
        if self.remaining() < len {
            return None;
        }
        let value = &self.buffer[self.offset..self.offset + len];
        self.offset += len;
        Some(value)
    }

    pub fn string(&mut self, max: usize) -> Option<String> {
        let raw = self.bytes(max)?;
        if raw.is_empty() || raw.contains(&0) {
            return None;
        }
        String::from_utf8(raw.to_vec()).ok()
    }
}

pub fn put_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

pub fn put_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

pub fn put_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_be_bytes());
}

pub fn put_bytes(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(value);
}

#[cfg(test)]
mod tests {
    use super::*;
    use hegel::{generators as gs, TestCase};

    /// @cc [owner:ghuntley,label:verification;protocol] terminal-frame-round-trip
    /// Every op and every payload up to `MAX_PAYLOAD` MUST decode to exactly the
    /// encoded frame, consuming exactly the header and declared payload.
    #[hegel::test(test_cases = 200)]
    fn round_trips_arbitrary_frames(tc: TestCase) {
        let op = tc.draw(gs::integers::<u8>());
        let payload: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(MAX_PAYLOAD));
        let wire = encode(op, &payload);
        match decode(&wire).expect("complete frame") {
            Ok(frame) => {
                assert_eq!(frame.op, op);
                assert!(
                    frame.payload == payload,
                    "decoded payload differs from encoded payload"
                );
                assert_eq!(wire.len(), consumed(payload.len()));
            }
            Err(()) => panic!("valid frame rejected"),
        }
    }

    #[test]
    fn rejects_bad_magic_and_oversize() {
        let mut wire = encode(OP_PING, b"");
        wire[0] = 0x00;
        assert_eq!(decode(&wire), Some(Err(())));
        let mut wire = encode(OP_PING, b"");
        let oversized = u16::try_from(MAX_PAYLOAD + 1).unwrap();
        wire[2..4].copy_from_slice(&oversized.to_be_bytes());
        assert_eq!(decode(&wire), Some(Err(())));
    }

    #[test]
    fn partial_frames_return_none() {
        let wire = encode(OP_CREATE, &[7u8; 100]);
        for cut in 0..wire.len() {
            assert_eq!(decode(&wire[..cut]), None, "cut at {cut}");
        }
    }

    #[test]
    fn reader_enforces_field_bounds() {
        let mut reader = Reader::new(&[1, 2]);
        assert_eq!(reader.u8(), Some(1));
        assert_eq!(reader.u16(), None);
        let mut reader = Reader::new(&[1, 2, 3, 4, 5, 6, 7, 8, 9]);
        assert_eq!(reader.u64(), Some(0x0102030405060708));
        assert_eq!(reader.bytes(2), None);
        assert_eq!(reader.bytes(1), Some(&[9u8][..]));
        assert_eq!(reader.bytes(1), None);
        assert_eq!(Reader::new(&[0xff]).string(1), None);
    }
}
