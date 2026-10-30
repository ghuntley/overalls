//! Command-grammar bounds for session mutations, observed through a fake
//! Porsche endpoint that records every exec line and its stdin.

use base64::{engine::general_purpose::STANDARD, Engine};
use hegel::{generators as gs, TestCase};
use mila_model::DevicePlatform;
use mila_session::ApplicationSession;
use mila_transport::{
    ssh::{DeviceSigner, SshError},
    TrustDocument,
};
use russh::{
    keys::{
        ssh_key::certificate::{Builder, CertType},
        Algorithm, Certificate, PrivateKey,
    },
    server, Channel, ChannelId,
};
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MACHINE: &str = "00000000-0000-0000-0000-000000000001";
const SECONDARY: &str = "00000000-0000-0000-0000-000000000002";
const REQUEST: &str = "porsche-0123456789abcdef0123456789abcdef";

/// One exec observed by the fake endpoint.
#[derive(Clone, Debug, Eq, PartialEq)]
struct Exec {
    line: String,
    stdin: Vec<u8>,
}

type Log = Arc<Mutex<Vec<Exec>>>;

/// One authenticated session shared by every generated case.
struct Harness {
    runtime: tokio::runtime::Runtime,
    session: ApplicationSession,
    log: Log,
}

static HARNESS: LazyLock<Mutex<Harness>> = LazyLock::new(|| Mutex::new(harness()));

/// Runs one session call and returns its result with the execs it caused.
fn observe<T>(
    call: impl for<'a> FnOnce(
        &'a mut ApplicationSession,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = T> + 'a>>,
) -> (T, Vec<Exec>) {
    let mut harness = HARNESS.lock().unwrap_or_else(PoisonError::into_inner);
    let Harness {
        runtime,
        session,
        log,
    } = &mut *harness;
    log.lock().unwrap_or_else(PoisonError::into_inner).clear();
    let result = runtime.block_on(call(session));
    let execs = std::mem::take(&mut *log.lock().unwrap_or_else(PoisonError::into_inner));
    (result, execs)
}

fn parsed(line: &str) -> mila_protocol::Command {
    mila_protocol::Command::parse(line).expect("sent line satisfies the shared grammar")
}

fn string_option(command: &mila_protocol::Command, key: &str) -> Option<String> {
    match command.options.get(key) {
        Some(mila_protocol::OptionValue::String(value)) => Some(value.clone()),
        _ => None,
    }
}

/// A value inside `low..=high`, biased to its ends.
fn within(tc: &TestCase, low: u64, high: u64) -> u64 {
    if tc.draw(gs::booleans()) {
        tc.draw(gs::sampled_from(vec![low, high]))
    } else {
        tc.draw(gs::integers::<u64>().min_value(low).max_value(high))
    }
}

/// A value just outside `low..=high`, or well above it.
fn outside(tc: &TestCase, low: u64, high: u64) -> u64 {
    let below = low.checked_sub(1).unwrap_or(high + 1);
    tc.draw(gs::sampled_from(vec![below, high + 1, high + 1_000]))
}

/// `outside` when this field is the case's fault, `within` otherwise.
fn field(tc: &TestCase, fault: bool, low: u64, high: u64) -> u64 {
    if fault {
        outside(tc, low, high)
    } else {
        within(tc, low, high)
    }
}

fn request_id(tc: &TestCase, fault: bool) -> &'static str {
    if fault {
        tc.draw(gs::sampled_from(vec![
            "porsche-0123",
            "porsche-0123456789ABCDEF0123456789ABCDEF",
        ]))
    } else {
        REQUEST
    }
}

fn machine_id(tc: &TestCase, fault: bool) -> &'static str {
    if fault {
        tc.draw(gs::sampled_from(vec![
            "00000000-0000-0000-0000-00000000000G",
            "not a machine",
        ]))
    } else {
        MACHINE
    }
}

/// `length` copies of `fill`, with one byte replaced from `bad` when `fault`,
/// or else from `good` half of the time.
fn text(
    tc: &TestCase,
    length: u64,
    fill: char,
    fault: bool,
    good: &[char],
    bad: &[char],
) -> String {
    let mut text: Vec<char> = std::iter::repeat_n(fill, usize::try_from(length).unwrap()).collect();
    if !text.is_empty() && (fault || tc.draw(gs::booleans())) {
        let index = tc.draw(gs::integers::<usize>().max_value(text.len() - 1));
        let pool = if fault { bad } else { good };
        text[index] = tc.draw(gs::sampled_from(pool.to_vec()));
    }
    text.into_iter().collect()
}

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-session-machine-create-bounds
/// `machine_create` MUST send exactly one grammar-checked `new` line carrying
/// the generated name, CPU, memory, disk and request id when the name is
/// 1..=128 bytes of `[A-Za-z0-9_-]`, CPU is 1..=256, memory 256..=4194304,
/// disk 1..=500 and the request id is canonical, and MUST send nothing
/// otherwise.
#[hegel::test(test_cases = 128)]
fn machine_create_sends_only_bounded_commands(tc: TestCase) {
    // At most one field is faulted per case, so accepted commands stay frequent.
    let fault = tc.draw(gs::integers::<u8>().max_value(9));
    let length = field(&tc, fault == 1, 1, 128);
    let name = text(
        &tc,
        length,
        'n',
        fault == 2,
        &['-', '_', 'Z', '7'],
        &[' ', '\'', '=', '.'],
    );
    let cpu = u32::try_from(field(&tc, fault == 3, 1, 256)).unwrap();
    let memory = field(&tc, fault == 4, 256, 4_194_304);
    let disk = field(&tc, fault == 5, 1, 500);
    let request = request_id(&tc, fault == 6);
    let (result, execs) = observe(|session| {
        let name = name.clone();
        Box::pin(async move {
            session
                .machine_create(&name, cpu, memory, disk, request)
                .await
        })
    });
    let expected = request == REQUEST
        && (1..=128).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
        && (1..=256).contains(&cpu)
        && (256..=4_194_304).contains(&memory)
        && (1..=500).contains(&disk);
    assert_eq!(result.is_ok(), expected, "{result:?}");
    if !expected {
        assert!(execs.is_empty());
        return;
    }
    assert_eq!(execs.len(), 1);
    let command = parsed(&execs[0].line);
    assert_eq!(command.command, "new");
    assert!(command.arguments.is_empty());
    assert_eq!(
        string_option(&command, "name").as_deref(),
        Some(name.as_str())
    );
    assert_eq!(string_option(&command, "cpu"), Some(cpu.to_string()));
    assert_eq!(string_option(&command, "memory"), Some(memory.to_string()));
    assert_eq!(string_option(&command, "disk"), Some(disk.to_string()));
    assert_eq!(
        string_option(&command, "request-id").as_deref(),
        Some(REQUEST)
    );
    assert!(execs[0].stdin.is_empty());
}

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-session-machine-resize-bounds
/// `machine_resize` MUST send exactly one grammar-checked `resize MACHINE` line
/// for a canonical machine id and request id with CPU 1..=256, memory
/// 256..=4194304 and disk 1..=500, and MUST send nothing otherwise.
#[hegel::test(test_cases = 128)]
fn machine_resize_sends_only_bounded_commands(tc: TestCase) {
    let fault = tc.draw(gs::integers::<u8>().max_value(7));
    let machine = machine_id(&tc, fault == 1);
    let cpu = u32::try_from(field(&tc, fault == 2, 1, 256)).unwrap();
    let memory = field(&tc, fault == 3, 256, 4_194_304);
    let disk = field(&tc, fault == 4, 1, 500);
    let request = request_id(&tc, fault == 5);
    let (result, execs) = observe(|session| {
        Box::pin(async move {
            session
                .machine_resize(machine, cpu, memory, disk, request)
                .await
        })
    });
    let expected = machine == MACHINE
        && request == REQUEST
        && (1..=256).contains(&cpu)
        && (256..=4_194_304).contains(&memory)
        && (1..=500).contains(&disk);
    assert_eq!(result.is_ok(), expected, "{result:?}");
    if !expected {
        assert!(execs.is_empty());
        return;
    }
    assert_eq!(execs.len(), 1);
    let command = parsed(&execs[0].line);
    assert_eq!(command.command, "resize");
    assert_eq!(command.arguments, [MACHINE]);
    assert_eq!(string_option(&command, "cpu"), Some(cpu.to_string()));
    assert_eq!(string_option(&command, "memory"), Some(memory.to_string()));
    assert_eq!(string_option(&command, "disk"), Some(disk.to_string()));
    assert_eq!(
        string_option(&command, "request-id").as_deref(),
        Some(REQUEST)
    );
}

/// A 43-symbol base64url X25519 key whose last symbol carries zero pad bits.
const ENC_KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

/// @cc [owner:ghuntley,label:verification;privacy;security] mila-session-device-register-bounds
/// `device_register` MUST send exactly one grammar-checked `device register`
/// line, with the push key only on stdin and never on the command line, when
/// the push key is 16..=700 bytes of `[A-Za-z0-9_-]`, the encryption key passes
/// `device_public_key_valid` and any label is 1..=64 bytes without control
/// characters; it MUST send nothing otherwise.
#[hegel::test(test_cases = 128)]
fn device_register_sends_the_push_key_only_on_stdin(tc: TestCase) {
    let fault = tc.draw(gs::integers::<u8>().max_value(7));
    let length = field(&tc, fault == 1, 16, 700);
    let push_key = text(
        &tc,
        length,
        'K',
        fault == 2,
        &['-', '_', 'z', '9'],
        &['+', '/', '='],
    );
    let enc_pubkey = if fault == 3 {
        tc.draw(gs::sampled_from(vec![
            format!("{}B", &ENC_KEY[..42]),
            ENC_KEY[..42].to_owned(),
            format!("{}+", &ENC_KEY[..42]),
        ]))
    } else {
        ENC_KEY.to_owned()
    };
    let label = if fault != 4 && tc.draw(gs::booleans()) {
        None
    } else {
        let length = field(&tc, fault == 4 && tc.draw(gs::booleans()), 1, 64);
        let mut label = text(&tc, length, 'l', false, &[' ', 'L', '-'], &[]);
        if fault == 4 && length <= 64 {
            label.push('\n');
        }
        Some(label)
    };
    let platform = tc.draw(gs::sampled_from(vec![
        DevicePlatform::Ios,
        DevicePlatform::Android,
        DevicePlatform::Macos,
        DevicePlatform::Windows,
    ]));
    let (result, execs) = observe(|session| {
        let (push_key, enc_pubkey, label) = (push_key.clone(), enc_pubkey.clone(), label.clone());
        Box::pin(async move {
            session
                .device_register(platform, &push_key, &enc_pubkey, label.as_deref())
                .await
        })
    });
    let expected = (16..=700).contains(&push_key.len())
        && push_key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
        && mila_protocol::device_public_key_valid(&enc_pubkey)
        && label
            .as_deref()
            .is_none_or(|l| (1..=64).contains(&l.len()) && !l.chars().any(char::is_control));
    assert_eq!(result.is_ok(), expected, "{result:?}");
    if !expected {
        assert!(execs.is_empty());
        return;
    }
    assert_eq!(execs.len(), 1);
    assert!(!execs[0].line.contains(&push_key));
    assert_eq!(execs[0].stdin, push_key.as_bytes());
    let command = parsed(&execs[0].line);
    assert_eq!(command.command, "device register");
    assert_eq!(string_option(&command, "push-key").as_deref(), Some("-"));
    assert_eq!(
        string_option(&command, "platform").as_deref(),
        Some(platform.as_str())
    );
    assert_eq!(string_option(&command, "enc-pubkey"), Some(enc_pubkey));
    assert_eq!(string_option(&command, "label"), label);
}

const THREAD_COMMANDS: [&str; 9] = [
    "thread ls",
    "thread show",
    "thread turns",
    "thread prompt",
    "thread answer",
    "thread plan approve",
    "thread plan revise",
    "thread mode",
    "ls",
];

/// Flips presence, or substitutes a non-canonical id when `invalid`.
fn identifier(
    present: bool,
    flip: bool,
    invalid: bool,
    valid: &'static str,
) -> Option<&'static str> {
    if invalid {
        Some("NOT-AN-ID")
    } else {
        (present != flip).then_some(valid)
    }
}

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-session-thread-action-bounds
/// `thread_action` MUST send exactly one grammar-checked line naming the
/// requested closed-vocabulary command with the expected thread and secondary
/// identifiers, stdin only for prompt, answer and plan revise (non-empty, at
/// most 64 KiB and NUL-free), and an optional canonical request id; every
/// other combination MUST send nothing.
#[hegel::test(test_cases = 192)]
fn thread_actions_send_only_closed_commands(tc: TestCase) {
    let command = tc.draw(gs::sampled_from(THREAD_COMMANDS.to_vec()));
    // Start from the command's well-formed shape and fault at most one part.
    let fault = tc.draw(gs::integers::<u8>().max_value(12));
    let (has_thread, has_secondary, has_input) = match command {
        "thread ls" => (false, false, false),
        "thread show" | "thread turns" => (true, false, false),
        "thread prompt" => (true, false, true),
        "thread answer" | "thread plan revise" => (true, true, true),
        _ => (true, true, false),
    };
    let thread = identifier(has_thread, fault == 1, fault == 2, MACHINE);
    let secondary = identifier(has_secondary, fault == 3, fault == 4, SECONDARY);
    let input = if has_input == (fault == 5) {
        None
    } else {
        Some(match fault {
            6 => String::new(),
            7 => "a\0b".to_owned(),
            8 => "x".repeat(64 * 1024 + 1),
            _ if tc.draw(gs::booleans()) => "x".repeat(64 * 1024),
            _ => tc.draw(gs::text().alphabet("ab \n'\"-").min_size(1).max_size(32)),
        })
    };
    let request = (fault == 9 || tc.draw(gs::booleans())).then(|| request_id(&tc, fault == 9));
    let (result, execs) = observe(|session| {
        let input = input.clone();
        Box::pin(async move {
            session
                .thread_action(thread, command, secondary, input.as_deref(), request)
                .await
        })
    });
    let ids_valid = thread != Some("NOT-AN-ID") && secondary != Some("NOT-AN-ID");
    let stdin_command = matches!(
        command,
        "thread prompt" | "thread answer" | "thread plan revise"
    );
    let shape = match command {
        "thread ls" => thread.is_none() && secondary.is_none() && input.is_none(),
        "thread show" | "thread turns" => {
            thread.is_some() && secondary.is_none() && input.is_none()
        }
        "thread prompt" => thread.is_some() && secondary.is_none() && input.is_some(),
        "thread answer" | "thread plan revise" => {
            thread.is_some() && secondary.is_some() && input.is_some()
        }
        "thread plan approve" => thread.is_some() && secondary.is_some() && input.is_none(),
        _ => false,
    };
    let stdin_valid = input
        .as_deref()
        .is_none_or(|text| !text.is_empty() && text.len() <= 64 * 1024 && !text.contains('\0'));
    let request_valid = request.is_none_or(|value| value == REQUEST);
    let accepted = ids_valid && shape && stdin_valid && request_valid;
    if !accepted {
        assert!(result.is_err(), "{command}");
        assert!(execs.is_empty(), "{command}");
        return;
    }
    // The grammar may still refuse a request id on a read; then nothing is sent.
    if result.is_err() {
        assert!(execs.is_empty(), "{command}");
        assert!(request.is_some(), "{command} {result:?}");
        assert!(
            matches!(command, "thread ls" | "thread show" | "thread turns"),
            "{command} {result:?}"
        );
        return;
    }
    assert_eq!(execs.len(), 1, "{command}");
    let sent = parsed(&execs[0].line);
    assert_eq!(sent.command, command);
    let mut arguments: Vec<String> = thread.into_iter().map(str::to_owned).collect();
    arguments.extend(secondary.map(str::to_owned));
    if stdin_command {
        arguments.push("-".to_owned());
    }
    assert_eq!(sent.arguments, arguments);
    assert_eq!(
        sent.options.get("json"),
        Some(&mila_protocol::OptionValue::Bool(true))
    );
    assert_eq!(
        string_option(&sent, "request-id").as_deref(),
        request,
        "{command}"
    );
    let expected_stdin = if stdin_command {
        input.unwrap_or_default().into_bytes()
    } else {
        Vec::new()
    };
    assert_eq!(execs[0].stdin, expected_stdin);
}

struct HardwareStandIn {
    key: p256::ecdsa::SigningKey,
}

impl DeviceSigner for HardwareStandIn {
    async fn sign(&mut self, message: &[u8]) -> Result<[u8; 64], SshError> {
        use p256::ecdsa::signature::Signer;
        let signature: p256::ecdsa::Signature = self.key.sign(message);
        Ok(signature.to_bytes().into())
    }
}

fn identity() -> (String, HardwareStandIn) {
    let key = p256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
    let mut blob = Vec::new();
    for bytes in [
        b"ecdsa-sha2-nistp256".as_slice(),
        b"nistp256",
        key.verifying_key().to_encoded_point(false).as_bytes(),
    ] {
        blob.extend_from_slice(&u32::try_from(bytes.len()).unwrap().to_be_bytes());
        blob.extend_from_slice(bytes);
    }
    (
        format!("ecdsa-sha2-nistp256 {}", STANDARD.encode(blob)),
        HardwareStandIn { key },
    )
}

/// Accepts every exec, records its line and stdin, and replies `{}` with exit 0.
struct Recorder {
    log: Log,
    pending: Option<Exec>,
}

impl server::Handler for Recorder {
    type Error = russh::Error;
    async fn auth_publickey(
        &mut self,
        _: &str,
        _: &russh::keys::PublicKey,
    ) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }
    async fn channel_open_session(
        &mut self,
        _: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }
    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.pending = Some(Exec {
            line: String::from_utf8_lossy(data).into_owned(),
            stdin: Vec::new(),
        });
        session.channel_success(channel)?;
        Ok(())
    }
    async fn data(
        &mut self,
        _: ChannelId,
        data: &[u8],
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        if let Some(pending) = self.pending.as_mut() {
            pending.stdin.extend_from_slice(data);
        }
        Ok(())
    }
    async fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        if let Some(exec) = self.pending.take() {
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(exec);
        }
        session.data(channel, b"{}".to_vec())?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }
}

fn harness() -> Harness {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let log = Log::default();
    let session = runtime.block_on(connect(log.clone()));
    Harness {
        runtime,
        session,
        log,
    }
}

async fn connect(log: Log) -> ApplicationSession {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let ca = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
    let host = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
    let mut builder = Builder::new(
        vec![1; 32],
        host.public_key().key_data().clone(),
        now - 60,
        now + 3_600,
    )
    .unwrap();
    builder
        .cert_type(CertType::Host)
        .unwrap()
        .key_id("test")
        .unwrap()
        .valid_principal("localhost")
        .unwrap();
    let certificate: Certificate = builder.sign(&ca).unwrap();
    let trust = TrustDocument {
        version: 1,
        ca: ca.public_key().to_openssh().unwrap(),
        management_host: "localhost".into(),
        zone: "example".into(),
        retirement: now + 3_600,
    };
    let mut config = server::Config {
        keys: vec![host],
        ..Default::default()
    };
    config.certificates = vec![certificate];
    config.auth_rejection_time = Duration::ZERO;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        if let Ok(connection) =
            server::run_stream(Arc::new(config), socket, Recorder { log, pending: None }).await
        {
            let _ = connection.await;
        }
    });
    let (public, signer) = identity();
    ApplicationSession::connect(trust, port, &public, signer, Duration::from_secs(10))
        .await
        .unwrap()
}
