using System.Runtime.InteropServices;
using System.Text.Json;
namespace Mila.Windows.Interop;

internal enum MilaWatchHint { Refresh, AuthorityLost, TransportLost }

/// <summary>One bounded watch subscription. The native protocol accepts at most 64 IDs.</summary>
internal readonly record struct MilaWatchFilters(IReadOnlyList<Guid> Machines, IReadOnlyList<Guid> Threads)
{
    private const int MaxMachines = 500;
    private const int MaxThreads = 256;
    private const int ShardSize = 64;

    /// @cc [owner:ghuntley,label:security;reliability] windows-watch-filter-sharding
    /// Each selected machine or thread ID MUST be retained within the bounded
    /// 500-machine and 256-thread windows and deterministic shards of at most 64 IDs; no
    /// native watch request may exceed the protocol filter limit.
    /// Partitions each filter kind into deterministic native-sized subscriptions.
    /// Every retained UI row is watched within its kind's bounded window.
    internal static IReadOnlyList<MilaWatchFilters> Groups(
        IReadOnlyList<Guid> machines, IReadOnlyList<Guid> threads)
    {
        static IEnumerable<Guid[]> Shards(IReadOnlyList<Guid> values, int maximum)
        {
            Guid[] bounded = values
                .Distinct()
                .OrderBy(value => value.ToString("D"), StringComparer.Ordinal)
                .Take(maximum)
                .ToArray();
            for (int offset = 0; offset < bounded.Length; offset += ShardSize)
                yield return bounded.Skip(offset).Take(ShardSize).ToArray();
        }

        List<MilaWatchFilters> groups = [];
        groups.AddRange(Shards(machines, MaxMachines).Select(shard => new MilaWatchFilters(shard, Array.Empty<Guid>())));
        groups.AddRange(Shards(threads, MaxThreads).Select(shard => new MilaWatchFilters(Array.Empty<Guid>(), shard)));
        return groups.Count == 0
            ? [new MilaWatchFilters(Array.Empty<Guid>(), Array.Empty<Guid>())]
            : groups;
    }
}

/// <summary>A worker-owned, cancellable watch; UI consumers receive hints only.</summary>
/// <remarks>
/// @cc [owner:ghuntley,label:security;reliability] windows-watch-authority
/// Watch reconnection retries only the subscription. Events are never authority;
/// refresh authenticated reads, fence callbacks by lifetime, and drop session state on revocation.
/// </remarks>
internal sealed class MilaWatchStream : IDisposable
{
    private CancellationTokenSource? _lifetime;
    internal void Start(ulong session, IReadOnlyList<Guid> machines, IReadOnlyList<Guid> threads, Action<MilaWatchHint> changed)
    {
        Stop();
        CancellationTokenSource lifetime = new();
        _lifetime = lifetime;
        CancellationToken token = lifetime.Token;
        foreach (MilaWatchFilters filter in MilaWatchFilters.Groups(machines, threads))
        {
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new { machines = filter.Machines, threads = filter.Threads });
            _ = Task.Run(() => Run(session, bytes, changed, token));
        }
    }
    internal void Stop() { _lifetime?.Cancel(); _lifetime = null; }
    public void Dispose() => Stop();
    private static void Run(ulong session, byte[] filters, Action<MilaWatchHint> changed, CancellationToken cancellation)
    {
        ulong watch = 0;
        void Report(MilaWatchHint hint) { if (!cancellation.IsCancellationRequested) changed(hint); }
        try
        {
            MilaNativeStatus status = RustNative.OpenWatch(session, filters, out watch);
            while (status == MilaNativeStatus.Busy && !cancellation.IsCancellationRequested)
            {
                cancellation.WaitHandle.WaitOne(100);
                status = RustNative.OpenWatch(session, filters, out watch);
            }
            if (status != MilaNativeStatus.Ok) { Report(MilaWatchHint.TransportLost); return; }
            while (!cancellation.IsCancellationRequested)
            {
                (status, byte kind, byte[] bytes) = RustNative.ReadWatch(watch);
                if (cancellation.IsCancellationRequested) break;
                if (status == MilaNativeStatus.Busy) { cancellation.WaitHandle.WaitOne(50); continue; }
                if (status != MilaNativeStatus.Ok) { Report(MilaWatchHint.TransportLost); break; }
                switch (kind)
                {
                    case 0:
                        if (NeedsRefresh(bytes)) Report(MilaWatchHint.Refresh);
                        break;
                    case 1: break;
                    case 3: Report(MilaWatchHint.AuthorityLost); return;
                    case 2: case 4:
                        status = RustNative.ReconnectWatch(watch, out ulong replacement);
                        if (status != MilaNativeStatus.Ok) { Report(MilaWatchHint.TransportLost); return; }
                        watch = replacement;
                        Report(MilaWatchHint.Refresh);
                        break;
                    default: Report(MilaWatchHint.TransportLost); return;
                }
            }
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or JsonException or InvalidDataException)
        { Report(MilaWatchHint.TransportLost); }
        finally { if (watch != 0) RustNative.CloseWatch(watch); }
    }
    internal static bool NeedsRefresh(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > 8192) throw new InvalidDataException("watch bounds");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("version", out JsonElement version) ||
            !version.TryGetInt32(out int value) || value != 1 ||
            !root.TryGetProperty("event", out JsonElement eventValue) ||
            eventValue.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("watch notice");
        return eventValue.GetString() is "machine" or "thread" or "terminal_session" or "resync" or "session";
    }
}

internal static partial class RustNative
{
    internal static unsafe MilaNativeStatus OpenWatch(ulong parent, byte[] filters, out ulong watch)
    {
        fixed (byte* input = filters) return (MilaNativeStatus)WatchOpenNative(parent, input, (nuint)filters.Length, out watch);
    }
    internal static unsafe (MilaNativeStatus Status, byte Kind, byte[] Data) ReadWatch(ulong watch)
    {
        byte[] output = new byte[8192];
        fixed (byte* buffer = output)
        {
            MilaNativeStatus status = (MilaNativeStatus)WatchReadNative(watch, 250, buffer, (nuint)output.Length, out nuint written, out byte kind);
            if (written > (nuint)output.Length) throw new InvalidDataException("watch output bounds");
            return (status, kind, output.AsSpan(0, checked((int)written)).ToArray());
        }
    }
    internal static MilaNativeStatus ReconnectWatch(ulong watch, out ulong replacement) => (MilaNativeStatus)WatchReconnectNative(watch, out replacement);
    internal static void CloseWatch(ulong watch)
    {
        try { _ = WatchCloseNative(watch); }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { }
    }
    [LibraryImport(LibraryName, EntryPoint = "mila_session_watch_open")]
    private static unsafe partial int WatchOpenNative(ulong parent, byte* filters, nuint length, out ulong watch);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_watch_read_within")]
    private static unsafe partial int WatchReadNative(ulong watch, uint wait, byte* output, nuint capacity, out nuint written, out byte kind);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_watch_reconnect")]
    private static partial int WatchReconnectNative(ulong watch, out ulong replacement);
    [LibraryImport(LibraryName, EntryPoint = "mila_session_watch_close")]
    private static partial int WatchCloseNative(ulong watch);
}
