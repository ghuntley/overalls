/// Connlabel bits as returned by the kernel; Lilly requires the bit-127 marker
/// and renders the label big-endian.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Labels(pub(crate) [u8; 16]);

impl Labels {
    pub(crate) fn zero() -> Self {
        Self([0; 16])
    }

    pub(crate) fn set(&mut self, bit: u32) {
        if bit < 128 {
            let byte = 15 - (bit / 8) as usize;
            self.0[byte] |= 1 << (bit % 8);
        }
    }

    pub fn to_hex(&self) -> String {
        let mut out = String::with_capacity(32);
        for byte in self.0 {
            out.push(char::from_digit(u32::from(byte >> 4), 16).expect("hex"));
            out.push(char::from_digit(u32::from(byte & 0x0f), 16).expect("hex"));
        }
        out
    }
}
