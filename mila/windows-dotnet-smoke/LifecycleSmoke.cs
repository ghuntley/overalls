using System.Net;
using System.Text;
using System.Text.Json;
using Mila.Windows.Interop;

/// <summary>
/// @cc [owner:ghuntley,label:verification] mila-windows-lifecycle-smoke
/// Hermetic lifecycle evidence for the Windows column: deployment picker
/// fencing, Rust-session sign-in approval outcomes and reconnect, terminal
/// reconnect, WNS exchange plumbing and authenticated share completion. Fakes
/// stand in only for the network peer and OS services; Rust encoders and ABI
/// refusals run against the staged library.
/// </summary>
internal static class LifecycleSmoke
{
    private const string Fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    internal static void Run()
    {
        DeploymentPicker();
        WhoamiDecoding();
        SignInApprovalOutcomes();
        SignInReconnect();
        TerminalReconnect();
        TerminalNewReceipt();
        PushRegistration();
        ShareCompletion();
        DeviceFixture();
        PresentationCatalogs();
        RealAbiRefusals();
    }

    private static void DeploymentPicker()
    {
        string path = Path.Combine(Path.GetTempPath(), $"mila-deployments-{Guid.NewGuid():N}.json");
        try
        {
            List<MilaDeployment?> deselected = [];
            MilaDeploymentPicker picker = new(new MilaDeploymentFileRepository(path), deselected.Add);
            Program.Require(picker.State.Deployments.Count == 0 && picker.State.Selected is null, "empty picker");
            foreach (string bad in new[] { "", "https://a.example", "a.example:22", "a..example", "-a.example", "single",
                         "192.168.0.1", "a.example/", "Kelvin.example", "a b.example" })
                Program.Require(picker.Add(bad, 22, out _) == MilaDeploymentAddResult.InvalidHost, "picker refuses " + bad);
            Program.Require(picker.Add("a.example", 0, out _) == MilaDeploymentAddResult.InvalidPort, "picker refuses port 0");
            Program.Require(picker.Add("  A.Example ", 22, out MilaDeployment? a) == MilaDeploymentAddResult.Added &&
                a == new MilaDeployment("a.example", 22), "picker canonicalizes host");
            Program.Require(picker.Add("a.example", 22, out _) == MilaDeploymentAddResult.Existing, "picker deduplicates");
            Program.Require(picker.Add("b.example", 2222, out MilaDeployment? b) == MilaDeploymentAddResult.Added, "second deployment");
            Program.Require(picker.Add("localhost", 2222, out _) == MilaDeploymentAddResult.Added, "loopback fixture host");
            Program.Require(new MilaDeploymentFileRepository(path).LoadAll().Count == 3, "picker persists");
            long? first = picker.Select(a!);
            Program.Require(first == 1 && picker.State.Selected == a && deselected.Count == 1 && deselected[0] is null,
                "first selection advances generation");
            Program.Require(picker.Select(a!) == first && deselected.Count == 1, "reselect is idempotent");
            long? second = picker.Select(b!);
            Program.Require(second == 2 && deselected[^1] == a && !picker.IsCurrent(first!.Value, a!),
                "switch signs out previous and fences its generation");
            Program.Require(picker.Select(new MilaDeployment("c.example")) is null, "unknown deployment refusal");
            Program.Require(picker.Forget(b!) && picker.State.Selected is null && deselected[^1] == b &&
                !picker.IsCurrent(second!.Value, b!), "forgetting selected signs out");
            Program.Require(!picker.Forget(b!), "forget is idempotent");
            File.WriteAllText(path, "[{\"Host\":\"ok.example\",\"Port\":22},{\"Host\":\"BAD host\",\"Port\":22}]");
            Program.Require(new MilaDeploymentFileRepository(path).LoadAll() is [{ Host: "ok.example" }],
                "repository drops non-canonical stored hosts");
            File.WriteAllText(path, "{\"Host\":\"legacy.example\"}");
            Program.Require(new MilaDeploymentFileRepository(path).LoadAll() is [{ Host: "legacy.example", Port: 22 }],
                "legacy single-entry migration");
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    private static void WhoamiDecoding()
    {
        Program.Require(MilaWhoamiDecoder.Decode("""{"version":1,"status":"succeeded","result":{"email":"op@example.test"}}"""u8)
            is MilaWhoami.Approved { Account: "op@example.test" }, "whoami approved");
        Program.Require(MilaWhoamiDecoder.Decode(Encoding.UTF8.GetBytes(
            $$"""{"version":1,"status":"approval_required","fingerprint":"{{Fingerprint}}","approval_url":"https://a.example/ssh/approve/x"}"""))
            is MilaWhoami.Pending, "whoami pending");
        Program.Require(MilaWhoamiDecoder.Decode("""{"version":1,"status":"error","error":"forbidden"}"""u8)
            is MilaWhoami.Refused { Failure: MilaSignInFailure.Refused }, "whoami refused");
        foreach (string bad in new[] { "{", "[]", """{"version":2,"status":"succeeded"}""",
                     """{"version":1,"status":"approval_required","fingerprint":"SHA256:short","approval_url":"https://a.example/x"}""",
                     """{"version":1,"status":"pending"}""" })
            Program.Require(MilaWhoamiDecoder.Decode(Encoding.UTF8.GetBytes(bad)) is MilaWhoami.Invalid, "whoami invalid " + bad);
        Program.Require(MilaApprovalInfo.TryCreate("https://localhost:8443/ssh/approve/x", Fingerprint, 1, "localhost", 8443) is not null,
            "fixture approval origin accepted");
        Program.Require(MilaApprovalInfo.TryCreate("https://localhost/ssh/approve/x", Fingerprint, 1, "localhost", 8443) is null,
            "approval port must match deployment HTTPS port");
        Program.Require(MilaApprovalInfo.TryCreate("https://evil.example/ssh/approve/x", Fingerprint, 1, "a.example") is null,
            "approval host must match deployment");
    }

    private sealed class FakeBrowser : IMilaApprovalBrowser
    {
        internal List<string> Opened { get; } = [];
        public Task<bool> OpenAsync(MilaApprovalInfo approval, CancellationToken cancellationToken)
        {
            Opened.Add(approval.Url);
            return Task.FromResult(true);
        }
    }

    /// <summary>Scripted session peer: connect results and whoami replies in order.</summary>
    private sealed class Peer
    {
        internal Queue<MilaNativeStatus> Connects { get; } = new();
        internal Queue<Func<MilaNativeSessionBytesResult>> Replies { get; } = new();
        internal int Closed;
        private ulong _next = 100;
        internal MilaSessionConnection Session() => new(
            (ReadOnlySpan<byte> trust, string host, ReadOnlySpan<byte> key, ushort port, uint timeout, Func<byte[], byte[]> signer) =>
            {
                MilaNativeStatus status = Connects.Count > 0 ? Connects.Dequeue() : MilaNativeStatus.Ok;
                return status == MilaNativeStatus.Ok ? new(status, ++_next) : new(status, null);
            },
            _ => Interlocked.Increment(ref Closed));
        internal MilaNativeSessionBytesResult Whoami(ulong handle) =>
            Replies.Count > 0 ? Replies.Dequeue()() : new(MilaNativeStatus.Transport, null);
    }

    private static Func<MilaNativeSessionBytesResult> Json(string json) =>
        () => new(MilaNativeStatus.Ok, Encoding.UTF8.GetBytes(json));
    private static Func<MilaNativeSessionBytesResult> Pending(string url) =>
        Json($$"""{"version":1,"status":"approval_required","fingerprint":"{{Fingerprint}}","approval_url":"{{url}}"}""");
    private static readonly Func<MilaNativeSessionBytesResult> Approved =
        Json("""{"version":1,"status":"succeeded","result":{"email":"op@example.test"}}""");
    private static MilaSignInTarget Target(string host = "a.example", ushort https = 443) =>
        new(host, 22, https, [1], [2], bytes => new byte[64]);
    private static readonly MilaSignInPolicy Fast = new(TimeSpan.Zero, 3, TimeSpan.Zero, 1000);

    private static MilaSignInCoordinator Coordinator(Peer peer, MilaSignInFlow flow, MilaSessionConnection session,
        FakeBrowser browser, Func<ulong> clock, Func<TimeSpan, CancellationToken, Task>? delay = null) =>
        new(flow, session, browser, peer.Whoami, clock, delay ?? ((_, _) => Task.CompletedTask), Fast);

    private static void SignInApprovalOutcomes()
    {
        // Pending, then approved on the same session: browser opened exactly once.
        Peer peer = new();
        peer.Replies.Enqueue(Pending("https://a.example/ssh/approve/1"));
        peer.Replies.Enqueue(Pending("https://a.example/ssh/approve/1"));
        peer.Replies.Enqueue(Approved);
        MilaSignInFlow flow = new();
        using MilaSessionConnection session = peer.Session();
        FakeBrowser browser = new();
        List<MilaSignInPhase> seen = [];
        MilaSignInCoordinator coordinator = Coordinator(peer, flow, session, browser, () => 1000);
        coordinator.Changed += state => seen.Add(state.Phase);
        MilaSignInState state = coordinator.SignInAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state is { Phase: MilaSignInPhase.SignedIn, Account: "op@example.test" } && session.Handle is > 0,
            "approval completes on the same Rust session");
        Program.Require(browser.Opened.Count == 1 && seen.Contains(MilaSignInPhase.AwaitingApproval), "approval opened once and surfaced");

        // Refused outcome closes the session.
        peer = new();
        peer.Replies.Enqueue(Pending("https://a.example/ssh/approve/2"));
        peer.Replies.Enqueue(Json("""{"version":1,"status":"error","error":"forbidden"}"""));
        using MilaSessionConnection refusedSession = peer.Session();
        state = Coordinator(peer, new(), refusedSession, new(), () => 1000).SignInAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state is { Phase: MilaSignInPhase.Failed, Failure: MilaSignInFailure.Refused } &&
            refusedSession.Handle is null && peer.Closed == 1, "approval refusal closes session");

        // Expiry after ten minutes without approval.
        peer = new();
        for (int i = 0; i < 3; i++) peer.Replies.Enqueue(Pending("https://a.example/ssh/approve/3"));
        ulong now = 1000;
        using MilaSessionConnection expiringSession = peer.Session();
        state = Coordinator(peer, new(), expiringSession, new(), () => now, (_, _) => { now += 400; return Task.CompletedTask; })
            .SignInAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state.Phase == MilaSignInPhase.Expired && state.Approval is null && expiringSession.Handle is null,
            "approval expiry clears link and session");

        // A link for another origin is a protocol failure, never opened.
        peer = new();
        peer.Replies.Enqueue(Pending("https://evil.example/ssh/approve/4"));
        FakeBrowser untouched = new();
        using MilaSessionConnection foreignSession = peer.Session();
        state = Coordinator(peer, new(), foreignSession, untouched, () => 1000).SignInAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state is { Phase: MilaSignInPhase.Failed, Failure: MilaSignInFailure.Protocol } && untouched.Opened.Count == 0,
            "foreign approval origin refused");

        // Untrusted host certificate maps to HostUntrusted without retry.
        peer = new();
        peer.Connects.Enqueue(MilaNativeStatus.InvalidRequest);
        using MilaSessionConnection untrusted = peer.Session();
        state = Coordinator(peer, new(), untrusted, new(), () => 1000).SignInAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state is { Phase: MilaSignInPhase.Failed, Failure: MilaSignInFailure.HostUntrusted }, "untrusted host failure");

        // A deployment switch (sign-out) during approval polling fences the late outcome.
        peer = new();
        MilaSignInFlow switching = new();
        using MilaSessionConnection switchingSession = peer.Session();
        MilaSignInCoordinator switcher = null!;
        peer.Replies.Enqueue(Pending("https://a.example/ssh/approve/5"));
        peer.Replies.Enqueue(Approved);
        switcher = Coordinator(peer, switching, switchingSession, new(), () => 1000,
            (_, _) => { switcher.SignOut(); return Task.CompletedTask; });
        state = switcher.SignInAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state.Phase == MilaSignInPhase.SignedOut && switchingSession.Handle is null && peer.Replies.Count == 1,
            "sign-out during approval prevents late authentication");
    }

    private static void SignInReconnect()
    {
        Peer peer = new();
        peer.Replies.Enqueue(Approved);
        MilaSignInFlow flow = new();
        using MilaSessionConnection session = peer.Session();
        MilaSignInCoordinator coordinator = Coordinator(peer, flow, session, new(), () => 1000);
        MilaSignInState state = coordinator.SignInAsync(Target()).GetAwaiter().GetResult();
        long generation = state.Generation;
        ulong? firstHandle = session.Handle;
        Program.Require(!coordinator.ReportTransportLoss(generation - 1), "stale transport loss ignored");
        Program.Require(coordinator.ReportTransportLoss(generation) && flow.State.Phase == MilaSignInPhase.Disconnected &&
            session.Handle is null, "transport loss disconnects and closes handle");
        // Two failed connects, then success; the approved key needs no new approval.
        peer.Connects.Enqueue(MilaNativeStatus.Transport);
        peer.Connects.Enqueue(MilaNativeStatus.Transport);
        peer.Replies.Enqueue(Approved);
        state = coordinator.ReconnectAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state.Phase == MilaSignInPhase.SignedIn && state.Generation == generation + 1 &&
            session.Handle is > 0 && session.Handle != firstHandle, "bounded reconnect through Rust session");
        Program.Require(coordinator.ReconnectAsync(Target()).GetAwaiter().GetResult().Generation == state.Generation,
            "reconnect refused while signed in");
        // Exhaustion after the configured attempts.
        coordinator.ReportTransportLoss(state.Generation);
        for (int i = 0; i < 3; i++) peer.Connects.Enqueue(MilaNativeStatus.Transport);
        state = coordinator.ReconnectAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state is { Phase: MilaSignInPhase.Failed, Failure: MilaSignInFailure.Unreachable } && peer.Connects.Count == 0,
            "reconnect attempts are bounded");
        // A revoked key on reconnect surfaces approval again rather than silently signing in.
        flow = new();
        peer = new();
        peer.Replies.Enqueue(Approved);
        using MilaSessionConnection again = peer.Session();
        FakeBrowser browser = new();
        coordinator = Coordinator(peer, flow, again, browser, () => 1000);
        state = coordinator.SignInAsync(Target()).GetAwaiter().GetResult();
        coordinator.ReportTransportLoss(state.Generation);
        peer.Replies.Enqueue(Pending("https://a.example/ssh/approve/6"));
        peer.Replies.Enqueue(Approved);
        state = coordinator.ReconnectAsync(Target()).GetAwaiter().GetResult();
        Program.Require(state.Phase == MilaSignInPhase.SignedIn && browser.Opened.Count == 1, "reconnect re-approval path");
    }

    private sealed class FakeTerminal : IMilaTerminalTransport
    {
        internal Queue<(MilaNativeStatus, ulong?)> Attaches { get; } = new();
        internal Queue<MilaNativeTerminalRead> Reads { get; } = new();
        internal List<ulong> Killed { get; } = [];
        internal List<ulong> AttachedSessions { get; } = [];
        internal List<string> AttachedTerminals { get; } = [];
        internal Queue<MilaNativeTerminalOpen> Opens { get; } = new();
        internal int OpenCount { get; private set; }
        public MilaNativeTerminalOpen Open(ulong sessionHandle, Guid machineId)
        {
            OpenCount++;
            Program.Require(machineId == Machine, "terminal new names the selected machine");
            return Opens.Count > 0 ? Opens.Dequeue() : new(MilaNativeStatus.Ok, $"019a0f73-3d4e-7f5a-8b6c-{OpenCount:x12}");
        }
        public (MilaNativeStatus Status, ulong? Handle) Attach(
            ulong sessionHandle, Guid machineId, string terminalId, ushort columns, ushort rows)
        {
            Program.Require(machineId == Machine && Guid.TryParseExact(terminalId, "D", out _), "attach names a server session");
            AttachedSessions.Add(sessionHandle);
            AttachedTerminals.Add(terminalId);
            return Attaches.Count > 0 ? Attaches.Dequeue() : (MilaNativeStatus.Transport, null);
        }
        public MilaNativeTerminalRead Read(ulong terminalHandle) =>
            Reads.Count > 0 ? Reads.Dequeue() : new(MilaNativeStatus.Ok, MilaTerminalReadEvent.Idle, null);
        public MilaNativeStatus Kill(ulong terminalHandle) { Killed.Add(terminalHandle); return MilaNativeStatus.Ok; }
    }

    private static readonly Guid Machine = Guid.Parse("019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a");

    private static MilaNativeTerminalRead Data(string text) =>
        new(MilaNativeStatus.Ok, MilaTerminalReadEvent.Data, Encoding.UTF8.GetBytes(text));
    private static readonly MilaNativeTerminalRead Lost = new(MilaNativeStatus.Transport, MilaTerminalReadEvent.Idle, null);

    private static void TerminalReconnect()
    {
        ulong? session = 7;
        FakeTerminal transport = new();
        MilaTerminalStream stream = new(transport, () => session, maxReconnects: 2);
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 11));
        Program.Require(!stream.Attach(Guid.Empty, true, 80, 24) && transport.OpenCount == 0, "attach requires a machine");
        Program.Require(stream.Attach(Machine, true, 80, 24) && stream.Session.NativeTerminalHandle == 11 &&
            transport.OpenCount == 1 && transport.AttachedTerminals[^1] == stream.TerminalId, "terminal attach names the terminal new session");
        string named = stream.TerminalId!;
        long first = stream.Generation;
        transport.Reads.Enqueue(new(MilaNativeStatus.Ok, MilaTerminalReadEvent.Idle, null));
        Program.Require(stream.Poll() == MilaTerminalPoll.Idle && stream.Session.State != MilaTerminalState.Reconnecting,
            "idle PTY is not a disconnect");
        // A multi-byte character split across reads decodes once complete.
        byte[] euro = Encoding.UTF8.GetBytes("€");
        transport.Reads.Enqueue(new(MilaNativeStatus.Ok, MilaTerminalReadEvent.Data, euro[..1]));
        transport.Reads.Enqueue(new(MilaNativeStatus.Ok, MilaTerminalReadEvent.Data, euro[1..]));
        stream.Poll(); stream.Poll();
        Program.Require(stream.Session.Output == "€", "split UTF-8 output");
        // Transport loss: reattach on the live session with a new generation and replay reset.
        transport.Reads.Enqueue(Lost);
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 12));
        Program.Require(stream.Poll() == MilaTerminalPoll.Reconnected && transport.Killed.Contains(11ul) &&
            stream.Generation > first && stream.Session.Output.Length == 0 && transport.AttachedSessions[^1] == 7,
            "transport loss reattaches with fresh generation");
        Program.Require(transport.OpenCount == 1 && transport.AttachedTerminals[^1] == named, "reconnect rejoins the same named session");
        Program.Require(!stream.Session.AppendReceived(first, "late"), "stale generation output refused after reconnect");
        transport.Reads.Enqueue(Data("again\n"));
        Program.Require(stream.Poll() == MilaTerminalPoll.Output && stream.ReconnectAttempts == 0, "output resets attempts");
        // Failed reattaches stay bounded, then exhaust.
        transport.Reads.Enqueue(Lost);
        Program.Require(stream.Poll() == MilaTerminalPoll.Reconnecting &&
            stream.Session.State == MilaTerminalState.Reconnecting, "failed reattach keeps reconnecting");
        Program.Require(!stream.Session.SendInput(stream.Generation, [13]), "input refused while reconnecting");
        Program.Require(stream.Poll() == MilaTerminalPoll.Reconnecting, "second bounded attempt");
        Program.Require(stream.Poll() == MilaTerminalPoll.Exhausted && stream.Poll() == MilaTerminalPoll.Detached,
            "reconnect exhaustion ends stream");
        // Clean close ends without reconnect.
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 13));
        stream.Attach(Machine, true, 80, 24);
        int attaches = transport.AttachedSessions.Count;
        transport.Reads.Enqueue(new(MilaNativeStatus.Ok, MilaTerminalReadEvent.Closed, null));
        Program.Require(stream.Poll() == MilaTerminalPoll.Ended && transport.AttachedSessions.Count == attaches,
            "closed PTY never reconnects");
        // Kill during reconnect stops further attempts.
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 14));
        stream.Attach(Machine, true, 80, 24);
        transport.Reads.Enqueue(Lost);
        stream.Poll();
        stream.Kill();
        attaches = transport.AttachedSessions.Count;
        Program.Require(stream.Poll() == MilaTerminalPoll.Detached && transport.AttachedSessions.Count == attaches,
            "kill stops reconnect");
        // Signed-out session refuses reattach.
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 15));
        stream.Attach(Machine, true, 80, 24);
        transport.Reads.Enqueue(Lost);
        session = null;
        Program.Require(stream.Poll() == MilaTerminalPoll.SignedOut && stream.Session.State == MilaTerminalState.SignedOut,
            "signed-out session refuses reconnect");
        // A refused `terminal new` (for example terminal_unavailable) never attaches.
        session = 7;
        transport.Opens.Enqueue(new(MilaNativeStatus.InvalidRequest, null));
        int before = transport.AttachedTerminals.Count;
        Program.Require(!stream.Attach(Machine, true, 80, 24) && transport.AttachedTerminals.Count == before,
            "refused terminal new does not attach");
        // A refused (not lost) session attach forgets the name; the next attempt opens a new session.
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 17));
        stream.Attach(Machine, true, 80, 24);
        string gone = stream.TerminalId!;
        transport.Reads.Enqueue(Lost);
        transport.Attaches.Enqueue((MilaNativeStatus.InvalidRequest, null));
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 18));
        int opens = transport.OpenCount;
        Program.Require(stream.Poll() == MilaTerminalPoll.Reconnecting && stream.TerminalId is null, "refused attach drops session id");
        Program.Require(stream.Poll() == MilaTerminalPoll.Reconnected && transport.OpenCount == opens + 1 &&
            stream.TerminalId is { } fresh && fresh != gone, "next attempt opens a new named session");
        // Revoked handle ends.
        session = 7;
        transport.Attaches.Enqueue((MilaNativeStatus.Ok, 16));
        stream.Attach(Machine, true, 80, 24);
        transport.Reads.Enqueue(new(MilaNativeStatus.InvalidHandle, MilaTerminalReadEvent.Idle, null));
        Program.Require(stream.Poll() == MilaTerminalPoll.Ended, "revoked terminal handle ends stream");
    }

    private sealed class FakeChannels(MilaWnsChannel? channel) : IMilaWnsChannelSource
    {
        public Task<MilaWnsChannel?> CreateChannelAsync(CancellationToken cancellationToken) => Task.FromResult(channel);
    }
    private sealed class FakeKeys(string? key) : IMilaPokeKeySource { public string? PublicKey(string deployment) => key; }
    private sealed class FakeSusan(HttpStatusCode status, string body) : IMilaSusanKeyClient
    {
        internal byte[]? Sent;
        public Task<MilaSusanKeyReply> IssueAsync(byte[] request, CancellationToken cancellationToken)
        {
            Sent = request; // Same buffer: the workflow must clear it after sending.
            return Task.FromResult(new MilaSusanKeyReply(status, Encoding.UTF8.GetBytes(body)));
        }
    }

    private const string Channel = "https://wns2-par02p.notify.windows.com/w/?token=AwYAAAB%2bQk1%3d";
    private const string EncKey = "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU";
    private const string SusanReply = """{"push_key":"c3VzYW4tc2VhbGVkLXB1c2gta2V5LWZvci13bnM","key_id":"k1","expires_at":"2099-01-01T00:00:00Z"}""";

    private static void PushRegistration()
    {
        // Real Rust: Susan body is closed, carries the channel once, and refuses Susan-invalid shapes.
        MilaNativeBytesResult body = RustNative.TryEncodeWindowsPushKeyRequest(Channel, MilaWindowsPushRegistration.AppId, "a.example");
        Program.Require(body.Succeeded, "Rust encodes Susan WNS key request");
        using (JsonDocument document = JsonDocument.Parse(body.Data!))
        {
            string[] keys = document.RootElement.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray();
            Program.Require(keys.SequenceEqual(["app_id", "deployment", "environment", "provider", "token"]) &&
                document.RootElement.GetProperty("provider").GetString() == "wns" &&
                document.RootElement.GetProperty("token").GetString() == Channel, "Susan body closed schema");
        }
        foreach (string refused in new[] { "https://wns2.notify.windows.com:443/w/?token=a", "https://evil.example/w/?token=a",
                     "https://wns2.notify.windows.com/w/?token=a%00" })
            Program.Require(RustNative.TryEncodeWindowsPushKeyRequest(refused, MilaWindowsPushRegistration.AppId, "a.example").Data is null,
                "Rust refuses Susan-invalid channel " + refused);

        ulong session = 5;
        (ulong Handle, byte[] Reply, string Key, string? Label)? registered = null;
        MilaPushRegistrationNative native = new(RustNative.TryEncodeWindowsPushKeyRequest, (handle, reply, key, label, now) =>
        {
            registered = (handle, reply.ToArray(), key, label);
            return new(MilaNativeStatus.Ok, """{"version":1,"status":"succeeded","request_id":"porsche-0123456789abcdef0123456789abcdef","result":{"id":"5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b"}}"""u8.ToArray());
        });
        MilaWindowsNotificationController controller = new();
        controller.SetSession(true);
        MilaWnsChannel live = new(Channel, DateTimeOffset.UtcNow.AddDays(30));
        FakeSusan susan = new(HttpStatusCode.Created, SusanReply);
        MilaWindowsPushRegistration registration = new(new FakeChannels(live), new FakeKeys(EncKey), susan, controller, native);
        MilaPushRegistrationOutcome outcome = registration.RegisterAsync(session, "a.example", () => session, "This device").GetAwaiter().GetResult();
        Program.Require(outcome == MilaPushRegistrationOutcome.Registered && registration.DeviceId == "5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b" &&
            registered is { Handle: 5, Key: EncKey, Label: "This device" } && Encoding.UTF8.GetString(registered.Value.Reply) == SusanReply &&
            susan.Sent is not null, "WNS channel exchange registers through Rust session");
        Program.Require(susan.Sent!.All(b => b == 0), "Susan request buffer cleared after send");

        static MilaPushRegistrationOutcome Attempt(IMilaWnsChannelSource channels, IMilaPokeKeySource keys, IMilaSusanKeyClient susan,
            MilaPushRegistrationNative native, Func<ulong?> current, ulong session = 5)
        {
            MilaWindowsNotificationController controller = new();
            controller.SetSession(true);
            return new MilaWindowsPushRegistration(channels, keys, susan, controller, native)
                .RegisterAsync(session, "a.example", current).GetAwaiter().GetResult();
        }
        Func<ulong?> same = () => 5;
        Program.Require(Attempt(new FakeChannels(live), new FakeKeys(null), susan, native, same) == MilaPushRegistrationOutcome.KeyUnavailable,
            "missing poke key refuses before channel");
        Program.Require(Attempt(new FakeChannels(null), new FakeKeys(EncKey), susan, native, same) == MilaPushRegistrationOutcome.ChannelUnavailable,
            "missing WNS channel");
        Program.Require(Attempt(new FakeChannels(live with { ExpiresAt = DateTimeOffset.UnixEpoch }), new FakeKeys(EncKey), susan, native, same) ==
            MilaPushRegistrationOutcome.ChannelUnavailable, "expired WNS channel");
        Program.Require(Attempt(new FakeChannels(live with { Uri = "https://evil.example/w" }), new FakeKeys(EncKey), susan, native, same) ==
            MilaPushRegistrationOutcome.InvalidChannel, "foreign channel never leaves the process");
        foreach ((HttpStatusCode status, MilaPushRegistrationOutcome expected) in new[] {
                     (HttpStatusCode.BadRequest, MilaPushRegistrationOutcome.RelayRefused),
                     (HttpStatusCode.Gone, MilaPushRegistrationOutcome.RelayUnregistered),
                     (HttpStatusCode.TooManyRequests, MilaPushRegistrationOutcome.RelayRateLimited),
                     (HttpStatusCode.ServiceUnavailable, MilaPushRegistrationOutcome.RelayUnavailable) })
            Program.Require(Attempt(new FakeChannels(live), new FakeKeys(EncKey), new FakeSusan(status, "{}"), native, same) == expected,
                "Susan status " + status);
        ulong? current = 5;
        FakeSusan switching = new(HttpStatusCode.Created, SusanReply);
        int registers = 0;
        MilaPushRegistrationNative counting = native with { Register = (h, r, k, l, n) => { registers++; return native.Register(h, r, k, l, n); } };
        Program.Require(Attempt(new FakeChannels(live), new FakeKeys(EncKey), new SwitchingSusan(switching, () => current = 6), counting, () => current) ==
            MilaPushRegistrationOutcome.Stale && registers == 0, "session change during exchange abandons registration");
        Program.Require(Attempt(new FakeChannels(live), new FakeKeys(EncKey), susan, native, () => null) == MilaPushRegistrationOutcome.SignedOut,
            "signed-out registration refusal");
    }

    private sealed class SwitchingSusan(IMilaSusanKeyClient inner, Action during) : IMilaSusanKeyClient
    {
        public async Task<MilaSusanKeyReply> IssueAsync(byte[] body, CancellationToken cancellationToken)
        {
            MilaSusanKeyReply reply = await inner.IssueAsync(body, cancellationToken);
            during();
            return reply;
        }
    }

    private sealed class FakeShareOperation : IMilaShareOperation
    {
        internal int Completed;
        internal int Failed;
        public void ReportCompleted() => Completed++;
        public void ReportFailed() => Failed++;
    }

    private static void ShareCompletion()
    {
        ulong now = 1000;
        MilaShareCompletion completion = new(new MilaExternalActivationGate(), () => now);
        MilaExternalActivation share = MilaExternalActivationParser.ParseArguments(
            "--share overalls://a.example/machines/0d9cc041-9db2-4e4c-b28b-1e41d7f472c1")!.Value;
        FakeShareOperation operation = new();
        Program.Require(completion.Offer(share, authenticated: false, null, out _, operation) == MilaShareCompletionOutcome.Deferred &&
            completion.PendingHost == "a.example", "signed-out share deferred");
        Program.Require(completion.Complete("b.example", out _) == MilaShareCompletionOutcome.Deferred, "other host keeps share pending");
        completion.OnDeploymentSelected("a.example");
        Program.Require(completion.Complete("a.example", out MilaRoute route) == MilaShareCompletionOutcome.Navigated &&
            route.Kind == MilaRouteKind.Machine && operation.Completed == 1, "authenticated share completion");
        Program.Require(completion.Complete("a.example", out _) == MilaShareCompletionOutcome.Expired, "share completes at most once");

        FakeShareOperation dropped = new();
        completion.Offer(share, false, null, out _, dropped);
        completion.OnDeploymentSelected("b.example");
        Program.Require(completion.Complete("a.example", out _) == MilaShareCompletionOutcome.Expired && dropped.Failed == 1,
            "switching to another deployment discards share");

        completion.Offer(share, false, null, out _);
        completion.Cancel();
        Program.Require(completion.Complete("a.example", out _) == MilaShareCompletionOutcome.Expired, "sign-out discards share");

        completion.Offer(share, false, null, out _);
        now += MilaShareCompletion.PendingLifetimeSeconds + 1;
        Program.Require(completion.Complete("a.example", out _) == MilaShareCompletionOutcome.Expired, "stale share expires");

        Program.Require(completion.Offer(share, true, "a.example", out route) == MilaShareCompletionOutcome.Navigated &&
            route.Host == "a.example", "authenticated share navigates immediately");
        MilaExternalActivation settings = MilaExternalActivationParser.ParseArguments("--share overalls://a.example/settings")!.Value;
        Program.Require(completion.Offer(settings, true, "a.example", out _) == MilaShareCompletionOutcome.Refused, "settings share refused");
        MilaExternalActivation link = MilaExternalActivationParser.ParseArguments("overalls://a.example/threads")!.Value;
        Program.Require(completion.Offer(link, true, "a.example", out _) == MilaShareCompletionOutcome.Refused, "non-share activation refused");
    }

    private static void DeviceFixture()
    {
        using JsonDocument fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "fixtures", "porsche_device_results.json")));
        string ls = fixture.RootElement.GetProperty("commands").GetProperty("device ls").GetProperty("response").GetRawText();
        IReadOnlyList<MilaWindowsNotificationDevice> devices = MilaWindowsNotificationDevicesController.DecodeListing(Encoding.UTF8.GetBytes(ls));
        Program.Require(devices is [{ Id: "5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b", Platform: "android", Enabled: true }],
            "Porsche device ls fixture decodes");
        string register = fixture.RootElement.GetProperty("commands").GetProperty("device register").GetProperty("response").GetRawText();
        Program.Require(MilaWindowsPushRegistration.DecodeDeviceId(Encoding.UTF8.GetBytes(register)) == "5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b",
            "Porsche device register fixture decodes");
    }

    private static void PresentationCatalogs()
    {
        string directory = Path.Combine(AppContext.BaseDirectory, "fixtures", "catalogs");
        string[] catalogs = Directory.GetFiles(directory, "app_*.arb");
        Program.Require(catalogs.Length >= 28, "shared catalogs staged");
        MilaMessage[] messages = MilaPresentation.All().DistinctBy(message => message.Id).ToArray();
        foreach (string path in catalogs)
        {
            using JsonDocument catalog = JsonDocument.Parse(File.ReadAllBytes(path));
            bool english = Path.GetFileName(path) == "app_en.arb";
            foreach (MilaMessage message in messages)
            {
                Program.Require(catalog.RootElement.TryGetProperty(message.Id, out JsonElement text) &&
                    text.ValueKind == JsonValueKind.String, $"{Path.GetFileName(path)} has {message.Id}");
                string[] placeholders = System.Text.RegularExpressions.Regex.Matches(text.GetString()!, "\\{([a-zA-Z]+)\\}")
                    .Select(match => match.Groups[1].Value).Distinct().Order(StringComparer.Ordinal).ToArray();
                Program.Require(placeholders.SequenceEqual(message.Placeholders), $"{Path.GetFileName(path)} placeholders for {message.Id}");
                if (english) Program.Require(text.GetString() == message.Fallback, $"English fallback matches catalog for {message.Id}");
            }
        }
        string rendered = new MilaMessage("signInConnecting", "Connecting to {host}…", "a.example").Render((_, fallback) => fallback);
        Program.Require(rendered == "Connecting to ⁨a.example⁩…", "host binding is bidi-isolated");
    }

    private static void RealAbiRefusals()
    {
        Program.Require(RustNative.TrySessionWhoami(0).Status == MilaNativeStatus.InvalidRequest, "whoami requires handle");
        Program.Require(RustNative.TrySessionWhoami(ulong.MaxValue).Status == MilaNativeStatus.InvalidHandle, "whoami unknown handle");
        Program.Require(RustNative.TrySessionReadMachines(ulong.MaxValue, false) == MilaNativeStatus.InvalidHandle, "read machines unknown handle");
        Program.Require(RustNative.TrySessionTerminalRead(ulong.MaxValue).Status == MilaNativeStatus.InvalidHandle, "terminal read unknown handle");
        Program.Require(RustNative.TrySessionDeviceRegister(ulong.MaxValue, MilaDevicePlatform.Windows, Encoding.UTF8.GetBytes(SusanReply), EncKey, null,
            (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds()).Status == MilaNativeStatus.InvalidHandle, "device register validates reply then handle");
        string expired = SusanReply.Replace("2099", "2001", StringComparison.Ordinal);
        Program.Require(RustNative.TrySessionDeviceRegister(ulong.MaxValue, MilaDevicePlatform.Windows, Encoding.UTF8.GetBytes(expired), EncKey, null,
            (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds()).Status == MilaNativeStatus.InvalidRequest, "Rust refuses expired Susan key");
        Program.Require(RustNative.TrySessionDeviceRegister(ulong.MaxValue, MilaDevicePlatform.Windows, Encoding.UTF8.GetBytes(SusanReply),
            EncKey[..42] + "B", null, 1).Status == MilaNativeStatus.InvalidRequest, "Rust refuses non-canonical X25519 key");
        // Named terminal sessions: the new exports are present and refuse unknown handles.
        const string Request = "porsche-0123456789abcdef0123456789abcdef";
        Program.Require(RustNative.TrySessionTerminalNew(ulong.MaxValue, Machine, Request).Status == MilaNativeStatus.InvalidHandle,
            "terminal new unknown handle");
        Program.Require(RustNative.TrySessionTerminalNew(ulong.MaxValue, Machine, "not-a-request").Status == MilaNativeStatus.InvalidRequest,
            "terminal new requires canonical request id");
        Program.Require(RustNative.TrySessionTerminalAttachSession(ulong.MaxValue, Machine, "019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c", 80, 24).Status ==
            MilaNativeStatus.InvalidHandle, "named terminal attach unknown handle");
        Program.Require(RustNative.TrySessionTerminalAttachSession(ulong.MaxValue, Machine, "not-a-session", 80, 24).Status ==
            MilaNativeStatus.InvalidRequest, "named terminal attach requires a session UUID");
        Program.Require(RustNative.TrySessionLastRefusal(ulong.MaxValue) is null, "last refusal unknown handle");
    }

    private static void TerminalNewReceipt()
    {
        string receipt = """{"version":1,"status":"succeeded","request_id":"porsche-0123456789abcdef0123456789abcdef","result":{"machine_id":"019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a","session_id":"019A0F73-3D4E-7F5A-8B6C-7D8E9F0A1B2C","guest_session_id":"3f2e1d0c-9b8a-4766-8544-332211009988","route":"overalls://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/terminals/019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c"}}""";
        Program.Require(RustNative.DecodeTerminalNew(Encoding.UTF8.GetBytes(receipt)) == "019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c",
            "terminal new receipt names the canonical session");
        foreach (string bad in new[]
                 {
                     """{"result":{}}""", """{"result":{"session_id":7}}""", """{"result":{"session_id":"x"}}""",
                     """{"result":{"session_id":"00000000-0000-0000-0000-000000000000"}}""", """[]""", "not json",
                 })
            Program.Require(RustNative.DecodeTerminalNew(Encoding.UTF8.GetBytes(bad)) is null, "terminal new receipt refuses " + bad);
    }
}
