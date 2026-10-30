//! Guest dataset streams (ADR-0183): hostd, not Lilly, derives the command
//! lines of every `zfs send`, `zfs receive` and transfer `ssh` on a Lilly
//! host, and runs them through `lilly-transfer-stream` under a stream lease.
//!
//! Only the ZFS sides run as root. The SSH producer and the probe's `cmp`
//! consumer run as the service uid, so the network-facing client never holds
//! privilege its caller lacks and the key files it reads are Lilly's own.

use crate::protocol::Refusal;
use crate::utilities::{Table, Utility};
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

/// Accepted stream deadline range in milliseconds (this request only).
pub const TIMEOUTS: std::ops::RangeInclusive<u32> = 1000..=86_400_000;
/// Accepted byte rates; zero is unthrottled.
pub const RATES: std::ops::RangeInclusive<u32> = 0..=1_073_741_824;
/// The single snapshot every transfer journal binds (Lilly's `slot/0`).
pub const SNAPSHOT: &str = "lilly-b";

/// What the remote export endpoint is asked for.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Verb {
    Export,
    Checkpoint,
    Resume { token: Vec<u8> },
    Probe { challenge: Vec<u8> },
}

/// The bytes' source.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Producer {
    /// `zfs send -c <dataset>/vm-<placement>@lilly-b`.
    LocalSend {
        dataset: Vec<u8>,
        placement: Vec<u8>,
    },
    /// Full immutable checkpoint leaf; its slot is exactly `a` or `b`.
    CheckpointSend {
        dataset: Vec<u8>,
        placement: Vec<u8>,
        slot: Vec<u8>,
    },
    /// `zfs send -t <token>` after `lilly-resume-token` confirmed the token
    /// names `<dataset>/vm-<placement>@lilly-b` with this to-GUID.
    LocalResume {
        dataset: Vec<u8>,
        placement: Vec<u8>,
        to_guid: Vec<u8>,
        token: Vec<u8>,
    },
    /// The pinned per-relocation SSH pull, run as the service uid.
    Ssh {
        address: Vec<u8>,
        port: Vec<u8>,
        source_host: Vec<u8>,
        relocation: Vec<u8>,
        identity: Vec<u8>,
        known_hosts: Vec<u8>,
        verb: Verb,
    },
}

/// The bytes' sink.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Consumer {
    /// `zfs receive -u -s` with the fixed properties into
    /// `<dataset>/vm-<placement>`, mounted (later) under `<pool>/vms/<placement>`.
    Receive {
        dataset: Vec<u8>,
        pool: Vec<u8>,
        placement: Vec<u8>,
        host: Vec<u8>,
        pool_id: Vec<u8>,
        nonce: Vec<u8>,
    },
    /// Unmounted, non-resumable sealed checkpoint receive into destination slot a.
    CheckpointReceive {
        dataset: Vec<u8>,
        pool: Vec<u8>,
        placement: Vec<u8>,
        host: Vec<u8>,
        pool_id: Vec<u8>,
        nonce: Vec<u8>,
        memory_bytes: Vec<u8>,
    },
    /// `cmp --silent -- <path> -`, run as the service uid (the SSH probe).
    Compare { path: Vec<u8> },
}

/// One decoded stream request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Stream {
    pub producer: Producer,
    pub consumer: Consumer,
}

const PRODUCER_LOCAL_SEND: u8 = 1;
const PRODUCER_LOCAL_RESUME: u8 = 2;
const PRODUCER_SSH_EXPORT: u8 = 3;
const PRODUCER_SSH_RESUME: u8 = 4;
const PRODUCER_SSH_PROBE: u8 = 5;
const PRODUCER_CHECKPOINT_SEND: u8 = 6;
const PRODUCER_SSH_CHECKPOINT: u8 = 7;
const CONSUMER_CHECKPOINT_RECEIVE: u8 = 3;
const CONSUMER_RECEIVE: u8 = 1;
const CONSUMER_COMPARE: u8 = 2;

impl Stream {
    /// Decode the kinds and their NUL-terminated fields: producer fields
    /// first, then consumer fields, with no field left over.
    pub fn decode(producer: u8, consumer: u8, mut fields: Vec<Vec<u8>>) -> Option<Stream> {
        let producer_fields = match producer {
            PRODUCER_LOCAL_SEND => 2,
            PRODUCER_CHECKPOINT_SEND => 3,
            PRODUCER_LOCAL_RESUME => 4,
            PRODUCER_SSH_EXPORT | PRODUCER_SSH_CHECKPOINT => 6,
            PRODUCER_SSH_RESUME | PRODUCER_SSH_PROBE => 7,
            _ => return None,
        };
        let consumer_fields = match consumer {
            CONSUMER_RECEIVE => 6,
            CONSUMER_CHECKPOINT_RECEIVE => 7,
            CONSUMER_COMPARE => 1,
            _ => return None,
        };
        if fields.len() != producer_fields + consumer_fields {
            return None;
        }
        let rest = fields.split_off(producer_fields);
        let mut p = fields.into_iter();
        // The field count was checked above, so `next()??` never returns early.
        let mut next = || p.next();
        let producer = match producer {
            PRODUCER_LOCAL_SEND => Producer::LocalSend {
                dataset: next()?,
                placement: next()?,
            },
            PRODUCER_CHECKPOINT_SEND => Producer::CheckpointSend {
                dataset: next()?,
                placement: next()?,
                slot: next()?,
            },
            PRODUCER_LOCAL_RESUME => Producer::LocalResume {
                dataset: next()?,
                placement: next()?,
                to_guid: next()?,
                token: next()?,
            },
            kind => {
                let (address, port, source_host, relocation, identity, known_hosts) =
                    (next()?, next()?, next()?, next()?, next()?, next()?);
                let verb = match kind {
                    PRODUCER_SSH_EXPORT => Verb::Export,
                    PRODUCER_SSH_CHECKPOINT => Verb::Checkpoint,
                    PRODUCER_SSH_RESUME => Verb::Resume { token: next()? },
                    _ => Verb::Probe { challenge: next()? },
                };
                Producer::Ssh {
                    address,
                    port,
                    source_host,
                    relocation,
                    identity,
                    known_hosts,
                    verb,
                }
            }
        };
        let mut c = rest.into_iter();
        let mut next = || c.next();
        let consumer = match consumer {
            CONSUMER_RECEIVE => Consumer::Receive {
                dataset: next()?,
                pool: next()?,
                placement: next()?,
                host: next()?,
                pool_id: next()?,
                nonce: next()?,
            },
            CONSUMER_CHECKPOINT_RECEIVE => Consumer::CheckpointReceive {
                dataset: next()?,
                pool: next()?,
                placement: next()?,
                host: next()?,
                pool_id: next()?,
                nonce: next()?,
                memory_bytes: next()?,
            },
            _ => Consumer::Compare { path: next()? },
        };
        Some(Stream { producer, consumer })
    }

    /// The wire kinds and fields (the inverse of decode).
    #[expect(
        clippy::too_many_lines,
        reason = "one arm per producer and consumer kind mirrors decode"
    )]
    pub fn encode(&self) -> (u8, u8, Vec<Vec<u8>>) {
        let mut fields = Vec::new();
        let producer = match &self.producer {
            Producer::LocalSend { dataset, placement } => {
                fields.extend([dataset.clone(), placement.clone()]);
                PRODUCER_LOCAL_SEND
            }
            Producer::CheckpointSend {
                dataset,
                placement,
                slot,
            } => {
                fields.extend([dataset.clone(), placement.clone(), slot.clone()]);
                PRODUCER_CHECKPOINT_SEND
            }
            Producer::LocalResume {
                dataset,
                placement,
                to_guid,
                token,
            } => {
                fields.extend([
                    dataset.clone(),
                    placement.clone(),
                    to_guid.clone(),
                    token.clone(),
                ]);
                PRODUCER_LOCAL_RESUME
            }
            Producer::Ssh {
                address,
                port,
                source_host,
                relocation,
                identity,
                known_hosts,
                verb,
            } => {
                fields.extend([
                    address.clone(),
                    port.clone(),
                    source_host.clone(),
                    relocation.clone(),
                    identity.clone(),
                    known_hosts.clone(),
                ]);
                match verb {
                    Verb::Export => PRODUCER_SSH_EXPORT,
                    Verb::Checkpoint => PRODUCER_SSH_CHECKPOINT,
                    Verb::Resume { token } => {
                        fields.push(token.clone());
                        PRODUCER_SSH_RESUME
                    }
                    Verb::Probe { challenge } => {
                        fields.push(challenge.clone());
                        PRODUCER_SSH_PROBE
                    }
                }
            }
        };
        let consumer = match &self.consumer {
            Consumer::Receive {
                dataset,
                pool,
                placement,
                host,
                pool_id,
                nonce,
            } => {
                fields.extend([
                    dataset.clone(),
                    pool.clone(),
                    placement.clone(),
                    host.clone(),
                    pool_id.clone(),
                    nonce.clone(),
                ]);
                CONSUMER_RECEIVE
            }
            Consumer::CheckpointReceive {
                dataset,
                pool,
                placement,
                host,
                pool_id,
                nonce,
                memory_bytes,
            } => {
                fields.extend([
                    dataset.clone(),
                    pool.clone(),
                    placement.clone(),
                    host.clone(),
                    pool_id.clone(),
                    nonce.clone(),
                    memory_bytes.clone(),
                ]);
                CONSUMER_CHECKPOINT_RECEIVE
            }
            Consumer::Compare { path } => {
                fields.push(path.clone());
                CONSUMER_COMPARE
            }
        };
        (producer, consumer, fields)
    }
}

/// Where and as whom the stream runs.
#[derive(Debug)]
pub struct Context<'a> {
    /// Configured pools as (dataset, directory) pairs.
    pub pools: &'a [(Vec<u8>, PathBuf)],
    pub utilities: &'a Table,
    /// The uid the unprivileged sides drop to: the service uid when hostd
    /// runs as another uid (root). None keeps hostd's own uid.
    pub side_uid: Option<u32>,
    /// Whether hostd is root while serving another uid. Keeping hostd's own
    /// uid is then refused; a root caller's private daemon gains nothing.
    pub elevated: bool,
}

/// The validated commands for one stream.
#[derive(Debug, Eq, PartialEq)]
pub struct Plan {
    /// `lilly-resume-token` arguments that must print exactly `ok\n` first.
    pub resume_check: Option<Vec<CString>>,
    /// The helper's arguments (its executable is the `TransferStream` utility).
    pub helper: Vec<CString>,
}

fn uuid(value: &[u8]) -> bool {
    crate::vm_launch::uuid(value)
}

/// A decimal ZFS GUID: 1..=20 digits, no leading zero.
fn guid(value: &[u8]) -> bool {
    (1..=20).contains(&value.len())
        && value.iter().all(u8::is_ascii_digit)
        && value[0] != b'0'
        && std::str::from_utf8(value)
            .ok()
            .and_then(|text| text.parse::<u64>().ok())
            .is_some()
}

fn hex(value: &[u8]) -> bool {
    value
        .iter()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

/// A ZFS resume token (Lilly's ExportRequest.token?):
/// `1-<hex 1..16>-<hex 1..16>-<hex pairs>`, at most 8192 bytes.
pub fn token(value: &[u8]) -> bool {
    if !(1..=8192).contains(&value.len()) {
        return false;
    }
    let mut parts = value.splitn(4, |byte| *byte == b'-');
    let (Some(version), Some(first), Some(second), Some(payload)) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    version == b"1"
        && (1..=16).contains(&first.len())
        && hex(first)
        && (1..=16).contains(&second.len())
        && hex(second)
        && !payload.is_empty()
        && payload.len() % 2 == 0
        && hex(payload)
}

/// A 32-character lowercase hexadecimal import nonce.
fn nonce(value: &[u8]) -> bool {
    value.len() == 32 && hex(value)
}

/// A canonical dotted-quad IPv4 address or a lowercase DNS name.
pub fn address(value: &[u8]) -> bool {
    if !(1..=253).contains(&value.len()) {
        return false;
    }
    if value
        .iter()
        .all(|byte| byte.is_ascii_digit() || *byte == b'.')
    {
        return std::str::from_utf8(value)
            .ok()
            .and_then(|text| text.parse::<std::net::Ipv4Addr>().ok())
            .is_some_and(|ip| ip.to_string().as_bytes() == value);
    }
    value.split(|byte| *byte == b'.').all(|label| {
        (1..=63).contains(&label.len())
            && label
                .iter()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
            && label[0] != b'-'
            && label[label.len() - 1] != b'-'
    })
}

/// A decimal TCP port, 1..=65535, no leading zero.
fn port(value: &[u8]) -> bool {
    (1..=5).contains(&value.len())
        && value[0] != b'0'
        && std::str::from_utf8(value)
            .ok()
            .and_then(|text| text.parse::<u16>().ok())
            .is_some()
}

/// A normalised absolute path of shell- and token-inert characters (no `%`
/// or `$` expansion for ssh, no spaces).
pub fn inert_path(value: &[u8]) -> bool {
    crate::protocol::valid_directory(value)
        && value
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_./-".contains(byte))
}

fn text(value: impl AsRef<[u8]>) -> Result<CString, Refusal> {
    CString::new(value.as_ref()).map_err(|_| Refusal::Malformed)
}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

fn executable(context: &Context<'_>, utility: Utility) -> Result<CString, Refusal> {
    let path = context.utilities.get(utility).ok_or(Refusal::Unavailable)?;
    text(path.as_os_str().as_bytes())
}

/// A ZFS dataset name: `/`-separated components of `[A-Za-z0-9_.:-]`, each
/// starting alphanumeric (so no name reads as an option).
fn dataset_name(value: &[u8]) -> bool {
    (1..=200).contains(&value.len())
        && value.split(|byte| *byte == b'/').all(|part| {
            part.first().is_some_and(u8::is_ascii_alphanumeric)
                && part
                    .iter()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_.:-".contains(byte))
        })
}

/// The configured pool for a dataset, requiring `directory` (when given) to
/// be that same pool's directory. A daemon with no configured pools (a
/// private daemon, which runs with its owner's privilege) accepts any
/// well-formed dataset and normalised directory.
fn pool(
    context: &Context<'_>,
    dataset: &[u8],
    directory: Option<&[u8]>,
) -> Result<(Vec<u8>, PathBuf), Refusal> {
    if context.pools.is_empty() {
        return match directory {
            _ if !dataset_name(dataset) => Err(Refusal::Malformed),
            Some(directory) if !crate::protocol::valid_directory(directory) => {
                Err(Refusal::Malformed)
            }
            directory => Ok((
                dataset.to_vec(),
                PathBuf::from(std::ffi::OsStr::from_bytes(directory.unwrap_or(b"/"))),
            )),
        };
    }
    context
        .pools
        .iter()
        .find(|(name, path)| {
            name.as_slice() == dataset
                && directory.is_none_or(|directory| path.as_os_str().as_bytes() == directory)
        })
        .cloned()
        .ok_or(Refusal::Malformed)
}

/// The fixed SSH options (Lilly.Transfer.SSH.command/3 before ADR-0183).
const SSH_OPTIONS: [&str; 34] = [
    "AddressFamily=inet",
    "BatchMode=yes",
    "IdentitiesOnly=yes",
    "IdentityAgent=none",
    "CertificateFile=none",
    "PreferredAuthentications=publickey",
    "PubkeyAuthentication=yes",
    "PasswordAuthentication=no",
    "KbdInteractiveAuthentication=no",
    "PubkeyAcceptedAlgorithms=ssh-ed25519",
    "HostKeyAlgorithms=ssh-ed25519",
    "StrictHostKeyChecking=yes",
    "GlobalKnownHostsFile=/dev/null",
    "KnownHostsCommand=none",
    "VerifyHostKeyDNS=no",
    "UpdateHostKeys=no",
    "CheckHostIP=no",
    "CanonicalizeHostname=no",
    "ControlMaster=no",
    "ControlPath=none",
    "ControlPersist=no",
    "ClearAllForwardings=yes",
    "ForwardAgent=no",
    "ForwardX11=no",
    "Tunnel=no",
    "ProxyCommand=none",
    "ProxyJump=none",
    "PermitLocalCommand=no",
    "ConnectionAttempts=1",
    "ConnectTimeout=10",
    "ServerAliveInterval=15",
    "ServerAliveCountMax=2",
    "Compression=no",
    "LogLevel=ERROR",
];

/// The receive properties Lilly's verification requires; the ownership
/// markers follow them.
const RECEIVE_PROPERTIES: [&str; 12] = [
    "canmount=noauto",
    "readonly=on",
    "exec=off",
    "setuid=off",
    "devices=off",
    "compression=lz4",
    "reservation=none",
    "refreservation=none",
    "dedup=off",
    "sync=standard",
    "quota=none",
    "refquota=none",
];

/// @cc [owner:ghuntley,label:security] hostd-transfer-stream-typed
/// plan MUST derive every command from validated fields only, and refuse
/// (Malformed, or Unavailable for an unresolved utility) anything else:
/// datasets MUST be configured pool datasets and a receive's pool directory
/// that same pool's; placements, relocations, source hosts, host and pool ids
/// UUIDs; GUIDs decimal; nonces 32 lowercase hex; tokens ZFS resume-token
/// syntax; addresses canonical IPv4 or lowercase DNS; ports 1..65535; key,
/// known-hosts and compare paths normalised inert absolute paths. A receive
/// MUST carry exactly the fixed unmounted, read-only, no-exec, no-setuid,
/// no-devices properties plus its mountpoint and ownership markers, and
/// target `<dataset>/vm-<placement>`; a local send names only
/// `<dataset>/vm-<placement>@lilly-b`, and a local resume first requires
/// `lilly-resume-token` to confirm that snapshot and to-GUID. SSH uses only
/// the fixed options, user `lilly-transfer` and a fixed remote verb. The SSH
/// producer and compare consumer run as the service uid when hostd runs as
/// another uid, and MUST be refused when a root hostd serves another uid
/// with no service uid; only a private daemon whose caller is hostd's own
/// uid keeps that uid. The ZFS sides run as hostd's uid.
/// Checkpoint send MUST name only a validated a/b sibling leaf at
/// `@lilly-checkpoint`; checkpoint receive MUST be non-resumable, unmounted,
/// sealed read-only, and target only destination slot a. Checkpoint SSH uses
/// only `lilly-checkpoint-v1` with the validated relocation identity.
#[expect(
    clippy::too_many_lines,
    reason = "the stream plan derives both command lines from one closed match per kind"
)]
pub fn plan(
    stream: &Stream,
    context: &Context<'_>,
    timeout_ms: u32,
    rate: u32,
    progress_fd: Option<i32>,
) -> Result<Plan, Refusal> {
    if !TIMEOUTS.contains(&timeout_ms) || !RATES.contains(&rate) {
        return Err(Refusal::Malformed);
    }
    // The SSH and compare sides never run with privilege the caller lacks.
    let unprivileged = match context.side_uid {
        Some(0) => Err(Refusal::Unavailable),
        Some(uid) => Ok(uid.to_string()),
        None if context.elevated => Err(Refusal::Unavailable),
        None => Ok("-".to_string()),
    };
    let zfs = || executable(context, Utility::ZfsMutation);
    let mut resume_check = None;
    let (producer, producer_uid) = match &stream.producer {
        Producer::LocalSend { dataset, placement } => {
            let (dataset, _) = pool(context, dataset, None)?;
            if !uuid(placement) {
                return Err(Refusal::Malformed);
            }
            let snapshot = concat(&[&dataset, b"/vm-", placement, b"@", SNAPSHOT.as_bytes()]);
            (
                vec![zfs()?, text("send")?, text("-c")?, text(snapshot)?],
                "-".to_string(),
            )
        }
        Producer::CheckpointSend {
            dataset,
            placement,
            slot,
        } => {
            let (dataset, _) = pool(context, dataset, None)?;
            if !uuid(placement) || !matches!(slot.as_slice(), b"a" | b"b") {
                return Err(Refusal::Malformed);
            }
            let snapshot = concat(&[
                &dataset,
                b"/checkpoint-",
                placement,
                b"-",
                slot,
                b"@lilly-checkpoint",
            ]);
            (
                vec![zfs()?, text("send")?, text("-c")?, text(snapshot)?],
                "-".to_string(),
            )
        }
        Producer::LocalResume {
            dataset,
            placement,
            to_guid,
            token: resume,
        } => {
            let (dataset, _) = pool(context, dataset, None)?;
            if !uuid(placement) || !guid(to_guid) || !token(resume) {
                return Err(Refusal::Malformed);
            }
            let snapshot = concat(&[&dataset, b"/vm-", placement, b"@", SNAPSHOT.as_bytes()]);
            resume_check = Some(vec![text(snapshot)?, text(to_guid)?, text(resume)?]);
            (
                vec![zfs()?, text("send")?, text("-t")?, text(resume)?],
                "-".to_string(),
            )
        }
        Producer::Ssh {
            address: host,
            port: number,
            source_host,
            relocation,
            identity,
            known_hosts,
            verb,
        } => {
            if !address(host)
                || !port(number)
                || !uuid(source_host)
                || !uuid(relocation)
                || !inert_path(identity)
                || !inert_path(known_hosts)
            {
                return Err(Refusal::Malformed);
            }
            let mut argv = vec![
                executable(context, Utility::Ssh)?,
                text("-F")?,
                text("/dev/null")?,
                text("-T")?,
                text("-n")?,
                text("-i")?,
                text(identity)?,
            ];
            for option in SSH_OPTIONS {
                argv.extend([text("-o")?, text(option)?]);
            }
            argv.extend([
                text("-o")?,
                text(concat(&[b"UserKnownHostsFile=", known_hosts]))?,
                text("-o")?,
                text(concat(&[b"HostKeyAlias=lilly-", source_host]))?,
                text("-p")?,
                text(number)?,
                text("-l")?,
                text("lilly-transfer")?,
                text("--")?,
                text(host)?,
            ]);
            match verb {
                Verb::Export => argv.extend([text("lilly-export-v4")?, text(relocation)?]),
                Verb::Checkpoint => argv.extend([text("lilly-checkpoint-v1")?, text(relocation)?]),
                Verb::Resume { token: resume } if token(resume) => {
                    argv.extend([text("lilly-resume-v4")?, text(relocation)?, text(resume)?]);
                }
                Verb::Probe { challenge } if uuid(challenge) => {
                    argv.extend([text("lilly-probe-v3")?, text(relocation)?, text(challenge)?]);
                }
                _ => return Err(Refusal::Malformed),
            }
            (argv, unprivileged.clone()?)
        }
    };
    let (consumer, consumer_uid) = match &stream.consumer {
        Consumer::Receive {
            dataset,
            pool: directory,
            placement,
            host,
            pool_id,
            nonce: marker,
        }
        | Consumer::CheckpointReceive {
            dataset,
            pool: directory,
            placement,
            host,
            pool_id,
            nonce: marker,
            memory_bytes: _,
        } => {
            let checkpoint = matches!(&stream.consumer, Consumer::CheckpointReceive { .. });
            let (dataset, directory) = pool(context, dataset, Some(directory))?;
            if !uuid(placement) || !uuid(host) || !uuid(pool_id) || !nonce(marker) {
                return Err(Refusal::Malformed);
            }
            let mountpoint = directory
                .join(if checkpoint {
                    ".lilly-checkpoints"
                } else {
                    "vms"
                })
                .join(std::str::from_utf8(placement).map_err(|_| Refusal::Malformed)?);
            let mountpoint = if checkpoint {
                mountpoint.join("a")
            } else {
                mountpoint
            };
            let mut argv = vec![zfs()?, text("receive")?, text("-u")?];
            if !checkpoint {
                argv.push(text("-s")?);
            }
            argv.extend([
                text("-o")?,
                text(concat(&[b"mountpoint=", mountpoint.as_os_str().as_bytes()]))?,
            ]);
            for property in RECEIVE_PROPERTIES {
                if checkpoint && property == "quota=none" {
                    continue;
                }
                argv.extend([text("-o")?, text(property)?]);
            }
            if let Consumer::CheckpointReceive { memory_bytes, .. } = &stream.consumer {
                let memory = std::str::from_utf8(memory_bytes)
                    .ok()
                    .and_then(|value| value.parse::<u64>().ok())
                    .filter(|value| {
                        (536_870_912..=274_877_906_944).contains(value)
                            && value % 1_048_576 == 0
                            && value.to_string().as_bytes() == memory_bytes
                    })
                    .ok_or(Refusal::Malformed)?;
                argv.extend([text("-o")?, text(format!("quota={}", memory + 67_108_864))?]);
            }
            for (key, value) in [
                (&b"lilly:host="[..], host.as_slice()),
                (b"lilly:pool=", pool_id),
                (b"lilly:vm=", placement),
                (b"lilly:nonce=", marker),
            ] {
                argv.extend([text("-o")?, text(concat(&[key, value]))?]);
            }
            let target = if checkpoint {
                concat(&[&dataset, b"/checkpoint-", placement, b"-a"])
            } else {
                concat(&[&dataset, b"/vm-", placement])
            };
            argv.push(text(target)?);
            (argv, "-".to_string())
        }
        Consumer::Compare { path } => {
            if !inert_path(path) {
                return Err(Refusal::Malformed);
            }
            (
                vec![
                    executable(context, Utility::Cmp)?,
                    text("--silent")?,
                    text("--")?,
                    text(path)?,
                    text("-")?,
                ],
                unprivileged?,
            )
        }
    };
    let mut helper = vec![
        text(timeout_ms.to_string())?,
        text(rate.to_string())?,
        text(progress_fd.map_or("-".to_string(), |fd| fd.to_string()))?,
        text(producer_uid)?,
        text(consumer_uid)?,
        text(producer.len().to_string())?,
    ];
    helper.extend(producer);
    helper.extend(consumer);
    Ok(Plan {
        resume_check,
        helper,
    })
}
