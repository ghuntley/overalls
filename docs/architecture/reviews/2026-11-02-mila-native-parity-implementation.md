# Mila native parity implementation (2026-11-02)

## Scope

This review reconciles the Mila native client audit with the implementation
changes made for ADR-0220, ADR-0222, ADR-0223, ADR-0235, ADR-0249, ADR-0264,
ADR-0277 and ADR-0278. It covers the shared Rust protocol/session/FFI layer,
Apple, Android, Linux and Windows presentation adapters. It does not claim
physical-device, signing, or live APNs/FCM/WNS delivery evidence.

## Changes and evidence

- The shared grammar, session API, C ABI and fixtures now support typed machine
  cloning and typed thread `mode`/`read` operations. Notification registration,
  preferences and removal expose additive caller-owned request-id entry points;
  legacy wrappers retain one pending identity until a definite success. Rust
  protocol/session/FFI tests and clippy pass. Clone names are validated
  consistently at the Apple, Android and Windows managed boundaries before
  crossing the native ABI.
- Apple notification settings use authenticated server device list/preferences/
  remove operations with generation fencing; host-bound deep links and
  host-qualified web routes are validated; the terminal UI uses bounded event
  reads. Android notification settings use authenticated server device CRUD,
  persisted appearance/RTL settings, and the terminal JNI bridge consumes the
  bounded read event API.
- Linux notification enablement is persisted atomically under owner-only XDG
  state and device rows are decoded into the GTK settings surface. Windows
  machine, sharing and web controls use live session paths, create fields are
  bounded, terminal detach/session fields are present, and the lock overlay is
  outside the disabled interaction tree with action guards.
- All four native clients now persist complete, host/port-bound offline snapshots
  with generation fencing, newest-wins atomic replacement and read-only cached
  rows. Their live watch workers deduplicate and shard bounded machine/thread
  filters, retry transient capability contention, reconnect only subscriptions,
  and fence authority loss; Linux additionally polls child shards fairly.
- Bounded terminal reads now accept any caller capacity from one byte through
  the 1 MiB transport maximum. Oversized SSH frames retain their unread
  remainder for the next read, so Android's normal 64 KiB UI reads do not fail
  while the Rust screen projection remains generation- and authority-fenced.
- Native create and resize forms now enforce the shared VM shape limits before
  FFI dispatch (CPU 1..256, memory 256..4,194,304 MiB, disk 1..500 GiB), with
  boundary tests on Android, Apple, Linux and Windows.
- macOS ad-hoc development builds now compile the explicit `MILA_SOFTWARE_KEYS`
  policy: `MilaDeviceSigner` stores deployment-scoped owner-only software keys,
  while the same policy blocks APNs registration. Profile-backed macOS builds,
  release configuration, and iOS never compile the fallback; native macOS
  execution remains unverified in this Linux environment.
- The custody follow-up preserves existing Secure Enclave application tags and
  stores development keys separately under Application Support. Digest-bound
  filenames admit the maximum canonical host length. Descriptor-pinned reads
  refuse unsafe permissions, symlinks, hard links, non-regular files and malformed
  keys; atomic publication never replaces a concurrent creator's identity.
  [`MilaSoftwareDeviceKeyTests.swift`](../../../mila/native/apple/Tests/MilaNativeUITests/MilaSoftwareDeviceKeyTests.swift)
  covers persistence, signing, host separation, malformed storage, permissions,
  links, FIFOs and concurrent creation. These tests are present but unexecuted
  here. The separate `//mila:apple-software-keys-test` CI target requires the
  software-key suite and direct APNs-refusal test to execute, and requires the
  compiler's policy diagnostic when the define is used without DEBUG. A signed
  macOS development build now requires its provisioning profile before compiling.
- Android thread overloads now dispatch through the authenticated Rust session;
  the generic adapter no longer echoes arbitrary operation payloads as success.
  Refresh, initial sign-in and approval completion require a successful current
  Rust read before returning a machine listing. Regression tests cover refused
  reads and dispatch through all overloads; Android SDK results are recorded below.
- The terminal follow-up masks RGB components before Apple byte conversion,
  validates typed Android JSON scalars, and rejects null Windows image entries.
  All native frame decoders enforce a 16 MiB frame bound and a combined
  1,048,576-pixel image budget. Apple image layers scroll with their text;
  Android uses physical pixel offsets and sizes with reachable image extents.
  Apple fixes terminal coordinates to left-to-right without changing localized
  controls. Apple and Android terminal controllers now clear old frames on fresh
  attachment and fence delayed attach/read/resize completions against session
  changes; deterministic delayed-operation regressions accompany those guards.
  The added Apple tests require macOS CI; Android results are recorded below.
- `cargo test --locked -p mila-protocol -p mila-session -p mila-ffi
  -p mila-native-linux`, `cargo clippy --locked -p mila-protocol
  -p mila-session -p mila-ffi -p mila-native-linux --all-targets -- -D warnings`,
  `cargo check --locked -p mila-native-linux`, `cargo fmt --all -- --check`
  (after formatting), and `git diff --check` pass in the implementation clone.

## Follow-up verification (2026-11-05)

Shell syntax, whitespace, code-contract format and ADR structural checks pass.
These structural results do not establish native compilation or runtime custody.
`//:check-mila-rust` and `tools/docs --check` pass in the isolated implementation
clone. The earlier shared-checkout Rust attempt was blocked by a concurrent
Marshall change; the isolated clone preserves the original Marshall sources.
`tools/precommit --all --exclude-label expensive` passes 78 of 79 checks; its
only failure is the unrelated existing Marshall `priv/gettext/terminal.pot`
freshness check. That file was not changed by this Mila implementation.

Installed Android and .NET SDKs were subsequently found outside PATH. Through
`//mila:android-debug`, the debug app, instrumentation APK and all three packaged
JNI ABIs built successfully; the final run passed all 221 JVM tests with no
failures or skips, including pagination, cancellation and session-replacement
regressions.
`//mila:android-ffi-clippy` also passed. These results establish compilation and
JVM behavior, separately from emulator instrumentation or physical-device custody.

`//mila:android-device-test` subsequently passed all 12 packaged instrumentation
tests on the disposable API 35 emulator, with zero failures or skips. This runs
the packaged JNI, route and app-lock tests; it explicitly excludes the fixture
journey. The final run (`mila-final-20261105-2`) binds its report to the APK
digests, API level and explicit emulator serial. Selection refuses physical or
unbooted devices before installation, commands and captured output are bounded,
and reports contain closed outcomes/counts without raw device or terminal logs.
The runner's unit, Ruff and type checks pass through Buck2. The JNI refusal
assertions now use JUnit, so disabled JVM language assertions cannot hide failure.

The new `//mila:linux-managed-smoke` passed against the production Linux Rust
package, using locked NuGet restore and the actual FFI library. This exposed and
fixed two defects: the Rust package copied the host build-script directory rather
than the platform release directory, omitting `libmila_ffi.so`, and the terminal
frame smoke class had the wrong namespace. The package now asserts the native
library exists before installing it. Windows CNG, DPAPI, package activation and
WinUI checks retain their Windows-only execution boundaries.
The final managed run also passes bounded machine pagination, failed-read
refusal, watch-filter coverage and delayed thread-operation regressions. Windows
thread completions are fenced against sign-out, session replacement and selection
changes before a queued worker enters the session.

`mila-builds.yml` now requires that portable managed check as an independent
Linux job. Its SDK follows the Windows project's `global.json`. Both workflow
files parse, their remote action references are full verified commit SHAs, and
the actual native-gate matrix/removal check executes successfully. The Gradle
action's truncated reference and the Flutter-removal check's self-match were
corrected. These checks validate workflow source; no CI run was launched here.
The Mila Rust and native Linux package targets omit unrelated swapped fleet
artifacts; `//buck:tool_outputs_leaf_free` passes for the initial seven tool outputs,
confirming they are independent of the 33 supplied artifacts.

The Linux follow-up adds declared `//mila:linux-journey` and
`//mila:linux-gtk-journey` entry points over a separate opt-in journey package,
with a pinned Broadway server. The normal package and release archive retain
only `bin/mila` and compile with the fixture feature disabled. Installation
selects the target platform's release executable explicitly. The final graph
test passes for all eight tool outputs against the 33 supplied artifacts.
The `linux-native` workflow now builds and runs these Buck2 targets, including
the Rust gate and mandatory widget tests, without direct Cargo build steps.
Its fixture startup diagnostics no longer print the token-bearing launcher log.

The lifecycle and pagination follow-up also fixes these concrete defects:

- Apple push enablement captures the approved deployment and request generation;
  reset cancels relay callbacks, and old token, failure or registration completions
  cannot register a newer deployment or overwrite its result. Bounded delayed
  callback tests are present; Swift execution remains pending macOS.
- Android watch acquisition and reconnect record handle ownership across the
  dispatcher handoff before cancellation resumes. Bounded regressions cancel
  blocked open/reconnect calls and require the successful handle to close once.
- Android, Linux and Windows refreshes now traverse bounded authenticated machine
  continuations and refuse failed pages before publishing a complete listing or
  snapshot. Apple retains its explicit Load more control. All clients preserve
  the shared 500-machine window, with machine watch filters covering that window
  and independent 256-thread limits. Linux offline reload no longer truncates
  valid complete snapshots to 256 rows.
- Apple snapshots use digest-bound host/port filenames, admitting valid 253-byte
  management hosts without exceeding filesystem component limits. Cached data
  remains Rust-validated, deployment-bound and read-only; disposable older cache
  filenames refill on authenticated refresh.
- Apple watch refresh callbacks retain their approved generation across machine
  and thread reads. A deployment switch during either suspended read cannot
  start work against the replacement adapter or send an old thread identity to
  it. Three bounded app-model regressions cover both races and the normal
  same-session refresh; their execution remains pending macOS CI.
- Windows terminal operations reserve their generation before a blocking open
  or attach and retain their original parent session and handle during reads.
  A late attach, terminal frame or transport failure cannot replace or close a
  newer attachment. EOF handles close explicitly, and an in-flight read owns
  retirement when closing its handle would return Busy. Portable regressions
  cover replacement, sign-out, kill, stale loss, revocation and bounded reads.
  The initial 17 deterministic race cases use scripted transport within
  `//mila:linux-managed-smoke`, which also links the production FFI. The WinUI
  caller retains the full 500-machine watch
  window; its source change still requires Windows compilation.
- Windows now validates the existing native terminal-state projection before
  accepting an attached handle or interpreting a closed read. Explicit refusal,
  authority loss and temporary transport failure have separate effects; generic
  argument errors cannot authorize a replacement `terminal new`. The UI starts
  bounded polling after an initial retryable attach, and the native read-only
  grant limits managed input. Portable smoke covers these outcomes and delayed
  state completions. A separate, fixed-capacity, one-call read helper also fixes
  frame (16 MiB), listing (8 MiB) and snapshot (1 MiB) projections previously
  rejected by the mutation helper's 256 KiB cap. Mutation sizing remains
  one-call and unchanged. The final portable smoke and scoped checks pass;
  C# contracts were reviewed manually because the extractor does not support C#.

The final Windows GNU FFI cross-build, ABI, Clippy and independent reproducibility
gates pass on Linux (`857527d0-1348-458a-8f03-3bbdc48a0af8`). All 63 `mila_*`
exports agree with the header, all named C# imports exist, and the independently
built DLLs are byte-identical (SHA-256
`83783a3d47ba0149f8eaf57e783be409da4cf5244f53c521a834b5e48ec6a317`).
This checks Windows-target compilation and symbol agreement; native Windows
marshalling, WinUI, custody and signed packaging remain unexecuted here.

The explicit Android fixture target subsequently passes all 14 ordered journey
tests with no failures or skips on API 35 (`mila-journey-20261105-2`). Descriptor
bytes remain outside Buck2 inputs and reports. The runner validates an owner-only
bounded descriptor, preserves existing reverse mappings and removes only its own,
then invokes the mutating suite once. The first setup attempt never reached
instrumentation: an empty `adb reverse --list` response includes a newline.
That framing bug is fixed with regression coverage; all 13 runner tests, Ruff
and type checks pass.

`//mila:linux-journey` also passes all 40 steps against the source-built hermetic
fixture: lifecycle, sharing, web policy, threads, notification-device CRUD,
terminal echo/resize/replay/kill and SSH-key revocation. Its terminal is the
fixture's real-PTY stand-in; this does not establish execution in a provisioned
guest VM.

The GTK follow-up repairs two contention paths exposed by the real window
journey. Web policy controls remain disabled until an authenticated web read
loads the endpoint; only Busy reads retry, with a five-second deadline and
approved generation, opaque session, machine and refresh-epoch fencing. A
policy mutation is still submitted once. The deployment-switch journey check
also waits for Busy listing reads within its existing deadline, rather than
misreporting a temporarily locked session as a missing seed machine. Deterministic
GTK-thread regressions cover delayed success, exhaustion, cancellation and
definitive refusal.
The GTK fixture helper also isolates `XDG_CACHE_HOME` beneath its owner-only
work directory, alongside config and data, so snapshot reads and writes cannot
touch the operator's Mila cache.
The corrected real-window journey passes all 39 steps against a fresh fixture,
including the public/private web mutations and deployment switch back. It runs
the opt-in Buck2-built journey package with pinned Broadway. This establishes
the fixture workflow, separately from native image rendering or provisioned
guest execution.
The canonical `//mila:linux-gtk-journey` wiring smoke also passes against the
exact final package: an unreachable deployment yields the expected two picker
successes followed by `host_untrusted`, with exit status 1.

`//:package-tool-mila-linux-native` executes 150 library and six binary test
cases for each of the default and `gtk-journey` feature sets, formatting, and
Clippy with warnings denied for both feature sets. The package now starts its
own bounded-readiness Broadway display and requires the GTK widget test to
execute; an unavailable display fails verification. Cleanup uses the stdenv
exit/failure hooks. This includes complete pagination,
failed continuation, 500-row projection/restart and watch sharding regressions.
The widget test does not establish an authenticated fixture journey. Final `//:check-mila-rust`,
`//:adrs`, `//:contracts`, `//:pins`, `tools/docs --check`, and whitespace checks
also pass. The repeated full precommit result remains 78/79 with only the same
unrelated Marshall terminal catalog freshness failure.

## Findings and remaining gaps

1. **High — native host acceptance remains open.** The Rust core and Linux native
   checks, Android packaged/fixture emulator tests and both Linux fixture
   journeys pass. Apple simulator app-lock/link journeys,
   Windows UI Automation/custody tests, and signed Apple/Android builds require
   their native CI environments and are not established by this Linux review.
2. **High — release/provider evidence remains open.** Windows now has AppInstance
   activation, protocol activation, an audited unsigned ZIP/MSIX packaging target,
   and CI artifact upload. The package is unsigned here; real Windows packaging,
   signing, install/activation, and physical Apple/Android device evidence remain
   CI/release work. APNs/FCM/WNS provider delivery remains host/provider evidence.
3. **Medium — terminal image acceptance remains scoped.** Rust decodes bounded ANSI,
   cursor movement, SGR, and SIXEL raster records into typed display frames. Apple,
   Android, Linux and Windows now render bounded RGB image layers from that frame;
   native CI and physical-terminal image journey receipts are still required before
   claiming production image compatibility.

ADR-0235 and ADR-0249 remain `partial` because accepted native-CI, signing,
physical-device, provider-delivery and production journey evidence is separate
from the implementation and unit/integration checks recorded here.

## Architecture impact

The changes preserve the accepted Porsche-only authority and thin-native-client
boundary. The additive clone, notification request-id and bounded terminal JNI
interfaces extend existing typed FFI contracts; they do not add an HTTP API or
move authorization into a platform shell. Reconnecting watches, snapshot stores,
terminal image layers and Windows packaging add lifecycle, persistence, rendering
and transport boundaries while keeping authorization in Rust. The follow-up
preserves these decisions: pagination uses Rust-owned continuations, lifecycle
callbacks retain their original authority, and the new Linux managed check adds
validation scope without substituting for Windows OS evidence. Watch and
terminal race fixes restore the accepted session ownership; the mandatory GTK
display extends verification without changing runtime or dependency boundaries.
The narrowed
package graph preserves ADR-0269's artifact-substitution boundary, with an
executed independence check rather than an assumed dependency exclusion.
