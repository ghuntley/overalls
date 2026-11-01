using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Mila.Windows.Interop;

/// <summary>
/// The fixture's closed stand-in actions (`POST &lt;fixture_url&gt;&lt;action&gt;`, ADR-0264):
/// `observe` stands in for the provisioner after a lifecycle intent, and the
/// `thread-*` actions stand in for the agent's thread, question and plan.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:verification;security] mila-windows-journey-fixture-hook
/// A hook call MUST use the descriptor's HTTPS fixture URL with the pinned
/// handler and bearer, carry only its canonical UUID input, accept only a 200
/// response of at most 64 KiB, and never print the bearer.
/// </remarks>
internal sealed class MilaFixtureHook(MilaJourneyDescriptor descriptor, HttpMessageHandler handler)
{
    private const int MaxBytes = 64 * 1024;
    private static readonly string[] Actions = ["observe", "thread-create", "thread-ready", "thread-question", "thread-proposal"];

    internal async Task<JsonElement> PostAsync(string action, Guid? machine, Guid? thread, CancellationToken cancellationToken)
    {
        if (!Actions.Contains(action, StringComparer.Ordinal)) throw new ArgumentOutOfRangeException(nameof(action));
        Uri hookBase = descriptor.FixtureUrl ?? throw new InvalidOperationException("journey fixture hook missing (approver.fixture_url)");
        if (!hookBase.AbsolutePath.EndsWith('/')) hookBase = new Uri(hookBase.AbsoluteUri + "/");
        Dictionary<string, string> body = [];
        if (machine is { } machineId) body["machine_id"] = machineId.ToString("D");
        if (thread is { } threadId) body["thread_id"] = threadId.ToString("D");
        // The fixture may wait for the stand-in to settle; its hooks answer within 330 s.
        using HttpClient client = new(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(330) };
        using HttpRequestMessage request = new(HttpMethod.Post, new Uri(hookBase, action))
        {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", descriptor.ApproverToken);
        using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if ((int)response.StatusCode != 200) throw new InvalidOperationException($"journey fixture {action} returned {(int)response.StatusCode}");
        if (response.Content.Headers.ContentLength > MaxBytes) throw new InvalidOperationException($"journey fixture {action} reply too large");
        byte[] bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (bytes.Length > MaxBytes) throw new InvalidOperationException($"journey fixture {action} reply too large");
        using JsonDocument document = JsonDocument.Parse(bytes);
        return document.RootElement.Clone();
    }
}

/// <summary>
/// @cc [owner:ghuntley,label:verification] mila-windows-journey-pages
/// Lifecycle, web, threads and the guest terminal against the tunnelled
/// fixture, through the staged Rust library and the WinUI client's interop.
/// Every step MUST assert its effect through a session read (listing desired
/// state, `web show`, `thread ls`/`show`/`turns`, terminal output), not only
/// the mutation's status. Lifecycle intents are observed by the fixture's
/// provisioner stand-in; a closed busy refusal is retried with a fresh request
/// id until the step deadline, and any other refusal fails the step.
/// </summary>
internal static class JourneyPages
{
    internal const string Prompt = "Report the hostname please";
    internal const string Answer = """{"approach":{"selected":"First","text":""}}""";
    private static readonly TimeSpan StepDeadline = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private static readonly string[] BusyRefusals = ["vm_busy", "temporarily_unavailable", "workload_not_stable"];
    private static readonly string[] TerminalReadiness = ["terminal_open_pending", "terminal_unavailable", "temporarily_unavailable"];

    private static void Step(string name) => Console.WriteLine("journey: " + name + " ok");

    private static string RequestId() => "porsche-" + Guid.NewGuid().ToString("N");

    /// <summary>Submits a mutation, retrying closed busy refusals with a fresh request id.</summary>
    private static async Task SubmitAsync(ulong handle, string name, Func<string, MilaNativeStatus> operation, CancellationToken cancellationToken)
    {
        DateTime deadline = DateTime.UtcNow + StepDeadline;
        while (true)
        {
            MilaNativeStatus status = operation(RequestId());
            if (status == MilaNativeStatus.Ok) return;
            string? refusal = RustNative.TrySessionLastRefusal(handle);
            if (refusal is null || !BusyRefusals.Contains(refusal, StringComparer.Ordinal) || DateTime.UtcNow >= deadline)
                throw new InvalidOperationException($"journey {name} ({status}/{refusal ?? "none"})");
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }
    }

    /// <summary>Polls a read until it reports a pass code; null means not yet.</summary>
    private static async Task<string> AwaitAsync(string name, Func<string?> check, CancellationToken cancellationToken)
    {
        DateTime deadline = DateTime.UtcNow + StepDeadline;
        while (true)
        {
            if (check() is { } code) return code;
            if (DateTime.UtcNow >= deadline) throw new InvalidOperationException($"journey {name} (timeout)");
            await Task.Delay(PollInterval, cancellationToken);
        }
    }

    private static IReadOnlyList<MilaMachineRow> Machines(ulong handle)
    {
        Program.Require(RustNative.TrySessionReadMachines(handle, false) == MilaNativeStatus.Ok, "journey machine read");
        MilaNativeSessionBytesResult listing = RustNative.TrySessionListing(handle);
        Program.Require(listing.Succeeded, "journey machine listing");
        return RustNative.DecodeSessionListing(listing.Data!).Machines;
    }

    private static MilaMachineRow? Named(ulong handle, string name) => Machines(handle).FirstOrDefault(row => row.Name == name);

    private static async Task<string> ObserveAsync(MilaFixtureHook hook, Guid machine, CancellationToken cancellationToken)
    {
        JsonElement observed = await hook.PostAsync("observe", machine, null, cancellationToken);
        return observed.TryGetProperty("observed_state", out JsonElement state) && state.ValueKind == JsonValueKind.String
            ? state.GetString()! : throw new InvalidOperationException("journey fixture observe reply");
    }

    private static async Task<Guid> CreateAsync(ulong handle, string name, uint cpu, ulong memory, ulong disk, CancellationToken cancellationToken)
    {
        await SubmitAsync(handle, "lifecycle create", request => RustNative.TrySessionMachineCreate(handle, name, cpu, memory, disk, request).Status,
            cancellationToken);
        MilaMachineRow? created = null;
        await AwaitAsync("lifecycle create", () => (created = Named(handle, name)) is null ? null : "listed", cancellationToken);
        return created!.Id;
    }

    /// <summary>
    /// Create, stop, start, pause, resume and delete a machine this run creates,
    /// then resize a second one last: an unapplied resize keeps its machine
    /// busy (`resize_in_progress`), so it cannot share the other steps' machine.
    /// </summary>
    internal static async Task LifecycleAsync(ulong handle, MilaFixtureHook hook, CancellationToken cancellationToken)
    {
        string name = "mila-journey-" + Guid.NewGuid().ToString("N")[..12];
        Guid machine = await CreateAsync(handle, name, 1, 512, 2, cancellationToken);
        await ObserveAsync(hook, machine, cancellationToken);
        Step("lifecycle create");

        foreach ((string action, string desired) in new[] { ("stop", "stopped"), ("start", "running"), ("pause", "paused"), ("resume", "running") })
        {
            await SubmitAsync(handle, "lifecycle " + action, request => RustNative.TrySessionMachineAction(handle, machine, action, request).Status,
                cancellationToken);
            await AwaitAsync("lifecycle " + action, () => Named(handle, name)?.DesiredState == desired ? desired : null, cancellationToken);
            string observed = await ObserveAsync(hook, machine, cancellationToken);
            Program.Require(action is "pause" or "resume" || observed == desired, $"journey lifecycle {action} observed {observed}");
            Step($"lifecycle {action} ({desired})");
        }

        await SubmitAsync(handle, "lifecycle delete", request => RustNative.TrySessionMachineAction(handle, machine, "rm", request).Status,
            cancellationToken);
        await AwaitAsync("lifecycle delete", () => Named(handle, name) is not { } row ? "absent"
            : row.DesiredState is "deleted" or "deleting" ? "deleting" : null, cancellationToken);
        // The deletion holds capacity until the provisioner stand-in observes it.
        try { await ObserveAsync(hook, machine, cancellationToken); }
        catch (InvalidOperationException) { }
        Step("lifecycle delete");

        string resizeName = name + "-r";
        Guid resized = await CreateAsync(handle, resizeName, 1, 512, 2, cancellationToken);
        await ObserveAsync(hook, resized, cancellationToken);
        await SubmitAsync(handle, "lifecycle resize", request => RustNative.TrySessionMachineResize(handle, resized, 2, 1024, 3, request).Status,
            cancellationToken);
        Step("lifecycle resize (requested)");
        await RemoveAsync(handle, hook, resized, cancellationToken);
    }

    /// <summary>Best-effort removal of the resize machine; a pinned resize can keep it busy for a while.</summary>
    private static async Task RemoveAsync(ulong handle, MilaFixtureHook hook, Guid machine, CancellationToken cancellationToken)
    {
        DateTime deadline = DateTime.UtcNow + StepDeadline;
        while (DateTime.UtcNow < deadline)
        {
            try { await ObserveAsync(hook, machine, cancellationToken); }
            catch (InvalidOperationException) { }
            if (RustNative.TrySessionMachineAction(handle, machine, "rm", RequestId()).Succeeded) return;
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }
    }

    private static MilaWebEndpoint WebShow(ulong handle, Guid machine)
    {
        MilaNativeSessionBytesResult shown = RustNative.TrySessionWebShow(handle, machine);
        Program.Require(shown.Succeeded, $"journey web show ({shown.Status})");
        return MilaWebEndpointDecoder.Decode(shown.Data!, machine);
    }

    /// <summary>Web show, then public and back to private, each at the current revision and read back at a newer one.</summary>
    internal static async Task WebAsync(ulong handle, Guid seed, CancellationToken cancellationToken)
    {
        MilaWebEndpoint before = WebShow(handle, seed);
        Step("web show");
        foreach (bool isPublic in new[] { true, false })
        {
            MilaWebEndpoint current = WebShow(handle, seed);
            await SubmitAsync(handle, "web set", request => RustNative.TrySessionWebSet(handle, seed, before.Port, isPublic, current.Revision, request).Status,
                cancellationToken);
            string code = await AwaitAsync("web set", () => WebShow(handle, seed) is var after && after.IsPublic == isPublic && after.Revision > current.Revision
                ? (isPublic ? "public" : "private") : null, cancellationToken);
            Step("web set " + code);
        }
    }

    private static JsonElement ThreadRead(ulong handle, Guid thread, string command)
    {
        MilaNativeSessionBytesResult read = RustNative.TrySessionThreadAction(handle, thread, command, null, null, null);
        Program.Require(read.Succeeded, $"journey {command} ({read.Status})");
        using JsonDocument document = JsonDocument.Parse(read.Data!);
        return MilaPorscheEnvelope.Result(document.RootElement).Clone();
    }

    private static Guid? ControlId(JsonElement detail, string name, bool openOnly = false) =>
        detail.TryGetProperty(name, out JsonElement control) && control.ValueKind == JsonValueKind.Object &&
        !(openOnly && control.TryGetProperty("implemented", out JsonElement implemented) && implemented.ValueKind == JsonValueKind.True) &&
        control.TryGetProperty("id", out JsonElement id) && id.ValueKind == JsonValueKind.String &&
        Guid.TryParseExact(id.GetString(), "D", out Guid parsed) ? parsed : null;

    private static Guid HookId(JsonElement reply, string name, string action) =>
        reply.TryGetProperty(name, out JsonElement id) && id.ValueKind == JsonValueKind.String &&
        Guid.TryParseExact(id.GetString(), "D", out Guid parsed) ? parsed : throw new InvalidOperationException($"journey fixture {action} reply");

    /// <summary>List, prompt, answer and plan approval through the WinUI thread controller.</summary>
    internal static async Task ThreadsAsync(ulong handle, MilaFixtureHook hook, CancellationToken cancellationToken)
    {
        Guid thread = HookId(await hook.PostAsync("thread-create", null, null, cancellationToken), "thread_id", "thread-create");
        JsonElement ready = await hook.PostAsync("thread-ready", null, thread, cancellationToken);
        Program.Require(ready.TryGetProperty("status", out JsonElement status) && status.GetString() == "ready", "journey fixture thread ready");

        MilaNativeSessionBytesResult listed = RustNative.TrySessionThreadAction(handle, null, "thread ls", null, null, null);
        Program.Require(listed.Succeeded, $"journey thread ls ({listed.Status})");
        MilaThreadListing listing = MilaThreadListing.Decode(listed.Data!);
        MilaThreadController threads = new();
        threads.SetSession(true, listing);
        Program.Require(threads.Select(thread), "journey created thread is listed");
        Step("threads list");

        ulong before = ThreadRead(handle, thread, "thread show").TryGetProperty("last_sequence", out JsonElement last) &&
            last.ValueKind == JsonValueKind.Number ? last.GetUInt64() : 0;
        Program.Require(threads.SubmitLive(handle, MilaThreadAction.Prompt, null, Prompt), "journey thread prompt");
        await AwaitAsync("thread prompt", () => ThreadRead(handle, thread, "thread turns").GetProperty("items").EnumerateArray()
            .Any(item => item.GetProperty("kind").GetString() == "prompt" && item.GetProperty("sequence").GetUInt64() > before)
            ? "prompt_recorded" : null, cancellationToken);
        Step("threads prompt");

        Guid question = HookId(await hook.PostAsync("thread-question", null, thread, cancellationToken), "question_id", "thread-question");
        Program.Require(ControlId(ThreadRead(handle, thread, "thread show"), "pending_question") == question, "journey thread question pending");
        Program.Require(threads.SubmitLive(handle, MilaThreadAction.Answer, question.ToString("D"), Answer), "journey thread answer");
        await AwaitAsync("thread answer", () => ControlId(ThreadRead(handle, thread, "thread show"), "pending_question") != question
            ? "answered" : null, cancellationToken);
        Step("threads answer");

        Guid plan = HookId(await hook.PostAsync("thread-proposal", null, thread, cancellationToken), "plan_id", "thread-proposal");
        Program.Require(ControlId(ThreadRead(handle, thread, "thread show"), "latest_plan", openOnly: true) == plan, "journey thread plan open");
        Program.Require(threads.SubmitLive(handle, MilaThreadAction.PlanApprove, plan.ToString("D")), "journey thread plan approve");
        await AwaitAsync("thread plan approve", () => ControlId(ThreadRead(handle, thread, "thread show"), "latest_plan", openOnly: true) != plan
            ? "approved" : null, cancellationToken);
        Step("threads plan approve");
    }

    /// <summary>
    /// The guest-backed terminal: echo a computed marker, resize to 132x40 and
    /// read it back with `stty size`, detach, and reattach the same named
    /// session with the marker replayed.
    /// </summary>
    internal static async Task GuestTerminalAsync(MilaSessionConnection session, Guid machine, CancellationToken cancellationToken)
    {
        ulong handle = session.Handle ?? throw new InvalidOperationException("journey session lost");
        MilaTerminalStream first = await AttachAsync(session, handle, machine, 100, 30, cancellationToken);
        string terminalId = first.TerminalId!;
        string marker = "mila-" + Guid.NewGuid().ToString("N")[..12];
        Send(first, $"echo {marker}-$((6*7))\r");
        await UntilAsync(first, marker + "-42", TimeSpan.FromSeconds(60), "guest terminal output", cancellationToken);
        Step("guest terminal echo");

        Program.Require(RustNative.TrySessionTerminalResize(first.Session.NativeTerminalHandle, 132, 40) == MilaNativeStatus.Ok,
            "journey guest terminal resize");
        Send(first, "stty size\r");
        await UntilAsync(first, "40 132", TimeSpan.FromSeconds(30), "guest terminal resize", cancellationToken);
        Step("guest terminal resize 132x40");

        first.Kill();
        MilaTerminalStream second = await AttachAsync(session, handle, machine, 132, 40, cancellationToken);
        Program.Require(second.TerminalId == terminalId, "journey guest terminal rejoins the named session");
        await UntilAsync(second, marker + "-42", TimeSpan.FromSeconds(60), "guest terminal replay", cancellationToken);
        second.Kill();
        Step("guest terminal detach and reattach with replay");
    }

    /// <summary>Attaches, retrying only the closed readiness refusals until 180 s.</summary>
    private static async Task<MilaTerminalStream> AttachAsync(
        MilaSessionConnection session, ulong handle, Guid machine, ushort columns, ushort rows, CancellationToken cancellationToken)
    {
        MilaTerminalStream stream = new(MilaRustTerminalTransport.Instance, () => session.Handle);
        DateTime deadline = DateTime.UtcNow + TimeSpan.FromMinutes(3);
        while (!stream.Attach(machine, true, columns, rows))
        {
            string? refusal = RustNative.TrySessionLastRefusal(handle);
            if (refusal is null || !TerminalReadiness.Contains(refusal, StringComparer.Ordinal) || DateTime.UtcNow >= deadline)
                throw new InvalidOperationException($"journey guest terminal attach ({refusal ?? "none"})");
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
        }
        Program.Require(stream.TerminalId is not null, "journey guest terminal names its session");
        return stream;
    }

    private static void Send(MilaTerminalStream stream, string text) =>
        Program.Require(RustNative.TrySessionTerminalInput(stream.Session.NativeTerminalHandle, Encoding.UTF8.GetBytes(text)) == MilaNativeStatus.Ok,
            "journey guest terminal input");

    private static async Task UntilAsync(MilaTerminalStream stream, string wanted, TimeSpan limit, string name, CancellationToken cancellationToken)
    {
        DateTime deadline = DateTime.UtcNow + limit;
        while (!stream.Session.Output.Contains(wanted, StringComparison.Ordinal))
        {
            MilaTerminalPoll poll = stream.Poll();
            Program.Require(poll is MilaTerminalPoll.Output or MilaTerminalPoll.Idle or MilaTerminalPoll.Reconnected,
                $"journey {name} ({poll})");
            if (DateTime.UtcNow >= deadline) throw new InvalidOperationException($"journey {name} (timeout)");
            if (poll is MilaTerminalPoll.Idle) await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken);
        }
    }
}
