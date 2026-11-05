//! Authenticated Porsche channels over one certificate-pinned SSH connection.
use crate::{parse_host_certificate_blob, verify_host_certificate, TrustDocument};
use mila_protocol::{
    decode_attach_header, AttachHeader, AttachMode, AttachOutcome, MAX_ATTACH_HEADER_BYTES,
    MAX_TERMINAL_CURSOR,
};
use russh::{
    client,
    keys::{Algorithm, EcdsaCurve, PublicKey, PublicKeyOrCertificate},
    ChannelMsg,
};
use std::fmt::Write as _;
use std::{
    borrow::Cow,
    future::Future,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const MAX_OUTPUT: usize = 1 << 20;
const MAX_INPUT: usize = 1 << 20;

#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("SSH operation failed")]
    Ssh(#[from] russh::Error),
    #[error("SSH channel unavailable")]
    Send(#[from] russh::SendError),
    #[error("host is untrusted")]
    HostUntrusted,
    #[error("device authentication failed")]
    Authentication,
    #[error("invalid device signature")]
    Signature,
    #[error("operation timed out; command must not be retried")]
    Timeout,
    #[error("request or response exceeds bounds")]
    Bounds,
    #[error("channel closed without exit status")]
    MissingExit,
    #[error("terminal attachment header is invalid")]
    AttachHeader,
    #[error("terminal attachment does not grant write access")]
    ReadOnly,
}

/// OS adapters sign SHA-256 ECDSA with their non-exportable deployment key.
/// Return the fixed-width big-endian r || s signature, never a private key.
pub trait DeviceSigner: Send {
    fn sign(&mut self, message: &[u8]) -> impl Future<Output = Result<[u8; 64], SshError>> + Send;
}

struct ExternalSigner<S> {
    signer: S,
    key: PublicKey,
}
impl<S: DeviceSigner> russh::Signer for ExternalSigner<S> {
    type Error = SshError;
    async fn auth_sign(
        &mut self,
        _: &russh::keys::agent::AgentIdentity,
        _: Option<russh::keys::HashAlg>,
        mut data: Vec<u8>,
    ) -> Result<Vec<u8>, SshError> {
        use p256::ecdsa::signature::Verifier;
        let signature = self.signer.sign(&data).await?;
        let ec = self.key.key_data().ecdsa().ok_or(SshError::Signature)?;
        let public = p256::ecdsa::VerifyingKey::from_sec1_bytes(ec.as_sec1_bytes())
            .map_err(|_| SshError::Signature)?;
        let parsed =
            p256::ecdsa::Signature::from_slice(&signature).map_err(|_| SshError::Signature)?;
        public
            .verify(&data, &parsed)
            .map_err(|_| SshError::Signature)?;
        let mut integers = Vec::new();
        for integer in signature.as_chunks::<32>().0 {
            let first = integer.iter().position(|b| *b != 0).unwrap_or(31);
            let integer = &integer[first..];
            let padding = usize::from(integer[0] & 128 != 0);
            let length = u32::try_from(integer.len() + padding).map_err(|_| SshError::Signature)?;
            integers.extend_from_slice(&length.to_be_bytes());
            if padding == 1 {
                integers.push(0);
            }
            integers.extend_from_slice(integer);
        }
        let mut encoded = Vec::new();
        field(&mut encoded, b"ecdsa-sha2-nistp256");
        field(&mut encoded, &integers);
        field(&mut data, &encoded);
        Ok(data)
    }
}
fn field(output: &mut Vec<u8>, value: &[u8]) {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "callers pass an algorithm name, two P-256 integers or the userauth signing payload, all far below 4 GiB"
    )]
    let length = value.len() as u32;
    output.extend_from_slice(&length.to_be_bytes());
    output.extend_from_slice(value);
}

struct HostPolicy {
    trust: TrustDocument,
}
impl client::Handler for HostPolicy {
    type Error = SshError;
    fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> impl Future<Output = Result<bool, SshError>> + Send {
        std::future::ready(self.check(key))
    }
}
impl HostPolicy {
    fn check(&self, key: &PublicKeyOrCertificate) -> Result<bool, SshError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| SshError::HostUntrusted)?
            .as_secs();
        if self.trust.retirement <= now {
            return Err(SshError::HostUntrusted);
        }
        let certificate = key.certificate().ok_or(SshError::HostUntrusted)?;
        let blob = certificate
            .to_bytes()
            .map_err(|_| SshError::HostUntrusted)?;
        let parsed = parse_host_certificate_blob(&blob).ok_or(SshError::HostUntrusted)?;
        verify_host_certificate(&parsed, &self.trust.ca, &self.trust.management_host, now)
            .map_err(|_| SshError::HostUntrusted)?;
        Ok(true)
    }
}

/// One authenticated connection; all commands open channels on this connection.
pub struct SshSession {
    connection: client::Handle<HostPolicy>,
    timeout: Duration,
}
impl std::fmt::Debug for SshSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SshSession")
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}
#[derive(Debug, Eq, PartialEq)]
pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub exit_status: u32,
}
impl SshSession {
    /// @cc [owner:ghuntley,label:security] rust-ssh-auth-after-certificate
    /// Device signing MUST occur only after certificate-only key exchange verifies
    /// the pinned authority, management principal and current validity window.
    pub async fn connect<S: DeviceSigner>(
        trust: TrustDocument,
        port: u16,
        public_key: &str,
        signer: S,
        timeout: Duration,
    ) -> Result<Self, SshError> {
        let key = PublicKey::from_openssh(public_key).map_err(|_| SshError::Authentication)?;
        if key.algorithm()
            != (Algorithm::Ecdsa {
                curve: EcdsaCurve::NistP256,
            })
        {
            return Err(SshError::Authentication);
        }
        let hostname = trust.management_host.clone();
        let mut config = client::Config::default();
        config.preferred.key = Cow::Borrowed(&[]);
        config.preferred.host_key_certificates = Cow::Owned(vec![Algorithm::Ed25519]);
        config.inactivity_timeout = Some(Duration::from_mins(2));
        tokio::time::timeout(timeout, async move {
            let mut connection = client::connect(
                Arc::new(config),
                (hostname.as_str(), port),
                HostPolicy { trust },
            )
            .await?;
            let mut external = ExternalSigner {
                signer,
                key: key.clone(),
            };
            let result = connection
                .authenticate_publickey_with("mila", key, None, &mut external)
                .await?;
            if !result.success() {
                return Err(SshError::Authentication);
            }
            Ok(Self {
                connection,
                timeout,
            })
        })
        .await
        .map_err(|_| SshError::Timeout)?
    }

    /// @cc [owner:ghuntley,label:protocol;security] rust-ssh-exec-bounded-once
    /// Exec MUST submit once, bound stdin and stdout to one MiB, discard stderr,
    /// require an exit status, and never retry an uncertain submission.
    pub async fn exec(&self, command: &str, stdin: &[u8]) -> Result<ExecOutput, SshError> {
        let parsed = mila_protocol::Command::parse(command).map_err(|_| SshError::Bounds)?;
        if parsed.options.get("json") != Some(&mila_protocol::OptionValue::Bool(true)) {
            return Err(SshError::Bounds);
        }
        if command.len() > 8192 || command.contains('\0') || stdin.len() > MAX_INPUT {
            return Err(SshError::Bounds);
        }
        let channel = tokio::time::timeout(self.timeout, self.connection.channel_open_session())
            .await
            .map_err(|_| SshError::Timeout)??;
        let (mut reader, writer) = channel.split();
        let result = tokio::time::timeout(self.timeout, async {
            writer.exec(true, command.as_bytes()).await?;
            // Write and read concurrently: a full receive window must not block input.
            let write = async {
                writer.data(stdin).await?;
                writer.eof().await
            };
            let read = async {
                let mut stdout = Vec::new();
                let mut exit_status = None;
                while let Some(message) = reader.wait().await {
                    match message {
                        ChannelMsg::Data { data } => {
                            if stdout.len().saturating_add(data.len()) > MAX_OUTPUT {
                                return Err(SshError::Bounds);
                            }
                            stdout.extend_from_slice(&data);
                        }
                        ChannelMsg::ExitStatus {
                            exit_status: status,
                        } => exit_status = Some(status),
                        ChannelMsg::Failure => return Err(SshError::Authentication),
                        ChannelMsg::Close => break,
                        _ => {}
                    }
                }
                Ok(ExecOutput {
                    stdout,
                    exit_status: exit_status.ok_or(SshError::MissingExit)?,
                })
            };
            let ((), output) =
                tokio::try_join!(async { write.await.map_err(SshError::from) }, read)?;
            Ok(output)
        })
        .await
        .map_err(|_| SshError::Timeout);
        // Close also on timeout/overflow so a canceled operation cannot retain a channel.
        let _ = writer.close().await;
        result?
    }
    pub async fn close(self) -> Result<(), SshError> {
        self.connection
            .disconnect(russh::Disconnect::ByApplication, "", "")
            .await?;
        Ok(())
    }

    pub(crate) async fn watch_channel(&self) -> Result<russh::Channel<client::Msg>, SshError> {
        tokio::time::timeout(self.timeout, self.connection.channel_open_session())
            .await
            .map_err(|_| SshError::Timeout)?
            .map_err(SshError::from)
    }

    pub(crate) const fn operation_timeout(&self) -> Duration {
        self.timeout
    }
}

/// A bounded interactive PTY channel on an authenticated SSH session.
/// The channel is deliberately owned by the caller so reads and writes cannot
/// outlive the certificate-pinned connection that created them.
/// One bounded PTY read result. `Idle` means the wait elapsed or a non-data
/// channel message arrived while the channel remains open.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PtyChunk {
    Data(Vec<u8>),
    Idle,
    Closed,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TerminalAttachOptions {
    /// None requests the server's retained replay buffer.
    pub cursor: Option<u64>,
    pub read_only: bool,
}

pub struct PtySession {
    reader: russh::ChannelReadHalf,
    writer: russh::ChannelWriteHalf<client::Msg>,
    timeout: Duration,
    closed: bool,
    header: AttachHeader,
    cursor: u64,
    read_only: bool,
    outcome: Option<AttachOutcome>,
    /// Data received in a larger SSH frame than the native caller requested.
    /// Keeping the remainder here preserves byte-for-byte replay when a caller
    /// uses a small read buffer instead of the transport's one MiB maximum.
    pending: Vec<u8>,
}
impl std::fmt::Debug for PtySession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PtySession")
            .field("timeout", &self.timeout)
            .field("closed", &self.closed)
            .finish_non_exhaustive()
    }
}

impl PtySession {
    /// Opens a Porsche terminal with a server-side PTY and bounded dimensions.
    ///
    /// This legacy entry point names no machine or terminal session; Porsche's
    /// grammar requires both, so the server refuses it. Use [`Self::attach`].
    pub async fn open(session: &SshSession, columns: u32, rows: u32) -> Result<Self, SshError> {
        Self::open_line(
            session,
            "terminal attach --json",
            columns,
            rows,
            TerminalAttachOptions::default(),
        )
        .await
    }

    /// @cc [owner:ghuntley,label:protocol;security] rust-pty-attach-named-session
    /// Attachment MUST name one machine and one canonical terminal session id,
    /// be parsed by the shared command grammar before a channel opens, and
    /// request a PTY with bounded dimensions before the attach exec.
    pub async fn attach(
        session: &SshSession,
        machine: &str,
        terminal: &str,
        columns: u32,
        rows: u32,
    ) -> Result<Self, SshError> {
        Self::attach_with_options(
            session,
            machine,
            terminal,
            columns,
            rows,
            TerminalAttachOptions::default(),
        )
        .await
    }

    /// @cc [owner:ghuntley,label:protocol;security] rust-pty-replay-and-write-grant
    /// Attach MUST bound a replay cursor to the signed protocol range, consume
    /// the single bounded stderr header before exposing output, and permit input
    /// and resize only while both the user and server grant read-write access.
    pub async fn attach_with_options(
        session: &SshSession,
        machine: &str,
        terminal: &str,
        columns: u32,
        rows: u32,
        options: TerminalAttachOptions,
    ) -> Result<Self, SshError> {
        if options
            .cursor
            .is_some_and(|value| value > MAX_TERMINAL_CURSOR)
        {
            return Err(SshError::Bounds);
        }
        let mut line = String::from("terminal attach --json");
        if let Some(cursor) = options.cursor {
            write!(line, " --cursor={cursor}").map_err(|_| SshError::Bounds)?;
        }
        if options.read_only {
            line.push_str(" --read-only");
        }
        let _ = write!(line, " -- {machine} {terminal}");
        let line = mila_protocol::Command::parse(&line)
            .and_then(|command| command.format())
            .map_err(|_| SshError::Bounds)?;
        Self::open_line(session, &line, columns, rows, options).await
    }

    async fn open_line(
        session: &SshSession,
        line: &str,
        columns: u32,
        rows: u32,
        options: TerminalAttachOptions,
    ) -> Result<Self, SshError> {
        if !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) || line.len() > 8192 {
            return Err(SshError::Bounds);
        }
        let channel =
            tokio::time::timeout(session.timeout, session.connection.channel_open_session())
                .await
                .map_err(|_| SshError::Timeout)??;
        let (mut reader, writer) = channel.split();
        let result = tokio::time::timeout(session.timeout, async {
            writer
                .request_pty(true, "xterm-256color", columns, rows, 0, 0, &[])
                .await?;
            writer.exec(true, line.as_bytes()).await?;
            let mut bytes = Vec::new();
            while let Some(message) = reader.wait().await {
                match message {
                    ChannelMsg::ExtendedData { data, ext: 1 } => {
                        if bytes.len().saturating_add(data.len()) > MAX_ATTACH_HEADER_BYTES {
                            return Err(SshError::AttachHeader);
                        }
                        bytes.extend_from_slice(&data);
                        if bytes.contains(&b'\n') {
                            return decode_attach_header(&bytes).ok_or(SshError::AttachHeader);
                        }
                    }
                    ChannelMsg::Success | ChannelMsg::WindowAdjusted { .. } => {}
                    _ => return Err(SshError::AttachHeader),
                }
            }
            Err(SshError::AttachHeader)
        })
        .await
        .map_err(|_| SshError::Timeout)
        .and_then(std::convert::identity);
        let header = match result {
            Ok(header) => header,
            Err(error) => {
                let _ = writer.close().await;
                return Err(error);
            }
        };
        let (cursor, read_only, outcome) = match header {
            AttachHeader::Attached { from, mode } => (
                from,
                options.read_only || mode == AttachMode::ReadOnly,
                None,
            ),
            AttachHeader::Refused(error) => (0, true, Some(error.outcome())),
        };
        if outcome.is_some() {
            let _ = writer.close().await;
        }
        Ok(Self {
            reader,
            writer,
            timeout: session.timeout,
            closed: outcome.is_some(),
            header,
            cursor,
            read_only,
            outcome,
            pending: Vec::new(),
        })
    }

    /// True once the server closed the channel or the client closed it.
    pub fn is_closed(&self) -> bool {
        self.closed
    }

    pub const fn header(&self) -> AttachHeader {
        self.header
    }
    pub const fn cursor(&self) -> u64 {
        self.cursor
    }
    pub const fn read_only(&self) -> bool {
        self.read_only
    }
    pub const fn outcome(&self) -> Option<AttachOutcome> {
        self.outcome
    }

    /// Reads one bounded PTY data chunk. Empty means no data or channel close.
    pub async fn read(&mut self) -> Result<Vec<u8>, SshError> {
        match self.read_within(self.timeout).await? {
            PtyChunk::Data(bytes) => Ok(bytes),
            PtyChunk::Idle | PtyChunk::Closed => Ok(Vec::new()),
        }
    }

    /// @cc [owner:ghuntley,label:security;terminal] pty-read-within-distinguishes-close
    /// A bounded read MUST distinguish data, an elapsed wait with the channel
    /// still open, and channel close. Waiting MUST NOT exceed the session
    /// timeout, and an elapsed wait MUST NOT mark the channel closed.
    pub async fn read_within(&mut self, wait: Duration) -> Result<PtyChunk, SshError> {
        self.read_within_bounded(wait, MAX_OUTPUT).await
    }

    /// Reads at most `capacity` bytes while retaining any remainder for the
    /// next call. This is used by native bindings whose UI frame buffer is
    /// smaller than the transport maximum.
    pub async fn read_within_bounded(
        &mut self,
        wait: Duration,
        capacity: usize,
    ) -> Result<PtyChunk, SshError> {
        if capacity == 0 || capacity > MAX_OUTPUT {
            return Err(SshError::Bounds);
        }
        if !self.pending.is_empty() {
            let take = capacity.min(self.pending.len());
            let remainder = self.pending.split_off(take);
            let data = std::mem::replace(&mut self.pending, remainder);
            return Ok(PtyChunk::Data(data));
        }
        if self.closed {
            return Ok(PtyChunk::Closed);
        }
        let wait = wait.min(self.timeout);
        let Ok(message) = tokio::time::timeout(wait, self.reader.wait()).await else {
            return Ok(PtyChunk::Idle);
        };
        match message {
            Some(ChannelMsg::Data { data }) if data.len() <= MAX_OUTPUT => {
                let frame_bytes = u64::try_from(data.len()).map_err(|_| SshError::Bounds)?;
                let next = self
                    .cursor
                    .checked_add(frame_bytes)
                    .filter(|value| *value <= MAX_TERMINAL_CURSOR);
                let Some(next) = next else {
                    self.finish(AttachOutcome::Invalid).await;
                    return Err(SshError::Bounds);
                };
                self.cursor = next;
                let mut data = data.to_vec();
                if data.len() > capacity {
                    self.pending = data.split_off(capacity);
                }
                Ok(PtyChunk::Data(data))
            }
            Some(ChannelMsg::Data { .. }) => {
                self.finish(AttachOutcome::Invalid).await;
                Err(SshError::Bounds)
            }
            Some(ChannelMsg::ExitStatus { exit_status }) => {
                let status = i32::try_from(exit_status).ok();
                self.finish(AttachOutcome::from_status(status)).await;
                Ok(PtyChunk::Closed)
            }
            Some(ChannelMsg::Close) | None => {
                self.finish(AttachOutcome::Transport).await;
                Ok(PtyChunk::Closed)
            }
            Some(ChannelMsg::Failure | ChannelMsg::ExitSignal { .. }) => {
                self.finish(AttachOutcome::Transport).await;
                Err(SshError::Authentication)
            }
            Some(ChannelMsg::ExtendedData { .. }) => {
                self.finish(AttachOutcome::Invalid).await;
                Err(SshError::AttachHeader)
            }
            Some(_) => Ok(PtyChunk::Idle),
        }
    }

    pub async fn write(&mut self, input: &[u8]) -> Result<(), SshError> {
        if self.closed || input.len() > MAX_INPUT {
            return Err(SshError::Bounds);
        }
        if self.read_only {
            return Err(SshError::ReadOnly);
        }
        tokio::time::timeout(self.timeout, self.writer.data(input))
            .await
            .map_err(|_| SshError::Timeout)??;
        Ok(())
    }

    pub async fn resize(&mut self, columns: u32, rows: u32) -> Result<(), SshError> {
        if self.closed || !(1..=4096).contains(&columns) || !(1..=512).contains(&rows) {
            return Err(SshError::Bounds);
        }
        if self.read_only {
            return Err(SshError::ReadOnly);
        }
        tokio::time::timeout(self.timeout, self.writer.window_change(columns, rows, 0, 0))
            .await
            .map_err(|_| SshError::Timeout)??;
        Ok(())
    }

    pub async fn close(&mut self) -> Result<(), SshError> {
        if !self.closed {
            self.closed = true;
            self.outcome = Some(AttachOutcome::Closed);
            tokio::time::timeout(self.timeout, self.writer.close())
                .await
                .map_err(|_| SshError::Timeout)??;
        }
        Ok(())
    }

    async fn finish(&mut self, outcome: AttachOutcome) {
        self.closed = true;
        self.outcome = Some(outcome);
        let _ = self.writer.close().await;
    }
}
