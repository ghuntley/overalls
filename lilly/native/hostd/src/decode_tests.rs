//! Decoder totality: arbitrary, truncated and length-corrupted datagrams
//! never panic the decoder or a session thread.

use crate::exec::{start_reaper, Custody};
use crate::leases::Leases;
use crate::protocol::*;
use crate::session::{serve, Daemon};
use crate::utilities::{Table, Utility};
use hegel::{generators as gs, TestCase};
use rustix::net::{
    recv, send, socketpair, AddressFamily, RecvFlags, SendFlags, SocketFlags, SocketType,
};
use std::ffi::CString;
use std::os::fd::OwnedFd;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, OnceLock};
use std::thread::JoinHandle;

/// Decode under `catch_unwind`, failing the test on any panic.
fn decode_total(bytes: &[u8]) -> Result<Envelope, DecodeError> {
    catch_unwind(AssertUnwindSafe(|| decode(bytes)))
        .unwrap_or_else(|_| panic!("decode panicked on {bytes:?}"))
}

/// Every accepted datagram is exactly one layout: it re-encodes to itself.
fn accepted_exactly(bytes: &[u8], decoded: &Result<Envelope, DecodeError>) {
    if let Ok(envelope) = decoded {
        assert_eq!(encode_request(envelope), bytes, "accepted {envelope:?}");
    }
}

const PLACEMENT: [u8; 36] = *b"11111111-2222-4333-8444-555555555555";

/// One valid request of every operation, with drawn variable parts.
#[expect(clippy::too_many_lines, reason = "one arm per wire request kind")]
fn valid_request(tc: &TestCase, kind: u8) -> Request {
    let name = |tc: &TestCase, max: usize| -> Vec<u8> {
        let length = tc.draw(gs::integers::<usize>().min_value(1).max_value(max));
        vec![b'a'; length]
    };
    let target_timeout =
        |tc: &TestCase| tc.draw(gs::integers::<u32>().min_value(1).max_value(30_000));
    let port = |tc: &TestCase| tc.draw(gs::integers::<u16>().min_value(1));
    match kind {
        0 => Request::Hello {
            version: tc.draw(gs::integers::<u32>()),
        },
        1 => Request::Acquire {
            mode: if tc.draw(gs::booleans()) {
                Mode::Shared
            } else {
                Mode::Exclusive
            },
            wait_ms: tc.draw(gs::integers::<u32>().max_value(MAX_WAIT_MS)),
            directory: [b"/".as_slice(), &name(tc, 40)].concat(),
        },
        2 => Request::Release {
            lease: tc.draw(gs::integers::<u64>()),
        },
        3 | 4 => {
            let arguments: Vec<CString> = (0..tc.draw(gs::integers::<usize>().max_value(6)))
                .map(|_| CString::new(name(tc, 8)).unwrap())
                .collect();
            let (lease, timeout_ms) = (tc.draw(gs::integers::<u64>()), 5_000);
            if tc.draw(gs::booleans()) {
                Request::Run {
                    lease,
                    timeout_ms,
                    output_limit: DEFAULT_OUTPUT_LIMIT,
                    utility: Utility::Stat,
                    arguments,
                }
            } else {
                Request::RunDurable {
                    key: [7; JOB_KEY],
                    lease,
                    timeout_ms,
                    output_limit: EXTENDED_OUTPUT_LIMIT,
                    utility: Utility::Stat,
                    arguments,
                }
            }
        }
        5 => Request::Cancel {
            target: tc.draw(gs::integers::<u64>()),
        },
        6 => Request::Attach {
            key: [3; JOB_KEY],
            wait_ms: tc.draw(gs::integers::<u32>().max_value(MAX_WAIT_MS)),
        },
        7 => Request::ConnectUnix {
            timeout_ms: target_timeout(tc),
            path: [b"/run/".as_slice(), &name(tc, 30)].concat(),
        },
        8 => Request::BridgeNetnsTcp {
            mark: tc.draw(gs::integers::<u32>()),
            destination: [10, 0, 0, 2],
            port: port(tc),
            source: [0; 4],
            timeout_ms: target_timeout(tc),
            namespace: name(tc, 64),
            device: name(tc, 15),
        },
        9 => {
            let expect = tc.draw(gs::binary().max_size(crate::ingress::MAX_EXPECT));
            Request::BridgeIngress {
                key: [5; crate::ingress::KEY],
                greeting: tc.draw(gs::binary().max_size(crate::ingress::MAX_GREETING)),
                preface: tc.draw(gs::binary().max_size(64)),
                ready_ms: if expect.is_empty() { 0 } else { 1_000 },
                expect,
                mark: 1,
                destination: [10, 0, 0, 2],
                port: port(tc),
                source: [10, 0, 0, 1],
                timeout_ms: target_timeout(tc),
                namespace: name(tc, 64),
                device: name(tc, 15),
            }
        }
        10 => Request::ListIngressBridges,
        11 => Request::EndIngressBridge {
            key: [9; crate::ingress::KEY],
        },
        12 => Request::LaunchVm {
            lease: tc.draw(gs::integers::<u64>()),
            launch: crate::vm_launch::Launch {
                placement: PLACEMENT,
                epoch: 7,
                generation: 9,
                uid: 1_000_010,
                memory_bytes: 1_342_177_280,
                vcpus: 2,
                firmware: tc.draw(gs::booleans()),
                logging: tc.draw(gs::booleans()),
                restore: tc.draw(gs::booleans()),
                state_dir: [b"/var/lib/".as_slice(), &name(tc, 40)].concat(),
                namespace: name(tc, 32),
                pool: [b"/".as_slice(), &name(tc, 20)].concat(),
            },
        },
        _ => Request::TransferStream {
            lease: tc.draw(gs::integers::<u64>()),
            timeout_ms: 5_000,
            rate: 0,
            stream: Box::new(crate::transfer::Stream {
                producer: crate::transfer::Producer::LocalSend {
                    dataset: b"tank/lilly".to_vec(),
                    placement: PLACEMENT.to_vec(),
                },
                consumer: crate::transfer::Consumer::Compare {
                    path: [b"/".as_slice(), &name(tc, 20)].concat(),
                },
            }),
        },
    }
}

/// A valid datagram of request kind `kind` (see `valid_request`); it
/// decodes to itself.
fn valid_frame_of(tc: &TestCase, kind: u8) -> Vec<u8> {
    let envelope = Envelope {
        id: tc.draw(gs::integers::<u64>()),
        request: valid_request(tc, kind),
    };
    let bytes = encode_request(&envelope);
    assert_eq!(decode_total(&bytes), Ok(envelope));
    bytes
}

/// A valid datagram of a drawn operation.
fn valid_frame(tc: &TestCase) -> Vec<u8> {
    let kind = tc.draw(gs::integers::<u8>().max_value(13));
    valid_frame_of(tc, kind)
}

/// @cc [owner:ghuntley,label:verification;security] hostd-decoder-total-property
/// For arbitrary bytes (biased towards known operation bytes and the size
/// bounds), decode MUST NOT panic, MUST return `Size` for datagrams shorter
/// than 9 or longer than 65536 bytes and `Operation` for an unknown
/// operation byte, and every accepted datagram MUST re-encode to itself.
#[hegel::test(test_cases = 500)]
fn arbitrary_bytes_decode_totally(tc: TestCase) {
    let op = tc.draw(gs::integers::<u8>());
    let mut bytes = vec![op];
    bytes.extend(tc.draw(gs::binary().max_size(600)));
    if tc.draw(gs::integers::<u8>().max_value(15)) == 0 {
        bytes.resize(
            REQUEST_LIMIT + tc.draw(gs::integers::<usize>().max_value(2)),
            0,
        );
    }
    let decoded = decode_total(&bytes);
    if bytes.len() < 9 || bytes.len() > REQUEST_LIMIT {
        assert_eq!(decoded, Err(DecodeError::Size));
    } else if !matches!(op, 1..=7 | 10..=16) {
        assert_eq!(decoded, Err(DecodeError::Operation));
    }
    accepted_exactly(&bytes, &decoded);
}

/// @cc [owner:ghuntley,label:verification;security] hostd-decoder-truncation-property
/// Every proper prefix of a valid datagram of every operation MUST decode
/// without panicking to a `DecodeError`, or to a request that re-encodes to
/// exactly that prefix (a shorter path or argument list is itself valid).
#[hegel::test(test_cases = 300)]
fn truncated_frames_decode_totally(tc: TestCase) {
    let bytes = valid_frame(&tc);
    let cut = tc.draw(gs::integers::<usize>().max_value(bytes.len() - 1));
    let prefix = &bytes[..cut];
    let decoded = decode_total(prefix);
    if cut < 9 {
        assert_eq!(decoded, Err(DecodeError::Size));
    }
    accepted_exactly(prefix, &decoded);
}

/// @cc [owner:ghuntley,label:verification;security] hostd-decoder-length-corruption-property
/// Overwriting any length field of a valid `LaunchVm`, `BridgeNetnsTcp` or
/// `BridgeIngress` datagram with an arbitrary value MUST decode without
/// panicking; a length naming more bytes than follow it MUST be a
/// `DecodeError`, and an accepted result MUST re-encode to the corrupted
/// bytes.
#[hegel::test(test_cases = 500)]
fn corrupted_lengths_decode_totally(tc: TestCase) {
    // BridgeNetnsTcp, BridgeIngress and LaunchVm in valid_request.
    let kind = tc.draw(gs::sampled_from(vec![8_u8, 9, 12]));
    let bytes = valid_frame_of(&tc, kind);
    let field = |at: usize| usize::from(u16::from_be_bytes([bytes[at], bytes[at + 1]]));
    // (offset, width) of each length field.
    let lengths: Vec<(usize, usize)> = match bytes[0] {
        10 => vec![(9 + 74, 1), (9 + 75, 1)],
        13 => vec![(9 + 18, 1)],
        _ => {
            let greeting_at = 9 + crate::ingress::KEY;
            let preface_at = greeting_at + 2 + field(greeting_at);
            let expect_at = preface_at + 2 + field(preface_at);
            let namespace_at = expect_at + 2 + field(expect_at) + 4 + 18;
            vec![
                (greeting_at, 2),
                (preface_at, 2),
                (expect_at, 2),
                (namespace_at, 1),
            ]
        }
    };
    let (at, width) = lengths[tc.draw(gs::integers::<usize>().max_value(lengths.len() - 1))];
    let left = bytes.len() - (at + width);
    let value = tc.draw(hegel::one_of!(
        gs::integers::<usize>().max_value(left + 1),
        gs::integers::<usize>()
            .min_value(left)
            .max_value(usize::from(u16::MAX)),
    ));
    let mut corrupted = bytes.clone();
    if width == 1 {
        corrupted[at] = u8::try_from(value).unwrap_or(u8::MAX);
    } else {
        corrupted[at..at + 2].copy_from_slice(&u16::try_from(value).unwrap().to_be_bytes());
    }
    let written = if width == 1 {
        usize::from(corrupted[at])
    } else {
        usize::from(u16::from_be_bytes([corrupted[at], corrupted[at + 1]]))
    };
    let decoded = decode_total(&corrupted);
    if written > left {
        assert!(decoded.is_err(), "overlong length accepted: {corrupted:?}");
    }
    accepted_exactly(&corrupted, &decoded);
}

/// Any one byte of any valid datagram overwritten with an arbitrary value
/// decodes without panicking, and an accepted result re-encodes to itself.
#[hegel::test(test_cases = 500)]
fn corrupted_bytes_decode_totally(tc: TestCase) {
    let mut bytes = valid_frame(&tc);
    let at = tc.draw(gs::integers::<usize>().max_value(bytes.len() - 1));
    bytes[at] = tc.draw(gs::integers::<u8>());
    let decoded = decode_total(&bytes);
    accepted_exactly(&bytes, &decoded);
}

#[test]
fn decode_errors_name_their_class() {
    assert_eq!(decode(&[]), Err(DecodeError::Size));
    assert_eq!(decode(&[1; 8]), Err(DecodeError::Size));
    assert_eq!(decode(&vec![1; REQUEST_LIMIT + 1]), Err(DecodeError::Size));
    assert_eq!(decode(&[99; 9]), Err(DecodeError::Operation));
    // A Hello one byte short and one byte long.
    let hello = encode_request(&Envelope {
        id: 1,
        request: Request::Hello { version: 1 },
    });
    assert_eq!(decode(&hello[..hello.len() - 1]), Err(DecodeError::Layout));
    assert_eq!(
        decode(&[hello.as_slice(), &[0]].concat()),
        Err(DecodeError::Layout)
    );
    // A LaunchVm whose state directory length runs past the datagram.
    let mut launch = encode_request(&Envelope {
        id: 1,
        request: Request::LaunchVm {
            lease: 1,
            launch: crate::vm_launch::Launch {
                placement: PLACEMENT,
                epoch: 1,
                generation: 1,
                uid: 1,
                memory_bytes: 1,
                vcpus: 1,
                firmware: false,
                logging: false,
                restore: false,
                state_dir: b"/s".to_vec(),
                namespace: b"n".to_vec(),
                pool: b"/p".to_vec(),
            },
        },
    });
    launch[9 + 74] = 255;
    assert_eq!(decode(&launch), Err(DecodeError::Layout));
    // A BridgeNetnsTcp whose namespace length leaves no device.
    let mut bridge = encode_request(&Envelope {
        id: 1,
        request: Request::BridgeNetnsTcp {
            mark: 1,
            destination: [10, 0, 0, 2],
            port: 22,
            source: [0; 4],
            timeout_ms: 1_000,
            namespace: b"ns".to_vec(),
            device: b"d".to_vec(),
        },
    });
    bridge[9 + 18] = 3;
    assert_eq!(decode(&bridge), Err(DecodeError::Value));
    bridge[9 + 18] = 4;
    assert_eq!(decode(&bridge), Err(DecodeError::Layout));
}

// ---------------------------------------------------------- session level

/// One daemon shared by every case: its utility table resolves nothing, so
/// no drawn request can run a host utility.
fn shared_daemon() -> Arc<Daemon> {
    static DAEMON: OnceLock<(tempfile::TempDir, Arc<Daemon>)> = OnceLock::new();
    let (_, daemon) = DAEMON.get_or_init(|| {
        start_reaper().expect("subreaper");
        let directory = tempfile::tempdir().expect("tempdir");
        let root = directory.path().join("root");
        std::fs::create_dir(&root).unwrap();
        let empty = directory.path().join("empty");
        std::fs::create_dir(&empty).unwrap();
        let daemon = Arc::new(Daemon::new(
            Leases::new(&[root]).unwrap(),
            Table::resolve(empty.as_os_str()),
            Custody::ProcessGroup,
            rustix::process::geteuid().as_raw(),
            Vec::new(),
        ));
        (directory, daemon)
    });
    Arc::clone(daemon)
}

/// A session served on its own thread over a socketpair; the handle reports
/// whether the session thread panicked.
fn session(daemon: Arc<Daemon>) -> (OwnedFd, JoinHandle<()>) {
    let (client, server) = socketpair(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    (client, std::thread::spawn(move || serve(daemon, server)))
}

fn request(socket: &OwnedFd, id: u64, request: Request) {
    send(
        socket,
        &encode_request(&Envelope { id, request }),
        SendFlags::NOSIGNAL,
    )
    .unwrap();
}

/// The next datagram, or None at end of stream.
fn reply(socket: &OwnedFd) -> Option<(u64, Reply)> {
    let mut buffer = vec![0_u8; 70_000];
    let (size, _) = recv(socket, &mut buffer, RecvFlags::empty()).unwrap();
    (size > 0).then(|| decode_reply(&buffer[..size]).expect("reply decodes"))
}

/// @cc [owner:ghuntley,label:verification;security] hostd-malformed-session-closes
/// A malformed datagram (truncated, length-corrupted or arbitrary), sent
/// first or after Hello, MUST end that session with a clean close and no
/// reply, without panicking its session thread; a new session on the same
/// daemon MUST then still answer Hello and a request.
#[hegel::test(test_cases = 200)]
fn malformed_datagrams_close_only_their_session(tc: TestCase) {
    let frame = match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => {
            let bytes = valid_frame(&tc);
            bytes[..tc.draw(gs::integers::<usize>().max_value(bytes.len() - 1))].to_vec()
        }
        1 => {
            let mut bytes = valid_frame(&tc);
            let at = tc.draw(gs::integers::<usize>().max_value(bytes.len() - 1));
            bytes[at] = tc.draw(gs::integers::<u8>());
            bytes
        }
        _ => tc.draw(gs::binary().min_size(1).max_size(300)),
    };
    tc.assume(decode(&frame).is_err());
    let daemon = shared_daemon();
    let (client, served) = session(Arc::clone(&daemon));
    if tc.draw(gs::booleans()) {
        request(
            &client,
            1,
            Request::Hello {
                version: PROTOCOL_VERSION,
            },
        );
        assert_eq!(
            reply(&client),
            Some((
                1,
                Reply::Hello {
                    version: PROTOCOL_VERSION
                }
            ))
        );
    }
    send(&client, &frame, SendFlags::NOSIGNAL).unwrap();
    assert_eq!(reply(&client), None, "malformed {frame:?} got a reply");
    assert!(
        served.join().is_ok(),
        "session thread panicked on {frame:?}"
    );
    let (next, served) = session(daemon);
    request(
        &next,
        2,
        Request::Hello {
            version: PROTOCOL_VERSION,
        },
    );
    assert_eq!(
        reply(&next),
        Some((
            2,
            Reply::Hello {
                version: PROTOCOL_VERSION
            }
        ))
    );
    request(&next, 3, Request::Release { lease: 99 });
    assert_eq!(
        reply(&next),
        Some((
            3,
            Reply::Refused {
                reason: Refusal::UnknownLease
            }
        ))
    );
    drop(next);
    assert!(served.join().is_ok());
}
