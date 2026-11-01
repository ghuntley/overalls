using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>One grant from `share show MACHINE --json`.</summary>
internal sealed record MilaShareGrant(string Email, string Role);

/// <summary>`show MACHINE --json`: requested state and size.</summary>
internal sealed record MilaMachineDetail(Guid Id, string DesiredState, uint? Vcpu, ulong? MemoryBytes)
{
    internal ulong? MemoryMib => MemoryBytes / (1024 * 1024);
}

/// <summary>
/// @cc [owner:ghuntley,label:protocol] mila-windows-session-reads
/// Share, machine, request and terminal-end reads MUST be decoded from Porsche's
/// result (a version-1 envelope is unwrapped only when succeeded or accepted),
/// within fixed bounds, and refuse any other shape. A request is admitted only
/// when its receipt status is accepted or succeeded.
/// </summary>
internal static class MilaSessionReads
{
    private const int MaxBytes = 256 * 1024;

    private static JsonDocument Parse(ReadOnlySpan<byte> bytes) =>
        bytes.Length is 0 or > MaxBytes ? throw new InvalidDataException("session read bounds") : JsonDocument.Parse(bytes.ToArray());

    /// <summary>`share show MACHINE --json`: the owner and every grant, as the Linux decoder bounds them.</summary>
    internal static IReadOnlyList<MilaShareGrant> DecodeShares(ReadOnlySpan<byte> bytes)
    {
        using JsonDocument document = Parse(bytes);
        JsonElement result = MilaPorscheEnvelope.Result(document.RootElement);
        if (result.ValueKind != JsonValueKind.Object ||
            !result.TryGetProperty("owner", out JsonElement owner) || owner.ValueKind != JsonValueKind.Object ||
            !owner.TryGetProperty("email", out JsonElement ownerEmail) || !Email(ownerEmail) ||
            !result.TryGetProperty("items", out JsonElement items) ||
            items.ValueKind != JsonValueKind.Array || items.GetArrayLength() > 512)
            throw new InvalidDataException("share listing");
        List<MilaShareGrant> grants = new(items.GetArrayLength());
        HashSet<string> ids = new(StringComparer.Ordinal);
        foreach (JsonElement item in items.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object ||
                !item.TryGetProperty("id", out JsonElement id) || !Text(id, 128) || !ids.Add(id.GetString()!) ||
                !item.TryGetProperty("user_id", out JsonElement user) || !Text(user, 128) ||
                !item.TryGetProperty("email", out JsonElement email) || !Email(email) ||
                !item.TryGetProperty("role", out JsonElement role) || role.GetString() is not ("viewer" or "operator" or "manager"))
                throw new InvalidDataException("share grant");
            grants.Add(new(email.GetString()!, role.GetString()!));
        }
        return grants;
    }

    private static bool Text(JsonElement value, int max) =>
        value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text &&
        System.Text.Encoding.UTF8.GetByteCount(text) <= max && !text.Any(char.IsControl);

    private static bool Email(JsonElement value) =>
        value.ValueKind == JsonValueKind.String && value.GetString() is { } text &&
        System.Text.Encoding.UTF8.GetByteCount(text) is >= 3 and <= 320 && text.Contains('@') &&
        !text.Any(c => c == '\0' || char.IsWhiteSpace(c));

    internal static MilaMachineDetail DecodeMachine(ReadOnlySpan<byte> bytes, Guid expected)
    {
        using JsonDocument document = Parse(bytes);
        JsonElement result = MilaPorscheEnvelope.Result(document.RootElement);
        if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("id", out JsonElement id) ||
            !Guid.TryParseExact(id.GetString(), "D", out Guid machine) || machine != expected ||
            !result.TryGetProperty("desired_state", out JsonElement desired) || desired.GetString() is not { Length: > 0 and <= 32 } state)
            throw new InvalidDataException("machine detail");
        uint? vcpu = result.TryGetProperty("vcpu", out JsonElement cpu) && cpu.ValueKind == JsonValueKind.Number &&
            cpu.TryGetUInt32(out uint count) ? count : null;
        ulong? memory = result.TryGetProperty("memory_bytes", out JsonElement bytesValue) && bytesValue.ValueKind == JsonValueKind.Number &&
            bytesValue.TryGetUInt64(out ulong size) ? size : null;
        return new(machine, state, vcpu, memory);
    }

    /// <summary>The receipt from `request show ID --json` reports an accepted or succeeded mutation.</summary>
    internal static bool RequestAdmitted(ReadOnlySpan<byte> bytes)
    {
        using JsonDocument document = Parse(bytes);
        JsonElement root = document.RootElement;
        static bool Admitted(JsonElement value) =>
            value.ValueKind == JsonValueKind.Object && value.TryGetProperty("status", out JsonElement status) &&
            status.GetString() is "accepted" or "succeeded";
        // The Linux journey rule: the receipt's own status, or its `result`'s.
        return Admitted(root) || (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("result", out JsonElement result) && Admitted(result));
    }

    /// <summary>`terminal kill MACHINE SESSION --json` reports the named session closed.</summary>
    internal static bool TerminalClosed(ReadOnlySpan<byte> bytes, string terminalId)
    {
        using JsonDocument document = Parse(bytes);
        JsonElement result = MilaPorscheEnvelope.Result(document.RootElement);
        return result.ValueKind == JsonValueKind.Object &&
            result.TryGetProperty("session_id", out JsonElement session) && session.GetString() == terminalId &&
            result.TryGetProperty("closed", out JsonElement closed) && closed.ValueKind == JsonValueKind.True;
    }
}
