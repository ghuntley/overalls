using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>WNS channel obtained by the platform. The URI is a bearer capability.</summary>
internal sealed record MilaWnsChannel(string Uri, DateTimeOffset ExpiresAt);

/// <summary>Obtains a WNS channel; production uses the Windows App SDK push manager.</summary>
internal interface IMilaWnsChannelSource
{
    Task<MilaWnsChannel?> CreateChannelAsync(CancellationToken cancellationToken);
}

/// <summary>Supplies the device's X25519 poke-decryption public key (unpadded base64url, 32 bytes).</summary>
internal interface IMilaPokeKeySource
{
    string? PublicKey(string deployment);
}

/// <summary>Placeholder until Windows X25519 poke-key custody exists; registration reports KeyUnavailable.</summary>
internal sealed class MilaUnavailablePokeKeySource : IMilaPokeKeySource
{
    public string? PublicKey(string deployment) => null;
}

/// <summary>Status and body of Susan's key-issuance reply.</summary>
internal sealed record MilaSusanKeyReply(HttpStatusCode Status, byte[] Body);

/// <summary>POSTs a Rust-encoded body to Susan's `/api/push/v1/keys`.</summary>
internal interface IMilaSusanKeyClient
{
    Task<MilaSusanKeyReply> IssueAsync(byte[] body, CancellationToken cancellationToken);
}

/// <summary>HTTPS client for Susan's fixed origin with redirects disabled and bounded replies.</summary>
internal sealed class MilaSusanKeyClient(Uri origin, HttpMessageHandler? handler = null) : IMilaSusanKeyClient
{
    /// <summary>ADR-0224's fixed Susan origin.</summary>
    internal static readonly Uri DefaultOrigin = new("https://notifications.overalls.dev");
    private const int MaxReplyBytes = 4096;

    public async Task<MilaSusanKeyReply> IssueAsync(byte[] body, CancellationToken cancellationToken)
    {
        if (origin.Scheme != Uri.UriSchemeHttps || !string.IsNullOrEmpty(origin.UserInfo) || origin.AbsolutePath != "/")
            throw new InvalidOperationException("Susan origin must be a bare HTTPS origin");
        // A caller-supplied handler (for a pinned test CA) stays owned by the caller.
        using HttpClient client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false },
            disposeHandler: handler is null) { Timeout = TimeSpan.FromSeconds(15) };
        using ByteArrayContent content = new(body);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        using HttpResponseMessage response = await client.PostAsync(new Uri(origin, "/api/push/v1/keys"), content, cancellationToken);
        if (response.Content.Headers.ContentLength is > MaxReplyBytes) return new(response.StatusCode, []);
        byte[] reply = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        return new(response.StatusCode, reply.Length > MaxReplyBytes ? [] : reply);
    }
}

internal enum MilaPushRegistrationOutcome
{
    Registered,
    SignedOut,
    Stale,
    ChannelUnavailable,
    KeyUnavailable,
    InvalidChannel,
    RelayRefused,
    RelayUnregistered,
    RelayRateLimited,
    RelayUnavailable,
    DeploymentRefused,
    Protocol,
}

/// <summary>Native seams for the registration workflow; production binds Rust.</summary>
internal sealed record MilaPushRegistrationNative(
    Func<string, string, string, MilaNativeBytesResult> EncodeKeyRequest,
    Func<ulong, byte[], string, string?, ulong, MilaNativeSessionBytesResult> Register)
{
    internal static MilaPushRegistrationNative Rust => new(
        RustNative.TryEncodeWindowsPushKeyRequest,
        (handle, reply, key, label, now) => RustNative.TrySessionDeviceRegister(handle, MilaDevicePlatform.Windows, reply, key, label, now));
}

/// <summary>
/// WNS channel exchange: platform channel, Rust validation and Susan body,
/// Susan key issuance, then Porsche `device register` through the
/// authenticated Rust session. WNS delivery itself is outside this workflow.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:security;privacy] mila-windows-wns-exchange
/// The channel URI MUST pass the managed shape check and Rust validation before
/// it leaves the process, MUST be sent only to Susan's HTTPS origin, and MUST
/// NOT be retained after the exchange. Susan's reply MUST be passed to Rust,
/// which sends the push key to Porsche on stdin only. A session generation that
/// changes during any await MUST abandon the exchange without registering.
/// </remarks>
internal sealed class MilaWindowsPushRegistration
{
    internal const string AppId = "dev.overalls.mila";
    private readonly IMilaWnsChannelSource _channels;
    private readonly IMilaPokeKeySource _keys;
    private readonly IMilaSusanKeyClient _susan;
    private readonly MilaPushRegistrationNative _native;
    private readonly MilaWindowsNotificationController _controller;
    private readonly Func<ulong> _clock;

    internal MilaWindowsPushRegistration(
        IMilaWnsChannelSource channels, IMilaPokeKeySource keys, IMilaSusanKeyClient susan,
        MilaWindowsNotificationController controller, MilaPushRegistrationNative? native = null,
        Func<ulong>? clock = null)
    {
        _channels = channels;
        _keys = keys;
        _susan = susan;
        _controller = controller;
        _native = native ?? MilaPushRegistrationNative.Rust;
        _clock = clock ?? (() => (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    }

    /// <summary>The registered device identifier from Porsche's reply, if any.</summary>
    internal string? DeviceId { get; private set; }

    internal async Task<MilaPushRegistrationOutcome> RegisterAsync(
        ulong sessionHandle, string deployment, Func<ulong?> currentSession, string? label = null,
        CancellationToken cancellationToken = default)
    {
        DeviceId = null;
        // Porsche bounds labels to 64 UTF-8 bytes; an over-long localized label is omitted.
        if (label is not null && System.Text.Encoding.UTF8.GetByteCount(label) is 0 or > 64) label = null;
        if (sessionHandle == 0 || currentSession() != sessionHandle) return MilaPushRegistrationOutcome.SignedOut;
        if (_keys.PublicKey(deployment) is not { Length: 43 } encKey) return MilaPushRegistrationOutcome.KeyUnavailable;
        MilaWnsChannel? channel = await _channels.CreateChannelAsync(cancellationToken);
        if (currentSession() != sessionHandle) return MilaPushRegistrationOutcome.Stale;
        if (channel is null || channel.ExpiresAt <= DateTimeOffset.FromUnixTimeSeconds((long)_clock()))
            return MilaPushRegistrationOutcome.ChannelUnavailable;
        if (_controller.Register(channel.Uri, AppId, deployment) != MilaWindowsNotificationState.Registered)
            return MilaPushRegistrationOutcome.InvalidChannel;
        MilaNativeBytesResult body = _native.EncodeKeyRequest(channel.Uri, AppId, deployment);
        channel = null;
        if (!body.Succeeded || body.Data is not { } request) return MilaPushRegistrationOutcome.InvalidChannel;
        MilaSusanKeyReply reply;
        try { reply = await _susan.IssueAsync(request, cancellationToken); }
        catch (HttpRequestException) { return Fail(MilaPushRegistrationOutcome.RelayUnavailable); }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested) { return Fail(MilaPushRegistrationOutcome.RelayUnavailable); }
        finally { Array.Clear(request); }
        if (currentSession() != sessionHandle) { Array.Clear(reply.Body); return Fail(MilaPushRegistrationOutcome.Stale); }
        MilaPushRegistrationOutcome? relay = reply.Status switch
        {
            HttpStatusCode.Created => null,
            HttpStatusCode.BadRequest => MilaPushRegistrationOutcome.RelayRefused,
            HttpStatusCode.Gone => MilaPushRegistrationOutcome.RelayUnregistered,
            HttpStatusCode.TooManyRequests => MilaPushRegistrationOutcome.RelayRateLimited,
            _ => MilaPushRegistrationOutcome.RelayUnavailable,
        };
        if (relay is { } refused) { Array.Clear(reply.Body); return Fail(refused); }
        MilaNativeSessionBytesResult registered = await Task.Run(
            () => _native.Register(sessionHandle, reply.Body, encKey, label, _clock()), CancellationToken.None);
        Array.Clear(reply.Body);
        if (currentSession() != sessionHandle) return Fail(MilaPushRegistrationOutcome.Stale);
        if (!registered.Succeeded || registered.Data is not { } result)
            return Fail(registered.Status == MilaNativeStatus.InvalidRequest
                ? MilaPushRegistrationOutcome.DeploymentRefused : MilaPushRegistrationOutcome.Protocol);
        DeviceId = DecodeDeviceId(result);
        return DeviceId is null ? Fail(MilaPushRegistrationOutcome.Protocol) : MilaPushRegistrationOutcome.Registered;
    }

    private MilaPushRegistrationOutcome Fail(MilaPushRegistrationOutcome outcome)
    {
        _controller.Disable();
        return outcome;
    }

    /// <summary>Reads `result.id` from Porsche's registration receipt.</summary>
    internal static string? DecodeDeviceId(ReadOnlySpan<byte> bytes)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
            return document.RootElement.TryGetProperty("result", out JsonElement result) &&
                result.ValueKind == JsonValueKind.Object &&
                result.TryGetProperty("id", out JsonElement id) && id.ValueKind == JsonValueKind.String &&
                Guid.TryParseExact(id.GetString(), "D", out Guid parsed)
                    ? parsed.ToString("D") : null;
        }
        catch (JsonException) { return null; }
    }
}
