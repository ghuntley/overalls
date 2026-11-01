# ADR-0235: Mila desktop clients for macOS and Windows

- ID: ADR-0235
- Date: 2026-10-21
- Status: accepted
- Implementation: partial
- Components: Mila, protocol, Marshall, mila-build
- Supersedes: none
- Superseded by: none

## Context

[ADR-0220](0220-mila-client-over-porsche-ssh.md) made Mila an iOS and Android
client with a Linux build for testing. Users also want first-class macOS and
Windows desktop apps. The code treated every platform that was not a phone as
Linux: file-backed keys, chmod-only storage, no push, and a hard-coded
`ios`/`android` device platform. Marshall and the protocol accepted only
`ios` and `android` for `device register`. No platform had distinct dev and
release build targets; release signing for iOS and Android was manual.

Facts that constrain the design:

- macOS has the Secure Enclave and APNs, but Secure Enclave keys and a push
  entitlement need a signed build with a provisioning profile; an unsigned
  local build has neither.
- Windows has no Secure Enclave. CNG's Microsoft Platform Crypto Provider holds
  non-exportable keys in a TPM 2.0, but many machines and VMs have no TPM. A TPM
  cannot hold an X25519 key.
- WNS, Windows' push service, needs a package identity (MSIX) and a new Susan
  provider ([ADR-0236](0236-susan-wns-provider.md)).
- POSIX permission bits mean nothing on NTFS; access is governed by DACLs.
- Windows CI hosts cannot run Nix, which ADR-0227 relies on to provide the
  patched dartssh2.

## Decision

Authorization: the approved Mila desktop plan (2026-10-20), with the user's
choices of hardware key custody, macOS APNs plus Windows WNS, signed release
artifacts, "for windows, if no tpm, no refusal. software is fine", and software
keys for unsigned macOS dev builds.

1. **Platform profile.** A single `PlatformProfile` per operating system fixes
   hardware-key custody, the push provider and device platform, the web view
   and the app lock. No code path infers Linux from "not a phone". Devices
   register as `ios`, `android`, `macos` or `windows`; the protocol and
   Marshall accept exactly these four.
2. **macOS.** Device keys live in the Secure Enclave and poke keys in the
   data-protection keychain group shared with a Notification Service extension.
   macOS uses APNs under the iOS topic `dev.overalls.mila`. The Swift for keys,
   poke keychain and poke opening is shared with iOS from `mila/app/darwin/Shared`.
   An unsigned dev build sets `MILA_SOFTWARE_KEYS`: owner-only software keys
   and no push. A release build that carries the define refuses to start.
3. **Windows.**
   - Device keys are non-exportable CNG ECDSA P-256 keys, one per host. The
     Platform Crypto Provider (TPM) is used when it works; otherwise the
     Software Key Storage Provider is used with no refusal. A key is always
     reopened from the provider that created it.
   - The X25519 poke key is generated natively, sealed with DPAPI (user scope)
     in the owner-only data directory, and only its public key crosses the
     platform channel.
   - Mila's files carry a protected DACL granting only the current user and
     SYSTEM, and Mila refuses to read a file whose DACL admits anyone else.
   - Push uses Windows App SDK raw notifications through WNS. The native poke
     opener decrypts the poke and shows a notification with fixed localized
     text, under the same `mila-native-poke-open-v1` contract as iOS and
     Android.
   - The app runs as a single instance, and `overalls://` links reach the
     running window.
4. **Build targets.** One typed planner, `mila-build <platform> <dev|release>`,
   defines a dev and a release target for Linux, Android, iOS, macOS and
   Windows.
   - A release plan refuses demo mode, software keys, another host's target and
     any missing signing input, and it verifies signatures as its final step.
   - Signing secrets arrive only through the environment and are redacted from
     printed plans.
   - Linux dev and release targets are Nix packages.
5. **Windows sources.** Windows builds run outside Nix from a Linux-built
   source bundle. The bundle holds the tracked Mila sources, a copied patched
   dartssh2 and the pinned native dependencies, so nothing resolves dartssh2
   from pub.dev (ADR-0227).

## Alternatives

- **Refuse Windows machines without a TPM.** Rejected by the user. A software
  CNG key is non-exportable and DPAPI-protected per user, which is the same
  custody as the Linux build.
- **Ad-hoc signed macOS dev builds with Secure Enclave keys.** Not possible: the
  Secure Enclave and keychain groups need a team-signed build with entitlements.
- **Electron or a separate desktop codebase.** Rejected: it would duplicate the
  transport, authority and localization already in the Flutter client.
- **A WebSocket or long-poll push channel for Windows.** Rejected: it would need
  a resident process and a new relay protocol, while WNS uses the existing
  push-key model.

## Consequences

- Desktop users get the same identity, push and link model as phone users.
  Marshall's device list can show which kind of device is registered.
- Custody on Windows varies by machine. The provider in use is not reported to
  Marshall, so a deployment cannot require a TPM-backed key.
- Release builds need Apple Developer ID, notarization, Android upload and
  Windows code-signing material in a protected CI environment.
- Native code for Windows (C++) adds a third implementation of the poke opener,
  which must stay byte-compatible with the shared vectors.

## Invariants and verification

- Every platform registers under its own wire name and provider (Dart unit test).
- A Windows DACL other than protected owner-plus-SYSTEM is refused (Dart unit and
  Hegel property tests, plus a Windows-only `icacls` round trip).
- Release plans never enable demo or software keys and keep secrets out of
  arguments (Hegel property over platform, host and inputs).
- The macOS and iOS poke openers pass the shared vectors (XCTest `RunnerTests`);
  the Windows opener passes the same vectors (CTest).
- A WNS token that is not a `notify.windows.com` channel is never sent to Susan.
- `device register --platform` accepts exactly ios, android, macos and windows
  (protocol and Marshall tests).

No NixOS machine test can host a macOS or Windows client. Native evidence comes
from XCTest, CTest, Dart tests and CI builds.

## Implementation evidence

- The Flutter evidence below was deleted with the Flutter client in `af4ad42e0`
  and is retained as history, not as current evidence: `platform.dart` and
  `push_registrar.dart` (profile and push selection), `owner_only_windows.dart`
  with `owner_only_test.dart` (Windows owner-only storage), `MilaPlatform.swift`,
  `MilaKeys.swift` and `PushPokeTests.swift` (macOS; the unsigned dev build ran
  locally on aarch64-darwin with 0700/0600 data files), and the Windows runner
  and portable poke opener under `mila/app`. Native replacements are tracked in
  [ADR-0249](0249-mila-rust-core-native-clients.md) and the
  [parity matrix](../../../mila/native/PARITY_MATRIX.md); on Apple, device keys
  are in [`MilaDeviceSigner.swift`](../../../mila/native/apple/Sources/MilaNativeUI/MilaDeviceSigner.swift)
  and push in [`MilaNotifications.swift`](../../../mila/native/apple/Sources/MilaNativeUI/MilaNotifications.swift).
- Build planner: the Dart planner was removed with the Flutter client. Apple
  targets now use [`mila-build`](../../../mila/native/mila-build) and
  [`build.sh`](../../../mila/native/apple/build.sh), which build the
  [`App`](../../../mila/native/apple/App/Package.swift) host around
  `MilaNativeUI`, refuse missing release signing inputs or a profile for another
  team or application identifier, and verify signatures and macOS notarization.
  `macos dev` and `ios dev` (simulator) were built and launched on aarch64-darwin
  ([review](../reviews/2026-10-29-mila-apple-host-app.md)). Linux targets:
  [`default.nix`](../../../nix/domains/artifacts/mila/default.nix).
- Platform enum: [`ssh_command.ex`](../../../protocol/lib/overalls_protocol/ssh_command.ex)
  and [`device.ex`](../../../marshall/lib/marshall/notifications/device.ex).
- CI: [`mila-builds.yml`](../../../.github/workflows/mila-builds.yml) and
  [`mila-release.yml`](../../../.github/workflows/mila-release.yml). Only a
  pushed `mila-v*` tag is a signed run: it alone enters the `mila-release`
  environment, refuses a missing signing input (Apple through `build.sh`,
  Android in the apksigner step) and publishes. Dispatches and trunk pushes
  touching the mobile build run the Android and Apple jobs unsigned, without
  the environment or any signing secret: the unsigned release APK and
  `mila-build <ios|macos> unsigned`, an ad-hoc signed release-configuration
  DMG and device IPA that reads no signing input. These are CI build checks
  beside decision 4's dev and release targets, not release plans, and are
  never published (`.github/CONTRACTS` mila-release-publish-tag-only and
  mila-release-signing-leak).
- Windows device-key custody (decision 3) in the native client:
  [`DeviceKey.cs`](../../../mila/windows-dotnet/Interop/DeviceKey.cs). "When it
  works" is applied as follows. NTE_DEVICE_NOT_READY from the Platform Crypto
  Provider is often transient (early boot, TBS starting, TPM provisioning), so it
  is retried with a bounded backoff of about 5 s before any fallback. A missing,
  undefined or unsupported platform provider falls back at once. Access denial and
  any other error propagate. An existing key is reopened from its own provider.
  The fallback is never silent: every key carries a recorded custody
  (`Platform`, `SoftwarePlatformUnavailable`, `SoftwarePlatformNotReady` or
  `SoftwareExisting`), and the SSH keys page marks this device's key as a
  software key. `MilaDeviceKeyPolicy.AllowSoftwareFallback` is the single switch
  that refuses software custody, should the "no refusal" choice be replaced.
  [`DeviceKeyCustodySmoke.cs`](../../../mila/windows-dotnet-smoke/DeviceKeyCustodySmoke.cs)
  covers retry-then-success, retry-then-fallback, immediate fallback, reuse of an
  existing software key, access denial and the strict switch against a scripted
  key store. The `windows-native` journey prints the custody it obtained. The
  Windows client has no diagnostic event catalogue, so no event is emitted.

Remaining gaps:

- No signed macOS build has run, so the Secure Enclave and APNs paths on macOS
  are unverified.
- The native Swift client does not implement decision 2's `MILA_SOFTWARE_KEYS`
  dev custody: `MilaDeviceSigner` refuses software fallback, so an ad-hoc dev
  build cannot sign in. Either implement the owner-only software keys for
  unsigned macOS dev builds or replace that part of the decision.
- The Apple release path has not run with real signing material, and no
  notification service extension is built, so APNs pokes to a closed app are
  not delivered by the native client.
- The Windows runner has not been compiled or run on Windows, and no TPM or
  software-provider key has been exercised.
- The release workflows have not run with real signing material: the
  `mila-release` environment and its Apple and Android signing secrets are
  not yet provisioned, so the signed paths, including the Android apksigner
  step, are untested. The apksigner path is hard-coded to Android
  build-tools 36.0.0 and has never run. The unsigned Android and Apple builds
  are not yet recorded as passing in CI.

## Open questions

- Whether Marshall should record and display the custody kind (hardware or
  software) of a desktop device key. The Windows client now records it and
  shows it locally. Reporting it needs a key attribute in Marshall, a
  Porsche command or sign-in field the client sends, and the Rust grammar and
  FFI to carry it. That is a protocol and persistence change for a new ADR.

## Related decisions

Extends [ADR-0220](0220-mila-client-over-porsche-ssh.md) and
[ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md); depends on
[ADR-0236](0236-susan-wns-provider.md) for Windows push;
[ADR-0225](0225-marshall-notifications-domain.md) (device platforms);
review [2026-10-21-mila-desktop](../reviews/2026-10-21-mila-desktop.md).
