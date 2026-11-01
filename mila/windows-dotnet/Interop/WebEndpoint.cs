using System.Text.Json;

namespace Mila.Windows.Interop;

internal readonly record struct MilaWebEndpoint(Guid MachineId, ushort Port, bool IsPublic, ulong Revision, Uri? Url);

internal static class MilaWebEndpointDecoder
{
    internal static MilaWebEndpoint Decode(ReadOnlySpan<byte> bytes, Guid expectedMachine)
    {
        if (bytes.Length is 0 or > 64 * 1024) throw new InvalidDataException("web response bounds");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = MilaPorscheEnvelope.Result(document.RootElement);
        if (!root.TryGetProperty("machine_id", out JsonElement idValue) ||
            !Guid.TryParseExact(idValue.GetString(), "D", out Guid machine) || machine != expectedMachine)
            throw new InvalidDataException("web machine mismatch");
        int port = root.GetProperty("port").GetInt32();
        ulong revision = root.GetProperty("policy_revision").GetUInt64();
        if (port is < 1 or > 65535 || revision == 0) throw new InvalidDataException("web policy bounds");
        string visibility = root.GetProperty("visibility").GetString() ?? string.Empty;
        if (visibility is not ("public" or "private")) throw new InvalidDataException("web visibility");
        Uri? url = null;
        if (root.TryGetProperty("url", out JsonElement urlValue) && urlValue.ValueKind != JsonValueKind.Null)
        {
            if (!Uri.TryCreate(urlValue.GetString(), UriKind.Absolute, out Uri? parsed) || parsed.Scheme != Uri.UriSchemeHttps)
                throw new InvalidDataException("web URL");
            url = parsed;
        }
        return new(machine, (ushort)port, visibility == "public", revision, url);
    }
}
