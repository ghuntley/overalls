using System.Text;

namespace Mila.Windows.Interop;

/// <summary>Native PTY operations; production calls the Rust session ABI.</summary>
internal interface IMilaTerminalTransport
{
    (MilaNativeStatus Status, ulong? Handle) Attach(ulong sessionHandle, ushort columns, ushort rows);
    MilaNativeTerminalRead Read(ulong terminalHandle);
    MilaNativeStatus Kill(ulong terminalHandle);
}

internal sealed class MilaRustTerminalTransport : IMilaTerminalTransport
{
    internal static readonly MilaRustTerminalTransport Instance = new();
    public (MilaNativeStatus Status, ulong? Handle) Attach(ulong sessionHandle, ushort columns, ushort rows)
        => RustNative.TrySessionTerminalAttach(sessionHandle, columns, rows);
    public MilaNativeTerminalRead Read(ulong terminalHandle) => RustNative.TrySessionTerminalRead(terminalHandle);
    public MilaNativeStatus Kill(ulong terminalHandle) => RustNative.TrySessionTerminalKill(terminalHandle);
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
/// A lost transport MUST NOT be confused with an idle or closed PTY: only a
/// transport failure reconnects, a clean close or revoked handle ends the
/// stream, and kill or sign-out MUST prevent any further attach. Each reattach
/// MUST use the live authenticated session handle, start a new generation that
/// discards prior output (replay reset) and refuses frames of older generations,
/// and the attempt count MUST be bounded and reset only by received output.
/// </remarks>
internal sealed class MilaTerminalStream
{
    internal const int DefaultMaxReconnects = 3;
    private readonly IMilaTerminalTransport _transport;
    private readonly Func<ulong?> _sessionHandle;
    private readonly int _maxReconnects;
    private readonly Decoder _decoder = new UTF8Encoding(false, false).GetDecoder();
    private long _generation;
    private int _attempts;
    private bool _readWrite;
    private ushort _columns = 80;
    private ushort _rows = 24;

    internal MilaTerminalStream(IMilaTerminalTransport transport, Func<ulong?> sessionHandle, int maxReconnects = DefaultMaxReconnects)
    {
        _transport = transport;
        _sessionHandle = sessionHandle;
        _maxReconnects = Math.Max(0, maxReconnects);
    }

    internal MilaTerminalSession Session { get; } = new();
    internal long Generation => _generation;
    internal int ReconnectAttempts => _attempts;

    /// <summary>Attaches a fresh stream; any previous PTY is killed first.</summary>
    internal bool Attach(bool readWrite, ushort columns, ushort rows)
    {
        KillNative();
        Session.Kill(_generation);
        _attempts = 0;
        _readWrite = readWrite;
        _columns = columns;
        _rows = rows;
        return AttachGeneration();
    }

    internal MilaTerminalPoll Poll()
    {
        ulong terminal = Session.NativeTerminalHandle;
        if (Session.State == MilaTerminalState.Reconnecting) return TryReattach();
        if (terminal == 0 || !Session.Reconnect(_generation)) return MilaTerminalPoll.Detached;
        MilaNativeTerminalRead read = _transport.Read(terminal);
        if (read.Status == MilaNativeStatus.Transport)
        {
            KillNative();
            Session.BeginReconnect(_generation);
            return TryReattach();
        }
        if (read.Status == MilaNativeStatus.InvalidHandle || (read.Succeeded && read.Event == MilaTerminalReadEvent.Closed))
        {
            Session.ClearNativeTerminal();
            Session.ReceiveEof(_generation);
            return MilaTerminalPoll.Ended;
        }
        if (!read.Succeeded || read.Event == MilaTerminalReadEvent.Idle || read.Data is not { Length: > 0 } bytes)
            return MilaTerminalPoll.Idle;
        char[] text = new char[_decoder.GetCharCount(bytes, flush: false)];
        _decoder.GetChars(bytes, text, flush: false);
        if (!Session.AppendReceived(_generation, text)) return MilaTerminalPoll.Idle;
        _attempts = 0;
        return MilaTerminalPoll.Output;
    }

    internal void Kill()
    {
        KillNative();
        Session.Kill(_generation);
    }

    internal void SignOut()
    {
        KillNative();
        Session.SignOut();
        _generation = checked(_generation + 1);
    }

    private MilaTerminalPoll TryReattach()
    {
        if (_sessionHandle() is not { } handle || handle == 0)
        {
            SignOut();
            return MilaTerminalPoll.SignedOut;
        }
        if (_attempts >= _maxReconnects)
        {
            Session.ReceiveEof(_generation);
            return MilaTerminalPoll.Exhausted;
        }
        _attempts++;
        return AttachGeneration() ? MilaTerminalPoll.Reconnected : MilaTerminalPoll.Reconnecting;
    }

    private bool AttachGeneration()
    {
        if (_sessionHandle() is not { } handle || handle == 0) return false;
        long generation = checked(_generation + 1);
        (MilaNativeStatus status, ulong? terminal) = _transport.Attach(handle, _columns, _rows);
        if (status != MilaNativeStatus.Ok || terminal is not > 0)
        {
            // Keep the reconnecting state so a later poll retries within the bound.
            if (Session.State != MilaTerminalState.Reconnecting) Session.BeginReconnect(_generation);
            return false;
        }
        _generation = generation;
        _decoder.Reset();
        if (Session.BeginAuthenticatedAttach(handle, generation, _readWrite) == 0 || !Session.SetNativeTerminal(terminal.Value))
        {
            _transport.Kill(terminal.Value);
            return false;
        }
        return true;
    }

    private void KillNative()
    {
        ulong terminal = Session.NativeTerminalHandle;
        Session.ClearNativeTerminal();
        if (terminal != 0) _transport.Kill(terminal);
    }
}
