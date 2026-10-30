//! Typed values shared by Mila's protocol, runtime and platform bindings.
//! The model deliberately has no retired client or transport dependency.

mod error;
mod identifier;
mod platform;
mod request_id;
mod route;
mod source;

pub use error::ModelError;
pub use identifier::Identifier;
pub use platform::DevicePlatform;
pub use request_id::RequestId;
pub use route::{MilaPage, MilaRoute};
pub use source::WorkspaceSource;

const MAX_ROUTE_BYTES: usize = 2_048;
const REQUEST_PREFIX: &str = "porsche-";

fn decode_component(value: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let raw = value.as_bytes();
    let mut index = 0;
    while index < raw.len() {
        if raw[index] == b'%' {
            if index + 2 >= raw.len() {
                return None;
            }
            let high = (raw[index + 1] as char).to_digit(16)? as u8;
            let low = (raw[index + 2] as char).to_digit(16)? as u8;
            bytes.push(high * 16 + low);
            index += 3;
        } else {
            bytes.push(if raw[index] == b'+' { b' ' } else { raw[index] });
            index += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn encode_component(value: &str) -> String {
    value.bytes().fold(String::new(), |mut output, byte| {
        if byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte) {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(char::from(b"0123456789ABCDEF"[(byte >> 4) as usize]));
            output.push(char::from(b"0123456789ABCDEF"[(byte & 0xf) as usize]));
        }
        output
    })
}

#[cfg(test)]
mod tests;
