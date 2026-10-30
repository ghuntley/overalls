# Mila Android native UI scaffold

This is an isolated Jetpack Compose application for the native Mila presentation seam. It is the production Android client. The adapter exposes a narrow, typed JNI seam for the
Rust `mila-ffi` library; host packaging supplies the ABI-compatible native library and may inject a
test binding implementing `MilaRustBindings`.

The project metadata targets Android API 36, uses Java 17, Android Gradle Plugin 9.1.0, and Kotlin
2.4.0 with the Kotlin Compose compiler plugin. The Compose dependency BOM is pinned in
`app/build.gradle.kts`; update it together with the rest of the native dependency lock when the
host build adopts this scaffold.

`MilaFfiPayload` owns a defensive copy of every byte array. The default linked adapter loads `mila_ffi` lazily and reports unavailable when the host has not
packaged it. Use `LinkedMilaFfiAdapter` in production packaging; keep the unavailable adapter only for tests. Keep
credentials, key material, authentication tokens, and terminal bytes out of this adapter's logs and
UI state.

The `preBuild` task also runs the shared catalog generator against
`mila/localization/catalogs` and packages the deterministic 30-locale JSON bundles as
APK assets. Native message identities use English only as a safe fallback when
a translated resource is unavailable.

## Static validation

On a machine with Android SDK API 36, JDK 17, and Gradle 9:

```sh
gradle --project-dir mila/native/android :app:assembleDebug
```

CI builds the APKs through Buck2 (ADR-0269):
`tools/buck2 build -c overalls.non_hermetic=true //mila:android-debug` (and `:android-release`,
`:android-ffi-clippy`) runs the same Gradle tasks with the SDK, JDK, Gradle and cargo-ndk on the
Buck2 daemon's `PATH`; see the buck2 skill. The repository's Linux checks do not install a native
Android SDK. If Gradle or the SDK is unavailable, inspect the Kotlin and Gradle metadata and run the
contract syntax check from the repository root.

Gradle verifies every downloaded artifact against the SHA-256 checksums in
`gradle/verification-metadata.xml`. After changing a plugin or dependency version, regenerate it
with `gradle --write-verification-metadata sha256 help assembleDebug assembleDebugAndroidTest
testDebugUnitTest assembleRelease` and review the diff. The `aapt2` `-osx` and `-windows` entries
were added by hand from Google Maven; refresh them with each AGP bump. Robolectric's
`android-all-instrumented` runtime jar is downloaded by Robolectric itself at test time, outside
Gradle, so this file does not cover it.

## Release evidence

The `android` job in `.github/workflows/mila-release.yml` assembles this project
with pinned JDK 17, Gradle 9.3.1, Android API 36/NDK 28.2.13676358, and locked
Rust dependencies (`cargo-ndk ... build --locked`). It publishes
`app-release-unsigned.apk` and a SHA-256 manifest as the native release
candidate. Signing remains a distribution concern while the native parity
matrix is open; the artifact is installable for QA and provides repeatable
build evidence.

## Instrumentation and the hermetic journey

`connectedDebugAndroidTest` runs on the API 35 emulator in the `android-native` CI job through
[`scripts/run-instrumentation.sh`](scripts/run-instrumentation.sh). Besides packaged JNI smoke tests,
`MilaAppLockDeviceTest` toggles the emulator's device credential with `locksettings` to exercise
the real `BiometricManager`/`BiometricPrompt` unavailable and enrolled states; it always restores a
credential-free device.

`MilaJourneyTest` drives the production controllers over the packaged Rust session against the
`mila-journey-fixture` Marshall+Porsche backend: sign-in with browser approval and reconnect,
machine listing, session-bound create/resize, lifecycle admission (including the closed `vm_busy`
resize refusal while a pause is unobserved), sharing, thread prompt/answer/plan approval, the
terminal's closed `terminal_unavailable` refusal on a never-observed machine, live terminal I/O on
the fixture's guest-backed `seed.terminal_machine_id` (named `terminal new`, attach, echo, resize to
132x40 with `stty size`, detach and reattach with replay, then `terminal kill` reporting `closed`),
web, SSH keys and notification-device CRUD. The fixture's
Bearer-protected `POST <approver.fixture_url><action>` hooks (`observe`, `thread-create`,
`thread-ready`, `thread-question`, `thread-proposal`) stand in for the absent provisioner and agent
and are required. It is skipped unless the `milaJourneyDescriptor` instrumentation
argument carries the base64 fixture descriptor (version 1):

```json
{
  "version": 1,
  "deployment": { "host": "localhost", "ssh_port": 2222, "https_port": 8443 },
  "tls": { "ca_pem": "-----BEGIN CERTIFICATE-----…", "server_name": "localhost" },
  "approver": { "url": "https://localhost:8444/approve", "fixture_url": "https://localhost:8444/fixture/", "bearer_token": "…" },
  "seed": { "machine_name": "…", "machine_id": "…", "terminal_machine_id": "…", "terminal_machine_name": "…", "share_principal": "…", "account_email": "…" }
}
```

CI substitutes the fixture from the `overalls` Cachix cache and builds it only when the flake exposes
`packages.<system>.mila-journey-fixture`, boots it after the APK is assembled, then `adb reverse`s its unprivileged ports so the emulator
dials `deployment.host` exactly as written. `localhost` deployments are accepted only while an
instrumentation test sets `MilaInstrumentationLoopback.allowed`; production input still requires a
dotted DNS name. FCM delivery and server-side device registration need a real push token and are
not part of the hermetic journey.
