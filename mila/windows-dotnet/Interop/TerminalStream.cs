using System.Text;

namespace Mila.Windows.Interop;

/// <summary>Native PTY operations; production calls the Rust session ABI.</summary>
internal interface IMilaTerminalTransport
{
    /// <summary>Opens or rejoins the caller's named server terminal session (`terminal new`).</summary>
    MilaNativeTerminalOpen Open(ulong sessionHandle, Guid machineId);
    (MilaNativeStatus Status, ulong? Handle) Attach(ulong sessionHandle, Guid machineId, string terminalId, ushort columns, ushort rows);
    MilaNativeTerminalRead Read(ulong terminalHandle);
    MilaNativeTerminalStateResult State(ulong terminalHandle);
    MilaTerminalFrame? Screen(ulong terminalHandle) => null;
    (MilaNativeStatus Status, ulong? Handle) AttachWithOptions(ulong sessionHandle, Guid machineId, string terminalId, ushort columns, ushort rows, bool readOnly)
        => Attach(sessionHandle, machineId, terminalId, columns, rows);
    MilaNativeStatus Kill(ulong terminalHandle);
    /// <summary>Closes the named server terminal session (`terminal kill`); true when the server reports it closed.</summary>
    bool End(ulong sessionHandle, Guid machineId, string terminalId);
}

internal sealed class MilaRustTerminalTransport : IMilaTerminalTransport
{
    internal static readonly MilaRustTerminalTransport Instance = new();
    public MilaNativeTerminalOpen Open(ulong sessionHandle, Guid machineId)
        => RustNative.TrySessionTerminalNew(sessionHandle, machineId, "porsche-" + Guid.NewGuid().ToString("N"));
    public (MilaNativeStatus Status, ulong? Handle) Attach(
        ulong sessionHandle, Guid machineId, string terminalId, ushort columns, ushort rows)
        => RustNative.TrySessionTerminalAttachSession(sessionHandle, machineId, terminalId, columns, rows);
    public MilaNativeTerminalRead Read(ulong terminalHandle) => RustNative.TrySessionTerminalRead(terminalHandle);
    public MilaNativeTerminalStateResult State(ulong terminalHandle) => RustNative.TrySessionTerminalState(terminalHandle);
    public MilaTerminalFrame? Screen(ulong terminalHandle) => RustNative.TrySessionTerminalFrame(terminalHandle);
    public (MilaNativeStatus Status, ulong? Handle) AttachWithOptions(ulong sessionHandle, Guid machineId, string terminalId, ushort columns, ushort rows, bool readOnly)
        => RustNative.TrySessionTerminalAttachSession(sessionHandle, machineId, terminalId, columns, rows, readOnly);
    public MilaNativeStatus Kill(ulong terminalHandle) => RustNative.TrySessionTerminalKill(terminalHandle);
    public bool End(ulong sessionHandle, Guid machineId, string terminalId)
    {
        MilaNativeSessionBytesResult ended = RustNative.TrySessionTerminalEnd(
            sessionHandle, machineId, terminalId, "porsche-" + Guid.NewGuid().ToString("N"));
        try { return ended.Succeeded && ended.Data is { } bytes && MilaSessionReads.TerminalClosed(bytes, terminalId); }
        catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { return false; }
    }
}

internal enum MilaTerminalPoll
{
    /// <summary>Output was appended to the current generation.</summary>
    Output,
    /// <summary>The PTY is open but produced nothing.</summary>
    Idle,
    /// <summary>A lost transport was replaced by a fresh attach generation.</summary>
    Reconnected,
    /// <summary>The transport is lost and a reattach failed; another poll retries.</summary>
    Reconnecting,
    /// <summary>The PTY closed cleanly, or its handle was revoked; no reconnect.</summary>
    Ended,
    /// <summary>Reconnect attempts are exhausted.</summary>
    Exhausted,
    /// <summary>No authenticated session remains; reconnect is refused.</summary>
    SignedOut,
    /// <summary>Nothing is attached (killed, ended or never attached).</summary>
    Detached,
}

/// <summary>
/// Generation-fenced terminal stream over the authenticated Rust session with
/// bounded reconnect after transport loss.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:reliability;security] mila-windows-terminal-reconnect
/// An established PTY's lost transport MUST NOT be confused with idle or
/// clean EOF: only a validated transport outcome reconnects, a clean close or
/// revoked handle ends the stream, and kill or sign-out MUST prevent any further attach. Each reattach
/// MUST use the live authenticated session handle, start a new generation that
/// discards prior output (replay reset) and refuses frames of older generations,
/// and the attempt count MUST be bounded and reset only by received output.
/// Every attach names a server terminal session obtained from `terminal new`;
/// reconnect rejoins the same named session and opens a new one only when the
/// session attach is refused rather than lost.
/// </remarks>
internal sealed class MilaTerminalStream
{
    internal const int DefaultMaxReconnects = 3;
    private readonly IMilaTerminalTransport _transport;
    private readonly Func<ulong?> _sessionHandle;
    private readonly int _maxReconnects;
    private readonly object _gate = new();
    private readonly Decoder _decoder = new UTF8Encoding(false, false).GetDecoder();
    private readonly HashSet<ulong> _reading = [];
    private readonly HashSet<ulong> _retired = [];
    private long _generation;
    private ulong _boundSession;
    private int _attempts;
    private bool _readWrite;
    private ushort _columns = 80;
    private ushort _rows = 24;
    private Guid _machine;
    private string? _terminalId;
    private readonly Dictionary<Guid, string> _rejoin = [];

    internal MilaTerminalStream(IMilaTerminalTransport transport, Func<ulong?> sessionHandle, int maxReconnects = DefaultMaxReconnects)
    {
        _transport = transport;
        _sessionHandle = sessionHandle;
        _maxReconnects = Math.Max(0, maxReconnects);
    }

    internal MilaTerminalSession Session { get; } = new();
    internal long Generation { get { lock (_gate) return _generation; } }
    internal int ReconnectAttempts { get { lock (_gate) return _attempts; } }
    internal string? TerminalId { get { lock (_gate) return _terminalId; } }

    internal bool Attach(Guid machineId, bool readWrite, ushort columns, ushort rows) =>
        AttachNamed(machineId, null, readWrite, columns, rows, out _);

    internal bool AttachSession(Guid machineId, string terminalId, bool readWrite, ushort columns, ushort rows) =>
        !string.IsNullOrEmpty(terminalId) && AttachNamed(machineId, terminalId, readWrite, columns, rows, out _);

    /// <summary>Rejoins a saved session only on its original authenticated parent.</summary>
    internal bool Open(Guid machineId, bool readWrite, ushort columns, ushort rows)
    {
        string? saved;
        ulong? parent;
        lock (_gate)
        {
            parent = _sessionHandle();
            if (parent is not > 0) return false;
            saved = parent == _boundSession && _rejoin.TryGetValue(machineId, out string? name) ? name : null;
        }
        if (saved is null) return AttachNamed(machineId, null, readWrite, columns, rows, out _, expectedSession: parent);
        if (AttachNamed(machineId, saved, readWrite, columns, rows, out long generation, expectedSession: parent)) return true;
        lock (_gate)
        {
            if (_generation != generation || _terminalId is not null || _sessionHandle() != parent) return false;
        }
        return AttachNamed(machineId, null, readWrite, columns, rows, out _, generation, parent);
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security;reliability] windows-terminal-reserved-generation
    /// Attach MUST reserve its generation before opening a server session or PTY.
    /// Kill, sign-out, replacement attach or parent-session replacement MUST fence
    /// late completion; a successful obsolete PTY MUST be closed without changing
    /// the current terminal, output, session name or reconnect state.
    /// </summary>
    private bool AttachNamed(Guid machineId, string? terminalId, bool readWrite, ushort columns, ushort rows,
        out long generation, long? expectedGeneration = null, ulong? expectedSession = null)
    {
        ulong previous;
        lock (_gate)
        {
            generation = _generation;
            ulong? parent = _sessionHandle();
            if (machineId == Guid.Empty || columns is 0 or > 4096 || rows is 0 or > 512 ||
                parent is not > 0 || (expectedGeneration is { } expected && expected != _generation) ||
                (expectedSession is { } expectedParent && parent != expectedParent)) return false;
            previous = TakeNative();
            if (_boundSession != parent.Value) _rejoin.Clear();
            _boundSession = parent.Value;
            _terminalId = terminalId;
            _machine = machineId;
            _attempts = 0;
            _readWrite = readWrite;
            _columns = columns;
            _rows = rows;
            generation = checked(++_generation);
            _decoder.Reset();
            Session.BeginAuthenticatedAttach(_boundSession, generation, _readWrite);
        }
        Close(previous);
        return AttachGeneration(generation);
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security;reliability] windows-terminal-read-handoff
    /// At most one native read/state/frame operation may own a terminal handle. A
    /// handle retired during that bounded operation MUST close once in its
    /// finally path, after the operation releases the native handle lock.
    /// </summary>
    internal MilaTerminalPoll Poll()
    {
        ulong terminal;
        long generation;
        bool reconnect;
        lock (_gate)
        {
            generation = _generation;
            terminal = Session.NativeTerminalHandle;
            reconnect = Session.State == MilaTerminalState.Reconnecting;
            if (!reconnect && (terminal == 0 || !Session.Reconnect(generation))) return MilaTerminalPoll.Detached;
            if (!reconnect && !_reading.Add(terminal)) return MilaTerminalPoll.Idle;
        }
        if (reconnect) return TryReattach(generation);
        try
        {
            if (!CurrentParent(generation)) return MilaTerminalPoll.SignedOut;
            return PollRead(generation, terminal);
        }
        finally
        {
            bool close;
            lock (_gate)
            {
                _reading.Remove(terminal);
                close = _retired.Remove(terminal);
            }
            if (close) _transport.Kill(terminal);
        }
    }

    private MilaTerminalPoll PollRead(long generation, ulong terminal)
    {
        MilaNativeTerminalRead read = _transport.Read(terminal);
        if (!CurrentParent(generation)) return MilaTerminalPoll.Detached;
        bool lost = read.Status == MilaNativeStatus.Transport;
        bool ended = read.Status == MilaNativeStatus.InvalidHandle ||
            (read.Succeeded && read.Event == MilaTerminalReadEvent.Closed);
        MilaTerminalOutcome? outcome = null;
        if (read.Succeeded && read.Event == MilaTerminalReadEvent.Closed)
        {
            MilaNativeTerminalStateResult state = _transport.State(terminal);
            if (!CurrentParent(generation)) return MilaTerminalPoll.Detached;
            if (state.Status == MilaNativeStatus.Busy) return MilaTerminalPoll.Idle;
            if (state.Succeeded && state.State is { Closed: true } closed)
            {
                outcome = closed.Outcome;
                lost = outcome == MilaTerminalOutcome.Transport;
                ended = !lost;
            }
        }
        lock (_gate)
        {
            if (!Current(generation, terminal)) return MilaTerminalPoll.Detached;
            if (lost || ended)
            {
                Session.ClearNativeTerminal();
                if (outcome == MilaTerminalOutcome.Authority) SignOutLocked();
                else
                {
                    if (outcome == MilaTerminalOutcome.Refused) ForgetTerminal();
                    if (lost) Session.BeginReconnect(generation); else Session.ReceiveEof(generation);
                }
            }
        }
        if (lost || ended)
        {
            Close(terminal);
            if (outcome == MilaTerminalOutcome.Authority) return MilaTerminalPoll.SignedOut;
            return lost ? TryReattach(generation) : MilaTerminalPoll.Ended;
        }
        if (!read.Succeeded || read.Event == MilaTerminalReadEvent.Idle || read.Data is not { Length: > 0 } bytes)
            return MilaTerminalPoll.Idle;
        MilaTerminalFrame? frame = _transport.Screen(terminal);
        if (!CurrentParent(generation)) return MilaTerminalPoll.Detached;
        lock (_gate)
        {
            if (!Current(generation, terminal)) return MilaTerminalPoll.Detached;
            if (frame is not null)
            {
                if (!Session.ApplyFrame(generation, frame)) return MilaTerminalPoll.Idle;
            }
            else
            {
                if (_transport is MilaRustTerminalTransport) return MilaTerminalPoll.Idle;
                char[] text = new char[_decoder.GetCharCount(bytes, flush: false)];
                _decoder.GetChars(bytes, text, flush: false);
                if (!Session.AppendReceived(generation, text)) return MilaTerminalPoll.Idle;
            }
            _attempts = 0;
            return MilaTerminalPoll.Output;
        }
    }

    internal void Kill()
    {
        ulong terminal;
        lock (_gate)
        {
            terminal = TakeNative();
            Session.Kill(_generation);
            _generation = checked(_generation + 1);
        }
        Close(terminal);
    }

    internal bool End()
    {
        string? terminalId;
        Guid machine;
        ulong parent;
        ulong terminal;
        lock (_gate)
        {
            terminalId = _terminalId;
            machine = _machine;
            parent = _boundSession;
            terminal = TakeNative();
            Session.Kill(_generation);
            _generation = checked(_generation + 1);
            _terminalId = null;
            _rejoin.Remove(machine);
        }
        Close(terminal);
        return terminalId is not null && machine != Guid.Empty && parent != 0 && _sessionHandle() == parent &&
            _transport.End(parent, machine, terminalId);
    }

    internal void SignOut()
    {
        ulong terminal;
        lock (_gate) terminal = SignOutLocked();
        Close(terminal);
    }

    private ulong SignOutLocked()
    {
        ulong terminal = TakeNative();
        _rejoin.Clear();
        _terminalId = null;
        _boundSession = 0;
        _decoder.Reset();
        Session.SignOut();
        _generation = checked(_generation + 1);
        return terminal;
    }

    private bool CurrentParent(long generation)
    {
        ulong close = 0;
        bool current;
        lock (_gate)
        {
            current = generation == _generation && _boundSession != 0 && _sessionHandle() == _boundSession;
            if (!current && generation == _generation) close = SignOutLocked();
        }
        Close(close);
        return current;
    }

    private bool Current(long generation, ulong terminal) =>
        generation == _generation && _boundSession != 0 && _sessionHandle() == _boundSession &&
        Session.NativeTerminalHandle == terminal;

    private MilaTerminalPoll TryReattach(long expectedGeneration)
    {
        if (!CurrentParent(expectedGeneration)) return MilaTerminalPoll.SignedOut;
        long generation;
        lock (_gate)
        {
            if (_generation != expectedGeneration || Session.State != MilaTerminalState.Reconnecting) return MilaTerminalPoll.Detached;
            if (_attempts >= _maxReconnects)
            {
                Session.ReceiveEof(_generation);
                return MilaTerminalPoll.Exhausted;
            }
            _attempts++;
            generation = checked(++_generation);
            _decoder.Reset();
            Session.BeginAuthenticatedAttach(_boundSession, generation, _readWrite);
        }
        if (AttachGeneration(generation)) return MilaTerminalPoll.Reconnected;
        lock (_gate)
        {
            if (Session.State == MilaTerminalState.SignedOut) return MilaTerminalPoll.SignedOut;
            if (_generation != generation) return MilaTerminalPoll.Detached;
            return Session.State == MilaTerminalState.Reconnecting ? MilaTerminalPoll.Reconnecting : MilaTerminalPoll.Ended;
        }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security;reliability] windows-terminal-native-attach-outcome
    /// A successful native attach handle MUST remain unpublished until its
    /// validated state confirms an open PTY. Only an authenticated refused
    /// outcome may discard its session name and permit terminal new; transport
    /// loss retries that same name, authority loss stops automatic attach, and
    /// malformed state or generic InvalidRequest MUST NOT imply refusal.
    /// </summary>
    private bool AttachGeneration(long generation)
    {
        if (!CurrentParent(generation)) return false;
        ulong parent;
        Guid machine;
        string? terminalId;
        bool readOnly;
        ushort columns;
        ushort rows;
        lock (_gate)
        {
            if (_generation != generation || _sessionHandle() != _boundSession) return false;
            parent = _boundSession;
            machine = _machine;
            terminalId = _terminalId;
            readOnly = !_readWrite;
            columns = _columns;
            rows = _rows;
        }
        if (terminalId is null)
        {
            MilaNativeTerminalOpen opened = _transport.Open(parent, machine);
            if (!CurrentParent(generation)) return false;
            lock (_gate)
            {
                if (_generation != generation || _sessionHandle() != parent) return false;
                if (!opened.Succeeded)
                {
                    // An uncertain terminal-new mutation must not be issued again by a reconnect poll.
                    Session.ReceiveEof(generation);
                    return false;
                }
                terminalId = opened.SessionId;
                _terminalId = terminalId;
                _rejoin[machine] = terminalId!;
            }
        }
        (MilaNativeStatus status, ulong? terminal) = _transport.AttachWithOptions(parent, machine, terminalId!, columns, rows, readOnly);
        MilaNativeTerminalStateResult state = status == MilaNativeStatus.Ok && terminal is > 0
            ? _transport.State(terminal.Value) : new(status, null);
        if (!CurrentParent(generation))
        {
            if (terminal is > 0) Close(terminal.Value);
            return false;
        }
        bool accepted = false;
        lock (_gate)
        {
            if (_generation == generation && _sessionHandle() == parent && _boundSession == parent)
            {
                if (status == MilaNativeStatus.Ok && terminal is > 0)
                {
                    if (state.Succeeded && state.State is { Closed: false } attached)
                    {
                        Session.BeginAuthenticatedAttach(parent, generation, _readWrite && !attached.ReadOnly);
                        accepted = Session.SetNativeTerminal(terminal.Value);
                        if (accepted) _rejoin[machine] = terminalId!;
                    }
                    else if (state.Succeeded && state.State is { Closed: true } closed)
                    {
                        switch (closed.Outcome)
                        {
                            case MilaTerminalOutcome.Refused:
                                ForgetTerminal();
                                Session.BeginReconnect(generation);
                                break;
                            case MilaTerminalOutcome.Transport:
                                Session.BeginReconnect(generation);
                                break;
                            case MilaTerminalOutcome.Authority:
                                SignOutLocked();
                                break;
                            default:
                                Session.ReceiveEof(generation);
                                break;
                        }
                    }
                    else if (state.Status == MilaNativeStatus.Busy) Session.BeginReconnect(generation);
                    else Session.ReceiveEof(generation);
                }
                else
                {
                    // Only a validated native refusal establishes that a named session is gone.
                    if (status is MilaNativeStatus.Transport or MilaNativeStatus.Busy) Session.BeginReconnect(generation);
                    else Session.ReceiveEof(generation);
                }
            }
        }
        if (!accepted && terminal is > 0) Close(terminal.Value);
        return accepted;
    }

    private void ForgetTerminal()
    {
        _terminalId = null;
        _rejoin.Remove(_machine);
    }

    private ulong TakeNative()
    {
        ulong terminal = Session.NativeTerminalHandle;
        Session.ClearNativeTerminal();
        return terminal;
    }

    private void Close(ulong terminal)
    {
        if (terminal == 0) return;
        lock (_gate)
        {
            // Native close may report Busy while a bounded read owns its handle.
            // The admitted read releases and closes a retired handle in finally.
            if (_reading.Contains(terminal)) { _retired.Add(terminal); return; }
        }
        _transport.Kill(terminal);
    }
}
