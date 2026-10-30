using Microsoft.Windows.PushNotifications;

namespace Mila.Windows.Interop;

/// <summary>Opens a validated approval link in the default browser.</summary>
internal sealed class MilaLauncherApprovalBrowser : IMilaApprovalBrowser
{
    public async Task<bool> OpenAsync(MilaApprovalInfo approval, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Uri.TryCreate(approval.Url, UriKind.Absolute, out Uri? uri) &&
            await global::Windows.System.Launcher.LaunchUriAsync(uri);
    }
}

/// <summary>
/// Windows App SDK WNS channel source. A channel needs the Entra application
/// (remote) identifier registered for the package; without one, or where push
/// is unsupported (for example unpackaged without identity), it returns null and
/// registration reports that notifications are unavailable.
/// </summary>
internal sealed class MilaWindowsAppSdkChannelSource(Guid? remoteId) : IMilaWnsChannelSource
{
    public async Task<MilaWnsChannel?> CreateChannelAsync(CancellationToken cancellationToken)
    {
        if (remoteId is not { } id || id == Guid.Empty || !PushNotificationManager.IsSupported()) return null;
        PushNotificationCreateChannelResult result =
            await PushNotificationManager.Default.CreateChannelAsync(id).AsTask(cancellationToken);
        if (result.Status != PushNotificationChannelStatus.CompletedSuccess || result.Channel is not { } channel)
            return null;
        return new MilaWnsChannel(channel.Uri.OriginalString, channel.ExpirationTime);
    }
}
