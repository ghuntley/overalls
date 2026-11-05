//! Identifier-only watch stream on the deployment's existing pinned connection.
use crate::{
    decode_watch_line,
    ssh::{SshError, SshSession},
    WatchEvent, WatchRequest, MAX_WATCH_LINE_BYTES,
};
use russh::{client, ChannelMsg};
use std::fmt::Write as FmtWrite;
use std::time::Duration;
use tokio::time::Instant;

/// Three missed 15-second Porsche heartbeats require reconnect and a full read.
pub const WATCH_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_BUFFER: usize = MAX_WATCH_LINE_BYTES * 2;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WatchRead {
    Event(WatchEvent),
    Idle,
    Closed,
    AuthorityLost,
    TransportLost,
}

/// Cancellation-safe bounded line framing; it owns no device signer or key.
struct WatchChannel {
    reader: russh::ChannelReadHalf,
    writer: russh::ChannelWriteHalf<client::Msg>,
    request: WatchRequest,
    pending: Vec<u8>,
    deadline: Instant,
    heartbeat_timeout: Duration,
    operation_timeout: Duration,
    watching: bool,
    session_id: Option<uuid::Uuid>,
    terminal: Option<WatchRead>,
}

impl WatchChannel {
    /// The configurable deadline also allows real-TCP heartbeat fault tests.
    /// Native clients use [`Self::open`] and the protocol's 45-second deadline.
    async fn open_with_heartbeat_timeout(
        session: &SshSession,
        request: WatchRequest,
        heartbeat_timeout: Duration,
    ) -> Result<Self, SshError> {
        let request =
            WatchRequest::new(request.machines, request.threads).map_err(|_| SshError::Bounds)?;
        if request.machines.len() + request.threads.len() > 16
            || heartbeat_timeout.is_zero()
            || heartbeat_timeout > WATCH_HEARTBEAT_TIMEOUT
        {
            return Err(SshError::Bounds);
        }
        let mut line = String::from("watch --json --session");
        for id in &request.machines {
            let _ = write!(line, " --machine={id}");
        }
        for id in &request.threads {
            let _ = write!(line, " --thread={id}");
        }
        let line = mila_protocol::Command::parse(&line)
            .and_then(|command| command.format())
            .map_err(|_| SshError::Bounds)?;
        let (reader, writer) = session.watch_channel().await?.split();
        let result = tokio::time::timeout(session.operation_timeout(), async {
            writer.exec(true, line.as_bytes()).await?;
            writer.eof().await?;
            Ok::<(), SshError>(())
        })
        .await
        .map_err(|_| SshError::Timeout)
        .and_then(std::convert::identity);
        if let Err(error) = result {
            let _ = tokio::time::timeout(session.operation_timeout(), writer.close()).await;
            return Err(error);
        }
        Ok(Self {
            reader,
            writer,
            request,
            pending: Vec::new(),
            deadline: Instant::now() + heartbeat_timeout,
            heartbeat_timeout,
            operation_timeout: session.operation_timeout(),
            watching: false,
            session_id: None,
            terminal: None,
        })
    }

    /// @cc [owner:ghuntley,label:security;recovery;protocol] mila-watch-live-framing
    /// Reads MUST preserve fragmented lines across cancellation, cap each line at
    /// 65536 bytes and buffered bytes at 131072, accept hints only after a matching
    /// subscription, and distinguish idle, authority loss and heartbeat/transport
    /// loss. Hints never grant authority. Error payloads never cross this boundary.
    async fn read_within(&mut self, wait: Duration) -> WatchRead {
        if let Some(terminal) = &self.terminal {
            return terminal.clone();
        }
        let until = Instant::now() + wait;
        loop {
            if let Some(index) = self.pending.iter().position(|byte| *byte == b'\n') {
                let mut line = self.pending.drain(..=index).collect::<Vec<_>>();
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                let next = self.decode(&line);
                if matches!(next, WatchRead::AuthorityLost | WatchRead::TransportLost) {
                    return self.finish(next).await;
                }
                return next;
            }
            if self.pending.len() > MAX_WATCH_LINE_BYTES {
                return self.finish(WatchRead::TransportLost).await;
            }
            let now = Instant::now();
            if now >= self.deadline {
                return self.finish(WatchRead::TransportLost).await;
            }
            let remaining = until
                .saturating_duration_since(now)
                .min(self.deadline - now);
            let message = match tokio::time::timeout(remaining, self.reader.wait()).await {
                Ok(message) => message,
                Err(_) if Instant::now() >= self.deadline => {
                    return self.finish(WatchRead::TransportLost).await
                }
                Err(_) => return WatchRead::Idle,
            };
            match message {
                Some(ChannelMsg::Data { data }) => {
                    if self.pending.len().saturating_add(data.len()) > MAX_BUFFER {
                        return self.finish(WatchRead::TransportLost).await;
                    }
                    self.pending.extend_from_slice(&data);
                }
                Some(ChannelMsg::ExitStatus { exit_status: 2 | 3 } | ChannelMsg::Failure) => {
                    return self.finish(WatchRead::AuthorityLost).await
                }
                Some(ChannelMsg::ExitStatus { exit_status: 0 } | ChannelMsg::Close) | None => {
                    return self.finish(WatchRead::Closed).await
                }
                Some(ChannelMsg::ExitStatus { .. }) => {
                    return self.finish(WatchRead::TransportLost).await
                }
                _ => {}
            }
            if Instant::now() >= until && self.pending.iter().all(|byte| *byte != b'\n') {
                return WatchRead::Idle;
            }
        }
    }

    fn decode(&mut self, line: &[u8]) -> WatchRead {
        if line.len() > MAX_WATCH_LINE_BYTES {
            return WatchRead::TransportLost;
        }
        // Porsche writes its ordinary error envelope immediately before exit.
        // Retain only the closed authority outcome, never the server body.
        if let Ok(value) = serde_json::from_slice::<serde_json::Value>(line) {
            if value.get("status").and_then(serde_json::Value::as_str) == Some("error") {
                return match value.get("error").and_then(serde_json::Value::as_str) {
                    Some("unauthorized" | "forbidden" | "not_found" | "approval_expired") => {
                        WatchRead::AuthorityLost
                    }
                    _ => WatchRead::TransportLost,
                };
            }
        }
        let Ok(event) = decode_watch_line(line) else {
            return WatchRead::TransportLost;
        };
        match &event {
            WatchEvent::Watching {
                machines,
                threads,
                session_id,
            } => {
                let Ok(actual) = WatchRequest::new(machines.clone(), threads.clone()) else {
                    return WatchRead::TransportLost;
                };
                if self
                    .session_id
                    .is_some_and(|expected| expected != *session_id)
                    || actual != self.request
                    || actual.machines.len() != machines.len()
                    || actual.threads.len() != threads.len()
                {
                    return WatchRead::TransportLost;
                }
                self.watching = true;
                self.session_id = Some(*session_id);
                self.deadline = Instant::now() + self.heartbeat_timeout;
            }
            WatchEvent::Heartbeat if self.watching => {
                self.deadline = Instant::now() + self.heartbeat_timeout;
            }
            WatchEvent::MachineChanged(id) | WatchEvent::TerminalSessionsChanged(id)
                if !self.watching || !self.request.machines.contains(id) =>
            {
                return WatchRead::TransportLost
            }
            WatchEvent::ThreadChanged(id)
                if !self.watching || !self.request.threads.contains(id) =>
            {
                return WatchRead::TransportLost
            }
            WatchEvent::Session { id, authenticated } => {
                if self.watching && !authenticated {
                    return WatchRead::AuthorityLost;
                }
                if self.session_id.is_some_and(|expected| expected != *id) {
                    return WatchRead::TransportLost;
                }
                self.session_id = Some(*id);
            }
            WatchEvent::SessionChanged(id) => {
                if self.session_id.is_some_and(|expected| expected != *id) {
                    return WatchRead::TransportLost;
                }
                self.session_id = Some(*id);
            }
            WatchEvent::Unknown => {}
            _ if !self.watching => return WatchRead::TransportLost,
            _ => {}
        }
        WatchRead::Event(event)
    }

    async fn finish(&mut self, state: WatchRead) -> WatchRead {
        self.terminal = Some(state.clone());
        self.pending.clear();
        // Queue a close if immediately available; caller waits must not grow
        // into the ordinary command timeout when the transport is stalled.
        let _ = tokio::time::timeout(Duration::ZERO, self.writer.close()).await;
        state
    }

    async fn close(&mut self) {
        let _ = self.finish(WatchRead::Closed).await;
        let _ = tokio::time::timeout(self.operation_timeout, self.writer.close()).await;
    }
}

/// A logical bounded subscription sharded into Porsche's 16-filter channels,
/// all on the deployment's one authenticated connection.
pub struct WatchSession {
    request: WatchRequest,
    channels: Vec<WatchChannel>,
    cursor: usize,
    terminal: Option<WatchRead>,
}
impl std::fmt::Debug for WatchSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WatchSession")
            .field("shards", &self.channels.len())
            .field("closed", &self.terminal.is_some())
            .finish_non_exhaustive()
    }
}
impl WatchSession {
    pub async fn open(session: &SshSession, request: WatchRequest) -> Result<Self, SshError> {
        Self::open_with_heartbeat_timeout(session, request, WATCH_HEARTBEAT_TIMEOUT).await
    }
    pub async fn open_with_heartbeat_timeout(
        session: &SshSession,
        request: WatchRequest,
        heartbeat_timeout: Duration,
    ) -> Result<Self, SshError> {
        let request =
            WatchRequest::new(request.machines, request.threads).map_err(|_| SshError::Bounds)?;
        let filters = request
            .machines
            .iter()
            .map(|id| (true, *id))
            .chain(request.threads.iter().map(|id| (false, *id)))
            .collect::<Vec<_>>();
        let mut channels: Vec<WatchChannel> = Vec::new();
        // Even an empty filter set watches session approval and revocation.
        for offset in (0..filters.len().max(1)).step_by(16) {
            let chunk = filters
                .get(offset..(offset + 16).min(filters.len()))
                .ok_or(SshError::Bounds)?;
            let machines = chunk
                .iter()
                .filter_map(|(machine, id)| machine.then_some(*id))
                .collect();
            let threads = chunk
                .iter()
                .filter_map(|(machine, id)| (!machine).then_some(*id))
                .collect();
            let shard = WatchRequest::new(machines, threads).map_err(|_| SshError::Bounds)?;
            match WatchChannel::open_with_heartbeat_timeout(session, shard, heartbeat_timeout).await
            {
                Ok(channel) => channels.push(channel),
                Err(error) => {
                    for channel in &mut channels {
                        channel.close().await;
                    }
                    return Err(error);
                }
            }
        }
        Ok(Self {
            request,
            channels,
            cursor: 0,
            terminal: None,
        })
    }
    pub fn request(&self) -> &WatchRequest {
        &self.request
    }

    /// @cc [owner:ghuntley,label:protocol;recovery] mila-watch-shards-fairness
    /// At most four 16-filter channels MUST share the existing connection.
    /// Reads MUST poll all shards fairly, and any lost authority or transport
    /// MUST terminate the logical subscription; reconnect requires a full read.
    pub async fn read_within(&mut self, wait: Duration) -> WatchRead {
        if let Some(terminal) = &self.terminal {
            return terminal.clone();
        }
        let until = Instant::now() + wait;
        loop {
            let count = self.channels.len();
            for _ in 0..count {
                let index = self.cursor;
                self.cursor = (self.cursor + 1) % count;
                let Some(channel) = self.channels.get_mut(index) else {
                    return self.finish(WatchRead::TransportLost).await;
                };
                match channel.read_within(Duration::ZERO).await {
                    WatchRead::Idle => {}
                    WatchRead::Event(event) => return WatchRead::Event(event),
                    terminal => return self.finish(terminal).await,
                }
            }
            let now = Instant::now();
            if now >= until {
                return WatchRead::Idle;
            }
            let Some(channel) = self.channels.get_mut(self.cursor) else {
                return self.finish(WatchRead::TransportLost).await;
            };
            let read = channel
                .read_within((until - now).min(Duration::from_millis(10)))
                .await;
            self.cursor = (self.cursor + 1) % count;
            match read {
                WatchRead::Idle => {}
                WatchRead::Event(event) => return WatchRead::Event(event),
                terminal => return self.finish(terminal).await,
            }
        }
    }
    async fn finish(&mut self, state: WatchRead) -> WatchRead {
        self.terminal = Some(state.clone());
        for channel in &mut self.channels {
            let _ = channel.finish(state.clone()).await;
        }
        state
    }
    pub async fn close(&mut self) {
        self.terminal = Some(WatchRead::Closed);
        for channel in &mut self.channels {
            channel.close().await;
        }
    }
}
