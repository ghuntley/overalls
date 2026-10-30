//! Read-only validation of the two pinned native root-disk layouts.

use super::{invalid, Os};
use std::io::{self, Read, Seek, SeekFrom};

const SECTOR: u64 = 512;
const HEADER_BYTES: usize = 92;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Partition {
    pub index: usize,
    pub start: u64,
    pub end: u64,
    bytes: [u8; 128],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Table {
    pub disk_bytes: u64,
    pub backup: u64,
    pub last: u64,
    pub root: Partition,
    partitions: Vec<Partition>,
}

#[derive(Clone, Debug)]
struct Header {
    current: u64,
    backup: u64,
    first: u64,
    last: u64,
    guid: [u8; 16],
    array: u64,
    count: u32,
    array_crc: u32,
}

fn number<const N: usize>(bytes: &[u8], offset: usize) -> io::Result<[u8; N]> {
    bytes
        .get(offset..offset.checked_add(N).ok_or_else(invalid)?)
        .ok_or_else(invalid)?
        .try_into()
        .map_err(|_| invalid())
}

fn word(bytes: &[u8], offset: usize) -> io::Result<u32> {
    Ok(u32::from_le_bytes(number(bytes, offset)?))
}

fn long(bytes: &[u8], offset: usize) -> io::Result<u64> {
    Ok(u64::from_le_bytes(number(bytes, offset)?))
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0_u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

fn guid(value: &str) -> io::Result<[u8; 16]> {
    let digits: Vec<u8> = value.bytes().filter(|byte| *byte != b'-').collect();
    if digits.len() != 32 || !digits.iter().all(u8::is_ascii_hexdigit) {
        return Err(invalid());
    }
    let mut bytes = [0_u8; 16];
    for (index, pair) in digits.as_chunks::<2>().0.iter().enumerate() {
        bytes[index] = u8::from_str_radix(std::str::from_utf8(pair).map_err(|_| invalid())?, 16)
            .map_err(|_| invalid())?;
    }
    bytes[..4].reverse();
    bytes[4..6].reverse();
    bytes[6..8].reverse();
    Ok(bytes)
}

fn read_at<R: Read + Seek>(disk: &mut R, sector: u64, count: usize) -> io::Result<Vec<u8>> {
    disk.seek(SeekFrom::Start(
        sector.checked_mul(SECTOR).ok_or_else(invalid)?,
    ))?;
    // illumos raw disks require a whole-sector transfer, including for its
    // nine-entry (1152-byte) logical GPT array. Padding is transport only;
    // header CRCs and primary/backup comparisons cover the logical bytes.
    let aligned = count.checked_next_multiple_of(512).ok_or_else(invalid)?;
    let mut bytes = vec![0_u8; aligned];
    disk.read_exact(&mut bytes)?;
    bytes.truncate(count);
    Ok(bytes)
}

fn header(bytes: &[u8]) -> io::Result<Header> {
    if bytes.len() != 512
        || &bytes[..8] != b"EFI PART"
        || word(bytes, 8)? != 0x0001_0000
        || usize::try_from(word(bytes, 12)?).map_err(|_| invalid())? != HEADER_BYTES
        || word(bytes, 20)? != 0
        || word(bytes, 84)? != 128
    {
        return Err(invalid());
    }
    let expected = word(bytes, 16)?;
    let mut copy = bytes[..HEADER_BYTES].to_vec();
    copy[16..20].fill(0);
    if crc32(&copy) != expected {
        return Err(invalid());
    }
    Ok(Header {
        current: long(bytes, 24)?,
        backup: long(bytes, 32)?,
        first: long(bytes, 40)?,
        last: long(bytes, 48)?,
        guid: number(bytes, 56)?,
        array: long(bytes, 72)?,
        count: word(bytes, 80)?,
        array_crc: word(bytes, 88)?,
    })
}

type Spec = (usize, u64, u64, &'static str, &'static str, &'static str);

fn specs(os: Os) -> &'static [Spec] {
    match os {
        Os::FreeBsd => &[
            (
                1,
                34,
                155,
                "83bd6b9d-7f41-11dc-be0b-001560b84f0f",
                "92519c27-42bc-11f0-9e0b-002590ec5bf2",
                "bootfs",
            ),
            (
                2,
                156,
                66739,
                "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
                "92519c30-42bc-11f0-9e0b-002590ec5bf2",
                "efiesp",
            ),
            (
                3,
                66740,
                2_163_891,
                "516e7cb5-6ecf-11d6-8ff8-00022d09712b",
                "92519c37-42bc-11f0-9e0b-002590ec5bf2",
                "swapfs",
            ),
            (
                4,
                2_163_892,
                2_165_939,
                "516e7cb4-6ecf-11d6-8ff8-00022d09712b",
                "92519c3b-42bc-11f0-9e0b-002590ec5bf2",
                "config-drive",
            ),
            (
                5,
                2_165_940,
                12_651_699,
                "516e7cb6-6ecf-11d6-8ff8-00022d09712b",
                "92519c40-42bc-11f0-9e0b-002590ec5bf2",
                "rootfs",
            ),
        ],
        Os::Illumos => &[
            (
                1,
                256,
                524_543,
                "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
                "3ddfc4e1-8931-4041-a067-9c3af6e7e6ff",
                "loader",
            ),
            (
                2,
                524_544,
                16_760_798,
                "6a898cc3-1dd2-11b2-99a6-080020736631",
                "9610b7a1-df6c-1a45-ba89-159690b86a8d",
                "zfs",
            ),
            (
                9,
                16_760_799,
                16_777_182,
                "6a945a3b-1dd2-11b2-99a6-080020736631",
                "4ae19670-ff90-8249-a2f6-d9a305e6fa78",
                "",
            ),
        ],
    }
}

fn disk_guid(os: Os) -> &'static str {
    match os {
        Os::FreeBsd => "9251b63a-42bc-11f0-9e0b-002590ec5bf2",
        Os::Illumos => "9c59ba04-83a2-0040-a996-c8c91931d866",
    }
}

/// @cc [owner:ghuntley,label:security;recovery] native-root-gpt-preflight
/// Before a native growth command, both GPT headers and entry arrays MUST have
/// valid matching CRCs and the pinned disk/partition identities and layout.
/// Physical capacity MUST contain the previous backup header; shrinking,
/// foreign disks, extra partitions, relocated starts and overlapping entries
/// MUST fail before any mutation. Only root length and the `OmniOS` reserved
/// tail location MAY differ from the pinned image.
#[expect(
    clippy::too_many_lines,
    reason = "one fail-closed validation sequence over both GPT copies"
)]
pub(super) fn read<R: Read + Seek>(disk: &mut R, disk_bytes: u64, os: Os) -> io::Result<Table> {
    if !disk_bytes.is_multiple_of(SECTOR) || !(1 << 30..=1 << 50).contains(&disk_bytes) {
        return Err(invalid());
    }
    let sectors = disk_bytes / SECTOR;
    let mbr = read_at(disk, 0, 512)?;
    if mbr[510..] != [0x55, 0xaa]
        || mbr[450] != 0xee
        || word(&mbr, 454)? != 1
        || mbr[462..510].iter().any(|byte| *byte != 0)
    {
        return Err(invalid());
    }
    let primary = header(&read_at(disk, 1, 512)?)?;
    let expected_count = match os {
        Os::FreeBsd => 128,
        Os::Illumos => 9,
    };
    if primary.current != 1
        || primary.backup >= sectors
        || primary.backup < 34
        || primary.first != 34
        || (primary.last != primary.backup - 33
            && (os != Os::FreeBsd
                || primary.last != primary.backup - 33 - (primary.backup - 32) % 8))
        || primary.guid != guid(disk_guid(os))?
        || primary.array != 2
        || primary.count != expected_count
    {
        return Err(invalid());
    }
    let count = usize::try_from(primary.count).map_err(|_| invalid())? * 128;
    let bytes = read_at(disk, primary.array, count)?;
    if crc32(&bytes) != primary.array_crc {
        return Err(invalid());
    }
    let backup = header(&read_at(disk, primary.backup, 512)?)?;
    let array_sectors = u64::try_from(count)
        .map_err(|_| invalid())?
        .div_ceil(SECTOR);
    if backup.current != primary.backup
        || backup.backup != 1
        || backup.first != primary.first
        || backup.last != primary.last
        || backup.guid != primary.guid
        || backup.count != primary.count
        || backup.array_crc != primary.array_crc
        || backup.array <= primary.last
        || backup
            .array
            .checked_add(array_sectors)
            .ok_or_else(invalid)?
            > backup.current
        || read_at(disk, backup.array, count)? != bytes
    {
        return Err(invalid());
    }
    let mut partitions = Vec::new();
    for (slot, row) in bytes.as_chunks::<128>().0.iter().enumerate() {
        let Some(spec) = specs(os).iter().find(|spec| spec.0 == slot + 1) else {
            // libefi serializes an unassigned zero-size entry as start=0,
            // end=UINT64_MAX. This exact sentinel is part of the pinned image.
            let mut empty = [0_u8; 128];
            if os == Os::Illumos {
                empty[40..48].fill(0xff);
            }
            if *row != empty {
                return Err(invalid());
            }
            continue;
        };
        let start = long(row, 32)?;
        let end = long(row, 40)?;
        let mut name = [0_u8; 72];
        for (index, character) in spec.5.encode_utf16().enumerate() {
            name[index * 2..index * 2 + 2].copy_from_slice(&character.to_le_bytes());
        }
        let root = slot + 1 == os.root_index();
        let reserved = os == Os::Illumos && slot + 1 == 9;
        if row[..16] != guid(spec.3)?
            || row[16..32] != guid(spec.4)?
            || long(row, 48)? != 0
            || row[56..] != name
            || end < start
            || end > primary.last
            || (!reserved && start != spec.1)
            || (root && end < spec.2)
            || (!root && !reserved && end != spec.2)
            || (reserved && end.checked_sub(start) != Some(16383))
        {
            return Err(invalid());
        }
        partitions.push(Partition {
            index: slot + 1,
            start,
            end,
            bytes: number(row, 0)?,
        });
    }
    for pair in partitions.windows(2) {
        if pair[0].end >= pair[1].start {
            return Err(invalid());
        }
    }
    let root = partitions
        .iter()
        .find(|part| part.index == os.root_index())
        .ok_or_else(invalid)?
        .clone();
    if os == Os::Illumos {
        let reserved = partitions.last().ok_or_else(invalid)?;
        if root.end.checked_add(1) != Some(reserved.start) || reserved.end != primary.last {
            return Err(invalid());
        }
    }
    Ok(Table {
        disk_bytes,
        backup: primary.backup,
        last: primary.last,
        root,
        partitions,
    })
}

impl Table {
    fn verify_transition(&self, after: &Self, os: Os) -> io::Result<()> {
        if self.disk_bytes != after.disk_bytes
            || after.root.start != self.root.start
            || after.root.end < self.root.end
            || after.backup != after.disk_bytes / SECTOR - 1
            || after.partitions.len() != self.partitions.len()
        {
            return Err(invalid());
        }
        for (before, after) in self.partitions.iter().zip(&after.partitions) {
            if before.index == os.root_index() {
                let mut expected = before.bytes;
                expected[40..48].copy_from_slice(&after.end.to_le_bytes());
                if expected != after.bytes {
                    return Err(invalid());
                }
            } else if os == Os::Illumos && before.index == 9 {
                let mut expected = before.bytes;
                expected[32..40].copy_from_slice(&after.start.to_le_bytes());
                expected[40..48].copy_from_slice(&after.end.to_le_bytes());
                if expected != after.bytes {
                    return Err(invalid());
                }
            } else if before != after {
                return Err(invalid());
            }
        }
        Ok(())
    }

    pub(super) fn verify_recovery(&self, after: &Self) -> io::Result<()> {
        self.verify_transition(after, Os::FreeBsd)?;
        if self.root != after.root {
            return Err(invalid());
        }
        Ok(())
    }

    pub(super) fn verify_growth(&self, after: &Self, os: Os) -> io::Result<()> {
        self.verify_transition(after, os)?;
        if os == Os::FreeBsd && after.root.end != after.last {
            return Err(invalid());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;

    const FREEBSD_BYTES: u64 = 6_477_687_296;
    const ILLUMOS_BYTES: u64 = 8_589_934_592;

    fn put32(bytes: &mut [u8], at: usize, value: u32) {
        bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
    }
    fn put64(bytes: &mut [u8], at: usize, value: u64) {
        bytes[at..at + 8].copy_from_slice(&value.to_le_bytes());
    }
    fn write_at(file: &mut File, at: u64, bytes: &[u8]) {
        file.seek(SeekFrom::Start(at * SECTOR)).unwrap();
        file.write_all(bytes).unwrap();
    }
    fn checksum(header: &mut [u8]) {
        put32(header, 16, 0);
        let crc = crc32(&header[..HEADER_BYTES]);
        put32(header, 16, crc);
    }
    fn initial(os: Os) -> u64 {
        match os {
            Os::FreeBsd => FREEBSD_BYTES,
            Os::Illumos => ILLUMOS_BYTES,
        }
    }

    // Sparse files exercise the real seek/read interface at native multi-GiB
    // offsets without allocating either image in memory.
    fn image(
        os: Os,
        labeled_bytes: u64,
        physical_bytes: u64,
        mutate: impl FnOnce(&mut [u8], &mut [u8]),
    ) -> File {
        let mut disk = tempfile::tempfile().unwrap();
        disk.set_len(physical_bytes).unwrap();
        let backup = labeled_bytes / SECTOR - 1;
        let maximum = backup - 33;
        let last = if os == Os::FreeBsd && labeled_bytes > FREEBSD_BYTES {
            maximum - (maximum + 1) % 8
        } else {
            maximum
        };
        let count = match os {
            Os::FreeBsd => 128,
            Os::Illumos => 9,
        };
        let mut entries = vec![0_u8; count * 128];
        if os == Os::Illumos {
            for slot in 2..8 {
                entries[slot * 128 + 40..slot * 128 + 48].fill(0xff);
            }
        }
        for spec in specs(os) {
            let at = (spec.0 - 1) * 128;
            let row = &mut entries[at..at + 128];
            row[..16].copy_from_slice(&guid(spec.3).unwrap());
            row[16..32].copy_from_slice(&guid(spec.4).unwrap());
            let start = if os == Os::Illumos && spec.0 == 9 {
                last - 16383
            } else {
                spec.1
            };
            let end = if spec.0 == os.root_index() {
                if os == Os::Illumos {
                    last - 16384
                } else {
                    last
                }
            } else if os == Os::Illumos && spec.0 == 9 {
                last
            } else {
                spec.2
            };
            put64(row, 32, start);
            put64(row, 40, end);
            for (index, character) in spec.5.encode_utf16().enumerate() {
                row[56 + index * 2..58 + index * 2].copy_from_slice(&character.to_le_bytes());
            }
        }
        let mut primary = vec![0_u8; 512];
        primary[..8].copy_from_slice(b"EFI PART");
        put32(&mut primary, 8, 0x10000);
        put32(&mut primary, 12, 92);
        put64(&mut primary, 24, 1);
        put64(&mut primary, 32, backup);
        put64(&mut primary, 40, 34);
        put64(&mut primary, 48, last);
        primary[56..72].copy_from_slice(&guid(disk_guid(os)).unwrap());
        put64(&mut primary, 72, 2);
        put32(&mut primary, 80, u32::try_from(count).unwrap());
        put32(&mut primary, 84, 128);
        mutate(&mut primary, &mut entries);
        put32(&mut primary, 88, crc32(&entries));
        checksum(&mut primary);
        let mut secondary = primary.clone();
        put64(&mut secondary, 24, backup);
        put64(&mut secondary, 32, 1);
        put64(&mut secondary, 72, backup - 32);
        checksum(&mut secondary);
        let mut mbr = [0_u8; 512];
        mbr[450] = 0xee;
        put32(&mut mbr, 454, 1);
        put32(&mut mbr, 458, u32::try_from(backup).unwrap());
        mbr[510..].copy_from_slice(&[0x55, 0xaa]);
        write_at(&mut disk, 0, &mbr);
        write_at(&mut disk, 1, &primary);
        write_at(&mut disk, 2, &entries);
        write_at(&mut disk, backup - 32, &entries);
        write_at(&mut disk, backup, &secondary);
        disk
    }

    #[test]
    fn both_layouts_grow_twice_without_moving_foreign_entries() {
        for os in [Os::FreeBsd, Os::Illumos] {
            let base = initial(os);
            let step = 2 << 30;
            let mut old = image(os, base, base + step, |_, _| {});
            let before = read(&mut old, base + step, os).unwrap();
            let mut grown = image(os, base + step, base + step, |_, _| {});
            let after = read(&mut grown, base + step, os).unwrap();
            before.verify_growth(&after, os).unwrap();
            assert!(after.root.end > before.root.end);
            let before = read(&mut grown, base + 2 * step, os).unwrap();
            let mut grown = image(os, base + 2 * step, base + 2 * step, |_, _| {});
            let after = read(&mut grown, base + 2 * step, os).unwrap();
            before.verify_growth(&after, os).unwrap();
            assert!(after.root.end > before.root.end);
            after.verify_growth(&after, os).unwrap();
        }
    }

    #[test]
    fn foreign_guid_and_partition_identity_bounds_and_geometry_fail() {
        for os in [Os::FreeBsd, Os::Illumos] {
            let size = initial(os);
            let root = (os.root_index() - 1) * 128;
            let mut bad = image(os, size, size, |header, _| header[56] ^= 1);
            assert!(read(&mut bad, size, os).is_err());
            for offset in [0, 16, 32, 48, 56] {
                let mut bad = image(os, size, size, |_, entries| entries[root + offset] ^= 1);
                assert!(read(&mut bad, size, os).is_err(), "offset {offset}");
            }
            let mut bad = image(os, size, size, |_, entries| {
                put64(entries, root + 40, size / 512);
            });
            assert!(read(&mut bad, size, os).is_err());
            let mut bad = image(os, size, size, |_, entries| entries[5 * 128] = 1);
            assert!(read(&mut bad, size, os).is_err());
            for (offset, value) in [(80, 129), (84, 256), (40, 35), (72, 3)] {
                let mut bad = image(os, size, size, |header, _| put32(header, offset, value));
                assert!(read(&mut bad, size, os).is_err());
            }
            let mut good = image(os, size, size, |_, _| {});
            assert!(read(&mut good, size - 512, os).is_err());
            assert!(read(&mut good, size + 1, os).is_err());
            assert!(read(&mut good, 0, os).is_err());
        }
    }

    #[test]
    fn corruption_of_either_header_or_array_fails() {
        for os in [Os::FreeBsd, Os::Illumos] {
            let size = initial(os);
            let backup = size / 512 - 1;
            for sector in [1, 2, backup - 32, backup] {
                let mut bad = image(os, size, size, |_, _| {});
                bad.seek(SeekFrom::Start(sector * 512 + 60)).unwrap();
                bad.write_all(&[0xff]).unwrap();
                assert!(read(&mut bad, size, os).is_err());
            }
        }
    }

    #[test]
    fn interrupted_freebsd_recover_retains_safe_resize_path() {
        let base = FREEBSD_BYTES;
        let larger = base + (2 << 30);
        let mut recovered = image(Os::FreeBsd, larger, larger, |_, entries| {
            put64(entries, 4 * 128 + 40, base / 512 - 34);
        });
        let before = read(&mut recovered, larger, Os::FreeBsd).unwrap();
        assert!(before.root.end < before.last);
        assert!(before.verify_growth(&before, Os::FreeBsd).is_err());
        let mut original = image(Os::FreeBsd, base, larger, |_, _| {});
        let original = read(&mut original, larger, Os::FreeBsd).unwrap();
        original.verify_recovery(&before).unwrap();
        let mut grown = image(Os::FreeBsd, larger, larger, |_, _| {});
        let after = read(&mut grown, larger, Os::FreeBsd).unwrap();
        before.verify_growth(&after, Os::FreeBsd).unwrap();
        assert!(original.verify_recovery(&after).is_err());
    }

    #[test]
    fn freebsd_usable_end_accepts_only_maximum_or_native_four_k_alignment() {
        let size = FREEBSD_BYTES + (2 << 30);
        let maximum = size / SECTOR - 34;
        let aligned = maximum - (maximum + 1) % 8;
        assert_ne!(maximum, aligned);
        for offset in 0..=8 {
            let last = maximum - offset;
            let mut candidate = image(Os::FreeBsd, size, size, |header, entries| {
                put64(header, 48, last);
                put64(entries, 4 * 128 + 40, last);
            });
            assert_eq!(
                read(&mut candidate, size, Os::FreeBsd).is_ok(),
                last == maximum || last == aligned,
                "offset {offset}"
            );
        }
    }

    #[test]
    fn illumos_raw_reads_use_whole_sectors_but_crc_only_logical_entries() {
        struct RawDisk(File);

        impl Read for RawDisk {
            fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
                if !bytes.len().is_multiple_of(512) {
                    return Err(io::Error::from(io::ErrorKind::InvalidInput));
                }
                self.0.read(bytes)
            }
        }

        impl Seek for RawDisk {
            fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
                self.0.seek(position)
            }
        }

        let size = initial(Os::Illumos);
        let mut file = image(Os::Illumos, size, size, |_, _| {});
        // Distinct padding on the two arrays must not alter logical-array
        // CRCs or equality; the unused raw transfer tail is not a GPT entry.
        file.seek(SeekFrom::Start(2 * SECTOR + 1152)).unwrap();
        file.write_all(&[0xa5; 384]).unwrap();
        file.seek(SeekFrom::Start((size / SECTOR - 33) * SECTOR + 1152))
            .unwrap();
        file.write_all(&[0x5a; 384]).unwrap();
        let mut raw = RawDisk(file);
        assert!(read(&mut raw, size, Os::Illumos).is_ok());
        raw.seek(SeekFrom::Start(2 * SECTOR)).unwrap();
        raw.0.write_all(&[0xff]).unwrap();
        assert!(read(&mut raw, size, Os::Illumos).is_err());
    }

    #[test]
    fn shrink_after_growth_and_reserved_tail_damage_fail() {
        let os = Os::Illumos;
        let size = ILLUMOS_BYTES;
        let larger = size + (2 << 30);
        let mut grown = image(os, larger, larger, |_, _| {});
        assert!(read(&mut grown, size, os).is_err());
        for delta in [1_u64, 512] {
            let mut bad = image(os, size, size, |_, entries| {
                put64(entries, 8 * 128 + 32, size / 512 - 16417 + delta);
            });
            assert!(read(&mut bad, size, os).is_err());
        }
    }
}
