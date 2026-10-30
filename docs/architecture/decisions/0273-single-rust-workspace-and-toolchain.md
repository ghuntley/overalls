# ADR-0273: One Cargo workspace and one Rust toolchain

- ID: ADR-0273
- Date: 2026-10-30
- Status: accepted
- Implementation: planned
- Components: Rust, build
- Supersedes: none
- Superseded by: none

## Context

The repository has about 22 Cargo lock roots and six Rust toolchains:

- a prebuilt 1.97.1 for Lyra and Mila;
- nixpkgs 1.99;
- cross-toolchain variants.

Shared crates resolve to different versions in different locks; for example,
hegeltest is at 0.28.6 in some and 0.28.8 in others. Buck2 builds Rust with the
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

No implementation yet (track T2, milestone M5).

## Open questions

None.

## Related decisions

- [ADR-0265](0265-rust-code-quality.md),
  [ADR-0267](0267-single-dependency-pin-registry.md) and
  [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md).
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
