//! Bounded VT presentation shared by native terminal surfaces.
//!
//! The parser intentionally keeps a compact, table-driven implementation. The
//! listed clippy exceptions cover display protocol constants and state-machine
//! shape; all external bounds remain explicit below.
#![allow(
    clippy::unreadable_literal,
    clippy::struct_excessive_bools,
    clippy::too_many_lines,
    clippy::semicolon_if_nothing_returned,
    clippy::items_after_statements,
    clippy::precedence,
    reason = "The bounded VT parser keeps protocol constants and state transitions together."
)]
use serde::{Deserialize, Serialize};

const MAX_CELLS: usize = 16_384;
const MAX_SEQUENCE: usize = 128;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalStyle {
    pub foreground: Option<u32>,
    pub background: Option<u32>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalSpan {
    pub text: String,
    #[serde(flatten)]
    pub style: TerminalStyle,
}

/// A display-only projection. It contains no escape sequences or executable links.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalFrame {
    pub version: u8,
    pub columns: u16,
    pub rows: u16,
    pub cursor_column: u16,
    pub cursor_row: u16,
    pub lines: Vec<Vec<TerminalSpan>>,
    #[serde(default)]
    pub images: Vec<TerminalImage>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalImage {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<u32>,
}

#[derive(Clone, Copy, Debug)]
struct Cell {
    character: char,
    style: TerminalStyle,
}
impl Default for Cell {
    fn default() -> Self {
        Self {
            character: ' ',
            style: TerminalStyle::default(),
        }
    }
}

#[derive(Debug, Default)]
enum ParseState {
    #[default]
    Ground,
    Escape,
    Charset,
    Csi(Vec<u8>),
    DiscardCsi,
    String,
    StringEscape,
    Sixel(Vec<u8>),
    SixelEscape(Vec<u8>),
}

/// @cc [owner:ghuntley,label:security;terminal] native-terminal-screen-bounds
/// The screen MUST retain at most 16384 cells per buffer, a 128-byte CSI and
/// three incomplete UTF-8 bytes. OSC/DCS/APC payloads MUST be discarded through
/// their terminator without storing them, opening URLs or executing commands.
/// Native consumers MUST receive only decoded text and closed style fields.
#[derive(Debug)]
pub struct TerminalScreen {
    columns: usize,
    rows: usize,
    cells: Vec<Cell>,
    primary: Option<(Vec<Cell>, usize, usize)>,
    column: usize,
    row: usize,
    saved: (usize, usize),
    top: usize,
    bottom: usize,
    style: TerminalStyle,
    parser: ParseState,
    utf8: Vec<u8>,
    images: Vec<TerminalImage>,
}

impl TerminalScreen {
    pub fn new(columns: u32, rows: u32) -> Option<Self> {
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return None;
        }
        let columns = usize::try_from(columns).ok()?;
        let rows = usize::try_from(rows).ok()?.min(MAX_CELLS / columns);
        Some(Self {
            columns,
            rows,
            cells: vec![Cell::default(); columns * rows],
            primary: None,
            column: 0,
            row: 0,
            saved: (0, 0),
            top: 0,
            bottom: rows - 1,
            style: TerminalStyle::default(),
            parser: ParseState::Ground,
            utf8: Vec::new(),
            images: Vec::new(),
        })
    }

    pub fn resize(&mut self, columns: u32, rows: u32) -> bool {
        let Some(mut next) = Self::new(columns, rows) else {
            return false;
        };
        for row in 0..self.rows.min(next.rows) {
            for column in 0..self.columns.min(next.columns) {
                next.cells[row * next.columns + column] = self.cells[row * self.columns + column];
            }
        }
        next.column = self.column.min(next.columns - 1);
        next.row = self.row.min(next.rows - 1);
        next.style = self.style;
        next.parser = std::mem::take(&mut self.parser);
        next.utf8 = std::mem::take(&mut self.utf8);
        next.images = std::mem::take(&mut self.images);
        *self = next;
        true
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            let state = std::mem::take(&mut self.parser);
            self.parser = match state {
                ParseState::Ground => {
                    self.ground(byte);
                    std::mem::take(&mut self.parser)
                }
                ParseState::Escape => match byte {
                    b'[' => ParseState::Csi(Vec::new()),
                    b']' | b'X' | b'^' | b'_' => ParseState::String,
                    b'P' => ParseState::Sixel(Vec::new()),
                    b'(' | b')' | b'*' | b'+' | b'%' | b'#' => ParseState::Charset,
                    b'7' => {
                        self.saved = (self.column, self.row);
                        ParseState::Ground
                    }
                    b'8' => {
                        (self.column, self.row) = self.saved;
                        ParseState::Ground
                    }
                    b'D' => {
                        self.line_feed();
                        ParseState::Ground
                    }
                    b'M' => {
                        self.reverse_index();
                        ParseState::Ground
                    }
                    b'E' => {
                        self.column = 0;
                        self.line_feed();
                        ParseState::Ground
                    }
                    b'c' => {
                        self.cells.fill(Cell::default());
                        self.column = 0;
                        self.row = 0;
                        self.style = TerminalStyle::default();
                        ParseState::Ground
                    }
                    0x1b => ParseState::Escape,
                    _ => ParseState::Ground,
                },
                ParseState::Charset => ParseState::Ground,
                ParseState::Csi(mut sequence) => {
                    if (0x40..=0x7e).contains(&byte) {
                        self.csi(&sequence, byte);
                        ParseState::Ground
                    } else if sequence.len() < MAX_SEQUENCE {
                        sequence.push(byte);
                        ParseState::Csi(sequence)
                    } else {
                        ParseState::DiscardCsi
                    }
                }
                ParseState::DiscardCsi => {
                    if (0x40..=0x7e).contains(&byte) {
                        ParseState::Ground
                    } else {
                        ParseState::DiscardCsi
                    }
                }
                ParseState::String => match byte {
                    0x07 => ParseState::Ground,
                    0x1b => ParseState::StringEscape,
                    _ => ParseState::String,
                },
                ParseState::StringEscape => match byte {
                    b'\\' | 0x07 => ParseState::Ground,
                    0x1b => ParseState::StringEscape,
                    _ => ParseState::String,
                },
                ParseState::Sixel(mut payload) => match byte {
                    0x1b => ParseState::SixelEscape(payload),
                    _ if payload.len() < (1 << 20) => {
                        payload.push(byte);
                        ParseState::Sixel(payload)
                    }
                    _ => ParseState::String,
                },
                ParseState::SixelEscape(payload) => match byte {
                    b'\\' => {
                        self.decode_sixel(&payload);
                        ParseState::Ground
                    }
                    0x1b => ParseState::SixelEscape(payload),
                    _ => ParseState::Sixel(payload),
                },
            };
        }
    }

    fn ground(&mut self, byte: u8) {
        if byte < 0x80 {
            if !self.utf8.is_empty() {
                self.utf8.clear();
                self.put(char::REPLACEMENT_CHARACTER);
            }
            match byte {
                0x1b => self.parser = ParseState::Escape,
                b'\r' => self.column = 0,
                b'\n' | 0x0b | 0x0c => self.line_feed(),
                b'\t' => self.column = ((self.column / 8 + 1) * 8).min(self.columns - 1),
                0x08 => self.column = self.column.saturating_sub(1),
                0x20..=0x7e => self.put(char::from(byte)),
                _ => {}
            }
            return;
        }
        if !self.utf8.is_empty() && byte & 0xc0 != 0x80 {
            self.utf8.clear();
            self.put(char::REPLACEMENT_CHARACTER);
        }
        self.utf8.push(byte);
        match std::str::from_utf8(&self.utf8) {
            Ok(text) => {
                let character = text.chars().next();
                self.utf8.clear();
                if let Some(character) = character.filter(|value| !value.is_control()) {
                    self.put(character);
                }
            }
            Err(error) if error.error_len().is_some() || self.utf8.len() >= 4 => {
                self.utf8.clear();
                self.put(char::REPLACEMENT_CHARACTER);
            }
            Err(_) => {}
        }
    }

    fn put(&mut self, character: char) {
        if self.column >= self.columns {
            self.column = 0;
            self.line_feed();
        }
        self.cells[self.row * self.columns + self.column] = Cell {
            character,
            style: self.style,
        };
        self.column += 1;
    }

    fn line_feed(&mut self) {
        if self.row == self.bottom {
            self.scroll_up(1);
        } else {
            self.row = (self.row + 1).min(self.rows - 1);
        }
    }

    fn reverse_index(&mut self) {
        if self.row == self.top {
            self.scroll_down(1);
        } else {
            self.row = self.row.saturating_sub(1);
        }
    }

    fn scroll_up(&mut self, count: usize) {
        let count = count.min(self.bottom - self.top + 1);
        self.cells.copy_within(
            (self.top + count) * self.columns..(self.bottom + 1) * self.columns,
            self.top * self.columns,
        );
        self.cells[(self.bottom + 1 - count) * self.columns..(self.bottom + 1) * self.columns]
            .fill(Cell::default());
    }

    fn scroll_down(&mut self, count: usize) {
        let count = count.min(self.bottom - self.top + 1);
        self.cells.copy_within(
            self.top * self.columns..(self.bottom + 1 - count) * self.columns,
            (self.top + count) * self.columns,
        );
        self.cells[self.top * self.columns..(self.top + count) * self.columns]
            .fill(Cell::default());
    }

    fn csi(&mut self, bytes: &[u8], final_byte: u8) {
        let private = bytes.first() == Some(&b'?');
        let bytes = if private { &bytes[1..] } else { bytes };
        let Ok(text) = std::str::from_utf8(bytes) else {
            return;
        };
        let Some(values) = text
            .split(';')
            .map(|part| {
                if part.is_empty() {
                    Some(0)
                } else {
                    part.parse::<usize>().ok()
                }
            })
            .collect::<Option<Vec<_>>>()
        else {
            return;
        };
        let value = |index: usize, default: usize| {
            values
                .get(index)
                .copied()
                .filter(|value| *value != 0)
                .unwrap_or(default)
        };
        if private {
            if values == [1049] && matches!(final_byte, b'h' | b'l') {
                if final_byte == b'h' && self.primary.is_none() {
                    self.primary = Some((
                        std::mem::replace(
                            &mut self.cells,
                            vec![Cell::default(); self.columns * self.rows],
                        ),
                        self.column,
                        self.row,
                    ));
                    self.column = 0;
                    self.row = 0;
                } else if final_byte == b'l' {
                    if let Some((cells, column, row)) = self.primary.take() {
                        self.cells = cells;
                        self.column = column;
                        self.row = row;
                    }
                }
            }
            return;
        }
        match final_byte {
            b'A' => self.row = self.row.saturating_sub(value(0, 1)),
            b'B' | b'e' => self.row = self.row.saturating_add(value(0, 1)).min(self.rows - 1),
            b'C' | b'a' => {
                self.column = self
                    .column
                    .saturating_add(value(0, 1))
                    .min(self.columns - 1)
            }
            b'D' => self.column = self.column.saturating_sub(value(0, 1)),
            b'E' => {
                self.row = self.row.saturating_add(value(0, 1)).min(self.rows - 1);
                self.column = 0;
            }
            b'F' => {
                self.row = self.row.saturating_sub(value(0, 1));
                self.column = 0;
            }
            b'G' | b'`' => self.column = value(0, 1).saturating_sub(1).min(self.columns - 1),
            b'd' => self.row = value(0, 1).saturating_sub(1).min(self.rows - 1),
            b'H' | b'f' => {
                self.row = value(0, 1).saturating_sub(1).min(self.rows - 1);
                self.column = value(1, 1).saturating_sub(1).min(self.columns - 1);
            }
            b'J' => {
                let cursor = (self.row * self.columns + self.column).min(self.cells.len() - 1);
                match values[0] {
                    0 => self.cells[cursor..].fill(Cell::default()),
                    1 => self.cells[..=cursor].fill(Cell::default()),
                    2 | 3 => self.cells.fill(Cell::default()),
                    _ => {}
                }
            }
            b'K' => {
                let start = self.row * self.columns;
                let column = self.column.min(self.columns - 1);
                match values[0] {
                    0 => self.cells[start + column..start + self.columns].fill(Cell::default()),
                    1 => self.cells[start..=start + column].fill(Cell::default()),
                    2 => self.cells[start..start + self.columns].fill(Cell::default()),
                    _ => {}
                }
            }
            b'X' => {
                let start = self.row * self.columns + self.column.min(self.columns - 1);
                let end = start
                    .saturating_add(value(0, 1))
                    .min((self.row + 1) * self.columns);
                self.cells[start..end].fill(Cell::default());
            }
            b'S' => self.scroll_up(value(0, 1)),
            b'T' => self.scroll_down(value(0, 1)),
            b'r' => {
                let top = value(0, 1) - 1;
                let bottom = value(1, self.rows) - 1;
                if top < bottom && bottom < self.rows {
                    self.top = top;
                    self.bottom = bottom;
                    self.row = 0;
                    self.column = 0;
                }
            }
            b's' => self.saved = (self.column.min(self.columns - 1), self.row),
            b'u' => (self.column, self.row) = self.saved,
            b'm' => self.sgr(&values),
            _ => {}
        }
    }

    fn decode_sixel(&mut self, payload: &[u8]) {
        const SIDE: usize = 1024;
        const MAX_PIXELS: usize = 1 << 20;
        let mut pixels = vec![0_u32; MAX_PIXELS];
        let mut palette = [0_u32; 256];
        const BASE: [u32; 16] = [
            0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
            0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
        ];
        palette[..16].copy_from_slice(&BASE);
        let mut width = 0;
        let mut height = 0;
        let mut x = 0;
        let mut y = 0;
        let mut color = 15;
        let mut repeat = 1;
        let mut index = usize::from(payload.first() == Some(&b'q'));
        while index < payload.len() {
            match payload[index] {
                b'?'..=b'~' => {
                    let value = palette[color];
                    let sixel = payload[index].saturating_sub(63);
                    for _ in 0..repeat {
                        for bit in 0..6 {
                            if sixel & (1 << bit) != 0 {
                                let px = x;
                                let py = y + bit;
                                if px < SIDE && py < SIDE {
                                    pixels[py * SIDE + px] = value;
                                    width = width.max(px + 1);
                                    height = height.max(py + 1);
                                }
                            }
                        }
                        x = x.saturating_add(1);
                    }
                    repeat = 1;
                    index += 1;
                }
                b'!' => {
                    index += 1;
                    let start = index;
                    while index < payload.len() && payload[index].is_ascii_digit() {
                        index += 1;
                    }
                    repeat = std::str::from_utf8(&payload[start..index])
                        .ok()
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(1_usize)
                        .min(1024);
                }
                b'$' => {
                    x = 0;
                    index += 1;
                }
                b'-' => {
                    x = 0;
                    y = y.saturating_add(6);
                    index += 1;
                }
                b'#' => {
                    index += 1;
                    let start = index;
                    while index < payload.len() && payload[index].is_ascii_digit() {
                        index += 1;
                    }
                    color = std::str::from_utf8(&payload[start..index])
                        .ok()
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0_usize)
                        .min(255);
                    if index < payload.len() && payload[index] == b';' {
                        let mut values = Vec::new();
                        while index < payload.len() && values.len() < 5 {
                            index += 1;
                            let start = index;
                            while index < payload.len() && payload[index].is_ascii_digit() {
                                index += 1;
                            }
                            values.push(
                                std::str::from_utf8(&payload[start..index])
                                    .ok()
                                    .and_then(|v| v.parse::<u32>().ok())
                                    .unwrap_or(0),
                            );
                            if index >= payload.len() || payload[index] != b';' {
                                break;
                            }
                        }
                        if values.len() >= 4 && values[0] == 2 {
                            palette[color] = ((values[1].min(100) * 255 / 100) << 16)
                                | ((values[2].min(100) * 255 / 100) << 8)
                                | (values[3].min(100) * 255 / 100);
                        }
                    }
                }
                b'"' => {
                    index += 1;
                    while index < payload.len() && payload[index] != b';' {
                        index += 1;
                    }
                }
                _ => index += 1,
            }
        }
        if width == 0 || height == 0 || width * height > MAX_PIXELS {
            return;
        }
        let mut compact = Vec::with_capacity(width * height);
        for row in 0..height {
            compact.extend_from_slice(&pixels[row * SIDE..row * SIDE + width]);
        }
        let current_pixels = self
            .images
            .iter()
            .map(|image| image.pixels.len())
            .sum::<usize>();
        if current_pixels.saturating_add(compact.len()) > (1 << 20) {
            return;
        }
        self.images.push(TerminalImage {
            x: u16::try_from(self.column.saturating_mul(8)).unwrap_or(u16::MAX),
            y: u16::try_from(self.row.saturating_mul(16)).unwrap_or(u16::MAX),
            width: u16::try_from(width).unwrap_or(u16::MAX),
            height: u16::try_from(height).unwrap_or(u16::MAX),
            pixels: compact,
        });
        if self.images.len() > 8 {
            self.images.remove(0);
        }
    }

    fn sgr(&mut self, values: &[usize]) {
        let mut index = 0;
        while index < values.len() {
            let value = values[index];
            match value {
                0 => self.style = TerminalStyle::default(),
                1 => self.style.bold = true,
                3 => self.style.italic = true,
                4 => self.style.underline = true,
                7 => self.style.inverse = true,
                22 => self.style.bold = false,
                23 => self.style.italic = false,
                24 => self.style.underline = false,
                27 => self.style.inverse = false,
                30..=37 | 90..=97 => {
                    self.style.foreground = palette(if value >= 90 {
                        value - 90 + 8
                    } else {
                        value - 30
                    })
                }
                40..=47 | 100..=107 => {
                    self.style.background = palette(if value >= 100 {
                        value - 100 + 8
                    } else {
                        value - 40
                    })
                }
                39 => self.style.foreground = None,
                49 => self.style.background = None,
                38 | 48 => {
                    let color = if values.get(index + 1) == Some(&5) {
                        let color = values.get(index + 2).copied().and_then(palette);
                        index = (index + 2).min(values.len());
                        color
                    } else if values.get(index + 1) == Some(&2) && values.len() > index + 4 {
                        let rgb = &values[index + 2..index + 5];
                        index += 4;
                        if rgb.iter().all(|channel| *channel <= 255) {
                            u32::try_from((rgb[0] << 16) | (rgb[1] << 8) | rgb[2]).ok()
                        } else {
                            None
                        }
                    } else {
                        None
                    };
                    if value == 38 {
                        self.style.foreground = color;
                    } else {
                        self.style.background = color;
                    }
                }
                _ => {}
            }
            index += 1;
        }
    }

    pub fn frame(&self) -> TerminalFrame {
        let mut lines = Vec::with_capacity(self.rows);
        for cells in self.cells.chunks_exact(self.columns) {
            let mut spans: Vec<TerminalSpan> = Vec::new();
            let last = cells
                .iter()
                .rposition(|cell| cell.character != ' ' || cell.style != TerminalStyle::default())
                .map_or(0, |index| index + 1);
            for cell in &cells[..last] {
                if let Some(span) = spans.last_mut().filter(|span| span.style == cell.style) {
                    span.text.push(cell.character);
                } else {
                    spans.push(TerminalSpan {
                        text: cell.character.to_string(),
                        style: cell.style,
                    });
                }
            }
            lines.push(spans);
        }
        TerminalFrame {
            version: 1,
            columns: u16::try_from(self.columns).unwrap_or(u16::MAX),
            rows: u16::try_from(self.rows).unwrap_or(u16::MAX),
            cursor_column: u16::try_from(self.column.min(self.columns - 1)).unwrap_or(u16::MAX),
            cursor_row: u16::try_from(self.row).unwrap_or(u16::MAX),
            lines,
            images: self.images.clone(),
        }
    }
}

fn palette(index: usize) -> Option<u32> {
    const BASE: [u32; 16] = [
        0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5, 0x7f7f7f,
        0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
    ];
    match index {
        0..=15 => Some(BASE[index]),
        16..=231 => {
            let index = index - 16;
            let level = |value: usize| if value == 0 { 0 } else { 55 + value * 40 };
            u32::try_from(
                (level(index / 36) << 16) | (level(index / 6 % 6) << 8) | level(index % 6),
            )
            .ok()
        }
        232..=255 => u32::try_from(8 + (index - 232) * 10)
            .ok()
            .map(|gray| gray * 0x010101),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn text(screen: &TerminalScreen) -> String {
        screen
            .frame()
            .lines
            .iter()
            .map(|line| {
                line.iter()
                    .map(|span| span.text.as_str())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    #[test]
    fn cursor_erase_alternate_screen_and_styles() {
        let mut screen = TerminalScreen::new(10, 3).unwrap();
        screen.feed(b"hello\rX\x1b[2;3H\x1b[1;3;4;38;2;1;2;3mred\x1b[0m");
        assert!(text(&screen).starts_with("Xello\n  red"));
        let frame = screen.frame();
        let style = frame.lines[1].last().unwrap().style;
        assert_eq!(style.foreground, Some(0x010203));
        assert!(style.bold && style.italic && style.underline);
        screen.feed(b"\x1b[?1049halt\x1b[?1049l");
        assert!(text(&screen).starts_with("Xello"));
        screen.feed(b"\x1b[1;1H\x1b[2Jdone");
        assert!(text(&screen).starts_with("done\n"));
    }
    #[test]
    fn utf8_and_controls_are_split_invariant_and_strings_never_escape() {
        let bytes =
            "caf\u{e9}\x1b[31mred\x1b[0m\x1b]8;;https://invalid/\x1b\\link\x1bPpayload\x1b\\ok"
                .as_bytes();
        let mut whole = TerminalScreen::new(80, 3).unwrap();
        whole.feed(bytes);
        for split in 0..=bytes.len() {
            let mut screen = TerminalScreen::new(80, 3).unwrap();
            screen.feed(&bytes[..split]);
            screen.feed(&bytes[split..]);
            assert_eq!(screen.frame(), whole.frame());
        }
        let mut screen = TerminalScreen::new(80, 24).unwrap();
        screen.feed(b"\x1bP");
        screen.feed(&vec![b'x'; 1 << 20]);
        screen.feed(b"\x1b\\safe");
        assert!(text(&screen).starts_with("safe\n"));
        assert!(screen.utf8.len() <= 3);
    }
    #[test]
    fn viewport_resize_and_scroll_are_bounded() {
        let mut screen = TerminalScreen::new(4096, 512).unwrap();
        assert!(screen.cells.len() <= MAX_CELLS);
        assert!(screen.resize(5, 2));
        screen.feed(b"one\r\ntwo\r\nthree");
        assert_eq!(text(&screen), "two\nthree");
        assert!(!screen.resize(0, 0));
    }

    #[test]
    fn sixel_palette_repeat_and_raster_are_bounded() {
        let mut screen = TerminalScreen::new(80, 24).unwrap();
        // DCS sixel: palette 1 = red, repeat 3 pixels in one sixel column.
        screen.feed(b"\x1bPq#1;2;100;0;0#1!3~\x1b\\");
        let frame = screen.frame();
        assert_eq!(frame.images.len(), 1);
        let image = &frame.images[0];
        assert_eq!((image.width, image.height), (3, 6));
        assert_eq!(image.pixels[0], 0xff0000);
        let mut split = TerminalScreen::new(80, 24).unwrap();
        for byte in b"\x1bPq#1;2;100;0;0#1!3~\x1b\\" {
            split.feed(std::slice::from_ref(byte));
        }
        assert_eq!(split.frame(), frame);
    }
}
