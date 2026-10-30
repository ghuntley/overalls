//! SHA-256 and HMAC-SHA256 for boot-challenge bound authentication.
const BLOCK: usize = 64;
#[expect(
    clippy::unreadable_literal,
    reason = "the FIPS 180-4 round constants stay in the standard's 8-digit form"
)]
const ROUNDS: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Streaming SHA-256.
pub(crate) struct Sha256 {
    state: [u32; 8],
    buffer: [u8; BLOCK],
    buffered: usize,
    length: u64,
}

impl Sha256 {
    #[expect(
        clippy::unreadable_literal,
        reason = "the FIPS 180-4 initial hash values stay in the standard's 8-digit form"
    )]
    pub(crate) fn new() -> Self {
        Sha256 {
            state: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            buffer: [0; BLOCK],
            buffered: 0,
            length: 0,
        }
    }

    pub(crate) fn update(&mut self, mut data: &[u8]) {
        self.length = self.length.wrapping_add(data.len() as u64);
        if self.buffered > 0 {
            let need = BLOCK - self.buffered;
            let take = need.min(data.len());
            self.buffer[self.buffered..self.buffered + take].copy_from_slice(&data[..take]);
            self.buffered += take;
            data = &data[take..];
            if self.buffered == BLOCK {
                let block = self.buffer;
                self.compress(&block);
                self.buffered = 0;
            }
        }
        while data.len() >= BLOCK {
            let mut block = [0u8; BLOCK];
            block.copy_from_slice(&data[..BLOCK]);
            self.compress(&block);
            data = &data[BLOCK..];
        }
        if !data.is_empty() {
            self.buffer[..data.len()].copy_from_slice(data);
            self.buffered = data.len();
        }
    }

    pub(crate) fn finish(mut self) -> [u8; 32] {
        let bits = self.length.wrapping_mul(8);
        self.update(&[0x80]);
        while self.buffered != 56 {
            self.update(&[0]);
        }
        self.length = 0;
        let mut tail = [0u8; 8];
        tail.copy_from_slice(&bits.to_be_bytes());
        self.update(&tail);
        let mut out = [0u8; 32];
        for (i, word) in self.state.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }

    fn compress(&mut self, block: &[u8; BLOCK]) {
        let mut w = [0u32; 64];
        for (i, chunk) in block.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(*chunk);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut h = self.state;
        for i in 0..64 {
            let s1 = h[4].rotate_right(6) ^ h[4].rotate_right(11) ^ h[4].rotate_right(25);
            let choose = (h[4] & h[5]) ^ ((!h[4]) & h[6]);
            let t1 = h[7]
                .wrapping_add(s1)
                .wrapping_add(choose)
                .wrapping_add(ROUNDS[i])
                .wrapping_add(w[i]);
            let s0 = h[0].rotate_right(2) ^ h[0].rotate_right(13) ^ h[0].rotate_right(22);
            let majority = (h[0] & h[1]) ^ (h[0] & h[2]) ^ (h[1] & h[2]);
            let t2 = s0.wrapping_add(majority);
            h[7] = h[6];
            h[6] = h[5];
            h[5] = h[4];
            h[4] = h[3].wrapping_add(t1);
            h[3] = h[2];
            h[2] = h[1];
            h[1] = h[0];
            h[0] = t1.wrapping_add(t2);
        }
        for (state, delta) in self.state.iter_mut().zip(h) {
            *state = state.wrapping_add(delta);
        }
    }
}

/// @cc [owner:ghuntley,label:security] hmac-proof-binding
/// `authenticate` MUST accept only the exact tag produced by this key over this
/// message; it compares in constant time and never accepts a truncated tag.
pub(crate) struct Hmac {
    inner: Sha256,
    outer: Sha256,
}

impl Hmac {
    pub(crate) fn new(key: &[u8]) -> Self {
        let mut block = [0u8; BLOCK];
        if key.len() > BLOCK {
            block[..32].copy_from_slice(&Sha256::new().chained_update(key).finish());
        } else {
            block[..key.len()].copy_from_slice(key);
        }
        let mut inner = Sha256::new();
        let mut outer = Sha256::new();
        for byte in &block {
            inner.update(&[byte ^ 0x36]);
            outer.update(&[byte ^ 0x5c]);
        }
        Hmac { inner, outer }
    }

    pub(crate) fn update(&mut self, data: &[u8]) {
        self.inner.update(data);
    }

    pub(crate) fn finish(self) -> [u8; 32] {
        let inner = self.inner.finish();
        let mut outer = self.outer;
        outer.update(&inner);
        outer.finish()
    }
}

pub(crate) fn digest(parts: &[&[u8]]) -> [u8; 32] {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update(part);
    }
    hash.finish()
}

pub(crate) fn tag(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut mac = Hmac::new(key);
    for part in parts {
        mac.update(part);
    }
    mac.finish()
}

pub(crate) fn constant_time_equal(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

trait Chained {
    fn chained_update(self, data: &[u8]) -> Self;
}

impl Chained for Sha256 {
    fn chained_update(mut self, data: &[u8]) -> Self {
        self.update(data);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        use std::fmt::Write as _;
        bytes.iter().fold(String::new(), |mut text, b| {
            let _ = write!(text, "{b:02x}");
            text
        })
    }

    #[test]
    fn sha256_vectors() {
        assert_eq!(
            hex(&digest(&[b"abc"])),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex(&digest(&[b""])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let million = vec![b'a'; 1_000_000];
        assert_eq!(
            hex(&digest(&[&million])),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    #[test]
    fn hmac_vectors() {
        assert_eq!(
            hex(&tag(b"Jefe", &[b"what do ya want for nothing?"])),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        let key45 = [0xaa; 20];
        let data = [0xdd; 50];
        assert_eq!(
            hex(&tag(&key45, &[&data])),
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
        );
    }

    #[test]
    fn hmac_incremental_matches_oneshot() {
        let parts: [&[u8]; 3] = [b"alpha", b"beta", b"gamma"];
        let mut mac = Hmac::new(b"secret-key-material");
        for part in parts {
            mac.update(part);
        }
        assert_eq!(mac.finish(), tag(b"secret-key-material", &parts));
    }

    #[test]
    fn long_keys_differ_from_their_prefix() {
        let long = vec![0x11; 200];
        let short = long[..64].to_vec();
        assert_eq!(tag(&long, &[b"payload"]), tag(&long, &[b"payload"]));
        assert_ne!(tag(&long, &[b"payload"]), tag(&short, &[b"payload"]));
    }

    #[test]
    fn comparisons_reject_length_and_bit_differences() {
        assert!(constant_time_equal(b"same", b"same"));
        assert!(!constant_time_equal(b"same", b"samf"));
        assert!(!constant_time_equal(b"same", b"sam"));
    }
}
