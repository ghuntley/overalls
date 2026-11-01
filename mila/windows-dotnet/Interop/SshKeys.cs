using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Mila.Windows.Interop;

internal sealed record MilaSshKey(Guid Id, string Fingerprint, string Algorithm, string? Label, bool IsCurrentDevice)
{
    /// <summary>Localized note shown beside the fingerprint (this device, and its key custody).</summary>
    internal string? Note { get; init; }

    /// <summary>The row text bound by the SSH key list.</summary>
    /// <remarks>The fingerprint is bidi-isolated so the row reads correctly in right-to-left locales.</remarks>
    public string Display => Note is null ? Fingerprint : "\u2068" + Fingerprint + "\u2069 \u00b7 " + Note;
}
internal enum MilaSshKeysStatus { SignedOut, Loading, Loaded, Failed }

internal sealed class MilaSshKeysController
{
    private readonly Func<CancellationToken, Task<IReadOnlyList<MilaSshKey>>> loader;
    private readonly Func<Guid, CancellationToken, Task> revoker;
    private long loadGeneration;
    private int signedIn;
    private readonly HashSet<Guid> revokedIds = new();
    internal MilaSshKeysStatus Status { get; private set; } = MilaSshKeysStatus.SignedOut;
    internal IReadOnlyList<MilaSshKey> Keys { get; private set; } = Array.Empty<MilaSshKey>();

    internal MilaSshKeysController(Func<CancellationToken, Task<IReadOnlyList<MilaSshKey>>> loader, Func<Guid, CancellationToken, Task> revoker)
    { this.loader = loader; this.revoker = revoker; }

    /// <summary>
    /// @cc [owner:ghuntley,label:reliability;security] mila-windows-ssh-key-load-generation
    /// A listing response may update the view only while its session generation is
    /// current; a signed-out or superseded request MUST NOT restore stale keys.
    /// </summary>
    internal Task LoadAsync(bool signedIn, CancellationToken cancellationToken = default) =>
        LoadAsync(signedIn, cancellationToken, null);

    private async Task LoadAsync(bool signedIn, CancellationToken cancellationToken, long? expectedGeneration)
    {
        if (expectedGeneration is { } expected &&
            (expected != Volatile.Read(ref loadGeneration) || Volatile.Read(ref this.signedIn) == 0)) return;
        long generation = Interlocked.Increment(ref loadGeneration);
        Volatile.Write(ref this.signedIn, signedIn ? 1 : 0);
        if (!signedIn) { Status = MilaSshKeysStatus.SignedOut; Keys = Array.Empty<MilaSshKey>(); return; }
        Status = MilaSshKeysStatus.Loading;
        try
        {
            IReadOnlyList<MilaSshKey> keys = await loader(cancellationToken);
            if (generation != Volatile.Read(ref loadGeneration)) return;
            Keys = keys; Status = MilaSshKeysStatus.Loaded;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (generation == Volatile.Read(ref loadGeneration)) Status = MilaSshKeysStatus.Loaded;
        }
        catch
        {
            if (generation == Volatile.Read(ref loadGeneration)) Status = MilaSshKeysStatus.Failed;
        }
    }

    internal async Task RevokeAsync(MilaSshKey key, CancellationToken cancellationToken = default)
    {
        if (Status != MilaSshKeysStatus.Loaded || key.IsCurrentDevice) return;
        lock (revokedIds)
        {
            if (!revokedIds.Add(key.Id)) return;
        }
        long generation = Volatile.Read(ref loadGeneration);
        try
        {
            await revoker(key.Id, cancellationToken);
            if (generation != Volatile.Read(ref loadGeneration) || Volatile.Read(ref signedIn) == 0) return;
            await LoadAsync(true, cancellationToken, generation);
        }
        catch
        {
            if (generation == Volatile.Read(ref loadGeneration) && Volatile.Read(ref signedIn) != 0)
                Status = MilaSshKeysStatus.Failed;
        }
    }

    internal static IReadOnlyList<MilaSshKey> DecodeListing(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > 256 * 1024) throw new InvalidDataException("SSH key listing too large");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        // `ssh-key list --json` answers in Porsche's version-1 envelope.
        JsonElement body = MilaPorscheEnvelope.Result(document.RootElement);
        if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty("keys", out JsonElement keys) ||
            keys.ValueKind != JsonValueKind.Array || keys.GetArrayLength() > 256) throw new InvalidDataException("Invalid SSH key listing");
        List<MilaSshKey> result = new(keys.GetArrayLength());
        foreach (JsonElement item in keys.EnumerateArray())
        {
            if (!Guid.TryParse(item.GetProperty("id").GetString(), out Guid id)) throw new InvalidDataException("Invalid SSH key id");
            string fingerprint = item.GetProperty("fingerprint").GetString() ?? throw new InvalidDataException("Missing fingerprint");
            string algorithm = item.GetProperty("algorithm").GetString() ?? throw new InvalidDataException("Missing algorithm");
            string? label = item.TryGetProperty("label", out JsonElement labelElement) ? labelElement.GetString() : null;
            bool current = item.TryGetProperty("current_device", out JsonElement currentElement) && currentElement.GetBoolean();
            if (fingerprint.Length is 0 or > 256 || algorithm.Length is 0 or > 64 || label?.Length > 256) throw new InvalidDataException("Invalid SSH key field");
            result.Add(new(id, fingerprint, algorithm, label, current));
        }
        return result;
    }

    /// <summary>Computes the OpenSSH SHA-256 fingerprint without retaining key material.</summary>
    internal static string? Fingerprint(string publicKey)
    {
        string[] parts = publicKey.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        try
        {
            byte[] blob = Convert.FromBase64String(parts[1]);
            byte[] digest = SHA256.HashData(blob);
            return "SHA256:" + Convert.ToBase64String(digest).TrimEnd('=');
        }
        catch (FormatException) { return null; }
    }
}
