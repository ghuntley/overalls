using System.Text.Json;
using Mila.Windows.Interop;

internal static class MachineListingSmoke
{
    internal static void Run()
    {
        List<bool> reads = [];
        int snapshots = 0;
        MilaMachineListingReader complete = new(
            more => { reads.Add(more); return MilaNativeStatus.Ok; },
            () => new(MilaNativeStatus.Ok, Listing(reads.Count, reads.Count == 1)),
            time => { snapshots++; Program.Require(time == 42, "snapshot retains refresh timestamp"); return new(MilaNativeStatus.Ok, [1, 2]); });
        MilaMachineRefreshResult result = complete.Refresh(42);
        Program.Require(reads.SequenceEqual([false, true]) && result.Listing is { Machines.Count: 2, HasMore: false },
            "machine refresh consumes authenticated continuation into the complete Rust projection");
        Program.Require(snapshots == 1 && result.Snapshot is [1, 2], "snapshot follows complete listing once");

        int copies = 0;
        MilaMachineListingReader failed = new(
            _ => MilaNativeStatus.InvalidRequest,
            () => { copies++; return new(MilaNativeStatus.Ok, Listing(1, false)); },
            _ => { snapshots++; return new(MilaNativeStatus.Ok, [1]); });
        snapshots = 0;
        result = failed.Refresh(1);
        Program.Require(result is { Status: MilaNativeStatus.InvalidRequest, Listing: null, Snapshot: null } &&
            copies == 0 && snapshots == 0, "failed fresh read never republishes a cached Rust listing");

        reads.Clear();
        MilaMachineListingReader interrupted = new(
            more => { reads.Add(more); return more ? MilaNativeStatus.Transport : MilaNativeStatus.Ok; },
            () => new(MilaNativeStatus.Ok, Listing(1, true)),
            _ => { snapshots++; return new(MilaNativeStatus.Ok, [1]); });
        result = interrupted.Refresh(1);
        Program.Require(reads.SequenceEqual([false, true]) &&
            result is { Status: MilaNativeStatus.Transport, Listing: null, Snapshot: null } && snapshots == 0,
            "interrupted continuation never publishes partial fresh rows or a snapshot");

        int pages = 0;
        MilaMachineListingReader unbounded = new(
            _ => { pages++; return MilaNativeStatus.Ok; },
            () => new(MilaNativeStatus.Ok, Listing(0, true)),
            _ => throw new InvalidOperationException("incomplete snapshot requested"));
        result = unbounded.Refresh(1);
        Program.Require(pages == 500 && result.Listing is null, "machine pagination has a fixed total read bound");
        Program.Require(MilaSessionListing.Decode(Listing(500, false)).Machines.Count == 500,
            "machine projection retains Rust's full 500-row bound");
        bool oversized = false;
        try { _ = MilaSessionListing.Decode(Listing(501, false)); }
        catch (InvalidDataException) { oversized = true; }
        Program.Require(oversized, "machine projection rejects more than Rust's 500-row bound");
        MilaMachineListingReader malformed = new(
            _ => MilaNativeStatus.Ok,
            () => new(MilaNativeStatus.Ok, "{"u8.ToArray()),
            _ => throw new InvalidOperationException("malformed snapshot requested"));
        Program.Require(malformed.Refresh(1).Listing is null, "malformed live projection fails closed");
    }

    private static byte[] Listing(int count, bool more) => JsonSerializer.SerializeToUtf8Bytes(new
    {
        machines = Enumerable.Range(1, count).Select(index => new
        {
            id = $"00000000-0000-0000-0000-{index:D12}",
            name = $"machine-{index}",
            desired_state = "running",
            observed_state = "running",
            pinned = false,
            read = true,
            write = true,
            manage = true,
        }),
        has_more = more,
    });
}
