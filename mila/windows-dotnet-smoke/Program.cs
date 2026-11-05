using System.Text;
using System.Text.Json;
using Mila.Windows.Interop;

/// <summary>
/// @cc [owner:ghuntley,label:verification] mila-windows-smoke-real-abi
/// The smoke executable MUST fail unless the production interop invokes the staged
/// Rust library successfully; Unavailable MUST NOT count as passing evidence.
/// </summary>
internal static class Program
{
    internal static void Require(bool condition, string check)
    {
        if (!condition) throw new InvalidOperationException(check);
    }

    private static int Main(string[] args)
    {
        // Journey mode: `--descriptor PATH` runs only the fixture journey; the
        // hermetic checks below are the default and need no backend.
        if (args is ["--descriptor", { Length: > 0 } descriptor])
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("journey mode requires Windows CNG");
            JourneySmoke.Run(descriptor);
            return 0;
        }
        if (args.Length != 0)
        {
            Console.Error.WriteLine("usage: Mila.Windows.Smoke [--descriptor PATH]");
            return 2;
        }
        if (OperatingSystem.IsWindows())
        {
            // CNG device custody and DPAPI poke-key custody exist only on Windows.
            DeviceKeySmoke.Run();
            PokeKeySmoke.Run();
            SnapshotSmoke.Run();
        }
        WatchSmoke.Run();
        TerminalFrameSmoke.Run();
        TerminalGenerationSmoke.Run();
        MachineListingSmoke.Run();
        ThreadGenerationSmoke.Run();
        SessionLifecycleSmoke.Run();
        SignInFlowSmoke.Run();
        WindowsNotificationsSmoke.Run();
        AssertDeploymentPorts();
        MilaNativeVersionResult version = RustNative.TryGetVersion();
        MilaSettings settings = MilaSettings.Defaults;
        Require(settings.Locale == "en" && !settings.DarkMode, "settings defaults");
        Require(MilaSettings.IsValidLocale("fr-FR") && MilaSettings.IsValidLocale("zh-Hant-TW"), "locale policy accepts BCP-47");
        Require(!MilaSettings.IsValidLocale("not a locale") && !MilaSettings.IsValidLocale("en/../../x"), "locale policy rejects malformed values");
        Require(new MilaSettings("ar", false).Direction() == LocaleDirection.Rtl, "Arabic locale is RTL");
        Require(new MilaSettings("en", false).Direction() == LocaleDirection.Ltr, "English locale is LTR");
        Require(new MilaSettings("ur", false).Direction() == LocaleDirection.Rtl, "Urdu locale is RTL");
        Require(new MilaSettings(" fr_FR ", true).Normalize() == new MilaSettings("fr-FR", true), "locale normalization");
        Require(new MilaSettings("ZH_hant_tw", false).Normalize() == new MilaSettings("zh-Hant-TW", false), "locale casing normalization");
        Require(version.Status == MilaNativeStatus.Ok && version.Version is { Major: 1, Minor: 0 }, "ABI version 1.0");
        const string route = "overalls://mgmt.example.test:8443/machines/0d9cc041-9db2-4e4c-b28b-1e41d7f472c1";
        MilaNativeRouteResult formatted = RustNative.TryFormatRoute(route);
        Require(formatted.Status == MilaNativeStatus.Ok && formatted.Canonical == route, "host-qualified canonical route");
        MilaNativeRouteResult invalid = RustNative.TryFormatRoute("overalls://mgmt.example.test/unknown");
        Require(invalid.Status == MilaNativeStatus.InvalidRoute && invalid.Canonical is null, "invalid route refusal");
        byte[] snapshot = Encoding.UTF8.GetBytes("""
            {"version":1,"host":"mgmt.example.test","port":8443,"saved_at":4294967298,"machines":[]}
            """);
        MilaNativeSnapshotResult valid = RustNative.TryValidateSnapshot(snapshot, "mgmt.example.test", 8443, true);
        Require(valid.Status == MilaNativeStatus.Ok && valid.Summary is { MachineCount: 0, SavedAt: 4294967298 }, "snapshot summary layout");
        RefusesSnapshot(snapshot, "foreign.example.test", 8443);
        RefusesSnapshot(snapshot, "mgmt.example.test", 443);
        RefusesSnapshot("{"u8.ToArray(), "mgmt.example.test", 8443);
        byte[] oversized = new byte[(1 << 20) + 1];
        Array.Fill(oversized, (byte)' ');
        snapshot.CopyTo(oversized, 0);
        RefusesSnapshot(oversized, "mgmt.example.test", 8443);
        byte[] machineSnapshot = Encoding.UTF8.GetBytes("""
            {"version":1,"host":"mgmt.example.test","port":8443,"saved_at":1,"machines":[{"id":"0d9cc041-9db2-4e4c-b28b-1e41d7f472c1","name":"test","desired_state":"running","observed_state":"running","pinned":false,"owner":"test","read":true,"write":true,"manage":true}]}
            """);
        MilaNativeActionsResult actions = RustNative.TryGetMachineActions(machineSnapshot, "mgmt.example.test", 8443, 0);
        Require(actions.Status == MilaNativeStatus.Ok && actions.Actions ==
            (MilaMachineAction.Stop | MilaMachineAction.Pause | MilaMachineAction.Pin | MilaMachineAction.Delete), "Rust action projection");
        Require(RustNative.TryGetMachineActions(machineSnapshot, "foreign.example.test", 8443, 0).Actions is null, "foreign action refusal");
        Require(RustNative.TryGetMachineActions(machineSnapshot, "mgmt.example.test", 8443, 1).Actions is null, "missing machine refusal");
        Guid machineId = Guid.Parse("0d9cc041-9db2-4e4c-b28b-1e41d7f472c1");
        MilaNativeCommandResult command = RustNative.TryFormatMachineCommand("stop", machineId, "porsche-0123456789abcdef0123456789abcdef");
        Require(command.Status == MilaNativeStatus.Ok && command.Command == $"stop {machineId:D} --json --request-id=porsche-0123456789abcdef0123456789abcdef", "bounded command format");
        foreach (string action in new[] { "stop --force", "stop\0ignored", "unknown" })
            Require(RustNative.TryFormatMachineCommand(action, machineId, "porsche-0123456789abcdef0123456789abcdef").Command is null, "action injection refusal");
        Require(RustNative.TryFormatMachineCommand("stop", machineId, null).Command is null, "mutation request required");
        Require(RustNative.TryFormatMachineCommand("stop", machineId, "id\0suffix").Command is null, "request truncation refusal");
        Guid keyId = Guid.NewGuid();
        MilaNativeSessionActionResult invalidSession = RustNative.TrySessionMachineAction(0, machineId, "stop", "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidSession.Status == MilaNativeStatus.InvalidRequest, "missing authenticated session refusal");
        MilaNativeSessionActionResult invalidResize = RustNative.TrySessionMachineResize(
            0, machineId, 2, 2048, 20_480, "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidResize.Status == MilaNativeStatus.InvalidRequest, "missing authenticated resize refusal");
        MilaNativeSessionActionResult oversizedResize = RustNative.TrySessionMachineResize(
            1, machineId, 2, 2048, 501, "porsche-0123456789abcdef0123456789abcdef");
        Require(oversizedResize.Status == MilaNativeStatus.InvalidRequest, "oversized resize refusal");
        MilaNativeSessionBytesResult invalidWeb = RustNative.TrySessionWebShow(0, machineId);
        Require(invalidWeb.Status == MilaNativeStatus.InvalidRequest && invalidWeb.Data is null, "missing authenticated web listing refusal");
        MilaNativeSessionActionResult invalidWebSet = RustNative.TrySessionWebSet(
            0, machineId, 8080, false, 0, "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidWebSet.Status == MilaNativeStatus.InvalidRequest, "missing authenticated web mutation refusal");
        MilaNativeSessionActionResult invalidShare = RustNative.TrySessionShareMutation(
            0, machineId, "operator@example.test", "operator", true,
            "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidShare.Status == MilaNativeStatus.InvalidRequest,
            "missing authenticated share mutation refusal");
        MilaWebEndpoint endpoint = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes($"{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":4,\"url\":\"https://web.example.test\"}}"), machineId);
        Require(endpoint.Revision == 4 && endpoint.IsPublic && endpoint.Url?.Scheme == "https", "web endpoint revision projection");
        bool badWeb = false;
        try { _ = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes($"{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":4,\"url\":\"http://web.example.test\"}}"), machineId); } catch (InvalidDataException) { badWeb = true; }
        Require(badWeb, "insecure web endpoint refusal");
        foreach (string unsafeUrl in new[] {
            "https://user:pass@web.example.test/",
            "https://web..example.test/",
            "https://web.example.test:8443/",
            "https://web.example.test/#fragment"])
        {
            bool unsafeRefused = false;
            try { _ = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes($"{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":4,\"url\":\"{unsafeUrl}\"}}"), machineId); }
            catch (InvalidDataException) { unsafeRefused = true; }
            Require(unsafeRefused, $"unsafe web endpoint refusal: {unsafeUrl}");
        }
        bool nonStringUrl = false;
        try { _ = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes($"{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":\"public\",\"policy_revision\":4,\"url\":42}}"), machineId); }
        catch (InvalidDataException) { nonStringUrl = true; }
        Require(nonStringUrl, "non-string web endpoint URL refusal");
        foreach (string malformed in new[] {
            $"{{\"machine_id\":42,\"port\":8080,\"visibility\":\"public\",\"policy_revision\":4}}",
            $"{{\"machine_id\":\"{machineId:D}\",\"port\":\"8080\",\"visibility\":\"public\",\"policy_revision\":4}}",
            $"{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":42,\"policy_revision\":4}}"])
        {
            bool malformedRefused = false;
            try { _ = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes(malformed), machineId); }
            catch (InvalidDataException) { malformedRefused = true; }
            Require(malformedRefused, "malformed web endpoint scalar refusal");
        }
        MilaWebEndpoint enveloped = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes($"{{\"version\":1,\"status\":\"succeeded\",\"result\":{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":\"private\",\"policy_revision\":5,\"url\":null}}}}"), machineId);
        Require(enveloped is { Port: 8080, IsPublic: false, Revision: 5 }, "web endpoint reads Porsche's succeeded envelope");
        bool failedEnvelope = false;
        try { _ = MilaWebEndpointDecoder.Decode(Encoding.UTF8.GetBytes($"{{\"version\":1,\"status\":\"failed\",\"result\":{{\"machine_id\":\"{machineId:D}\",\"port\":8080,\"visibility\":\"private\",\"policy_revision\":5}}}}"), machineId); } catch (InvalidDataException) { failedEnvelope = true; }
        Require(failedEnvelope, "web endpoint refuses a failed envelope");
        Uri webOrigin = new("https://web.example.test");
        Require(MilaWebOrigin.IsAllowed(webOrigin, new Uri("https://web.example.test/path")), "same web origin allowed");
        Require(!MilaWebOrigin.IsAllowed(webOrigin, new Uri("http://web.example.test/path")), "http web origin refusal");
        Require(!MilaWebOrigin.IsAllowed(webOrigin, new Uri("https://other.example.test/path")), "foreign web origin refusal");
        Require(!MilaWebOrigin.IsAllowed(webOrigin, new Uri("https://web.example.test/path#fragment")), "fragment web origin refusal");
        Require(!MilaWebOrigin.IsAllowed(new Uri("https://user:pass@web.example.test"), new Uri("https://web.example.test/path")), "credentialed origin refusal");
        Require(!MilaWebOrigin.IsAllowed(webOrigin, new Uri("https://user:pass@web.example.test/path")), "credentialed target refusal");
        MilaNativeSessionBytesResult invalidKeys = RustNative.TrySessionSshKeys(0);
        Require(invalidKeys.Status == MilaNativeStatus.InvalidRequest && invalidKeys.Data is null, "missing authenticated SSH key listing refusal");
        MilaNativeSessionBytesResult invalidListing = RustNative.TrySessionListing(0);
        Require(invalidListing.Status == MilaNativeStatus.InvalidRequest && invalidListing.Data is null, "missing authenticated machine listing refusal");
        MilaNativeSessionActionResult invalidRevoke = RustNative.TrySessionSshKeyRevoke(
            0, keyId, "porsche-0123456789abcdef0123456789abcdef");
        Require(invalidRevoke.Status == MilaNativeStatus.InvalidRequest, "missing authenticated SSH key revoke refusal");
        Require(RustNative.TrySessionSshKeyRevoke(1, keyId, "bad-request").Status == MilaNativeStatus.InvalidRequest,
            "SSH key revoke request-id validation");
        MilaNativeThreadCommandResult thread = RustNative.TryClassifyThreadCommand("thread ls");
        Require(thread.Status == MilaNativeStatus.Ok && thread.Kind == MilaThreadCommandKind.List, "thread command projection");
        Require(RustNative.TryClassifyThreadCommand("thread plan approve 00000000-0000-0000-0000-000000000001 00000000-0000-0000-0000-000000000002").Kind == MilaThreadCommandKind.PlanApprove,
            "thread plan approval projection");
        Require(RustNative.TryClassifyThreadCommand("thread plan revise 00000000-0000-0000-0000-000000000001 00000000-0000-0000-0000-000000000002 -").Kind == MilaThreadCommandKind.PlanRevise,
            "thread plan revision projection");
        Require(RustNative.TryClassifyThreadCommand("thread plan approve 00000000-0000-0000-0000-000000000001").Kind is null,
            "thread plan approval input refusal");
        Require(RustNative.TryClassifyThreadCommand("thread plan revise 00000000-0000-0000-0000-000000000001 00000000-0000-0000-0000-000000000002 -\0ignored").Kind is null,
            "thread plan revision truncation refusal");
        Require(RustNative.TryClassifyThreadCommand("thread delete abc").Kind is null, "unknown thread command refusal");
        Require(RustNative.TryClassifyThreadCommand("thread ls\0ignored").Kind is null, "thread command truncation refusal");
        Require(RustNative.TryValidateTerminalAttach(0, 120, 40, true).IsValid, "terminal attach validation");
        Require(RustNative.TryValidateTerminalResize(120, 40, true).IsValid, "terminal resize validation");
        Require(RustNative.TryValidateTerminalInput(1024, true).IsValid, "terminal input validation");
        Require(!RustNative.TryValidateTerminalResize(0, 40, true).IsValid, "terminal resize bounds");
        Require(!RustNative.TryValidateTerminalInput((nuint)(1 << 20) + 1, true).IsValid, "terminal input bounds");
        var terminal = new MilaTerminalSession();
        terminal.BeginAttach(7, true);
        Require(terminal.Append(7, "ready\n"), "terminal output append");
        Require(terminal.Resize(7, 120, 40) && terminal.SendInput(7, new byte[] { 13 }), "terminal live controls");
        Require(!terminal.Append(6, "stale"), "stale terminal generation refusal");
        Require(!terminal.SendInput(7, new byte[65_537]), "terminal input hard bound");
        Require(terminal.ReceiveEof(7), "terminal clean EOF transition");
        Require(!terminal.Reconnect(7) && !terminal.SendInput(7, new byte[] { 13 }), "closed terminal refuses controls");
        terminal.Kill(7); Require(!terminal.Reconnect(7), "killed terminal reconnect refusal");
        terminal.BeginAuthenticatedAttach(9, 8, true);
        Require(terminal.Append(8, "reconnected\n"), "terminal reconnect attach");
        terminal.SignOut();
        Require(!terminal.Reconnect(8), "signed-out terminal reconnect refusal");
        Require(!terminal.Append(8, "late"), "signed-out stale terminal output refusal");
        MilaSessionListing listing = RustNative.DecodeSessionListing(Encoding.UTF8.GetBytes("{\"machines\":[{\"id\":\"0d9cc041-9db2-4e4c-b28b-1e41d7f472c1\",\"name\":\"test\",\"desired_state\":\"running\",\"observed_state\":\"running\",\"pinned\":false,\"read\":true,\"write\":true,\"manage\":true}],\"has_more\":true}"));
        Require(listing.HasMore && listing.Machines.Count == 1 && listing.Machines[0].Name == "test", "bounded live listing projection");
        bool refused = false;
        try { RustNative.DecodeSessionListing(Encoding.UTF8.GetBytes("{\"machines\":[{\"id\":\"bad\"}]}")); } catch (InvalidDataException) { refused = true; }
        Require(refused, "invalid listing refusal");
        Guid planId = new("00000000-0000-0000-0000-000000000002");
        MilaThreadListing threadListing = MilaThreadListing.Decode(Encoding.UTF8.GetBytes("{\"items\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"build\",\"status\":\"ready\",\"latest_plan\":{\"id\":\"00000000-0000-0000-0000-000000000002\"}}],\"next_cursor\":null}"));
        Require(threadListing.Threads[0].PlanId == planId && !threadListing.HasMore, "thread plan identity projection");
        AssertThreadListingProtocol();
        MilaSshKey key = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes($"{{\"keys\":[{{\"id\":\"{keyId:D}\",\"fingerprint\":\"SHA256:test\",\"algorithm\":\"ed25519\",\"current_device\":false}}]}}"))[0];
        Require(key.Id == keyId && key.Algorithm == "ed25519", "SSH key listing projection");
        // Marshall's `ssh-key list` reply: the version-1 envelope over `view/1` (no current_device).
        MilaSshKey served = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes(
            $"{{\"version\":1,\"status\":\"succeeded\",\"result\":{{\"keys\":[{{\"id\":\"{keyId:D}\",\"label\":\"\",\"algorithm\":\"ecdsa-sha2-nistp256\",\"fingerprint\":\"SHA256:test\",\"inserted_at\":\"2026-11-01T00:00:00Z\"}}]}}}}"))[0];
        Require(served.Id == keyId && !served.IsCurrentDevice, "enveloped SSH key listing projection");
        bool failedKeyEnvelope = false;
        try { _ = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes("{\"version\":1,\"status\":\"failed\",\"result\":{\"keys\":[]}}")); }
        catch (InvalidDataException) { failedKeyEnvelope = true; }
        Require(failedKeyEnvelope, "failed SSH key envelope refusal");
        AssertSessionReads();
        DeviceKeyCustodySmoke.Run();
        Require(MilaSshKeysController.Fingerprint("ssh-ed25519 !!!") is null,
            "invalid SSH base64 fingerprint refusal");
        int revokeCount = 0;
        var keys = new MilaSshKeysController(_ => Task.FromResult<IReadOnlyList<MilaSshKey>>(new[] { key }), (id, _) => { if (id == keyId) revokeCount++; return Task.CompletedTask; });
        keys.LoadAsync(true).GetAwaiter().GetResult(); keys.RevokeAsync(key).GetAwaiter().GetResult(); keys.RevokeAsync(key).GetAwaiter().GetResult();
        Require(revokeCount == 1 && keys.Status == MilaSshKeysStatus.Loaded, "SSH key revoke at-most-once workflow");
        MilaSshKey current = key with { IsCurrentDevice = true };
        bool currentRevoked = false;
        var currentKeys = new MilaSshKeysController(_ => Task.FromResult<IReadOnlyList<MilaSshKey>>(new[] { current }), (id, _) => { currentRevoked = true; return Task.CompletedTask; });
        currentKeys.LoadAsync(true).GetAwaiter().GetResult(); currentKeys.RevokeAsync(current).GetAwaiter().GetResult();
        Require(!currentRevoked && currentKeys.Status == MilaSshKeysStatus.Loaded, "current device revoke refusal");
        bool malformed = false; try { _ = MilaSshKeysController.DecodeListing(Encoding.UTF8.GetBytes("{\"keys\":[{\"id\":\"bad\"}]}")); } catch (InvalidDataException) { malformed = true; }
        Require(malformed, "invalid SSH key listing refusal");
        var hello = new FakeHello(MilaWindowsHelloAvailability.Available, MilaWindowsHelloVerification.Verified);
        var lockController = new MilaAppLockController(hello);
        Require(lockController.RefreshAvailabilityAsync().GetAwaiter().GetResult() == MilaAppLockState.Unlocked, "Hello availability");
        lockController.OnDeactivated(); Require(lockController.IsLocked, "app lock deactivation state");
        Require(lockController.UnlockAsync().GetAwaiter().GetResult() && !lockController.IsLocked && hello.LastMessage == "Unlock Mila", "Hello unlock");
        var unavailable = new MilaAppLockController(new FakeHello(MilaWindowsHelloAvailability.Unavailable, MilaWindowsHelloVerification.Verified));
        Require(unavailable.RefreshAvailabilityAsync().GetAwaiter().GetResult() == MilaAppLockState.Unavailable, "Hello unavailable state");
        RustNative.CheckOutputBounds(route);
        AssertRoutes();
        AssertExternalActivation();
        LifecycleSmoke.Run();
        JourneyDescriptorSmoke.Run();
        Console.WriteLine("Windows Rust FFI smoke passed.");
        return 0;
    }

    /// <summary>`thread ls --json` as Porsche returns it (the shared protocol fixture), bare and enveloped.</summary>
    private static bool Refuses(Action decode)
    {
        try { decode(); return false; }
        catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { return true; }
    }

    private static void AssertSessionReads()
    {
        static byte[] B(string json) => Encoding.UTF8.GetBytes(json);
        Guid machine = new("019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a");
        const string grant = "{\"id\":\"g1\",\"user_id\":\"u1\",\"email\":\"Teammate@Example.test\",\"role\":\"viewer\"}";
        IReadOnlyList<MilaShareGrant> grants = MilaSessionReads.DecodeShares(B(
            "{\"version\":1,\"status\":\"succeeded\",\"result\":{\"owner\":{\"email\":\"owner@example.test\"},\"items\":[" + grant + "]}}"));
        Require(grants.Count == 1 && grants[0] == new MilaShareGrant("Teammate@Example.test", "viewer"), "share listing projection");
        Require(MilaSessionReads.DecodeShares(B("{\"owner\":{\"email\":\"owner@example.test\"},\"items\":[]}")).Count == 0, "bare empty share listing");
        Require(Refuses(() => MilaSessionReads.DecodeShares(B("{\"items\":[]}"))), "share listing requires the owner");
        Require(Refuses(() => MilaSessionReads.DecodeShares(B("{\"owner\":{\"email\":\"o@x.test\"},\"items\":[" + grant.Replace("viewer", "owner") + "]}"))),
            "share listing refuses an owner grant");
        Require(Refuses(() => MilaSessionReads.DecodeShares(B("{\"owner\":{\"email\":\"o@x.test\"},\"items\":[" + grant + "," + grant + "]}"))),
            "share listing refuses duplicate grants");
        Require(Refuses(() => MilaSessionReads.DecodeShares(B("{\"version\":1,\"status\":\"failed\",\"result\":{}}"))), "failed share envelope");

        string detail = $"{{\"id\":\"{machine:D}\",\"name\":\"seed\",\"desired_state\":\"running\",\"vcpu\":2,\"memory_bytes\":1073741824}}";
        MilaMachineDetail shown = MilaSessionReads.DecodeMachine(B("{\"version\":1,\"status\":\"succeeded\",\"result\":" + detail + "}"), machine);
        Require(shown is { Vcpu: 2, MemoryMib: 1024, DesiredState: "running" }, "machine detail projection");
        Require(MilaSessionReads.DecodeMachine(B($"{{\"id\":\"{machine:D}\",\"desired_state\":\"stopped\"}}"), machine) is { Vcpu: null, MemoryMib: null },
            "machine detail without size");
        Require(Refuses(() => MilaSessionReads.DecodeMachine(B(detail), Guid.NewGuid())), "machine detail names the requested machine");

        Require(MilaSessionReads.RequestAdmitted(B("{\"status\":\"accepted\"}")), "bare accepted receipt");
        Require(MilaSessionReads.RequestAdmitted(B("{\"result\":{\"status\":\"succeeded\"}}")), "nested succeeded receipt");
        Require(!MilaSessionReads.RequestAdmitted(B("{\"status\":\"pending\",\"result\":{\"status\":\"failed\"}}")), "pending receipt is not admitted");
        Require(!MilaSessionReads.RequestAdmitted(B("[]")), "non-object receipt is not admitted");

        const string session = "019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c";
        string closed = $"{{\"machine_id\":\"{machine:D}\",\"session_id\":\"{session}\",\"closed\":true}}";
        Require(MilaSessionReads.TerminalClosed(B(closed), session), "bare terminal kill result");
        Require(MilaSessionReads.TerminalClosed(B("{\"version\":1,\"status\":\"succeeded\",\"result\":" + closed + "}"), session), "enveloped terminal kill result");
        Require(!MilaSessionReads.TerminalClosed(B(closed), "019a0f73-3d4e-7f5a-8b6c-000000000000"), "terminal kill names the ended session");
        Require(!MilaSessionReads.TerminalClosed(B(closed.Replace("true", "false")), session), "terminal kill not closed");
        Require(Refuses(() => MilaSessionReads.TerminalClosed(ReadOnlySpan<byte>.Empty, session)), "empty terminal kill result");
        Require(RustNative.TrySessionTerminalEnd(0, machine, session, "porsche-" + Guid.NewGuid().ToString("N")).Status == MilaNativeStatus.InvalidRequest &&
            RustNative.TrySessionTerminalEnd(1, machine, "not-a-session", "porsche-" + Guid.NewGuid().ToString("N")).Status == MilaNativeStatus.InvalidRequest &&
            RustNative.TrySessionRequestShow(1, "bad").Status == MilaNativeStatus.InvalidRequest &&
            RustNative.TrySessionShareShow(1, Guid.Empty).Status == MilaNativeStatus.InvalidRequest,
            "session read arguments are validated before the native call");
        // The protocol fixture's terminal kill result decodes as closed.
        using System.Text.Json.JsonDocument fixture = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(
            Path.Combine(AppContext.BaseDirectory, "fixtures", "porsche_client_results.json")));
        System.Text.Json.JsonElement kill = fixture.RootElement.GetProperty("results").GetProperty("terminal kill");
        Require(MilaSessionReads.TerminalClosed(B(kill.GetRawText()), kill.GetProperty("session_id").GetString()!), "fixture terminal kill result");
    }

    private static void AssertThreadListingProtocol()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "fixtures", "porsche_client_results.json");
        using JsonDocument fixtures = JsonDocument.Parse(File.ReadAllBytes(path));
        string result = fixtures.RootElement.GetProperty("results").GetProperty("thread ls").GetRawText();
        foreach (string body in new[] { result, $"{{\"version\":1,\"status\":\"succeeded\",\"result\":{result}}}" })
        {
            MilaThreadListing listing = MilaThreadListing.Decode(Encoding.UTF8.GetBytes(body));
            Require(listing.Threads.Count > 0 && listing.Threads[0].Id == new Guid("0d9cc041-9db2-4e4c-b28b-1e41d7f472c1") &&
                listing.Threads[0].State == "ready", "thread listing decodes Porsche's thread ls result");
        }
        foreach (string refused in new[]
                 {
                     "{\"threads\":[]}",
                     $"{{\"version\":1,\"status\":\"failed\",\"result\":{result}}}",
                     $"{{\"version\":2,\"status\":\"succeeded\",\"result\":{result}}}",
                 })
        {
            bool threw = false;
            try { MilaThreadListing.Decode(Encoding.UTF8.GetBytes(refused)); }
            catch (InvalidDataException) { threw = true; }
            Require(threw, "thread listing refuses a non-protocol shape");
        }
    }

    private static void AssertRoutes()
    {
        MilaRoute? machines = MilaRouteParser.Parse("overalls://mgmt.example.test/machines");
        Require(machines is { Kind: MilaRouteKind.Machines, Host: "mgmt.example.test" }, "machines activation route");
        MilaRoute? machine = MilaRouteParser.Parse("overalls://mgmt.example.test/machines/0d9cc041-9db2-4e4c-b28b-1e41d7f472c1");
        Require(machine is { Kind: MilaRouteKind.Machine } && machine.Value.Id.HasValue, "machine activation route");
        foreach (string invalid in new[] { "https://mgmt.example.test/machines", "overalls://MGMT.example.test/machines", "overalls://-mgmt.example.test/machines", "overalls://mgmt.example.test:443/machines", "overalls://mgmt.example.test/machines?x=1", "overalls://mgmt.example.test/unknown", "overalls://mgmt.example.test/machines/new", "overalls://mgmt.example.test/machines/" + new string('a', 2010) })
            Require(MilaRouteParser.Parse(invalid) is null, "invalid activation route refusal");
    }

    private static void AssertExternalActivation()
    {
        MilaExternalActivation? deepLink = MilaExternalActivationParser.ParseArguments(
            "overalls://mgmt.example.test/machines");
        Require(deepLink is { Route.Kind: MilaRouteKind.Machines, IsShareTarget: false },
            "protocol activation routing");
        MilaExternalActivation? shared = MilaExternalActivationParser.ParseArguments(
            "--share overalls://mgmt.example.test/threads");
        Require(shared is { Route.Kind: MilaRouteKind.Threads, IsShareTarget: true },
            "share activation routing");
        Require(shared is { } accepted && MilaShareTarget.TryAuthorize(
            accepted, authenticated: true, "mgmt.example.test", out MilaRoute authorized) &&
            authorized.Kind == MilaRouteKind.Threads, "authenticated share authorization");
        Require(shared is { } rejected && !MilaShareTarget.TryAuthorize(
            rejected, authenticated: false, "mgmt.example.test", out _),
            "signed-out share refusal");
        Require(shared is { } wrongHost && !MilaShareTarget.TryAuthorize(
            wrongHost, authenticated: true, "other.example.test", out _),
            "cross-deployment share refusal");
        var gate = new MilaExternalActivationGate();
        long activationGeneration = gate.Generation;
        gate.Reset();
        Require(shared is { } stale && !gate.TryAuthorize(stale, activationGeneration, true, "mgmt.example.test", out _),
            "stale generation share refusal");
        foreach (string invalid in new[] { "--share", "--sharex overalls://mgmt.example.test/machines", "--share https://example.test", "overalls://mgmt.example.test/machines\n", new string('x', 4097) })
            Require(MilaExternalActivationParser.ParseArguments(invalid) is null,
                "invalid external activation refusal");
    }

    private static void AssertDeploymentPorts()
    {
        MilaDeployment? legacy = JsonSerializer.Deserialize<MilaDeployment>("{\"Host\":\"mgmt.example.test\"}")?.Normalize();
        Require(legacy is { Host: "mgmt.example.test", Port: MilaDeployment.DefaultPort }, "legacy deployment defaults to Porsche port 22");
        MilaDeployment explicitPort = new("mgmt.example.test", 2222);
        MilaDeployment? roundTrip = JsonSerializer.Deserialize<MilaDeployment>(JsonSerializer.Serialize(explicitPort));
        Require(roundTrip is { Host: "mgmt.example.test", Port: 2222 }, "deployment port persists as typed value");
    }

    private sealed class FakeHello(MilaWindowsHelloAvailability availability, MilaWindowsHelloVerification result) : IMilaWindowsHelloVerifier
    {
        internal string? LastMessage { get; private set; }
        public Task<MilaWindowsHelloAvailability> CheckAvailabilityAsync(CancellationToken cancellationToken = default) => Task.FromResult(availability);
        public Task<MilaWindowsHelloVerification> VerifyAsync(string message, CancellationToken cancellationToken = default) { LastMessage = message; return Task.FromResult(result); }
    }

    private static void RefusesSnapshot(byte[] snapshot, string host, ushort port)
    {
        MilaNativeSnapshotResult result = RustNative.TryValidateSnapshot(snapshot, host, port, true);
        Require((int)result.Status == -4 && result.Summary is null, "invalid snapshot refusal");
    }
}
