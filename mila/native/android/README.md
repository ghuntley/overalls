# Mila Android native client

This is the production Jetpack Compose client over the shared Rust core. The
adapter exposes a narrow, typed JNI seam for `mila-ffi`; packaging supplies the
ABI-compatible native library, and tests may inject `MilaRustBindings`.

The project metadata targets Android API 36, uses Java 17, Android Gradle Plugin 9.1.0, and Kotlin
2.4.0 with the Kotlin Compose compiler plugin. The Compose dependency BOM is pinned in
`app/build.gradle.kts`; update it together with the native dependency lock.

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
tools/buck2 build -c overalls.non_hermetic=true //mila:android-debug
```

CI builds the APKs through Buck2 (ADR-0269):
`tools/buck2 build -c overalls.non_hermetic=true //mila:android-debug` (and `:android-release`,
`:android-ffi-clippy`) runs the same Gradle tasks with the SDK, JDK, Gradle and cargo-ndk on the
Buck2 daemon's `PATH`; see the buck2 skill. The targets build on Linux or macOS; CI builds them
on a Namespace macOS runner. The repository's Linux checks do not install a native Android SDK. If Gradle or the SDK is unavailable, inspect the Kotlin and Gradle metadata and run the
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
on an uncached Namespace macOS runner with pinned JDK 17, Gradle 9.3.1, Android API 36/NDK 28.2.13676358, and locked
Rust dependencies (`cargo-ndk ... build --locked`). It publishes
`app-release-unsigned.apk` and a SHA-256 manifest as the native release
candidate. Signing remains a distribution concern while the native parity
matrix is open; the artifact is installable for QA and provides repeatable
build evidence.

## Instrumentation and the hermetic journey

To test an already booted disposable emulator locally, set its exact serial and a fresh run
identity for every invocation:

```sh
tools/buck2 test -c overalls.non_hermetic=true \
  -c mila.android_serial=emulator-5580 \
  -c mila.android_test_run=local-20261105-1 //mila:android-device-test
```

The target builds the APKs through `:android-debug`, requires `ro.kernel.qemu=1`, uninstalls both
test packages, and runs the packaged instrumentation suite with the fixture journey excluded.
The app-lock tests change and restore the emulator's PIN; physical devices are refused. The
bounded JSON report records the serial, API, run identity, both APK SHA-256 digests, test counts
and sanitized failing test identities. It includes no raw test streams or device logs. Build
`'//mila:android-device-test[out]'` with the same configuration to retrieve that report. A new
`mila.android_test_run` value is required for fresh execution rather than a previous local result.
The SDK must be in the Buck2 daemon's environment; `adb` resolves from `ANDROID_HOME/platform-tools`
or its `PATH`. This target never starts or stops an emulator.

For the authenticated journey, boot the declared fixture through
`tools/buck2 run //mila:journey-fixture` and keep its descriptor and launcher
output private. Then use a separate fresh run identity:

```sh
tools/buck2 build -c overalls.non_hermetic=true \
  -c mila.android_serial=emulator-5580 \
  -c mila.android_test_run=local-journey-1 \
  -c mila.android_journey_descriptor=/private/fixture/descriptor.json \
  '//mila:android-journey-device-test[out]'
```

This target requires the bounded owner-only descriptor, reverses its loopback
ports without replacing conflicting mappings, and invokes the ordered journey
once. All 14 tests must pass with no skips. It removes only the reverse mappings
it created and emits the same bounded report without descriptor contents or
device logs. It never retries the mutating suite after failure or timeout.
Local API 35 execution passes all 12 packaged tests and all 14 journey tests;
see the [implementation review](../../../docs/architecture/reviews/2026-11-02-mila-native-parity-implementation.md).

The instrumentation suite runs on the API 35 emulator in the Linux `android-emulator` CI job
through [`scripts/run-instrumentation.sh`](scripts/run-instrumentation.sh), which installs the
`app-debug.apk` and `app-debug-androidTest.apk` that the macOS `android-native` job built
(`MILA_ANDROID_APK_DIR`) and runs them with `am instrument`. The emulator and the journey fixture
need KVM, which a macOS runner lacks. Besides packaged JNI smoke tests,
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
web, SSH keys and notification-device CRUD, signed-out share completion, and a seed-machine
`overalls://` link launched through the platform resolver (`am start` with no component) into the
real `MainActivity` window, with non-canonical links refused. The fixture's
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

CI substitutes the fixture from the `overalls` Cachix cache, with a local
`//:package-mila-journey-fixture` Buck2 build as fallback, boots it after the APK is assembled, then `adb reverse`s its unprivileged ports so the emulator
dials `deployment.host` exactly as written. `localhost` deployments are accepted only while an
instrumentation test sets `MilaInstrumentationLoopback.allowed`; production input still requires a
dotted DNS name. FCM delivery and server-side device registration need a real push token and are
not part of the hermetic journey.
