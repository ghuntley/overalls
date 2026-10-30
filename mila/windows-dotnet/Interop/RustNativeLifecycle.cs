using System.Runtime.InteropServices;
using System.Text;

namespace Mila.Windows.Interop;

/// <summary>Classification returned beside one bounded terminal read.</summary>
internal enum MilaTerminalReadEvent : byte
{
    /// <summary>PTY output was copied.</summary>
    Data = 0,
    /// <summary>No output within the session timeout; the channel is still open.</summary>
    Idle = 1,
    /// <summary>The channel closed; no further output will arrive.</summary>
    Closed = 2,
}

/// <summary>Typed terminal read result. <see cref="Data"/> is set only for <see cref="MilaTerminalReadEvent.Data"/>.</summary>
internal readonly record struct MilaNativeTerminalRead(MilaNativeStatus Status, MilaTerminalReadEvent Event, byte[]? Data)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok;
}

/// <summary>Typed bytes result for stateless Rust encoders.</summary>
internal readonly record struct MilaNativeBytesResult(MilaNativeStatus Status, byte[]? Data)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok && Data is not null;
}

/// <summary>Typed `terminal new` result: the named server session to attach, or the refusal status.</summary>
internal readonly record struct MilaNativeTerminalOpen(MilaNativeStatus Status, string? SessionId)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok && SessionId is not null;
}

/// <summary>Push platforms accepted by Porsche's closed `device register` grammar.</summary>
internal enum MilaDevicePlatform : byte { Ios = 0, Android = 1, Macos = 2, Windows = 3 }

/// <summary>
/// Session lifecycle entry points used by sign-in, terminal reconnect and push
/// registration. Every call takes an opaque Rust handle; transport, command
/// construction and secret handling remain in Rust.
/// </summary>
internal static partial class RustNative
{
    private const int TerminalReadCapacity = 65_536;

    /// <summary>Returns the bounded `whoami --json` envelope from the authenticated session.</summary>
    internal static MilaNativeSessionBytesResult TrySessionWhoami(ulong handle)
    {
        if (handle == 0) return new(MilaNativeStatus.InvalidRequest, null);
        return TrySessionBytesOnce((bytes, capacity, written) => SessionWhoamiNative(handle, bytes, capacity, written), 64 * 1024);
    }

    /// <summary>Refreshes (<paramref name="more"/> false) or continues the Rust-owned machine listing.</summary>
    internal static MilaNativeStatus TrySessionReadMachines(ulong handle, bool more)
    {
        if (handle == 0) return MilaNativeStatus.InvalidRequest;
        try { return SessionReadMachinesNative(handle, more ? (byte)1 : (byte)0); }
        catch (DllNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (EntryPointNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (BadImageFormatException) { return MilaNativeStatus.Unavailable; }
    }

    /// <summary>
    /// Reads one bounded terminal chunk and its Rust classification. A lost
    /// transport is reported as <see cref="MilaNativeStatus.Transport"/>; idle and
    /// closed channels are distinct successful events.
    /// </summary>
    internal static MilaNativeTerminalRead TrySessionTerminalRead(ulong terminalHandle)
    {
        if (terminalHandle == 0) return new(MilaNativeStatus.InvalidRequest, MilaTerminalReadEvent.Idle, null);
        IntPtr output = Marshal.AllocHGlobal(TerminalReadCapacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = SessionTerminalReadNative(
                terminalHandle, output, (nuint)TerminalReadCapacity, written, out byte kind);
            nuint count = (nuint)Marshal.ReadIntPtr(written);
            if (status != MilaNativeStatus.Ok || count > (nuint)TerminalReadCapacity ||
                !Enum.IsDefined((MilaTerminalReadEvent)kind))
                return new(status == MilaNativeStatus.Ok ? MilaNativeStatus.Internal : status, MilaTerminalReadEvent.Idle, null);
            MilaTerminalReadEvent readEvent = (MilaTerminalReadEvent)kind;
            if (readEvent != MilaTerminalReadEvent.Data) return new(status, readEvent, null);
            byte[] bytes = new byte[checked((int)count)];
            Marshal.Copy(output, bytes, 0, bytes.Length);
            return new(status, readEvent, bytes);
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, MilaTerminalReadEvent.Idle, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, MilaTerminalReadEvent.Idle, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, MilaTerminalReadEvent.Idle, null); }
        finally { Marshal.FreeHGlobal(output); Marshal.FreeHGlobal(written); }
    }

    /// <summary>
    /// Encodes Susan's closed WNS key-issuance body after Rust validates the
    /// channel, application and deployment. The channel URI appears only in the
    /// returned request body and is never retained by managed state.
    /// </summary>
    internal static MilaNativeBytesResult TryEncodeWindowsPushKeyRequest(string channelUri, string appId, string deployment)
    {
        ArgumentNullException.ThrowIfNull(channelUri);
        ArgumentNullException.ThrowIfNull(appId);
        ArgumentNullException.ThrowIfNull(deployment);
        if (channelUri.Contains('\0') || appId.Contains('\0') || deployment.Contains('\0'))
            return new(MilaNativeStatus.InvalidRequest, null);
        IntPtr token = Marshal.StringToCoTaskMemUTF8(channelUri);
        IntPtr application = Marshal.StringToCoTaskMemUTF8(appId);
        IntPtr host = Marshal.StringToCoTaskMemUTF8(deployment);
        const int capacity = 4096;
        IntPtr buffer = Marshal.AllocHGlobal(capacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = PushKeyRequestNative(2, 1, token, application, host, token,
                new MilaRouteOutput(buffer, capacity, written));
            nuint count = (nuint)Marshal.ReadIntPtr(written);
            if (status != MilaNativeStatus.Ok || count is 0 or > capacity) return new(status, null);
            byte[] body = new byte[checked((int)count)];
            Marshal.Copy(buffer, body, 0, body.Length);
            return new(status, body);
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally
        {
            Marshal.FreeCoTaskMem(token); Marshal.FreeCoTaskMem(application); Marshal.FreeCoTaskMem(host);
            Marshal.FreeHGlobal(buffer); Marshal.FreeHGlobal(written);
        }
    }

    /// <summary>
    /// Registers this device through the authenticated Rust session. Rust validates
    /// Susan's reply and sends the push key to Porsche on stdin only.
    /// </summary>
    internal static MilaNativeSessionBytesResult TrySessionDeviceRegister(
        ulong handle, MilaDevicePlatform platform, ReadOnlySpan<byte> susanReply,
        string encPublicKey, string? label, ulong now)
    {
        ArgumentNullException.ThrowIfNull(encPublicKey);
        if (handle == 0 || susanReply.Length is 0 or > 4096 || encPublicKey.Length != 43 ||
            !Enum.IsDefined(platform) || (label is not null && Encoding.UTF8.GetByteCount(label) is 0 or > 64))
            return new(MilaNativeStatus.InvalidRequest, null);
        byte[] reply = susanReply.ToArray();
        byte[] key = Encoding.UTF8.GetBytes(encPublicKey);
        byte[] name = label is null ? [] : Encoding.UTF8.GetBytes(label);
        GCHandle replyPin = GCHandle.Alloc(reply, GCHandleType.Pinned);
        GCHandle keyPin = GCHandle.Alloc(key, GCHandleType.Pinned);
        GCHandle labelPin = GCHandle.Alloc(name, GCHandleType.Pinned);
        try
        {
            return TrySessionBytesOnce((bytes, capacity, written) => SessionDeviceRegisterNative(
                handle, (byte)platform, replyPin.AddrOfPinnedObject(), (nuint)reply.Length,
                keyPin.AddrOfPinnedObject(), (nuint)key.Length,
                name.Length == 0 ? IntPtr.Zero : labelPin.AddrOfPinnedObject(), (nuint)name.Length,
                now, bytes, capacity, written), 64 * 1024);
        }
        finally
        {
            // The reply carries the push key; clear the managed copy after the call.
            Array.Clear(reply);
            replyPin.Free(); keyPin.Free(); labelPin.Free();
        }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:protocol;reliability] mila-windows-terminal-named-session
    /// Terminal attach MUST name a server terminal session: `terminal new` opens
    /// or rejoins the caller's session on one machine and its receipt's
    /// <c>result.session_id</c> (a UUID) is the only identity passed to
    /// `mila_session_terminal_attach_session`. Porsche refuses unnamed attach.
    /// </summary>
    internal static MilaNativeTerminalOpen TrySessionTerminalNew(ulong handle, Guid machineId, string requestId)
    {
        if (handle == 0 || machineId == Guid.Empty || !IsCanonicalRequestId(requestId))
            return new(MilaNativeStatus.InvalidRequest, null);
        byte[] machine = Encoding.UTF8.GetBytes(machineId.ToString("D"));
        byte[] request = Encoding.UTF8.GetBytes(requestId);
        GCHandle machinePin = GCHandle.Alloc(machine, GCHandleType.Pinned);
        GCHandle requestPin = GCHandle.Alloc(request, GCHandleType.Pinned);
        try
        {
            MilaNativeSessionBytesResult receipt = TrySessionBytesOnce((bytes, capacity, written) => SessionTerminalNewNative(
                handle, machinePin.AddrOfPinnedObject(), (nuint)machine.Length,
                requestPin.AddrOfPinnedObject(), (nuint)request.Length, bytes, capacity, written), 64 * 1024);
            if (receipt.Status != MilaNativeStatus.Ok || receipt.Data is null) return new(receipt.Status, null);
            return DecodeTerminalNew(receipt.Data) is { } session
                ? new(MilaNativeStatus.Ok, session)
                : new(MilaNativeStatus.InvalidRequest, null);
        }
        finally { machinePin.Free(); requestPin.Free(); }
    }

    /// <summary>Decodes the `terminal new` receipt to its canonical session UUID, or null.</summary>
    internal static string? DecodeTerminalNew(ReadOnlySpan<byte> receipt)
    {
        try
        {
            using System.Text.Json.JsonDocument document = System.Text.Json.JsonDocument.Parse(receipt.ToArray());
            System.Text.Json.JsonElement root = document.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object ||
                !root.TryGetProperty("result", out System.Text.Json.JsonElement result) ||
                result.ValueKind != System.Text.Json.JsonValueKind.Object ||
                !result.TryGetProperty("session_id", out System.Text.Json.JsonElement id) ||
                id.ValueKind != System.Text.Json.JsonValueKind.String ||
                !Guid.TryParseExact(id.GetString(), "D", out Guid session) || session == Guid.Empty)
                return null;
            return session.ToString("D");
        }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>Attaches a bounded PTY to one named server terminal session.</summary>
    internal static (MilaNativeStatus Status, ulong? Handle) TrySessionTerminalAttachSession(
        ulong sessionHandle, Guid machineId, string terminalId, ushort columns, ushort rows)
    {
        if (sessionHandle == 0 || machineId == Guid.Empty || columns is 0 or > 4096 || rows is 0 or > 512 ||
            !Guid.TryParseExact(terminalId, "D", out Guid terminal) || terminal == Guid.Empty)
            return (MilaNativeStatus.InvalidRequest, null);
        byte[] machine = Encoding.UTF8.GetBytes(machineId.ToString("D"));
        byte[] session = Encoding.UTF8.GetBytes(terminal.ToString("D"));
        GCHandle machinePin = GCHandle.Alloc(machine, GCHandleType.Pinned);
        GCHandle sessionPin = GCHandle.Alloc(session, GCHandleType.Pinned);
        try
        {
            MilaNativeStatus status = SessionTerminalAttachSessionNative(
                sessionHandle, machinePin.AddrOfPinnedObject(), (nuint)machine.Length,
                sessionPin.AddrOfPinnedObject(), (nuint)session.Length, columns, rows, out ulong handle);
            return status == MilaNativeStatus.Ok && handle > 0 ? (status, handle) : (status, null);
        }
        catch (DllNotFoundException) { return (MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return (MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return (MilaNativeStatus.Unavailable, null); }
        finally { machinePin.Free(); sessionPin.Free(); }
    }

    /// <summary>
    /// Returns the closed refusal code of the session's most recent refused
    /// command (for example <c>terminal_unavailable</c>), or null.
    /// </summary>
    internal static string? TrySessionLastRefusal(ulong handle)
    {
        if (handle == 0) return null;
        MilaNativeSessionBytesResult result = TrySessionBytesOnce(
            (bytes, capacity, written) => SessionLastRefusalNative(handle, bytes, capacity, written), 1024);
        if (!result.Succeeded || result.Data is null) return null;
        try
        {
            using System.Text.Json.JsonDocument document = System.Text.Json.JsonDocument.Parse(result.Data);
            return document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                document.RootElement.TryGetProperty("error", out System.Text.Json.JsonElement error) &&
                error.ValueKind == System.Text.Json.JsonValueKind.String &&
                error.GetString() is { Length: > 0 and <= 64 } code && code.All(c => c is >= 'a' and <= 'z' or '_')
                ? code : null;
        }
        catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:reliability] mila-windows-session-bytes-once
    /// Session operations that execute a remote command MUST be invoked exactly
    /// once per call with a fixed bounded buffer. The size-probing helper repeats
    /// the native call and would resubmit a mutation such as a prompt or
    /// device registration.
    /// </summary>
    internal static MilaNativeSessionBytesResult TrySessionBytesOnce(
        Func<IntPtr, nuint, IntPtr, MilaNativeStatus> call, int capacity)
    {
        if (capacity is <= 0 or > 256 * 1024) return new(MilaNativeStatus.InvalidRequest, null);
        IntPtr output = Marshal.AllocHGlobal(capacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = call(output, (nuint)capacity, written);
            nuint size = (nuint)Marshal.ReadIntPtr(written);
            if (status != MilaNativeStatus.Ok || size > (nuint)capacity) return new(status, null);
            byte[] bytes = new byte[checked((int)size)];
            Marshal.Copy(output, bytes, 0, bytes.Length);
            return new(status, bytes);
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { Marshal.FreeHGlobal(output); Marshal.FreeHGlobal(written); }
    }

    [LibraryImport(LibraryName, EntryPoint = "mila_session_whoami")]
    private static partial MilaNativeStatus SessionWhoamiNative(ulong handle, IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_read_machines")]
    private static partial MilaNativeStatus SessionReadMachinesNative(ulong handle, byte more);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_new")]
    private static partial MilaNativeStatus SessionTerminalNewNative(
        ulong handle, IntPtr machine, nuint machineLength, IntPtr requestId, nuint requestIdLength,
        IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_attach_session")]
    private static partial MilaNativeStatus SessionTerminalAttachSessionNative(
        ulong sessionHandle, IntPtr machine, nuint machineLength, IntPtr terminal, nuint terminalLength,
        uint columns, uint rows, out ulong terminalHandle);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_last_refusal")]
    private static partial MilaNativeStatus SessionLastRefusalNative(ulong handle, IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_read")]
    private static partial MilaNativeStatus SessionTerminalReadNative(
        ulong terminalHandle, IntPtr output, nuint capacity, IntPtr written, out byte readEvent);

    [LibraryImport(LibraryName, EntryPoint = "mila_push_key_request_encode")]
    private static partial MilaNativeStatus PushKeyRequestNative(
        byte provider, byte environment, IntPtr token, IntPtr appId, IntPtr deployment,
        IntPtr endpoint, MilaRouteOutput output);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_device_register")]
    private static partial MilaNativeStatus SessionDeviceRegisterNative(
        ulong handle, byte platform, IntPtr susanReply, nuint susanReplyLength,
        IntPtr encPublicKey, nuint encPublicKeyLength, IntPtr label, nuint labelLength,
        ulong now, IntPtr output, nuint capacity, IntPtr written);
}
