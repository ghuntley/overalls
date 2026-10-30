//! Bounded text renderer for the Linux terminal presentation surface.
//!
//! PTY transport remains owned by the authenticated runtime. This renderer only
//! receives already decoded text, keeps a bounded viewport, and never exposes
//! terminal bytes to GTK or logs.

const MAX_RENDERED_CHARS: usize = 64 * 1024;
const MAX_CHUNK_CHARS: usize = 16 * 1024;
const MAX_COLUMNS: u16 = 512;
const MAX_ROWS: u16 = 512;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RenderError {
    InvalidDimensions,
    ChunkTooLarge,
    UnsupportedControl,
}

/// A bounded terminal viewport suitable for a GTK text surface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalRenderer {
    columns: u16,
    rows: u16,
    lines: Vec<String>,
    cursor_column: usize,
    rendered_chars: usize,
}

impl TerminalRenderer {
    pub fn new(columns: u16, rows: u16) -> Result<Self, RenderError> {
        if !(1..=MAX_COLUMNS).contains(&columns) || !(1..=MAX_ROWS).contains(&rows) {
            return Err(RenderError::InvalidDimensions);
        }
        Ok(Self {
            columns,
            rows,
            lines: vec![String::new()],
            cursor_column: 0,
            rendered_chars: 0,
        })
    }

    pub const fn columns(&self) -> u16 {
        self.columns
    }

    pub const fn rows(&self) -> u16 {
        self.rows
    }

    pub fn lines(&self) -> &[String] {
        &self.lines
    }

    pub const fn cursor_column(&self) -> usize {
        self.cursor_column
    }

    /// Appends decoded display text while preserving a bounded viewport.
    /// Newline, carriage return, tab and backspace are handled locally;
    /// all other control characters are rejected before they reach GTK.
    pub fn append_text(&mut self, text: &str) -> Result<(), RenderError> {
        if text.chars().count() > MAX_CHUNK_CHARS {
            return Err(RenderError::ChunkTooLarge);
        }
        let mut next = self.clone();
        next.append_text_inner(text)?;
        *self = next;
        Ok(())
    }

    /// Appends text of any length as consecutive bounded chunks. The whole
    /// call is atomic: a rejected chunk leaves the viewport unchanged.
    pub fn append_stream(&mut self, text: &str) -> Result<(), RenderError> {
        let mut next = self.clone();
        let mut rest = text;
        while !rest.is_empty() {
            let split = rest
                .char_indices()
                .nth(MAX_CHUNK_CHARS)
                .map_or(rest.len(), |(offset, _)| offset);
            let (chunk, after) = rest.split_at(split);
            next.append_text(chunk)?;
            rest = after;
        }
        *self = next;
        Ok(())
    }

    fn append_text_inner(&mut self, text: &str) -> Result<(), RenderError> {
        for character in text.chars() {
            match character {
                '\n' => self.newline(),
                '\r' => self.cursor_column = 0,
                '\t' => {
                    let next = (self.cursor_column / 8 + 1) * 8;
                    self.cursor_column = next.min(self.columns as usize);
                }
                '\u{8}' => self.cursor_column = self.cursor_column.saturating_sub(1),
                character if character.is_control() => return Err(RenderError::UnsupportedControl),
                character => self.append_character(character),
            }
        }
        Ok(())
    }

    fn append_character(&mut self, character: char) {
        if self.rendered_chars >= MAX_RENDERED_CHARS {
            return;
        }
        if self.cursor_column >= self.columns as usize {
            self.newline();
        }
        let line = self.lines.last_mut().expect("renderer always has one line");
        let byte_offset = line
            .char_indices()
            .nth(self.cursor_column)
            .map_or(line.len(), |(offset, _)| offset);
        if self.cursor_column < line.chars().count() {
            let end = line
                .char_indices()
                .nth(self.cursor_column + 1)
                .map_or(line.len(), |(offset, _)| offset);
            line.replace_range(byte_offset..end, &character.to_string());
        } else {
            line.push(character);
        }
        self.cursor_column += 1;
        self.rendered_chars += 1;
    }

    fn newline(&mut self) {
        self.lines.push(String::new());
        self.cursor_column = 0;
        while self.lines.len() > self.rows as usize {
            let removed = self.lines.remove(0);
            self.rendered_chars = self.rendered_chars.saturating_sub(removed.chars().count());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RenderError, TerminalRenderer};

    #[test]
    fn renders_bounded_text_and_control_navigation() {
        let mut renderer = TerminalRenderer::new(8, 2).expect("dimensions");
        renderer.append_text("hello\nworld\rX").expect("text");
        assert_eq!(renderer.lines(), &["hello".to_owned(), "Xorld".to_owned()]);
        assert_eq!(renderer.cursor_column(), 1);
        renderer.append_text("\tZ").expect("tab");
        assert_eq!(renderer.lines(), &["Xorld".to_owned(), "Z".to_owned()]);
        assert_eq!(renderer.cursor_column(), 1);
    }

    #[test]
    fn rejects_unsafe_controls_and_unbounded_chunks() {
        let mut renderer = TerminalRenderer::new(80, 24).expect("dimensions");
        assert_eq!(
            renderer.append_text("bad\u{1b}[2J"),
            Err(RenderError::UnsupportedControl)
        );
        assert_eq!(
            renderer.append_text(&"x".repeat(16 * 1024 + 1)),
            Err(RenderError::ChunkTooLarge)
        );
        assert!(TerminalRenderer::new(0, 24).is_err());
    }
}

/// A transport request bound to one authenticated session authority.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PtyAttachRequest {
    /// The machine whose terminal session is attached.
    pub machine_id: String,
    /// A named terminal session; empty opens or rejoins the caller's own.
    pub session_id: String,
    pub from: u64,
    pub columns: u16,
    pub rows: u16,
    pub read_write: bool,
}

/// One bounded read from a host PTY. `Idle` means the channel is still open
/// and produced no displayable text; only `Eof` ends the stream.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PtyRead {
    Text(String),
    Idle,
    Eof,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PtyError {
    Unauthenticated,
    InvalidRequest,
    Transport,
    Render,
}

/// @cc [owner:ghuntley,label:security;terminal] linux-terminal-transport-authenticated
/// Attach and every subsequent operation MUST be bound to an authenticated
/// session generation; PTY bytes stay inside the host transport.
///
/// Host transport implemented by the authenticated runtime adapter.
/// Output is already decoded display text; PTY bytes never cross this seam.
pub trait PtyTransport {
    fn attach(&mut self, request: &PtyAttachRequest) -> Result<(), PtyError>;
    /// Binds the host channel opened by `attach` to the reducer generation.
    /// Implementations that do not need a host handle may retain the default.
    fn bind_generation(&mut self, _generation: u64) -> Result<(), PtyError> {
        Ok(())
    }
    fn read_output(&mut self, generation: u64) -> Result<PtyRead, PtyError>;
    /// Sends user input that the reducer has already bounded and permitted.
    fn send_input(&mut self, generation: u64, input: &[u8]) -> Result<(), PtyError>;
    fn resize(&mut self, generation: u64, columns: u16, rows: u16) -> Result<(), PtyError>;
    fn kill(&mut self, generation: u64) -> Result<(), PtyError>;
}

pub trait SessionAuthority {
    fn is_authenticated(&self) -> bool;
}

impl<A: SessionAuthority + ?Sized> SessionAuthority for &A {
    fn is_authenticated(&self) -> bool {
        (**self).is_authenticated()
    }
}

impl SessionAuthority for std::rc::Rc<std::cell::RefCell<crate::session::SessionBinding>> {
    fn is_authenticated(&self) -> bool {
        self.try_borrow()
            .is_ok_and(|binding| binding.is_authenticated())
    }
}

impl SessionAuthority for crate::session::SessionBinding {
    fn is_authenticated(&self) -> bool {
        self.is_authenticated()
    }
}

/// Couples the reducer and renderer to a current authenticated session.
pub struct AuthenticatedPty<A: SessionAuthority, T: PtyTransport> {
    authority: A,
    transport: T,
    stream: crate::adapter::TerminalStream,
    renderer: TerminalRenderer,
}

impl<A: SessionAuthority, T: PtyTransport> AuthenticatedPty<A, T> {
    pub fn new(authority: A, transport: T, columns: u16, rows: u16) -> Result<Self, RenderError> {
        Ok(Self {
            authority,
            transport,
            stream: crate::adapter::TerminalStream::new(),
            renderer: TerminalRenderer::new(columns, rows)?,
        })
    }

    pub fn attach(&mut self, request: PtyAttachRequest) -> Result<u64, PtyError> {
        if !self.authority.is_authenticated()
            || request.machine_id.is_empty()
            || request.machine_id.len() > 128
            || request.session_id.len() > 128
            || request
                .machine_id
                .bytes()
                .chain(request.session_id.bytes())
                .any(|byte| byte.is_ascii_whitespace() || byte == 0)
        {
            return Err(PtyError::Unauthenticated);
        }
        crate::adapter::validate_terminal_operation(crate::adapter::TerminalOperation::Attach {
            from: request.from,
            columns: request.columns,
            rows: request.rows,
            read_write: request.read_write,
        })
        .map_err(|_| PtyError::InvalidRequest)?;
        let generation = self.stream.attach().map_err(|_| PtyError::InvalidRequest)?;
        self.transport.attach(&request)?;
        self.transport.bind_generation(generation)?;
        self.stream
            .connected(generation, request.from, request.read_write)
            .map_err(|_| PtyError::InvalidRequest)?;
        Ok(generation)
    }

    /// Reads one chunk for the current generation. Output for any other
    /// generation, or after the stream ended, is refused before the renderer.
    pub fn read_output(&mut self, generation: u64) -> Result<PtyRead, PtyError> {
        if !self.authority.is_authenticated() {
            return Err(PtyError::Unauthenticated);
        }
        if !self.stream.state().accepts_output(generation) {
            return Err(PtyError::InvalidRequest);
        }
        match self.transport.read_output(generation)? {
            PtyRead::Eof => {
                // A clean host EOF is terminal state. Fence input and resize
                // immediately, even when the backend cannot perform a second
                // close after EOF.
                self.stream
                    .kill(generation)
                    .map_err(|_| PtyError::InvalidRequest)?;
                Ok(PtyRead::Eof)
            }
            PtyRead::Text(text) if text.is_empty() => Ok(PtyRead::Idle),
            PtyRead::Text(text) => {
                self.renderer
                    .append_stream(&text)
                    .map_err(|_| PtyError::Render)?;
                self.stream
                    .output(generation, text.chars().count())
                    .map_err(|_| PtyError::InvalidRequest)?;
                Ok(PtyRead::Text(text))
            }
            PtyRead::Idle => Ok(PtyRead::Idle),
        }
    }

    pub fn send_input(&mut self, generation: u64, input: &[u8]) -> Result<(), PtyError> {
        if !self.authority.is_authenticated() {
            return Err(PtyError::Unauthenticated);
        }
        if generation != self.stream.state().generation() {
            return Err(PtyError::InvalidRequest);
        }
        self.stream
            .validate_input(input.len())
            .map_err(|_| PtyError::InvalidRequest)?;
        self.transport.send_input(generation, input)
    }

    pub fn resize(&mut self, generation: u64, columns: u16, rows: u16) -> Result<(), PtyError> {
        if generation != self.stream.state().generation() {
            return Err(PtyError::InvalidRequest);
        }
        self.stream
            .validate_resize(columns, rows)
            .map_err(|_| PtyError::InvalidRequest)?;
        self.transport.resize(generation, columns, rows)
    }

    pub fn kill(&mut self, generation: u64) -> Result<(), PtyError> {
        self.transport.kill(generation)?;
        self.stream
            .kill(generation)
            .map_err(|_| PtyError::InvalidRequest)
    }

    pub fn renderer(&self) -> &TerminalRenderer {
        &self.renderer
    }

    /// Ends the current generation locally even when the host can no longer
    /// close its channel, so a stale channel can never accept input again.
    pub fn abandon(&mut self, generation: u64) {
        let _ = self.transport.kill(generation);
        let _ = self.stream.kill(generation);
    }

    /// Current reducer generation and phase, for presentation only.
    pub fn state(&self) -> &mila_runtime::TerminalAttach {
        self.stream.state()
    }

    pub fn transport_mut(&mut self) -> &mut T {
        &mut self.transport
    }
}

/// Operations supplied by the host's authenticated Porsche/PTY runtime.
/// The backend exposes decoded display text and lengths only; PTY bytes stay
/// inside the host transport and never enter GTK state.
pub trait HostPtyBackend {
    fn attach(&mut self, request: &PtyAttachRequest) -> Result<u64, PtyError>;
    fn read_output(&mut self, channel: u64) -> Result<PtyRead, PtyError>;
    fn send_input(&mut self, channel: u64, input: &[u8]) -> Result<(), PtyError>;
    fn resize(&mut self, channel: u64, columns: u16, rows: u16) -> Result<(), PtyError>;
    fn kill(&mut self, channel: u64) -> Result<(), PtyError>;
}

/// Porsche's authenticated PTY channel as exposed by the Linux host runtime.
///
/// The native presentation crate deliberately depends on this narrow client
/// contract rather than an SSH implementation.  Porsche owns credentials,
/// channel bytes, and reconnect policy; only decoded display text crosses the
/// boundary.  `PorschePtyBackend` adds the session binding that the generic
/// `HostPtyTransport` requires.
pub trait PorschePtyClient {
    fn open(&mut self, request: &PtyAttachRequest) -> Result<u64, PtyError>;
    fn output(&mut self, channel: u64) -> Result<PtyRead, PtyError>;
    fn input(&mut self, channel: u64, input: &[u8]) -> Result<(), PtyError>;
    fn dimensions(&mut self, channel: u64, columns: u16, rows: u16) -> Result<(), PtyError>;
    fn close(&mut self, channel: u64) -> Result<(), PtyError>;
}

/// @cc [owner:ghuntley,label:security;terminal] porsche-pty-session-binding
/// `open` MUST be called with the same authenticated session for the lifetime
/// of this backend; operations for another session are refused before client.
///
/// Concrete bridge from Porsche's host PTY client to the authenticated native
/// terminal transport.  A channel cannot be reused for a different session.
pub struct PorschePtyBackend<C> {
    client: C,
    session_id: Option<String>,
}

impl<C> PorschePtyBackend<C> {
    pub const fn new(client: C) -> Self {
        Self {
            client,
            session_id: None,
        }
    }

    pub fn client_mut(&mut self) -> &mut C {
        &mut self.client
    }
}

impl<C: PorschePtyClient> HostPtyBackend for PorschePtyBackend<C> {
    fn attach(&mut self, request: &PtyAttachRequest) -> Result<u64, PtyError> {
        if self
            .session_id
            .as_deref()
            .is_some_and(|id| id != request.session_id)
        {
            return Err(PtyError::Unauthenticated);
        }
        let channel = self.client.open(request)?;
        self.session_id = Some(request.session_id.clone());
        Ok(channel)
    }

    fn read_output(&mut self, channel: u64) -> Result<PtyRead, PtyError> {
        self.client.output(channel)
    }

    fn send_input(&mut self, channel: u64, input: &[u8]) -> Result<(), PtyError> {
        self.client.input(channel, input)
    }

    fn resize(&mut self, channel: u64, columns: u16, rows: u16) -> Result<(), PtyError> {
        self.client.dimensions(channel, columns, rows)
    }

    fn kill(&mut self, channel: u64) -> Result<(), PtyError> {
        self.client.close(channel)
    }
}

/// @cc [owner:ghuntley,label:security;terminal] linux-host-pty-binding
/// A host channel MUST be used only after `bind_generation`, and every
/// operation with a different generation MUST be refused before the backend.
///
/// Host-owned PTY transport that binds every operation to one session and
/// authenticated reducer generation. A runtime supplies the backend to keep
/// SSH credentials and raw PTY bytes outside the native presentation crate.
pub struct HostPtyTransport<B> {
    backend: B,
    session_id: Option<String>,
    pending_channel: Option<u64>,
    active: Option<(u64, u64)>,
}

impl<B> HostPtyTransport<B> {
    pub const fn new(backend: B) -> Self {
        Self {
            backend,
            session_id: None,
            pending_channel: None,
            active: None,
        }
    }

    pub fn backend_mut(&mut self) -> &mut B {
        &mut self.backend
    }

    fn channel_for(&self, generation: u64) -> Result<u64, PtyError> {
        self.active
            .filter(|(_, current)| *current == generation)
            .map(|(channel, _)| channel)
            .ok_or(PtyError::InvalidRequest)
    }
}

impl<B: HostPtyBackend> PtyTransport for HostPtyTransport<B> {
    fn attach(&mut self, request: &PtyAttachRequest) -> Result<(), PtyError> {
        if self.pending_channel.is_some() || self.active.is_some() {
            return Err(PtyError::Transport);
        }
        if self
            .session_id
            .as_deref()
            .is_some_and(|session| session != request.session_id)
        {
            return Err(PtyError::Unauthenticated);
        }
        let channel = self.backend.attach(request)?;
        self.session_id = Some(request.session_id.clone());
        self.pending_channel = Some(channel);
        Ok(())
    }

    fn bind_generation(&mut self, generation: u64) -> Result<(), PtyError> {
        let channel = self
            .pending_channel
            .take()
            .ok_or(PtyError::InvalidRequest)?;
        self.active = Some((channel, generation));
        Ok(())
    }

    fn read_output(&mut self, generation: u64) -> Result<PtyRead, PtyError> {
        let channel = self.channel_for(generation)?;
        let read = self.backend.read_output(channel)?;
        if read == PtyRead::Eof {
            // The backend channel is gone; a later attach may open a new one.
            self.active = None;
        }
        Ok(read)
    }

    fn send_input(&mut self, generation: u64, input: &[u8]) -> Result<(), PtyError> {
        let channel = self.channel_for(generation)?;
        self.backend.send_input(channel, input)
    }

    fn resize(&mut self, generation: u64, columns: u16, rows: u16) -> Result<(), PtyError> {
        let channel = self.channel_for(generation)?;
        self.backend.resize(channel, columns, rows)
    }

    fn kill(&mut self, generation: u64) -> Result<(), PtyError> {
        let channel = self.channel_for(generation)?;
        let result = self.backend.kill(channel);
        if result.is_ok() {
            self.active = None;
            self.pending_channel = None;
        }
        result
    }
}

#[cfg(test)]
mod transport_tests {
    use super::{
        AuthenticatedPty, HostPtyBackend, HostPtyTransport, PorschePtyBackend, PorschePtyClient,
        PtyAttachRequest, PtyError, PtyRead, PtyTransport, SessionAuthority,
    };

    struct Authority(bool);
    impl SessionAuthority for Authority {
        fn is_authenticated(&self) -> bool {
            self.0
        }
    }

    #[derive(Default)]
    struct FakeTransport {
        attached: bool,
        input: usize,
        killed: bool,
    }
    impl PtyTransport for FakeTransport {
        fn attach(&mut self, _: &PtyAttachRequest) -> Result<(), PtyError> {
            self.attached = true;
            Ok(())
        }
        fn read_output(&mut self, _: u64) -> Result<PtyRead, PtyError> {
            Ok(PtyRead::Text("ready".to_owned()))
        }
        fn send_input(&mut self, _: u64, input: &[u8]) -> Result<(), PtyError> {
            self.input = input.len();
            Ok(())
        }
        fn resize(&mut self, _: u64, _: u16, _: u16) -> Result<(), PtyError> {
            Ok(())
        }
        fn kill(&mut self, _: u64) -> Result<(), PtyError> {
            self.killed = true;
            Ok(())
        }
    }

    fn request() -> PtyAttachRequest {
        PtyAttachRequest {
            machine_id: "machine-1".to_owned(),
            session_id: "terminal-1".to_owned(),
            from: 0,
            columns: 80,
            rows: 24,
            read_write: true,
        }
    }

    #[test]
    fn authenticated_transport_binds_lifecycle_and_renderer() {
        let authority = Authority(true);
        let mut pty = AuthenticatedPty::new(&authority, FakeTransport::default(), 80, 24).unwrap();
        let generation = pty.attach(request()).unwrap();
        assert_eq!(
            pty.read_output(generation).unwrap(),
            PtyRead::Text("ready".to_owned())
        );
        pty.send_input(generation, b"ls\r\n").unwrap();
        pty.resize(generation, 100, 30).unwrap();
        pty.kill(generation).unwrap();
        assert_eq!(pty.renderer().lines()[0], "ready");
    }

    #[test]
    fn clean_eof_fences_subsequent_input() {
        struct EofTransport;
        impl PtyTransport for EofTransport {
            fn attach(&mut self, _: &PtyAttachRequest) -> Result<(), PtyError> {
                Ok(())
            }
            fn read_output(&mut self, _: u64) -> Result<PtyRead, PtyError> {
                Ok(PtyRead::Eof)
            }
            fn send_input(&mut self, _: u64, _: &[u8]) -> Result<(), PtyError> {
                Ok(())
            }
            fn resize(&mut self, _: u64, _: u16, _: u16) -> Result<(), PtyError> {
                Ok(())
            }
            fn kill(&mut self, _: u64) -> Result<(), PtyError> {
                Ok(())
            }
        }
        let authority = Authority(true);
        let mut pty = AuthenticatedPty::new(&authority, EofTransport, 80, 24).unwrap();
        let generation = pty.attach(request()).unwrap();
        assert_eq!(pty.read_output(generation).unwrap(), PtyRead::Eof);
        assert_eq!(
            pty.send_input(generation, b"x"),
            Err(PtyError::InvalidRequest)
        );
        assert_eq!(pty.read_output(generation), Err(PtyError::InvalidRequest));
    }

    #[test]
    fn authenticated_transport_rejects_invalid_input_and_resize_bounds() {
        let authority = Authority(true);
        let mut pty = AuthenticatedPty::new(&authority, FakeTransport::default(), 80, 24).unwrap();
        let generation = pty.attach(request()).unwrap();
        assert_eq!(pty.send_input(generation, b""), Ok(()));
        assert_eq!(
            pty.send_input(generation, &vec![b'x'; (1 << 20) + 1]),
            Err(PtyError::InvalidRequest)
        );
        assert_eq!(pty.resize(generation, 0, 24), Err(PtyError::InvalidRequest));
        assert_eq!(pty.resize(generation, 80, 0), Err(PtyError::InvalidRequest));
        assert_eq!(
            pty.resize(generation, u16::MAX, 24),
            Err(PtyError::InvalidRequest)
        );
    }

    #[test]
    fn authenticated_transport_reconnect_rejects_stale_generation() {
        let authority = Authority(true);
        let mut pty = AuthenticatedPty::new(&authority, FakeTransport::default(), 80, 24).unwrap();
        let first = pty.attach(request()).unwrap();
        pty.kill(first).unwrap();
        let second = pty.attach(request()).unwrap();
        assert_ne!(first, second);
        assert_eq!(pty.read_output(first), Err(PtyError::InvalidRequest));
        assert_eq!(pty.send_input(first, b"x"), Err(PtyError::InvalidRequest));
        assert_eq!(pty.resize(first, 80, 24), Err(PtyError::InvalidRequest));
        assert_eq!(
            pty.read_output(second).unwrap(),
            PtyRead::Text("ready".to_owned())
        );
    }

    #[test]
    fn unauthenticated_attach_never_calls_transport() {
        let authority = Authority(false);
        let mut pty = AuthenticatedPty::new(&authority, FakeTransport::default(), 80, 24).unwrap();
        assert_eq!(pty.attach(request()), Err(PtyError::Unauthenticated));
    }

    #[derive(Default)]
    struct HostBackend {
        calls: usize,
        killed: bool,
    }

    impl HostPtyBackend for HostBackend {
        fn attach(&mut self, _: &PtyAttachRequest) -> Result<u64, PtyError> {
            self.calls += 1;
            Ok(41)
        }

        fn read_output(&mut self, channel: u64) -> Result<PtyRead, PtyError> {
            self.calls += 1;
            (channel == 41)
                .then(|| PtyRead::Text("host-ready".to_owned()))
                .ok_or(PtyError::Transport)
        }

        fn send_input(&mut self, channel: u64, _: &[u8]) -> Result<(), PtyError> {
            self.calls += 1;
            (channel == 41).then_some(()).ok_or(PtyError::Transport)
        }

        fn resize(&mut self, channel: u64, _: u16, _: u16) -> Result<(), PtyError> {
            self.calls += 1;
            (channel == 41).then_some(()).ok_or(PtyError::Transport)
        }

        fn kill(&mut self, channel: u64) -> Result<(), PtyError> {
            self.calls += 1;
            if channel == 41 {
                self.killed = true;
                Ok(())
            } else {
                Err(PtyError::Transport)
            }
        }
    }

    #[test]
    fn host_transport_binds_channel_to_generation_and_session() {
        let authority = Authority(true);
        let mut pty = AuthenticatedPty::new(
            &authority,
            HostPtyTransport::new(HostBackend::default()),
            80,
            24,
        )
        .unwrap();
        let generation = pty.attach(request()).unwrap();
        assert_eq!(
            pty.read_output(generation).unwrap(),
            PtyRead::Text("host-ready".to_owned())
        );
        assert_eq!(
            pty.read_output(generation + 1),
            Err(PtyError::InvalidRequest)
        );
        pty.send_input(generation, b"date\r").unwrap();
        pty.resize(generation, 100, 30).unwrap();
        pty.kill(generation).unwrap();
        assert_eq!(pty.renderer().lines()[0], "host-ready");
        assert!(pty.transport.backend_mut().killed);
    }

    #[test]
    fn host_transport_refuses_second_channel_before_backend() {
        let mut transport = HostPtyTransport::new(HostBackend::default());
        let first = request();
        let second = PtyAttachRequest {
            session_id: "other-session".to_owned(),
            ..first.clone()
        };
        transport.attach(&first).unwrap();
        assert_eq!(transport.attach(&second), Err(PtyError::Transport));
        assert_eq!(transport.backend_mut().calls, 1);
    }

    #[derive(Default)]
    struct PorscheClient {
        opens: usize,
        closes: usize,
    }

    impl PorschePtyClient for PorscheClient {
        fn open(&mut self, _: &PtyAttachRequest) -> Result<u64, PtyError> {
            self.opens += 1;
            Ok(73)
        }
        fn output(&mut self, _: u64) -> Result<PtyRead, PtyError> {
            Ok(PtyRead::Text("porsche-ready".to_owned()))
        }
        fn input(&mut self, _: u64, _: &[u8]) -> Result<(), PtyError> {
            Ok(())
        }
        fn dimensions(&mut self, _: u64, _: u16, _: u16) -> Result<(), PtyError> {
            Ok(())
        }
        fn close(&mut self, _: u64) -> Result<(), PtyError> {
            self.closes += 1;
            Ok(())
        }
    }

    #[test]
    fn porsche_backend_binds_session_before_opening_second_channel() {
        let mut backend = PorschePtyBackend::new(PorscheClient::default());
        backend.attach(&request()).expect("first session");
        let other = PtyAttachRequest {
            session_id: "other".to_owned(),
            ..request()
        };
        assert_eq!(backend.attach(&other), Err(PtyError::Unauthenticated));
        assert_eq!(backend.client_mut().opens, 1);
        assert_eq!(
            backend.read_output(73).expect("output"),
            PtyRead::Text("porsche-ready".to_owned())
        );
        backend.kill(73).expect("close");
        assert_eq!(backend.client_mut().closes, 1);
    }
}
