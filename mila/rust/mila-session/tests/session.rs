use base64::{engine::general_purpose::STANDARD, Engine};
use mila_session::{ApplicationSession, SessionError};
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
    future::Future,
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
const SECOND: &str = "00000000-0000-0000-0000-000000000002";
fn machine(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name, "desired_state": "running", "observed_state": "running",
        "owner": true, "pinned": false, "permissions": {"read": true, "write": true, "manage": true}})
}
#[expect(
    clippy::unwrap_used,
    clippy::needless_pass_by_value,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test; it takes owned rows so call sites can build them inline"
)]
fn page(items: Vec<Value>, cursor: Option<&str>) -> Vec<u8> {
    serde_json::to_vec(&json!({"version": 1, "status": "succeeded", "result": {"items": items, "next_cursor": cursor}})).unwrap()
}
fn reply(command: &str, bytes: Vec<u8>) -> Response {
    Response {
        command: command.into(),
        bytes,
        exit: Some(0),
    }
}

#[tokio::test]
async fn pages_refresh_and_complete_snapshot_use_one_authenticated_connection() {
    let responses = Arc::new(Mutex::new(VecDeque::from([
        reply("ls --json", page(vec![machine(FIRST, "z")], Some(FIRST))),
        reply(
            &format!("ls --json --after {FIRST}"),
            page(vec![machine(SECOND, "a")], None),
        ),
        reply("ls --json", page(vec![machine(SECOND, "fresh")], None)),
    ])));
    let (trust, port, auth, task) = endpoint(responses.clone()).await;
    let signatures = Arc::new(AtomicUsize::new(0));
    let (public, signer) = identity(signatures.clone());
    let mut session =
        ApplicationSession::connect(trust, port, &public, signer, Duration::from_secs(5))
            .await
            .unwrap();
    assert!(session.listing().is_none());
    assert!(session.snapshot(1).unwrap().is_none());
    assert!(matches!(
        session.more_machines().await,
        Err(SessionError::NotLoaded)
    ));
    assert!(session.refresh_machines().await.unwrap().has_more());
    assert!(session.snapshot(2).unwrap().is_none());
    let listing = session.more_machines().await.unwrap();
    assert!(!listing.has_more());
    assert_eq!(
        listing
            .machines()
            .iter()
            .map(|m| m.id.as_str())
            .collect::<Vec<_>>(),
        [SECOND, FIRST]
    );
    let snapshot = session.snapshot(3).unwrap().unwrap();
    assert_eq!(snapshot.host, "localhost");
    assert_eq!(snapshot.port, Some(port));
    assert_eq!(snapshot.saved_at, 3);
    assert_eq!(snapshot.machines.len(), 2);
    assert_eq!(session.more_machines().await.unwrap().machines().len(), 2); // no extra command
    let fresh = session.refresh_machines().await.unwrap();
    assert_eq!(fresh.machines().len(), 1);
    assert_eq!(fresh.machines()[0].name, "fresh");
    assert_eq!(auth.load(Ordering::SeqCst), 1);
    assert_eq!(signatures.load(Ordering::SeqCst), 1);
    assert!(responses.lock().unwrap().is_empty());
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn invalid_refused_and_interrupted_refresh_never_replace_the_last_good_list() {
    let responses = Arc::new(Mutex::new(VecDeque::from([
        reply("ls --json", page(vec![machine(FIRST, "kept")], None)),
        reply("ls --json", b"not json".to_vec()),
        Response {
            command: "ls --json".into(),
            bytes: page(vec![], None),
            exit: Some(1),
        },
        Response {
            command: "ls --json".into(),
            bytes: page(vec![], None),
            exit: None,
        },
        reply("ls --json", page(vec![], None)),
    ])));
    let (trust, port, _, task) = endpoint(responses.clone()).await;
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let mut session =
        ApplicationSession::connect(trust, port, &public, signer, Duration::from_secs(5))
            .await
            .unwrap();
    session.refresh_machines().await.unwrap();
    assert!(matches!(
        session.refresh_machines().await,
        Err(SessionError::InvalidListing)
    ));
    assert_eq!(session.listing().unwrap().machines()[0].name, "kept");
    assert!(matches!(
        session.refresh_machines().await,
        Err(SessionError::Refused)
    ));
    assert_eq!(session.listing().unwrap().machines()[0].name, "kept");
    assert!(matches!(
        session.refresh_machines().await,
        Err(SessionError::Transport(SshError::MissingExit))
    ));
    assert_eq!(session.listing().unwrap().machines()[0].name, "kept");
    assert_eq!(session.refresh_machines().await.unwrap().machines(), []);
    assert!(responses.lock().unwrap().is_empty());
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn authenticated_share_mutations_use_typed_commands_and_reject_bad_roles() {
    let responses = Arc::new(Mutex::new(VecDeque::from([
        reply(
            &format!("share add {FIRST} 'teammate@example.test' viewer --json --request-id=porsche-00000000000000000000000000000000"),
            Vec::new(),
        ),
        reply(
            &format!("share remove {FIRST} 'teammate@example.test' --json --request-id=porsche-11111111111111111111111111111111"),
            Vec::new(),
        ),
    ])));
    let (trust, port, _, task) = endpoint(responses.clone()).await;
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let mut session =
        ApplicationSession::connect(trust, port, &public, signer, Duration::from_secs(5))
            .await
            .unwrap();
    session
        .share_mutation(
            FIRST,
            "teammate@example.test",
            Some("viewer"),
            true,
            "porsche-00000000000000000000000000000000",
        )
        .await
        .unwrap();
    session
        .share_mutation(
            FIRST,
            "teammate@example.test",
            None,
            false,
            "porsche-11111111111111111111111111111111",
        )
        .await
        .unwrap();
    assert!(matches!(
        session
            .share_mutation(
                FIRST,
                "teammate@example.test",
                Some("owner"),
                true,
                "porsche-22222222222222222222222222222222"
            )
            .await,
        Err(SessionError::MutationRefused)
    ));
    assert!(responses.lock().unwrap().is_empty());
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn machine_and_share_reads_use_grammar_checked_commands() {
    let grants = br#"{"owner":{"email":"owner@example.test"},"items":[]}"#.to_vec();
    let responses = Arc::new(Mutex::new(VecDeque::from([
        reply(
            &format!("show {FIRST} --json"),
            machine(FIRST, "box").to_string().into_bytes(),
        ),
        reply(&format!("share show {FIRST} --json"), grants.clone()),
        reply(&format!("share show {FIRST} --json"), b"not json".to_vec()),
    ])));
    let (trust, port, _, task) = endpoint(responses.clone()).await;
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let mut session =
        ApplicationSession::connect(trust, port, &public, signer, Duration::from_secs(5))
            .await
            .unwrap();
    let shown: Value = serde_json::from_slice(&session.machine_show(FIRST).await.unwrap()).unwrap();
    assert_eq!(shown["name"], "box");
    assert_eq!(session.share_show(FIRST).await.unwrap(), grants);
    assert!(matches!(
        session.share_show(FIRST).await,
        Err(SessionError::Refused)
    ));
    assert!(matches!(
        session.machine_show("not a machine").await,
        Err(SessionError::InvalidListing)
    ));
    assert!(responses.lock().unwrap().is_empty());
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn cyclic_pagination_keeps_previous_rows_and_cursor() {
    let responses = Arc::new(Mutex::new(VecDeque::from([
        reply("ls --json", page(vec![machine(FIRST, "kept")], Some(FIRST))),
        reply(
            &format!("ls --json --after {FIRST}"),
            page(vec![machine(SECOND, "discard")], Some(FIRST)),
        ),
        reply(
            &format!("ls --json --after {FIRST}"),
            page(vec![machine(SECOND, "accepted")], None),
        ),
    ])));
    let (trust, port, _, task) = endpoint(responses.clone()).await;
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let mut session =
        ApplicationSession::connect(trust, port, &public, signer, Duration::from_secs(5))
            .await
            .unwrap();
    session.refresh_machines().await.unwrap();
    assert!(matches!(
        session.more_machines().await,
        Err(SessionError::RepeatedCursor)
    ));
    assert_eq!(session.listing().unwrap().machines().len(), 1);
    assert!(session.listing().unwrap().has_more());
    assert!(session.snapshot(1).unwrap().is_none());
    assert_eq!(session.more_machines().await.unwrap().machines().len(), 2);
    assert!(responses.lock().unwrap().is_empty());
    session.close().await.unwrap();
    task.abort();
}
impl DeviceSigner for HardwareStandIn {
    fn sign(&mut self, message: &[u8]) -> impl Future<Output = Result<[u8; 64], SshError>> + Send {
        use p256::ecdsa::signature::Signer;
        self.calls.fetch_add(1, Ordering::SeqCst);
        let signature: p256::ecdsa::Signature = self.key.sign(message);
        std::future::ready(Ok(signature.to_bytes().into()))
    }
}
#[expect(
    clippy::unwrap_used,
    clippy::cast_possible_truncation,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test, and the three SSH key fields are under 100 bytes"
)]
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
}
struct Handler {
    responses: Arc<Mutex<VecDeque<Response>>>,
    pending: Option<Response>,
    authentications: Arc<AtomicUsize>,
}
impl server::Handler for Handler {
    type Error = russh::Error;
    fn auth_publickey(
        &mut self,
        _: &str,
        _: &russh::keys::PublicKey,
    ) -> impl Future<Output = Result<server::Auth, Self::Error>> + Send {
        self.authentications.fetch_add(1, Ordering::SeqCst);
        std::future::ready(Ok(server::Auth::Accept))
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
    #[expect(
        clippy::unwrap_used,
        clippy::expect_used,
        reason = "scripted test server: an unexpected command must fail the calling test"
    )]
    fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut server::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        let response = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected command");
        assert_eq!(data, response.command.as_bytes());
        self.pending = Some(response);
        std::future::ready(session.channel_success(channel))
    }
    #[expect(
        clippy::unwrap_used,
        reason = "scripted test server: EOF always follows the exec that set the pending response"
    )]
    fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut server::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        std::future::ready((|| {
            session.extended_data(channel, 1, b"discard progress".to_vec())?;
            let response = self.pending.take().unwrap();
            session.data(channel, response.bytes)?;
            if let Some(exit) = response.exit {
                session.exit_status_request(channel, exit)?;
            }
            session.eof(channel)?;
            session.close(channel)?;
            Ok(())
        })())
    }
}
#[expect(
    clippy::unwrap_used,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test"
)]
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
            },
        )
        .await
        {
            let _ = connection.await;
        }
    });
    (trust, port, authentications, task)
}
