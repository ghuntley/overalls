//! Detached ingress bridges (ADR-0187): decoding, names, listing, ending,
//! the client check and the start handshake. The real scope placement,
//! survival across a hostd restart and the namespace dial are machine-test
//! obligations (user-SSH journey).

use crate::exec::start_reaper;
use crate::ingress::{self, Config, Stage, KEY, MAX_EXPECT, MAX_GREETING, MAX_PREFACE};
use crate::protocol::*;
use hegel::{generators as gs, TestCase};
use rustix::net::{socketpair, AddressFamily, SocketFlags, SocketType};
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// @cc [owner:ghuntley,label:verification] hostd-ingress-decoding
/// `BridgeIngress` datagrams MUST decode exactly when the greeting (at most
/// 256 bytes), preface (at most 4096) and expected frame (at most 256) fit
/// their declared lengths, the ready wait is 0 for an empty expected frame
/// and 1..=30000 ms otherwise, and the target that follows obeys
/// `BridgeNetnsTcp`'s rules; accepted datagrams carry a descriptor and
/// re-encode to the same bytes. `ListIngressBridges` takes an empty body and
/// `EndIngressBridge` exactly a 16-byte key, and neither carries a descriptor.
#[hegel::test]
fn ingress_decoding_matches_model(tc: TestCase) {
    let key: Vec<u8> = tc.draw(gs::binary().min_size(KEY).max_size(KEY));
    let greeting = tc.draw(gs::binary().max_size(300));
    let preface = tc.draw(hegel::one_of!(
        gs::binary().max_size(40),
        gs::binary().min_size(4090).max_size(4100),
    ));
    let expect = tc.draw(gs::binary().max_size(300));
    let declared = tc.draw(hegel::one_of!(
        gs::just(u16::try_from(greeting.len()).unwrap()),
        gs::integers::<u16>().max_value(400),
    ));
    let ready = tc.draw(hegel::one_of!(
        gs::just(0_u32),
        gs::integers::<u32>().min_value(1).max_value(2),
        gs::integers::<u32>().min_value(29_999).max_value(30_001),
    ));
    let port = tc.draw(hegel::one_of!(gs::just(0_u16), gs::integers::<u16>()));
    let timeout = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(0).max_value(2),
        gs::integers::<u32>().min_value(29_999).max_value(30_001),
    ));
    let namespace = tc.draw(gs::binary().max_size(5));
    let device = tc.draw(gs::binary().max_size(5));
    let mut target = Vec::new();
    target.extend(7_u32.to_be_bytes());
    target.extend([10, 0, 0, 2]);
    target.extend(port.to_be_bytes());
    target.extend([0, 0, 0, 0]);
    target.extend(timeout.to_be_bytes());
    target.push(u8::try_from(namespace.len()).unwrap());
    target.extend(&namespace);
    target.extend(&device);
    let mut body = vec![14_u8];
    body.extend(9_u64.to_be_bytes());
    body.extend(&key);
    body.extend(declared.to_be_bytes());
    body.extend(&greeting);
    body.extend(u16::try_from(preface.len()).unwrap().to_be_bytes());
    body.extend(&preface);
    body.extend(u16::try_from(expect.len()).unwrap().to_be_bytes());
    body.extend(&expect);
    body.extend(ready.to_be_bytes());
    body.extend(&target);
    let length = usize::from(declared);
    // When the declared length differs from the greeting, the fields after
    // it start elsewhere; the model accepts only the layout really built.
    let model = length == greeting.len()
        && length <= MAX_GREETING
        && preface.len() <= MAX_PREFACE
        && expect.len() <= MAX_EXPECT
        && if expect.is_empty() {
            ready == 0
        } else {
            (1..=30_000).contains(&ready)
        }
        && port != 0
        && (1..=30_000).contains(&timeout)
        && !namespace.is_empty()
        && !device.is_empty();
    let decoded = decode(&body);
    if length == greeting.len() {
        assert_eq!(decoded.is_some(), model, "body {body:?}");
    }
    if let Some(envelope) = decoded {
        assert!(carries_descriptor(&envelope.request));
        assert_eq!(encode_request(&envelope), body);
        if let Request::BridgeIngress {
            greeting: got,
            preface: sent,
            expect: wanted,
            ..
        } = &envelope.request
        {
            assert!(got.len() <= MAX_GREETING);
            assert!(sent.len() <= MAX_PREFACE);
            assert!(wanted.len() <= MAX_EXPECT);
        } else {
            panic!("op 14 decodes as BridgeIngress");
        }
    }
    let trailing = tc.draw(gs::binary().max_size(20));
    let mut list = vec![15_u8];
    list.extend(1_u64.to_be_bytes());
    list.extend(&trailing);
    assert_eq!(decode(&list).is_some(), trailing.is_empty());
    let mut end = vec![16_u8];
    end.extend(1_u64.to_be_bytes());
    end.extend(&trailing);
    let decoded = decode(&end);
    assert_eq!(decoded.is_some(), trailing.len() == KEY);
    if let Some(envelope) = decoded {
        assert!(!carries_descriptor(&envelope.request));
        assert_eq!(encode_request(&envelope), end);
    }
}

/// @cc [owner:ghuntley,label:verification;security] hostd-ingress-scope-names
/// unit and `key_of` MUST be inverse on every key, and `key_of` MUST refuse any
/// name that is not exactly the lowercase form.
#[hegel::test]
fn scope_names_round_trip(tc: TestCase) {
    let bytes: Vec<u8> = tc.draw(gs::binary().min_size(KEY).max_size(KEY));
    let key: [u8; KEY] = bytes.try_into().unwrap();
    let name = ingress::unit(&key);
    assert_eq!(ingress::key_of(name.as_bytes()), Some(key));
    assert_eq!(ingress::key_of(name.to_uppercase().as_bytes()), None);
    assert_eq!(ingress::key_of(&name.as_bytes()[1..]), None);
    let noise = tc.draw(gs::binary().max_size(60));
    if let Some(found) = ingress::key_of(&noise) {
        assert_eq!(ingress::unit(&found).as_bytes(), noise.as_slice());
    }
}

#[test]
fn slices_users_and_passwd() {
    assert!(ingress::valid_slice("lilly.slice"));
    for bad in [
        "lilly-vm.slice",
        ".slice",
        "Lilly.slice",
        "lilly",
        "lilly.scope",
    ] {
        assert!(!ingress::valid_slice(bad), "{bad}");
    }
    let passwd = b"root:x:0:0::/root:/bin/sh\naudi:x:991:990::/var/empty:/bin/false\n";
    assert_eq!(crate::passwd_uid(passwd, "audi"), Some(991));
    assert_eq!(crate::passwd_uid(passwd, "aud"), None);
    let twice = b"audi:x:991:990::/:/bin/false\naudi:x:992:990::/:/bin/false\n";
    assert_eq!(crate::passwd_uid(twice, "audi"), None);
    assert_eq!(crate::passwd_uid(b"audi:x:-1:0::/:/x\n", "audi"), None);
    let options = |extra: &[&str]| {
        let mut words = vec!["--socket", "/run/h.sock", "--root", "/run"];
        words.extend(extra);
        crate::parse_options(
            &words
                .iter()
                .map(std::ffi::OsString::from)
                .collect::<Vec<_>>(),
        )
    };
    assert_eq!(
        options(&[
            "--ingress-peer-user",
            "audi",
            "--ingress-slice",
            "lilly.slice"
        ])
        .unwrap()
        .ingress,
        Some(("audi".to_owned(), "lilly.slice".to_owned()))
    );
    assert!(options(&["--ingress-peer-user", "audi"]).is_none());
    assert!(options(&["--ingress-slice", "lilly.slice"]).is_none());
    assert!(options(&[
        "--ingress-peer-user",
        "Audi",
        "--ingress-slice",
        "lilly.slice"
    ])
    .is_none());
    assert!(options(&[
        "--ingress-peer-user",
        "audi",
        "--ingress-slice",
        "a-b.slice"
    ])
    .is_none());
}

fn config(cgroup: &Path) -> Config {
    Config {
        peer_uid: rustix::process::geteuid().as_raw(),
        slice: "lilly.slice".to_owned(),
        cgroup: cgroup.to_path_buf(),
        launcher: None,
    }
}

fn fake_scope(cgroup: &Path, name: &str, populated: bool) -> PathBuf {
    let scope = cgroup.join(name);
    std::fs::create_dir_all(&scope).unwrap();
    std::fs::write(
        scope.join("cgroup.events"),
        format!("populated {}\nfrozen 0\n", u8::from(populated)),
    )
    .unwrap();
    scope
}

/// @cc [owner:ghuntley,label:verification;recovery] hostd-ingress-list-and-end
/// live MUST list only populated, well-named scopes; end MUST succeed at once
/// for an absent or empty scope, write cgroup.kill and wait for a populated
/// scope to empty, and never remove the directory.
#[test]
fn bridges_are_listed_and_ended_through_their_cgroups() {
    let directory = tempfile::tempdir().unwrap();
    let cgroup = directory.path();
    let live_key = [0xab_u8; KEY];
    let empty_key = [0x01_u8; KEY];
    let live = fake_scope(cgroup, &ingress::unit(&live_key), true);
    fake_scope(cgroup, &ingress::unit(&empty_key), false);
    fake_scope(cgroup, "lilly-vm-x.scope", true);
    fake_scope(cgroup, "lilly-ingress-ABAB.scope", true);
    let config = config(cgroup);
    assert_eq!(ingress::live(&config), vec![live_key]);
    assert_eq!(ingress::end(&config, &empty_key), Ok(()));
    assert_eq!(ingress::end(&config, &[0x77; KEY]), Ok(()));
    let watcher = {
        let live = live.clone();
        std::thread::spawn(move || {
            while !live.join("cgroup.kill").exists() {
                std::thread::sleep(Duration::from_millis(5));
            }
            std::fs::write(live.join("cgroup.events"), "populated 0\n").unwrap();
        })
    };
    assert_eq!(ingress::end(&config, &live_key), Ok(()));
    watcher.join().unwrap();
    assert_eq!(std::fs::read(live.join("cgroup.kill")).unwrap(), b"1");
    assert!(live.is_dir(), "systemd owns the scope's cgroup");
    // Compare the count: bridge keys stay out of the failure message.
    assert_eq!(ingress::live(&config).len(), 0);
}

fn pair() -> (OwnedFd, OwnedFd) {
    socketpair(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap()
}

/// @cc [owner:ghuntley,label:verification;security] hostd-ingress-client-kind
/// Only a connected, non-listening `AF_UNIX` stream socket whose peer is the
/// configured uid may be a detached bridge's client.
#[test]
fn only_audis_connected_stream_is_a_client() {
    let me = rustix::process::geteuid().as_raw();
    let (client, _peer) = pair();
    assert_eq!(ingress::client_kind(&client, me), Ok(()));
    assert_eq!(
        ingress::client_kind(&client, me.wrapping_add(1)),
        Err(Refusal::Malformed)
    );
    let unconnected = rustix::net::socket_with(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    assert_eq!(
        ingress::client_kind(&unconnected, me),
        Err(Refusal::Malformed)
    );
    let directory = tempfile::tempdir().unwrap();
    let listener = std::os::unix::net::UnixListener::bind(directory.path().join("l")).unwrap();
    assert_eq!(
        ingress::client_kind(&OwnedFd::from(listener), me),
        Err(Refusal::Malformed)
    );
    let (datagram, _other) = socketpair(
        AddressFamily::UNIX,
        SocketType::DGRAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    assert_eq!(ingress::client_kind(&datagram, me), Err(Refusal::Malformed));
    let file = OwnedFd::from(tempfile::tempfile().unwrap());
    assert_eq!(ingress::client_kind(&file, me), Err(Refusal::Malformed));
}

fn helper(directory: &Path, body: &str) -> PathBuf {
    let path = directory.join("bridge");
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// @cc [owner:ghuntley,label:verification;security] hostd-ingress-start-handshake
/// start MUST give the helper `--detached 5 3 4` with the client at 3, the
/// guest at 4 and the control socket at 5, write the greeting to the client
/// only after READY and before GO, and keep no copy of either connection; a
/// helper that never reports READY is a refusal and its client sees no
/// greeting.
#[test]
fn start_writes_the_greeting_between_ready_and_go() {
    start_reaper().expect("subreaper");
    let directory = tempfile::tempdir().unwrap();
    let config = config(directory.path());
    let bridge = helper(
        directory.path(),
        r#"[ "$*" = "--detached 5 3 4" ] || exit 64
printf R >&5
go=$(dd bs=1 count=1 <&5 2>/dev/null)
[ "$go" = G ] || exit 70
exec 5>&-
exec cat <&3 >&4"#,
    );
    let (audi, client) = pair();
    let (guest, guest_end) = pair();
    assert_eq!(
        ingress::start(
            &config,
            &bridge,
            &[1; KEY],
            b"ready-frame",
            client,
            guest,
            None
        ),
        Ok(())
    );
    let mut audi = UnixStream::from(audi);
    audi.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut greeting = [0_u8; 11];
    audi.read_exact(&mut greeting).unwrap();
    assert_eq!(&greeting, b"ready-frame");
    audi.write_all(b"ssh-bytes").unwrap();
    audi.shutdown(std::net::Shutdown::Write).unwrap();
    let mut guest_end = UnixStream::from(guest_end);
    guest_end
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut moved = Vec::new();
    guest_end.read_to_end(&mut moved).unwrap();
    assert_eq!(
        moved, b"ssh-bytes",
        "the helper alone holds the connections"
    );

    let silent = helper(directory.path(), "exit 0");
    let (audi, client) = pair();
    let (guest, _guest_end) = pair();
    assert_eq!(
        ingress::start(&config, &silent, &[2; KEY], b"never", client, guest, None),
        Err(Refusal::Unavailable)
    );
    let mut audi = UnixStream::from(audi);
    audi.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut rest = Vec::new();
    audi.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty(), "no greeting without READY");
}

/// @cc [owner:ghuntley,label:verification;security] hostd-ingress-guest-stage
/// stage MUST deliver the whole preface to the guest, accept the guest only
/// when its next bytes are exactly the expected frame, leave every byte after
/// that frame unread for the bridge, and refuse a different frame, a closed
/// guest or a guest that stays silent past the ready wait.
#[test]
fn stage_writes_the_preface_and_requires_the_exact_frame() {
    let preface = b"\x00\x00\x00\x05hello";
    let frame = b"\x00\x00\x00\x1a{\"version\":1,\"ready\":true}";
    let stage = Stage {
        preface,
        expect: frame,
        ready: Duration::from_secs(5),
    };

    let (hostd, guest) = pair();
    let mut guest = UnixStream::from(guest);
    guest.write_all(frame).unwrap();
    guest.write_all(b"after").unwrap();
    assert_eq!(ingress::stage(&hostd, &stage), Ok(()));
    let mut sent = [0_u8; 9];
    guest.read_exact(&mut sent).unwrap();
    assert_eq!(&sent, preface);
    let mut rest = UnixStream::from(hostd);
    rest.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut after = [0_u8; 5];
    rest.read_exact(&mut after).unwrap();
    assert_eq!(&after, b"after", "no byte past the frame is consumed");

    let (hostd, guest) = pair();
    let mut guest = UnixStream::from(guest);
    let mut wrong = frame.to_vec();
    wrong[20] ^= 1;
    guest.write_all(&wrong).unwrap();
    assert_eq!(ingress::stage(&hostd, &stage), Err(Refusal::Unavailable));

    let (hostd, guest) = pair();
    let mut guest = UnixStream::from(guest);
    guest.write_all(&frame[..10]).unwrap();
    drop(guest);
    assert_eq!(ingress::stage(&hostd, &stage), Err(Refusal::Unavailable));

    let (hostd, _guest) = pair();
    let silent = Stage {
        ready: Duration::from_millis(50),
        ..stage
    };
    assert_eq!(ingress::stage(&hostd, &silent), Err(Refusal::Unavailable));

    let (hostd, guest) = pair();
    let plain = Stage {
        preface: b"",
        expect: b"",
        ready: Duration::ZERO,
    };
    assert_eq!(ingress::stage(&hostd, &plain), Ok(()));
    drop(hostd);
    let mut guest = UnixStream::from(guest);
    let mut nothing = Vec::new();
    guest.read_to_end(&mut nothing).unwrap();
    assert!(nothing.is_empty(), "a preface-free stage writes nothing");
}

/// command MUST wrap the helper in a transient scope named by the key in the
/// configured slice, with the bridge's hard lifetime, when a launcher is set.
#[test]
fn production_command_places_the_bridge_in_its_own_scope() {
    let mut config = config(Path::new("/sys/fs/cgroup/lilly.slice"));
    config.launcher = Some(PathBuf::from("/run/current-system/sw/bin/systemd-run"));
    let (executable, arguments) = ingress::command(
        &config,
        Path::new("/nix/store/x/bin/lilly-ingress-bridge"),
        &[0xcd; KEY],
        Some(377),
    )
    .unwrap();
    assert_eq!(
        executable,
        PathBuf::from("/run/current-system/sw/bin/systemd-run")
    );
    let words: Vec<_> = arguments
        .iter()
        .map(|argument| argument.to_str().unwrap())
        .collect();
    assert_eq!(
        words,
        [
            "--scope",
            "--quiet",
            "--collect",
            "--unit=lilly-ingress-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd.scope",
            "--slice=lilly.slice",
            "--property=RuntimeMaxSec=2592000",
            "--",
            "/nix/store/x/bin/lilly-ingress-bridge",
            "--detached",
            "5",
            "3",
            "4",
            "377",
        ]
    );
}

#[test]
fn detached_bridge_exits_are_reported_by_closed_class() {
    use crate::exec::BridgeExit;
    let cases = [
        ((Some(0), None), ("ok", "none")),
        ((Some(74), None), ("exit_io", "none")),
        ((Some(70), None), ("setup_failed", "none")),
        ((Some(64), None), ("setup_failed", "none")),
        ((Some(1), None), ("exit_other", "none")),
        ((None, Some(libc::SIGPIPE)), ("signal", "pipe")),
        ((None, Some(libc::SIGKILL)), ("signal", "kill")),
        ((None, Some(libc::SIGTERM)), ("signal", "other")),
    ];
    for ((code, signal), expected) in cases {
        assert_eq!(BridgeExit::of(code, signal).fields(), expected);
    }
}
