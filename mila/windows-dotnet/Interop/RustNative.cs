using System.Runtime.InteropServices;
using System.Text;

namespace Mila.Windows.Interop;

internal enum MilaRouteKind { Machines, Machine, Threads, Thread, Settings }
internal readonly record struct MilaRoute(MilaRouteKind Kind, string Host, Guid? Id = null)
{
    internal string Path => Kind switch
    {
        MilaRouteKind.Machines => "/machines",
        MilaRouteKind.Machine => $"/machines/{Id?.ToString("D")}",
        MilaRouteKind.Threads => "/threads",
        MilaRouteKind.Thread => $"/threads/{Id?.ToString("D")}",
        MilaRouteKind.Settings => "/settings",
        _ => throw new InvalidOperationException("Unknown route kind")
    };
}

internal static class MilaRouteParser
{
    internal static MilaRoute? Parse(string value)
    {
        if (value.Length is 0 or > 4096 || value.Any(char.IsControl) || value.Contains(' ') ||
            !value.StartsWith("overalls://", StringComparison.Ordinal) ||
            !Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) || uri.Scheme != "overalls" ||
            !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) ||
            !string.IsNullOrEmpty(uri.UserInfo) || uri.Port != -1) return null;
        string authority = value["overalls://".Length..].Split('/', 2)[0];
        string host = uri.Host;
        if (host.Length == 0 || host != host.ToLowerInvariant() || host.Contains('%')) return null;
        if (authority != host) return null;
        string remainder = value["overalls://".Length..];
        int slash = remainder.IndexOf('/');
        string rawPath = slash < 0 ? string.Empty : remainder[slash..].Split('?', 2)[0];
        if (rawPath.Length == 0 || rawPath.Contains("//", StringComparison.Ordinal) || rawPath.EndsWith('/') || rawPath.Contains('%')) return null;
        string[] parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 1 && parts.Length != 2) return null;
        if (parts.Length == 1) return parts[0] switch
        {
            "machines" => new(MilaRouteKind.Machines, host),
            "threads" => new(MilaRouteKind.Threads, host),
            "settings" => new(MilaRouteKind.Settings, host),
            _ => null,
        };
        if (parts[1].Length == 0 ||
            !Guid.TryParseExact(parts[1], "D", out Guid id) || parts[1] != id.ToString("D")) return null;
        return parts[0] switch
        {
            "machines" => new(MilaRouteKind.Machine, host, id),
            "threads" => new(MilaRouteKind.Thread, host, id),
            _ => null,
        };
    }
}

/// <summary>
/// Status values returned by the Rust native library.
/// </summary>
internal enum MilaNativeStatus : int
{
    Ok = 0,
    NullInput = -1,
    InvalidRoute = -2,
    OutputTooSmall = -3,
    InvalidRequest = -4,
    InvalidHandle = -10,
    Transport = -11,
    NotLoaded = -12,
    Busy = -13,
    Internal = -14,
    Unavailable = -127,
}

/// <summary>
/// Version returned by the native ABI. Keep this layout in sync with Rust's
/// <c>#[repr(C)]</c> struct when the implementation is added.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaNativeVersion
{
    internal MilaNativeVersion(uint major, uint minor)
    {
        Major = major;
        Minor = minor;
    }

    internal readonly uint Major;

    internal readonly uint Minor;
}

/// <summary>Typed result from the native version probe.</summary>
internal readonly record struct MilaNativeVersionResult(
    MilaNativeStatus Status,
    MilaNativeVersion? Version);

/// <summary>Caller-owned output buffer passed to the stable Rust route ABI.</summary>
[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaRouteOutput
{
    internal MilaRouteOutput(IntPtr bytes, nuint capacity, IntPtr written)
    {
        Bytes = bytes;
        Capacity = capacity;
        Written = written;
    }

    internal readonly IntPtr Bytes;
    internal readonly nuint Capacity;
    internal readonly IntPtr Written;
}

internal readonly record struct MilaNativeRouteResult(
    MilaNativeStatus Status,
    string? Canonical);

internal readonly record struct MilaNativeTrustResult(
    MilaNativeStatus Status,
    byte[]? Document);

[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaSnapshotSummary
{
    internal readonly uint MachineCount;
    internal readonly ulong SavedAt;
}

internal readonly record struct MilaNativeSnapshotResult(
    MilaNativeStatus Status,
    MilaSnapshotSummary? Summary);

[Flags]
internal enum MilaMachineAction : ushort
{
    None = 0, Start = 1, Stop = 2, Pause = 4, Resume = 8,
    Pin = 16, Unpin = 32, Delete = 64,
}

[StructLayout(LayoutKind.Sequential)]
internal readonly struct MilaMachineActions
{
    internal readonly MilaMachineAction Bits;
}

internal readonly record struct MilaNativeActionsResult(
    MilaNativeStatus Status, MilaMachineAction? Actions);
internal readonly record struct MilaNativeCommandResult(
    MilaNativeStatus Status, string? Command);

internal readonly record struct MilaNativeSessionActionResult(MilaNativeStatus Status)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok;
}
internal readonly record struct MilaNativeSessionBytesResult(
    MilaNativeStatus Status, byte[]? Data)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok && Data is not null;
}
internal readonly record struct MilaNativeSessionConnectResult(MilaNativeStatus Status, ulong? Handle)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok && Handle is > 0;
}

internal enum MilaThreadCommandKind : int
{
    Unknown = 0, List = 1, Show = 2, Turns = 3, Prompt = 4, Answer = 5,
    PlanApprove = 6, PlanRevise = 7, Mode = 8, Read = 9,
}
internal enum MilaMachineCommandKind : int { Unknown = 0, List = 1, Show = 2, New = 3, Resize = 4, Start = 5, Stop = 6, Pause = 7, Resume = 8, Delete = 9, ShareAdd = 10, ShareRemove = 11, WebShow = 12, WebSet = 13 }

internal readonly record struct MilaNativeThreadCommandResult(
    MilaNativeStatus Status, MilaThreadCommandKind? Kind);

internal readonly record struct MilaNativeTerminalResult(MilaNativeStatus Status)
{
    internal bool IsValid => Status == MilaNativeStatus.Ok;
}
internal readonly record struct MilaNativeTerminalBytesResult(MilaNativeStatus Status, byte[]? Data)
{
    internal bool Succeeded => Status == MilaNativeStatus.Ok && Data is not null;
}

internal readonly record struct MilaNativePokeResult(MilaNativeStatus Status)
{
    internal bool IsValid => Status == MilaNativeStatus.Ok;
}

/// <summary>
/// Narrow P/Invoke boundary for the Rust implementation.
///
/// The DLL is intentionally absent from this scaffold. Callers receive
/// <see cref="MilaNativeStatus.Unavailable"/> until the Windows build stages
/// the Rust library produced by the source bundle.
/// </summary>
internal static partial class RustNative
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int MilaSignCallback(nuint context, IntPtr message, nuint messageLength, IntPtr signature);

    /// Establishes an authenticated Rust session. The signer callback is retained only
    /// for the duration of the synchronous native connect call.
    internal static MilaNativeSessionConnectResult TrySessionConnect(
        ReadOnlySpan<byte> trust, string host, ReadOnlySpan<byte> publicKey, ushort port,
        uint timeoutMs, Func<byte[], byte[]> signer)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(signer);
        if (host.Any(char.IsControl) || host.Contains('\0') || port == 0 || timeoutMs is < 1 or > 120_000)
            return new(MilaNativeStatus.InvalidRequest, null);
        GCHandle holder = GCHandle.Alloc(signer);
        MilaSignCallback callback = (context, message, length, output) =>
        {
            try
            {
                byte[] input = new byte[checked((int)length)];
                Marshal.Copy(message, input, 0, input.Length);
                byte[] signature = ((Func<byte[], byte[]>)GCHandle.FromIntPtr((IntPtr)context).Target!)(input);
                if (signature.Length != 64) return -1;
                Marshal.Copy(signature, 0, output, signature.Length);
                return 0;
            }
            catch { return -1; }
        };
        try
        {
            ulong handle = 0;
            GCHandle trustPin = GCHandle.Alloc(trust.ToArray(), GCHandleType.Pinned);
            GCHandle publicPin = GCHandle.Alloc(publicKey.ToArray(), GCHandleType.Pinned);
            MilaNativeStatus status;
            try { status = SessionConnectNative(trustPin.AddrOfPinnedObject(), (nuint)trust.Length,
                host, (nuint)Encoding.UTF8.GetByteCount(host), publicPin.AddrOfPinnedObject(), (nuint)publicKey.Length,
                port, timeoutMs, callback, (nuint)GCHandle.ToIntPtr(holder), out handle);
            } finally { trustPin.Free(); publicPin.Free(); }
            return status == MilaNativeStatus.Ok ? new(status, handle) : new(status, null);
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { holder.Free(); }
    }
    /// <summary>Decodes a bounded listing copied from the live Rust session.</summary>
    internal static MilaSessionListing DecodeSessionListing(ReadOnlySpan<byte> bytes) => MilaSessionListing.Decode(bytes);
    private const string LibraryName = "mila_native";

    /// <summary>
    /// Queries the native ABI version without exposing raw pointers to callers.
    /// </summary>
    /// <returns>A typed status and an optional version.</returns>
    internal static MilaNativeVersionResult TryGetVersion()
    {
        try
        {
            MilaNativeStatus status = GetVersionNative(out MilaNativeVersion version);
            return status == MilaNativeStatus.Ok
                ? new(status, version)
                : new(status, null);
        }
        catch (DllNotFoundException)
        {
            return new(MilaNativeStatus.Unavailable, null);
        }
        catch (EntryPointNotFoundException)
        {
            return new(MilaNativeStatus.Unavailable, null);
        }
        catch (BadImageFormatException)
        {
            return new(MilaNativeStatus.Unavailable, null);
        }
    }

    /// <summary>Validates and reconciles a fetched trust document in Rust.</summary>
    internal static unsafe MilaNativeTrustResult TryReconcileTrust(
        byte[]? pinned, byte[]? fetched, string host, ulong now)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (host.Contains('\0') || pinned?.Length > 8192 || fetched?.Length > 8192)
            return new(MilaNativeStatus.InvalidRequest, null);
        byte[] output = new byte[8192];
        IntPtr hostPtr = Marshal.StringToCoTaskMemUTF8(host);
        try
        {
            fixed (byte* pinnedPtr = pinned)
            fixed (byte* fetchedPtr = fetched)
            fixed (byte* outputPtr = output)
            {
                nuint written = 0;
                MilaRouteOutput target = new((IntPtr)outputPtr, (nuint)output.Length,
                    (IntPtr)(&written));
                MilaNativeStatus status = TrustReconcileNative(
                    (IntPtr)pinnedPtr, (nuint)(pinned?.Length ?? 0),
                    (IntPtr)fetchedPtr, (nuint)(fetched?.Length ?? 0), hostPtr, now, target);
                if (status != MilaNativeStatus.Ok || written == 0 || written > (nuint)output.Length)
                    return new(status, null);
                return new(status, output[..checked((int)written)]);
            }
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { Marshal.FreeCoTaskMem(hostPtr); }
    }

    /// <summary>
    /// Canonicalizes a navigation route using the Rust closed route grammar.
    /// Managed callers never receive or provide raw pointers; this method owns
    /// temporary UTF-8 input and output storage for the duration of the call.
    /// </summary>
    internal static MilaNativeRouteResult TryFormatRoute(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Contains('\0')) return new(MilaNativeStatus.InvalidRoute, null);
        byte[] inputBytes = Encoding.UTF8.GetBytes(value);
        IntPtr input = Marshal.AllocHGlobal(inputBytes.Length + 1);
        IntPtr bytes = Marshal.AllocHGlobal(RouteOutputCapacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.Copy(inputBytes, 0, input, inputBytes.Length);
            Marshal.WriteByte(input, inputBytes.Length, 0);
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaRouteOutput output = new(bytes, (nuint)RouteOutputCapacity, written);
            MilaNativeStatus status = FormatRouteNative(input, output);
            if (status != MilaNativeStatus.Ok) return new(status, null);
            nuint length = (nuint)Marshal.ReadIntPtr(written);
            if (length > RouteOutputCapacity) return new(MilaNativeStatus.InvalidRoute, null);
            byte[] result = new byte[checked((int)length)];
            Marshal.Copy(bytes, result, 0, result.Length);
            return new(status, new UTF8Encoding(false, true).GetString(result));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (DecoderFallbackException) { return new(MilaNativeStatus.InvalidRoute, null); }
        finally
        {
            Marshal.FreeHGlobal(input);
            Marshal.FreeHGlobal(bytes);
            Marshal.FreeHGlobal(written);
        }
    }

    /// <summary>Validates an offline snapshot against the active deployment.</summary>
    internal static MilaNativeSnapshotResult TryValidateSnapshot(
        ReadOnlySpan<byte> snapshot, string host, ushort port, bool hasPort)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (host.Contains('\0')) return new(MilaNativeStatus.InvalidRequest, null);
        unsafe
        {
            fixed (byte* bytes = snapshot)
            {
                IntPtr hostPtr = Marshal.StringToCoTaskMemUTF8(host);
                try
                {
                    MilaNativeStatus status = ValidateSnapshotNative(
                        (IntPtr)bytes, (nuint)snapshot.Length, hostPtr, port,
                        hasPort ? (byte)1 : (byte)0, out MilaSnapshotSummary summary);
                    return status == MilaNativeStatus.Ok
                        ? new(status, summary)
                        : new(status, null);
                }
                catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
                catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
                catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
                finally { Marshal.FreeCoTaskMem(hostPtr); }
            }
        }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security] mila-windows-rust-action-policy
    /// Available actions MUST come from Rust's deployment-validated snapshot;
    /// refusals MUST expose no actions and MUST NOT change local authority.
    /// </summary>
    internal static unsafe MilaNativeActionsResult TryGetMachineActions(
        ReadOnlySpan<byte> snapshot, string host, ushort? port, uint index)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (host.Contains('\0')) return new(MilaNativeStatus.InvalidRequest, null);
        fixed (byte* bytes = snapshot)
        {
            IntPtr hostPtr = Marshal.StringToCoTaskMemUTF8(host);
            try
            {
                MilaNativeStatus status = MachineActionsNative((IntPtr)bytes,
                    (nuint)snapshot.Length, hostPtr, port ?? 0, port.HasValue ? (byte)1 : (byte)0,
                    index, out MilaMachineActions actions);
                return status == MilaNativeStatus.Ok ? new(status, actions.Bits) : new(status, null);
            }
            catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
            catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
            catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
            finally { Marshal.FreeCoTaskMem(hostPtr); }
        }
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:protocol] mila-windows-command-format-only
    /// Commands MUST be formatted by Rust into bounded storage. Formatting MUST
    /// NOT submit a command or imply authentication, authorization or queuing.
    /// </summary>
    internal static MilaNativeCommandResult TryFormatMachineCommand(
        string action, Guid machineId, string? requestId)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (action.Contains('\0') || requestId?.Contains('\0') == true)
            return new(MilaNativeStatus.InvalidRequest, null);
        IntPtr actionPtr = Marshal.StringToCoTaskMemUTF8(action);
        IntPtr machinePtr = Marshal.StringToCoTaskMemUTF8(machineId.ToString("D"));
        IntPtr requestPtr = requestId is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(requestId);
        IntPtr bytes = Marshal.AllocHGlobal(RouteOutputCapacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = MachineCommandNative(actionPtr, machinePtr, requestPtr,
                new(bytes, RouteOutputCapacity, written));
            if (status != MilaNativeStatus.Ok) return new(status, null);
            nuint length = (nuint)Marshal.ReadIntPtr(written);
            if (length > RouteOutputCapacity) return new(MilaNativeStatus.InvalidRequest, null);
            byte[] result = new byte[checked((int)length)];
            Marshal.Copy(bytes, result, 0, result.Length);
            return new(status, new UTF8Encoding(false, true).GetString(result));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (DecoderFallbackException) { return new(MilaNativeStatus.InvalidRequest, null); }
        finally
        {
            Marshal.FreeCoTaskMem(actionPtr);
            Marshal.FreeCoTaskMem(machinePtr);
            Marshal.FreeCoTaskMem(requestPtr);
            Marshal.FreeHGlobal(bytes);
            Marshal.FreeHGlobal(written);
        }
    }

    /// <summary>Dispatches one authenticated mutation through an existing Rust session.</summary>
    internal static MilaNativeSessionActionResult TrySessionMachineAction(
        ulong handle, Guid machineId, string action, string requestId)
    {
        ArgumentException.ThrowIfNullOrEmpty(action);
        ArgumentException.ThrowIfNullOrEmpty(requestId);
        if (handle == 0 || action.Any(char.IsWhiteSpace) || action.Length > 32 ||
            requestId.Length > 64 || action.Contains('\0') || requestId.Contains('\0'))
            return new(MilaNativeStatus.InvalidRequest);
        IntPtr machine = Marshal.StringToCoTaskMemUTF8(machineId.ToString("D"));
        IntPtr operation = Marshal.StringToCoTaskMemUTF8(action);
        IntPtr request = Marshal.StringToCoTaskMemUTF8(requestId);
        try
        {
            return new((MilaNativeStatus)SessionMachineActionNative(handle, machine, 36, operation,
                (nuint)Encoding.UTF8.GetByteCount(action), request, (nuint)Encoding.UTF8.GetByteCount(requestId)));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(machine); Marshal.FreeCoTaskMem(operation); Marshal.FreeCoTaskMem(request); }
    }

    internal static MilaNativeSessionActionResult TrySessionMachineCreate(ulong handle, string name, uint cpu, ulong memory, ulong disk, string requestId)
    {
        if (handle == 0 || string.IsNullOrWhiteSpace(name) || name.Length > 128 || !name.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_') ||
            cpu is < 1 or > 256 || memory is < 256 or > 4_194_304 || disk is < 1 or > 500 || !IsCanonicalRequestId(requestId)) return new(MilaNativeStatus.InvalidRequest);
        IntPtr namePtr = Marshal.StringToCoTaskMemUTF8(name), requestPtr = Marshal.StringToCoTaskMemUTF8(requestId);
        try { return new((MilaNativeStatus)SessionMachineCreateNative(handle, namePtr, (nuint)Encoding.UTF8.GetByteCount(name), cpu, memory, disk, requestPtr, (nuint)Encoding.UTF8.GetByteCount(requestId))); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); } catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); } catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(namePtr); Marshal.FreeCoTaskMem(requestPtr); }
    }

    internal static MilaNativeSessionActionResult TrySessionMachineResize(
        ulong handle, Guid machineId, uint cpu, ulong memory, ulong disk, string requestId)
    {
        // Empty IDs are never valid machine targets. Reject them before crossing
        // the ABI so a signed-in UI cannot accidentally mutate an unspecified
        // resource when selection state is stale.
        if (handle == 0 || machineId == Guid.Empty || cpu is < 1 or > 256 || memory is < 256 or > 4_194_304 ||
            disk is < 1 or > 16_777_216 || !IsCanonicalRequestId(requestId))
            return new(MilaNativeStatus.InvalidRequest);
        string machine = machineId.ToString("D");
        IntPtr machinePtr = Marshal.StringToCoTaskMemUTF8(machine);
        IntPtr requestPtr = Marshal.StringToCoTaskMemUTF8(requestId);
        try
        {
            return new((MilaNativeStatus)SessionMachineResizeNative(handle, machinePtr,
                (nuint)Encoding.UTF8.GetByteCount(machine), cpu, memory, disk, requestPtr,
                (nuint)Encoding.UTF8.GetByteCount(requestId)));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(machinePtr); Marshal.FreeCoTaskMem(requestPtr); }
    }

    internal static MilaNativeSessionActionResult TrySessionShareMutation(ulong handle, Guid machineId, string email, string? role, bool add, string requestId)
    {
        if (handle == 0 || machineId == Guid.Empty || string.IsNullOrWhiteSpace(email) || email.Length > 320 || email.Any(char.IsControl) || !IsCanonicalRequestId(requestId))
            return new(MilaNativeStatus.InvalidRequest);
        if (add && role is not ("viewer" or "operator" or "manager")) return new(MilaNativeStatus.InvalidRequest);
        if (!add) role = string.Empty;
        string machine = machineId.ToString("D");
        IntPtr m = Marshal.StringToCoTaskMemUTF8(machine), e = Marshal.StringToCoTaskMemUTF8(email), r = Marshal.StringToCoTaskMemUTF8(role), q = Marshal.StringToCoTaskMemUTF8(requestId);
        try { return new((MilaNativeStatus)SessionShareMutationNative(handle, m, 36, e, (nuint)Encoding.UTF8.GetByteCount(email), r, (nuint)Encoding.UTF8.GetByteCount(role ?? string.Empty), add ? (byte)1 : (byte)0, q, (nuint)Encoding.UTF8.GetByteCount(requestId))); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(m); Marshal.FreeCoTaskMem(e); Marshal.FreeCoTaskMem(r); Marshal.FreeCoTaskMem(q); }
    }

    internal static MilaNativeSessionBytesResult TrySessionWebShow(ulong handle, Guid machineId)
    {
        if (handle == 0) return new(MilaNativeStatus.InvalidRequest, null);
        string machine = machineId.ToString("D");
        IntPtr machinePtr = Marshal.StringToCoTaskMemUTF8(machine);
        try { return TrySessionBytes((bytes, capacity, written) => SessionWebShowNative(handle, machinePtr, 36, bytes, capacity, written)); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { Marshal.FreeCoTaskMem(machinePtr); }
    }

    internal static MilaNativeSessionActionResult TrySessionWebSet(
        ulong handle, Guid machineId, ushort port, bool isPublic, ulong revision, string requestId)
    {
        if (handle == 0 || port == 0 || !IsCanonicalRequestId(requestId))
            return new(MilaNativeStatus.InvalidRequest);
        string machine = machineId.ToString("D");
        IntPtr machinePtr = Marshal.StringToCoTaskMemUTF8(machine);
        IntPtr requestPtr = Marshal.StringToCoTaskMemUTF8(requestId);
        try { return new((MilaNativeStatus)SessionWebSetNative(handle, machinePtr, 36, port, isPublic ? (byte)1 : (byte)0, revision, requestPtr, (nuint)Encoding.UTF8.GetByteCount(requestId))); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(machinePtr); Marshal.FreeCoTaskMem(requestPtr); }
    }

    /// <summary>
    /// Copies the bounded approved-key listing from an authenticated Rust session.
    /// Managed callers receive only owned UTF-8 bytes; the native session remains
    /// the authority for authentication and authorization.
    /// </summary>
    internal static MilaNativeSessionBytesResult TrySessionSshKeys(ulong handle)
    {
        if (handle == 0) return new(MilaNativeStatus.InvalidRequest, null);
        return TrySessionBytes((bytes, capacity, written) =>
            SessionSshKeysNative(handle, bytes, capacity, written));
    }

    internal static MilaNativeSessionBytesResult TrySessionDevices(ulong handle)
    {
        if (handle == 0) return new(MilaNativeStatus.InvalidRequest, null);
        return TrySessionBytes((bytes, capacity, written) => SessionDevicesNative(handle, bytes, capacity, written));
    }

    internal static MilaNativeSessionActionResult TrySessionDeviceRemove(ulong handle, string deviceId)
    {
        if (handle == 0 || string.IsNullOrWhiteSpace(deviceId) || deviceId.Length > 128) return new(MilaNativeStatus.InvalidRequest);
        IntPtr id = Marshal.StringToCoTaskMemUTF8(deviceId);
        try { return new((MilaNativeStatus)SessionDeviceRemoveNative(handle, id, (nuint)Encoding.UTF8.GetByteCount(deviceId))); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(id); }
    }

    internal static MilaNativeSessionActionResult TrySessionDevicePreferences(ulong handle, string deviceId, bool enabled)
    {
        if (handle == 0 || string.IsNullOrWhiteSpace(deviceId) || deviceId.Length > 128) return new(MilaNativeStatus.InvalidRequest);
        IntPtr id = Marshal.StringToCoTaskMemUTF8(deviceId);
        try { return new((MilaNativeStatus)SessionDevicePreferencesNative(handle, id, (nuint)Encoding.UTF8.GetByteCount(deviceId), enabled ? (byte)1 : (byte)0)); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(id); }
    }

    /// <summary>Copies the bounded machine listing from an authenticated Rust session.</summary>
    internal static MilaNativeSessionBytesResult TrySessionListing(ulong handle)
    {
        if (handle == 0) return new(MilaNativeStatus.InvalidRequest, null);
        return TrySessionBytes((bytes, capacity, written) => SessionListingNative(handle, bytes, capacity, written));
    }

    /// <summary>Executes one authenticated, bounded thread operation in Rust.</summary>
    internal static MilaNativeSessionBytesResult TrySessionThreadAction(
        ulong handle, Guid? thread, string command, string? secondary, string? input, string? requestId)
    {
        if (handle == 0 || string.IsNullOrWhiteSpace(command) || command.Length > 64 ||
            command.Contains('\0') || command.Split(' ').Any(string.IsNullOrEmpty) ||
            (thread is null && command != "ls") ||
            (thread is not null && command == "ls") ||
            secondary?.Length > 128 || input?.Length > 64 * 1024 || requestId?.Length > 64 ||
            (requestId is not null && !IsCanonicalRequestId(requestId)))
            return new(MilaNativeStatus.InvalidRequest, null);
        string? threadText = thread?.ToString("D");
        IntPtr threadPtr = Marshal.StringToCoTaskMemUTF8(threadText ?? string.Empty);
        IntPtr commandPtr = Marshal.StringToCoTaskMemUTF8(command);
        IntPtr secondaryPtr = Marshal.StringToCoTaskMemUTF8(secondary ?? string.Empty);
        IntPtr inputPtr = Marshal.StringToCoTaskMemUTF8(input ?? string.Empty);
        IntPtr requestPtr = Marshal.StringToCoTaskMemUTF8(requestId ?? string.Empty);
        try
        {
            // Prompts, answers and plan decisions execute remotely: call once.
            return TrySessionBytesOnce((bytes, capacity, written) => SessionThreadActionNative(
                handle, threadPtr, (nuint)Encoding.UTF8.GetByteCount(threadText ?? string.Empty),
                commandPtr, (nuint)Encoding.UTF8.GetByteCount(command), secondaryPtr,
                (nuint)Encoding.UTF8.GetByteCount(secondary ?? string.Empty), inputPtr,
                (nuint)Encoding.UTF8.GetByteCount(input ?? string.Empty), requestPtr,
                (nuint)Encoding.UTF8.GetByteCount(requestId ?? string.Empty), bytes, capacity, written), 256 * 1024);
        }
        finally
        {
            Marshal.FreeCoTaskMem(threadPtr); Marshal.FreeCoTaskMem(commandPtr);
            Marshal.FreeCoTaskMem(secondaryPtr); Marshal.FreeCoTaskMem(inputPtr); Marshal.FreeCoTaskMem(requestPtr);
        }
    }

    /// <summary>Revokes one canonical approved-key identity through the Rust session.</summary>
    internal static MilaNativeSessionActionResult TrySessionSshKeyRevoke(
        ulong handle, Guid keyId, string requestId)
    {
        if (handle == 0 || !IsCanonicalRequestId(requestId))
            return new(MilaNativeStatus.InvalidRequest);
        string key = keyId.ToString("D");
        IntPtr keyPtr = Marshal.StringToCoTaskMemUTF8(key);
        IntPtr requestPtr = Marshal.StringToCoTaskMemUTF8(requestId);
        try
        {
            return new((MilaNativeStatus)SessionSshKeyRevokeNative(
                handle, keyPtr, (nuint)Encoding.UTF8.GetByteCount(key), requestPtr,
                (nuint)Encoding.UTF8.GetByteCount(requestId)));
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        finally { Marshal.FreeCoTaskMem(keyPtr); Marshal.FreeCoTaskMem(requestPtr); }
    }

    private static bool IsCanonicalRequestId(string? value) =>
        value is { Length: 40 } && value.StartsWith("porsche-", StringComparison.Ordinal) &&
        value[8..].All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static MilaNativeSessionBytesResult TrySessionBytes(
        Func<IntPtr, nuint, IntPtr, MilaNativeStatus> call)
    {
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = call(IntPtr.Zero, 0, written);
            nuint size = (nuint)Marshal.ReadIntPtr(written);
            if (status != MilaNativeStatus.OutputTooSmall || size == 0 || size > 256 * 1024)
                return new(status, null);
            IntPtr output = Marshal.AllocHGlobal(checked((int)size));
            try
            {
                status = call(output, size, written);
                nuint writtenSize = (nuint)Marshal.ReadIntPtr(written);
                if (status != MilaNativeStatus.Ok || writtenSize > size)
                    return new(status, null);
                byte[] bytes = new byte[checked((int)writtenSize)];
                Marshal.Copy(output, bytes, 0, bytes.Length);
                return new(status, bytes);
            }
            finally { Marshal.FreeHGlobal(output); }
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { Marshal.FreeHGlobal(written); }
    }

    internal static MilaNativeStatus TrySessionClose(ulong handle)
    {
        if (handle == 0) return MilaNativeStatus.InvalidRequest;
        try { return (MilaNativeStatus)SessionCloseNative(handle); }
        catch (DllNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (EntryPointNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (BadImageFormatException) { return MilaNativeStatus.Unavailable; }
    }

    /// <summary>Projects only the closed Rust thread-command catalogue.</summary>
    internal static MilaNativeThreadCommandResult TryClassifyThreadCommand(string line)
    {
        ArgumentNullException.ThrowIfNull(line);
        if (line.Contains('\0')) return new(MilaNativeStatus.InvalidRequest, null);
        IntPtr input = Marshal.StringToCoTaskMemUTF8(line);
        try
        {
            MilaNativeStatus status = ThreadCommandKindNative(input, out MilaThreadCommandKind kind);
            return status == MilaNativeStatus.Ok ? new(status, kind) : new(status, null);
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { Marshal.FreeCoTaskMem(input); }
    }
    internal static MilaMachineCommandKind? TryClassifyMachineCommand(string line)
    {
        if (line.Contains('\0')) return null;
        IntPtr input = Marshal.StringToCoTaskMemUTF8(line);
        try { MilaNativeStatus status = MachineCommandKindNative(input, out MilaMachineCommandKind kind); return status == MilaNativeStatus.Ok ? kind : null; }
        catch (DllNotFoundException) { return null; } catch (EntryPointNotFoundException) { return null; } finally { Marshal.FreeCoTaskMem(input); }
    }

    /// <summary>Validates terminal attach dimensions and mode before opening a PTY.</summary>
    internal static MilaNativeTerminalResult TryValidateTerminalAttach(
        ulong from, ushort columns, ushort rows, bool readWrite)
        => TryTerminal(() => TerminalAttachNative(from, columns, rows, readWrite ? (byte)1 : (byte)0));

    internal static MilaNativeTerminalResult TryValidateTerminalInput(nuint length, bool readWrite)
        => TryTerminal(() => TerminalInputNative(length, readWrite ? (byte)1 : (byte)0));

    internal static MilaNativeTerminalResult TryValidateTerminalResize(
        ushort columns, ushort rows, bool readWrite)
        => TryTerminal(() => TerminalResizeNative(columns, rows, readWrite ? (byte)1 : (byte)0));

    internal static MilaNativeTerminalBytesResult TrySessionTerminalPoll(ulong terminalHandle)
    {
        if (terminalHandle == 0) return new(MilaNativeStatus.InvalidRequest, null);
        const int capacity = 65_536;
        IntPtr output = Marshal.AllocHGlobal(capacity);
        IntPtr written = Marshal.AllocHGlobal(nuint.Size);
        try
        {
            Marshal.WriteIntPtr(written, IntPtr.Zero);
            MilaNativeStatus status = SessionTerminalPollNative(terminalHandle, output, (nuint)capacity, written);
            nuint count = (nuint)Marshal.ReadIntPtr(written);
            if (status != MilaNativeStatus.Ok || count > (nuint)capacity)
                return new(status, null);
            byte[] bytes = new byte[checked((int)count)];
            Marshal.Copy(output, bytes, 0, bytes.Length);
            return new(status, bytes);
        }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable, null); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable, null); }
        finally { Marshal.FreeHGlobal(output); Marshal.FreeHGlobal(written); }
    }

    internal static MilaNativeStatus TrySessionTerminalInput(ulong terminalHandle, ReadOnlySpan<byte> input)
    {
        if (terminalHandle == 0 || input.Length > 65_536) return MilaNativeStatus.InvalidRequest;
        IntPtr buffer = Marshal.AllocHGlobal(input.Length);
        try
        {
            Marshal.Copy(input.ToArray(), 0, buffer, input.Length);
            return SessionTerminalInputNative(terminalHandle, buffer, (nuint)input.Length);
        }
        catch (DllNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (EntryPointNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (BadImageFormatException) { return MilaNativeStatus.Unavailable; }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    internal static MilaNativeStatus TrySessionTerminalResize(ulong terminalHandle, ushort columns, ushort rows)
    {
        if (terminalHandle == 0 || columns is 0 or > 4096 || rows is 0 or > 512) return MilaNativeStatus.InvalidRequest;
        try { return SessionTerminalResizeNative(terminalHandle, columns, rows); }
        catch (DllNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (EntryPointNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (BadImageFormatException) { return MilaNativeStatus.Unavailable; }
    }

    internal static MilaNativeStatus TrySessionTerminalKill(ulong terminalHandle)
    {
        if (terminalHandle == 0) return MilaNativeStatus.InvalidRequest;
        try { return SessionTerminalKillNative(terminalHandle); }
        catch (DllNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (EntryPointNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (BadImageFormatException) { return MilaNativeStatus.Unavailable; }
    }

    /// <summary>Validates an opaque Susan push poke before waking the UI.</summary>
    internal static unsafe MilaNativePokeResult TryValidatePushPoke(
        ReadOnlySpan<byte> envelope, ulong now)
    {
        fixed (byte* bytes = envelope)
        {
            try { return new(PushPokeNative((IntPtr)bytes, (nuint)envelope.Length, now)); }
            catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
            catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
            catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
        }
    }

    /// <summary>Validates WNS channel metadata without retaining the bearer URI.</summary>
    internal static MilaNativeStatus TryValidateWindowsPushRegistration(
        string channelUri, string appId, string deployment)
    {
        ArgumentNullException.ThrowIfNull(channelUri);
        ArgumentNullException.ThrowIfNull(appId);
        ArgumentNullException.ThrowIfNull(deployment);
        if (channelUri.Contains('\0') || appId.Contains('\0') || deployment.Contains('\0'))
            return MilaNativeStatus.InvalidRequest;
        IntPtr token = Marshal.StringToCoTaskMemUTF8(channelUri);
        IntPtr application = Marshal.StringToCoTaskMemUTF8(appId);
        IntPtr host = Marshal.StringToCoTaskMemUTF8(deployment);
        try
        {
            return (MilaNativeStatus)PushRegistrationNative(2, 1, token, application, host, token);
        }
        catch (DllNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (EntryPointNotFoundException) { return MilaNativeStatus.Unavailable; }
        catch (BadImageFormatException) { return MilaNativeStatus.Unavailable; }
        finally
        {
            Marshal.FreeCoTaskMem(token);
            Marshal.FreeCoTaskMem(application);
            Marshal.FreeCoTaskMem(host);
        }
    }

    private static MilaNativeTerminalResult TryTerminal(Func<MilaNativeStatus> call)
    {
        try { return new(call()); }
        catch (DllNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (EntryPointNotFoundException) { return new(MilaNativeStatus.Unavailable); }
        catch (BadImageFormatException) { return new(MilaNativeStatus.Unavailable); }
    }

    [LibraryImport(LibraryName, EntryPoint = "mila_snapshot_machine_actions")]
    private static partial MilaNativeStatus MachineActionsNative(
        IntPtr bytes, nuint length, IntPtr host, ushort port, byte hasPort,
        uint index, out MilaMachineActions actions);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_command_format")]
    private static partial MilaNativeStatus MachineCommandNative(
        IntPtr action, IntPtr machineId, IntPtr requestId, MilaRouteOutput output);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_machine_action")]
    private static partial int SessionMachineActionNative(ulong handle, IntPtr machine, nuint machineLength,
        IntPtr action, nuint actionLength, IntPtr requestId, nuint requestIdLength);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_machine_create")]
    private static partial int SessionMachineCreateNative(ulong handle, IntPtr name, nuint nameLength, uint cpu, ulong memory, ulong disk, IntPtr requestId, nuint requestIdLength);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_machine_resize")]
    private static partial int SessionMachineResizeNative(ulong handle, IntPtr machine, nuint machineLength,
        uint cpu, ulong memory, ulong disk, IntPtr requestId, nuint requestIdLength);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_share_mutation")]
    private static partial int SessionShareMutationNative(ulong handle, IntPtr machine, nuint machineLength,
        IntPtr email, nuint emailLength, IntPtr role, nuint roleLength, byte add,
        IntPtr requestId, nuint requestIdLength);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_web_show")]
    private static partial MilaNativeStatus SessionWebShowNative(ulong handle, IntPtr machine, nuint machineLength,
        IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_web_set")]
    private static partial int SessionWebSetNative(ulong handle, IntPtr machine, nuint machineLength,
        ushort port, byte isPublic, ulong revision, IntPtr requestId, nuint requestIdLength);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_ssh_keys")]
    private static partial MilaNativeStatus SessionSshKeysNative(
        ulong handle, IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_device_ls")]
    private static partial MilaNativeStatus SessionDevicesNative(ulong handle, IntPtr output, nuint capacity, IntPtr written);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_device_rm")]
    private static partial MilaNativeStatus SessionDeviceRemoveNative(ulong handle, IntPtr device, nuint length);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_device_prefs")]
    private static partial MilaNativeStatus SessionDevicePreferencesNative(ulong handle, IntPtr device, nuint length, byte enabled);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_listing")]
    private static partial MilaNativeStatus SessionListingNative(
        ulong handle, IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_thread_action")]
    private static partial MilaNativeStatus SessionThreadActionNative(
        ulong handle, IntPtr thread, nuint threadLength, IntPtr command, nuint commandLength,
        IntPtr secondary, nuint secondaryLength, IntPtr input, nuint inputLength,
        IntPtr requestId, nuint requestIdLength, IntPtr output, nuint capacity, IntPtr written);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_ssh_key_revoke")]
    private static partial MilaNativeStatus SessionSshKeyRevokeNative(
        ulong handle, IntPtr key, nuint keyLength, IntPtr request, nuint requestLength);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_close")]
    private static partial int SessionCloseNative(ulong handle);

    [DllImport(LibraryName, EntryPoint = "mila_session_connect", CallingConvention = CallingConvention.Cdecl)]
    private static extern MilaNativeStatus SessionConnectNative(
        IntPtr trust, nuint trustLength, [MarshalAs(UnmanagedType.LPUTF8Str)] string host,
        nuint hostLength, IntPtr publicKey, nuint publicKeyLength, ushort port, uint timeoutMs,
        MilaSignCallback callback, nuint context, out ulong handle);

    private const int RouteOutputCapacity = 4096;

    [LibraryImport(LibraryName, EntryPoint = "mila_ffi_get_version")]
    private static partial MilaNativeStatus GetVersionNative(
        out MilaNativeVersion version);

    [LibraryImport(LibraryName, EntryPoint = "mila_route_format")]
    private static partial MilaNativeStatus FormatRouteNative(
        IntPtr input,
        MilaRouteOutput output);

    [LibraryImport(LibraryName, EntryPoint = "mila_trust_document_reconcile")]
    private static unsafe partial MilaNativeStatus TrustReconcileNative(
        IntPtr pinned, nuint pinnedLength, IntPtr fetched, nuint fetchedLength,
        IntPtr host, ulong now, MilaRouteOutput output);

    [LibraryImport(LibraryName, EntryPoint = "mila_thread_command_kind")]
    private static partial MilaNativeStatus ThreadCommandKindNative(
        IntPtr line, out MilaThreadCommandKind kind);
    [LibraryImport(LibraryName, EntryPoint = "mila_machine_command_kind")]
    private static partial MilaNativeStatus MachineCommandKindNative(IntPtr line, out MilaMachineCommandKind kind);

    [LibraryImport(LibraryName, EntryPoint = "mila_terminal_attach_validate")]
    private static partial MilaNativeStatus TerminalAttachNative(
        ulong from, ushort columns, ushort rows, byte readWrite);

    [LibraryImport(LibraryName, EntryPoint = "mila_terminal_input_validate")]
    private static partial MilaNativeStatus TerminalInputNative(nuint length, byte readWrite);

    [LibraryImport(LibraryName, EntryPoint = "mila_terminal_resize_validate")]
    private static partial MilaNativeStatus TerminalResizeNative(
        ushort columns, ushort rows, byte readWrite);

    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_poll")]
    private static partial MilaNativeStatus SessionTerminalPollNative(
        ulong terminalHandle, IntPtr output, nuint capacity, IntPtr written);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_input")]
    private static partial MilaNativeStatus SessionTerminalInputNative(
        ulong terminalHandle, IntPtr input, nuint inputLength);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_resize")]
    private static partial MilaNativeStatus SessionTerminalResizeNative(
        ulong terminalHandle, uint columns, uint rows);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_terminal_kill")]
    private static partial MilaNativeStatus SessionTerminalKillNative(ulong terminalHandle);

    [LibraryImport(LibraryName, EntryPoint = "mila_push_poke_validate")]
    private static partial MilaNativeStatus PushPokeNative(
        IntPtr envelope, nuint length, ulong now);

    [LibraryImport(LibraryName, EntryPoint = "mila_push_registration_validate")]
    private static partial MilaNativeStatus PushRegistrationNative(
        byte provider, byte environment, IntPtr token, IntPtr appId,
        IntPtr deployment, IntPtr endpoint);

    [LibraryImport(LibraryName, EntryPoint = "mila_snapshot_validate")]
    private static partial MilaNativeStatus ValidateSnapshotNative(
        IntPtr bytes, nuint length, IntPtr host, ushort port, byte hasPort,
        out MilaSnapshotSummary summary);
}
