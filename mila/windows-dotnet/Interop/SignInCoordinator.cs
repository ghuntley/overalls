using System.Text.Json;
using System.Text.RegularExpressions;

namespace Mila.Windows.Interop;

/// <summary>Decoded `whoami --json` outcome.</summary>
internal abstract record MilaWhoami
{
    private MilaWhoami() { }
    internal sealed record Approved(string? Account) : MilaWhoami;
    internal sealed record Pending(string Url, string Fingerprint) : MilaWhoami;
    internal sealed record Refused(MilaSignInFailure Failure) : MilaWhoami;
    internal sealed record Invalid : MilaWhoami;
}

/// <summary>Bounded decoder for Porsche's whoami envelope.</summary>
internal static partial class MilaWhoamiDecoder
{
    internal const int MaxBytes = 64 * 1024;

    [GeneratedRegex("^SHA256:[A-Za-z0-9+/]{43}$", RegexOptions.CultureInvariant)]
    private static partial Regex Fingerprint();

    /// <summary>
    /// Accepts `succeeded`, `approval_required` and `error` envelopes with
    /// version 1. Approval links are returned unvalidated here and MUST pass
    /// <see cref="MilaApprovalInfo.TryCreate"/> against the selected deployment.
    /// </summary>
    internal static MilaWhoami Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > MaxBytes) return new MilaWhoami.Invalid();
        try
        {
            using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("version", out JsonElement version) ||
                version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out int v) || v != 1 ||
                !root.TryGetProperty("status", out JsonElement status) || status.ValueKind != JsonValueKind.String)
                return new MilaWhoami.Invalid();
            switch (status.GetString())
            {
                case "succeeded":
                    string? account = null;
                    if (root.TryGetProperty("result", out JsonElement result) && result.ValueKind == JsonValueKind.Object &&
                        result.TryGetProperty("email", out JsonElement email) && email.ValueKind == JsonValueKind.String &&
                        email.GetString() is { Length: > 0 and <= 320 } text && !text.Any(char.IsControl))
                        account = text;
                    return new MilaWhoami.Approved(account);
                case "approval_required":
                    if (root.TryGetProperty("approval_url", out JsonElement url) && url.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("fingerprint", out JsonElement fingerprint) &&
                        fingerprint.ValueKind == JsonValueKind.String &&
                        fingerprint.GetString() is { } fp && Fingerprint().IsMatch(fp) &&
                        url.GetString() is { Length: > 0 and <= 2048 } link)
                        return new MilaWhoami.Pending(link, fp);
                    return new MilaWhoami.Invalid();
                case "error":
                    string? reason = root.TryGetProperty("error", out JsonElement error) &&
                        error.ValueKind == JsonValueKind.String ? error.GetString() : null;
                    return reason switch
                    {
                        "unauthorized" or "forbidden" => new MilaWhoami.Refused(MilaSignInFailure.Refused),
                        "temporarily_unavailable" => new MilaWhoami.Refused(MilaSignInFailure.Unreachable),
                        _ => new MilaWhoami.Refused(MilaSignInFailure.Protocol),
                    };
                default:
                    return new MilaWhoami.Invalid();
            }
        }
        catch (JsonException) { return new MilaWhoami.Invalid(); }
    }
}

/// <summary>Opens a validated approval link; it never submits credentials.</summary>
internal interface IMilaApprovalBrowser
{
    Task<bool> OpenAsync(MilaApprovalInfo approval, CancellationToken cancellationToken);
}

/// <summary>Everything one Rust session connect needs. The signer stays in OS custody.</summary>
internal sealed record MilaSignInTarget(
    string Host, ushort SshPort, ushort HttpsPort, byte[] Trust, byte[] PublicKey, Func<byte[], byte[]> Signer);

/// <summary>Timing policy; tests shorten it, production uses the defaults.</summary>
internal sealed record MilaSignInPolicy(TimeSpan PollInterval, int ReconnectAttempts, TimeSpan ReconnectBackoff, uint ConnectTimeoutMs)
{
    internal static MilaSignInPolicy Default => new(TimeSpan.FromSeconds(2), 3, TimeSpan.FromSeconds(1), 30_000);
}

/// <summary>
/// Drives <see cref="MilaSignInFlow"/> with the authenticated Rust session:
/// connect, same-session whoami polling while the browser approval is pending,
/// approval outcome handling, and bounded reconnect after transport loss.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:security;reliability] mila-windows-signin-coordinator
/// Every await MUST be followed by a generation check; a result for an older
/// generation MUST close its session and change nothing. Approval links MUST be
/// bound to the selected deployment host and HTTPS port and opened at most once
/// per generation. Refusal, expiry and protocol failures MUST close the session.
/// Reconnect MUST start a fresh generation, MUST NOT reuse the prior approval and
/// MUST stop after the configured number of attempts.
/// </remarks>
internal sealed class MilaSignInCoordinator
{
    private readonly MilaSignInFlow _flow;
    private readonly MilaSessionConnection _session;
    private readonly Func<ulong, MilaNativeSessionBytesResult> _whoami;
    private readonly IMilaApprovalBrowser _browser;
    private readonly Func<ulong> _clock;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly MilaSignInPolicy _policy;

    internal MilaSignInCoordinator(
        MilaSignInFlow flow, MilaSessionConnection session, IMilaApprovalBrowser browser,
        Func<ulong, MilaNativeSessionBytesResult>? whoami = null, Func<ulong>? clock = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null, MilaSignInPolicy? policy = null)
    {
        _flow = flow;
        _session = session;
        _browser = browser;
        _whoami = whoami ?? RustNative.TrySessionWhoami;
        _clock = clock ?? (() => (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        _delay = delay ?? Task.Delay;
        _policy = policy ?? MilaSignInPolicy.Default;
    }

    internal MilaSignInState State => _flow.State;

    /// <summary>Raised after approval becomes pending and when an attempt settles.</summary>
    internal event Action<MilaSignInState>? Changed;

    private MilaSignInState Notify()
    {
        MilaSignInState state = _flow.State;
        Changed?.Invoke(state);
        return state;
    }

    /// <summary>Starts a new sign-in generation for <paramref name="target"/>.</summary>
    internal async Task<MilaSignInState> SignInAsync(MilaSignInTarget target, CancellationToken cancellationToken = default)
    {
        long generation = _flow.Start();
        Notify();
        await ConnectAndAuthenticateAsync(target, generation, attempts: 1, cancellationToken);
        return Notify();
    }

    /// <summary>Reconnects a disconnected deployment; refused unless the flow is Disconnected.</summary>
    internal async Task<MilaSignInState> ReconnectAsync(MilaSignInTarget target, CancellationToken cancellationToken = default)
    {
        if (_flow.Reconnect() is not { } generation) return _flow.State;
        Notify();
        await ConnectAndAuthenticateAsync(target, generation, Math.Max(1, _policy.ReconnectAttempts), cancellationToken);
        return Notify();
    }

    /// <summary>Records a transport loss reported by any session operation of this generation.</summary>
    internal bool ReportTransportLoss(long generation)
    {
        if (!_flow.Disconnected(generation)) return false;
        _session.SignOut();
        Notify();
        return true;
    }

    internal void SignOut()
    {
        _flow.SignOut();
        _session.SignOut();
    }

    private bool Current(long generation) => _flow.State.Generation == generation;

    private async Task<MilaSignInState> ConnectAndAuthenticateAsync(
        MilaSignInTarget target, long generation, int attempts, CancellationToken cancellationToken)
    {
        for (int attempt = 1; ; attempt++)
        {
            bool connected;
            try
            {
                connected = await Task.Run(() => _session.Connect(target.Trust, target.Host, target.PublicKey,
                    target.SshPort, _policy.ConnectTimeoutMs, target.Signer), cancellationToken);
            }
            catch (OperationCanceledException) { return Abandon(generation); }
            // A newer generation owns the session; its Connect or SignOut closes this handle.
            if (!Current(generation)) return _flow.State;
            if (connected && _session.Handle is { } handle) return await AuthenticateAsync(target, generation, handle, cancellationToken);
            MilaSignInFailure failure = _session.State.Error switch
            {
                MilaNativeStatus.InvalidRequest => MilaSignInFailure.HostUntrusted,
                MilaNativeStatus.Transport or MilaNativeStatus.Busy => MilaSignInFailure.Unreachable,
                _ => MilaSignInFailure.Protocol,
            };
            if (failure != MilaSignInFailure.Unreachable || attempt >= attempts)
            {
                _flow.Fail(failure, generation);
                return _flow.State;
            }
            try { await _delay(_policy.ReconnectBackoff * attempt, cancellationToken); }
            catch (OperationCanceledException) { return Abandon(generation); }
            if (!Current(generation)) return _flow.State;
        }
    }

    private async Task<MilaSignInState> AuthenticateAsync(
        MilaSignInTarget target, long generation, ulong handle, CancellationToken cancellationToken)
    {
        bool browserOpened = false;
        while (true)
        {
            MilaNativeSessionBytesResult reply = await Task.Run(() => _whoami(handle), CancellationToken.None);
            if (!Current(generation) || _session.Handle != handle) return _flow.State;
            if (!reply.Succeeded || reply.Data is not { } bytes)
                return Close(reply.Status == MilaNativeStatus.Transport ? MilaSignInFailure.Unreachable : MilaSignInFailure.Protocol, generation);
            switch (MilaWhoamiDecoder.Decode(bytes))
            {
                case MilaWhoami.Approved approved:
                    _flow.Authenticated(generation, approved.Account ?? target.Host);
                    return _flow.State;
                case MilaWhoami.Refused refused:
                    return Close(refused.Failure, generation);
                case MilaWhoami.Invalid:
                    return Close(MilaSignInFailure.Protocol, generation);
                case MilaWhoami.Pending pending:
                    ulong now = _clock();
                    if (_flow.State.Phase == MilaSignInPhase.Connecting)
                    {
                        _flow.AwaitApproval(generation);
                        if (!_flow.SetApproval(generation, pending.Url, pending.Fingerprint, now, target.Host, target.HttpsPort))
                            return Close(MilaSignInFailure.Protocol, generation);
                        Notify();
                    }
                    if (_flow.Expire(generation, now)) { _session.SignOut(); return _flow.State; }
                    if (!browserOpened && _flow.State.Approval is { } approval)
                    {
                        browserOpened = true;
                        // A refused launch leaves the link in state for a manual open;
                        // polling continues either way until approval or expiry.
                        try { await _browser.OpenAsync(approval, cancellationToken); }
                        catch (OperationCanceledException) { return Abandon(generation); }
                        catch (HttpRequestException) { }
                        if (!Current(generation)) return _flow.State;
                    }
                    try { await _delay(_policy.PollInterval, cancellationToken); }
                    catch (OperationCanceledException) { return Abandon(generation); }
                    if (!Current(generation)) return _flow.State;
                    break;
            }
        }
    }

    private MilaSignInState Close(MilaSignInFailure failure, long generation)
    {
        _flow.Fail(failure, generation);
        if (Current(generation)) _session.SignOut();
        return _flow.State;
    }

    private MilaSignInState Abandon(long generation)
    {
        if (Current(generation)) SignOut();
        return _flow.State;
    }
}
