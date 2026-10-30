namespace Mila.Windows.Interop;

internal enum MilaDeploymentAddResult { Added, Existing, InvalidHost, InvalidPort }

/// <summary>Immutable picker projection consumed by the WinUI list.</summary>
internal sealed record MilaDeploymentPickerState(
    IReadOnlyList<MilaDeployment> Deployments,
    MilaDeployment? Selected,
    long SelectionGeneration);

/// <summary>
/// Owns the deployment list, the single selected deployment and the selection
/// generation that fences approval and session work for that deployment.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:security;reliability] mila-windows-deployment-picker
/// Only canonical hosts and non-zero ports MAY enter the picker. Selecting a
/// different deployment, or forgetting the selected one, MUST advance the
/// selection generation and invoke the sign-out hook before the new selection
/// is visible, so a pending approval, session handle or deep link for the old
/// deployment can never complete against the new one.
/// </remarks>
internal sealed class MilaDeploymentPicker
{
    private readonly object _gate = new();
    private readonly IMilaDeploymentRepository _repository;
    private readonly Action<MilaDeployment?> _deselected;
    private MilaDeploymentPickerState _state;

    internal MilaDeploymentPicker(IMilaDeploymentRepository repository, Action<MilaDeployment?> deselected)
    {
        _repository = repository;
        _deselected = deselected;
        IReadOnlyList<MilaDeployment> all = repository.LoadAll();
        _state = new(all, null, 0);
    }

    internal MilaDeploymentPickerState State { get { lock (_gate) return _state; } }

    internal bool IsCurrent(long selectionGeneration, MilaDeployment deployment)
    {
        lock (_gate)
            return _state.SelectionGeneration == selectionGeneration && _state.Selected == deployment;
    }

    /// <summary>Validates operator input and persists a new deployment without selecting it.</summary>
    internal MilaDeploymentAddResult Add(string? hostInput, ushort port, out MilaDeployment? deployment)
    {
        deployment = null;
        if (port == 0) return MilaDeploymentAddResult.InvalidPort;
        if (MilaDeploymentHost.Canonicalize(hostInput) is not { } host) return MilaDeploymentAddResult.InvalidHost;
        deployment = new MilaDeployment(host, port);
        lock (_gate)
        {
            if (_state.Deployments.Contains(deployment)) return MilaDeploymentAddResult.Existing;
            _repository.Save(deployment);
            _state = _state with { Deployments = _repository.LoadAll() };
        }
        return MilaDeploymentAddResult.Added;
    }

    /// <summary>Selects a stored deployment; returns the new selection generation, or null when it is not stored.</summary>
    internal long? Select(MilaDeployment deployment)
    {
        ArgumentNullException.ThrowIfNull(deployment);
        MilaDeployment? previous;
        long generation;
        lock (_gate)
        {
            // Keep the stored instance so list controls can match it by reference.
            if (_state.Deployments.FirstOrDefault(stored => stored == deployment) is not { } listed) return null;
            deployment = listed;
            if (_state.Selected == deployment) return _state.SelectionGeneration;
            previous = _state.Selected;
            generation = checked(_state.SelectionGeneration + 1);
            _state = _state with { Selected = null, SelectionGeneration = generation };
        }
        // Tear down the old deployment's session before the new one is visible.
        _deselected(previous);
        lock (_gate)
        {
            if (_state.SelectionGeneration != generation) return null;
            _state = _state with { Selected = deployment };
            return generation;
        }
    }

    /// <summary>Removes a deployment; forgetting the selected one signs it out first.</summary>
    internal bool Forget(MilaDeployment deployment)
    {
        ArgumentNullException.ThrowIfNull(deployment);
        bool wasSelected;
        lock (_gate)
        {
            wasSelected = _state.Selected == deployment;
            if (wasSelected)
                _state = _state with { Selected = null, SelectionGeneration = checked(_state.SelectionGeneration + 1) };
        }
        if (wasSelected) _deselected(deployment);
        bool removed = _repository.Forget(deployment);
        lock (_gate) _state = _state with { Deployments = _repository.LoadAll() };
        return removed;
    }
}
