//! Per-boot identity for Windows guests (ADR-0171).
//!
//! Linux agents read `/proc/sys/kernel/random/boot_id`. Windows has no such
//! value, so the first agent of a boot generates a `UUIDv4` and keeps it in a
//! **volatile** registry key (`HKLM\SOFTWARE\Overalls\Boot`, value `BootId`):
//! stable for every process of this boot, gone at the next one. A named mutex
//! serialises the first generation so all agents agree.

use super::wide;
use crate::sys::windows::error::system_random;
use crate::sys::windows::registry;
use crate::sys::windows::sync::NamedMutexGuard;
use std::io;
use windows_sys::Win32::System::Registry::REG_SZ;

const KEY: &str = "SOFTWARE\\Overalls\\Boot";
const VALUE: &str = "BootId";
const MUTEX: &str = "Global\\OverallsBootId";

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

/// A fresh lowercase `UUIDv4` from the system RNG.
pub fn generate() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    if !system_random(&mut bytes) {
        return Err(io::Error::other("system RNG unavailable"));
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{}-{}-{}-{}-{}",
        hex::encode(&bytes[0..4]),
        hex::encode(&bytes[4..6]),
        hex::encode(&bytes[6..8]),
        hex::encode(&bytes[8..10]),
        hex::encode(&bytes[10..16])
    ))
}

struct Key(registry::Key);

impl Key {
    fn open_volatile() -> io::Result<Self> {
        // The volatile option makes the key vanish at reboot.
        registry::Key::create_volatile_local_machine(KEY).map(Self)
    }

    fn read(&self) -> Option<String> {
        let mut buffer = [0u16; 64];
        let mut size = u32::try_from(size_of_val(&buffer)).ok()?;
        let kind = self.0.query(VALUE, &mut buffer, &mut size)?;
        if kind != REG_SZ {
            return None;
        }
        let units = (size as usize / 2).min(buffer.len());
        let text = String::from_utf16_lossy(&buffer[..units]);
        let text = text.trim_end_matches('\0').to_owned();
        valid_uuid(&text).then_some(text)
    }

    fn write(&self, value: &str) -> io::Result<()> {
        let data = wide(value);
        let bytes =
            u32::try_from(data.len() * 2).map_err(|_| io::Error::other("invalid boot ID"))?;
        self.0.set_string(VALUE, &data, bytes)
    }
}

/// @cc [owner:ghuntley,label:security;recovery] windows-boot-id-volatile-once
/// `boot_id` MUST return the same lowercase `UUIDv4` to every process of one
/// Windows boot and a different one after a reboot: it lives only in a
/// volatile registry key, is generated at most once per boot under a named
/// mutex, and a malformed stored value is replaced rather than returned.
pub fn boot_id() -> io::Result<String> {
    let _guard = NamedMutexGuard::acquire(MUTEX, "boot identity mutex unavailable")?;
    let key = Key::open_volatile()?;
    if let Some(existing) = key.read() {
        return Ok(existing);
    }
    let fresh = generate()?;
    key.write(&fresh)?;
    Ok(fresh)
}

/// @cc [owner:ghuntley,label:recovery] windows-per-boot-marker
/// `C:\overalls\run` survives reboots and relocation, unlike Linux's `/run`, so
/// a run marker MUST name the boot that wrote it: `write_marker` stores this
/// boot's id and `marker_is_current` is true only when the marker holds exactly
/// that id. A marker from an earlier boot, an unreadable marker or an
/// unavailable boot id is not current.
pub fn marker_is_current(path: &std::path::Path) -> bool {
    match (std::fs::read_to_string(path), boot_id()) {
        (Ok(content), Ok(current)) => content.trim() == current,
        _ => false,
    }
}

/// Record that `path` was reached during this boot (see [`marker_is_current`]).
pub fn write_marker(path: &std::path::Path) -> io::Result<()> {
    std::fs::write(path, format!("{}\n", boot_id()?))
}
