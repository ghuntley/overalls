//! Argument grammar for the `zfs` and `zpool` utilities (ADR-0176 decision 4).
//!
//! Dataset names are not file-system paths, so a grammar suffices: every name
//! Lilly passes must lie strictly beneath one of the configured pool datasets,
//! every option and property must be one Lilly uses, and a `mountpoint` must lie
//! inside a configured pool directory.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Properties Lilly sets, and the values each may take (None: any safe value).
const PROPERTIES: [(&str, Option<&[&str]>); 15] = [
    ("canmount", Some(&["on", "off", "noauto"])),
    ("compression", None),
    ("dedup", Some(&["off"])),
    ("devices", Some(&["off"])),
    ("exec", Some(&["on", "off"])),
    ("setuid", Some(&["off"])),
    ("mountpoint", None),
    ("quota", None),
    ("refquota", None),
    ("reservation", None),
    ("refreservation", None),
    ("readonly", Some(&["on", "off"])),
    ("sync", Some(&["standard"])),
    ("volmode", Some(&["none", "dev"])),
    ("atime", Some(&["on", "off"])),
];

/// Where Lilly's datasets may live.
#[derive(Debug)]
pub struct Scope<'a> {
    /// Configured pool datasets (e.g. `zroot/lilly`); names must be beneath one.
    pub datasets: &'a [Vec<u8>],
    /// Configured pool directories; a `mountpoint` must be beneath one.
    pub paths: &'a [PathBuf],
}

fn component(part: &[u8]) -> bool {
    !part.is_empty()
        && part.len() <= 128
        && part
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.:-".contains(byte))
}

/// A dataset (or, when `snapshot`, a dataset or snapshot) strictly beneath a pool dataset.
fn name(value: &[u8], scope: &Scope<'_>, snapshot: bool) -> bool {
    let (dataset, tag) = match value.iter().position(|byte| *byte == b'@') {
        Some(at) if snapshot => (&value[..at], Some(&value[at + 1..])),
        Some(_) => return false,
        None => (value, None),
    };
    value.len() <= 255
        && dataset.split(|byte| *byte == b'/').all(component)
        && tag.is_none_or(component)
        && scope.datasets.iter().any(|pool| {
            dataset.len() > pool.len() + 1
                && dataset.starts_with(pool)
                && dataset[pool.len()] == b'/'
        })
}

fn property(value: &[u8], scope: &Scope<'_>) -> bool {
    let Some(equals) = value.iter().position(|byte| *byte == b'=') else {
        return false;
    };
    let (key, value) = (&value[..equals], &value[equals + 1..]);
    if let Some(key) = key.strip_prefix(b"lilly:") {
        return component(key) && component(value);
    }
    let Some((_, allowed)) = PROPERTIES.iter().find(|(name, _)| name.as_bytes() == key) else {
        return false;
    };
    match (key, allowed) {
        (b"mountpoint", _) => {
            crate::protocol::valid_directory(value) && {
                let path = Path::new(OsStr::from_bytes(value));
                scope
                    .paths
                    .iter()
                    .any(|pool| path.starts_with(pool) && path != pool)
            }
        }
        (_, Some(values)) => values.iter().any(|allowed| allowed.as_bytes() == value),
        (_, None) => component(value),
    }
}

/// @cc [owner:ghuntley,label:security] zfs-arguments-within-pools
/// mutation MUST accept only `create (-o P)* NAME`, `snapshot (-o P)*
/// NAME@SNAP`, `destroy NAME[@SNAP]`, `set P+ NAME`, `mount NAME`,
/// `unmount NAME`, `rename NAME NAME` and `receive -A NAME`, where every NAME
/// lies strictly beneath a configured pool dataset (never the pool dataset
/// itself, never recursive or forced) and every property P is one Lilly sets,
/// with `setuid`/`devices` only `off` and a `mountpoint` strictly inside a
/// configured pool directory. reads MUST accept only `zfs list|get` and
/// `zpool status|get|iostat`, which cannot change state.
/// A received snapshot MAY receive only the UUID `lilly:transfer_nonce` marker;
/// this does not grant recursive mutation or arbitrary snapshot properties.
#[expect(
    clippy::match_same_arms,
    reason = "one arm per accepted command shape keeps the security grammar reviewable"
)]
pub fn mutation(argv: &[&[u8]], scope: &Scope<'_>) -> bool {
    let options = |mut rest: &[&[u8]]| -> Option<usize> {
        let mut count = 0;
        while let [b"-o", value, tail @ ..] = rest {
            if !property(value, scope) {
                return None;
            }
            count += 2;
            rest = tail;
        }
        Some(count)
    };
    match argv {
        [b"create" | b"snapshot", rest @ ..] => {
            let snapshot = argv[0] == b"snapshot";
            match options(rest) {
                Some(count) if rest.len() == count + 1 => {
                    let target = rest[count];
                    name(target, scope, snapshot) && (target.contains(&b'@') == snapshot)
                }
                _ => false,
            }
        }
        [b"destroy", target] => name(target, scope, true),
        [b"set", marker, target]
            if target.contains(&b'@')
                && marker
                    .strip_prefix(b"lilly:transfer_nonce=")
                    .is_some_and(crate::vm_launch::uuid) =>
        {
            name(target, scope, true)
        }
        [b"set", rest @ ..] if rest.len() >= 2 => {
            let (properties, target) = rest.split_at(rest.len() - 1);
            properties.iter().all(|value| property(value, scope)) && name(target[0], scope, false)
        }
        [b"mount" | b"unmount", target] => name(target, scope, false),
        [b"rename", from, to] => name(from, scope, false) && name(to, scope, false),
        [b"receive", b"-A", target] => name(target, scope, false),
        _ => false,
    }
}

/// Read-only `zfs` and `zpool` subcommands.
pub fn read(zpool: bool, argv: &[&[u8]]) -> bool {
    matches!(
        (zpool, argv.first()),
        (false, Some(&b"list" | &b"get")) | (true, Some(&b"status" | &b"get" | &b"iostat"))
    )
}
