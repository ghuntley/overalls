using System.Text.Json;

namespace Mila.Windows.Interop;

internal readonly record struct MilaWebEndpoint(Guid MachineId, ushort Port, bool IsPublic, ulong Revision, Uri? Url);

internal static class MilaWebEndpointDecoder
{
    /// <summary>
    /// @cc [owner:ghuntley,label:security] windows-web-endpoint-origin-input
    /// A web endpoint URL MUST be an HTTPS URL with a canonical ASCII DNS host,
    /// no credentials or fragment, and an explicit port only when it matches
    /// the authenticated endpoint port. This validation runs before assigning
    /// the URL to WebView2, because navigation fencing cannot protect the
    /// initial navigation if the decoded origin is already unsafe.
    /// </summary>
    internal static MilaWebEndpoint Decode(ReadOnlySpan<byte> bytes, Guid expectedMachine)
    {
        try
        {
            return DecodeCore(bytes, expectedMachine);
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException or OverflowException)
        {
            throw new InvalidDataException("web response", error);
        }
    }

    private static MilaWebEndpoint DecodeCore(ReadOnlySpan<byte> bytes, Guid expectedMachine)
    {
        try
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
                if (urlValue.ValueKind != JsonValueKind.String)
                    throw new InvalidDataException("web URL");
                string? rawUrl = urlValue.GetString();
                if (rawUrl is null or { Length: > 2048 } ||
                    !Uri.TryCreate(rawUrl, UriKind.Absolute, out Uri? parsed) ||
                    parsed.Scheme != Uri.UriSchemeHttps ||
                    !string.IsNullOrEmpty(parsed.UserInfo) ||
                    !string.IsNullOrEmpty(parsed.Fragment) ||
                    !CanonicalDnsHost(parsed.Host) ||
                    !ExplicitPortMatchesEndpoint(rawUrl, parsed, port))
                    throw new InvalidDataException("web URL");
                url = parsed;
            }
            return new(machine, (ushort)port, visibility == "public", revision, url);
        }
        catch (InvalidDataException) { throw; }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        {
            throw new InvalidDataException("invalid web response", error);
        }
    }

    private static bool CanonicalDnsHost(string host)
    {
        if (host.Length is 0 or > 253) return false;
        string[] labels = host.Split('.', StringSplitOptions.None);
        return labels.All(label => label.Length is > 0 and <= 63 &&
            label[0] != '-' && label[^1] != '-' &&
            label.All(character => (character is >= 'a' and <= 'z') ||
                (character is >= 'A' and <= 'Z') ||
                (character is >= '0' and <= '9') || character == '-'));
    }

    private static bool ExplicitPortMatchesEndpoint(string rawUrl, Uri parsed, int expectedPort)
    {
        int authorityStart = Uri.UriSchemeHttps.Length + Uri.SchemeDelimiter.Length;
        int authorityEnd = rawUrl.IndexOfAny(['/','?', '#'], authorityStart);
        if (authorityEnd < 0) authorityEnd = rawUrl.Length;
        string authority = rawUrl[authorityStart..authorityEnd];
        if (authority == parsed.Host) return true;
        return authority == $"{parsed.Host}:{expectedPort}" && parsed.Port == expectedPort;
    }
}
