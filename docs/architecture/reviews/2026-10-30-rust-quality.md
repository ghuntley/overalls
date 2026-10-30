# Rust code quality: module layout, lint policy and Hegel properties (2026-10-30)

Scope: every non-vendored Rust crate in the repository, under
[ADR-0265](../decisions/0265-rust-code-quality.md). That is the twelve Lilly
helpers and hostd, the diagnostics spool, the guest editor broker, the guest
telemetry receiver, observability-runtimes, Enrico git-owner, terminald, Lyra,
the ten Mila workspace members and the Mila Linux client. The review covers the
policy, the drift guard, the `lib.rs` splits, the Hegel migration and gap
properties, and the gates that make the lints fatal.

## Changes

- **Policy and drift guard.** [`scripts/rust/lints.toml`](../../../scripts/rust/lints.toml)
  and [`scripts/rust/clippy.toml`](../../../scripts/rust/clippy.toml) are the
  single source.
  - [`scripts/check_rust_lints.exs`](../../../scripts/check_rust_lints.exs) runs
    as the `rust-lints` prek hook and Nix check, and now runs with `--strict`:
    a crate without the canonical block fails.
  - Each `.rs` file is judged by its nearest enclosing manifest, so a workspace
    root that adopts the policy does not impose it on members that have not
    opted in. The regression tests are in
    [`rust_lints_test.exs`](../../../marshall/test/architecture/rust_lints_test.exs).
- **Splits.** The oversized `lib.rs` files became indexes:
  - mila-ffi, mila-runtime, mila-session, mila-protocol, mila-transport and
    mila-model
  - the spool, with unsafe code confined to `sys.rs` under
    `#![deny(unsafe_code)]`
  - the broker, the receiver, and nine Lilly helpers

  Each split was a pure move. `cargo test -- --list` is identical before and
  after every split, and public paths are re-exported. mila-ffi's 93 dynamic
  symbols (52 `mila_`, 41 `Java_`) and `include/mila_ffi.h` are byte-identical.
  The Android `MilaJniSignatureTest` now reads every `.rs` file under
  `mila-ffi/src` in sorted order, because the JNI exports moved to
  `src/android/`.
- **One property engine.** proptest is gone. Every proptest block in the spool,
  the broker and the receiver became a Hegel property with the same meaning.
  Gap properties were added where the plan's coverage map found none, for
  example:
  - the transfer-stream credit refill and the boot-log custody, which
    `CONTRACTS` had over-claimed
  - the spool SQLite limits
  - Mila command grammar round-trips and reply totality
  - trust reconciliation idempotence
  - C ABI buffer bounds
  - the app-lock state machine
  - session command bounds against a fake Porsche endpoint
  - the device-key primitives

  Each crate's `…-hegel-properties` contract now describes only the coverage
  that exists. Six Mila crates gained `CONTRACTS` files.
- **Lint fixes.** Every unsafe block carries a `// SAFETY:` comment.
  - Production `unwrap`/`expect` became typed errors, or an `#[expect]` whose
    reason records the invariant.
  - Truncating casts became `try_from` on the existing refusal paths.
  - Panicking string slices became `get`.
  - Manual `Debug` impls keep keys, bearer tokens and terminal bytes out of
    diagnostics.
- **Gates.** Every crate's gate runs fmt and `clippy --all-targets --locked -D
  warnings`:
  - Nix postChecks for the spool, receiver, observability-runtimes, terminald,
    Lyra under 1.97.1, the Lilly helpers and the Mila Linux client
  - Windows cross-target clippy for the broker and terminald
  - clippy for mila-ffi in the Apple, Windows, Linux and Android
    `mila-builds` jobs

## Defects found and fixed

- otel-request-recorder's machine test reset a unit that systemd had already
  garbage-collected.
- The commit-reply-loss fixture did not build on Rust 1.99.
- observability-runtimes' `Cargo.lock` was stale, so `--locked` refused it.
- mila-transport shipped `hegeltest` as a runtime dependency.
- The mila-transport trust test never called `reconcile_trust`.
- A Lyra privacy fixture expectation was wrong.

## Defects found and recorded, not fixed (behaviour changes need their own decision)

- `mila_protocol::Command::format` drops the `--` separator. An argument that
  starts with `--` formats to a line that does not parse back. It fails closed,
  and the `CONTRACTS` entry records the exclusion.
- `decode_reply` accepts any `request_id` string and non-canonical
  `operation_id` UUIDs. This is a partial gap against
  `mila-protocol-strict-envelope`.
- mila-journey's `unhex` accepts a leading `+` (`u8::from_str_radix`).

## Architecture impact

ADR-0265 moves from partial to implemented. No API, protocol, persistence,
authorization or isolation contract changed. Evidence links in ADR-0249 and
ADR-0264 were re-pointed where cited items moved.

## Verification run

- Per crate, on nixpkgs 1.99 and the pinned 1.97.1:
  - `cargo fmt --check`
  - `cargo test --locked`
  - `cargo clippy --all-targets --locked -- -D warnings`
  - `cargo doc --no-deps`
- `nix build` of every touched derivation, plus the `mila-rust`, `rust-lints`
  and `conflict-markers` checks.
- NixOS machine tests that passed:
  - trace-spool-native, vscode-web-broker, enrico-service and
    fleet-exporter-native
  - otel-request-recorder and its commit-reply-loss variant
  - vm-watch, source-export, zfs-io, terminal-fleet, agent-cli,
    installer-trust and service-roles
  - fleet
- Linux-native job replica: Broadway GTK tests (137 library + 6 GTK) and
  clippy for both feature sets on the integrated Mila tree. The hermetic
  fixture journeys passed locally on the Linux lint commit (headless 28/28,
  GTK 29/29). Another session's fixture held the fixed ports, so the journeys
  did not run locally against the final integrated workspace; the linux-native
  CI job runs them there.
- The mila-ffi `nm` symbol diff, the header hash and the JNI signature test.
  The JNI test ran through a kotlinc/JUnit harness because Gradle and the
  Android SDK are not installed locally. A deliberate return-type mismatch
  failed it as expected.
- `elixir scripts/check_rust_lints.exs --strict`, `check_adrs.exs`,
  `check_conflict_markers.exs`, `check_contracts.mjs format` and the checker's
  ExUnit tests.

## Known failures and remaining gaps

- These fail identically on the trunk baseline (aaadafd55):
  - zfs-guest "restart-contention 3" returns `invalid_workload_bundle` where
    it expects `disk_not_ready`.
  - the `logging` test's `overalls_logging_filesystem_valid`.

  The zfs-transfer and Marshall Inception failures are known Inception
  failures.
- The full Marshall suite timed out repeatedly under host load above 150. Only
  the checker test changed in Marshall, and it passes.
- Android-target clippy and Gradle did not run locally. CI's android-native
  job covers them.
- Not yet done:
  - unsafe confinement for Lyra and terminald, so that `unsafe_code = "deny"`
    can join the canonical block
  - a clippy gate for the native FreeBSD/illumos terminald derivation
  - splits of the large non-`lib.rs` files
  - rustdoc reports each `/// @cc [owner:…]` tag as an unresolved link
    (warnings, which is why rustdoc lints stay at their defaults)
- A planned single root Cargo workspace (Buck2 track T2) would contradict the
  alternative ADR-0265 rejected and needs a superseding decision.
