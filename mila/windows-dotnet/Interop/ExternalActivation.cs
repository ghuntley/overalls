namespace Mila.Windows.Interop;

/// <summary>Typed external activation accepted by the Windows host.</summary>
internal readonly record struct MilaExternalActivation(MilaRoute Route, bool IsShareTarget);

internal static class MilaShareTarget
{
    /// <summary>Authorizes a share activation before it reaches native controls.</summary>
    /// <remarks>Sharing a route is navigation only; it must never implicitly mutate data.</remarks>
    internal static bool TryAuthorize(
        MilaExternalActivation activation,
        bool authenticated,
        string? activeHost,
        out MilaRoute route)
    {
        route = default;
        if (!activation.IsShareTarget || !authenticated ||
            !string.Equals(activeHost, activation.Route.Host, StringComparison.OrdinalIgnoreCase) ||
            activation.Route.Kind is not (MilaRouteKind.Machine or MilaRouteKind.Thread or MilaRouteKind.Threads))
            return false;
        route = activation.Route;
        return true;
    }
}

internal sealed class MilaExternalActivationGate
{
    private long _generation;
    internal long Generation => _generation;
    internal long Reset() => ++_generation;
    internal bool TryAuthorize(MilaExternalActivation activation, long activationGeneration, bool authenticated, string? activeHost, out MilaRoute route)
    {
        if (activationGeneration != _generation) { route = default; return false; }
        return MilaShareTarget.TryAuthorize(activation, authenticated, activeHost, out route);
    }
}

internal static class MilaExternalActivationParser
{
    private const int MaxActivationText = 4096;

    /// <summary>
    /// Parses protocol activation or a share payload. Share payloads are treated
    /// as navigation only after the Rust-aligned canonical route parser accepts
    /// them; arbitrary text and command-like query strings are rejected.
    /// </summary>
    internal static MilaExternalActivation? Parse(string? value, bool shareTarget = false)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        string candidate = value.Trim().Trim('"');
        if (candidate.Length > MaxActivationText || candidate.Any(char.IsControl)) return null;
        MilaRoute? route = MilaRouteParser.Parse(candidate);
        return route is null ? null : new MilaExternalActivation(route.Value, shareTarget);
    }

    /// <summary>Parses the bounded command line supplied by WinUI activation.</summary>
    /// <remarks>
    /// Protocol activation is a single URI. Share/open activation uses the
    /// explicit <c>--share</c> marker so arbitrary command-line text cannot be
    /// interpreted as a route. The payload is still accepted only by the same
    /// canonical route grammar.
    /// </remarks>
    internal static MilaExternalActivation? ParseArguments(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments) || arguments.Length > MaxActivationText || arguments.Any(char.IsControl)) return null;
        string value = arguments.Trim();
        const string marker = "--share";
        if (value.StartsWith(marker, StringComparison.Ordinal))
        {
            if (value.Length == marker.Length || !char.IsWhiteSpace(value[marker.Length])) return null;
            return Parse(value[marker.Length..], shareTarget: true);
        }
        return Parse(value);
    }
}

internal enum MilaShareCompletionOutcome
{
    /// <summary>The route is authorized for the authenticated deployment; navigate now.</summary>
    Navigated,
    /// <summary>Held until the target deployment authenticates in this generation.</summary>
    Deferred,
    /// <summary>Not a share activation, or a navigation kind sharing never opens.</summary>
    Refused,
    /// <summary>Nothing pending, or the pending share outlived its generation or lifetime.</summary>
    Expired,
}

/// <summary>Reports the share outcome back to the OS share provider, when one exists.</summary>
internal interface IMilaShareOperation
{
    void ReportCompleted();
    void ReportFailed();
}

/// <summary>
/// Completes share/open activations after authentication.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:security] mila-windows-share-completion
/// A share received while signed out, or for another deployment, MAY be held
/// for at most one activation and <see cref="PendingLifetimeSeconds"/>. It
/// MUST complete only when that exact host authenticates within the same
/// activation generation, at most once, and only through
/// <see cref="MilaShareTarget.TryAuthorize"/>. Sign-out or a deployment switch
/// MUST discard it. Completion is navigation only and never mutates data.
/// </remarks>
internal sealed class MilaShareCompletion(MilaExternalActivationGate gate, Func<ulong>? clock = null)
{
    internal const ulong PendingLifetimeSeconds = 600;
    private readonly Func<ulong> _clock = clock ?? (() => (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    private (MilaExternalActivation Activation, long Generation, ulong ReceivedAt, IMilaShareOperation? Operation)? _pending;

    internal string? PendingHost => _pending?.Activation.Route.Host;

    internal MilaShareCompletionOutcome Offer(MilaExternalActivation activation, bool authenticated, string? activeHost,
        out MilaRoute route, IMilaShareOperation? operation = null)
    {
        route = default;
        if (!activation.IsShareTarget ||
            activation.Route.Kind is not (MilaRouteKind.Machine or MilaRouteKind.Thread or MilaRouteKind.Threads))
        {
            operation?.ReportFailed();
            return MilaShareCompletionOutcome.Refused;
        }
        if (gate.TryAuthorize(activation, gate.Generation, authenticated, activeHost, out route))
        {
            operation?.ReportCompleted();
            return MilaShareCompletionOutcome.Navigated;
        }
        // A newer share replaces an older pending one; the older one is reported failed.
        _pending?.Operation?.ReportFailed();
        _pending = (activation, gate.Generation, _clock(), operation);
        return MilaShareCompletionOutcome.Deferred;
    }

    /// <summary>Called once the deployment <paramref name="authenticatedHost"/> has a live session.</summary>
    internal MilaShareCompletionOutcome Complete(string authenticatedHost, out MilaRoute route)
    {
        route = default;
        if (_pending is not { } pending) return MilaShareCompletionOutcome.Expired;
        if (!string.Equals(pending.Activation.Route.Host, authenticatedHost, StringComparison.Ordinal))
            return MilaShareCompletionOutcome.Deferred;
        _pending = null;
        ulong now = _clock();
        if (now < pending.ReceivedAt || now - pending.ReceivedAt > PendingLifetimeSeconds ||
            !gate.TryAuthorize(pending.Activation, pending.Generation, true, authenticatedHost, out route))
        {
            pending.Operation?.ReportFailed();
            return MilaShareCompletionOutcome.Expired;
        }
        pending.Operation?.ReportCompleted();
        return MilaShareCompletionOutcome.Navigated;
    }

    /// <summary>
    /// Deployment switch: advance the gate. A pending share survives only when the
    /// newly selected deployment is its own host (the operator is signing in to
    /// complete it); otherwise it is discarded.
    /// </summary>
    internal void OnDeploymentSelected(string? host)
    {
        gate.Reset();
        if (_pending is { } pending && string.Equals(pending.Activation.Route.Host, host, StringComparison.Ordinal))
            _pending = pending with { Generation = gate.Generation };
        else
        {
            _pending?.Operation?.ReportFailed();
            _pending = null;
        }
    }

    /// <summary>Sign-out: advance the gate and drop any pending share.</summary>
    internal void Cancel()
    {
        gate.Reset();
        _pending?.Operation?.ReportFailed();
        _pending = null;
    }
}
