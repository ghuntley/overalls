use crate::protocol::*;
use crate::transfer::{plan, Consumer, Context, Producer, Stream, Verb};
use crate::utilities::Table;
use hegel::{generators as gs, TestCase};
use std::ffi::{CString, OsString};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

const PLACEMENT: &[u8] = b"11111111-2222-4333-8444-555555555555";
const RELOCATION: &[u8] = b"22222222-3333-4444-8555-666666666666";
const SOURCE: &[u8] = b"33333333-4444-4555-8666-777777777777";
const HOST: &[u8] = b"44444444-5555-4666-8777-888888888888";
const POOL_ID: &[u8] = b"55555555-6666-4777-8888-999999999999";
const NONCE: &[u8] = b"0123456789abcdef0123456789abcdef";
const TOKEN: &[u8] = b"1-ab-cd-ef";

/// A utility table whose stream executables are scripts in a private bin.
fn table() -> (tempfile::TempDir, Table) {
    let directory = tempfile::tempdir().expect("tempdir");
    for name in [
        "zfs",
        "ssh",
        "cmp",
        "lilly-transfer-stream",
        "lilly-resume-token",
    ] {
        let path = directory.path().join(name);
        std::fs::write(&path, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let table = Table::resolve(&OsString::from(directory.path()));
    (directory, table)
}

fn pools() -> Vec<(Vec<u8>, PathBuf)> {
    vec![(b"tank/lilly".to_vec(), PathBuf::from("/pool"))]
}

fn receive() -> Consumer {
    Consumer::Receive {
        dataset: b"tank/lilly".to_vec(),
        pool: b"/pool".to_vec(),
        placement: PLACEMENT.to_vec(),
        host: HOST.to_vec(),
        pool_id: POOL_ID.to_vec(),
        nonce: NONCE.to_vec(),
    }
}

fn ssh(verb: Verb) -> Producer {
    Producer::Ssh {
        address: b"source.example".to_vec(),
        port: b"2223".to_vec(),
        source_host: SOURCE.to_vec(),
        relocation: RELOCATION.to_vec(),
        identity: b"/var/lib/lilly/transfers/key/id_ed25519".to_vec(),
        known_hosts: b"/var/lib/lilly/transfers/key/known_hosts".to_vec(),
        verb,
    }
}

fn local_send() -> Producer {
    Producer::LocalSend {
        dataset: b"tank/lilly".to_vec(),
        placement: PLACEMENT.to_vec(),
    }
}

fn strings(argv: &[CString]) -> Vec<String> {
    argv.iter()
        .map(|a| a.clone().into_string().unwrap())
        .collect()
}

fn context<'a>(pools: &'a [(Vec<u8>, PathBuf)], table: &'a Table) -> Context<'a> {
    Context {
        pools,
        utilities: table,
        side_uid: Some(977),
        elevated: true,
    }
}

/// The derived receive is exactly the fixed property set Lilly's
/// verification requires, into `<dataset>/vm-<placement>`.
#[test]
fn local_clone_derives_the_exact_commands() {
    let (bin, table) = table();
    let pools = pools();
    let tool = |name: &str| bin.path().join(name).display().to_string();
    let plan = plan(
        &Stream {
            producer: local_send(),
            consumer: receive(),
        },
        &context(&pools, &table),
        86_400_000,
        1024,
        Some(9),
    )
    .unwrap();
    assert_eq!(plan.resume_check, None);
    let placement = std::str::from_utf8(PLACEMENT).unwrap();
    let mut expected = vec![
        "86400000".to_string(),
        "1024".into(),
        "9".into(),
        "-".into(),
        "-".into(),
        "4".into(),
        tool("zfs"),
        "send".into(),
        "-c".into(),
        format!("tank/lilly/vm-{placement}@lilly-b"),
        tool("zfs"),
        "receive".into(),
        "-u".into(),
        "-s".into(),
        "-o".into(),
        format!("mountpoint=/pool/vms/{placement}"),
    ];
    for property in [
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
    ] {
        expected.extend(["-o".to_string(), property.to_string()]);
    }
    expected.extend([
        "-o".to_string(),
        format!("lilly:host={}", std::str::from_utf8(HOST).unwrap()),
        "-o".into(),
        format!("lilly:pool={}", std::str::from_utf8(POOL_ID).unwrap()),
        "-o".into(),
        format!("lilly:vm={placement}"),
        "-o".into(),
        format!("lilly:nonce={}", std::str::from_utf8(NONCE).unwrap()),
        format!("tank/lilly/vm-{placement}"),
    ]);
    assert_eq!(strings(&plan.helper), expected);
}

/// A local resume validates the token against the bound snapshot first and
/// sends only by that token.
#[test]
fn local_resume_checks_the_token_first() {
    let (_bin, table) = table();
    let pools = pools();
    let plan = plan(
        &Stream {
            producer: Producer::LocalResume {
                dataset: b"tank/lilly".to_vec(),
                placement: PLACEMENT.to_vec(),
                to_guid: b"12345".to_vec(),
                token: TOKEN.to_vec(),
            },
            consumer: receive(),
        },
        &context(&pools, &table),
        10_000,
        0,
        None,
    )
    .unwrap();
    let placement = std::str::from_utf8(PLACEMENT).unwrap();
    assert_eq!(
        strings(plan.resume_check.as_deref().unwrap()),
        [
            format!("tank/lilly/vm-{placement}@lilly-b"),
            "12345".into(),
            "1-ab-cd-ef".into()
        ]
    );
    let helper = strings(&plan.helper);
    assert_eq!(helper[2], "-");
    assert_eq!(&helper[7..10], ["send", "-t", "1-ab-cd-ef"]);
}

/// The SSH side keeps every fixed restriction, drops to the service uid and
/// asks only for a fixed verb.
#[test]
fn ssh_pull_runs_unprivileged_with_fixed_options() {
    let (bin, table) = table();
    let pools = pools();
    let relocation = std::str::from_utf8(RELOCATION).unwrap();
    for (verb, tail) in [
        (Verb::Export, vec!["lilly-export-v4", relocation]),
        (
            Verb::Resume {
                token: TOKEN.to_vec(),
            },
            vec!["lilly-resume-v4", relocation, "1-ab-cd-ef"],
        ),
    ] {
        let helper = strings(
            &plan(
                &Stream {
                    producer: ssh(verb),
                    consumer: receive(),
                },
                &context(&pools, &table),
                60_000,
                67_108_864,
                Some(4),
            )
            .unwrap()
            .helper,
        );
        assert_eq!(helper[3], "977", "the SSH producer runs as the service uid");
        assert_eq!(helper[4], "-", "the receive runs as hostd");
        let count: usize = helper[5].parse().unwrap();
        let producer = &helper[6..6 + count];
        assert_eq!(producer[0], bin.path().join("ssh").display().to_string());
        assert_eq!(
            &producer[1..7],
            [
                "-F",
                "/dev/null",
                "-T",
                "-n",
                "-i",
                "/var/lib/lilly/transfers/key/id_ed25519"
            ]
        );
        for option in [
            "BatchMode=yes",
            "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=/var/lib/lilly/transfers/key/known_hosts",
            "GlobalKnownHostsFile=/dev/null",
            &format!(
                "HostKeyAlias=lilly-{}",
                std::str::from_utf8(SOURCE).unwrap()
            ),
            "ProxyCommand=none",
            "PermitLocalCommand=no",
            "ForwardAgent=no",
        ] {
            assert!(
                producer.windows(2).any(|w| w[0] == "-o" && w[1] == option),
                "{option}"
            );
        }
        let end = producer.iter().position(|a| a == "--").unwrap();
        assert_eq!(
            &producer[end - 4..end],
            ["-p", "2223", "-l", "lilly-transfer"]
        );
        assert_eq!(producer[end + 1], "source.example");
        assert_eq!(&producer[end + 2..], tail.as_slice());
    }
}

/// @cc [owner:ghuntley,label:verification;security] hostd-ssh-effective-configuration
/// Real OpenSSH (`ssh -G`) MUST resolve the derived producer to IPv4 only,
/// user `lilly-transfer`, no agent, strict pinned host keys, identities only,
/// no forwarding or multiplexing, batch public-key authentication with
/// Ed25519 host keys, the given known-hosts file and identity, and no global
/// known-hosts file. Skipped when ssh is not installed.
#[test]
fn real_openssh_resolves_the_fixed_restrictions() {
    let system = Table::resolve(&std::env::var_os("PATH").unwrap_or_default());
    let Some(ssh_path) = system.get(crate::utilities::Utility::Ssh) else {
        return;
    };
    // ssh -G drops an inaccessible -i file, so the key files must exist.
    let keys = tempfile::tempdir().expect("tempdir");
    let identity = keys.path().join("id_ed25519");
    let known_hosts = keys.path().join("known_hosts");
    std::fs::write(&identity, "").unwrap();
    std::fs::set_permissions(&identity, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::write(&known_hosts, "").unwrap();
    let mut producer = ssh(Verb::Export);
    if let Producer::Ssh {
        identity: i,
        known_hosts: k,
        ..
    } = &mut producer
    {
        *i = identity.to_str().unwrap().as_bytes().to_vec();
        *k = known_hosts.to_str().unwrap().as_bytes().to_vec();
    }
    let (_bin, table) = table();
    let pools = pools();
    let helper = strings(
        &plan(
            &Stream {
                producer,
                consumer: receive(),
            },
            &Context {
                pools: &pools,
                utilities: &table,
                side_uid: Some(977),
                elevated: true,
            },
            60_000,
            0,
            None,
        )
        .unwrap()
        .helper,
    );
    let count: usize = helper[5].parse().unwrap();
    let producer = &helper[6..6 + count];
    assert!(producer[0].ends_with("/ssh"));
    let output = std::process::Command::new(ssh_path)
        .arg("-G")
        .args(&producer[1..])
        .output()
        .expect("ssh -G");
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    let mut configuration: std::collections::HashMap<&str, Vec<&str>> =
        std::collections::HashMap::new();
    for (key, value) in text.lines().filter_map(|line| line.split_once(' ')) {
        configuration.entry(key).or_default().push(value);
    }
    let identity = identity.to_str().unwrap();
    let known_hosts = known_hosts.to_str().unwrap();
    for (key, value) in [
        ("addressfamily", "inet"),
        ("user", "lilly-transfer"),
        ("port", "2223"),
        ("identityagent", "none"),
        ("stricthostkeychecking", "true"),
        ("identitiesonly", "yes"),
        ("forwardagent", "no"),
        ("forwardx11", "no"),
        ("controlmaster", "false"),
        ("batchmode", "yes"),
        ("preferredauthentications", "publickey"),
        ("hostkeyalgorithms", "ssh-ed25519"),
        ("userknownhostsfile", known_hosts),
        ("globalknownhostsfile", "/dev/null"),
        ("identityfile", identity),
        ("permitlocalcommand", "no"),
    ] {
        assert_eq!(configuration.get(key), Some(&vec![value]), "{key}");
    }
    for key in ["proxycommand", "proxyjump", "localcommand", "remotecommand"] {
        assert!(!configuration.contains_key(key), "{key}");
    }
}

/// The probe compares against Lilly's own file as the service uid.
#[test]
fn ssh_probe_compares_unprivileged() {
    let (bin, table) = table();
    let pools = pools();
    let challenge = b"66666666-7777-4888-8999-aaaaaaaaaaaa".to_vec();
    let helper = strings(
        &plan(
            &Stream {
                producer: ssh(Verb::Probe { challenge }),
                consumer: Consumer::Compare {
                    path: b"/var/lib/lilly/transfers/key/probe".to_vec(),
                },
            },
            &context(&pools, &table),
            30_000,
            0,
            None,
        )
        .unwrap()
        .helper,
    );
    assert_eq!(helper[3..5], ["977", "977"]);
    assert_eq!(
        helper[helper.len() - 5..],
        [
            bin.path().join("cmp").display().to_string(),
            "--silent".into(),
            "--".into(),
            "/var/lib/lilly/transfers/key/probe".into(),
            "-".into(),
        ]
    );
}

/// @cc [owner:ghuntley,label:verification;security] hostd-transfer-refusals
/// Every field outside its grammar, a dataset or pool directory that is not
/// one configured pair, and an SSH or compare side that would run as root
/// MUST be refused before anything runs.
#[test]
#[expect(
    clippy::too_many_lines,
    reason = "one table-driven test walks every case of one grammar"
)]
fn out_of_policy_streams_are_refused() {
    let (_bin, table) = table();
    let pools = pools();
    let refused = |stream: Stream, context: &Context<'_>| {
        assert_eq!(
            plan(&stream, context, 10_000, 0, None),
            Err(Refusal::Malformed),
            "{stream:?}"
        );
    };
    let ctx = context(&pools, &table);
    let with_consumer = |consumer| Stream {
        producer: local_send(),
        consumer,
    };
    let with_producer = |producer| Stream {
        producer,
        consumer: receive(),
    };
    let receive_with = |edit: &dyn Fn(&mut Consumer)| {
        let mut consumer = receive();
        edit(&mut consumer);
        consumer
    };
    // A foreign dataset, a pool directory of another pool, a nested target.
    refused(
        with_producer(Producer::LocalSend {
            dataset: b"rpool/root".to_vec(),
            placement: PLACEMENT.to_vec(),
        }),
        &ctx,
    );
    refused(
        with_consumer(receive_with(&|c| {
            if let Consumer::Receive { pool, .. } = c {
                *pool = b"/etc".to_vec();
            }
        })),
        &ctx,
    );
    refused(
        with_consumer(receive_with(&|c| {
            if let Consumer::Receive { placement, .. } = c {
                *placement = b"../../etc".to_vec();
            }
        })),
        &ctx,
    );
    refused(
        with_consumer(receive_with(&|c| {
            if let Consumer::Receive { nonce, .. } = c {
                *nonce = b"0123456789ABCDEF0123456789ABCDEF".to_vec();
            }
        })),
        &ctx,
    );
    // Tokens and GUIDs.
    for (to_guid, token) in [
        (&b"12345"[..], &b"1-ab-cd-e"[..]),
        (b"12345", b"2-ab-cd-ef"),
        (b"12345", b"1-ab-cd-ef -o x"),
        (b"012345", TOKEN),
        (b"", TOKEN),
    ] {
        refused(
            with_producer(Producer::LocalResume {
                dataset: b"tank/lilly".to_vec(),
                placement: PLACEMENT.to_vec(),
                to_guid: to_guid.to_vec(),
                token: token.to_vec(),
            }),
            &ctx,
        );
    }
    // SSH fields.
    let ssh_with = |edit: &dyn Fn(&mut Producer)| {
        let mut producer = ssh(Verb::Export);
        edit(&mut producer);
        with_producer(producer)
    };
    for address in [
        &b"Source.example"[..],
        b"-oProxyCommand=x",
        b"010.0.0.1",
        b"a..b",
    ] {
        refused(
            ssh_with(&|p| {
                if let Producer::Ssh { address: a, .. } = p {
                    *a = address.to_vec();
                }
            }),
            &ctx,
        );
    }
    for port in [&b"0"[..], b"65536", b"022", b""] {
        refused(
            ssh_with(&|p| {
                if let Producer::Ssh { port: value, .. } = p {
                    *value = port.to_vec();
                }
            }),
            &ctx,
        );
    }
    for path in [
        &b"relative/key"[..],
        b"/keys/%h",
        b"/keys/../etc/shadow",
        b"/keys/a b",
    ] {
        refused(
            ssh_with(&|p| {
                if let Producer::Ssh { identity, .. } = p {
                    *identity = path.to_vec();
                }
            }),
            &ctx,
        );
    }
    refused(
        with_producer(ssh(Verb::Probe {
            challenge: b"not-a-uuid".to_vec(),
        })),
        &ctx,
    );
    // An SSH side never runs as root.
    let root = Context {
        pools: &pools,
        utilities: &table,
        side_uid: None,
        elevated: true,
    };
    assert_eq!(
        plan(&with_producer(ssh(Verb::Export)), &root, 10_000, 0, None),
        Err(Refusal::Unavailable)
    );
    // Bounds.
    assert_eq!(
        plan(&with_consumer(receive()), &ctx, 999, 0, None),
        Err(Refusal::Malformed)
    );
    assert_eq!(
        plan(&with_consumer(receive()), &ctx, 86_400_001, 0, None),
        Err(Refusal::Malformed)
    );
}

/// A private daemon (no configured pools) still requires well-formed names.
#[test]
fn private_daemon_streams_require_well_formed_names() {
    let (_bin, table) = table();
    let context = Context {
        pools: &[],
        utilities: &table,
        side_uid: None,
        elevated: false,
    };
    let stream = |dataset: &[u8]| Stream {
        producer: Producer::LocalSend {
            dataset: dataset.to_vec(),
            placement: PLACEMENT.to_vec(),
        },
        consumer: Consumer::Compare {
            path: b"/tmp/expected".to_vec(),
        },
    };
    assert!(plan(&stream(b"other/pool"), &context, 10_000, 0, None).is_ok());
    // No component may be empty, contain a space or read as an option.
    for dataset in [&b"pool//x"[..], b"pool/x y", b"", b"-o/x", b"pool/-x"] {
        assert_eq!(
            plan(&stream(dataset), &context, 10_000, 0, None),
            Err(Refusal::Malformed),
            "{dataset:?}"
        );
    }
}

fn field(tc: &TestCase) -> Vec<u8> {
    tc.draw(gs::vecs(gs::integers::<u8>().min_value(1)).max_size(40))
}

fn producer(tc: &TestCase) -> Producer {
    match tc.draw(gs::integers::<u8>().min_value(0).max_value(6)) {
        0 => Producer::LocalSend {
            dataset: field(tc),
            placement: field(tc),
        },
        1 => Producer::LocalResume {
            dataset: field(tc),
            placement: field(tc),
            to_guid: field(tc),
            token: field(tc),
        },
        5 => Producer::CheckpointSend {
            dataset: field(tc),
            placement: field(tc),
            slot: field(tc),
        },
        kind => Producer::Ssh {
            address: field(tc),
            port: field(tc),
            source_host: field(tc),
            relocation: field(tc),
            identity: field(tc),
            known_hosts: field(tc),
            verb: match kind {
                2 => Verb::Export,
                6 => Verb::Checkpoint,
                3 => Verb::Resume { token: field(tc) },
                _ => Verb::Probe {
                    challenge: field(tc),
                },
            },
        },
    }
}

fn consumer(tc: &TestCase) -> Consumer {
    match tc.draw(gs::integers::<u8>().max_value(2)) {
        0 => Consumer::Receive {
            dataset: field(tc),
            pool: field(tc),
            placement: field(tc),
            host: field(tc),
            pool_id: field(tc),
            nonce: field(tc),
        },
        1 => Consumer::CheckpointReceive {
            memory_bytes: field(tc),
            dataset: field(tc),
            pool: field(tc),
            placement: field(tc),
            host: field(tc),
            pool_id: field(tc),
            nonce: field(tc),
        },
        _ => Consumer::Compare { path: field(tc) },
    }
}

/// @cc [owner:ghuntley,label:verification] hostd-transfer-stream-decoding
/// Every `TransferStream` datagram within bounds MUST decode to exactly the
/// encoded request, and removing or adding one field, or an out-of-range
/// timeout or rate, MUST fail to decode.
#[hegel::test]
fn transfer_stream_decoding_round_trips(tc: TestCase) {
    let stream = Stream {
        producer: producer(&tc),
        consumer: consumer(&tc),
    };
    let timeout_ms = tc.draw(gs::integers::<u32>().min_value(1000).max_value(86_400_000));
    let rate = tc.draw(gs::integers::<u32>().max_value(1_073_741_824));
    let envelope = Envelope {
        id: tc.draw(gs::integers::<u64>()),
        request: Request::TransferStream {
            lease: tc.draw(gs::integers::<u64>()),
            timeout_ms,
            rate,
            stream: Box::new(stream),
        },
    };
    let bytes = encode_request(&envelope);
    assert_eq!(decode(&bytes), Some(envelope));
    let mut extra = bytes.clone();
    extra.extend(b"x\0");
    assert_eq!(decode(&extra), None);
    // Dropping the last field (its bytes and NUL terminator).
    let last = bytes[..bytes.len() - 1]
        .iter()
        .rposition(|byte| *byte == 0)
        .map_or(9 + 18, |at| at + 1);
    assert_eq!(decode(&bytes[..last]), None);
    let mut slow = bytes.clone();
    slow[9 + 8..9 + 12].copy_from_slice(&86_400_001_u32.to_be_bytes());
    assert_eq!(decode(&slow), None);
    let mut fast = bytes;
    fast[9 + 12..9 + 16].copy_from_slice(&1_073_741_825_u32.to_be_bytes());
    assert_eq!(decode(&fast), None);
}

/// Resume-token syntax matches Lilly's ExportRequest.token? model.
#[hegel::test]
fn token_grammar_matches_model(tc: TestCase) {
    let alphabet = b"0123456789abcdefAg-1 ";
    let token: Vec<u8> = tc
        .draw(gs::vecs(gs::integers::<usize>().max_value(alphabet.len() - 1)).max_size(24))
        .into_iter()
        .map(|index| alphabet[index])
        .collect();
    let model = (|| {
        let text = std::str::from_utf8(&token).ok()?;
        let rest = text.strip_prefix("1-")?;
        let (first, rest) = rest.split_once('-')?;
        let (second, payload) = rest.split_once('-')?;
        let hex = |s: &str| {
            s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        Some(
            (1..=16).contains(&first.len())
                && hex(first)
                && (1..=16).contains(&second.len())
                && hex(second)
                && !payload.is_empty()
                && payload.len() % 2 == 0
                && hex(payload),
        )
    })()
    .unwrap_or(false);
    assert_eq!(crate::transfer::token(&token), model, "{token:?}");
}

/// @cc [owner:ghuntley,label:verification;security] checkpoint-stream-custody
/// Generated valid slots MUST name only the private checkpoint sibling; unknown
/// slots and foreign pools MUST refuse. Receive MUST retain fixed ownership,
/// read-only policy and no resumable token, separate from ordinary disk targets.
#[hegel::test]
fn checkpoint_stream_custody(tc: TestCase) {
    let (_bin, table) = table();
    let pools = pools();
    let ctx = context(&pools, &table);
    let slot = if tc.draw(gs::booleans()) { b"a" } else { b"b" };
    let checkpoint = |slot: &[u8], dataset: &[u8]| Stream {
        producer: Producer::CheckpointSend {
            dataset: dataset.to_vec(),
            placement: PLACEMENT.to_vec(),
            slot: slot.to_vec(),
        },
        consumer: Consumer::CheckpointReceive {
            dataset: b"tank/lilly".to_vec(),
            pool: b"/pool".to_vec(),
            placement: PLACEMENT.to_vec(),
            host: HOST.to_vec(),
            pool_id: POOL_ID.to_vec(),
            nonce: NONCE.to_vec(),
            memory_bytes: b"1073741824".to_vec(),
        },
    };
    let request = checkpoint(slot, b"tank/lilly");
    let derived = plan(&request, &ctx, 10_000, 0, None).unwrap();
    let argv = strings(&derived.helper);
    let placement = std::str::from_utf8(PLACEMENT).unwrap();
    let slot = std::str::from_utf8(slot).unwrap();
    assert!(argv.contains(&format!(
        "tank/lilly/checkpoint-{placement}-{slot}@lilly-checkpoint"
    )));
    assert!(argv.contains(&format!(
        "mountpoint=/pool/.lilly-checkpoints/{placement}/a"
    )));
    assert_eq!(
        argv.last(),
        Some(&format!("tank/lilly/checkpoint-{placement}-a"))
    );
    for property in [
        "readonly=on",
        "canmount=noauto",
        "exec=off",
        "setuid=off",
        "devices=off",
        "quota=1140850688",
    ] {
        assert!(argv.iter().any(|value| value == property));
    }
    assert!(!argv
        .iter()
        .any(|value| value == "-s" || value.contains("/vm-")));
    assert!(derived.resume_check.is_none());
    let invalid = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(24));
    if invalid != b"a" && invalid != b"b" {
        assert_eq!(
            plan(&checkpoint(&invalid, b"tank/lilly"), &ctx, 10_000, 0, None),
            Err(Refusal::Malformed)
        );
    }
    assert_eq!(
        plan(&checkpoint(b"a", b"other/pool"), &ctx, 10_000, 0, None),
        Err(Refusal::Malformed)
    );
    let mut pull = request;
    pull.producer = ssh(Verb::Checkpoint);
    let pull = strings(&plan(&pull, &ctx, 10_000, 0, None).unwrap().helper);
    assert!(pull.windows(2).any(|pair| pair
        == [
            "lilly-checkpoint-v1",
            std::str::from_utf8(RELOCATION).unwrap()
        ]));
    assert_eq!(pull[3], "977");
}
