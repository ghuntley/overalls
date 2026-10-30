use base64::{engine::general_purpose::STANDARD, Engine};
use mila_ffi::session::*;
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
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::sync::Mutex;
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

struct HardwareStandIn {
    key: p256::ecdsa::SigningKey,
    calls: Arc<AtomicUsize>,
}

const FIRST: &str = "00000000-0000-0000-0000-000000000001";

fn machine(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name, "desired_state": "running", "observed_state": "running",
        "owner": true, "pinned": false, "permissions": {"read": true, "write": true, "manage": true}})
}
fn page(items: Vec<Value>, cursor: Option<&str>) -> Vec<u8> {
    serde_json::to_vec(&json!({"version": 1, "status": "succeeded", "result": {"items": items, "next_cursor": cursor}})).unwrap()
}
fn reply(command: &str, bytes: Vec<u8>) -> Response {
    Response {
        command: command.into(),
        bytes,
        exit: Some(0),
        stdin: None,
    }
}

impl DeviceSigner for HardwareStandIn {
    async fn sign(&mut self, message: &[u8]) -> Result<[u8; 64], SshError> {
        use p256::ecdsa::signature::Signer;
        self.calls.fetch_add(1, Ordering::SeqCst);
        let signature: p256::ecdsa::Signature = self.key.sign(message);
        Ok(signature.to_bytes().into())
    }
}
fn identity(calls: Arc<AtomicUsize>) -> (String, HardwareStandIn) {
    let key = p256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
    let mut blob = Vec::new();
    for bytes in [
        b"ecdsa-sha2-nistp256".as_slice(),
        b"nistp256",
        key.verifying_key().to_encoded_point(false).as_bytes(),
    ] {
        blob.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        blob.extend_from_slice(bytes);
    }
    (
        format!("ecdsa-sha2-nistp256 {}", STANDARD.encode(blob)),
        HardwareStandIn { key, calls },
    )
}
struct Response {
    command: String,
    bytes: Vec<u8>,
    exit: Option<u32>,
    /// When set, the exact stdin bytes the client must send before EOF.
    stdin: Option<Vec<u8>>,
}
struct Handler {
    responses: Arc<Mutex<VecDeque<Response>>>,
    pending: Option<Response>,
    received: Vec<u8>,
    authentications: Arc<AtomicUsize>,
}
impl server::Handler for Handler {
    type Error = russh::Error;
    async fn auth_publickey(
        &mut self,
        _: &str,
        _: &russh::keys::PublicKey,
    ) -> Result<server::Auth, Self::Error> {
        self.authentications.fetch_add(1, Ordering::SeqCst);
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
        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected command");
        assert_eq!(data, response.command.as_bytes());
        self.pending = Some(response);
        self.received.clear();
        session.channel_success(channel)?;
        Ok(())
    }
    async fn data(
        &mut self,
        _: ChannelId,
        data: &[u8],
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.received.extend_from_slice(data);
        Ok(())
    }
    async fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.extended_data(channel, 1, b"discard progress".to_vec())?;
        let response = self.pending.take().unwrap();
        if let Some(expected) = &response.stdin {
            assert_eq!(&self.received, expected, "stdin payload");
        }
        session.data(channel, response.bytes)?;
        if let Some(exit) = response.exit {
            session.exit_status_request(channel, exit)?;
        }
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }
}
async fn endpoint(
    responses: Arc<Mutex<VecDeque<Response>>>,
) -> (
    TrustDocument,
    u16,
    Arc<AtomicUsize>,
    tokio::task::JoinHandle<()>,
) {
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
        now + 60,
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
        retirement: now + 60,
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
    let authentications = Arc::new(AtomicUsize::new(0));
    let count = authentications.clone();
    let task = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        if let Ok(connection) = server::run_stream(
            Arc::new(config),
            socket,
            Handler {
                authentications: count,
                responses,
                pending: None,
                received: Vec::new(),
            },
        )
        .await
        {
            let _ = connection.await;
        }
    });
    (trust, port, authentications, task)
}

unsafe extern "C" fn sign(context: usize, message: *const u8, len: usize, output: *mut u8) -> i32 {
    use p256::ecdsa::signature::Signer;
    let signer = &*(context as *const HardwareStandIn);
    signer.calls.fetch_add(1, Ordering::SeqCst);
    let signature: p256::ecdsa::Signature =
        signer.key.sign(std::slice::from_raw_parts(message, len));
    std::ptr::copy_nonoverlapping(signature.to_bytes().as_ptr(), output, 64);
    0
}
#[test]
fn ffi_real_ssh_read_snapshot_and_close() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let responses = Arc::new(Mutex::new(VecDeque::from([
        reply("ls --json", page(vec![machine(FIRST, "live")], None)),
        reply("ls --json", b"malformed".to_vec()),
    ])));
    let (trust, port, auth, task) = runtime.block_on(endpoint(responses.clone()));
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let trust = serde_json::to_vec(&trust).unwrap();
    let mut handle = 0;
    unsafe {
        assert_eq!(
            mila_session_connect(
                trust.as_ptr(),
                trust.len(),
                b"localhost".as_ptr(),
                9,
                public.as_ptr(),
                public.len(),
                port,
                5000,
                Some(sign),
                &signer as *const _ as usize,
                &mut handle
            ),
            SessionStatus::Ok
        );
        assert_ne!(handle, 0);
        assert_eq!(mila_session_read_machines(handle, 0), SessionStatus::Ok);
        let mut required = 0;
        assert_eq!(
            mila_session_listing(handle, std::ptr::null_mut(), 0, &mut required),
            SessionStatus::SmallBuffer
        );
        let mut data = vec![0; required];
        assert_eq!(
            mila_session_listing(handle, data.as_mut_ptr(), data.len(), &mut required),
            SessionStatus::Ok
        );
        let value: Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(value["machines"][0]["name"], "live");
        assert_eq!(
            mila_session_read_machines(handle, 0),
            SessionStatus::Transport
        );
        assert_eq!(
            mila_session_snapshot(handle, 42, std::ptr::null_mut(), 0, &mut required),
            SessionStatus::SmallBuffer
        );
        let mut snapshot = vec![0; required];
        assert_eq!(
            mila_session_snapshot(
                handle,
                42,
                snapshot.as_mut_ptr(),
                snapshot.len(),
                &mut required
            ),
            SessionStatus::Ok
        );
        let decoded =
            mila_runtime::MachineSnapshot::decode(&snapshot, "localhost", Some(port)).unwrap();
        assert_eq!(decoded.machines[0].name, "live");
        assert_eq!(decoded.saved_at, 42);
        assert_eq!(mila_session_close(handle), SessionStatus::Ok);
        assert_eq!(mila_session_close(handle), SessionStatus::InvalidHandle);
        assert_eq!(
            mila_session_listing(handle, data.as_mut_ptr(), data.len(), &mut required),
            SessionStatus::InvalidHandle
        );
    }
    assert_eq!(signer.calls.load(Ordering::SeqCst), 1);
    assert_eq!(auth.load(Ordering::SeqCst), 1);
    assert!(responses.lock().unwrap().is_empty());
    task.abort();
}
#[hegel::test(test_cases = 128)]
fn arbitrary_stale_handles_refuse_without_writing(tc: hegel::TestCase) {
    let handle = tc.draw(hegel::generators::default::<u64>()) | (1u64 << 63);
    let mut output = [0xA5; 32];
    let mut written = 123;
    unsafe {
        assert_eq!(
            mila_session_listing(handle, output.as_mut_ptr(), output.len(), &mut written),
            SessionStatus::InvalidHandle
        );
    }
    assert_eq!(output, [0xA5; 32]);
    assert_eq!(written, 123);
    assert_eq!(mila_session_close(handle), SessionStatus::InvalidHandle);
}

#[test]
fn machine_actions_reject_invalid_inputs_before_lookup() {
    let machine = b"not-an-id";
    let action = b"start";
    let request = b"porsche-00000000000000000000000000000000";
    let status = unsafe {
        mila_session_machine_action(
            u64::MAX,
            machine.as_ptr(),
            machine.len(),
            action.as_ptr(),
            action.len(),
            request.as_ptr(),
            request.len(),
        )
    };
    assert_eq!(status, SessionStatus::InvalidHandle);
}

/// PTY handles are opaque capabilities. Every generated stale handle must be
/// rejected without modifying caller-owned output or length storage.
#[hegel::test(test_cases = 128)]
fn arbitrary_stale_terminal_handles_refuse_without_writing(tc: hegel::TestCase) {
    let handle = tc.draw(hegel::generators::default::<u64>()) | (1_u64 << 63);
    let mut output = [0xA5; 64];
    let mut written = 17_usize;
    unsafe {
        assert_eq!(
            mila_session_terminal_poll(handle, output.as_mut_ptr(), output.len(), &mut written),
            SessionStatus::InvalidHandle
        );
        assert_eq!(
            mila_session_terminal_input(handle, b"x".as_ptr(), 1),
            SessionStatus::InvalidHandle
        );
    }
    assert_eq!(
        mila_session_terminal_resize(handle, 80, 24),
        SessionStatus::InvalidHandle
    );
    assert_eq!(
        mila_session_terminal_kill(handle),
        SessionStatus::InvalidHandle
    );
    assert_eq!(output, [0xA5; 64]);
    assert_eq!(written, 17);
}

/// The bounded terminal read refuses undersized buffers and out-of-range waits
/// before any handle lookup, and stale handles never write caller storage.
#[hegel::test(test_cases = 128)]
fn arbitrary_terminal_reads_refuse_before_consuming(tc: hegel::TestCase) {
    let handle = tc.draw(hegel::generators::default::<u64>()) | (1_u64 << 63);
    let wait = tc.draw(hegel::generators::default::<u32>());
    let mut output = vec![0xA5_u8; MILA_TERMINAL_READ_CAPACITY];
    let mut written = 17_usize;
    let mut state = TerminalReadEvent::Closed;
    let status = unsafe {
        mila_session_terminal_read_within(
            handle,
            wait,
            output.as_mut_ptr(),
            output.len(),
            &mut written,
            &mut state,
        )
    };
    if wait > 1_000 {
        assert_eq!(status, SessionStatus::Invalid);
    } else {
        assert_eq!(status, SessionStatus::InvalidHandle);
    }
    let small = unsafe {
        mila_session_terminal_read_within(
            handle,
            0,
            output.as_mut_ptr(),
            MILA_TERMINAL_READ_CAPACITY - 1,
            &mut written,
            &mut state,
        )
    };
    assert_eq!(small, SessionStatus::Invalid);
    assert!(output.iter().all(|byte| *byte == 0xA5));
    assert_eq!(written, 17);
    assert_eq!(state, TerminalReadEvent::Closed);
}

/// Dimension validation is stable across the full generated input space and
/// does not perform a session lookup for malformed dimensions.
#[hegel::test(test_cases = 128)]
fn arbitrary_terminal_dimensions_are_bounded_before_lookup(tc: hegel::TestCase) {
    let columns = tc.draw(hegel::generators::default::<u32>());
    let rows = tc.draw(hegel::generators::default::<u32>());
    let valid = (1..=4096).contains(&columns) && (1..=512).contains(&rows);
    let mut terminal = 0_u64;
    let status = mila_session_terminal_attach(u64::MAX, columns, rows, &mut terminal);
    if valid {
        assert_eq!(status, SessionStatus::InvalidHandle);
    } else {
        assert_eq!(status, SessionStatus::Invalid);
    }
    assert_eq!(terminal, 0);
}

const PUSH_KEY: &str = "c3VzYW4tc2VhbGVkLXB1c2gta2V5LWZvci13bnM";
const ENC_PUBKEY: &str = "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU";

fn connect_scripted(
    runtime: &tokio::runtime::Runtime,
    responses: Arc<Mutex<VecDeque<Response>>>,
) -> (u64, HardwareStandIn, tokio::task::JoinHandle<()>) {
    let (trust, port, _, task) = runtime.block_on(endpoint(responses));
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let trust = serde_json::to_vec(&trust).unwrap();
    let mut handle = 0;
    // SAFETY: buffers live for the call; the signer outlives the connect.
    let status = unsafe {
        mila_session_connect(
            trust.as_ptr(),
            trust.len(),
            b"localhost".as_ptr(),
            9,
            public.as_ptr(),
            public.len(),
            port,
            5000,
            Some(sign),
            &signer as *const _ as usize,
            &mut handle,
        )
    };
    assert_eq!(status, SessionStatus::Ok);
    (handle, signer, task)
}

/// Fixture agreement with `protocol/test/fixtures/porsche_device_results.json`:
/// the Windows registration line is canonical, the push key travels only on
/// stdin, and the Susan reply is validated before any channel opens.
#[test]
fn ffi_device_register_sends_push_key_on_stdin_only() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let result = br#"{"version":1,"status":"succeeded","request_id":"porsche-0123456789abcdef0123456789abcdef","operation_id":null,"result":{"id":"5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b","platform":"windows","enabled":true,"state":"active"}}"#.to_vec();
    let line = format!(
        "device register --enc-pubkey={ENC_PUBKEY} --json --label=Desk --platform=windows --push-key=-"
    );
    let responses = Arc::new(Mutex::new(VecDeque::from([Response {
        command: line.clone(),
        bytes: result.clone(),
        exit: Some(0),
        stdin: Some(PUSH_KEY.as_bytes().to_vec()),
    }])));
    let parsed = mila_protocol::Command::parse(&line).expect("canonical line parses");
    assert_eq!(parsed.format().unwrap(), line);
    let (handle, _signer, task) = connect_scripted(&runtime, responses.clone());
    let susan =
        format!(r#"{{"push_key":"{PUSH_KEY}","key_id":"k1","expires_at":"2099-01-01T00:00:00Z"}}"#);
    let expired =
        format!(r#"{{"push_key":"{PUSH_KEY}","key_id":"k1","expires_at":"2000-01-01T00:00:00Z"}}"#);
    let mut out = vec![0u8; 4096];
    let mut written = 0usize;
    // SAFETY: every pointer references a live buffer of the stated length.
    unsafe {
        let register =
            |reply: &str, key: &str, platform: u8, out: &mut [u8], written: &mut usize| {
                mila_session_device_register(
                    handle,
                    platform,
                    reply.as_ptr(),
                    reply.len(),
                    key.as_ptr(),
                    key.len(),
                    b"Desk".as_ptr(),
                    4,
                    1_800_000_000,
                    out.as_mut_ptr(),
                    out.len(),
                    written,
                )
            };
        assert_eq!(
            register(&expired, ENC_PUBKEY, 3, &mut out, &mut written),
            SessionStatus::Invalid
        );
        assert_eq!(
            register(&susan, "short", 3, &mut out, &mut written),
            SessionStatus::Invalid
        );
        assert_eq!(
            register(&susan, ENC_PUBKEY, 4, &mut out, &mut written),
            SessionStatus::Invalid
        );
        assert_eq!(
            register(&susan, ENC_PUBKEY, 3, &mut out, &mut written),
            SessionStatus::Ok
        );
        assert_eq!(&out[..written], result.as_slice());
        assert_eq!(mila_session_close(handle), SessionStatus::Ok);
    }
    assert!(responses.lock().unwrap().is_empty());
    task.abort();
}

#[test]
fn terminal_read_refuses_stale_handles_and_null_outputs() {
    let mut out = [0u8; 8];
    let mut written = 0usize;
    let mut event = TerminalReadEvent::Data;
    // SAFETY: valid stack storage; null pointers are the refused inputs.
    unsafe {
        assert_eq!(
            mila_session_terminal_read(
                u64::MAX,
                out.as_mut_ptr(),
                out.len(),
                &mut written,
                &mut event
            ),
            SessionStatus::InvalidHandle
        );
        assert_eq!(
            mila_session_terminal_read(
                1,
                out.as_mut_ptr(),
                out.len(),
                &mut written,
                std::ptr::null_mut()
            ),
            SessionStatus::Invalid
        );
    }
    assert_eq!(event, TerminalReadEvent::Data);
}
