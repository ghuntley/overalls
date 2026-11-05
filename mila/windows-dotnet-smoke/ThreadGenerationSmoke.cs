using Mila.Windows.Interop;

internal static class ThreadGenerationSmoke
{
    internal static void Run()
    {
        Guid first = Guid.NewGuid();
        Guid second = Guid.NewGuid();
        MilaThreadListing listing = new([
            new(first, "first", "ready"), new(second, "second", "ready")], false);
        foreach (bool replaceSession in new[] { false, true })
        {
            using ManualResetEventSlim entered = new(false);
            using ManualResetEventSlim release = new(false);
            int submitted = 0;
            MilaThreadController controller = new((handle, thread, command, secondary, input, request) =>
            {
                Program.Require(handle == 42 && thread == first, "thread transport captures the original target");
                Interlocked.Increment(ref submitted);
                entered.Set();
                if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
                return new(MilaNativeStatus.Ok, "{}"u8.ToArray());
            });
            controller.SetSession(true, listing, 42);
            Program.Require(controller.Select(first), "thread selection is authenticated");
            Task<bool> pending = Task.Run(() => controller.SubmitLive(42, MilaThreadAction.Prompt, input: "hello"));
            try
            {
                Program.Require(entered.Wait(TimeSpan.FromSeconds(10)), "thread submit began");
                Program.Require(!controller.SubmitLive(42, MilaThreadAction.Prompt, input: "duplicate") && submitted == 1,
                    "one generation cannot submit a second in-flight thread mutation");
                if (replaceSession)
                {
                    controller.SetSession(true, listing, 99);
                    Program.Require(controller.Select(second), "replacement session selection");
                    Program.Require(!controller.SubmitLive(42, MilaThreadAction.Show), "replacement rejects an old session handle");
                }
                else controller.SetSession(false, null);
            }
            finally { release.Set(); }
            Program.Require(pending.Wait(TimeSpan.FromSeconds(10)) && !pending.GetAwaiter().GetResult(),
                "late thread completion is refused");
            Program.Require(replaceSession
                ? controller.State is { Kind: MilaThreadActionStateKind.Ready, Thread.Id: var id } && id == second
                : controller.State.Kind == MilaThreadActionStateKind.SignedOut,
                "late thread result preserves the newer session state");
        }
        int staleSubmissions = 0;
        MilaThreadController changedSelection = new((handle, thread, command, secondary, input, request) =>
        {
            staleSubmissions++;
            return new(MilaNativeStatus.Ok, "{}"u8.ToArray());
        });
        changedSelection.SetSession(true, listing, 42);
        Program.Require(changedSelection.Select(first), "first queued thread target");
        long queuedGeneration = changedSelection.Generation;
        Program.Require(changedSelection.Select(second), "replacement queued thread target");
        Program.Require(!changedSelection.SubmitLive(42, MilaThreadAction.Prompt, input: "old input",
            expectedGeneration: queuedGeneration) && staleSubmissions == 0,
            "queued thread action cannot retarget after selection changes");
    }
}
