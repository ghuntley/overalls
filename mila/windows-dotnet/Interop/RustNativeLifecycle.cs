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
