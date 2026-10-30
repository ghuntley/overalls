# ADR-0249: Mila Rust core with native platform clients

- ID: ADR-0249
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: Mila
- Supersedes: none
- Superseded by: none

## Context

Mila's shipped client is Flutter and currently contains transport, protocol,
cryptographic and state-transition code beside its widgets. The product must
ship native clients on Apple (iOS and macOS), Android, Linux and Windows while
keeping behavior consistent and auditable. Windows is supported on the latest
.NET SDK only.

## Decision

1. Shared protocol, cryptography, transport orchestration, state transitions,
   persistence contracts and test models live in typed Rust crates under
   `mila/rust`. Crates are split by dependency and compile-time boundary.
2. Platform applications are thin UI and OS integration layers: SwiftUI for
   iOS/macOS, Jetpack Compose for Android, GTK4/libadwaita for Linux, and WinUI
   3 targeting the latest .NET SDK for Windows. They call the Rust core through
   typed, versioned FFI adapters and do not reimplement authorization or
   protocol rules.
3. Device key custody, push registration, secure storage, terminal surfaces,
   deep links and platform lifecycle remain OS-specific adapters behind core
   traits. Secrets and raw transport bytes never cross a UI boundary.
4. Rust behavior is verified with Hegel property tests and shared fixtures;
   native integration tests verify adapter and lifecycle invariants. Flutter is
   retained until native parity evidence is recorded, then removed.

Authorization: the approved native rewrite request (2026-10-20).

## Alternatives

- **Keep Flutter and add platform plugins.** Rejected: core behavior would
  remain coupled to one UI runtime and native lifecycle guarantees would be
  incomplete.
- **Duplicate domain logic in each native client.** Rejected: divergence would
  undermine protocol and authorization invariants.

## Consequences

Rust compilation and FFI versioning become release dependencies, but protocol
behavior is shared and property-tested. Native build toolchains are required
for release evidence. Platform accessibility, lifecycle and secure-storage
behavior must be tested per OS.

## Invariants and verification

- All externally reachable routes and mutations pass through the Rust core;
  malformed input is rejected and mutations are at-most-once.
- FFI surfaces use typed handles and bounded buffers; no UI receives private
  keys or unvalidated terminal data.
- Hegel properties and shared fixtures run in the Rust workspace; native CI
  builds each target and exercises adapter smoke tests.

## Implementation evidence

The initial workspace and adapters are in [`mila/rust/Cargo.toml`](../../../mila/rust/Cargo.toml),
[`mila/native/apple`](../../../mila/native/apple),
[`mila/native/android`](../../../mila/native/android),
[`mila/native/linux`](../../../mila/native/linux) and
[`mila/windows-dotnet`](../../../mila/windows-dotnet). The Rust workspace,
Hegel fixtures and Nix checks pass on Linux. Transport, secure-storage,
feature-complete screens, native-host builds and Flutter removal remain open.

[`mila-session`](../../../mila/rust/mila-session/src/lib.rs) composes the pure
runtime with the certificate-pinned SSH transport for validated machine reads.
It owns first-page refresh, bounded continuation, atomic failure preservation and
complete-only offline projections. Its separate crate keeps network dependencies
out of the pure runtime. Local TCP SSH tests in
[`session.rs`](../../../mila/rust/mila-session/tests/session.rs) exercise actual
certificate negotiation and channels with scripted server results; Hegel tests in
[`properties.rs`](../../../mila/rust/mila-session/tests/properties.rs) check decoder
identity and permission handling. Browser approval, native signer/FFI orchestration,
watch, mutations and real Porsche integration remain open for this layer; see the
[session review](../reviews/2026-10-21-mila-native-session.md).

The terminal attachment reducer is ported from Dart in
[`terminal.rs`](../../../mila/rust/mila-runtime/src/terminal.rs), with private
state, current-generation headers, replay reset accounting, closed outcomes,
retry exhaustion and server/user permission gates. Hegel action sequences in
[`terminal.rs`](../../../mila/rust/mila-runtime/tests/terminal.rs) exercise the
pure reducer; native PTY transport and renderer integration remain unverified.

The [release readiness review](../reviews/2026-10-24-mila-native-release-readiness.md)
records that Linux/Android release outputs and source-bundle consumers still
depend on Flutter. Shared catalogs now live outside the Flutter tree, but this
does not establish gettext conversion or native release acceptance. The native
release replacement is authorized implementation work under this decision;
platform journeys and release artifacts still require execution evidence.

The Android client binds machine creation and sharing to the authenticated
Rust session through dedicated JNI entry points
([`mila-ffi`](../../../mila/rust/mila-ffi/src/lib.rs) `nativeSessionMachineCreate`
and `nativeSessionShareMutation`); previously creation only echoed through the
ABI probe and sharing reached the lifecycle seam, which Rust refused.
[`MilaMachineFormController`](../../../mila/native/android/app/src/main/java/dev/overalls/mila/nativeui/MilaMachineCreate.kt)
fences create/resize to the signed-in session generation, and
[`MilaDeepLinks.kt`](../../../mila/native/android/app/src/main/java/dev/overalls/mila/nativeui/MilaDeepLinks.kt)
completes VIEW/share-provider targets only for an authenticated session. JVM
tests cover these controllers; emulator instrumentation covers the packaged JNI
exports and BiometricPrompt unavailable/enrolled states. The
[`MilaJourneyTest`](../../../mila/native/android/app/src/androidTest/java/dev/overalls/mila/nativeui/MilaJourneyTest.kt)
suite against the hermetic Marshall+Porsche fixture is wired into CI but has no
recorded passing execution until the fixture lands; FCM delivery is not
hermetic and remains outside it.

The Windows adapter's lifecycle layer keeps protocol authority in Rust:
[`SignInCoordinator.cs`](../../../mila/windows-dotnet/Interop/SignInCoordinator.cs)
polls `mila_session_whoami` and reconnects through the Rust session;
[`TerminalStream.cs`](../../../mila/windows-dotnet/Interop/TerminalStream.cs)
reattaches only on transport loss reported by `mila_session_terminal_read`;
[`WindowsPushRegistration.cs`](../../../mila/windows-dotnet/Interop/WindowsPushRegistration.cs)
sends the Rust-encoded Susan request and registers the push key with Porsche through
`mila_session_device_register` (push key on stdin). The Rust grammar now accepts
Porsche's `device` and `ssh-key list` commands, checked against the shared
[`porsche_device_results.json`](../../../protocol/test/fixtures/porsche_device_results.json)
fixture, and the Rust WNS channel check matches Susan's. The
[lifecycle smoke](../../../mila/windows-dotnet-smoke/LifecycleSmoke.cs) runs these
adapters against scripted peers in the `windows-native` CI job; its
[journey mode](../../../mila/windows-dotnet-smoke/JourneySmoke.cs) needs the hermetic
Marshall+Porsche fixture and is gated by the `MILA_WINDOWS_JOURNEY` repository
variable. Windows X25519 poke-key custody, WNS delivery and live journey execution
remain open.

The Linux GTK client keeps its decisions in GTK-independent library modules:
the bounded [deployment list](../../../mila/native/linux/src/deployments.rs),
the [terminal surface](../../../mila/native/linux/src/terminal_surface.rs) over
`AuthenticatedPty`/`HostPtyTransport` with host-side
[PTY text decoding](../../../mila/native/linux/src/terminal_text.rs), the
[SSH-key view](../../../mila/native/linux/src/ssh_keys_view.rs) and
navigation-only [deep-link presentation](../../../mila/native/linux/src/deep_link.rs).
The terminal reads through the additive bounded-wait
`mila_session_terminal_read_within` FFI entry, which reports the same
`TerminalReadEvent` codes as `mila_session_terminal_read` without waiting for
the session timeout; [transport](../../../mila/rust/mila-transport/tests/ssh.rs) and
[FFI](../../../mila/rust/mila-ffi/tests/session.rs) tests cover it. A GTK
widget test in [`main.rs`](../../../mila/native/linux/src/main.rs) runs on a
headless Broadway display in CI, and
[`mila-linux-journey`](../../../mila/native/linux/src/journey.rs) drives the
same modules against the hermetic fixture descriptor. The GTK Sign in button
runs the [sign-in driver](../../../mila/native/linux/src/signin_driver.rs), which
connects with the owner-only [device key](../../../mila/native/linux/src/device_key.rs),
polls `whoami`, opens approval once per generation, heartbeats the bound session
and reconnects after a loss. The window binds only the session the driver
establishes. The headless journey signs in through the same driver, and the
`gtk-journey` build drives the real window
([`gtk_journey.rs`](../../../mila/native/linux/src/gtk_journey.rs)). Neither
journey has a recorded fixture run; see the
[Linux parity review](../reviews/2026-10-30-mila-linux-gtk-parity.md).

## Open questions

None blocking the direction; platform key-storage and release-signing details
remain implementation work under ADR-0235.

## Related decisions

[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0222](0222-porsche-client-commands.md),
[ADR-0225](0225-marshall-notifications-domain.md),
[ADR-0235](0235-mila-desktop-clients.md).

The native Apple [device signer](../../../mila/native/apple/Sources/MilaNativeUI/MilaDeviceSigner.swift)
ports deployment-scoped Secure Enclave custody without a software fallback.
[Swift tests](../../../mila/native/apple/Tests/MilaNativeUITests/MilaDeviceSignerTests.swift)
cover hostname boundaries and signature conversion; signed-device execution,
callback integration and release entitlement verification remain open.
