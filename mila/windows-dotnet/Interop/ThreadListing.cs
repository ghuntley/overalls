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

/// <summary>Maintains authenticated thread selection and routes every action through Rust's command catalogue.</summary>
internal sealed class MilaThreadController
{
    internal MilaThreadActionState State { get; private set; } = new(MilaThreadActionStateKind.SignedOut, null, null, null);
    private MilaThreadListing? _listing;
    private bool _authenticated;

    internal void SetSession(bool authenticated, MilaThreadListing? listing)
    {
        _authenticated = authenticated && listing is not null;
        _listing = _authenticated ? listing : null;
        State = _authenticated ? new(MilaThreadActionStateKind.Empty, null, null, null) : new(MilaThreadActionStateKind.SignedOut, null, null, null);
    }

    internal bool Select(Guid id)
    {
        MilaThreadRow? thread = _listing?.Threads.FirstOrDefault(item => item.Id == id);
        if (thread is null) return false;
        State = new(MilaThreadActionStateKind.Ready, thread, null, null);
        return true;
    }

    internal bool Submit(MilaThreadAction action)
    {
        if (!_authenticated || State.Thread is null) { State = new(MilaThreadActionStateKind.SignedOut, null, null, null); return false; }
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
            State = new(MilaThreadActionStateKind.Failed, State.Thread, action, result.Status.ToString());
            return false;
        }
        State = new(MilaThreadActionStateKind.Applied, State.Thread, action, null);
        return true;
    }

    /// <summary>Dispatches the selected action through the authenticated Rust session.</summary>
    internal bool SubmitLive(ulong handle, MilaThreadAction action, string? secondary = null, string? input = null)
    {
        if (!_authenticated || handle == 0 || State.Thread is null)
        {
            State = new(MilaThreadActionStateKind.SignedOut, null, action, null);
            return false;
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
        MilaNativeSessionBytesResult result = RustNative.TrySessionThreadAction(
            handle, State.Thread.Id, command, secondary, input, request);
        State = result.Succeeded
            ? new(MilaThreadActionStateKind.Applied, State.Thread, action, null)
            : new(MilaThreadActionStateKind.Failed, State.Thread, action, result.Status.ToString());
        return result.Succeeded;
    }
}
