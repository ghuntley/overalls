use base64::{engine::general_purpose::STANDARD, Engine};
use mila_transport::{
    ssh::{DeviceSigner, SshError, SshSession},
    TrustDocument, WatchEvent, WatchRead, WatchRequest, WatchSession,
};
use russh::{
    keys::{
        ssh_key::certificate::{Builder, CertType},
        Algorithm, Certificate, PrivateKey,
    },
    server, Channel, ChannelId,
};
use std::{
    future::Future,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

struct HardwareStandIn {
    key: p256::ecdsa::SigningKey,
    calls: Arc<AtomicUsize>,
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

struct Script {
    chunks: Vec<Vec<u8>>,
    exit: Option<u32>,
}
struct Handler {
    authentications: Arc<AtomicUsize>,
    scripts: Arc<Mutex<std::collections::VecDeque<Script>>>,
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
        reason = "a poisoned script or unexpected command must fail the TCP fixture"
    )]
    fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut server::Session,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send {
        std::future::ready((|| {
            let command =
                mila_protocol::Command::parse(std::str::from_utf8(data).unwrap()).unwrap();
            assert_eq!(command.command, "watch");
            assert_eq!(
                command.options.get("session"),
                Some(&mila_protocol::OptionValue::Bool(true))
            );
            session.channel_success(channel)?;
            let script = self
                .scripts
                .lock()
                .unwrap()
                .pop_front()
                .expect("one script per watch");
            for chunk in script.chunks {
                session.data(channel, chunk)?;
            }
            if let Some(status) = script.exit {
                session.exit_status_request(channel, status)?;
                session.close(channel)?;
            }
            Ok(())
        })())
    }
}
#[expect(
    clippy::unwrap_used,
    reason = "integration-test fixture helper outside #[test]; a failed fixture setup must abort the calling test"
)]
async fn endpoint(
    scripts: Vec<Script>,
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
                scripts: Arc::new(Mutex::new(scripts.into())),
            },
        )
        .await
        {
            let _ = connection.await;
        }
    });
    (trust, port, authentications, task)
}

const MACHINE: &str = "00000000-0000-0000-0000-000000000001";
const THREAD: &str = "00000000-0000-0000-0000-000000000002";
const SESSION: &str = "00000000-0000-0000-0000-000000000003";
#[expect(clippy::unwrap_used, reason = "canonical fixture identifiers")]
fn request() -> WatchRequest {
    WatchRequest::new(
        vec![MACHINE.parse().unwrap()],
        vec![THREAD.parse().unwrap()],
    )
    .unwrap()
}
#[expect(clippy::unwrap_used, reason = "valid JSON fixture")]
fn watching() -> Vec<u8> {
    let mut line=serde_json::to_vec(&serde_json::json!({"version":1,"event":"watching","session_id":SESSION,"machines":[MACHINE],"threads":[THREAD]})).unwrap();
    line.push(b'\n');
    line
}
#[expect(clippy::unwrap_used, reason = "fixture TCP connection must succeed")]
async fn connect(
    scripts: Vec<Script>,
) -> (SshSession, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
    let (trust, port, auth, task) = endpoint(scripts).await;
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let session = SshSession::connect(trust, port, &public, signer, Duration::from_secs(5))
        .await
        .unwrap();
    (session, auth, task)
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-watch-tcp-stream
/// A real pinned SSH watch MUST decode fragmented lines and batched identifier
/// hints, preserve idle state and reuse one authenticated connection on reopen.
#[tokio::test]
async fn watch_stream_frames_fragments_hints_and_reopens_one_connection() {
    let start = watching();
    let mut tail = start[10..].to_vec();
    tail.extend_from_slice(format!("{{\"version\":1,\"event\":\"heartbeat\"}}\n{{\"version\":1,\"event\":\"machine\",\"id\":\"{MACHINE}\"}}\n{{\"version\":1,\"event\":\"thread\",\"id\":\"{THREAD}\"}}\n{{\"version\":1,\"event\":\"session\",\"id\":\"{SESSION}\"}}\n{{\"version\":1,\"event\":\"resync\"}}\n").as_bytes());
    let (session, auth, task) = connect(vec![
        Script {
            chunks: vec![start[..10].to_vec(), tail],
            exit: None,
        },
        Script {
            chunks: vec![watching()],
            exit: Some(0),
        },
    ])
    .await;
    let mut stream = WatchSession::open(&session, request()).await.unwrap();
    assert!(matches!(
        stream.read_within(Duration::from_secs(5)).await,
        WatchRead::Event(WatchEvent::Watching { .. })
    ));
    for expected in [
        WatchEvent::Heartbeat,
        WatchEvent::MachineChanged(MACHINE.parse().unwrap()),
        WatchEvent::ThreadChanged(THREAD.parse().unwrap()),
        WatchEvent::SessionChanged(SESSION.parse().unwrap()),
        WatchEvent::Resync,
    ] {
        assert_eq!(
            stream.read_within(Duration::from_secs(5)).await,
            WatchRead::Event(expected)
        );
    }
    assert_eq!(
        stream.read_within(Duration::from_millis(10)).await,
        WatchRead::Idle
    );
    stream.close().await;
    assert_eq!(stream.read_within(Duration::ZERO).await, WatchRead::Closed);
    let mut reopened = WatchSession::open(&session, request()).await.unwrap();
    assert!(matches!(
        reopened.read_within(Duration::from_secs(5)).await,
        WatchRead::Event(WatchEvent::Watching { .. })
    ));
    assert_eq!(
        reopened.read_within(Duration::from_secs(5)).await,
        WatchRead::Closed
    );
    assert_eq!(auth.load(Ordering::SeqCst), 1);
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn watch_heartbeat_stall_is_transport_loss_and_authority_refusal_is_distinct() {
    let (session, _, task) = connect(vec![
        Script {
            chunks: vec![watching()],
            exit: None,
        },
        Script {
            chunks: vec![br#"{"version":1,"status":"error","error":"forbidden"}
"#
            .to_vec()],
            exit: Some(3),
        },
    ])
    .await;
    let mut stream =
        WatchSession::open_with_heartbeat_timeout(&session, request(), Duration::from_millis(100))
            .await
            .unwrap();
    assert!(matches!(
        stream.read_within(Duration::from_secs(5)).await,
        WatchRead::Event(WatchEvent::Watching { .. })
    ));
    assert_eq!(
        stream.read_within(Duration::from_millis(5)).await,
        WatchRead::Idle
    );
    assert_eq!(
        stream.read_within(Duration::from_secs(1)).await,
        WatchRead::TransportLost
    );
    let mut refused = WatchSession::open(&session, request()).await.unwrap();
    assert_eq!(
        refused.read_within(Duration::from_secs(5)).await,
        WatchRead::AuthorityLost
    );
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn watch_refuses_unsubscribed_hints_mismatched_subscription_and_unbounded_lines() {
    let wrong=serde_json::to_vec(&serde_json::json!({"version":1,"event":"watching","session_id":SESSION,"machines":[],"threads":[]})).unwrap();
    let mut wrong_line = wrong;
    wrong_line.push(b'\n');
    let hints =
        format!("{{\"version\":1,\"event\":\"machine\",\"id\":\"{MACHINE}\"}}\n").into_bytes();
    let (session, _, task) = connect(vec![
        Script {
            chunks: vec![hints],
            exit: None,
        },
        Script {
            chunks: vec![wrong_line],
            exit: None,
        },
        Script {
            chunks: vec![vec![b'x'; 65537]],
            exit: None,
        },
    ])
    .await;
    for _ in 0..3 {
        let mut stream = WatchSession::open(&session, request()).await.unwrap();
        assert_eq!(
            stream.read_within(Duration::from_secs(5)).await,
            WatchRead::TransportLost
        );
    }
    session.close().await.unwrap();
    task.abort();
}

#[tokio::test]
async fn watch_shards_sixty_four_filters_with_one_authentication() {
    let machines = (1..=64).map(uuid::Uuid::from_u128).collect::<Vec<_>>();
    let scripts=machines.chunks(16).map(|chunk| {
        let mut line=serde_json::to_vec(&serde_json::json!({"version":1,"event":"watching","session_id":SESSION,"machines":chunk,"threads":[]})).unwrap();
        line.push(b'\n'); Script {chunks:vec![line],exit:None}
    }).collect();
    let (session, auth, task) = connect(scripts).await;
    let mut stream = WatchSession::open(
        &session,
        WatchRequest::new(machines.clone(), vec![]).unwrap(),
    )
    .await
    .unwrap();
    let mut watched = Vec::new();
    for _ in 0..4 {
        let WatchRead::Event(WatchEvent::Watching { machines, .. }) =
            stream.read_within(Duration::from_secs(5)).await
        else {
            panic!("expected each authorized shard");
        };
        assert!(machines.len() <= 16);
        watched.extend(machines);
    }
    watched.sort();
    assert_eq!(watched, machines);
    assert_eq!(auth.load(Ordering::SeqCst), 1);
    stream.close().await;
    session.close().await.unwrap();
    task.abort();
}
