using System.Text.Json;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
namespace Mila.Windows.Interop;

internal sealed record MilaWindowsNotificationDevice(string Id, string Platform, bool Enabled);
internal enum MilaWindowsNotificationDevicesStatus { SignedOut, Loading, Loaded, Failed }

internal sealed class MilaWindowsNotificationDevicesController
{
    private static bool ValidText(string value, int maxBytes) =>
        !string.IsNullOrWhiteSpace(value) && value.Length <= maxBytes && value.All(character => !char.IsControl(character));
    private readonly Func<CancellationToken, Task<IReadOnlyList<MilaWindowsNotificationDevice>>> load;
    private readonly Func<string, CancellationToken, Task> remove;
    private readonly Func<string, bool, CancellationToken, Task> preferences;
    private long generation;
    private bool signedIn;
    internal MilaWindowsNotificationDevicesStatus Status { get; private set; } = MilaWindowsNotificationDevicesStatus.SignedOut;
    internal IReadOnlyList<MilaWindowsNotificationDevice> Devices { get; private set; } = Array.Empty<MilaWindowsNotificationDevice>();
    internal MilaWindowsNotificationDevicesController(
        Func<CancellationToken, Task<IReadOnlyList<MilaWindowsNotificationDevice>>> load,
        Func<string, CancellationToken, Task> remove,
        Func<string, bool, CancellationToken, Task> preferences) { this.load = load; this.remove = remove; this.preferences = preferences; }

    internal async Task LoadAsync(bool signedIn, CancellationToken cancellationToken = default)
    {
        long current = Interlocked.Increment(ref generation);
        this.signedIn = signedIn;
        if (!signedIn) { Devices = Array.Empty<MilaWindowsNotificationDevice>(); Status = MilaWindowsNotificationDevicesStatus.SignedOut; return; }
        Status = MilaWindowsNotificationDevicesStatus.Loading;
        try { IReadOnlyList<MilaWindowsNotificationDevice> result = await load(cancellationToken); if (current == Volatile.Read(ref generation)) { Devices = result; Status = MilaWindowsNotificationDevicesStatus.Loaded; } }
        catch { if (current == Volatile.Read(ref generation)) Status = MilaWindowsNotificationDevicesStatus.Failed; }
    }
    internal async Task RemoveAsync(MilaWindowsNotificationDevice device, CancellationToken cancellationToken = default)
    {
        long current = Volatile.Read(ref generation);
        if (Status != MilaWindowsNotificationDevicesStatus.Loaded || !signedIn || device.Id.Length == 0) return;
        await remove(device.Id, cancellationToken);
        if (current == Volatile.Read(ref generation) && signedIn) await LoadAsync(true, cancellationToken);
    }
    internal async Task SetEnabledAsync(MilaWindowsNotificationDevice device, bool enabled, CancellationToken cancellationToken = default)
    {
        long current = Volatile.Read(ref generation);
        if (Status != MilaWindowsNotificationDevicesStatus.Loaded || !signedIn || device.Id.Length == 0) return;
        await preferences(device.Id, enabled, cancellationToken);
        if (current == Volatile.Read(ref generation) && signedIn) await LoadAsync(true, cancellationToken);
    }
    internal void Invalidate(string deviceId)
    {
        if (Status != MilaWindowsNotificationDevicesStatus.Loaded || string.IsNullOrWhiteSpace(deviceId)) return;
        Devices = Devices.Where(device => !string.Equals(device.Id, deviceId, StringComparison.Ordinal)).ToArray();
    }

    internal static IReadOnlyList<MilaWindowsNotificationDevice> DecodeListing(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > 256 * 1024) throw new InvalidDataException("Notification listing too large");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid notification listing");
        // Porsche replies `{"version":1,"status":"succeeded","result":{"items":[...]}}`
        // (protocol/test/fixtures/porsche_device_results.json); the local store
        // persists the flattened `{"devices":[...]}` projection.
        JsonElement devices;
        if (root.TryGetProperty("result", out JsonElement envelope))
        {
            if (envelope.ValueKind != JsonValueKind.Object || !envelope.TryGetProperty("items", out devices))
                throw new InvalidDataException("Invalid notification listing");
        }
        else if (!root.TryGetProperty("devices", out devices))
            return Array.Empty<MilaWindowsNotificationDevice>();
        if (devices.ValueKind != JsonValueKind.Array || devices.GetArrayLength() > 256) throw new InvalidDataException("Invalid notification listing");
        List<MilaWindowsNotificationDevice> result = new(devices.GetArrayLength());
        foreach (JsonElement item in devices.EnumerateArray())
        {
            if (!item.TryGetProperty("id", out JsonElement idValue) ||
                !item.TryGetProperty("platform", out JsonElement platformValue) ||
                !item.TryGetProperty("enabled", out JsonElement enabledValue))
                throw new InvalidDataException("Incomplete notification device");
            string id = idValue.GetString() ?? throw new InvalidDataException("Missing device id");
            string platform = platformValue.GetString() ?? throw new InvalidDataException("Missing device platform");
            if (!ValidText(id, 128) || !ValidText(platform, 32)) throw new InvalidDataException("Invalid device metadata");
            if (enabledValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                throw new InvalidDataException("Invalid device enabled state");
            result.Add(new(id, platform, enabledValue.GetBoolean()));
        }
        return result;
    }
}

internal enum MilaWindowsNotificationState { Disabled, Registered, Unavailable, Invalid }

/// <summary>
/// Owns the Windows notification capability without retaining the WNS bearer URI.
/// The native runner obtains the channel; this controller only validates its metadata.
/// </summary>
internal sealed class MilaWindowsNotificationController
{
    private readonly Func<string, string, string, MilaNativeStatus> _validate;
    internal MilaWindowsNotificationState State { get; private set; } = MilaWindowsNotificationState.Disabled;
    private long generation;
    private bool signedIn;

    internal MilaWindowsNotificationController(
        Func<string, string, string, MilaNativeStatus>? validate = null)
    {
        _validate = validate ?? RustNative.TryValidateWindowsPushRegistration;
    }

    internal void SetSession(bool authenticated)
    {
        signedIn = authenticated;
        generation++;
        if (!authenticated) State = MilaWindowsNotificationState.Disabled;
    }

    /// <summary>
    /// @cc [owner:ghuntley,label:security] mila-windows-push-registration
    /// WNS channel URIs MUST be validated by Rust and MUST NOT be retained by the
    /// managed shell; failed validation MUST leave notifications disabled.
    /// </summary>
    internal MilaWindowsNotificationState Register(
        string channelUri, string appId, string deployment)
    {
        if (!signedIn)
        {
            State = MilaWindowsNotificationState.Invalid;
            return State;
        }
        if (!ValidRegistrationMetadata(channelUri, appId, deployment))
        {
            State = MilaWindowsNotificationState.Invalid;
            return State;
        }
        long current = generation;
        MilaNativeStatus status = _validate(channelUri, appId, deployment);
        if (current != generation || !signedIn)
        {
            State = MilaWindowsNotificationState.Disabled;
            return State;
        }
        State = status switch
        {
            MilaNativeStatus.Ok => MilaWindowsNotificationState.Registered,
            MilaNativeStatus.Unavailable => MilaWindowsNotificationState.Unavailable,
            _ => MilaWindowsNotificationState.Invalid,
        };
        return State;
    }

    internal void Disable() => State = MilaWindowsNotificationState.Disabled;

    private static bool ValidRegistrationMetadata(string channelUri, string appId, string deployment)
    {
        if (!ValidText(channelUri, 2048) || !ValidText(appId, 256) || !ValidText(deployment, 256))
            return false;
        if (!Uri.TryCreate(channelUri, UriKind.Absolute, out Uri? uri) || uri.Scheme != Uri.UriSchemeHttps ||
            uri.Port != 443 || string.IsNullOrEmpty(uri.AbsolutePath) || uri.AbsolutePath == "/" ||
            !Regex.IsMatch(uri.Host, "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\\.notify\\.windows\\.com$", RegexOptions.CultureInvariant) ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment) ||
            channelUri.Contains('\\') || channelUri.Contains(' '))
            return false;
        return true;
    }

    private static bool ValidText(string value, int maxBytes)
    {
        if (value.Length == 0 || Encoding.UTF8.GetByteCount(value) > maxBytes) return false;
        return value.All(character => !char.IsControl(character) && !char.IsWhiteSpace(character));
    }
}

internal sealed class MilaWindowsNotificationDeviceStore
{
    private readonly string path;
    internal MilaWindowsNotificationDeviceStore(string? path = null)
    {
        this.path = path ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mila", "notification-devices.json");
    }

    internal IReadOnlyList<MilaWindowsNotificationDevice> Load()
    {
        try
        {
            if (!File.Exists(path)) return Array.Empty<MilaWindowsNotificationDevice>();
            return MilaWindowsNotificationDevicesController.DecodeListing(File.ReadAllBytes(path));
        }
        catch (IOException) { return Array.Empty<MilaWindowsNotificationDevice>(); }
        catch (JsonException) { return Array.Empty<MilaWindowsNotificationDevice>(); }
        catch (InvalidDataException) { return Array.Empty<MilaWindowsNotificationDevice>(); }
    }

    internal void Save(IReadOnlyList<MilaWindowsNotificationDevice> devices)
    {
        if (devices.Count > 256) throw new ArgumentOutOfRangeException(nameof(devices));
        string? directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        string json = JsonSerializer.Serialize(new { devices }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        File.WriteAllText(path, json);
    }
}
