using System.Text.Json;

namespace Mila.Windows.Interop;

/// <summary>Bounded, typed thread projection owned by the Rust session boundary.</summary>
internal sealed record MilaThreadRow(Guid Id, string Title, string State, Guid? PlanId = null);
internal sealed record MilaThreadListing(IReadOnlyList<MilaThreadRow> Threads, bool HasMore)
{
    internal const int MaxBytes = 8 * 1024 * 1024;
    internal const int MaxThreads = 10_000;

    /// <summary>
    /// Decodes `thread ls --json` (<c>result.items[]</c>, Porsche protocol). A version-1
    /// envelope is unwrapped only when its status is succeeded or accepted.
    /// </summary>
    internal static MilaThreadListing Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaxBytes) throw new InvalidDataException("thread listing exceeds bound");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = MilaPorscheEnvelope.Result(document.RootElement);
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("items", out JsonElement rows) ||
            rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > MaxThreads)
            throw new InvalidDataException("invalid thread listing");
        List<MilaThreadRow> threads = new(rows.GetArrayLength());
        foreach (JsonElement row in rows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("id", out JsonElement idElement) ||
                idElement.ValueKind != JsonValueKind.String || !Guid.TryParseExact(idElement.GetString(), "D", out Guid id))
                throw new InvalidDataException("invalid thread id");
            string title = ReadString(row, "title") ?? id.ToString("D");
            string state = ReadString(row, "status") ?? "unknown";
            Guid? planId = null;
            if (row.TryGetProperty("latest_plan", out JsonElement plan) && plan.ValueKind == JsonValueKind.Object &&
                plan.TryGetProperty("id", out JsonElement planElement) && planElement.ValueKind == JsonValueKind.String &&
                Guid.TryParseExact(planElement.GetString(), "D", out Guid parsedPlan)) planId = parsedPlan;
            threads.Add(new(id, title, state, planId));
        }
        bool hasMore = root.TryGetProperty("next_cursor", out JsonElement more) && more.ValueKind == JsonValueKind.String;
        return new(threads, hasMore);
    }

    private static string? ReadString(JsonElement row, string name) =>
        row.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

internal enum MilaThreadAction { Show, Turns, Read, Prompt, Answer, PlanApprove, PlanRevise }
internal enum MilaThreadActionStateKind { SignedOut, Empty, Ready, Submitting, Applied, Failed }
internal sealed record MilaThreadActionState(MilaThreadActionStateKind Kind, MilaThreadRow? Thread, MilaThreadAction? Action, string? Error);

internal delegate MilaNativeSessionBytesResult MilaThreadCommandSubmit(
    ulong handle, Guid? thread, string command, string? secondary, string? input, string? requestId);

/// <summary>
/// @cc [owner:ghuntley,label:security;reliability] mila-windows-thread-result-generation
/// A thread result MUST update only the authenticated session and selected-thread
/// generation that submitted it; signing out or replacing a selection MUST fence
/// in-flight completion, including replacement by another authenticated session.
/// </summary>
internal sealed class MilaThreadController(MilaThreadCommandSubmit? submit = null)
{
    private readonly object _gate = new();
    private readonly MilaThreadCommandSubmit _submit = submit ?? RustNative.TrySessionThreadAction;
    private long _generation;
    private MilaThreadActionState _state = new(MilaThreadActionStateKind.SignedOut, null, null, null);
    internal MilaThreadActionState State { get { lock (_gate) return _state; } }
    internal long Generation { get { lock (_gate) return _generation; } }
    private MilaThreadListing? _listing;
    private bool _authenticated;
    private ulong _handle;

    internal void SetSession(bool authenticated, MilaThreadListing? listing, ulong handle = 0)
    {
        lock (_gate)
        {
            _generation++;
            _authenticated = authenticated && listing is not null;
            _handle = _authenticated ? handle : 0;
            _listing = _authenticated ? listing : null;
            _state = _authenticated ? new(MilaThreadActionStateKind.Empty, null, null, null) : new(MilaThreadActionStateKind.SignedOut, null, null, null);
        }
    }

    internal bool Select(Guid id)
    {
        lock (_gate)
        {
            MilaThreadRow? thread = _listing?.Threads.FirstOrDefault(item => item.Id == id);
            if (thread is null) return false;
            _generation++;
            _state = new(MilaThreadActionStateKind.Ready, thread, null, null);
            return true;
        }
    }

    internal bool Submit(MilaThreadAction action)
    {
        lock (_gate)
        {
            if (!_authenticated || _state.Thread is null) { _state = new(MilaThreadActionStateKind.SignedOut, null, null, null); return false; }
            string command = action switch
            {
                MilaThreadAction.Show => "thread show",
                MilaThreadAction.Turns => "thread turns",
                MilaThreadAction.Read => "thread read",
                MilaThreadAction.Prompt => "thread prompt",
                MilaThreadAction.Answer => "thread answer",
                MilaThreadAction.PlanApprove => "thread plan approve",
                MilaThreadAction.PlanRevise => "thread plan revise",
                _ => throw new ArgumentOutOfRangeException(nameof(action)),
            };
            MilaNativeThreadCommandResult result = RustNative.TryClassifyThreadCommand(command);
            if (result.Status != MilaNativeStatus.Ok || result.Kind is null)
            {
                _state = new(MilaThreadActionStateKind.Failed, _state.Thread, action, result.Status.ToString());
                return false;
            }
            _state = new(MilaThreadActionStateKind.Applied, _state.Thread, action, null);
            return true;
        }
    }

    /// <summary>Dispatches the selected action through the authenticated Rust session.</summary>
    internal bool SubmitLive(ulong handle, MilaThreadAction action, string? secondary = null, string? input = null,
        long? expectedGeneration = null)
    {
        long generation;
        MilaThreadRow thread;
        lock (_gate)
        {
            if (!_authenticated || handle == 0 || _handle != handle || _state.Thread is not { } selected ||
                (expectedGeneration is { } expected && expected != _generation) ||
                _state.Kind == MilaThreadActionStateKind.Submitting) return false;
            generation = _generation;
            thread = selected;
            _state = new(MilaThreadActionStateKind.Submitting, thread, action, null);
        }
        string command = action switch
        {
            MilaThreadAction.Show => "thread show", MilaThreadAction.Turns => "thread turns", MilaThreadAction.Read => "thread read",
            MilaThreadAction.Prompt => "thread prompt", MilaThreadAction.Answer => "thread answer",
            MilaThreadAction.PlanApprove => "thread plan approve", MilaThreadAction.PlanRevise => "thread plan revise",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };
        string? request = action is MilaThreadAction.Prompt or MilaThreadAction.Answer or
            MilaThreadAction.PlanApprove or MilaThreadAction.PlanRevise
            ? "porsche-" + Guid.NewGuid().ToString("N") : null;
        MilaNativeSessionBytesResult result = _submit(handle, thread.Id, command, secondary, input, request);
        lock (_gate)
        {
            if (!_authenticated || generation != _generation) return false;
            _state = result.Succeeded
                ? new(MilaThreadActionStateKind.Applied, thread, action, null)
                : new(MilaThreadActionStateKind.Failed, thread, action, result.Status.ToString());
            return result.Succeeded;
        }
    }
}
