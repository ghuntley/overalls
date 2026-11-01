using System.Globalization;

namespace Mila.Windows.Interop;

/// <summary>
/// What the WinUI deployment controls show after one picker action. A null
/// <see cref="HostText"/>, <see cref="PortText"/> or <see cref="Status"/>
/// leaves that control unchanged.
/// </summary>
internal sealed record MilaDeploymentPickerView(
    IReadOnlyList<MilaDeployment> Rows,
    MilaDeployment? Selected,
    long SelectionGeneration,
    bool ForgetEnabled,
    string? HostText,
    string? PortText,
    MilaMessage? Status);

/// <summary>
/// The WinUI deployment picker's decisions, without WinUI: list rows, the
/// selected row, the Forget control, the host and port entries and the status
/// message. <c>MainWindow</c> forwards its controls' events here and assigns
/// the returned view to the controls, so the hermetic smoke and the fixture
/// journey exercise the same decisions the window makes.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:security;reliability] mila-windows-deployment-picker-controller
/// Every selection change MUST go through <see cref="MilaDeploymentPicker.Select"/>
/// (so the old deployment is signed out and its generation fenced before the
/// new one is visible) and MUST then tell <see cref="MilaShareCompletion"/>
/// which host is selected, so a pending share survives only for its own host.
/// Forgetting a deployment MUST cancel any pending share. A sign-in target
/// MUST be the stored deployment whose host is the canonical typed host;
/// non-canonical input yields no target and the invalid-host message.
/// A list event that names no row, or the already selected row, MUST be a no-op.
/// </remarks>
internal sealed class MilaDeploymentPickerController(MilaDeploymentPicker picker, MilaShareCompletion shares)
{
    internal MilaDeploymentPicker Picker => picker;

    /// <summary>The current picker state, with entries and status unchanged.</summary>
    internal MilaDeploymentPickerView View => Project(false, null);

    /// <summary>The list's selection changed; null when the event changes nothing.</summary>
    internal MilaDeploymentPickerView? Choose(MilaDeployment? row)
    {
        if (row is null || picker.State.Selected == row) return null;
        if (picker.Select(row) is null) return null;
        shares.OnDeploymentSelected(row.Host);
        return Project(true, null);
    }

    /// <summary>Adds the typed deployment and, when <paramref name="select"/>, selects it.</summary>
    internal MilaDeploymentPickerView Add(string? hostText, string? portText, bool select, out MilaDeployment? deployment)
    {
        MilaDeploymentAddResult result = picker.Add(hostText, ParsePort(portText), out deployment);
        if (MilaPresentation.DeploymentAdd(result) is { } message)
        {
            deployment = null;
            return Project(false, message);
        }
        // An existing entry is selected as stored, so its row matches by reference.
        MilaDeployment? typed = deployment;
        deployment = picker.State.Deployments.FirstOrDefault(stored => stored == typed) ?? typed;
        if (select && deployment is not null && picker.Select(deployment) is not null)
            shares.OnDeploymentSelected(deployment.Host);
        return Project(select, null);
    }

    /// <summary>Forgets the given row; signs it out first when it is selected.</summary>
    internal MilaDeploymentPickerView? Forget(MilaDeployment? row)
    {
        if (row is null || !picker.Forget(row)) return null;
        shares.Cancel();
        return Project(false, MilaPresentation.SignIn(MilaSignInState.Initial, null));
    }

    /// <summary>
    /// Resolves the sign-in target from the typed host: the selected deployment
    /// when it matches, otherwise the typed deployment added (or found) and
    /// selected. <paramref name="target"/> is null when the input is invalid.
    /// </summary>
    internal MilaDeploymentPickerView Connect(string? hostText, string? portText, out MilaDeployment? target, out long selection)
    {
        string typed = MilaDeploymentHost.Canonicalize(hostText) ?? string.Empty;
        target = picker.State.Selected;
        MilaDeploymentPickerView view = Project(false, null);
        if (target is null || target.Host != typed) view = Add(hostText, portText, select: true, out target);
        target = picker.State.Selected;
        selection = picker.State.SelectionGeneration;
        if (target is null || target.Host != typed)
        {
            target = null;
            return view with { Status = MilaPresentation.DeploymentAdd(MilaDeploymentAddResult.InvalidHost) };
        }
        return view;
    }

    /// <summary>Projects the picker; <paramref name="entries"/> also fills the host and port entries from the selection.</summary>
    private MilaDeploymentPickerView Project(bool entries, MilaMessage? status)
    {
        MilaDeploymentPickerState state = picker.State;
        MilaDeployment? shown = entries ? state.Selected : null;
        return new(state.Deployments, state.Selected, state.SelectionGeneration, state.Selected is not null,
            shown?.Host, shown?.Port.ToString(CultureInfo.InvariantCulture), status);
    }

    private static ushort ParsePort(string? text) =>
        ushort.TryParse(text?.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out ushort parsed) ? parsed : (ushort)0;
}
