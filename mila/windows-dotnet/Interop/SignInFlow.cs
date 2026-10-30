namespace Mila.Windows.Interop;

internal enum MilaSignInPhase
{
    SignedOut,
    Connecting,
    AwaitingApproval,
    SignedIn,
    Disconnected,
    Expired,
    Failed,
}

internal enum MilaSignInFailure { HostUntrusted, Refused, Protocol, Unreachable }

/// <summary>Approval metadata held only in memory while a sign-in is pending.</summary>
internal sealed record MilaApprovalInfo(string Url, string Fingerprint, ulong IssuedAt)
{
    /// <summary>
    /// Validates approval metadata. When <paramref name="expectedHost"/> is set the
    /// link MUST name exactly that deployment host on <paramref name="httpsPort"/>,
    /// so a whoami reply cannot send the browser to another origin.
    /// </summary>
    internal static MilaApprovalInfo? TryCreate(string url, string fingerprint, ulong issuedAt,
        string? expectedHost = null, ushort httpsPort = 443)
    {
        if (httpsPort == 0) return null;
        if (url.Length is 0 or > 2048 || fingerprint.Length is 0 or > 256 ||
            url.Any(char.IsControl) || fingerprint.Any(char.IsControl) ||
            !Uri.TryCreate(url, UriKind.Absolute, out Uri? parsed) ||
            parsed.Scheme != Uri.UriSchemeHttps || parsed.Host.Length == 0 ||
            Uri.CheckHostName(parsed.Host) is UriHostNameType.Unknown ||
            parsed.UserInfo.Length != 0 || parsed.Fragment.Length != 0 ||
            (httpsPort == 443 ? parsed.Port is not (-1 or 443) : parsed.Port != httpsPort) ||
            (expectedHost is not null && !string.Equals(parsed.Host, expectedHost, StringComparison.Ordinal)))
            return null;
        return new(url, fingerprint, issuedAt);
    }
}

internal sealed record MilaSignInState(
    MilaSignInPhase Phase,
    long Generation,
    MilaApprovalInfo? Approval,
    string? Account,
    MilaSignInFailure? Failure)
{
    internal static MilaSignInState Initial => new(MilaSignInPhase.SignedOut, 0, null, null, null);
}

/// <summary>
/// Generation-scoped approval and reconnect reducer for the native Windows shell.
/// Approval URLs and fingerprints never leave this in-memory state.
/// </summary>
internal sealed class MilaSignInFlow
{
    private readonly object _gate = new();
    private MilaSignInState _state = MilaSignInState.Initial;

    internal MilaSignInState State { get { lock (_gate) return _state; } }

    /// <summary>
    /// @cc [owner:ghuntley,label:reliability] mila-windows-signin-generation
    /// Sign-out, reconnect and approval outcomes MUST be generation-scoped so a
    /// late browser or transport result cannot authenticate a newer attempt.
    /// </summary>
    internal long Start()
    {
        lock (_gate)
        {
            long generation = checked(_state.Generation + 1);
            _state = new(MilaSignInPhase.Connecting, generation, null, null, null);
            return generation;
        }
    }

    internal bool AwaitApproval(long generation)
    {
        lock (_gate)
        {
            if (generation != _state.Generation || _state.Phase != MilaSignInPhase.Connecting) return false;
            _state = _state with { Phase = MilaSignInPhase.AwaitingApproval, Approval = null, Failure = null };
            return true;
        }
    }

    internal bool SetApproval(long generation, string url, string fingerprint, ulong issuedAt,
        string? expectedHost = null, ushort httpsPort = 443)
    {
        MilaApprovalInfo? approval = MilaApprovalInfo.TryCreate(url, fingerprint, issuedAt, expectedHost, httpsPort);
        if (approval is null) return false;
        lock (_gate)
        {
            if (generation != _state.Generation || _state.Phase != MilaSignInPhase.AwaitingApproval) return false;
            _state = _state with { Approval = approval };
            return true;
        }
    }

    internal bool Authenticated(long generation, string account)
    {
        if (string.IsNullOrWhiteSpace(account) || account.Any(char.IsControl)) return false;
        lock (_gate)
        {
            if (generation != _state.Generation ||
                _state.Phase is not (MilaSignInPhase.Connecting or MilaSignInPhase.AwaitingApproval))
                return false;
            _state = new(MilaSignInPhase.SignedIn, generation, null, account, null);
            return true;
        }
    }

    internal bool Disconnected(long generation)
    {
        lock (_gate)
        {
            if (generation != _state.Generation || _state.Phase != MilaSignInPhase.SignedIn) return false;
            _state = _state with { Phase = MilaSignInPhase.Disconnected };
            return true;
        }
    }

    /// Starts a fresh transport generation after an established connection is
    /// lost. The prior approval is discarded and cannot authenticate it.
    internal long? Reconnect()
    {
        lock (_gate)
        {
            if (_state.Phase != MilaSignInPhase.Disconnected) return null;
            long generation = checked(_state.Generation + 1);
            _state = new(MilaSignInPhase.Connecting, generation, null, _state.Account, null);
            return generation;
        }
    }

    internal bool Expire(long generation, ulong now)
    {
        lock (_gate)
        {
            if (generation != _state.Generation || _state.Phase != MilaSignInPhase.AwaitingApproval ||
                _state.Approval is not { } approval || now < approval.IssuedAt || now - approval.IssuedAt < 600)
                return false;
            _state = _state with { Phase = MilaSignInPhase.Expired, Approval = null };
            return true;
        }
    }

    internal void Fail(MilaSignInFailure failure, long generation)
    {
        lock (_gate)
        {
            if (generation == _state.Generation)
                _state = _state with { Phase = MilaSignInPhase.Failed, Approval = null, Failure = failure };
        }
    }

    internal void SignOut()
    {
        lock (_gate)
        {
            _state = new(MilaSignInPhase.SignedOut, checked(_state.Generation + 1), null, null, null);
        }
    }
}
