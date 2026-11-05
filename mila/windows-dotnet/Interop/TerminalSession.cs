namespace Mila.Windows.Interop;

internal sealed class MilaTerminalSpan
{
    [System.Text.Json.Serialization.JsonPropertyName("text")] public required string Text { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("foreground")] public required uint? Foreground { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("background")] public required uint? Background { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("bold")] public required bool Bold { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("italic")] public required bool Italic { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("underline")] public required bool Underline { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("inverse")] public required bool Inverse { get; init; }
}

/// <summary>Validated opaque RGB pixels from the bounded Rust SIXEL projection.</summary>
internal sealed class MilaTerminalImage
{
    [System.Text.Json.Serialization.JsonPropertyName("x")] public required ushort X { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("y")] public required ushort Y { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("width")] public required ushort Width { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("height")] public required ushort Height { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("pixels")] public required List<uint> Pixels { get; init; }
}

/// <summary>Bounded display spans from Rust; raw terminal controls never reach WinUI.</summary>
internal sealed class MilaTerminalFrame
{
    [System.Text.Json.Serialization.JsonPropertyName("version")] public required byte Version { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("columns")] public required ushort Columns { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("rows")] public required ushort Rows { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("cursor_column")] public required ushort CursorColumn { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("cursor_row")] public required ushort CursorRow { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("lines")] public required List<List<MilaTerminalSpan>> Lines { get; init; }
    [System.Text.Json.Serialization.JsonPropertyName("images")] public required List<MilaTerminalImage> Images { get; init; }
    [System.Text.Json.Serialization.JsonIgnore] internal string Text => string.Join("\n", Lines.Select(line => string.Concat(line.Select(span => span.Text))));

    /// <summary>
    /// @cc [owner:ghuntley,label:security;terminal] windows-terminal-frame-bounds
    /// Decode only a 16 MiB projection containing at most 1,048,576 opaque RGB
    /// pixels in total. Null image entries, invalid extents and out-of-range
    /// colours MUST be refused before the frame reaches WinUI.
    /// </summary>
    internal static MilaTerminalFrame? Decode(byte[] bytes)
    {
        if (bytes.Length > 16 << 20) return null;
        try
        {
            MilaTerminalFrame? frame = System.Text.Json.JsonSerializer.Deserialize<MilaTerminalFrame>(bytes,
                new System.Text.Json.JsonSerializerOptions { UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow });
            if (frame is null || frame.Version != 1 || frame.Columns is 0 or > 4096 || frame.Rows is 0 or > 512 ||
                frame.CursorColumn >= frame.Columns || frame.CursorRow >= frame.Rows || frame.Lines is null || frame.Lines.Count > frame.Rows) return null;
            int count = 0;
            foreach (List<MilaTerminalSpan> line in frame.Lines)
            {
                if (line is null) return null;
                int columns = 0;
                foreach (MilaTerminalSpan span in line)
                {
                    if (span is null || span.Text is null || span.Text.Any(char.IsControl) || span.Foreground > 0xffffff || span.Background > 0xffffff) return null;
                    columns += span.Text.EnumerateRunes().Count();
                }
                if (columns > frame.Columns) return null;
                count += columns;
            }
            return count <= 16_384 && frame.Images is not null && frame.Images.Count <= 8 &&
                frame.Images.All(image => image is not null && image.Pixels is not null && image.Width > 0 && image.Height > 0 &&
                    image.Width <= 1024 && image.Height <= 1024 &&
                    image.Pixels.Count == (long)image.Width * image.Height && image.Pixels.Count <= 1_048_576 &&
                    image.Pixels.All(pixel => pixel <= 0xffffff)) &&
                frame.Images.Sum(image => image.Pixels.Count) <= 1_048_576 ? frame : null;
        }
        catch (System.Text.Json.JsonException) { return null; }
    }
}

/// <summary>Bounded, generation-fenced terminal lifecycle state.</summary>
internal sealed class MilaTerminalSession
{
    internal const int MaxOutputCharacters = 1_048_576;
    internal const int MaxInputBytes = 65_536;
    internal MilaTerminalState State { get; private set; } = MilaTerminalState.SignedOut;
    private long _generation;
    private ulong _sessionHandle;
    private ulong _terminalHandle;
    private bool _readWrite;
    private readonly System.Text.StringBuilder _output = new();

    internal string Output => _output.ToString();
    internal MilaTerminalFrame? Frame { get; private set; }
    internal long BeginAttach(long generation, bool readWrite)
    {
        _generation = generation;
        _readWrite = readWrite;
        _output.Clear();
        Frame = null;
        State = readWrite ? MilaTerminalState.Attaching : MilaTerminalState.ReadOnly;
        return generation;
    }

    /// Starts a stream only for a live authenticated Rust session. A zero
    /// handle is never accepted, and the generation fences late PTY frames.
    internal long BeginAuthenticatedAttach(ulong sessionHandle, long generation, bool readWrite)
    {
        if (sessionHandle == 0) return 0;
        _sessionHandle = sessionHandle;
        return BeginAttach(generation, readWrite);
    }
    internal bool SetNativeTerminal(ulong terminalHandle)
    {
        if (terminalHandle == 0 || _sessionHandle == 0 || State is MilaTerminalState.SignedOut or MilaTerminalState.Killed)
            return false;
        _terminalHandle = terminalHandle;
        return true;
    }
    internal ulong NativeTerminalHandle => _terminalHandle;

    /// Detaches the native handle after its owner has killed it, so sign-out
    /// does not close an already-closed handle a second time.
    internal void ClearNativeTerminal() => _terminalHandle = 0;

    /// Marks a lost transport for the current generation. Output and input stay
    /// refused until a fresh authenticated attach generation replaces it.
    internal bool BeginReconnect(long generation)
    {
        if (generation != _generation || State is not (MilaTerminalState.Attaching or MilaTerminalState.Live or MilaTerminalState.ReadOnly))
            return false;
        State = MilaTerminalState.Reconnecting;
        _terminalHandle = 0;
        return true;
    }
    internal bool Append(long generation, ReadOnlySpan<char> text)
    {
        if (generation != _generation || State is MilaTerminalState.SignedOut or MilaTerminalState.Killed or
            MilaTerminalState.Failed or MilaTerminalState.Reconnecting) return false;
        if (_output.Length + text.Length > MaxOutputCharacters) return false;
        _output.Append(text);
        State = MilaTerminalState.Live;
        return true;
    }

    /// Appends a renderer-safe projection received from the authenticated
    /// transport. The native boundary deliberately never passes terminal
    /// bytes into this class; callers must decode and sanitize in Rust first.
    internal bool AppendReceived(long generation, ReadOnlySpan<char> text) =>
        Append(generation, text);

    internal bool ApplyFrame(long generation, MilaTerminalFrame frame)
    {
        if (generation != _generation || State is not (MilaTerminalState.Attaching or MilaTerminalState.Live or MilaTerminalState.ReadOnly)) return false;
        Frame = frame;
        _output.Clear();
        _output.Append(frame.Text);
        State = _readWrite ? MilaTerminalState.Live : MilaTerminalState.ReadOnly;
        return true;
    }
    internal bool Resize(long generation, ushort columns, ushort rows)
    {
        if (generation != _generation || !_readWrite || columns is 0 or > 4096 || rows is 0 or > 512 ||
            State is not (MilaTerminalState.Attaching or MilaTerminalState.Live)) return false;
        State = MilaTerminalState.Live;
        return true;
    }
    internal bool SendInput(long generation, ReadOnlySpan<byte> input)
    {
        if (generation != _generation || !_readWrite || input.Length > MaxInputBytes || State is not MilaTerminalState.Live) return false;
        return true;
    }
    internal bool Reconnect(long generation) => generation == _generation &&
        State is (MilaTerminalState.Attaching or MilaTerminalState.Live or MilaTerminalState.ReadOnly);
    /// Marks the authenticated PTY closed by the transport. A clean EOF must
    /// invalidate reconnect and input until a fresh attach generation starts.
    internal bool ReceiveEof(long generation)
    {
        if (generation != _generation || State is MilaTerminalState.SignedOut or MilaTerminalState.Killed) return false;
        State = MilaTerminalState.Failed;
        return true;
    }
    internal void Kill(long generation) { if (generation == _generation) State = MilaTerminalState.Killed; }
    internal void SignOut()
    {
        if (_terminalHandle != 0) RustNative.TrySessionTerminalKill(_terminalHandle);
        _terminalHandle = 0;
        _sessionHandle = 0;
        _generation++; _readWrite = false; State = MilaTerminalState.SignedOut; _output.Clear(); Frame = null;
    }
}

internal enum MilaTerminalState { SignedOut, Attaching, ReadOnly, Live, Failed, Killed, Reconnecting }
