namespace Mila.Windows.Interop;

/// <summary>
/// One catalog message identity with its English fallback and optional
/// <c>{host}</c> binding. Identities come from mila/localization/catalogs.
/// </summary>
internal sealed record MilaMessage(string Id, string Fallback, string? Host = null)
{
    /// <summary>Placeholders this identity binds; the smoke test checks catalogs declare exactly these.</summary>
    internal IReadOnlyList<string> Placeholders => Host is null ? [] : ["host"];

    /// <summary>
    /// Resolves through <paramref name="lookup"/> (id, fallback) and binds
    /// <c>{host}</c> inside Unicode first-strong isolates so an LTR host name
    /// renders correctly inside RTL translations.
    /// </summary>
    internal string Render(Func<string, string, string> lookup)
    {
        string text = lookup(Id, Fallback);
        return Host is null ? text : text.Replace("{host}", "⁨" + Host + "⁩", StringComparison.Ordinal);
    }
}

/// <summary>Typed mapping from Windows lifecycle outcomes to shared catalog messages.</summary>
/// <remarks>
/// @cc [owner:ghuntley,label:localization] mila-windows-outcome-messages
/// Every user-visible lifecycle outcome MUST map to an existing shared catalog
/// identity with matching placeholders; raw status codes, URLs, tokens and
/// fingerprints MUST NOT be rendered through these messages.
/// </remarks>
internal static class MilaPresentation
{
    internal static MilaMessage SignIn(MilaSignInState state, string? host) => state.Phase switch
    {
        MilaSignInPhase.SignedOut => new("signInTitle", "Sign in"),
        MilaSignInPhase.Connecting => new("signInConnecting", "Connecting to {host}…", host ?? string.Empty),
        MilaSignInPhase.AwaitingApproval => new("signInApprove",
            "Approve this device in your browser, then return here. Keep Mila open until you have approved it."),
        MilaSignInPhase.SignedIn => new("settingsSignedIn", "Signed in"),
        MilaSignInPhase.Disconnected => new("signInDisconnected", "The connection to this deployment closed."),
        MilaSignInPhase.Expired => new("signInExpired", "The approval link is no longer valid. Start again to get a new one."),
        _ => state.Failure switch
        {
            MilaSignInFailure.HostUntrusted => new("signInFailedHost",
                "This host did not present a certificate from its published authority, so Mila did not connect."),
            MilaSignInFailure.Refused => new("signInFailedRefused", "The deployment refused this device."),
            MilaSignInFailure.Unreachable => new("signInFailedUnreachable", "The deployment cannot be reached."),
            _ => new("signInFailedProtocol", "The deployment sent a reply Mila does not understand."),
        },
    };

    internal static MilaMessage Push(MilaPushRegistrationOutcome outcome) => outcome switch
    {
        MilaPushRegistrationOutcome.Registered => new("pushStateOn", "on"),
        MilaPushRegistrationOutcome.SignedOut => new("notificationsSignInFirst", "Sign in to this deployment to manage its notifications."),
        MilaPushRegistrationOutcome.ChannelUnavailable or MilaPushRegistrationOutcome.KeyUnavailable =>
            new("pushUnsupported", "Notifications are not available on this platform."),
        MilaPushRegistrationOutcome.RelayRefused or MilaPushRegistrationOutcome.RelayUnregistered or
            MilaPushRegistrationOutcome.DeploymentRefused =>
            new("pushFailedRefused", "The deployment or the notification relay refused this device."),
        MilaPushRegistrationOutcome.InvalidChannel or MilaPushRegistrationOutcome.Protocol =>
            new("pushFailedProtocol", "Mila could not understand the reply."),
        _ => new("pushStateFailed", "failed"),
    };

    internal static MilaMessage Terminal(MilaTerminalPoll poll) => poll switch
    {
        MilaTerminalPoll.Output or MilaTerminalPoll.Idle or MilaTerminalPoll.Reconnected => new("terminalLive", "live"),
        MilaTerminalPoll.Reconnecting => new("terminalReconnecting", "reconnecting"),
        MilaTerminalPoll.Exhausted => new("terminalUnreachable", "The deployment cannot be reached."),
        MilaTerminalPoll.SignedOut => new("terminalSignedOut", "This device is no longer authorized. Sign in again to attach."),
        _ => new("terminalEnded", "The terminal session ended."),
    };

    internal static MilaMessage? DeploymentAdd(MilaDeploymentAddResult result) => result switch
    {
        MilaDeploymentAddResult.InvalidHost or MilaDeploymentAddResult.InvalidPort =>
            new("invalidHost", "Enter a host name such as overalls.example."),
        _ => null,
    };

    internal static MilaMessage? Share(MilaShareCompletionOutcome outcome, string? host, bool hostStored) => outcome switch
    {
        MilaShareCompletionOutcome.Navigated => null,
        MilaShareCompletionOutcome.Deferred when !hostStored =>
            new("linkUnknownDeployment", "Add {host} as a deployment to open this link.", host ?? string.Empty),
        MilaShareCompletionOutcome.Deferred => new("signInTitle", "Sign in"),
        _ => new("linkRefused", "Mila cannot open this link."),
    };

    /// <summary>Every message the mappings can produce, for catalog verification.</summary>
    internal static IEnumerable<MilaMessage> All()
    {
        MilaSignInState state = MilaSignInState.Initial;
        foreach (MilaSignInPhase phase in Enum.GetValues<MilaSignInPhase>())
            foreach (MilaSignInFailure? failure in Enum.GetValues<MilaSignInFailure>().Cast<MilaSignInFailure?>().Append(null))
                yield return SignIn(state with { Phase = phase, Failure = failure }, "example.test");
        foreach (MilaPushRegistrationOutcome outcome in Enum.GetValues<MilaPushRegistrationOutcome>()) yield return Push(outcome);
        foreach (MilaTerminalPoll poll in Enum.GetValues<MilaTerminalPoll>()) yield return Terminal(poll);
        foreach (MilaDeploymentAddResult result in Enum.GetValues<MilaDeploymentAddResult>())
            if (DeploymentAdd(result) is { } message) yield return message;
        foreach (MilaShareCompletionOutcome outcome in Enum.GetValues<MilaShareCompletionOutcome>())
            foreach (bool stored in new[] { false, true })
                if (Share(outcome, "example.test", stored) is { } message) yield return message;
    }
}
