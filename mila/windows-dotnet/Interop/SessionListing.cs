using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>Bounded, typed projection of the Rust live-session listing.</summary>
internal sealed record MilaMachineRow(
    Guid Id,
    string Name,
    string DesiredState,
    string? ObservedState,
    bool Pinned,
    bool CanRead,
    bool CanWrite,
    bool CanManage);

internal sealed record MilaSessionListing(IReadOnlyList<MilaMachineRow> Machines, bool HasMore)
{
    internal const int MaxBytes = 8 * 1024 * 1024;
    internal const int MaxMachines = 500;

    internal static MilaSessionListing Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaxBytes) throw new InvalidDataException("listing exceeds bound");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("machines", out JsonElement rows) ||
            rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > MaxMachines)
            throw new InvalidDataException("invalid machine listing");
        List<MilaMachineRow> machines = new(rows.GetArrayLength());
        foreach (JsonElement row in rows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("id", out JsonElement idElement) ||
                idElement.ValueKind != JsonValueKind.String || !Guid.TryParseExact(idElement.GetString(), "D", out Guid id))
                throw new InvalidDataException("invalid machine id");
            string name = ReadString(row, "name") ?? id.ToString("D");
            string desired = ReadString(row, "desired_state") ?? "unknown";
            string? observed = ReadString(row, "observed_state");
            machines.Add(new(id, name, desired, observed,
                ReadBool(row, "pinned"), ReadBool(row, "read"), ReadBool(row, "write"), ReadBool(row, "manage")));
        }
        bool hasMore = false;
        if (root.TryGetProperty("has_more", out JsonElement more))
        {
            if (more.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                throw new InvalidDataException("invalid listing continuation");
            hasMore = more.GetBoolean();
        }
        return new(machines, hasMore);
    }

    private static string? ReadString(JsonElement row, string name) =>
        row.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static bool ReadBool(JsonElement row, string name) =>
        row.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.True;
}

internal sealed record MilaMachineRefreshResult(
    MilaNativeStatus Status, MilaSessionListing? Listing, byte[]? Snapshot);

/// <summary>
/// @cc [owner:ghuntley,label:protocol;security] mila-windows-complete-machine-refresh
/// A refresh MUST advance authenticated continuation on the same Rust session,
/// within 500 reads. A failed read MUST NOT publish a cached Rust listing or
/// create a snapshot; snapshots MUST follow only a complete successful listing.
/// </summary>
internal sealed class MilaMachineListingReader(
    Func<bool, MilaNativeStatus> read,
    Func<MilaNativeSessionBytesResult> listing,
    Func<ulong, MilaNativeSessionBytesResult> snapshot)
{
    internal static MilaMachineRefreshResult Refresh(ulong handle, ulong savedAt) =>
        new MilaMachineListingReader(
            more => RustNative.TrySessionReadMachines(handle, more),
            () => RustNative.TrySessionListing(handle),
            time => RustNative.TrySessionSnapshot(handle, time)).Refresh(savedAt);

    internal MilaMachineRefreshResult Refresh(ulong savedAt)
    {
        for (int page = 0; page < MilaSessionListing.MaxMachines; page++)
        {
            MilaNativeStatus status = read(page != 0);
            if (status != MilaNativeStatus.Ok) return new(status, null, null);
            MilaNativeSessionBytesResult result = listing();
            if (!result.Succeeded || result.Data is not { } bytes)
                return new(result.Status == MilaNativeStatus.Ok ? MilaNativeStatus.Internal : result.Status, null, null);
            MilaSessionListing decoded;
            try { decoded = MilaSessionListing.Decode(bytes); }
            catch (Exception error) when (error is InvalidDataException or JsonException)
            { return new(MilaNativeStatus.InvalidRequest, null, null); }
            if (decoded.HasMore) continue;
            MilaNativeSessionBytesResult cached = snapshot(savedAt);
            return new(MilaNativeStatus.Ok, decoded, cached.Succeeded ? cached.Data : null);
        }
        return new(MilaNativeStatus.InvalidRequest, null, null);
    }
}
