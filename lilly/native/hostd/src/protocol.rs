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
    Some(u32::from_be_bytes(
        bytes.get(at..at.checked_add(4)?)?.try_into().ok()?,
    ))
}

fn u64_at(bytes: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(
        bytes.get(at..at.checked_add(8)?)?.try_into().ok()?,
    ))
}

/// Why a request datagram did not decode. The reasons are closed and carry
/// no wire bytes or native text; the session answers every one alike, by
/// ending the session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecodeError {
    /// Shorter than the 9-byte header, or longer than `REQUEST_LIMIT`.
    Size,
    /// The operation byte names no request.
    Operation,
    /// The body is shorter or longer than its operation's layout, a length
    /// field names more bytes than follow it, or a NUL-terminated field is
    /// unterminated.
    Layout,
    /// A field is outside what its operation accepts: a timeout, limit, wait,
    /// mode, flag, kind, utility, path, name, port, length or count.
    Value,
}

type Decoded<T> = Result<T, DecodeError>;

/// A field the operation refuses unless `accepted`.
fn require(accepted: bool) -> Decoded<()> {
    if accepted {
        Ok(())
    } else {
        Err(DecodeError::Value)
    }
}

/// A bounds-checked reader over untrusted bytes: a read past the end is
/// `Layout`, never a panic.
struct Cursor<'a> {
    rest: &'a [u8],
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Cursor { rest: bytes }
    }

    fn take(&mut self, count: usize) -> Decoded<&'a [u8]> {
        let (head, tail) = self
            .rest
            .split_at_checked(count)
            .ok_or(DecodeError::Layout)?;
        self.rest = tail;
        Ok(head)
    }

    fn array<const N: usize>(&mut self) -> Decoded<[u8; N]> {
        self.take(N)?.try_into().map_err(|_| DecodeError::Layout)
    }

    fn u8(&mut self) -> Decoded<u8> {
        let [byte] = self.array::<1>()?;
        Ok(byte)
    }

    fn u16(&mut self) -> Decoded<u16> {
        Ok(u16::from_be_bytes(self.array()?))
    }

    fn u32(&mut self) -> Decoded<u32> {
        Ok(u32::from_be_bytes(self.array()?))
    }

    fn u64(&mut self) -> Decoded<u64> {
        Ok(u64::from_be_bytes(self.array()?))
    }

    /// Every remaining byte.
    fn rest(self) -> &'a [u8] {
        self.rest
    }

    /// The layout ends here: trailing bytes are `Layout`.
    fn finish(self) -> Decoded<()> {
        if self.rest.is_empty() {
            Ok(())
        } else {
            Err(DecodeError::Layout)
        }
    }
}

/// @cc [owner:ghuntley,label:protocol;security] hostd-request-decoding-total
/// decode MUST return a request only for a datagram of at most 65536 bytes
/// that exactly matches one operation layout, and a `DecodeError` for
/// anything else: unknown operations, trailing bytes, timeouts outside 1000..14400000 ms,
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
/// closed table that hostd resolves itself. decode MUST NOT panic on any
/// input: every read is bounds-checked, because under `panic = "abort"` one
/// panic would end the whole daemon.
pub fn decode(bytes: &[u8]) -> Result<Envelope, DecodeError> {
    if bytes.len() > REQUEST_LIMIT {
        return Err(DecodeError::Size);
    }
    let Some((header, body)) = bytes.split_at_checked(9) else {
        return Err(DecodeError::Size);
    };
    let mut header = Cursor::new(header);
    let op = header.u8()?;
    let id = header.u64()?;
    let mut fields = Cursor::new(body);
    let request = match op {
        OP_HELLO => {
            let version = fields.u32()?;
            fields.finish()?;
            Request::Hello { version }
        }
        OP_ACQUIRE => acquire(fields)?,
        OP_RELEASE => {
            let lease = fields.u64()?;
            fields.finish()?;
            Request::Release { lease }
        }
        OP_RUN => {
            let (lease, timeout_ms, output_limit, utility, arguments) = run_body(fields)?;
            Request::Run {
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            }
        }
        OP_RUN_DURABLE => {
            let key = fields.array::<JOB_KEY>()?;
            let (lease, timeout_ms, output_limit, utility, arguments) = run_body(fields)?;
            Request::RunDurable {
                key,
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            }
        }
        OP_ATTACH => {
            let key = fields.array::<JOB_KEY>()?;
            let wait_ms = fields.u32()?;
            fields.finish()?;
            require(wait_ms <= MAX_WAIT_MS)?;
            Request::Attach { key, wait_ms }
        }
        OP_CONNECT_UNIX => {
            let timeout_ms = fields.u32()?;
            let path = fields.rest();
            require((1..=30_000).contains(&timeout_ms) && valid_directory(path))?;
            Request::ConnectUnix {
                timeout_ms,
                path: path.to_vec(),
            }
        }
        OP_BRIDGE_NETNS_TCP => {
            let target = netns_target(fields)?;
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
        OP_BRIDGE_INGRESS => bridge_ingress(fields)?,
        OP_LIST_INGRESS_BRIDGES => {
            fields.finish()?;
            Request::ListIngressBridges
        }
        OP_END_INGRESS_BRIDGE => {
            let key = fields.array::<{ crate::ingress::KEY }>()?;
            fields.finish()?;
            Request::EndIngressBridge { key }
        }
        OP_LAUNCH_VM => launch_vm(fields)?,
        OP_TRANSFER_STREAM => transfer_stream(fields)?,
        OP_CANCEL => {
            let target = fields.u64()?;
            fields.finish()?;
            Request::Cancel { target }
        }
        _ => return Err(DecodeError::Operation),
    };
    Ok(Envelope { id, request })
}

type RunBody = (u64, u32, u32, Utility, Vec<CString>);

/// Mode, wait and directory.
fn acquire(mut fields: Cursor<'_>) -> Decoded<Request> {
    let mode = match fields.u8()? {
        0 => Mode::Exclusive,
        1 => Mode::Shared,
        _ => return Err(DecodeError::Value),
    };
    let wait_ms = fields.u32()?;
    let directory = fields.rest();
    require(wait_ms <= MAX_WAIT_MS && valid_directory(directory))?;
    Ok(Request::Acquire {
        mode,
        wait_ms,
        directory: directory.to_vec(),
    })
}

/// Key, three u16-sized fields, the ready wait and a namespace target.
fn bridge_ingress(mut fields: Cursor<'_>) -> Decoded<Request> {
    let key = fields.array::<{ crate::ingress::KEY }>()?;
    let greeting = sized(&mut fields, crate::ingress::MAX_GREETING)?;
    let preface = sized(&mut fields, crate::ingress::MAX_PREFACE)?;
    let expect = sized(&mut fields, crate::ingress::MAX_EXPECT)?;
    let ready_ms = fields.u32()?;
    require(if expect.is_empty() {
        ready_ms == 0
    } else {
        (1..=crate::ingress::MAX_READY_MS).contains(&ready_ms)
    })?;
    let target = netns_target(fields)?;
    Ok(Request::BridgeIngress {
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
    })
}

/// Lease, placement, epoch, generation, uid, memory, vCPUs, flags, the state
/// directory and namespace lengths, then the state directory, the namespace
/// and the (non-empty) pool.
fn launch_vm(mut fields: Cursor<'_>) -> Decoded<Request> {
    let lease = fields.u64()?;
    let placement = fields.array::<36>()?;
    let epoch = fields.u64()?;
    let generation = fields.u64()?;
    let uid = fields.u32()?;
    let memory_bytes = fields.u64()?;
    let vcpus = fields.u8()?;
    let flags = fields.u8()?;
    let state_length = usize::from(fields.u8()?);
    let namespace_length = usize::from(fields.u8()?);
    require(flags & !0b111 == 0 && state_length != 0 && namespace_length != 0)?;
    let (state_dir, rest) = fields
        .rest()
        .split_at_checked(state_length)
        .ok_or(DecodeError::Layout)?;
    let (namespace, pool) = rest
        .split_at_checked(namespace_length)
        .ok_or(DecodeError::Layout)?;
    require(!pool.is_empty())?;
    Ok(Request::LaunchVm {
        lease,
        launch: crate::vm_launch::Launch {
            placement,
            epoch,
            generation,
            uid,
            memory_bytes,
            vcpus,
            firmware: flags & 0b01 != 0,
            logging: flags & 0b10 != 0,
            restore: flags & 0b100 != 0,
            state_dir: state_dir.to_vec(),
            namespace: namespace.to_vec(),
            pool: pool.to_vec(),
        },
    })
}

/// Lease, timeout, rate, producer and consumer kinds, then NUL-terminated
/// fields.
fn transfer_stream(mut fields: Cursor<'_>) -> Decoded<Request> {
    let lease = fields.u64()?;
    let timeout_ms = fields.u32()?;
    let rate = fields.u32()?;
    let producer = fields.u8()?;
    let consumer = fields.u8()?;
    require(
        crate::transfer::TIMEOUTS.contains(&timeout_ms) && crate::transfer::RATES.contains(&rate),
    )?;
    let strings = nul_terminated(fields.rest(), MAX_STREAM_FIELDS)?
        .into_iter()
        .map(<[u8]>::to_vec)
        .collect();
    let stream =
        crate::transfer::Stream::decode(producer, consumer, strings).ok_or(DecodeError::Value)?;
    Ok(Request::TransferStream {
        lease,
        timeout_ms,
        rate,
        stream: Box::new(stream),
    })
}

/// Split `rest` into NUL-terminated fields: more than `maximum` is `Value`,
/// a last field without its NUL is `Layout`.
fn nul_terminated(mut rest: &[u8], maximum: usize) -> Decoded<Vec<&[u8]>> {
    let mut fields = Vec::new();
    while !rest.is_empty() {
        if fields.len() == maximum {
            return Err(DecodeError::Value);
        }
        let end = rest
            .iter()
            .position(|byte| *byte == 0)
            .ok_or(DecodeError::Layout)?;
        let (field, tail) = rest.split_at_checked(end).ok_or(DecodeError::Layout)?;
        fields.push(field);
        rest = tail.get(1..).ok_or(DecodeError::Layout)?;
    }
    Ok(fields)
}

/// A u16 big-endian length, at most `maximum` (else `Value`), and that many
/// bytes (else `Layout`).
fn sized<'a>(fields: &mut Cursor<'a>, maximum: usize) -> Decoded<&'a [u8]> {
    let length = usize::from(fields.u16()?);
    require(length <= maximum)?;
    fields.take(length)
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
/// timeout outside 1..=30000 ms is `Value`, a namespace longer than the bytes
/// left is `Layout`.
fn netns_target(mut fields: Cursor<'_>) -> Decoded<NetnsTarget> {
    let mark = fields.u32()?;
    let destination = fields.array::<4>()?;
    let port = fields.u16()?;
    let source = fields.array::<4>()?;
    let timeout_ms = fields.u32()?;
    let namespace_length = usize::from(fields.u8()?);
    require(namespace_length != 0 && port != 0 && (1..=30_000).contains(&timeout_ms))?;
    let (namespace, device) = fields
        .rest()
        .split_at_checked(namespace_length)
        .ok_or(DecodeError::Layout)?;
    require(!device.is_empty())?;
    Ok(NetnsTarget {
        mark,
        destination,
        port,
        source,
        timeout_ms,
        namespace: namespace.to_vec(),
        device: device.to_vec(),
    })
}

/// Parse the shared Run layout: lease, timeout, output limit, utility and
/// NUL-terminated arguments.
fn run_body(mut fields: Cursor<'_>) -> Decoded<RunBody> {
    let lease = fields.u64()?;
    let timeout_ms = fields.u32()?;
    let output_limit = fields.u32()?;
    let utility = Utility::from_index(fields.u8()?).ok_or(DecodeError::Value)?;
    // Reachable only through typed requests whose command lines hostd
    // builds itself (typed-only-utilities).
    require(
        !utility.typed_only()
            && (MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&timeout_ms)
            && (output_limit == DEFAULT_OUTPUT_LIMIT || output_limit == EXTENDED_OUTPUT_LIMIT),
    )?;
    let arguments = nul_terminated(fields.rest(), MAX_ARGUMENTS)?
        .into_iter()
        .map(|argument| CString::new(argument).map_err(|_| DecodeError::Layout))
        .collect::<Decoded<Vec<CString>>>()?;
    Ok((lease, timeout_ms, output_limit, utility, arguments))
}

/// Whether a lock directory is absolute, NUL-free, bounded and free of `.`,
/// `..` and empty components.
pub fn valid_directory(directory: &[u8]) -> bool {
    directory.len() <= MAX_PATH
        && !directory.contains(&0)
        && directory.strip_prefix(b"/").is_some_and(|relative| {
            relative
                .split(|byte| *byte == b'/')
                .all(|part| !part.is_empty() && part != b"." && part != b"..")
        })
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
            reason: match *body.first()? {
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
            status: match *body.first()? {
                0 => Status::Succeeded,
                1 => Status::Failed,
                2 => Status::TimedOut,
                3 => Status::OutputLimit,
                4 => Status::Setup,
                5 => Status::Cancelled,
                _ => return None,
            },
            bytes: body.get(1..)?.to_vec(),
        },
        _ => return None,
    };
    Some((id, reply))
}
