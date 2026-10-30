using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>Persisted endpoint for one Porsche management gateway.</summary>
internal sealed record MilaDeployment(string Host, ushort Port = 22)
{
    /// <summary>Porsche's public management SSH listener.</summary>
    internal const ushort DefaultPort = 22;

    /// <summary>
    /// Backward-compatible normalization for deployment.json files written by
    /// the host-only schema. A missing numeric property can deserialize as zero;
    /// zero is never a valid session port, so it maps to Porsche's default.
    /// </summary>
    internal MilaDeployment Normalize()
        => Port == 0 ? this with { Port = DefaultPort } : this;
}

/// <summary>Durable deployment list used by the picker.</summary>
internal interface IMilaDeploymentRepository
{
    IReadOnlyList<MilaDeployment> LoadAll();
    void Save(MilaDeployment deployment);
    bool Forget(MilaDeployment deployment);
}

/// <summary>
/// JSON file repository. Malformed or invalid entries are dropped on load so a
/// damaged file cannot introduce an unvalidated host into the picker.
/// </summary>
internal sealed class MilaDeploymentFileRepository(string path) : IMilaDeploymentRepository
{
    internal const int MaxDeployments = 64;
    private const int MaxFileBytes = 64 * 1024;

    internal static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mila", "deployment.json");

    public IReadOnlyList<MilaDeployment> LoadAll()
    {
        try
        {
            FileInfo info = new(path);
            if (!info.Exists || info.Length > MaxFileBytes) return Array.Empty<MilaDeployment>();
            string json = File.ReadAllText(path);
            IEnumerable<MilaDeployment>? loaded = null;
            try { loaded = JsonSerializer.Deserialize<List<MilaDeployment>>(json); }
            catch (JsonException) { }
            if (loaded is null && JsonSerializer.Deserialize<MilaDeployment>(json) is { } one) loaded = [one];
            return (loaded ?? Enumerable.Empty<MilaDeployment>())
                .Where(static deployment => deployment is not null)
                .Select(static deployment => deployment.Normalize())
                .Where(static deployment => MilaDeploymentHost.IsCanonical(deployment.Host))
                .Distinct()
                .Take(MaxDeployments)
                .ToArray();
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (JsonException) { }
        return Array.Empty<MilaDeployment>();
    }

    public void Save(MilaDeployment deployment)
    {
        ArgumentNullException.ThrowIfNull(deployment);
        deployment = deployment.Normalize();
        if (!MilaDeploymentHost.IsCanonical(deployment.Host))
            throw new ArgumentException("deployment host is not canonical", nameof(deployment));
        List<MilaDeployment> deployments = LoadAll().Where(existing => existing != deployment).Append(deployment)
            .TakeLast(MaxDeployments).ToList();
        Write(deployments);
    }

    public bool Forget(MilaDeployment deployment)
    {
        ArgumentNullException.ThrowIfNull(deployment);
        IReadOnlyList<MilaDeployment> current = LoadAll();
        List<MilaDeployment> remaining = current.Where(existing => existing != deployment).ToList();
        if (remaining.Count == current.Count) return false;
        Write(remaining);
        return true;
    }

    private void Write(IReadOnlyList<MilaDeployment> deployments)
    {
        string? directory = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(directory)) throw new IOException("deployment directory unavailable");
        Directory.CreateDirectory(directory);
        string temporary = path + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(deployments));
        File.Move(temporary, path, true);
    }
}

/// <summary>Compatibility facade over the default per-user repository.</summary>
internal static class MilaDeploymentStore
{
    private static readonly MilaDeploymentFileRepository Default = new(MilaDeploymentFileRepository.DefaultPath);
    internal static IMilaDeploymentRepository Repository => Default;
    internal static MilaDeployment? Load() => LoadAll().FirstOrDefault();
    internal static IReadOnlyList<MilaDeployment> LoadAll() => Default.LoadAll();
    internal static void Save(MilaDeployment deployment) => Default.Save(deployment);
    internal static bool Forget(MilaDeployment deployment) => Default.Forget(deployment);
}

/// <summary>Canonical deployment host grammar shared with Rust's `validate_host`.</summary>
internal static class MilaDeploymentHost
{
    /// <summary>
    /// Lower-case DNS labels only: no scheme, port, path, IP literal or trailing
    /// dot. Single-label names are refused except <c>localhost</c>, which the
    /// hermetic loopback journey fixture uses.
    /// </summary>
    internal static bool IsCanonical(string? host)
    {
        if (string.IsNullOrEmpty(host) || host.Length > 253) return false;
        string[] labels = host.Split('.');
        if (labels.Length < 2 && host != "localhost") return false;
        if (labels.All(label => label.Length > 0 && label.All(char.IsAsciiDigit))) return false;
        return labels.All(label => label.Length is >= 1 and <= 63 && label[0] != '-' && label[^1] != '-' &&
            label.All(character => character is >= 'a' and <= 'z' or >= '0' and <= '9' or '-'));
    }

    /// <summary>Canonicalizes operator input by trimming and lower-casing; never guesses a scheme or port.</summary>
    internal static string? Canonicalize(string? input)
    {
        if (input is null || input.Length > 253) return null;
        string trimmed = input.Trim();
        // Lower-case only ASCII so compatibility characters (for example the
        // Kelvin sign) cannot fold into a different ASCII host.
        if (!trimmed.All(char.IsAscii)) return null;
        string candidate = trimmed.ToLowerInvariant();
        return IsCanonical(candidate) ? candidate : null;
    }
}
