# ADR-0273: One Cargo workspace and one Rust toolchain

- ID: ADR-0273
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: Rust, build
- Supersedes: none
- Superseded by: none

## Context

The repository has about 22 Cargo lock roots and six Rust toolchains:

- a prebuilt 1.97.1 for Lyra and Mila;
- nixpkgs 1.99;
- cross-toolchain variants.

Shared crates resolve to different versions in different locks; for example,
hegeltest is at 0.28.6 in some and 0.28.8 in others. (Correction at T2: by
then every manifest already required `hegeltest = "=0.28.8"`; the remaining
skew was 48 patch-level versions such as libc 0.2.186 to 0.2.191, with the
Lilly helpers pinning `=0.2.189`.) Buck2 builds Rust with the
prelude rules from a single reindeer-generated third-party cell
([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)). The user chose
one workspace with prelude rules and reindeer on 2026-10-30.

## Decision

1. **Workspace and lock.** A root `Cargo.toml` workspace and a single root
   `Cargo.lock` replace the per-crate lock roots. Nix vendors that lock with
   `importCargoLock`, with no separate hash
   ([ADR-0267](0267-single-dependency-pin-registry.md)).
2. **Toolchain.** One Rust toolchain, pinned through a rust-overlay flake input
   with every target the repository builds, replaces the prebuilt archives and
   the per-component toolchains.
3. **Buck2 builds.** Buck2 builds every crate with the prelude Rust rules.
   Third-party crates come from `reindeer buckify` over the vendored lock.
4. **Lint gate.** The [ADR-0265](0265-rust-code-quality.md) lint gate
   (`cargo clippy --all-targets --locked -- -D warnings`) stays. Its lint
   tables move to `[workspace.lints]`, and the per-crate lint check is updated
   to match.

Authorization: the user's 2026-10-30 answer choosing one workspace with prelude
rules and reindeer, and the approved migration plan (T2 and M5).

## Alternatives

- **Per-crate locks with Buck2 `cargo` wrappers.** This keeps today's layout,
  but it duplicates third-party builds and keeps version skew.
- **crane or naersk in Nix.** These are Nix builds of first-party code, which
  ADR-0269 removes.

## Consequences

- One set of third-party crate versions. Upgrades touch one lock.
- The merge is a large single change, and it conflicts with concurrent
  per-crate work.
- The Lyra and Mila targets move from 1.97.1 to the chosen pinned version. That
  version is recorded with the toolchain input.

## Invariants and verification

- Exactly one tracked `Cargo.lock`, checked by the `pins` registry and the
  cargo upgrade refusal.
- The lint gate and `cargo fmt --check` pass on the workspace.
- Lyra, terminald and the Mila native outputs are behaviourally equal before
  and after the move. Checked by their existing tests, release probes and the
  dependent machine tests.

## Implementation evidence

Partial: decisions 1 and 4 are implemented by track T2. Decisions 2 and 3 are
partial, in milestone M5.

- **One workspace, one lock.** The root [`Cargo.toml`](../../../Cargo.toml)
  lists all 32 first-party crates as members: the 13 Lilly helpers, Lyra,
  terminald, the editor broker, the diagnostics spool, Enrico's git-owner,
  Marshall's Cedar NIF, the guest telemetry receiver, observability-runtimes,
  the Mila Linux client and the nine `mila/rust` crates. No crate is exempt.
  The root [`Cargo.lock`](../../../Cargo.lock) was seeded from the union of the
  23 previous locks, keeping the highest version in each semver-compatible
  group, and then resolved by Cargo. Every locked third-party version was
  already in some previous lock except `web-sys` 0.3.106, which matches the
  `js-sys` 0.3.106 already in use. The Lilly helpers' exact libc pin moved from
  `=0.2.189` to `=0.2.191`. Lyra's `fs2` illumos patch moved to the root
  `[patch.crates-io]`. Mix dependency checkouts (`<app>/deps`) and vendored
  trees are excluded, so the Rustler crates of hegel_ex and ex_cedar still build
  outside the workspace.
- **Profiles.** Cargo applies profiles only at the root. `release` stays
  Cargo's default, so Rustler NIFs and Mila's FFI libraries keep unwinding
  panics. A `hardened` profile (`inherits = "release"`, strip, LTO, one codegen
  unit, `panic = "abort"`) carries the settings that the Lilly helpers, Lyra,
  terminald and the editor broker each declared before. Their Nix builds select
  it with `cargoBuildType = "hardened"` or `--profile hardened`.
  **Open regression from T2 (a89cde0de).** `cargoBuildType` has no effect:
  nixpkgs' `buildRustPackage` sets it from its own `buildType` argument
  (default `release`). Since a89cde0de the 13 Lilly helpers and terminald's
  and the editor broker's Linux musl builds are therefore `release` builds
  that unwind on panic, keep their symbol tables and use neither LTO nor one
  codegen unit (`cargoBuildHook flags: ... --profile release` in their
  logs). Before T2 each crate's own `[profile.release]` made them abort, strip
  and use LTO. Lyra, terminald's FreeBSD, illumos and Windows builds and the
  broker's Windows build pass `--profile hardened` and are unaffected. The
  deployed helpers are the unwind builds, so the Buck2 helpers match them
  (`release`) until a later change restores `hardened` in Nix
  (`buildType = "hardened"`) and Buck2 together, after the panic paths that
  abort would expose are found. The leaves now declare that profile with the
  effective `buildType = "release"`, and `cargoWorkspace.rustPlatform`'s
  `buildRustPackage` refuses `cargoBuildType`, so a declared profile can no
  longer be dropped silently.
- **Nix.** [`cargo-workspace.nix`](../../../nix/domains/artifacts/infrastructure/cargo-workspace.nix)
  vendors the root lock once with `importCargoLock` (through
  [`locked-cargo-vendor.nix`](../../../nix/domains/artifacts/infrastructure/locked-cargo-vendor.nix)).
  It builds each consumer's source from the root manifest, lock and
  `clippy.toml`, every member manifest, and the full sources of only the crates
  that consumer compiles. Other members get empty target stubs, so `--locked`
  sees the unchanged lock, and an edit to one crate does not rebuild the
  others. Every first-party Rust derivation uses it, as does Marshall's release
  source for Rustler. The `cedarCargo` fixed-output hash is gone, and
  `lib.dependencyPins.cargo` has the single `workspace` entry in
  [`default.nix`](../../../nix/domains/artifacts/default.nix).
- **Vendor stays a build input.** The Cedar NIF's panic locations named
  vendored crate sources, so Marshall's release retained the vendor link farm
  and all 516 crates: 540 runtime paths instead of 24. Marshall's release
  build now passes `--remap-path-prefix` for the vendor, and the closure is
  23 paths. The single `marshall-cedar-vendor` that the pre-T2 build retained
  is gone too. Every `<app>-release` check in
  [`release/default.nix`](../../../nix/verification/tests/release/default.nix)
  refuses a closure that contains the vendor or any crate in it.
- **Exactly one lock.** `cargo_locks/1` in [`pins.ex`](../../../scripts/pins.ex)
  (the `pins` check) and `single_root_lock/1` in
  [`cargo_security_upgrades.ex`](../../../scripts/cargo_security_upgrades.ex)
  refuse any other tracked `Cargo.lock`. Their tests are in
  [`pins_test.exs`](../../../marshall/test/architecture/pins_test.exs) and
  [`dependency_pins_test.exs`](../../../marshall/test/architecture/dependency_pins_test.exs).
- **Toolchain (decision 2, partial).** The `rust-overlay` flake input in
  [`flake.nix`](../../../flake.nix) (following `buildNixpkgs`) is the only
  rust-overlay pin. [`rust-toolchain.nix`](../../../nix/rust-toolchain.nix)
  reads it from `flake.lock` and defines the one release (1.97.1), its
  components and its 14 target standard libraries: Linux gnu and musl,
  Windows gnu, macOS, FreeBSD, illumos, iOS and the three Android ABIs. It
  omits `rust-src`, because with it rustc maps std's `/rustc/<hash>` panic
  locations to the store path and Lyra's and terminald's `allowedReferences`
  fail; rust-analyzer gets the sources through `RUST_SRC_PATH`. The devenv
  shell on every platform ([`devenv.nix`](../../../devenv.nix)), Lyra's and
  terminald's cross and native builds
  ([`lyra.nix`](../../../nix/domains/artifacts/infrastructure/lyra.nix)) and
  Buck2's `[nix] rust` entry ([`cells.nix`](../../../nix/buck/cells.nix)) use
  it. The prebuilt `rustStd*`, `rustcArchive` and `clippyArchive` pins and
  devenv's own rust-overlay input are gone. Runners without Nix keep the
  `toolchain:` literal in the Mila workflows;
  [`check_rust_toolchain_literals.exs`](../../../scripts/check_rust_toolchain_literals.exs)
  (`//:rust-toolchain-literals`, a precommit check) refuses one that differs
  from the pinned version. Lyra, Lyra's tests, its Windows and native builds,
  terminald (musl, Windows and native) and the editor broker's Windows build
  rebuilt under it. Every first-party Nix Rust leaf now uses it too:
  [`cargo-workspace.nix`](../../../nix/domains/artifacts/infrastructure/cargo-workspace.nix)
  exports `rustPlatform` (`makeRustPlatform` over the single toolchain),
  `rustTools` (its clippy and rustfmt) and `buildStaticMusl`, which builds a
  static-pie musl binary with rustc's self-contained CRT and `rust-lld`
  (`allowedReferences = [ ]`). The 13 Lilly helpers, Enrico's git owner,
  the guest telemetry receiver, observability-runtimes, the trace spool,
  terminald's checks and Mila's Rust and Linux builds use `rustPlatform`;
  terminald's musl build and the editor broker use `buildStaticMusl`
  with the profile the leaf declares through `buildType` (`release` for both,
  as before; see the open T2 regression above). The exported
  `buildRustPackage` refuses `cargoBuildType`, which nixpkgs ignores, so a
  declared profile always takes effect. `pkgsStatic`'s
  `makeRustPlatform` over this toolchain was rejected: its build scripts
  crashed with SIGSEGV. The leaves' derivations, and so every host's
  system derivation, changed on purpose; the closures differ only in those
  leaves and their dependents. Third-party builds (NativeLink, underclass),
  Marshall's Cedar NIF and lints and libhegel stay on nixpkgs Rust until M6.
- **Buck2 builds (decision 3, partial).** [rust.nix](../../../nix/buck/rust.nix)
  generates the `rust//` cell in Nix from the root lock:
  [rust_cell.py](../../../nix/buck/rust_cell.py) writes a pseudo-package of
  every member's direct third-party dependencies at their locked versions,
  refuses any version the root lock did not resolve, and `reindeer buckify`
  ([reindeer.toml](../../../nix/buck/rust/reindeer.toml)) runs over the
  `importCargoLock` sources. Nothing generated is committed, so the lock stays
  the only pin. [rust.bzl](../../../toolchains/rust.bzl) defines the prelude
  Rust toolchain over the single toolchain and a C toolchain over the Nix cc
  wrapper. [buck/rust.bzl](../../../buck/rust.bzl)'s `overalls_rust_crate`
  builds members from the generated `workspace.bzl` table with the workspace
  lints and Cargo profiles, and adds per-crate `clippy` and `rustfmt`
  precommit checks. The 13 Lilly helpers, Enrico's git owner, the guest
  telemetry receiver, observability-runtimes and the trace spool build and pass
  their tests (60 Buck2 test targets). `rust_leaf_parity_test` compares an
  imported Buck2 leaf with its Nix build. Those five leaves are swapped for
  machine tests: [rust_artifacts.bzl](../../../buck/rust_artifacts.bzl) maps
  `lilly-host-helpers`, `enrico-git-owner`, `otel-guest-receiver`,
  `observability-runtimes` and `trace-spool` to their imports, and each has a
  passing `heavy` parity test, which also compares the panic strategy (see the
  [M5 review](../reviews/2026-10-30-buck2-migration.md#m5-rust-on-buck2)).
  The affected machine tests pass with the swaps except fleet's capacity
  race, which fails identically without them on current trunk (race host
  16.895 GB free against a sub-180 MB slot margin) until overalls-1f's fix.
  The Buck2 helpers first used `hardened`, matching the declared profile but
  not the unwind build Nix actually produces; real guest launches failed in
  machine run 41094831662, and fbb29d9fe held the swap back. An A/B cleared
  them (the failures were runner oversubscription; see the review), and the
  helpers now build `release`, with the panic strategy in the parity test.
  Since M2 (7ccb4f72a) a host's `:deployment` target carries the same
  `ASSEMBLY_ARTIFACTS`, so hosts deploy these Buck2 builds too; the flake's
  Nix builds remain the fallback until M11. Remaining: terminald, the editor broker
  and Lyra (musl and cross targets), Marshall's Cedar NIF, Mila and its
  cbindgen header.
- **Lint gate.** The root `[workspace.lints]` is `scripts/rust/lints.toml`
  verbatim. Every member opts in with `[lints] workspace = true`, and one root
  [`clippy.toml`](../../../clippy.toml) replaces the per-crate copies.
  [`rust_lints.ex`](../../../scripts/rust_lints.ex) treats a root at `.` as
  enclosing every crate. A regression test for this is in
  [`rust_lints_test.exs`](../../../marshall/test/architecture/rust_lints_test.exs).
  `cargo clippy --workspace --all-targets --locked -- -D warnings` and
  `cargo fmt --all -- --check` passed on the workspace under nixpkgs Rust 1.99,
  and the clippy gate passes in the devenv shell under the pinned 1.97.1.
  The per-crate Nix gates still run their crate's clippy, including Lyra's and
  terminald's cross-target clippy under the pinned 1.97.1 toolchain.
- **Platform builds.** The Mila Apple script, the Android Gradle task and the
  `mila-builds`/`mila-release` workflows build `mila-ffi` through its own
  manifest inside the root workspace. Gradle also tracks the root lock as an
  input.

Remaining for this decision:

- Marshall's Cedar NIF, its lints and libhegel on nixpkgs Rust 1.99
  (decision 2, M6), and the Buck2 builds of terminald, the broker, Lyra, the
  Cedar NIF and Mila (decision 3), in M5;
- per-consumer Nix source filters, until M5 deletes the `buildRustPackage`
  leaves.

## Open questions

None.

## Related decisions

- Amends [ADR-0265](0265-rust-code-quality.md)'s lint-distribution clauses
  (decision 1 and its first rejected alternative); ADR-0265 records the
  amendment.
- [ADR-0267](0267-single-dependency-pin-registry.md) and
  [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md).
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
