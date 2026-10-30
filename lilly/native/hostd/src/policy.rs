//! The argument grammar for every utility hostd still runs as a program
//! (ADR-0176 decision 4). Native utilities (files, jail mounts, the VM launch)
//! are confined in their own modules; ZFS names in `zfs_policy`.
//!
//! The grammar is enforced when hostd runs as the production unit (pool
//! datasets configured). A private daemon started by an eval tool runs with
//! its owner's own privilege and marks no boundary, so it is not confined.

use crate::utilities::{Table, Utility};
use crate::zfs_policy::{self, Scope};
use std::ffi::{CString, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// What the grammar may refer to.
#[derive(Debug)]
pub struct Context<'a> {
    pub file_roots: &'a [PathBuf],
    pub scope: Scope<'a>,
    pub utilities: &'a Table,
    /// hostd's private directory for checked copies of host rule files.
    pub private: Option<&'a Path>,
    /// The request id (names the checked copy).
    pub request: u64,
}

/// The decision for one request.
#[derive(Debug, Eq, PartialEq)]
pub enum Decision {
    /// Run with the caller's arguments.
    Run,
    /// Run with these arguments instead (a namespaced executable replaced by
    /// hostd's own path for that utility).
    Rewrite(Vec<CString>),
    Refuse,
}

fn beneath(roots: &[PathBuf], value: &[u8]) -> bool {
    crate::protocol::valid_directory(value) && {
        let path = Path::new(OsStr::from_bytes(value));
        roots
            .iter()
            .any(|root| path.starts_with(root) && path != root)
    }
}

fn hex(value: &[u8], length: usize) -> bool {
    value.len() == length
        && value
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
}

/// `lilly-<12 hex>`: the VM network namespace.
fn namespace(value: &[u8]) -> bool {
    value
        .strip_prefix(b"lilly-")
        .is_some_and(|rest| hex(rest, 12))
}

/// Devices Lilly creates or configures: the uplink veth pair, guest taps, lo.
fn device(value: &[u8]) -> bool {
    value == b"uplink"
        || value == b"lo"
        || value.strip_prefix(b"lu").is_some_and(|rest| hex(rest, 12))
        || value.strip_prefix(b"lv").is_some_and(|rest| hex(rest, 12))
}

fn number(value: &[u8]) -> bool {
    !value.is_empty() && value.len() <= 20 && value.iter().all(u8::is_ascii_digit)
}

/// A route or address operand: an IPv4 address, optionally with a prefix.
fn ipv4(value: &[u8]) -> bool {
    let (address, prefix) = match value.iter().position(|b| *b == b'/') {
        Some(slash) => (&value[..slash], Some(&value[slash + 1..])),
        None => (value, None),
    };
    std::str::from_utf8(address).is_ok_and(|a| a.parse::<std::net::Ipv4Addr>().is_ok())
        && prefix.is_none_or(|p| {
            std::str::from_utf8(p).is_ok_and(|p| p.parse::<u8>().is_ok_and(|p| p <= 32))
        })
}

/// A link alias Lilly sets: `lilly:` followed by its own tags.
fn alias(value: &[u8]) -> bool {
    value.starts_with(b"lilly:")
        && value.len() <= 255
        && value
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || b":.,-".contains(b))
}

/// A locally administered unicast MAC in lowercase colon form, as Lilly derives
/// for guest TAP gateways.
fn unicast_local_mac(value: &[u8]) -> bool {
    let parts: Vec<&[u8]> = value.split(|b| *b == b':').collect();
    parts.len() == 6
        && parts.iter().all(|part| {
            part.len() == 2
                && part
                    .iter()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        })
        && std::str::from_utf8(parts[0])
            .ok()
            .and_then(|first| u8::from_str_radix(first, 16).ok())
            .is_some_and(|first| first & 0b11 == 0b10)
}

/// @cc [owner:ghuntley,label:security] ip-arguments-lilly-devices
/// ip MUST accept only reads (`[-j] [-d] [-4] link|addr|route|rule show ...`,
/// `netns list`, `netns pids NS`), `netns add|delete NS`, link, address,
/// tap, route and rule changes that name only Lilly's devices (uplink veth,
/// guest taps, lo) and namespaces (`lilly-<12 hex>`), a namespaced guest-tap
/// address change only to a locally administered unicast MAC, and `netns exec NS
/// EXE ...` where EXE's file name is ip, nft, sysctl or lilly-flow-label;
/// that EXE is replaced by hostd's own path for the utility and the rest is
/// checked by that utility's grammar in the namespace.
#[expect(
    clippy::match_same_arms,
    reason = "one arm per accepted command shape keeps the security grammar reviewable"
)]
fn ip(argv: &[&[u8]], in_namespace: bool) -> bool {
    let reads = |rest: &[&[u8]]| {
        matches!(
            rest.first(),
            Some(&(b"link" | b"addr" | b"route" | b"rule"))
        ) && rest.get(1) == Some(&&b"show"[..])
    };
    let mut rest = argv;
    while let [b"-j" | b"-d" | b"-4", tail @ ..] = rest {
        rest = tail;
    }
    if rest.len() < argv.len() {
        return reads(rest)
            && rest[2..]
                .iter()
                .all(|word| !word.starts_with(b"-") || *word == b"-4");
    }
    match rest {
        [b"netns", b"list"] => true,
        [b"netns", b"pids" | b"add" | b"delete", ns] => !in_namespace && namespace(ns),
        [b"link" | b"addr" | b"route" | b"rule", b"show", ..] => true,
        [b"link", b"add", uplink, b"type", b"veth", b"peer", b"name", b"uplink", b"netns", ns] => {
            !in_namespace && device(uplink) && namespace(ns)
        }
        [b"link", b"delete", link] => device(link),
        [b"link", b"set", b"dev", link, b"alias", value] => device(link) && alias(value),
        [b"link", b"set", b"dev", tap, b"address", mac] => {
            in_namespace && tap.starts_with(b"lv") && device(tap) && unicast_local_mac(mac)
        }
        [b"link", b"set", b"dev", link, b"up" | b"down"]
        | [b"link", b"set", link, b"up" | b"down"] => device(link),
        [b"addr", b"replace", address, b"dev", link] => ipv4(address) && device(link),
        [b"tuntap", b"add", b"dev", tap, b"mode", b"tap", b"user", uid] => {
            in_namespace && device(tap) && number(uid)
        }
        [b"tuntap", b"del", b"dev", tap, b"mode", b"tap"] => in_namespace && device(tap),
        [b"route", b"replace", b"default", b"via", gateway, b"dev", link] => {
            in_namespace && ipv4(gateway) && device(link)
        }
        [b"route", b"replace", address, b"dev", link, b"scope", b"link"] => {
            in_namespace && ipv4(address) && device(link)
        }
        [b"route", b"replace", b"local", b"0.0.0.0/0", b"dev", b"lo", b"table", table] => {
            in_namespace && number(table)
        }
        [b"rule", b"add", b"priority", priority, b"fwmark", mark, b"lookup", table] => {
            in_namespace
                && number(priority)
                && number(table)
                && mark
                    .iter()
                    .all(|b| b.is_ascii_hexdigit() || b"x/".contains(b))
        }
        _ => false,
    }
}

/// @cc [owner:ghuntley,label:security] sysctl-keys-lilly-networking
/// sysctl MUST accept only `-n net.ipv4.ip_forward` and `-qw` writes of the
/// IPv4/IPv6 per-device keys Lilly sets (forwarding, redirects, source
/// routing, `rp_filter`, `src_valid_mark`, `arp_ignore`, `arp_announce`, `disable_ipv6`) to 0, 1 or
/// 2; in the root namespace only for Lilly's uplink device.
fn sysctl(argv: &[&[u8]], in_namespace: bool) -> bool {
    match argv {
        [b"-n", b"net.ipv4.ip_forward"] => true,
        [b"-qw", settings @ ..] if !settings.is_empty() => settings.iter().all(|setting| {
            let Some(equals) = setting.iter().position(|b| *b == b'=') else {
                return false;
            };
            let (key, value) = (&setting[..equals], &setting[equals + 1..]);
            let key = std::str::from_utf8(key).unwrap_or("");
            let parts: Vec<&str> = key.split('.').collect();
            let known = match parts.as_slice() {
                ["net", "ipv4", "ip_forward"] => in_namespace,
                ["net", "ipv4" | "ipv6", "conf", device_name, setting] => {
                    let device_ok = if in_namespace {
                        ["all", "default"].contains(device_name) || device(device_name.as_bytes())
                    } else {
                        device_name.starts_with("lu") && device(device_name.as_bytes())
                    };
                    device_ok
                        && [
                            "disable_ipv6",
                            "accept_source_route",
                            "accept_redirects",
                            "send_redirects",
                            "rp_filter",
                            "src_valid_mark",
                            "arp_ignore",
                            "arp_announce",
                        ]
                        .contains(setting)
                }
                _ => false,
            };
            known && matches!(value, b"0" | b"1" | b"2")
        }),
        _ => false,
    }
}

/// @cc [owner:ghuntley,label:security] nft-files-beneath-state
/// nft MUST accept only `--file PATH` with PATH beneath the file roots and
/// the read-only `--json|-j list tables|table inet NAME`. The rule file's
/// content is Lilly's network policy and is not inspected (residual risk:
/// root-namespace rules are written by Lilly).
fn nft(argv: &[&[u8]], roots: &[PathBuf]) -> bool {
    match argv {
        [b"--file", path] => beneath(roots, path),
        [b"--json" | b"-j", b"list", b"tables"] => true,
        [b"--json" | b"-j", b"list", b"table", b"inet", name] => {
            name.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_')
        }
        _ => false,
    }
}

/// @cc [owner:ghuntley,label:security] systemctl-lilly-units-only
/// systemctl MUST accept only `show` and `list-units` queries of `lilly.slice`
/// and `lilly-vm-*` units. Lifecycle stop/kill MUST target exactly one
/// `lilly-vm-UUID.service`, never the shared slice or a wildcard.
#[expect(
    clippy::match_same_arms,
    reason = "one arm per accepted command shape keeps the security grammar reviewable"
)]
fn systemctl(argv: &[&[u8]]) -> bool {
    let vm_unit = |name: &[u8]| {
        name.strip_prefix(b"lilly-vm-")
            .and_then(|rest| rest.strip_suffix(b".service"))
            .is_some_and(crate::vm_launch::uuid)
    };
    let query_unit =
        |name: &[u8]| name == b"lilly.slice" || name == b"lilly-vm-*.service" || vm_unit(name);
    match argv {
        [b"stop", name] => vm_unit(name),
        [b"kill", b"--kill-who=all", b"--signal=KILL", name] => vm_unit(name),
        [b"show" | b"list-units", rest @ ..] => {
            let (options, units): (Vec<&[u8]>, Vec<&[u8]>) =
                rest.iter().partition(|word| word.starts_with(b"--"));
            !units.is_empty()
                && units.iter().all(|name| query_unit(name))
                && options.iter().all(|option| {
                    matches!(
                        *option,
                        b"--value" | b"--no-pager" | b"--all" | b"--plain" | b"--no-legend"
                    ) || option.starts_with(b"--property=")
                })
        }
        _ => false,
    }
}

fn image_copy(argv: &[&[u8]], roots: &[PathBuf]) -> bool {
    let source = |path: &[u8]| path.starts_with(b"/nix/store/") || beneath(roots, path);
    match argv {
        [b"identity", path] => source(path),
        [b"auto" | b"copy", from, to, size] => source(from) && beneath(roots, to) && number(size),
        [b"auto" | b"copy", from, to, size, lease] => {
            source(from) && beneath(roots, to) && number(size) && beneath(roots, lease)
        }
        [b"snapshot", from, to, size, uid] => {
            beneath(roots, from) && beneath(roots, to) && number(size) && number(uid)
        }
        _ => false,
    }
}

/// @cc [owner:ghuntley,label:security] utility-arguments-grammar
/// check MUST refuse any request for a utility that still runs as a program
/// unless its arguments match that utility's grammar: the ZFS grammar
/// (zfs-arguments-within-pools), ip-arguments-lilly-devices,
/// sysctl-keys-lilly-networking, nft-files-beneath-state,
/// systemctl-lilly-units-only, image copies whose destinations (and clone
/// sources) lie beneath the file roots, `cp --archive --no-target-directory --
/// POOL/.lilly-zfs /run/overalls-backups/pools/ID`, ssh-keygen on an
/// `id_ed25519` beneath the file roots, `lilly-zfs-namespace-unmount DS PATH`,
/// argument-free `lilly-kvm-probe`, and the read-only stat/findmnt/realpath
/// and `lilly-resume-token`/`lilly-flow-label`, whose own parsers validate.
#[expect(
    clippy::match_same_arms,
    reason = "the always-allowed utilities are listed apart from the refused wildcard on purpose"
)]
pub fn check(utility: Utility, arguments: &[CString], context: &Context<'_>) -> Decision {
    let argv: Vec<&[u8]> = arguments.iter().map(CString::as_bytes).collect();
    let roots = context.file_roots;
    let allowed = match utility {
        Utility::Ip => match argv.as_slice() {
            [b"netns", b"exec", ns, executable, rest @ ..] => {
                return namespaced(ns, executable, rest, arguments, context);
            }
            _ => ip(&argv, false),
        },
        // Host-namespace rule files load only Lilly's own tables, from hostd's
        // checked copy (host-nft-own-tables-only).
        Utility::Nft => match argv.as_slice() {
            [b"--file", path] => {
                let copy = context.private.and_then(|private| {
                    crate::nft_policy::checked_copy(path, roots, private, context.request)
                });
                return match copy.and_then(|copy| CString::new(copy.as_os_str().as_bytes()).ok()) {
                    Some(copy) => Decision::Rewrite(vec![c"--file".to_owned(), copy]),
                    None => Decision::Refuse,
                };
            }
            _ => nft(&argv, roots),
        },
        Utility::Sysctl => sysctl(&argv, false),
        Utility::Systemctl => systemctl(&argv),
        Utility::ZfsMutation => zfs_policy::mutation(&argv, &context.scope),
        Utility::Zfs => zfs_policy::read(false, &argv),
        Utility::Zpool => zfs_policy::read(true, &argv),
        Utility::ImageCopy | Utility::ImageIdentity => image_copy(&argv, roots),
        Utility::Cp => match argv.as_slice() {
            [b"--archive", b"--no-target-directory", b"--", from, to] => {
                from.ends_with(b"/.lilly-zfs")
                    && beneath(roots, from)
                    && to.starts_with(b"/run/overalls-backups/pools/")
                    && beneath(roots, to)
            }
            _ => false,
        },
        Utility::SshKeygen => match argv.as_slice() {
            [b"-q", b"-t", b"ed25519", b"-N", b"", b"-C", b"", b"-f", path]
            | [b"-y", b"-f", path] => path.ends_with(b"/id_ed25519") && beneath(roots, path),
            _ => false,
        },
        Utility::ZfsNamespaceUnmount => match argv.as_slice() {
            [dataset, path] => {
                zfs_policy::mutation(&[b"unmount", dataset], &context.scope) && beneath(roots, path)
            }
            _ => false,
        },
        Utility::KvmProbe => argv.is_empty(),
        // Read-only, or validated by the helper's own strict parser.
        Utility::Stat
        | Utility::Findmnt
        | Utility::Realpath
        | Utility::ResumeToken
        | Utility::FlowLabel => true,
        // Native, typed or otherwise confined elsewhere.
        _ => true,
    };
    if allowed {
        Decision::Run
    } else {
        Decision::Refuse
    }
}

fn namespaced(
    ns: &[u8],
    executable: &[u8],
    rest: &[&[u8]],
    arguments: &[CString],
    context: &Context<'_>,
) -> Decision {
    let name = Path::new(OsStr::from_bytes(executable))
        .file_name()
        .map(OsStrExt::as_bytes);
    let (inner, allowed) = match name {
        Some(b"ip") => (Utility::Ip, ip(rest, true)),
        Some(b"nft") => (Utility::Nft, nft(rest, context.file_roots)),
        Some(b"sysctl") => (Utility::Sysctl, sysctl(rest, true)),
        Some(b"lilly-flow-label") => (Utility::FlowLabel, rest.len() == 4),
        _ => return Decision::Refuse,
    };
    if !namespace(ns) || !executable.starts_with(b"/") || !allowed {
        return Decision::Refuse;
    }
    let Some(own) = context.utilities.get(inner) else {
        return Decision::Refuse;
    };
    let Ok(own) = CString::new(own.as_os_str().as_bytes()) else {
        return Decision::Refuse;
    };
    let mut rewritten = arguments.to_vec();
    rewritten[3] = own;
    Decision::Rewrite(rewritten)
}
