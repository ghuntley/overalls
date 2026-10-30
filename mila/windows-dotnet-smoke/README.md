# Windows Rust interop smoke

This .NET 10 console executable links the production `RustNative.cs` without
WinUI or test-framework dependencies. Run after the production Windows build:

```powershell
dotnet run --project mila/windows-dotnet-smoke --configuration Release -p:MilaNativeDll=C:\absolute\path\to\staged\mila_native.dll
```

`MilaNativeDll` is required and must exist. The project copies it beside its
executable. A missing library or export fails the ABI-version assertion; the
production `Unavailable` fallback never passes. Checks cover a host-qualified
route, invalid-route refusal, snapshot summary layout including a timestamp
larger than 32 bits, wrong host/port, malformed and oversized snapshots, and
short route output preserving both guard bytes and the reported length.

The `windows-native` job passes the DLL staged by the WinUI build, rather than
an independently supplied test implementation. These checks establish only the
invoked adapter behavior, not UI, device custody or lifecycle acceptance.

## Lifecycle checks

`LifecycleSmoke.cs` covers the deployment picker, `whoami` decoding, sign-in
approval outcomes and bounded reconnect, terminal reconnect, the WNS exchange,
share completion, the shared Porsche device fixture and catalog coverage for
every lifecycle message. Fakes replace only the network peer and OS services
(scripted session connect/whoami, PTY transport, WNS channel, Susan); the Rust
WNS validation and Susan body encoding and the new ABI refusals run against
the staged library. The project also builds and runs on Linux against
`libmila_ffi.so` copied as `libmila_native.so`, which is how it was checked
before Windows CI.

## Journey mode

```powershell
dotnet run --project mila/windows-dotnet-smoke --configuration Release `
  -p:MilaNativeDll=C:\absolute\path\to\mila_native.dll -- --descriptor C:\path\descriptor.json
```

The descriptor is the hermetic Marshall+Porsche fixture's version 1 JSON:

```json
{"version":1,
 "deployment":{"host":"localhost","ssh_port":2222,"https_port":8443},
 "tls":{"ca_pem":"-----BEGIN CERTIFICATE-----...","server_name":"localhost"},
 "approver":{"url":"https://localhost:8443/...","bearer_token":"..."},
 "seed":{"machine_name":"...","machine_id":"<uuid>",
         "share_principal":"second@example.test","account_email":"owner@example.test"}}
```

Unknown members, another version, a non-canonical host, zero ports, a server
name other than the host, an unparsable CA or a non-HTTPS approver are refused
before any connection. The journey trusts only the fixture CA, fetches
`https://host:https_port/bin/ssh-trust.json`, reconciles it in Rust, signs in
with a CNG device key (deleted afterwards when the journey created it), lets the
approver hook approve the browser link (`POST {approval_url, fingerprint}` with
the Bearer token), then lists machines, adds and removes a viewer share on the
seed machine (matched by `machine_id` and name, signed in as `account_email`),
lists notification devices, opens a named terminal with `terminal new` and
attaches to it (the fixture runs no guest, so the closed `terminal_unavailable`
refusal is accepted there), simulates a
transport loss and reconnects, and completes a share deferred before sign-in.
The bearer token is never printed. The `windows-native` job runs it only when
the repository variable `MILA_WINDOWS_JOURNEY` is `enabled` and the fixture
tunnel has written `$RUNNER_TEMP/mila-journey-descriptor.json`.
