# Mila Windows native scaffold

This directory is the native Windows host for the desktop Mila client. It is a
small unpackaged WinUI 3 application targeting .NET 10 and Windows 10
19041. The native client owns presentation while the shared Rust core owns transport, validation, and policy.

## Build on Windows

Install the .NET 10 SDK, the Windows 10/11 SDK, and the Visual Studio workload
**Desktop development with C++**. From PowerShell:

```powershell
dotnet restore .\Mila.Windows.csproj
dotnet build .\Mila.Windows.csproj -c Debug -p:Platform=x64
dotnet run --project .\Mila.Windows.csproj -c Debug -p:Platform=x64
```

The project uses `Microsoft.WindowsAppSDK` with `UseWinUI=true` and runs
unpackaged (`WindowsPackageType=None`). Release packaging and signing belong to
the Windows build workflow once that workflow stages the Rust library.

## Rust ABI seam

`Interop/RustNative.cs` declares the typed ABI boundary with source-generated
`LibraryImport`. `TryGetVersion` returns `Unavailable` while `mila_native.dll`
is absent, so the scaffold can start before the native library is staged.
The C ABI the Rust `#[repr(C)]` implementation exports is described by the
single hand-written header `mila/rust/mila-ffi/include/mila_ffi.h`, which
`mila-ffi`'s `tests/header.rs` keeps equal to the crate's exports and enum
discriminants; `RustNative.cs` must match it. The native library must be copied beside the executable as
`mila_native.dll` by the Windows source-bundle build.

The boundary currently exposes only a status and version. Device keys,
signatures, tokens, command arguments and terminal bytes must remain in the
existing typed Mila transport and must not be added as untyped FFI payloads.

## Verification in this repository

The development host is Linux, so the Windows SDK and .NET SDK are not
available here. The project files are checked for contract and XML syntax;
`dotnet restore` and a Windows build must run in the Windows CI job described by
ADR-0235.

## Deployments, sign-in and reconnect

`Interop/DeploymentPicker.cs` owns the stored deployment list and the single
selection. Hosts are canonical lower-case DNS names (`localhost` is accepted
only for the loopback journey fixture). Selecting another deployment or
forgetting the selected one advances the selection generation and signs the
old deployment out first, so a pending approval, session handle or deferred
share for it cannot complete against the new one.

`Interop/SignInCoordinator.cs` drives `MilaSignInFlow` with the Rust session:
it connects through `mila_session_connect`, polls `mila_session_whoami` on the
same session while browser approval is pending, opens the approval link once
(only when it names the selected host and HTTPS port), and maps approval,
refusal, expiry and protocol outcomes. After a session operation reports a lost
transport, Reconnect starts a fresh generation and retries a bounded number of
times through the Rust session; a revoked key returns to browser approval.

## Terminal reconnect

`Interop/TerminalStream.cs` names a server terminal session with
`mila_session_terminal_new` and attaches with
`mila_session_terminal_attach_session` (Porsche refuses unnamed attach;
reconnect rejoins the same session id). It polls `mila_session_terminal_read`, which
classifies each read as data, idle or closed and reports a lost transport
separately. Only a lost transport reattaches, on the live session handle, with
a new generation that discards prior output and refuses older frames; attempts
are bounded and reset by received output. Kill, a clean close and sign-out end
the stream.

## Notifications (WNS)

`Interop/WindowsPushRegistration.cs` performs the channel exchange: the Windows
App SDK channel (`MILA_WNS_REMOTE_ID` names the Entra application), managed and
Rust channel-shape checks, the Rust-encoded Susan body posted to
`https://notifications.overalls.dev/api/push/v1/keys`, then
`mila_session_device_register`, where Rust validates Susan's reply and sends
the push key to Porsche on stdin. Windows X25519 poke-key custody is not yet
implemented, so the app reports notifications as unavailable before obtaining
a channel. WNS delivery, Susan issuance and poke decryption cannot be verified
hermetically; the smoke covers the exchange with fakes for WNS and Susan.

## Share completion

`MilaShareCompletion` holds one share activation received while signed out or
for another deployment and completes it, at most once and within ten minutes,
only after that host authenticates in the same activation generation.

## Windows Hello app lock

`Interop/MilaWindowsHelloBroker` is the only adapter that calls
`UserConsentVerifier`. `MilaAppLockController` exposes typed availability,
locked/unlocked state, and verification outcomes to the UI; biometric data,
passcodes, and Windows API objects never cross that boundary. The app disables
navigation while locked and requires a successful Windows Hello verification to
unlock.

## Release boundary

The .NET release is the production native client. Publish it with
`dotnet publish Mila.Windows.csproj -c Release -r win-x64 --self-contained true`
and stage the production `mila_native.dll`; do not invoke a different platform build.
Before signing or archiving, run `powershell -File .\verify-release.ps1
-PublishDirectory .\bin\Release\net10.0-windows10.0.19041.0\win-x64\publish`.
The verifier requires both release binaries and rejects foreign runtime engines, snapshots, and generated-runner files.
