use super::*;
use crate::materialize::{data_extents, materialize_with};
use crate::source::{source_lease, with_source_lease};
use hegel::{generators as gs, TestCase};
use rustix::fs::{copy_file_range, flock, FlockOperation, Mode as FileMode};
use std::fs;
use std::os::unix::fs::{symlink, FileExt, PermissionsExt};

fn fixture(bytes: &[u8]) -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let directory = tempfile::tempdir().expect("isolated fixture");
    let source = directory.path().join("source");
    let target = directory.path().join("target");
    fs::write(&source, bytes).expect("fixture bytes");
    fs::set_permissions(&source, fs::Permissions::from_mode(0o444)).expect("readonly source");
    (directory, source, target)
}

/// @cc [owner:ghuntley,label:verification] image-copy-sparse-independent-destination
/// Materialized bytes MUST equal the sparse source in both modes, the destination
/// MUST be a single-link independent inode, and a second materialization MUST
/// refuse the existing destination without touching it or the source identity.
#[hegel::test(test_cases = 100)]
fn sparse_bytes_and_independent_destination_writes(tc: TestCase) {
    let mut bytes = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(4096));
    bytes.truncate(4096);
    let hole = 1024 * 1024 + usize::from(tc.draw(gs::integers::<u16>()));
    bytes.extend(std::iter::repeat_n(0, hole));
    bytes.push(tc.draw(gs::integers::<u8>()));
    let (_directory, source, target) = fixture(&bytes);
    let mode = if tc.draw(gs::integers::<u8>()).is_multiple_of(2) {
        Mode::Auto
    } else {
        Mode::Copy
    };
    let before = identity(&source).unwrap();
    let method = materialize(mode, &source, &target, bytes.len() as u64).unwrap();
    if mode == Mode::Copy {
        assert_eq!(method, Method::Copy);
    }
    assert_eq!(fs::read(&target).unwrap(), bytes);
    assert_eq!(fs::metadata(&target).unwrap().nlink(), 1);
    fs::write(&target, b"independent mutation").unwrap();
    assert_eq!(fs::read(&source).unwrap(), bytes);
    assert_eq!(identity(&source).unwrap(), before);
    assert_eq!(
        materialize(mode, &source, &target, bytes.len() as u64),
        Err(Error::Destination)
    );
    assert_eq!(fs::read(&target).unwrap(), b"independent mutation");
}

/// @cc [owner:ghuntley,label:verification] hegel-fallback-independent-oracle
/// Generated errno histories MUST exercise the actual materialization branch,
/// not just compare the classifier to itself. Unsupported errors copy exact
/// bytes; every other error leaves an empty temporary destination and fails.
#[hegel::test(test_cases = 100)]
fn only_recognized_unsupported_errors_can_copy(tc: TestCase) {
    let raw = i32::from(tc.draw(gs::integers::<u8>())) + 1;
    let error = Errno::from_raw_os_error(raw);
    let (_directory, source, target) = fixture(b"oracle bytes");
    let result = materialize_with(
        Mode::Auto,
        &source,
        &target,
        12,
        SourcePolicy::Image,
        |_| Ok(true),
        |_, _| Err(error),
        |_, _, _, _| Err(Errno::XDEV),
    );
    if [18, 25, 95].contains(&raw) {
        assert_eq!(result, Ok(Method::Copy));
        assert_eq!(fs::read(&target).unwrap(), b"oracle bytes");
    } else {
        assert_eq!(result, Err(Error::Clone));
        assert_eq!(fs::metadata(&target).unwrap().len(), 0);
    }
}

/// @cc [owner:ghuntley,label:verification;security] image-copy-size-and-symlink-refusal
/// A mismatched size or writable source MUST fail before creation, and a leaf
/// destination symlink MUST be refused without writing through it.
#[hegel::test(test_cases = 100)]
fn mismatched_sizes_and_symlinks_never_overwrite(tc: TestCase) {
    let bytes = [tc.draw(gs::integers::<u8>()); 16];
    let (directory, source, target) = fixture(&bytes);
    let wrong = u64::from(tc.draw(gs::integers::<u16>())) + 17;
    assert_eq!(
        materialize(Mode::Auto, &source, &target, wrong),
        Err(Error::Source)
    );
    assert!(!target.exists());
    let unrelated = directory.path().join("unrelated");
    fs::write(&unrelated, b"untouched").unwrap();
    symlink(&unrelated, &target).unwrap();
    assert_eq!(
        materialize(Mode::Copy, &source, &target, 16),
        Err(Error::Destination)
    );
    assert_eq!(fs::read(&unrelated).unwrap(), b"untouched");
    fs::remove_file(&target).unwrap();
    fs::set_permissions(&source, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        materialize(Mode::Copy, &source, &target, 16),
        Err(Error::Source)
    );
    assert!(!target.exists());
}

/// @cc [owner:ghuntley,label:verification] image-copy-size-parser-oracle
/// `parse_size` MUST accept exactly canonical decimals in `1..=MAX_BYTES` and
/// refuse signed or zero-padded spellings.
#[hegel::test(test_cases = 100)]
fn byte_count_parser_is_canonical_and_bounded(tc: TestCase) {
    let size = tc.draw(gs::integers::<u64>());
    assert_eq!(
        parse_size(&size.to_string()).is_ok(),
        (1..=MAX_BYTES).contains(&size)
    );
    assert_eq!(parse_size(&format!("+{size}")), Err(Error::Arguments));
    assert_eq!(parse_size(&format!("0{size}")), Err(Error::Arguments));
}

/// @cc [owner:ghuntley,label:verification;recovery] image-copy-changed-source-refusal
/// A source whose identity changes during the copy MUST fail with Changed.
#[hegel::test(test_cases = 100)]
fn changed_source_identity_during_clone_cannot_publish(tc: TestCase) {
    let initial = tc.draw(gs::integers::<u8>());
    let (_directory, source, target) = fixture(&[initial; 128]);
    let result = materialize_with(
        Mode::Auto,
        &source,
        &target,
        128,
        SourcePolicy::Image,
        |_| Ok(true),
        |_, _| {
            fs::set_permissions(&source, fs::Permissions::from_mode(0o644)).unwrap();
            fs::write(&source, [initial.wrapping_add(1); 128]).unwrap();
            // Filesystem clocks may coalesce rapid operations. Establish an actual
            // identity change, independently of elapsed wall time or test scheduling.
            let file = File::options().write(true).open(&source).unwrap();
            file.set_modified(
                std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000),
            )
            .unwrap();
            fs::set_permissions(&source, fs::Permissions::from_mode(0o444)).unwrap();
            Err(Errno::XDEV)
        },
        |_, _, _, _| Err(Errno::XDEV),
    );
    assert_eq!(result, Err(Error::Changed));
}

/// @cc [owner:ghuntley,label:verification] image-copy-nanosecond-identity
/// `identity` MUST carry the exact seconds and nanoseconds of the modification time.
#[hegel::test(test_cases = 100)]
fn file_identity_preserves_nanosecond_fields(tc: TestCase) {
    let nanos = u64::from(tc.draw(gs::integers::<u32>())) % 1_000_000_000;
    let (_directory, source, _target) = fixture(b"precise");
    fs::set_permissions(&source, fs::Permissions::from_mode(0o644)).unwrap();
    let file = File::options().write(true).open(&source).unwrap();
    let time = std::time::UNIX_EPOCH
        + std::time::Duration::new(1_000_000_000, u32::try_from(nanos).unwrap());
    file.set_modified(time).unwrap();
    fs::set_permissions(&source, fs::Permissions::from_mode(0o444)).unwrap();
    let identity = identity(&source).unwrap();
    assert_eq!(identity.0[7], 1_000_000_000);
    assert_eq!(identity.0[8], nanos);
}

/// @cc [owner:ghuntley,label:verification;security] image-copy-nonregular-source-refusal
/// Symlink, FIFO and directory sources MUST be refused by materialization and
/// identity alike, and no destination is created.
#[hegel::test(test_cases = 100)]
fn nonregular_sources_and_source_symlinks_are_refused(tc: TestCase) {
    let (directory, source, target) = fixture(&[tc.draw(gs::integers::<u8>()); 16]);
    let alias = directory.path().join("alias");
    symlink(&source, &alias).unwrap();
    let fifo = directory.path().join("fifo");
    rustix::fs::mkfifoat(rustix::fs::CWD, &fifo, FileMode::from_raw_mode(0o400)).unwrap();
    for candidate in [&alias, &fifo, &directory.path().to_path_buf()] {
        assert_eq!(
            materialize(Mode::Copy, candidate, &target, 16),
            Err(Error::Source)
        );
        assert!(!target.exists());
        assert_eq!(identity(candidate), Err(Error::Source));
    }
}

/// @cc [owner:ghuntley,label:verification;concurrency] image-copy-source-lease-model
/// The copy's own shared lease MUST exclude retirement after the caller's lease
/// closes, a lease that cannot be shared MUST refuse the copy, and symlink, FIFO,
/// group/other-accessible or hard-linked lease inodes MUST be refused.
#[hegel::test(test_cases = 100)]
fn independent_source_lease_excludes_retirement_and_refuses_unsafe_inodes(tc: TestCase) {
    let bytes = [tc.draw(gs::integers::<u8>()); 128];
    let (directory, source, target) = fixture(&bytes);
    let path = directory.path().join("owner.lock");
    let original = File::create(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    flock(&original, FlockOperation::NonBlockingLockShared).unwrap();
    let contender = File::open(&path).unwrap();
    let result = with_source_lease(&path, || {
        drop(original);
        assert!(flock(&contender, FlockOperation::NonBlockingLockExclusive).is_err());
        materialize(Mode::Copy, &source, &target, 128)
    });
    assert_eq!(result, Ok(Method::Copy));
    assert_eq!(fs::read(&target).unwrap(), bytes);
    flock(&contender, FlockOperation::NonBlockingLockExclusive).unwrap();
    fs::remove_file(&target).unwrap();
    assert_eq!(
        materialize_leased(Mode::Copy, &source, &target, 128, &path),
        Err(Error::Lease)
    );
    assert!(!target.exists());
    drop(contender);
    let alias = directory.path().join("alias");
    symlink(&path, &alias).unwrap();
    assert!(source_lease(&alias).is_err());
    let fifo = directory.path().join("fifo");
    rustix::fs::mkfifoat(rustix::fs::CWD, &fifo, FileMode::from_raw_mode(0o600)).unwrap();
    assert!(source_lease(&fifo).is_err());
    let mode = 0o600 | u32::from(tc.draw(gs::integers::<u8>()) % 63 + 1);
    fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
    assert!(source_lease(&path).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let link = directory.path().join("hardlink");
    fs::hard_link(&path, &link).unwrap();
    assert!(source_lease(&path).is_err());
}

/// @cc [owner:ghuntley,label:verification] hegel-offload-fallback-oracle
/// Generated errno histories MUST drive the real offload branch: only an
/// allowlisted refusal before any transfer copies exact bytes; anything else
/// fails with an empty unpublished destination.
#[hegel::test(test_cases = 100)]
fn offload_refusal_before_progress_is_the_only_fallback(tc: TestCase) {
    let raw = i32::from(tc.draw(gs::integers::<u8>())) + 1;
    let error = Errno::from_raw_os_error(raw);
    let (_directory, source, target) = fixture(b"offload oracle");
    let result = materialize_with(
        Mode::Auto,
        &source,
        &target,
        14,
        SourcePolicy::Image,
        |_| Ok(true),
        |_, _| Err(Errno::XDEV),
        |_, _, _, _| Err(error),
    );
    if [18, 25, 38, 95].contains(&raw) {
        assert_eq!(result, Ok(Method::Copy));
        assert_eq!(fs::read(&target).unwrap(), b"offload oracle");
    } else {
        assert_eq!(result, Err(Error::Copy));
        assert_eq!(fs::metadata(&target).unwrap().len(), 0);
    }
}

/// @cc [owner:ghuntley,label:verification;recovery] image-copy-partial-offload-fails
/// Once kernel offload has transferred any byte, a later refusal or short
/// transfer MUST fail the copy instead of falling back.
#[hegel::test(test_cases = 100)]
fn partial_or_short_offload_never_falls_back_or_publishes(tc: TestCase) {
    let size = u64::from(tc.draw(gs::integers::<u8>()) % 200) + 2;
    let first = usize::try_from(u64::from(tc.draw(gs::integers::<u8>())) % (size - 1) + 1).unwrap();
    let short = tc.draw(gs::booleans());
    let (_directory, source, target) = fixture(&vec![7_u8; usize::try_from(size).unwrap()]);
    let mut calls = 0;
    let result = materialize_with(
        Mode::Auto,
        &source,
        &target,
        size,
        SourcePolicy::Image,
        |_| Ok(true),
        |_, _| Err(Errno::XDEV),
        |_, _, _, _| {
            calls += 1;
            match (calls, short) {
                (1, _) => Ok(first),
                (_, true) => Ok(0),
                (_, false) => Err(Errno::XDEV),
            }
        },
    );
    assert_eq!(result, Err(Error::Copy));
}

/// @cc [owner:ghuntley,label:verification] image-copy-offload-byte-preservation
/// Kernel copy offload MUST preserve every byte into an independent destination
/// and leave the source identity unchanged.
#[hegel::test(test_cases = 100)]
fn kernel_offload_preserves_bytes_and_independence(tc: TestCase) {
    let mut bytes = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(8192));
    bytes.truncate(8192);
    bytes.push(tc.draw(gs::integers::<u8>()));
    let (_directory, source, target) = fixture(&bytes);
    let before = identity(&source).unwrap();
    let method = materialize_with(
        Mode::Auto,
        &source,
        &target,
        bytes.len() as u64,
        SourcePolicy::Image,
        |_| Ok(true),
        |_, _| Err(Errno::XDEV),
        |target, source, offset, length| {
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    )
    .unwrap();
    assert!(matches!(method, Method::Offload | Method::Copy));
    assert_eq!(fs::read(&target).unwrap(), bytes);
    fs::write(&target, b"independent mutation").unwrap();
    assert_eq!(fs::read(&source).unwrap(), bytes);
    assert_eq!(identity(&source).unwrap(), before);
}

/// @cc [owner:ghuntley,label:verification;security] hegel-snapshot-source-policy
/// Snapshot sources are accepted only on a read-only filesystem for the exact
/// expected uid with a single link; writable filesystems, other uids and
/// hard-linked files are refused before any destination is created.
#[hegel::test(test_cases = 100)]
fn snapshot_source_requires_read_only_exact_uid_single_link(tc: TestCase) {
    let mut bytes = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(4096));
    bytes.truncate(4096);
    bytes.push(tc.draw(gs::integers::<u8>()));
    let (directory, source, target) = fixture(&bytes);
    let uid = rustix::process::geteuid().as_raw();
    let read_only = tc.draw(gs::booleans());
    let other_uid = tc.draw(gs::booleans());
    let linked = tc.draw(gs::booleans());
    if linked {
        fs::hard_link(&source, directory.path().join("alias")).unwrap();
    }
    let expected_uid = if other_uid { uid.wrapping_add(1) } else { uid };
    let result = materialize_with(
        Mode::Auto,
        &source,
        &target,
        bytes.len() as u64,
        SourcePolicy::Snapshot { uid: expected_uid },
        |_| Ok(read_only),
        |_, _| Err(Errno::XDEV),
        |target, source, offset, length| {
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    );
    if read_only && !other_uid && !linked {
        assert!(matches!(result, Ok(Method::Offload | Method::Copy)));
        assert_eq!(fs::read(&target).unwrap(), bytes);
    } else {
        assert_eq!(result, Err(Error::Source));
        assert!(!target.exists());
    }
}

/// @cc [owner:ghuntley,label:verification] image-copy-snapshot-size-parser-oracle
/// `parse_snapshot_size` MUST accept exactly canonical decimals in
/// `1..=SNAPSHOT_MAX_BYTES`, admitting sizes the image bound refuses.
#[hegel::test(test_cases = 100)]
fn snapshot_size_bound_admits_guest_disks_beyond_image_bound(tc: TestCase) {
    let size = tc.draw(gs::integers::<u64>());
    assert_eq!(
        parse_snapshot_size(&size.to_string()).is_ok(),
        (1..=SNAPSHOT_MAX_BYTES).contains(&size)
    );
    assert!(parse_snapshot_size(&(MAX_BYTES + 1).to_string()).is_ok());
    assert!(parse_size(&(MAX_BYTES + 1).to_string()).is_err());
}

/// @cc [owner:ghuntley,label:verification;performance] hegel-extent-copy-oracle
/// Generated sparse sources MUST copy byte for byte in every mode while the
/// offload path is asked only for ranges inside the source's data extents, so
/// holes are never read or written (image-copy-source-extents).
#[hegel::test(test_cases = 100)]
fn holes_are_skipped_and_bytes_preserved(tc: TestCase) {
    let directory = tempfile::tempdir().expect("isolated fixture");
    let source = directory.path().join("source");
    let target = directory.path().join("target");
    let block = 1_u64 << 20;
    let blocks = u64::from(tc.draw(gs::integers::<u8>()) % 16) + 2;
    let size = blocks * block;
    let mut expected = vec![0_u8; usize::try_from(size).unwrap()];
    {
        let file = fs::File::create(&source).expect("source");
        file.set_len(size).expect("sparse length");
        for index in 0..blocks {
            if tc.draw(gs::booleans()) {
                let value = tc.draw(gs::integers::<u8>()) | 1;
                let offset = index * block + u64::from(tc.draw(gs::integers::<u16>()));
                let length = usize::from(tc.draw(gs::integers::<u8>())) + 1;
                let bytes = vec![value; length];
                file.write_all_at(&bytes, offset).expect("data block");
                let start = usize::try_from(offset).unwrap();
                expected[start..start + length].copy_from_slice(&bytes);
            }
        }
    }
    fs::set_permissions(&source, fs::Permissions::from_mode(0o444)).expect("readonly source");
    let extents = {
        let file = fs::File::open(&source).expect("source");
        data_extents(&file, size).expect("extents")
    };
    let inside = |offset: u64, length: usize| {
        extents
            .iter()
            .any(|(start, end)| offset >= *start && offset + length as u64 <= *end)
    };
    let mode = if tc.draw(gs::booleans()) {
        Mode::Auto
    } else {
        Mode::Copy
    };
    let mut asked = Vec::new();
    let method = materialize_with(
        mode,
        &source,
        &target,
        size,
        SourcePolicy::Image,
        |_| Ok(true),
        |_, _| Err(Errno::XDEV),
        |target, source, offset, length| {
            asked.push((offset, length));
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    )
    .unwrap();
    assert!(
        asked
            .iter()
            .all(|(offset, length)| inside(*offset, *length)),
        "{asked:?} outside {extents:?}"
    );
    if mode == Mode::Copy {
        assert_eq!(method, Method::Copy);
        assert!(asked.is_empty());
    }
    assert_eq!(fs::metadata(&target).unwrap().len(), size);
    assert_eq!(fs::read(&target).unwrap(), expected);
}

/// @cc [owner:ghuntley,label:verification] image-copy-method-wire-injective
/// The stdout result word MUST identify exactly one copy method: distinct
/// methods never share a wire word, and every word is a fixed lowercase token
/// from the private result protocol.
#[hegel::test(test_cases = 64)]
fn method_wire_is_injective(tc: TestCase) {
    let methods = vec![Method::Reflink, Method::Offload, Method::Copy];
    let left = tc.draw(gs::sampled_from(methods.clone()));
    let right = tc.draw(gs::sampled_from(methods));
    assert_eq!(left.wire() == right.wire(), left == right);
    assert!(["reflink", "offload", "copy"].contains(&left.wire()));
    assert!(left.wire().bytes().all(|byte| byte.is_ascii_lowercase()));
}

/// @cc [owner:ghuntley,label:verification;security] image-copy-policy-size-lattice
/// For every guest uid the snapshot bound MUST be the maximum guest disk size,
/// at least the image bound, which stays the fixed image ceiling.
#[hegel::test(test_cases = 64)]
fn snapshot_bound_dominates_image_bound(tc: TestCase) {
    let uid = tc.draw(gs::integers::<u32>());
    let snapshot = SourcePolicy::Snapshot { uid }.max_bytes();
    let image = SourcePolicy::Image.max_bytes();
    assert!(snapshot >= image);
    assert_eq!(snapshot, 536_870_912_000);
    assert_eq!(image, 137_438_953_472);
}
