using System.Net.Http.Headers;
using System.Net.Security;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Mila.Windows.Interop;

/// <summary>Validated fixture descriptor v1 written by the hermetic Marshall+Porsche fixture.</summary>
/// <remarks>
/// @cc [owner:ghuntley,label:verification;security] mila-windows-journey-descriptor
/// The descriptor MUST be exactly version 1 with canonical host, non-zero
/// ports, a parseable CA certificate whose server name equals the host, an
/// HTTPS approver hook and bounded seed values; anything else MUST refuse
/// before a network connection. The bearer token MUST NOT be printed.
/// The fixture's optional v1 members (`approver.fixture_url`,
/// `seed.terminal_machine_id`, `seed.terminal_machine_name` and the
/// `launcher` block) are accepted and validated when present, as the Linux and
/// Apple journeys accept them; any other member still refuses.
/// </remarks>
internal sealed record MilaJourneyDescriptor(
    string Host, ushort SshPort, ushort HttpsPort, X509Certificate2 Ca, Uri ApproverUrl, string ApproverToken,
    string MachineName, Guid MachineId, string SharePrincipal, string AccountEmail)
{
    /// <summary>Base of the fixture's stand-in action hook, when the fixture serves one.</summary>
    internal Uri? FixtureUrl { get; init; }

    /// <summary>The guest-backed terminal machine, when the fixture runs its terminal mode.</summary>
    internal Guid? TerminalMachineId { get; init; }

    internal string? TerminalMachineName { get; init; }

    private const int MaxBytes = 64 * 1024;

    internal static MilaJourneyDescriptor Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > MaxBytes) throw new InvalidDataException("descriptor size");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = document.RootElement;
        Members(root, ["version", "deployment", "tls", "approver", "seed"], ["launcher"]);
        if (root.GetProperty("version").ValueKind != JsonValueKind.Number || root.GetProperty("version").GetInt32() != 1)
            throw new InvalidDataException("descriptor version");
        JsonElement deployment = Members(root.GetProperty("deployment"), ["host", "ssh_port", "https_port"], []);
        JsonElement tls = Members(root.GetProperty("tls"), ["ca_pem", "server_name"], []);
        JsonElement approver = Members(root.GetProperty("approver"), ["url", "bearer_token"], ["fixture_url"]);
        JsonElement seed = Members(root.GetProperty("seed"), ["machine_name", "machine_id", "share_principal", "account_email"],
            ["terminal_machine_id", "terminal_machine_name"]);
        // The launcher block records the fixture's bind address; the journey
        // reaches the fixture through localhost and does not use it.
        if (root.TryGetProperty("launcher", out JsonElement launcher)) Text(Members(launcher, ["bind"], []), "bind", 253);
        Uri? fixtureUrl = null;
        if (approver.TryGetProperty("fixture_url", out _) &&
            (!Uri.TryCreate(Text(approver, "fixture_url", 2048), UriKind.Absolute, out fixtureUrl) || !HttpsHook(fixtureUrl)))
            throw new InvalidDataException("descriptor approver fixture_url");
        Guid? terminalId = null;
        if (seed.TryGetProperty("terminal_machine_id", out _))
        {
            if (!Guid.TryParseExact(Text(seed, "terminal_machine_id", 36), "D", out Guid parsedTerminal) || parsedTerminal == Guid.Empty)
                throw new InvalidDataException("descriptor seed terminal machine id");
            terminalId = parsedTerminal;
        }
        string? terminalName = seed.TryGetProperty("terminal_machine_name", out _) ? Text(seed, "terminal_machine_name", 63) : null;
        string host = Text(deployment, "host", 253);
        if (!MilaDeploymentHost.IsCanonical(host)) throw new InvalidDataException("descriptor host");
        ushort ssh = Port(deployment, "ssh_port");
        ushort https = Port(deployment, "https_port");
        if (Text(tls, "server_name", 253) != host) throw new InvalidDataException("descriptor server name must equal host");
        X509Certificate2 ca;
        try { ca = X509Certificate2.CreateFromPem(Text(tls, "ca_pem", 32 * 1024)); }
        catch (CryptographicException) { throw new InvalidDataException("descriptor CA"); }
        if (!Uri.TryCreate(Text(approver, "url", 2048), UriKind.Absolute, out Uri? hook) || !HttpsHook(hook))
        {
            ca.Dispose();
            throw new InvalidDataException("descriptor approver url");
        }
        string token = Text(approver, "bearer_token", 4096);
        if (!token.All(character => character is > ' ' and < '\x7f'))
        {
            ca.Dispose();
            throw new InvalidDataException("descriptor approver token");
        }
        string machine = Text(seed, "machine_name", 63);
        string principal = Text(seed, "share_principal", 320);
        string account = Text(seed, "account_email", 320);
        if (!Email(principal) || !Email(account) || string.Equals(principal, account, StringComparison.OrdinalIgnoreCase))
        {
            ca.Dispose();
            throw new InvalidDataException("descriptor seed principals");
        }
        if (!Guid.TryParseExact(Text(seed, "machine_id", 36), "D", out Guid machineId) || machineId == Guid.Empty)
        {
            ca.Dispose();
            throw new InvalidDataException("descriptor seed machine id");
        }
        return new(host, ssh, https, ca, hook, token, machine, machineId, principal, account)
        {
            FixtureUrl = fixtureUrl, TerminalMachineId = terminalId, TerminalMachineName = terminalName,
        };
    }

    private static bool HttpsHook(Uri hook) =>
        hook.Scheme == Uri.UriSchemeHttps && hook.UserInfo.Length == 0 && hook.Fragment.Length == 0;

    private static bool Email(string value) =>
        value.IndexOf('@') is > 0 and var at && at < value.Length - 1 && !value.Any(char.IsWhiteSpace);

    /// <summary>Every required member and otherwise only the named optional ones, each once.</summary>
    private static JsonElement Members(JsonElement element, string[] required, string[] optional)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new InvalidDataException("descriptor members");
        string[] names = element.EnumerateObject().Select(property => property.Name).ToArray();
        if (names.Distinct(StringComparer.Ordinal).Count() != names.Length ||
            !required.All(name => names.Contains(name, StringComparer.Ordinal)) ||
            !names.All(name => required.Contains(name, StringComparer.Ordinal) || optional.Contains(name, StringComparer.Ordinal)))
            throw new InvalidDataException("descriptor members");
        return element;
    }

    private static string Text(JsonElement element, string name, int max)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } text || text.Length > max ||
            (name != "ca_pem" && text.Any(char.IsControl)))
            throw new InvalidDataException("descriptor " + name);
        return text;
    }

    private static ushort Port(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetUInt16(out ushort port) || port == 0)
            throw new InvalidDataException("descriptor " + name);
        return port;
    }

    /// <summary>HTTP handler that trusts only the fixture CA, with redirects disabled.</summary>
    internal SocketsHttpHandler PinnedHandler()
    {
        X509ChainPolicy policy = new()
        {
            TrustMode = X509ChainTrustMode.CustomRootTrust,
            RevocationMode = X509RevocationMode.NoCheck,
        };
        policy.CustomTrustStore.Add(Ca);
        return new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            SslOptions = new SslClientAuthenticationOptions { CertificateChainPolicy = policy },
        };
    }
}

/// <summary>Approver hook: POST {approval_url, fingerprint} with a Bearer token, expecting 2xx.</summary>
internal sealed class MilaJourneyApprover(MilaJourneyDescriptor descriptor, HttpMessageHandler handler) : IMilaApprovalBrowser
{
    internal int Calls { get; private set; }

    public async Task<bool> OpenAsync(MilaApprovalInfo approval, CancellationToken cancellationToken)
    {
        Calls++;
        using HttpClient client = new(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(30) };
        using HttpRequestMessage request = new(HttpMethod.Post, descriptor.ApproverUrl)
        {
            Content = new StringContent(JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["approval_url"] = approval.Url,
                ["fingerprint"] = approval.Fingerprint,
            }), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", descriptor.ApproverToken);
        using HttpResponseMessage response = await client.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"approver hook returned {(int)response.StatusCode}");
        return true;
    }
}

/// <summary>
/// @cc [owner:ghuntley,label:verification] mila-windows-journey-smoke
/// Journey mode runs only with `--descriptor PATH` against the tunnelled
/// fixture: CA-pinned trust enrollment, Rust session sign-in with browser
/// approval through the approver hook, machine listing, share add/remove read
/// back, notification device register/list/preferences/remove (WNS and
/// Susan stand-ins, real poke key), web show/set, machine lifecycle with
/// resize read-back, threads, SSH key listing and second-device revoke,
/// the guestless terminal refusal, the guest-backed terminal (when the
/// descriptor names one), transport-loss reconnect and authenticated share
/// completion. It MUST fail on any step that does not
/// complete through the staged Rust library.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class JourneySmoke
{
    internal static void Run(string descriptorPath)
    {
        MilaJourneyDescriptor descriptor = MilaJourneyDescriptor.Parse(File.ReadAllBytes(descriptorPath));
        Console.WriteLine($"journey: descriptor host={descriptor.Host} ssh={descriptor.SshPort} https={descriptor.HttpsPort}");
        using SocketsHttpHandler handler = descriptor.PinnedHandler();
        using CancellationTokenSource timeout = new(TimeSpan.FromMinutes(25));
        RunAsync(descriptor, handler, timeout.Token).GetAwaiter().GetResult();
        descriptor.Ca.Dispose();
        Console.WriteLine("Windows journey smoke passed.");
    }

    private static void Step(string name) => Console.WriteLine("journey: " + name + " ok");

    private static async Task RunAsync(MilaJourneyDescriptor descriptor, SocketsHttpHandler handler, CancellationToken cancellationToken)
    {
        string host = descriptor.Host;
        byte[] fetched = await FetchTrustAsync(descriptor, handler, cancellationToken);
        MilaNativeTrustResult trust = RustNative.TryReconcileTrust(null, fetched, host, (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        Program.Require(trust.Status == MilaNativeStatus.Ok && trust.Document is not null, "journey trust enrollment");
        Step("trust enrollment");

        // The WinUI picker's controller over a private list: the fixture and a
        // second deployment that is never reached, then the fixture selected.
        string pickerPath = Path.Combine(Path.GetTempPath(), $"mila-journey-deployments-{Guid.NewGuid():N}.json");
        Action? signOutSelected = null;
        MilaShareCompletion shares = new(new MilaExternalActivationGate());
        MilaDeploymentPicker picker = new(new MilaDeploymentFileRepository(pickerPath), _ => signOutSelected?.Invoke());
        MilaDeploymentPickerController deployments = new(picker, shares);
        string sshPort = descriptor.SshPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        _ = deployments.Add(host, sshPort, select: false, out MilaDeployment? fixture);
        MilaDeploymentPickerView view = deployments.Add(SecondDeployment, sshPort, select: true, out MilaDeployment? second);
        Program.Require(fixture is not null && second is not null && view.Rows.Count == 2 && view.Selected == second,
            "journey picker lists two deployments");
        Step("deployment picker: two deployments listed");
        view = deployments.Choose(fixture) ?? throw new InvalidOperationException("journey picker select");
        Program.Require(view.Selected == fixture && view.HostText == host && view.PortText == sshPort && view.ForgetEnabled,
            "journey picker selects the fixture");
        Step("deployment picker: fixture selected");

        MilaExternalActivation share = MilaExternalActivationParser.ParseArguments($"--share overalls://{host}/threads")
            ?? throw new InvalidOperationException("journey share route");
        Program.Require(shares.Offer(share, false, null, out _) == MilaShareCompletionOutcome.Deferred, "journey share deferred while signed out");

        bool keyExisted = KeyExists(host);
        DeviceKey key = DeviceKey.OpenOrCreate(host);
        Console.WriteLine($"journey: device key custody {key.Custody}");
        try
        {
            using MilaSessionConnection session = new();
            MilaSignInFlow flow = new();
            MilaJourneyApprover approver = new(descriptor, handler);
            MilaSignInCoordinator coordinator = new(flow, session, approver,
                policy: new MilaSignInPolicy(TimeSpan.FromSeconds(1), 3, TimeSpan.FromSeconds(1), 30_000));
            signOutSelected = coordinator.SignOut;
            _ = deployments.Connect(host, sshPort, out MilaDeployment? selected, out long selection);
            Program.Require(selected == fixture && picker.IsCurrent(selection, fixture!), "journey picker sign-in target");
            MilaSignInTarget target = new(selected!.Host, selected.Port, descriptor.HttpsPort, trust.Document!, key.PublicPoint(), bytes => key.Sign(bytes));
            MilaSignInState state = await coordinator.SignInAsync(target, cancellationToken);
            Program.Require(state.Phase == MilaSignInPhase.SignedIn && session.Handle is > 0 && !string.IsNullOrEmpty(state.Account),
                $"journey sign-in ({state.Phase}/{state.Failure})");
            Program.Require(string.Equals(state.Account, descriptor.AccountEmail, StringComparison.OrdinalIgnoreCase),
                "journey signed in as the seeded account");
            Step(approver.Calls > 0 ? "browser approval sign-in" : "sign-in (key already approved)");

            Program.Require(shares.Complete(host, out MilaRoute shared) == MilaShareCompletionOutcome.Navigated &&
                shared.Kind == MilaRouteKind.Threads, "journey share completion");
            Step("authenticated share completion");

            // Switching away through the picker releases the session and fences
            // the fixture's selection generation before the second is visible.
            ulong first = session.Handle!.Value;
            view = deployments.Choose(second) ?? throw new InvalidOperationException("journey picker switch");
            Program.Require(view.Selected == second && session.Handle is null && flow.State.Phase == MilaSignInPhase.SignedOut &&
                !picker.IsCurrent(selection, fixture!), "journey picker switch releases the session");
            Step("deployment picker: switch away released the session and fenced its generation");

            // A share for the fixture received meanwhile is held, survives selecting
            // the fixture again, and completes once the picker's target signs in.
            Program.Require(shares.Offer(share, false, null, out _) == MilaShareCompletionOutcome.Deferred,
                "journey picker share deferred on another deployment");
            view = deployments.Choose(fixture) ?? throw new InvalidOperationException("journey picker switch back");
            Program.Require(view.Selected == fixture && shares.PendingHost == host, "journey picker share survives its own host");
            _ = deployments.Connect(host, sshPort, out selected, out selection);
            Program.Require(selected == fixture && picker.IsCurrent(selection, fixture!), "journey picker switch-back target");
            state = await coordinator.SignInAsync(target, cancellationToken);
            Program.Require(state.Phase == MilaSignInPhase.SignedIn && session.Handle is > 0 && session.Handle != first &&
                picker.IsCurrent(selection, fixture!), $"journey picker sign-in after switch back ({state.Phase}/{state.Failure})");
            Program.Require(shares.Complete(host, out shared) == MilaShareCompletionOutcome.Navigated &&
                shared.Kind == MilaRouteKind.Threads, "journey picker held share completion");
            Step("deployment picker: switch back signed in again and completed the held share");

            ulong handle = session.Handle!.Value;
            Program.Require(RustNative.TrySessionReadMachines(handle, false) == MilaNativeStatus.Ok, "journey machine read");
            MilaNativeSessionBytesResult listing = RustNative.TrySessionListing(handle);
            Program.Require(listing.Succeeded, "journey machine listing");
            MilaMachineRow machine = RustNative.DecodeSessionListing(listing.Data!).Machines
                .FirstOrDefault(row => row.Id == descriptor.MachineId && row.Name == descriptor.MachineName)
                ?? throw new InvalidOperationException("journey seed machine missing");
            Step("machine listing");

            await JourneyPages.SharingAsync(handle, machine.Id, descriptor.SharePrincipal, cancellationToken);

            await JourneyPages.NotificationsAsync(session, host, cancellationToken);

            // Web, lifecycle and threads assert their effects through session
            // reads; the fixture hooks stand in for the provisioner and agent.
            MilaFixtureHook hook = new(descriptor, handler);
            await JourneyPages.WebAsync(handle, machine.Id, cancellationToken);
            await JourneyPages.LifecycleAsync(handle, hook, cancellationToken);
            await JourneyPages.ThreadsAsync(handle, hook, cancellationToken);
            if (descriptor.TerminalMachineId is { } terminalMachine)
                await JourneyPages.GuestTerminalAsync(session, terminalMachine, cancellationToken);

            // The guestless refusal runs on a machine this run creates and never
            // observes, not on the shared seed machine (ADR-0264 item 9).
            await JourneyPages.GuestlessTerminalAsync(handle, hook, cancellationToken);

            await SshKeysAsync(descriptor, handler, target, session, key, cancellationToken);

            Program.Require(coordinator.ReportTransportLoss(state.Generation) && session.Handle is null, "journey transport loss");
            state = await coordinator.ReconnectAsync(target, cancellationToken);
            Program.Require(state.Phase == MilaSignInPhase.SignedIn && session.Handle is > 0 && session.Handle != handle,
                $"journey reconnect ({state.Phase}/{state.Failure})");
            Step("reconnect through Rust session");
            coordinator.SignOut();
        }
        finally
        {
            key.Dispose();
            if (!keyExisted) DeleteKey(host);
            if (File.Exists(pickerPath)) File.Delete(pickerPath);
        }
    }

    /// <summary>A second, never-reached deployment for the picker steps; canonical, unlike Linux's IP-literal alias.</summary>
    private const string SecondDeployment = "mila-journey-second.localhost";

    private static string RequestId() => "porsche-" + Guid.NewGuid().ToString("N");

    /// <summary>
    /// SSH keys through the client controller: this device's key is listed and
    /// protected from revoke; a second device signs in, the first revokes it
    /// once, and the revoked key must be approved again before it can sign in.
    /// </summary>
    private static async Task SshKeysAsync(MilaJourneyDescriptor descriptor, SocketsHttpHandler handler, MilaSignInTarget target,
        MilaSessionConnection session, DeviceKey key, CancellationToken cancellationToken)
    {
        string own = MilaSshKeysController.Fingerprint(Encoding.ASCII.GetString(key.PublicPoint()))
            ?? throw new InvalidOperationException("journey device fingerprint");
        int revokes = 0;
        MilaSshKeysController keys = new(
            _ =>
            {
                MilaNativeSessionBytesResult listing = RustNative.TrySessionSshKeys(session.Handle ?? 0);
                Program.Require(listing.Succeeded, $"journey ssh-key list ({listing.Status})");
                return Task.FromResult<IReadOnlyList<MilaSshKey>>(MilaSshKeysController.DecodeListing(listing.Data!)
                    .Select(row => row with { IsCurrentDevice = row.Fingerprint == own }).ToArray());
            },
            (id, _) =>
            {
                revokes++;
                MilaNativeSessionActionResult revoked = RustNative.TrySessionSshKeyRevoke(session.Handle ?? 0, id, RequestId());
                Program.Require(revoked.Succeeded, $"journey ssh-key remove ({revoked.Status}/{RustNative.TrySessionLastRefusal(session.Handle ?? 0) ?? "none"})");
                return Task.CompletedTask;
            });
        await keys.LoadAsync(true, cancellationToken);
        MilaSshKey ownRow = keys.Keys.SingleOrDefault(row => row.IsCurrentDevice)
            ?? throw new InvalidOperationException($"journey ssh keys: device key missing ({keys.Status})");
        Step("ssh keys: device key listed");
        await keys.RevokeAsync(ownRow, cancellationToken);
        Program.Require(revokes == 0 && keys.Keys.Any(row => row.Id == ownRow.Id), "journey ssh keys: this device is not revocable");
        Step("ssh keys: this device not submitted");

        string secondHost = "mila-journey-second." + target.Host;
        bool secondExisted = KeyExists(secondHost);
        DeviceKey second = DeviceKey.OpenOrCreate(secondHost);
        try
        {
            byte[] secondPoint = second.PublicPoint();
            string secondFingerprint = MilaSshKeysController.Fingerprint(Encoding.ASCII.GetString(secondPoint))
                ?? throw new InvalidOperationException("journey second fingerprint");
            MilaSignInTarget secondTarget = target with { PublicKey = secondPoint, Signer = bytes => second.Sign(bytes) };
            using (MilaSessionConnection secondSession = new())
            {
                MilaSignInCoordinator secondCoordinator = new(new MilaSignInFlow(), secondSession, new MilaJourneyApprover(descriptor, handler),
                    policy: new MilaSignInPolicy(TimeSpan.FromSeconds(1), 3, TimeSpan.FromSeconds(1), 30_000));
                MilaSignInState signedIn = await secondCoordinator.SignInAsync(secondTarget, cancellationToken);
                Program.Require(signedIn.Phase == MilaSignInPhase.SignedIn &&
                    string.Equals(signedIn.Account, descriptor.AccountEmail, StringComparison.OrdinalIgnoreCase),
                    $"journey second device sign-in ({signedIn.Phase}/{signedIn.Failure})");
                secondCoordinator.SignOut();
            }
            Step("ssh keys: second device signed in");

            await keys.LoadAsync(true, cancellationToken);
            MilaSshKey secondRow = keys.Keys.SingleOrDefault(row => row.Fingerprint == secondFingerprint)
                ?? throw new InvalidOperationException("journey ssh keys: second key missing");
            await keys.RevokeAsync(secondRow, cancellationToken);
            await keys.RevokeAsync(secondRow, cancellationToken);
            Program.Require(revokes == 1 && keys.Status == MilaSshKeysStatus.Loaded && keys.Keys.All(row => row.Id != secondRow.Id),
                $"journey ssh keys: second key revoked once ({revokes}/{keys.Status})");

            MilaNativeSessionConnectResult fresh = RustNative.TrySessionConnect(
                target.Trust, target.Host, secondPoint, target.SshPort, 30_000, bytes => second.Sign(bytes));
            if (fresh.Succeeded)
            {
                try
                {
                    MilaNativeSessionBytesResult whoami = RustNative.TrySessionWhoami(fresh.Handle!.Value);
                    Program.Require(!whoami.Succeeded || MilaWhoamiDecoder.Decode(whoami.Data!) is not MilaWhoami.Approved,
                        "journey ssh keys: revoked key still authenticates");
                }
                finally { RustNative.TrySessionClose(fresh.Handle!.Value); }
            }
            Step("ssh keys: revoked, reapproval required");
        }
        finally
        {
            second.Dispose();
            if (!secondExisted) DeleteKey(secondHost);
        }
    }

    private static async Task<byte[]> FetchTrustAsync(MilaJourneyDescriptor descriptor, HttpMessageHandler handler, CancellationToken cancellationToken)
    {
        using HttpClient client = new(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(30) };
        Uri uri = new($"https://{descriptor.Host}:{descriptor.HttpsPort}/bin/ssh-trust.json");
        using HttpResponseMessage response = await client.GetAsync(uri, cancellationToken);
        response.EnsureSuccessStatusCode();
        byte[] bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        Program.Require(bytes.Length is > 0 and <= 8192, "journey trust size");
        return bytes;
    }

    private static readonly CngProvider[] Providers =
        [CngProvider.MicrosoftPlatformCryptoProvider, CngProvider.MicrosoftSoftwareKeyStorageProvider];

    private static bool KeyExists(string host)
    {
        foreach (CngProvider provider in Providers)
        {
            try { if (CngKey.Exists(DeviceKey.KeyName(host), provider)) return true; }
            catch (CryptographicException) { }
        }
        return false;
    }

    private static void DeleteKey(string host)
    {
        foreach (CngProvider provider in Providers)
        {
            try
            {
                if (!CngKey.Exists(DeviceKey.KeyName(host), provider)) continue;
                using CngKey key = CngKey.Open(DeviceKey.KeyName(host), provider);
                key.Delete();
            }
            catch (CryptographicException) { }
        }
    }
}

/// <summary>Hermetic descriptor validation so journey mode has evidence before the fixture exists.</summary>
internal static class JourneyDescriptorSmoke
{
    internal static void Run()
    {
        using ECDsa key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        CertificateRequest request = new("CN=Mila journey test CA", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        using X509Certificate2 ca = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
        string pem = ca.ExportCertificatePem();
        string Descriptor(string host = "localhost", int ssh = 2222, int https = 8443, string? server = null, string? pemText = null,
            string hook = "https://localhost:8443/__fixture/approve", string token = "fixture-token", string principal = "second@example.test",
            int version = 1, string extra = "", string machineId = "019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a",
            string account = "owner@example.test") => JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["version"] = version,
            ["deployment"] = new Dictionary<string, object> { ["host"] = host, ["ssh_port"] = ssh, ["https_port"] = https },
            ["tls"] = new Dictionary<string, object> { ["ca_pem"] = pemText ?? pem, ["server_name"] = server ?? host },
            ["approver"] = new Dictionary<string, object> { ["url"] = hook, ["bearer_token"] = token },
            ["seed"] = new Dictionary<string, object>
            {
                ["machine_name"] = "journey-machine", ["machine_id"] = machineId,
                ["share_principal"] = principal, ["account_email"] = account,
            },
        }).Replace("\"version\"", extra + "\"version\"", StringComparison.Ordinal);

        MilaJourneyDescriptor parsed = MilaJourneyDescriptor.Parse(Encoding.UTF8.GetBytes(Descriptor()));
        Program.Require(parsed is { Host: "localhost", SshPort: 2222, HttpsPort: 8443, MachineName: "journey-machine",
                AccountEmail: "owner@example.test" } && parsed.MachineId == Guid.Parse("019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a") &&
            parsed.Ca.Thumbprint == ca.Thumbprint, "journey descriptor v1 parses");
        using (SocketsHttpHandler handler = parsed.PinnedHandler())
            Program.Require(handler.SslOptions.CertificateChainPolicy?.CustomTrustStore.Count == 1 && !handler.AllowAutoRedirect,
                "journey handler pins only the fixture CA");
        parsed.Ca.Dispose();

        // The fixture's current v1 descriptor (run 41263134077): the optional
        // approver.fixture_url, seed terminal machine and launcher block.
        string Current(Action<JsonObject>? change = null)
        {
            JsonObject node = JsonNode.Parse(Descriptor())!.AsObject();
            node["approver"]!["fixture_url"] = "https://localhost:8444/fixture/";
            node["seed"]!["terminal_machine_id"] = "cf2dc277-763f-4c33-9fa5-503956fe6af8";
            node["seed"]!["terminal_machine_name"] = "vm-cf2dc277763f4c339fa5503956fe6af8";
            node["launcher"] = new JsonObject { ["bind"] = "100.81.223.13" };
            change?.Invoke(node);
            return node.ToJsonString();
        }
        MilaJourneyDescriptor current = MilaJourneyDescriptor.Parse(Encoding.UTF8.GetBytes(Current()));
        Program.Require(current.FixtureUrl == new Uri("https://localhost:8444/fixture/") &&
            current.TerminalMachineId == Guid.Parse("cf2dc277-763f-4c33-9fa5-503956fe6af8") &&
            current.TerminalMachineName == "vm-cf2dc277763f4c339fa5503956fe6af8", "journey descriptor v1 accepts the fixture's optional members");
        current.Ca.Dispose();
        Program.Require(parsed.FixtureUrl is null && parsed.TerminalMachineId is null && parsed.TerminalMachineName is null,
            "journey descriptor optional members default to absent");

        foreach ((string label, string json) in new[]
                 {
                     ("fixture url scheme", Current(node => node["approver"]!["fixture_url"] = "http://localhost:8444/fixture/")),
                     ("terminal machine id", Current(node => node["seed"]!["terminal_machine_id"] = "not-a-uuid")),
                     ("terminal machine name", Current(node => node["seed"]!["terminal_machine_name"] = "")),
                     ("launcher member", Current(node => node["launcher"]!["extra"] = 1)),
                     ("launcher shape", Current(node => node["launcher"] = "100.81.223.13")),
                     ("unknown approver member", Current(node => node["approver"]!["extra"] = "x")),
                     ("unknown seed member", Current(node => node["seed"]!["extra"] = "x")),
                     ("version", Descriptor(version: 2)),
                     ("host", Descriptor(host: "Bad Host")),
                     ("port", Descriptor(ssh: 0)),
                     ("port range", Descriptor(https: 70000)),
                     ("server name", Descriptor(server: "other.example")),
                     ("ca", Descriptor(pemText: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----")),
                     ("hook scheme", Descriptor(hook: "http://localhost:8443/approve")),
                     ("token", Descriptor(token: "has space")),
                     ("principal", Descriptor(principal: "not-an-email")),
                     ("account", Descriptor(account: "@example.test")),
                     ("same principal", Descriptor(account: "Second@example.test")),
                     ("machine id", Descriptor(machineId: "journey-machine")),
                     ("unknown member", Descriptor(extra: "\"extra\":1,")),
                 })
        {
            bool refused = false;
            try { MilaJourneyDescriptor.Parse(Encoding.UTF8.GetBytes(json)).Ca.Dispose(); }
            catch (InvalidDataException) { refused = true; }
            catch (JsonException) { refused = true; }
            Program.Require(refused, "journey descriptor refuses " + label);
        }
    }
}
