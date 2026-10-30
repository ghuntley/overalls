using System.Net.Http.Headers;
using System.Net.Security;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Mila.Windows.Interop;

/// <summary>Validated fixture descriptor v1 written by the hermetic Marshall+Porsche fixture.</summary>
/// <remarks>
/// @cc [owner:ghuntley,label:verification;security] mila-windows-journey-descriptor
/// The descriptor MUST be exactly version 1 with canonical host, non-zero
/// ports, a parseable CA certificate whose server name equals the host, an
/// HTTPS approver hook and bounded seed values; anything else MUST refuse
/// before a network connection. The bearer token MUST NOT be printed.
/// </remarks>
internal sealed record MilaJourneyDescriptor(
    string Host, ushort SshPort, ushort HttpsPort, X509Certificate2 Ca, Uri ApproverUrl, string ApproverToken,
    string MachineName, Guid MachineId, string SharePrincipal, string AccountEmail)
{
    private const int MaxBytes = 64 * 1024;

    internal static MilaJourneyDescriptor Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > MaxBytes) throw new InvalidDataException("descriptor size");
        using JsonDocument document = JsonDocument.Parse(bytes.ToArray());
        JsonElement root = document.RootElement;
        Exact(root, "version", "deployment", "tls", "approver", "seed");
        if (root.GetProperty("version").ValueKind != JsonValueKind.Number || root.GetProperty("version").GetInt32() != 1)
            throw new InvalidDataException("descriptor version");
        JsonElement deployment = Exact(root.GetProperty("deployment"), "host", "ssh_port", "https_port");
        JsonElement tls = Exact(root.GetProperty("tls"), "ca_pem", "server_name");
        JsonElement approver = Exact(root.GetProperty("approver"), "url", "bearer_token");
        JsonElement seed = Exact(root.GetProperty("seed"), "machine_name", "machine_id", "share_principal", "account_email");
        string host = Text(deployment, "host", 253);
        if (!MilaDeploymentHost.IsCanonical(host)) throw new InvalidDataException("descriptor host");
        ushort ssh = Port(deployment, "ssh_port");
        ushort https = Port(deployment, "https_port");
        if (Text(tls, "server_name", 253) != host) throw new InvalidDataException("descriptor server name must equal host");
        X509Certificate2 ca;
        try { ca = X509Certificate2.CreateFromPem(Text(tls, "ca_pem", 32 * 1024)); }
        catch (CryptographicException) { throw new InvalidDataException("descriptor CA"); }
        if (!Uri.TryCreate(Text(approver, "url", 2048), UriKind.Absolute, out Uri? hook) || hook.Scheme != Uri.UriSchemeHttps ||
            hook.UserInfo.Length != 0 || hook.Fragment.Length != 0)
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
        return new(host, ssh, https, ca, hook, token, machine, machineId, principal, account);
    }

    private static bool Email(string value) =>
        value.IndexOf('@') is > 0 and var at && at < value.Length - 1 && !value.Any(char.IsWhiteSpace);

    private static JsonElement Exact(JsonElement element, params string[] names)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal)
                .SequenceEqual(names.Order(StringComparer.Ordinal)))
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
/// approval through the approver hook, machine listing and share mutation,
/// terminal attach, transport-loss reconnect, authenticated share completion
/// and notification device listing. It MUST fail on any step that does not
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
        using CancellationTokenSource timeout = new(TimeSpan.FromMinutes(5));
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

        MilaShareCompletion shares = new(new MilaExternalActivationGate());
        MilaExternalActivation share = MilaExternalActivationParser.ParseArguments($"--share overalls://{host}/threads")
            ?? throw new InvalidOperationException("journey share route");
        Program.Require(shares.Offer(share, false, null, out _) == MilaShareCompletionOutcome.Deferred, "journey share deferred while signed out");

        bool keyExisted = KeyExists(host);
        DeviceKey key = DeviceKey.OpenOrCreate(host);
        try
        {
            using MilaSessionConnection session = new();
            MilaSignInFlow flow = new();
            MilaJourneyApprover approver = new(descriptor, handler);
            MilaSignInCoordinator coordinator = new(flow, session, approver,
                policy: new MilaSignInPolicy(TimeSpan.FromSeconds(1), 3, TimeSpan.FromSeconds(1), 30_000));
            MilaSignInTarget target = new(host, descriptor.SshPort, descriptor.HttpsPort, trust.Document!, key.PublicPoint(), bytes => key.Sign(bytes));
            MilaSignInState state = await coordinator.SignInAsync(target, cancellationToken);
            Program.Require(state.Phase == MilaSignInPhase.SignedIn && session.Handle is > 0 && !string.IsNullOrEmpty(state.Account),
                $"journey sign-in ({state.Phase}/{state.Failure})");
            Program.Require(string.Equals(state.Account, descriptor.AccountEmail, StringComparison.OrdinalIgnoreCase),
                "journey signed in as the seeded account");
            Step(approver.Calls > 0 ? "browser approval sign-in" : "sign-in (key already approved)");

            Program.Require(shares.Complete(host, out MilaRoute shared) == MilaShareCompletionOutcome.Navigated &&
                shared.Kind == MilaRouteKind.Threads, "journey share completion");
            Step("authenticated share completion");

            ulong handle = session.Handle!.Value;
            Program.Require(RustNative.TrySessionReadMachines(handle, false) == MilaNativeStatus.Ok, "journey machine read");
            MilaNativeSessionBytesResult listing = RustNative.TrySessionListing(handle);
            Program.Require(listing.Succeeded, "journey machine listing");
            MilaMachineRow machine = RustNative.DecodeSessionListing(listing.Data!).Machines
                .FirstOrDefault(row => row.Id == descriptor.MachineId && row.Name == descriptor.MachineName)
                ?? throw new InvalidOperationException("journey seed machine missing");
            Step("machine listing");

            Program.Require(RustNative.TrySessionShareMutation(handle, machine.Id, descriptor.SharePrincipal, "viewer", true, RequestId()).Succeeded,
                "journey share add");
            Program.Require(RustNative.TrySessionShareMutation(handle, machine.Id, descriptor.SharePrincipal, null, false, RequestId()).Succeeded,
                "journey share remove");
            Step("machine share add/remove");

            MilaNativeSessionBytesResult devices = RustNative.TrySessionDevices(handle);
            Program.Require(devices.Succeeded, "journey device listing");
            _ = MilaWindowsNotificationDevicesController.DecodeListing(devices.Data!);
            Step("notification device listing");

            // Real Porsche refuses unnamed attach: `terminal new` names the session first.
            // The hermetic fixture runs no guest, so Marshall refuses it with the
            // closed `terminal_unavailable` reason, which the journey accepts.
            MilaNativeTerminalOpen opened = RustNative.TrySessionTerminalNew(handle, machine.Id, RequestId());
            if (!opened.Succeeded)
            {
                string? refusal = RustNative.TrySessionLastRefusal(handle);
                Program.Require(refusal == "terminal_unavailable", $"journey terminal new ({opened.Status}/{refusal ?? "none"})");
                Step("terminal new refused: terminal_unavailable (no guest)");
            }
            else
            {
                MilaTerminalStream terminal = new(MilaRustTerminalTransport.Instance, () => session.Handle);
                Program.Require(terminal.Attach(machine.Id, machine.CanWrite, 80, 24) && terminal.TerminalId is not null,
                    "journey named terminal attach");
                MilaTerminalPoll poll = MilaTerminalPoll.Idle;
                for (int i = 0; i < 10 && poll is MilaTerminalPoll.Idle; i++) poll = terminal.Poll();
                Program.Require(poll is MilaTerminalPoll.Output or MilaTerminalPoll.Idle or MilaTerminalPoll.Ended, $"journey terminal poll ({poll})");
                terminal.Kill();
                Step($"named terminal attach ({poll})");
            }

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
        }
    }

    private static string RequestId() => "porsche-" + Guid.NewGuid().ToString("N");

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
        foreach ((string label, string json) in new[]
                 {
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
