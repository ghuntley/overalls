//! Host-side PTY byte decoding and key encoding for the GTK terminal surface.
//!
//! PTY output bytes are decoded here, inside the host transport, into display
//! text the bounded renderer accepts. GTK receives only that text. Key events
//! are encoded into the bytes a remote PTY expects; GTK never builds escape
//! sequences itself.

/// Longest control sequence retained before the decoder abandons it.
const MAX_CSI_BYTES: usize = 64;
/// Longest string-terminated sequence (OSC, DCS, APC, PM, SOS) retained.
const MAX_STRING_BYTES: usize = 4_096;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum EscapeState {
    #[default]
    Ground,
    Escape,
    Intermediate,
    Csi(usize),
    String(usize),
    StringEscape(usize),
}

/// @cc [owner:ghuntley,label:security;terminal] linux-pty-text-decoder-bounded
/// Decoding MUST be independent of how the byte stream is split into chunks,
/// MUST drop escape sequences and every control character other than newline,
/// carriage return, tab and backspace, MUST replace invalid UTF-8 with U+FFFD,
/// and MUST retain at most a bounded partial sequence between chunks.
///
/// Stateful decoder from raw PTY bytes to renderer-safe display text.
#[derive(Clone, Debug, Default)]
pub struct PtyTextDecoder {
    escape: EscapeState,
    pending: Vec<u8>,
}

impl PtyTextDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Decodes one chunk. Partial UTF-8 and escape sequences carry over.
    pub fn decode(&mut self, bytes: &[u8]) -> String {
        let mut text = Vec::with_capacity(bytes.len());
        for &byte in bytes {
            self.escape = match self.escape {
                EscapeState::Ground if byte == 0x1b => EscapeState::Escape,
                EscapeState::Ground => {
                    text.push(byte);
                    EscapeState::Ground
                }
                EscapeState::Escape => match byte {
                    b'[' => EscapeState::Csi(0),
                    b']' | b'P' | b'X' | b'^' | b'_' => EscapeState::String(0),
                    b'(' | b')' | b'*' | b'+' | b'-' | b'.' | b'/' | b'#' | b'%' => {
                        EscapeState::Intermediate
                    }
                    0x1b => EscapeState::Escape,
                    _ => EscapeState::Ground,
                },
                EscapeState::Intermediate => EscapeState::Ground,
                EscapeState::Csi(length) => {
                    if (0x40..=0x7e).contains(&byte) || length >= MAX_CSI_BYTES {
                        EscapeState::Ground
                    } else {
                        EscapeState::Csi(length + 1)
                    }
                }
                EscapeState::String(length) => match byte {
                    0x07 => EscapeState::Ground,
                    0x1b => EscapeState::StringEscape(length),
                    _ if length >= MAX_STRING_BYTES => EscapeState::Ground,
                    _ => EscapeState::String(length + 1),
                },
                EscapeState::StringEscape(length) => {
                    if byte == b'\\' {
                        EscapeState::Ground
                    } else {
                        EscapeState::String(length + 1)
                    }
                }
            };
        }
        let mut input = std::mem::take(&mut self.pending);
        input.extend_from_slice(&text);
        let mut output = String::with_capacity(input.len());
        let mut rest = input.as_slice();
        loop {
            match std::str::from_utf8(rest) {
                Ok(valid) => {
                    push_display(&mut output, valid);
                    break;
                }
                Err(error) => {
                    let (valid, after) = rest.split_at(error.valid_up_to());
                    push_display(
                        &mut output,
                        std::str::from_utf8(valid).expect("prefix is valid UTF-8"),
                    );
                    match error.error_len() {
                        Some(length) => {
                            output.push(char::REPLACEMENT_CHARACTER);
                            rest = &after[length..];
                        }
                        None => {
                            // An incomplete trailing sequence is at most three bytes.
                            self.pending = after.to_vec();
                            break;
                        }
                    }
                }
            }
        }
        output
    }
}

fn push_display(output: &mut String, text: &str) {
    output.extend(text.chars().filter(|character| {
        matches!(character, '\n' | '\r' | '\t' | '\u{8}') || !character.is_control()
    }));
}

/// A key press the GTK surface forwards to the remote PTY.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalKey {
    Text(char),
    Control(char),
    Enter,
    Backspace,
    Tab,
    Escape,
    Up,
    Down,
    Right,
    Left,
    Home,
    End,
    Delete,
    PageUp,
    PageDown,
}

/// @cc [owner:ghuntley,label:security;terminal] linux-terminal-key-encoding-closed
/// Key encoding MUST map only the closed `TerminalKey` set to PTY bytes;
/// `Text` MUST refuse control characters and `Control` MUST accept only the
/// ASCII control-key range, so GTK cannot inject arbitrary escape sequences.
pub fn encode_key(key: TerminalKey) -> Option<Vec<u8>> {
    let bytes: &[u8] = match key {
        TerminalKey::Text(character) if character.is_control() => return None,
        TerminalKey::Text(character) => {
            let mut buffer = [0_u8; 4];
            return Some(character.encode_utf8(&mut buffer).as_bytes().to_vec());
        }
        TerminalKey::Control(character) => {
            let lower = character.to_ascii_lowercase();
            let code = match lower {
                'a'..='z' => lower as u8 - b'a' + 1,
                '@' | ' ' | '2' => 0,
                '[' => 0x1b,
                '\\' => 0x1c,
                ']' => 0x1d,
                '^' => 0x1e,
                '_' => 0x1f,
                _ => return None,
            };
            return Some(vec![code]);
        }
        TerminalKey::Enter => b"\r",
        TerminalKey::Backspace => b"\x7f",
        TerminalKey::Tab => b"\t",
        TerminalKey::Escape => b"\x1b",
        TerminalKey::Up => b"\x1b[A",
        TerminalKey::Down => b"\x1b[B",
        TerminalKey::Right => b"\x1b[C",
        TerminalKey::Left => b"\x1b[D",
        TerminalKey::Home => b"\x1b[H",
        TerminalKey::End => b"\x1b[F",
        TerminalKey::Delete => b"\x1b[3~",
        TerminalKey::PageUp => b"\x1b[5~",
        TerminalKey::PageDown => b"\x1b[6~",
    };
    Some(bytes.to_vec())
}

#[cfg(test)]
mod tests {
    use super::{encode_key, PtyTextDecoder, TerminalKey};
    use crate::terminal::TerminalRenderer;

    const SAMPLES: &[&[u8]] = &[
        b"plain\r\nline two\r\n",
        b"\x1b[1;32mgreen\x1b[0m done\r\n",
        b"\x1b]0;window title\x07prompt$ ",
        b"\x1b]8;;https://example.test\x1b\\link\x1b]8;;\x1b\\ ok",
        b"\x1b(Bcharset\x1b=keypad\x1b>",
        "caf\u{e9} \u{1f600} \u{65e5}\u{672c}\r\n".as_bytes(),
        b"bad \xff\xfe utf8 \xe2\x82",
        b"bell\x07 and \x00nul and \x7fdel\x08\tTab",
        b"\x1bP1;2|dcs payload\x1b\\after",
    ];

    fn whole(bytes: &[u8]) -> String {
        PtyTextDecoder::new().decode(bytes)
    }

    #[test]
    fn decodes_escape_sequences_to_display_text() {
        assert_eq!(whole(SAMPLES[0]), "plain\r\nline two\r\n");
        assert_eq!(whole(SAMPLES[1]), "green done\r\n");
        assert_eq!(whole(SAMPLES[2]), "prompt$ ");
        assert_eq!(whole(SAMPLES[3]), "link ok");
        assert_eq!(whole(SAMPLES[4]), "charsetkeypad");
        assert_eq!(whole(SAMPLES[8]), "after");
        assert_eq!(whole(SAMPLES[7]), "bell and nul and del\u{8}\tTab");
        assert_eq!(whole(b"bad \xff ok"), "bad \u{fffd} ok");
    }

    /// Exhaustive split invariance: every one- and two-cut partition of each
    /// sample decodes to the same text as the unsplit stream.
    #[test]
    fn decoding_is_independent_of_chunk_boundaries() {
        let stream = SAMPLES.concat();
        let expected = whole(&stream);
        for first in 0..=stream.len() {
            let mut decoder = PtyTextDecoder::new();
            let mut text = decoder.decode(&stream[..first]);
            text.push_str(&decoder.decode(&stream[first..]));
            assert_eq!(text, expected, "split at {first}");
        }
        for sample in SAMPLES {
            let expected = whole(sample);
            for first in 0..=sample.len() {
                for second in first..=sample.len() {
                    let mut decoder = PtyTextDecoder::new();
                    let mut text = decoder.decode(&sample[..first]);
                    text.push_str(&decoder.decode(&sample[first..second]));
                    text.push_str(&decoder.decode(&sample[second..]));
                    assert_eq!(text, expected, "splits at {first},{second}");
                }
            }
        }
    }

    /// Every byte value, alone and after an escape introducer, decodes to text
    /// the bounded renderer accepts; the carried state stays bounded.
    #[test]
    fn every_byte_yields_renderer_safe_text_with_bounded_state() {
        for prefix in [&b""[..], b"\x1b", b"\x1b[", b"\x1b]", b"\xe2", b"\xf0\x9f"] {
            for byte in 0_u8..=255 {
                let mut decoder = PtyTextDecoder::new();
                let mut input = prefix.to_vec();
                input.push(byte);
                let text = decoder.decode(&input);
                let mut renderer = TerminalRenderer::new(80, 24).unwrap();
                assert!(renderer.append_text(&text).is_ok(), "{prefix:?} {byte}");
                assert!(decoder.pending.len() <= 3);
            }
        }
        let mut decoder = PtyTextDecoder::new();
        let mut unterminated = b"\x1b]".to_vec();
        unterminated.extend(std::iter::repeat_n(b'x', 10_000));
        let text = decoder.decode(&unterminated);
        assert!(text.len() < 10_000 - super::MAX_STRING_BYTES + 1);
    }

    #[test]
    fn key_encoding_is_closed() {
        assert_eq!(encode_key(TerminalKey::Text('a')), Some(b"a".to_vec()));
        assert_eq!(
            encode_key(TerminalKey::Text('\u{e9}')),
            Some("\u{e9}".as_bytes().to_vec())
        );
        assert_eq!(encode_key(TerminalKey::Text('\u{1b}')), None);
        assert_eq!(encode_key(TerminalKey::Text('\n')), None);
        assert_eq!(encode_key(TerminalKey::Control('c')), Some(vec![3]));
        assert_eq!(encode_key(TerminalKey::Control('D')), Some(vec![4]));
        assert_eq!(encode_key(TerminalKey::Control('1')), None);
        assert_eq!(encode_key(TerminalKey::Enter), Some(b"\r".to_vec()));
        assert_eq!(encode_key(TerminalKey::Up), Some(b"\x1b[A".to_vec()));
        for character in (0_u32..0x300).filter_map(char::from_u32) {
            if let Some(bytes) = encode_key(TerminalKey::Text(character)) {
                assert!(!bytes.contains(&0x1b) && bytes.iter().all(|b| *b >= 0x20 && *b != 0x7f));
            }
        }
    }
}
