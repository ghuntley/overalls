using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>
/// @cc [owner:ghuntley,label:protocol] mila-windows-porsche-envelope
/// Porsche's `--json` output is a version-1 envelope. Its <c>result</c> object MUST
/// be read only when the version is 1 and the status is succeeded or accepted;
/// any other envelope MUST refuse. A document without version and status is
/// already a bare result.
/// </summary>
internal static class MilaPorscheEnvelope
{
    internal static JsonElement Result(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out JsonElement version) ||
            !root.TryGetProperty("status", out JsonElement status))
            return root;
        return version.ValueKind == JsonValueKind.Number && version.TryGetInt32(out int number) && number == 1 &&
            status.ValueKind == JsonValueKind.String && status.GetString() is "succeeded" or "accepted" &&
            root.TryGetProperty("result", out JsonElement result) && result.ValueKind == JsonValueKind.Object
            ? result
            : throw new InvalidDataException("Porsche result envelope");
    }
}
