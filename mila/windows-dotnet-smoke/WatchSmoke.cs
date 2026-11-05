using Mila.Windows.Interop;
internal static class WatchSmoke
{
    internal static void Run()
    {
        static Guid Id(int value) => Guid.Parse($"00000000-0000-0000-0000-{value:D12}");

        Guid[] machineIds = Enumerable.Range(0, 300).Select(Id).ToArray();
        IReadOnlyList<MilaWatchFilters> machineGroups = MilaWatchFilters.Groups(machineIds, Array.Empty<Guid>());
        Program.Require(machineGroups.Count == 5, "watch shards machine filters");
        Program.Require(machineGroups.All(group => group.Machines.Count is > 0 and <= 64 && group.Threads.Count == 0),
            "watch machine shards stay within native filter bound");
        Program.Require(machineGroups.SelectMany(group => group.Machines).Distinct().Count() == 300,
            "watch retains the bounded machine filter set");

        Guid[] threadIds = Enumerable.Range(0, 130).Select(Id).ToArray();
        IReadOnlyList<MilaWatchFilters> threadGroups = MilaWatchFilters.Groups(Array.Empty<Guid>(), threadIds);
        Program.Require(threadGroups.Count == 3, "watch shards thread filters");
        Program.Require(threadGroups.All(group => group.Machines.Count == 0 && group.Threads.Count is > 0 and <= 64),
            "watch thread shards stay within native filter bound");
        Program.Require(threadGroups.SelectMany(group => group.Threads).Distinct().Count() == 130,
            "watch retains every bounded thread filter");

        Guid duplicate = Id(1);
        IReadOnlyList<MilaWatchFilters> deduplicated = MilaWatchFilters.Groups(
            new[] { duplicate, duplicate, Id(2) }, Array.Empty<Guid>());
        Program.Require(deduplicated.Count == 1 && deduplicated[0].Machines.Count == 2,
            "watch filter shards deduplicate IDs");
        Guid[] duplicateHeavy = Enumerable.Range(0, 510).Select(Id)
            .SelectMany(id => Enumerable.Repeat(id, 2)).Append(Id(999)).ToArray();
        IReadOnlyList<MilaWatchFilters> duplicateHeavyGroups = MilaWatchFilters.Groups(
            duplicateHeavy, Array.Empty<Guid>());
        Program.Require(duplicateHeavyGroups.SelectMany(group => group.Machines).Distinct().Count() == 500,
            "watch deduplicates before applying the bounded filter window");
        IReadOnlyList<MilaWatchFilters> full = MilaWatchFilters.Groups(
            Enumerable.Range(0, 510).Select(Id).ToArray(), Enumerable.Range(0, 270).Select(Id).ToArray());
        Program.Require(full.Count == 12 && full.All(group => group.Machines.Count + group.Threads.Count <= 64) &&
            full.Sum(group => group.Machines.Count) == 500 && full.Sum(group => group.Threads.Count) == 256,
            "watch covers full bounded machine and thread projections in twelve protocol-sized subscriptions");
        IReadOnlyList<MilaWatchFilters> empty = MilaWatchFilters.Groups(Array.Empty<Guid>(), Array.Empty<Guid>());
        Program.Require(empty.Count == 1 && empty[0].Machines.Count == 0 && empty[0].Threads.Count == 0,
            "watch keeps an unfiltered subscription when no IDs are selected");

        Program.Require(MilaWatchStream.NeedsRefresh("{\"version\":1,\"event\":\"resync\"}"u8), "watch reconnect resync refreshes reads");
        Program.Require(MilaWatchStream.NeedsRefresh("{\"version\":1,\"event\":\"machine\"}"u8), "machine hint refreshes authenticated state");
        Program.Require(!MilaWatchStream.NeedsRefresh("{\"version\":1,\"event\":\"heartbeat\"}"u8), "heartbeat is not a machine update");
        Program.Require(Refuses("{\"event\":\"machine\"}"u8), "watch refuses a missing version");
        Program.Require(Refuses("{\"version\":1,\"event\":7}"u8), "watch refuses a non-string event");
        bool refused = false;
        try { MilaWatchStream.NeedsRefresh(new byte[8193]); }
        catch (InvalidDataException) { refused = true; }
        Program.Require(refused, "watch rejects oversized external output");
    }

    private static bool Refuses(ReadOnlySpan<byte> bytes)
    {
        try { _ = MilaWatchStream.NeedsRefresh(bytes); return false; }
        catch (InvalidDataException) { return true; }
    }
}
