use base64::{engine::general_purpose::STANDARD, Engine};
use mila_transport::{
    ssh::{DeviceSigner, PtyChunk, PtySession, SshError, SshSession},
    TrustDocument,
};
use russh::{
    keys::{
        ssh_key::certificate::{Builder, CertType},
        Algorithm, Certificate, PrivateKey,
    },
    server, Channel, ChannelId,
};
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
struct Handler {
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
        if data == b"terminal attach --json" {
            session.channel_success(channel)?;
            session.data(channel, b"ready\r\n".to_vec())?;
            return Ok(());
        }
        assert_eq!(data, b"images --json");
        session.channel_success(channel)?;
        Ok(())
    }
    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _: &str,
        _: u32,
        _: u32,
        _: u32,
        _: u32,
        _: &[(russh::Pty, u32)],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }
    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        if data == b"exit" {
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            session.close(channel)?;
        }
        Ok(())
    }
    async fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.extended_data(channel, 1, b"discard progress".to_vec())?;
        session.data(channel, b"{\"version\":1}".to_vec())?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }
}
async fn endpoint(
    principal: &str,
    expired: bool,
    bare: bool,
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
        if expired { now - 1 } else { now + 60 },
    )
    .unwrap();
    builder
        .cert_type(CertType::Host)
        .unwrap()
        .key_id("test")
        .unwrap()
        .valid_principal(principal)
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
    if !bare {
        config.certificates = vec![certificate];
    }
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
            },
        )
        .await
        {
            let _ = connection.await;
        }
    });
    (trust, port, authentications, task)
}
#[tokio::test]
async fn authenticated_exec_over_real_tcp_and_external_signer() {
    let (trust, port, auth, task) = endpoint("localhost", false, false).await;
    let calls = Arc::new(AtomicUsize::new(0));
    let (public, signer) = identity(calls.clone());
    let session = SshSession::connect(trust, port, &public, signer, Duration::from_secs(5))
        .await
        .unwrap();
    let output = session.exec("images --json", b"").await.unwrap();
    assert_eq!(output.stdout, b"{\"version\":1}");
    assert_eq!(output.exit_status, 0);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(auth.load(Ordering::SeqCst), 1);
    session.close().await.unwrap();
    task.abort();
}
#[tokio::test]
async fn untrusted_hosts_never_reach_device_signing_or_authentication() {
    for (principal, expired, bare, wrong_ca) in [
        ("foreign.example", false, false, false),
        ("localhost", true, false, false),
        ("localhost", false, true, false),
        ("localhost", false, false, true),
    ] {
        let (mut trust, port, auth, task) = endpoint(principal, expired, bare).await;
        if wrong_ca {
            trust.ca = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)
                .unwrap()
                .public_key()
                .to_openssh()
                .unwrap();
        }
        let calls = Arc::new(AtomicUsize::new(0));
        let (public, signer) = identity(calls.clone());
        assert!(
            SshSession::connect(trust, port, &public, signer, Duration::from_secs(5))
                .await
                .is_err()
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(auth.load(Ordering::SeqCst), 0);
        task.abort();
    }
}
#[test]
fn elixir_host_certificate_fixtures_match() {
    #[derive(serde::Deserialize)]
    struct Fixtures {
        certificates: Vec<Fixture>,
    }
    #[derive(serde::Deserialize)]
    struct Fixture {
        line: String,
        ca: String,
        principal: String,
        now: u64,
        valid: bool,
    }
    let fixtures: Fixtures =
        serde_json::from_str(include_str!("fixtures/ssh_host_certificates.json")).unwrap();
    for f in fixtures.certificates {
        let certificate = mila_transport::parse_host_certificate_line(&f.line).unwrap();
        assert_eq!(
            mila_transport::verify_host_certificate(&certificate, &f.ca, &f.principal, f.now)
                .is_ok(),
            f.valid
        );
    }
}

/// The bounded PTY read distinguishes data, an elapsed wait on an open channel
/// and channel close over a real certificate-authenticated SSH connection.
#[tokio::test]
async fn pty_read_within_distinguishes_idle_from_close() {
    let (trust, port, _auth, task) = endpoint("localhost", false, false).await;
    let (public, signer) = identity(Arc::new(AtomicUsize::new(0)));
    let session = SshSession::connect(trust, port, &public, signer, Duration::from_secs(5))
        .await
        .unwrap();
    let mut pty = PtySession::open(&session, 80, 24).await.unwrap();
    // Channel bookkeeping messages surface as `Idle`; the first data chunk
    // must still arrive intact.
    let mut first = PtyChunk::Idle;
    for _ in 0..16 {
        first = pty.read_within(Duration::from_secs(5)).await.unwrap();
        if first != PtyChunk::Idle {
            break;
        }
    }
    assert_eq!(first, PtyChunk::Data(b"ready\r\n".to_vec()));
    assert_eq!(
        pty.read_within(Duration::from_millis(20)).await.unwrap(),
        PtyChunk::Idle
    );
    pty.write(b"exit").await.unwrap();
    let mut closed = false;
    for _ in 0..16 {
        if pty.read_within(Duration::from_secs(5)).await.unwrap() == PtyChunk::Closed {
            closed = true;
            break;
        }
    }
    assert!(closed, "channel close must be reported");
    assert_eq!(
        pty.read_within(Duration::ZERO).await.unwrap(),
        PtyChunk::Closed
    );
    assert!(matches!(pty.write(b"x").await, Err(SshError::Bounds)));
    session.close().await.unwrap();
    task.abort();
}
