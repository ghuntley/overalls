using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using Mila.Windows.Interop;

internal static class TerminalGenerationSmoke
{
    private static readonly Guid Machine = Guid.Parse("019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a");

    internal static void Run()
    {
        foreach (Operation operation in new[] { Operation.Open, Operation.Attach, Operation.State })
            foreach (Replacement replacement in Enum.GetValues<Replacement>())
                AttachCompletion(operation, replacement);
        foreach (MilaNativeStatus status in new[] { MilaNativeStatus.Ok, MilaNativeStatus.Transport, MilaNativeStatus.InvalidHandle })
            ReadCompletion(status);
        ScreenCompletion();
        ParentReplacement();
        UncertainOpen();
        BusyRejoin();
        LostAttachReopen();
        CleanClose();
        NativeStateBoundary();
        ProjectionBufferBoundary();
        foreach (MilaTerminalOutcome outcome in Enum.GetValues<MilaTerminalOutcome>())
        {
            ClosedAttach(outcome);
            ClosedRead(outcome);
        }
        InvalidAttachBoundary();
    }

    private enum Operation { None, Open, Attach, State, Read, Screen }
    private enum Replacement { Kill, SignOut, Attach, Parent }

    private sealed class Transport(Operation blocked = Operation.None) : IMilaTerminalTransport, IDisposable
    {
        internal readonly ManualResetEventSlim Entered = new(false);
        internal readonly ManualResetEventSlim Release = new(false);
        internal readonly ConcurrentQueue<ulong> Killed = new();
        internal int Opens;
        internal int Attaches;
        internal int Reads;
        internal int Ends;
        internal int BusyCloses;
        private int screens;
        private int states;
        private readonly ConcurrentDictionary<ulong, MilaNativeTerminalState> nativeStates = new();
        internal MilaNativeStatus ReadStatus = MilaNativeStatus.Ok;
        internal MilaTerminalReadEvent ReadEvent = MilaTerminalReadEvent.Data;
        internal MilaNativeStatus OpenStatus = MilaNativeStatus.Ok;
        internal MilaNativeStatus FirstAttachStatus = MilaNativeStatus.Ok;
        internal byte[]? FirstStatePayload;
        internal MilaTerminalOutcome ReadOutcome = MilaTerminalOutcome.Closed;

        private void Block(Operation operation, int count)
        {
            if (blocked != operation || count != 1) return;
            Entered.Set();
            if (!Release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
        }

        public MilaNativeTerminalOpen Open(ulong sessionHandle, Guid machineId)
        {
            int call = Interlocked.Increment(ref Opens);
            Block(Operation.Open, call);
            return new(OpenStatus, OpenStatus == MilaNativeStatus.Ok ? $"019a0f73-3d4e-7f5a-8b6c-{call:x12}" : null);
        }
        public (MilaNativeStatus Status, ulong? Handle) Attach(ulong sessionHandle, Guid machineId,
            string terminalId, ushort columns, ushort rows)
        {
            int call = Interlocked.Increment(ref Attaches);
            Block(Operation.Attach, call);
            MilaNativeStatus status = call == 1 ? FirstAttachStatus : MilaNativeStatus.Ok;
            return (status, status == MilaNativeStatus.Ok ? 100UL + (ulong)call : null);
        }
        public MilaNativeTerminalRead Read(ulong terminalHandle)
        {
            Block(Operation.Read, Interlocked.Increment(ref Reads));
            if (ReadStatus == MilaNativeStatus.Ok && ReadEvent == MilaTerminalReadEvent.Closed)
                nativeStates[terminalHandle] = new(0, false, true, ReadOutcome);
            return new(ReadStatus, ReadEvent, ReadStatus == MilaNativeStatus.Ok && ReadEvent == MilaTerminalReadEvent.Data
                ? Encoding.UTF8.GetBytes("old") : null);
        }
        public MilaNativeTerminalStateResult State(ulong terminalHandle)
        {
            int call = Interlocked.Increment(ref states);
            Block(Operation.State, call);
            if (call == 1 && FirstStatePayload is { } bytes)
                return RustNative.DecodeTerminalState(bytes) is { } state
                    ? new(MilaNativeStatus.Ok, state) : new(MilaNativeStatus.InvalidRequest, null);
            return new(MilaNativeStatus.Ok, nativeStates.GetValueOrDefault(terminalHandle, new(0, false, false, null)));
        }
        public MilaTerminalFrame? Screen(ulong terminalHandle)
        {
            Block(Operation.Screen, Interlocked.Increment(ref screens));
            return blocked == Operation.Screen ? Frame() : null;
        }
        public MilaNativeStatus Kill(ulong terminalHandle)
        {
            if (blocked is Operation.Read or Operation.Screen && Entered.IsSet && !Release.IsSet)
            { Interlocked.Increment(ref BusyCloses); return MilaNativeStatus.Busy; }
            Killed.Enqueue(terminalHandle);
            return MilaNativeStatus.Ok;
        }
        public bool End(ulong sessionHandle, Guid machineId, string terminalId) { Interlocked.Increment(ref Ends); return true; }
        public void Dispose() { Release.Set(); Entered.Dispose(); Release.Dispose(); }
    }

    private static MilaTerminalFrame Frame() => new()
    {
        Version = 1, Columns = 80, Rows = 24, CursorColumn = 0, CursorRow = 0,
        Images = [], Lines = [[new MilaTerminalSpan
        {
            Text = "old", Foreground = null, Background = null,
            Bold = false, Italic = false, Underline = false, Inverse = false,
        }]],
    };

    private static void AttachCompletion(Operation operation, Replacement replacement)
    {
        long parent = 7;
        using Transport transport = new(operation);
        MilaTerminalStream stream = new(transport, () => (ulong)Volatile.Read(ref parent));
        Task<bool> pending = Task.Run(() => stream.Attach(Machine, true, 80, 24));
        ulong newer = 0;
        try
        {
            Program.Require(transport.Entered.Wait(TimeSpan.FromSeconds(10)), "terminal acquisition began");
            switch (replacement)
            {
                case Replacement.Kill: stream.Kill(); break;
                case Replacement.SignOut: stream.SignOut(); break;
                case Replacement.Attach:
                    Program.Require(stream.Attach(Machine, true, 132, 40), "replacement terminal acquired");
                    newer = stream.Session.NativeTerminalHandle;
                    break;
                case Replacement.Parent: Interlocked.Exchange(ref parent, 99); break;
            }
        }
        finally { transport.Release.Set(); }
        Program.Require(pending.Wait(TimeSpan.FromSeconds(10)) && !pending.GetAwaiter().GetResult(),
            "obsolete terminal acquisition cannot publish");
        Program.Require(stream.Session.NativeTerminalHandle == newer && stream.Session.Output.Length == 0,
            "obsolete acquisition preserves the current terminal projection");
        if (operation is Operation.Attach or Operation.State)
            Program.Require(transport.Killed.Count(handle => handle == 101) == 1 && !transport.Killed.Contains(newer),
                "obsolete acquired PTY closes exactly once without closing its replacement");
        else Program.Require(transport.Attaches == (replacement == Replacement.Attach ? 1 : 0),
            "obsolete terminal-new result never begins PTY attachment");
        stream.SignOut();
    }

    private static void ReadCompletion(MilaNativeStatus status)
    {
        using Transport transport = new(Operation.Read) { ReadStatus = status };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(stream.Attach(Machine, true, 80, 24), "initial terminal attaches");
        Task<MilaTerminalPoll> pending = Task.Run(stream.Poll);
        try
        {
            Program.Require(transport.Entered.Wait(TimeSpan.FromSeconds(10)), "terminal read began");
            Program.Require(stream.Poll() == MilaTerminalPoll.Idle && transport.Reads == 1,
                "one terminal cannot run overlapping native reads");
            Program.Require(stream.Attach(Machine, true, 132, 40), "terminal replaces a blocked read");
        }
        finally { transport.Release.Set(); }
        Program.Require(pending.Wait(TimeSpan.FromSeconds(10)) && pending.GetAwaiter().GetResult() != MilaTerminalPoll.Output &&
            stream.Session.NativeTerminalHandle == 102 && stream.Session.Output.Length == 0,
            "late output, loss and invalid-handle results cannot mutate a replacement terminal");
        Program.Require(transport.Killed.SequenceEqual([101UL]) && transport.Attaches == 2 && transport.BusyCloses == 0,
            "late read closes no replacement and starts no reconnect");
        stream.SignOut();
    }

    private static void ScreenCompletion()
    {
        using Transport transport = new(Operation.Screen);
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(stream.Attach(Machine, true, 80, 24), "screen terminal attaches");
        Task<MilaTerminalPoll> pending = Task.Run(stream.Poll);
        try
        {
            Program.Require(transport.Entered.Wait(TimeSpan.FromSeconds(10)), "terminal frame read began");
            stream.SignOut();
        }
        finally { transport.Release.Set(); }
        Program.Require(pending.Wait(TimeSpan.FromSeconds(10)) && pending.GetAwaiter().GetResult() != MilaTerminalPoll.Output &&
            stream.Session.Frame is null && stream.Session.Output.Length == 0 && stream.Session.State == MilaTerminalState.SignedOut,
            "late rich frame cannot repopulate a signed-out viewport");
        Program.Require(transport.BusyCloses == 0 && transport.Killed.SequenceEqual([101UL]),
            "sign-out retires the frame reader's handle and closes it after the bounded operation finishes");
    }

    private static void ParentReplacement()
    {
        long parent = 7;
        using Transport transport = new();
        MilaTerminalStream stream = new(transport, () => (ulong)Volatile.Read(ref parent));
        Program.Require(stream.Attach(Machine, true, 80, 24), "parent-bound terminal attaches");
        stream.Session.ApplyFrame(stream.Generation, Frame());
        Interlocked.Exchange(ref parent, 99);
        Program.Require(stream.Poll() == MilaTerminalPoll.SignedOut && transport.Reads == 0 &&
            stream.Session.Frame is null && stream.Session.Output.Length == 0 && transport.Killed.SequenceEqual([101UL]),
            "true-to-true parent replacement closes the old terminal before any read");
        Program.Require(!stream.End() && transport.Ends == 0, "old terminal end cannot target the replacement deployment");
        Program.Require(stream.Open(Machine, true, 80, 24) && transport.Opens == 2,
            "replacement parent cannot reuse saved terminal names from its predecessor");
        stream.SignOut();
    }

    private static void UncertainOpen()
    {
        using Transport transport = new() { OpenStatus = MilaNativeStatus.Transport };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(!stream.Attach(Machine, true, 80, 24) && stream.Poll() == MilaTerminalPoll.Detached &&
            stream.Poll() == MilaTerminalPoll.Detached && transport.Opens == 1 && transport.Attaches == 0,
            "uncertain terminal-new mutation is not resubmitted by reconnect polling");
    }

    private static void BusyRejoin()
    {
        using Transport transport = new() { FirstAttachStatus = MilaNativeStatus.Busy };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(!stream.Attach(Machine, true, 80, 24) && stream.TerminalId is not null,
            "busy attachment retains its existing server session name");
        Program.Require(stream.Poll() == MilaTerminalPoll.Reconnected && transport.Opens == 1 && transport.Attaches == 2,
            "busy attachment retries the same named session without a second terminal-new mutation");
        stream.SignOut();
    }

    private static void CleanClose()
    {
        using Transport transport = new() { ReadEvent = MilaTerminalReadEvent.Closed };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(stream.Attach(Machine, true, 80, 24) && stream.Poll() == MilaTerminalPoll.Ended &&
            transport.Killed.SequenceEqual([101UL]), "clean EOF releases its native terminal handle");
        stream.SignOut();
        Program.Require(transport.Killed.SequenceEqual([101UL]), "sign-out does not close an EOF handle twice");
    }

    private static void LostAttachReopen()
    {
        using Transport transport = new() { FirstAttachStatus = MilaNativeStatus.Transport };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(!stream.Open(Machine, true, 80, 24) && stream.TerminalId is not null,
            "a lost first PTY attachment retains its newly opened server session");
        Program.Require(stream.Open(Machine, true, 80, 24) && transport.Opens == 1 && transport.Attaches == 2,
            "reopening after first-attach loss rejoins without duplicating terminal new");
        stream.SignOut();
    }

    private static byte[] ClosedState(MilaTerminalOutcome outcome) => Encoding.UTF8.GetBytes(
        "{\"version\":1,\"cursor\":0,\"read_only\":true,\"closed\":true,\"outcome\":\"" +
        outcome.ToString().ToLowerInvariant() + "\"}");

    private static void ClosedAttach(MilaTerminalOutcome outcome)
    {
        using Transport transport = new() { FirstStatePayload = ClosedState(outcome) };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(!stream.Open(Machine, true, 80, 24) && stream.Session.NativeTerminalHandle == 0 &&
            transport.Killed.SequenceEqual([101UL]), "closed native attachment is never published and closes once");
        if (outcome is MilaTerminalOutcome.Refused or MilaTerminalOutcome.Transport)
        {
            Program.Require(stream.Session.State == MilaTerminalState.Reconnecting &&
                (outcome == MilaTerminalOutcome.Refused ? stream.TerminalId is null : stream.TerminalId is not null),
                "only an explicit refusal forgets the saved session name");
            Program.Require(stream.Poll() == MilaTerminalPoll.Reconnected && transport.Attaches == 2 &&
                transport.Opens == (outcome == MilaTerminalOutcome.Refused ? 2 : 1),
                "refusal permits a new session while transient transport rejoins the same session");
        }
        else
        {
            Program.Require(stream.Session.State == (outcome == MilaTerminalOutcome.Authority
                    ? MilaTerminalState.SignedOut : MilaTerminalState.Failed) &&
                stream.Poll() == MilaTerminalPoll.Detached && transport.Opens == 1 && transport.Attaches == 1,
                "authority, invalid and clean-close outcomes prevent automatic attach or terminal new");
        }
        stream.SignOut();
        Program.Require(transport.Killed.Count(handle => handle == 101) == 1, "closed attachment is not closed twice at sign-out");
    }

    private static void ClosedRead(MilaTerminalOutcome outcome)
    {
        using Transport transport = new() { ReadEvent = MilaTerminalReadEvent.Closed, ReadOutcome = outcome };
        MilaTerminalStream stream = new(transport, () => 7);
        Program.Require(stream.Open(Machine, true, 80, 24), "native-outcome terminal starts attached");
        MilaTerminalPoll expected = outcome switch
        {
            MilaTerminalOutcome.Transport => MilaTerminalPoll.Reconnected,
            MilaTerminalOutcome.Authority => MilaTerminalPoll.SignedOut,
            _ => MilaTerminalPoll.Ended,
        };
        Program.Require(stream.Poll() == expected && transport.Opens == 1 &&
            transport.Attaches == (outcome == MilaTerminalOutcome.Transport ? 2 : 1) &&
            transport.Killed.SequenceEqual([101UL]), "native closed outcome distinguishes loss, authority and EOF");
        if (outcome == MilaTerminalOutcome.Refused)
            Program.Require(stream.TerminalId is null && stream.Open(Machine, true, 80, 24) && transport.Opens == 2,
                "a later explicit open replaces a session refused during a read");
        stream.SignOut();
    }

    private static void InvalidAttachBoundary()
    {
        foreach (bool malformedState in new[] { false, true })
        {
            using Transport transport = new()
            {
                FirstAttachStatus = malformedState ? MilaNativeStatus.Ok : MilaNativeStatus.InvalidRequest,
                FirstStatePayload = malformedState ? "{}"u8.ToArray() : null,
            };
            MilaTerminalStream stream = new(transport, () => 7);
            Program.Require(!stream.Open(Machine, true, 80, 24) && stream.TerminalId is not null &&
                stream.Session.State == MilaTerminalState.Failed && stream.Poll() == MilaTerminalPoll.Detached &&
                transport.Opens == 1 && transport.Attaches == 1,
                "malformed native state and generic InvalidRequest do not prove refusal or authorize terminal new");
            stream.SignOut();
        }
    }

    private static void NativeStateBoundary()
    {
        const string open = "{\"version\":1,\"cursor\":9223372036854775807,\"read_only\":false,\"closed\":false,\"outcome\":null}";
        Program.Require(RustNative.DecodeTerminalState(Encoding.UTF8.GetBytes(open)) is
            { Cursor: long.MaxValue, ReadOnly: false, Closed: false, Outcome: null }, "native state validates the signed cursor bound");
        foreach (MilaTerminalOutcome outcome in Enum.GetValues<MilaTerminalOutcome>())
            Program.Require(RustNative.DecodeTerminalState(ClosedState(outcome)) is { Closed: true } state && state.Outcome == outcome,
                "native state decodes each closed transport outcome");
        foreach (string malformed in new[]
        {
            "{}", "[]", open.Replace("9223372036854775807", "9223372036854775808"),
            open.Replace("9223372036854775807", "-1"), open.Replace("\"version\":1", "\"version\":2"),
            open.Replace("\"closed\":false", "\"closed\":true"), open.Replace("\"outcome\":null", "\"outcome\":\"refused\""),
            open.Replace("\"read_only\":false", "\"read_only\":0"), open.Replace("\"outcome\":null", "\"outcome\":\"unknown\""),
            open.Replace("\"version\":1", "\"version\":1,\"version\":1"), open.Replace("\"cursor\":9223372036854775807", "\"extra\":0"),
        }) Program.Require(RustNative.DecodeTerminalState(Encoding.UTF8.GetBytes(malformed)) is null,
            "malformed native state is refused at the typed boundary");
        Program.Require(RustNative.DecodeTerminalState(new byte[1025]) is null &&
            RustNative.TrySessionTerminalState(0).Status == MilaNativeStatus.InvalidRequest &&
            RustNative.TrySessionTerminalState(ulong.MaxValue).Status == MilaNativeStatus.InvalidHandle,
            "production terminal-state FFI validates handles and bounded output");
    }

    private static void ProjectionBufferBoundary()
    {
        foreach (int capacity in new[] { 1024, 1 << 20, MilaSessionListing.MaxBytes, 16 << 20 })
        {
            int calls = 0;
            MilaNativeSessionBytesResult result = RustNative.TrySessionProjectionBytesOnce((output, actualCapacity, written) =>
            {
                calls++;
                Program.Require(actualCapacity == (nuint)capacity, "projection supplies its declared output capacity");
                Marshal.WriteByte(output, 42);
                Marshal.WriteIntPtr(written, (IntPtr)1);
                return MilaNativeStatus.Ok;
            }, capacity);
            Program.Require(result.Succeeded && result.Data is [42] && calls == 1,
                "state, snapshot, listing and frame capacities reach one native boundary call");
        }
        int refusedCalls = 0;
        MilaNativeStatus RefusedCall(IntPtr output, nuint capacity, IntPtr written)
        {
            refusedCalls++;
            return MilaNativeStatus.Ok;
        }
        Program.Require(RustNative.TrySessionProjectionBytesOnce(RefusedCall, (16 << 20) + 1).Status == MilaNativeStatus.InvalidRequest &&
            RustNative.TrySessionBytesOnce(RefusedCall, (256 << 10) + 1).Status == MilaNativeStatus.InvalidRequest && refusedCalls == 0,
            "projection bound and smaller mutation bound refuse before native invocation");
        int oversizedCalls = 0;
        MilaNativeSessionBytesResult oversized = RustNative.TrySessionProjectionBytesOnce((output, capacity, written) =>
        {
            oversizedCalls++;
            Marshal.WriteIntPtr(written, (IntPtr)1025);
            return MilaNativeStatus.Ok;
        }, 1024);
        Program.Require(oversized.Status == MilaNativeStatus.InvalidRequest && oversized.Data is null && oversizedCalls == 1,
            "oversized native output is refused without probing or retry");
        Program.Require(RustNative.TrySessionListing(ulong.MaxValue).Status == MilaNativeStatus.InvalidHandle &&
            RustNative.TrySessionSnapshot(ulong.MaxValue, 0).Status == MilaNativeStatus.InvalidHandle,
            "production listing and snapshot FFI receive their supported projection capacities");
    }
}
