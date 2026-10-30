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

Partial: decisions 1 and 4 are implemented by track T2. Decisions 2 and 3
remain planned for milestone M5.

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
- **Lint gate.** The root `[workspace.lints]` is `scripts/rust/lints.toml`
  verbatim. Every member opts in with `[lints] workspace = true`, and one root
  [`clippy.toml`](../../../clippy.toml) replaces the per-crate copies.
  [`rust_lints.ex`](../../../scripts/rust_lints.ex) treats a root at `.` as
  enclosing every crate. A regression test for this is in
  [`rust_lints_test.exs`](../../../marshall/test/architecture/rust_lints_test.exs).
  `cargo clippy --workspace --all-targets --locked -- -D warnings` and
  `cargo fmt --all -- --check` pass on the workspace under nixpkgs Rust 1.99.
  The per-crate Nix gates still run their crate's clippy, including Lyra's and
  terminald's cross-target clippy under the pinned 1.97.1 toolchain.
- **Platform builds.** The Mila Apple script, the Android Gradle task and the
  `mila-builds`/`mila-release` workflows build `mila-ffi` through its own
  manifest inside the root workspace. Gradle also tracks the root lock as an
  input.

Remaining for this decision:

- the rust-overlay toolchain (decision 2) and Buck2 prelude and reindeer builds
  (decision 3), in M5;
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
