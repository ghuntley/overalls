//! The closed binary protocol between Lilly and `lilly-hostd`.
//!
//! Every message is one `SOCK_SEQPACKET` datagram. Integers are big-endian.
//! A request starts with an operation byte and a caller-chosen request id;
//! every reply names the request id it answers.

use crate::utilities::Utility;
use std::ffi::CString;

/// Protocol version exchanged by `Hello`. A mismatch refuses the session.
pub const PROTOCOL_VERSION: u32 = 1;
/// Largest request datagram accepted (the old helper's frame bound).
pub const REQUEST_LIMIT: usize = 65_536;
/// Output bytes carried by one reply datagram; longer output is chunked.
pub const CHUNK_SIZE: usize = 32_768;
/// Standard captured-output bound in bytes.
pub const DEFAULT_OUTPUT_LIMIT: u32 = 65_536;
/// The only allowed extended captured-output bound in bytes.
pub const EXTENDED_OUTPUT_LIMIT: u32 = 4 * 1024 * 1024;
/// Maximum argv entries excluding the executable, which hostd chooses.
pub const MAX_ARGUMENTS: usize = 127;
/// Accepted utility timeout range in milliseconds.
pub const MIN_TIMEOUT_MS: u32 = 1000;
pub const MAX_TIMEOUT_MS: u32 = 14_400_000;
/// Longest a lease acquisition may wait in its queue.
pub const MAX_WAIT_MS: u32 = 120_000;
/// Longest accepted lock directory path in bytes.
pub const MAX_PATH: usize = 4096;

const OP_HELLO: u8 = 1;
const OP_ACQUIRE: u8 = 2;
const OP_RELEASE: u8 = 3;
const OP_RUN: u8 = 4;
const OP_CANCEL: u8 = 5;
const OP_RUN_DURABLE: u8 = 6;
const OP_ATTACH: u8 = 7;
const OP_LAUNCH_VM: u8 = 10;
const OP_TRANSFER_STREAM: u8 = 11;
const OP_CONNECT_UNIX: u8 = 12;
const OP_BRIDGE_NETNS_TCP: u8 = 13;
const OP_BRIDGE_INGRESS: u8 = 14;
const OP_LIST_INGRESS_BRIDGES: u8 = 15;
const OP_END_INGRESS_BRIDGE: u8 = 16;
/// Fixed `TransferStream` prefix: lease, timeout, rate, producer and consumer kinds.
const STREAM_FIXED: usize = 8 + 4 + 4 + 1 + 1;
/// Most NUL-terminated `TransferStream` fields (an SSH pull into a receive).
const MAX_STREAM_FIELDS: usize = 14;
/// Length of a durable job key.
pub const JOB_KEY: usize = 32;

const KIND_HELLO: u8 = 1;
const KIND_GRANTED: u8 = 2;
const KIND_REFUSED: u8 = 3;
const KIND_RELEASED: u8 = 4;
const KIND_CHUNK: u8 = 5;
const KIND_RESULT: u8 = 6;
const KIND_CONNECTED: u8 = 8;

/// How a lease is held.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum Mode {
    Exclusive,
    Shared,
}

/// One decoded client request.
#[derive(Debug, Eq, PartialEq)]
pub enum Request {
    Hello {
        version: u32,
    },
    Acquire {
        mode: Mode,
        wait_ms: u32,
        directory: Vec<u8>,
    },
    Release {
        lease: u64,
    },
    Run {
        lease: u64,
        timeout_ms: u32,
        output_limit: u32,
        utility: Utility,
        arguments: Vec<CString>,
    },
    Cancel {
        target: u64,
    },
    /// A command that outlives its session: it keeps its lease until it
    /// finishes, and any later session may attach to its result by key.
    RunDurable {
        key: [u8; JOB_KEY],
        lease: u64,
        timeout_ms: u32,
        output_limit: u32,
        utility: Utility,
        arguments: Vec<CString>,
    },
    /// Wait at most `wait_ms` for a durable job's result.
    Attach {
        key: [u8; JOB_KEY],
        wait_ms: u32,
    },
    /// Connect the caller's own unconnected Unix stream socket, which
    /// travels with the request, to a Firecracker API or vsock socket.
    ConnectUnix {
        timeout_ms: u32,
        path: Vec<u8>,
    },
    /// Start one VM's systemd unit; hostd builds the command line.
    LaunchVm {
        lease: u64,
        launch: crate::vm_launch::Launch,
    },
    /// Run one guest dataset stream under the stream lease; hostd builds
    /// every command line (hostd-transfer-stream-typed).
    TransferStream {
        lease: u64,
        timeout_ms: u32,
        rate: u32,
        stream: Box<crate::transfer::Stream>,
    },
    /// Dial TCP inside a VM network namespace and bridge it to the caller's
    /// own unconnected Unix stream socket, which travels with the request.
    BridgeNetnsTcp {
        mark: u32,
        destination: [u8; 4],
        port: u16,
        source: [u8; 4],
        timeout_ms: u32,
        namespace: Vec<u8>,
        device: Vec<u8>,
    },
    /// Dial TCP inside a VM network namespace exactly as `BridgeNetnsTcp` and
    /// bridge it to Audi's connection, which travels with the request, in a
    /// detached bridge named by `key` that outlives hostd (ADR-0187). hostd
    /// first writes `preface` to the guest and, when `expect` is not empty,
    /// requires the guest's next `expect.len()` bytes to equal it within
    /// `ready_ms` (ADR-0192); it then writes `greeting` to Audi's connection
    /// before any guest byte.
    BridgeIngress {
        key: [u8; crate::ingress::KEY],
        greeting: Vec<u8>,
        preface: Vec<u8>,
        expect: Vec<u8>,
        ready_ms: u32,
        mark: u32,
        destination: [u8; 4],
        port: u16,
        source: [u8; 4],
        timeout_ms: u32,
        namespace: Vec<u8>,
        device: Vec<u8>,
    },
    /// The keys of every live detached bridge.
    ListIngressBridges,
    /// End one detached bridge; an absent one is already ended.
    EndIngressBridge {
        key: [u8; crate::ingress::KEY],
    },
}

/// A request datagram: the caller's id plus the operation.
#[derive(Debug, Eq, PartialEq)]
pub struct Envelope {
    pub id: u64,
    pub request: Request,
}

/// Closed refusal reasons. Native error strings never cross the socket.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Refusal {
    /// The queue wait ended without the lease (contention).
    Contended = 1,
    /// The lock inode or its directory is unsafe or unavailable.
    Unavailable = 2,
    /// The request was malformed or out of bounds.
    Malformed = 3,
    /// The named lease is not held by this session.
    UnknownLease = 4,
    /// The lease already has a command in flight.
    LeaseBusy = 5,
    /// A mutating utility requires a lease.
    LeaseRequired = 6,
    /// The protocol version differs.
    Version = 7,
    /// No durable job has this key (never started, or its result expired).
    UnknownJob = 8,
    /// The attach wait ended while the job was still running.
    JobRunning = 9,
}

/// Command outcome, matching the old helper's status byte.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Status {
    Succeeded = 0,
    Failed = 1,
    TimedOut = 2,
    OutputLimit = 3,
    Setup = 4,
    /// The command was cancelled, its lease released or its session ended;
    /// it was killed and reaped before this reply.
    Cancelled = 5,
}

/// One reply datagram.
#[derive(Debug, Eq, PartialEq)]
pub enum Reply {
    Hello {
        version: u32,
    },
    Granted {
        lease: u64,
    },
    Refused {
        reason: Refusal,
    },
    Released,
    Chunk {
        bytes: Vec<u8>,
    },
    Result {
        status: Status,
        bytes: Vec<u8>,
    },
    /// The caller's socket is now connected (`ConnectUnix`, `BridgeNetnsTcp`,
    /// `BridgeIngress`).
    Connected,
}

/// @cc [owner:ghuntley,label:protocol;security] hostd-descriptor-requests-only
/// Exactly `ConnectUnix`, `BridgeNetnsTcp` and `BridgeIngress` carry one `SCM_RIGHTS`
/// descriptor: the caller's own socket, or for `BridgeIngress` the Audi
/// connection the BEAM accepted; every other request carries none. hostd
/// never sends a descriptor: the BEAM cannot release one it did not create
/// (ADR-0184).
pub fn carries_descriptor(request: &Request) -> bool {
    matches!(
        request,
        Request::ConnectUnix { .. }
            | Request::BridgeNetnsTcp { .. }
            | Request::BridgeIngress { .. }
    )
}

fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn u64_at(bytes: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(bytes.get(at..at + 8)?.try_into().ok()?))
}

/// @cc [owner:ghuntley,label:protocol;security] hostd-request-decoding-total
/// decode MUST return a request only for a datagram of at most 65536 bytes
/// that exactly matches one operation layout, and None for anything else:
/// unknown operations, trailing bytes, timeouts outside 1000..14400000 ms,
/// output limits other than 65536 or 4194304, waits above 120000 ms, a
/// directory that is not absolute or contains NUL or a `..` component, more
/// than 127 arguments, unterminated arguments, an unknown or typed-only
/// utility, or a `TransferStream` whose timeout is outside 1000..86400000 ms,
/// whose rate exceeds 1073741824, whose producer or consumer kind is unknown,
/// or whose NUL-terminated field count differs from those kinds' count, a
/// `ConnectUnix` or `BridgeNetnsTcp` whose timeout is outside 1..30000 ms, a
/// `ConnectUnix` path that is not a valid directory, a `BridgeNetnsTcp` with
/// port 0 or an empty namespace or device, a `BridgeIngress` whose greeting
/// exceeds 256 bytes, whose preface exceeds 4096 bytes, whose expected guest
/// frame exceeds 256 bytes, whose ready wait is not 0 for an empty expected
/// frame and 1..=30000 ms otherwise, or whose target fails `BridgeNetnsTcp`'s
/// rules, or a
/// `ListIngressBridges` or `EndIngressBridge` with any other body length.
/// The caller never names an executable: the utility is an index into the
/// closed table that hostd resolves itself.
#[expect(
    clippy::too_many_lines,
    reason = "one arm per wire request kind keeps the closed decoder in one reviewable match"
)]
pub fn decode(bytes: &[u8]) -> Option<Envelope> {
    if bytes.len() > REQUEST_LIMIT || bytes.len() < 9 {
        return None;
    }
    let op = bytes[0];
    let id = u64_at(bytes, 1)?;
    let body = &bytes[9..];
    let request = match op {
        OP_HELLO if body.len() == 4 => Request::Hello {
            version: u32_at(body, 0)?,
        },
        OP_ACQUIRE if body.len() >= 6 => {
            let mode = match body[0] {
                0 => Mode::Exclusive,
                1 => Mode::Shared,
                _ => return None,
            };
            let wait_ms = u32_at(body, 1)?;
            let directory = body[5..].to_vec();
            if wait_ms > MAX_WAIT_MS || !valid_directory(&directory) {
                return None;
            }
            Request::Acquire {
                mode,
                wait_ms,
                directory,
            }
        }
        OP_RELEASE if body.len() == 8 => Request::Release {
            lease: u64_at(body, 0)?,
        },
        OP_RUN if body.len() >= 17 => {
            let (lease, timeout_ms, output_limit, utility, arguments) = run_body(body)?;
            Request::Run {
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            }
        }
        OP_RUN_DURABLE if body.len() >= JOB_KEY + 17 => {
            let key: [u8; JOB_KEY] = body[..JOB_KEY].try_into().ok()?;
            let (lease, timeout_ms, output_limit, utility, arguments) = run_body(&body[JOB_KEY..])?;
            Request::RunDurable {
                key,
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            }
        }
        OP_ATTACH if body.len() == JOB_KEY + 4 => {
            let wait_ms = u32_at(body, JOB_KEY)?;
            if wait_ms > MAX_WAIT_MS {
                return None;
            }
            Request::Attach {
                key: body[..JOB_KEY].try_into().ok()?,
                wait_ms,
            }
        }
        OP_CONNECT_UNIX if body.len() > 4 => {
            let timeout_ms = u32_at(body, 0)?;
            if !(1..=30_000).contains(&timeout_ms) || !valid_directory(&body[4..]) {
                return None;
            }
            Request::ConnectUnix {
                timeout_ms,
                path: body[4..].to_vec(),
            }
        }
        OP_BRIDGE_NETNS_TCP => {
            let target = netns_target(body)?;
            Request::BridgeNetnsTcp {
                mark: target.mark,
                destination: target.destination,
                port: target.port,
                source: target.source,
                timeout_ms: target.timeout_ms,
                namespace: target.namespace,
                device: target.device,
            }
        }
        OP_BRIDGE_INGRESS if body.len() >= crate::ingress::KEY => {
            let key: [u8; crate::ingress::KEY] = body[..crate::ingress::KEY].try_into().ok()?;
            let rest = &body[crate::ingress::KEY..];
            let (greeting, rest) = sized(rest, crate::ingress::MAX_GREETING)?;
            let (preface, rest) = sized(rest, crate::ingress::MAX_PREFACE)?;
            let (expect, rest) = sized(rest, crate::ingress::MAX_EXPECT)?;
            let ready_ms = u32_at(rest, 0)?;
            let ready_valid = if expect.is_empty() {
                ready_ms == 0
            } else {
                (1..=crate::ingress::MAX_READY_MS).contains(&ready_ms)
            };
            if !ready_valid {
                return None;
            }
            let target = netns_target(&rest[4..])?;
            Request::BridgeIngress {
                key,
                greeting: greeting.to_vec(),
                preface: preface.to_vec(),
                expect: expect.to_vec(),
                ready_ms,
                mark: target.mark,
                destination: target.destination,
                port: target.port,
                source: target.source,
                timeout_ms: target.timeout_ms,
                namespace: target.namespace,
                device: target.device,
            }
        }
        OP_LIST_INGRESS_BRIDGES if body.is_empty() => Request::ListIngressBridges,
        OP_END_INGRESS_BRIDGE if body.len() == crate::ingress::KEY => Request::EndIngressBridge {
            key: body.try_into().ok()?,
        },
        OP_LAUNCH_VM if body.len() >= LAUNCH_FIXED + 3 => {
            let flags = body[LAUNCH_FIXED - 3];
            let state_length = usize::from(body[LAUNCH_FIXED - 2]);
            let namespace_length = usize::from(body[LAUNCH_FIXED - 1]);
            let rest = &body[LAUNCH_FIXED..];
            if flags & !0b111 != 0
                || state_length == 0
                || namespace_length == 0
                || state_length + namespace_length >= rest.len()
            {
                return None;
            }
            Request::LaunchVm {
                lease: u64_at(body, 0)?,
                launch: crate::vm_launch::Launch {
                    placement: body[8..44].try_into().ok()?,
                    epoch: u64_at(body, 44)?,
                    generation: u64_at(body, 52)?,
                    uid: u32_at(body, 60)?,
                    memory_bytes: u64_at(body, 64)?,
                    vcpus: body[72],
                    firmware: flags & 0b01 != 0,
                    logging: flags & 0b10 != 0,
                    restore: flags & 0b100 != 0,
                    state_dir: rest[..state_length].to_vec(),
                    namespace: rest[state_length..state_length + namespace_length].to_vec(),
                    pool: rest[state_length + namespace_length..].to_vec(),
                },
            }
        }
        OP_TRANSFER_STREAM if body.len() > STREAM_FIXED => {
            let timeout_ms = u32_at(body, 8)?;
            let rate = u32_at(body, 12)?;
            if !crate::transfer::TIMEOUTS.contains(&timeout_ms)
                || !crate::transfer::RATES.contains(&rate)
            {
                return None;
            }
            let mut fields = Vec::new();
            let mut rest = &body[STREAM_FIXED..];
            while !rest.is_empty() {
                if fields.len() == MAX_STREAM_FIELDS {
                    return None;
                }
                let end = rest.iter().position(|byte| *byte == 0)?;
                fields.push(rest[..end].to_vec());
                rest = &rest[end + 1..];
            }
            Request::TransferStream {
                lease: u64_at(body, 0)?,
                timeout_ms,
                rate,
                stream: Box::new(crate::transfer::Stream::decode(body[16], body[17], fields)?),
            }
        }
        OP_CANCEL if body.len() == 8 => Request::Cancel {
            target: u64_at(body, 0)?,
        },
        _ => return None,
    };
    Some(Envelope { id, request })
}

type RunBody = (u64, u32, u32, Utility, Vec<CString>);

/// Fixed `LaunchVm` prefix: lease, placement, epoch, generation, uid, memory,
/// vCPUs, flags, the state directory length and the namespace length.
const LAUNCH_FIXED: usize = 8 + 36 + 8 + 8 + 4 + 8 + 1 + 1 + 1 + 1;

fn port_zero(body: &[u8]) -> bool {
    body[8] == 0 && body[9] == 0
}

/// A u16 big-endian length, at most `maximum`, and that many bytes; the
/// field and what follows it, or None.
fn sized(body: &[u8], maximum: usize) -> Option<(&[u8], &[u8])> {
    let length = usize::from(u16::from_be_bytes([*body.first()?, *body.get(1)?]));
    let rest = &body[2..];
    if length > maximum || length > rest.len() {
        return None;
    }
    Some(rest.split_at(length))
}

/// A namespace TCP target as `BridgeNetnsTcp` and `BridgeIngress` carry it.
struct NetnsTarget {
    mark: u32,
    destination: [u8; 4],
    port: u16,
    source: [u8; 4],
    timeout_ms: u32,
    namespace: Vec<u8>,
    device: Vec<u8>,
}

/// Parse mark, destination, port, source, timeout, the namespace length,
/// the namespace and the device; port 0, an empty namespace or device, or a
/// timeout outside 1..=30000 ms is None.
fn netns_target(body: &[u8]) -> Option<NetnsTarget> {
    if body.len() < 20 {
        return None;
    }
    let namespace_length = usize::from(body[18]);
    let rest = &body[19..];
    if namespace_length == 0 || namespace_length >= rest.len() || port_zero(body) {
        return None;
    }
    let timeout_ms = u32_at(body, 14)?;
    if !(1..=30_000).contains(&timeout_ms) {
        return None;
    }
    Some(NetnsTarget {
        mark: u32_at(body, 0)?,
        destination: body[4..8].try_into().ok()?,
        port: u16::from_be_bytes([body[8], body[9]]),
        source: body[10..14].try_into().ok()?,
        timeout_ms,
        namespace: rest[..namespace_length].to_vec(),
        device: rest[namespace_length..].to_vec(),
    })
}

/// Parse the shared Run layout: lease, timeout, output limit, utility and
/// NUL-terminated arguments.
fn run_body(body: &[u8]) -> Option<RunBody> {
    if body.len() < 17 {
        return None;
    }
    let lease = u64_at(body, 0)?;
    let timeout_ms = u32_at(body, 8)?;
    let output_limit = u32_at(body, 12)?;
    let utility = Utility::from_index(body[16])?;
    // Reachable only through typed requests whose command lines hostd
    // builds itself (typed-only-utilities).
    if utility.typed_only() {
        return None;
    }
    if !(MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&timeout_ms)
        || (output_limit != DEFAULT_OUTPUT_LIMIT && output_limit != EXTENDED_OUTPUT_LIMIT)
    {
        return None;
    }
    let mut arguments = Vec::new();
    let mut rest = &body[17..];
    while !rest.is_empty() {
        if arguments.len() == MAX_ARGUMENTS {
            return None;
        }
        let end = rest.iter().position(|byte| *byte == 0)?;
        arguments.push(CString::new(&rest[..end]).ok()?);
        rest = &rest[end + 1..];
    }
    Some((lease, timeout_ms, output_limit, utility, arguments))
}

/// Whether a lock directory is absolute, NUL-free, bounded and free of `.`,
/// `..` and empty components.
pub fn valid_directory(directory: &[u8]) -> bool {
    directory.len() <= MAX_PATH
        && directory.first() == Some(&b'/')
        && !directory.contains(&0)
        && directory[1..]
            .split(|byte| *byte == b'/')
            .all(|part| !part.is_empty() && part != b"." && part != b"..")
}

/// Encode a request (used by tests and by documentation of the layout).
#[expect(
    clippy::too_many_lines,
    reason = "one arm per wire request kind mirrors decode"
)]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the inverse of decode: requests that decode accepts fit the u8 and u16 length fields; any other length keeps the existing wire truncation"
)]
pub fn encode_request(envelope: &Envelope) -> Vec<u8> {
    let mut out = Vec::new();
    let op = match envelope.request {
        Request::Hello { .. } => OP_HELLO,
        Request::Acquire { .. } => OP_ACQUIRE,
        Request::Release { .. } => OP_RELEASE,
        Request::Run { .. } => OP_RUN,
        Request::Cancel { .. } => OP_CANCEL,
        Request::RunDurable { .. } => OP_RUN_DURABLE,
        Request::Attach { .. } => OP_ATTACH,
        Request::ConnectUnix { .. } => OP_CONNECT_UNIX,
        Request::BridgeNetnsTcp { .. } => OP_BRIDGE_NETNS_TCP,
        Request::BridgeIngress { .. } => OP_BRIDGE_INGRESS,
        Request::ListIngressBridges => OP_LIST_INGRESS_BRIDGES,
        Request::EndIngressBridge { .. } => OP_END_INGRESS_BRIDGE,
        Request::LaunchVm { .. } => OP_LAUNCH_VM,
        Request::TransferStream { .. } => OP_TRANSFER_STREAM,
    };
    out.push(op);
    out.extend(envelope.id.to_be_bytes());
    match &envelope.request {
        Request::Hello { version } => out.extend(version.to_be_bytes()),
        Request::Acquire {
            mode,
            wait_ms,
            directory,
        } => {
            out.push(match mode {
                Mode::Exclusive => 0,
                Mode::Shared => 1,
            });
            out.extend(wait_ms.to_be_bytes());
            out.extend(directory);
        }
        Request::Release { lease } => out.extend(lease.to_be_bytes()),
        Request::Run {
            lease,
            timeout_ms,
            output_limit,
            utility,
            arguments,
        } => {
            out.extend(lease.to_be_bytes());
            out.extend(timeout_ms.to_be_bytes());
            out.extend(output_limit.to_be_bytes());
            out.push(utility.index());
            for argument in arguments {
                out.extend(argument.as_bytes());
                out.push(0);
            }
        }
        Request::Cancel { target } => out.extend(target.to_be_bytes()),
        Request::RunDurable {
            key,
            lease,
            timeout_ms,
            output_limit,
            utility,
            arguments,
        } => {
            out.extend(key);
            out.extend(lease.to_be_bytes());
            out.extend(timeout_ms.to_be_bytes());
            out.extend(output_limit.to_be_bytes());
            out.push(utility.index());
            for argument in arguments {
                out.extend(argument.as_bytes());
                out.push(0);
            }
        }
        Request::Attach { key, wait_ms } => {
            out.extend(key);
            out.extend(wait_ms.to_be_bytes());
        }
        Request::ConnectUnix { timeout_ms, path } => {
            out.extend(timeout_ms.to_be_bytes());
            out.extend(path);
        }
        Request::LaunchVm { lease, launch } => {
            out.extend(lease.to_be_bytes());
            out.extend(launch.placement);
            out.extend(launch.epoch.to_be_bytes());
            out.extend(launch.generation.to_be_bytes());
            out.extend(launch.uid.to_be_bytes());
            out.extend(launch.memory_bytes.to_be_bytes());
            out.push(launch.vcpus);
            out.push(
                u8::from(launch.firmware)
                    | (u8::from(launch.logging) << 1)
                    | (u8::from(launch.restore) << 2),
            );
            out.push(launch.state_dir.len() as u8);
            out.push(launch.namespace.len() as u8);
            out.extend(&launch.state_dir);
            out.extend(&launch.namespace);
            out.extend(&launch.pool);
        }
        Request::TransferStream {
            lease,
            timeout_ms,
            rate,
            stream,
        } => {
            let (producer, consumer, fields) = stream.encode();
            out.extend(lease.to_be_bytes());
            out.extend(timeout_ms.to_be_bytes());
            out.extend(rate.to_be_bytes());
            out.push(producer);
            out.push(consumer);
            for field in fields {
                out.extend(field);
                out.push(0);
            }
        }
        Request::BridgeNetnsTcp {
            mark,
            destination,
            port,
            source,
            timeout_ms,
            namespace,
            device,
        } => {
            out.extend(mark.to_be_bytes());
            out.extend(destination);
            out.extend(port.to_be_bytes());
            out.extend(source);
            out.extend(timeout_ms.to_be_bytes());
            out.push(namespace.len() as u8);
            out.extend(namespace);
            out.extend(device);
        }
        Request::BridgeIngress {
            key,
            greeting,
            preface,
            expect,
            ready_ms,
            mark,
            destination,
            port,
            source,
            timeout_ms,
            namespace,
            device,
        } => {
            out.extend(key);
            for field in [greeting, preface, expect] {
                out.extend((field.len() as u16).to_be_bytes());
                out.extend(field);
            }
            out.extend(ready_ms.to_be_bytes());
            out.extend(mark.to_be_bytes());
            out.extend(destination);
            out.extend(port.to_be_bytes());
            out.extend(source);
            out.extend(timeout_ms.to_be_bytes());
            out.push(namespace.len() as u8);
            out.extend(namespace);
            out.extend(device);
        }
        Request::ListIngressBridges => {}
        Request::EndIngressBridge { key } => out.extend(key),
    }
    out
}

/// Encode one reply datagram answering request `id`.
#[expect(
    clippy::match_same_arms,
    reason = "one arm per reply kind mirrors decode_reply; merging would hide which kinds share a wire layout"
)]
pub fn encode_reply(id: u64, reply: &Reply) -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    let kind = match reply {
        Reply::Hello { .. } => KIND_HELLO,
        Reply::Granted { .. } => KIND_GRANTED,
        Reply::Refused { .. } => KIND_REFUSED,
        Reply::Released => KIND_RELEASED,
        Reply::Chunk { .. } => KIND_CHUNK,
        Reply::Result { .. } => KIND_RESULT,
        Reply::Connected => KIND_CONNECTED,
    };
    out.push(kind);
    out.extend(id.to_be_bytes());
    match reply {
        Reply::Hello { version } => out.extend(version.to_be_bytes()),
        Reply::Granted { lease } => out.extend(lease.to_be_bytes()),
        Reply::Refused { reason } => out.push(*reason as u8),
        Reply::Released => {}
        Reply::Chunk { bytes } => out.extend(bytes),
        Reply::Result { status, bytes } => {
            out.push(*status as u8);
            out.extend(bytes);
        }
        Reply::Connected => {}
    }
    out
}

/// Decode a reply datagram (used by tests; Lilly has its own decoder).
pub fn decode_reply(bytes: &[u8]) -> Option<(u64, Reply)> {
    let kind = *bytes.first()?;
    let id = u64_at(bytes, 1)?;
    let body = bytes.get(9..)?;
    let reply = match kind {
        KIND_HELLO if body.len() == 4 => Reply::Hello {
            version: u32_at(body, 0)?,
        },
        KIND_GRANTED if body.len() == 8 => Reply::Granted {
            lease: u64_at(body, 0)?,
        },
        KIND_REFUSED if body.len() == 1 => Reply::Refused {
            reason: match body[0] {
                1 => Refusal::Contended,
                2 => Refusal::Unavailable,
                3 => Refusal::Malformed,
                4 => Refusal::UnknownLease,
                5 => Refusal::LeaseBusy,
                6 => Refusal::LeaseRequired,
                7 => Refusal::Version,
                8 => Refusal::UnknownJob,
                9 => Refusal::JobRunning,
                _ => return None,
            },
        },
        KIND_RELEASED if body.is_empty() => Reply::Released,
        KIND_CONNECTED if body.is_empty() => Reply::Connected,
        KIND_CHUNK => Reply::Chunk {
            bytes: body.to_vec(),
        },
        KIND_RESULT if !body.is_empty() => Reply::Result {
            status: match body[0] {
                0 => Status::Succeeded,
                1 => Status::Failed,
                2 => Status::TimedOut,
                3 => Status::OutputLimit,
                4 => Status::Setup,
                5 => Status::Cancelled,
                _ => return None,
            },
            bytes: body[1..].to_vec(),
        },
        _ => return None,
    };
    Some((id, reply))
}
