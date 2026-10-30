# ADR-0265: Rust code quality: module layout, lint policy and Hegel properties

- ID: ADR-0265
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: Lilly, Mila, diagnostics, Lyra, terminald, guest artifacts, verification
- Supersedes: none
- Superseded by: none

## Context

Overalls has 31 non-vendored Rust crates (about 99,000 lines) across Lilly host
helpers, the Mila core and clients, Lyra, terminald, the diagnostics spool, the
guest editor broker and guest telemetry. They share no lint policy. No manifest
had a `[lints]` table. Several crates kept most of their code in one `lib.rs`:
mila-ffi had 2,267 lines, with 59 exported C and JNI symbols. Clippy
`-D warnings` gated most Nix builds, but not spool, the guest telemetry receiver,
observability-runtimes or the Windows broker. CI built mila-ffi on each platform
without clippy.

A probe on 2026-10-30 ran the lint set below against every crate on nixpkgs Rust
1.99.0. It found about 4,800 findings:

| Finding | Count |
| --- | --- |
| `unwrap`/`expect`, all code | 2,445 |
| `unwrap`/`expect` in production code (Lyra 102, mila/rust 57, terminald 52, hostd 35) | about 260 |
| unsafe blocks without a SAFETY comment | 318 |
| `unreachable_pub` | 211 |
| pedantic casts | 210 |
| intentional `let _ =` drops | 169 |

Most crates use the pinned Rust Hegel binding (`hegeltest = "=0.28.8"`).
Spool, the broker and the receiver used proptest instead.
[ADR-0191](0191-elixir-hegel-property-verification.md) settled the Elixir
property engine only. Two crate `CONTRACTS` claimed Hegel coverage that did not
exist: transfer-stream's credit throttle, and boot-log's output custody and exit
mapping.

The user requested the module split, strict compilation and clippy best
practice for all Rust, and Hegel property tests. That request authorizes this
decision.

## Decision

1. **Canonical lints.** [`scripts/rust/lints.toml`](../../../scripts/rust/lints.toml)
   is the single lint policy.
   - Every non-vendored crate carries it verbatim as `[lints]`. The Mila
     workspace carries it as `[workspace.lints]`, and each member uses
     `[lints] workspace = true`.
   - [`scripts/rust/clippy.toml`](../../../scripts/rust/clippy.toml) sits beside
     every standalone manifest and workspace root. Nix builds copy only the crate
     directory, so clippy cannot find a repository-root file there.
   - The policy:
     - **rustc, deny:** `unsafe_op_in_unsafe_fn`, `unused_must_use`.
     - **rustc, warn:** `rust_2018_idioms`, `unused_qualifications`, trivial
       casts, `unreachable_pub`, `missing_debug_implementations`.
     - **rustdoc:** left at its defaults. Denying `broken_intra_doc_links`
       would reject every `/// @cc [owner:…]` contract tag as an unresolved link.
     - **clippy, warn:** the `all` and `pedantic` groups, plus `unwrap_used`,
       `expect_used`, `panic`, `todo`, `unimplemented`, `dbg_macro`,
       `undocumented_unsafe_blocks`, `multiple_unsafe_ops_per_block`,
       `allow_attributes_without_reason`, `mem_forget`, `string_slice`,
       `as_underscore` and `lossy_float_literal`.
     - **allowed:** `module_name_repetitions`, `must_use_candidate`,
       `missing_errors_doc` and `missing_panics_doc`. They add noise without
       catching defects in unpublished internal crates.
     - **tests** may use `unwrap`, `expect`, `panic` and indexing.
2. **Fatal gates.** Every Rust gate runs `cargo clippy --all-targets --locked
   -- -D warnings`, so warn-level lints fail CI. Plain release builds fail only on
   the deny-level lints. A toolchain that introduces a new lint therefore breaks
   gates, not releases. The change that bumps the toolchain fixes the new
   findings. Every lint name must exist on both pinned toolchains: nixpkgs 1.99
   and 1.97.1 for Lyra and the Mila platform CI jobs.
3. **Narrow exceptions.** An exception is
   `#[expect(lint, reason = "...")]` at the narrowest scope that needs it.
   - An `allow` is permitted only where `expect` cannot work. An example is an
     unsafe shim module whose lint fires on only some targets. Even then it
     carries a reason.
   - Crate-wide exceptions require an amendment to this ADR.
   - Production `unwrap`/`expect` become typed errors or a proven invariant
     recorded in the reason.
4. **Unsafe confinement.** A crate that denies or forbids `unsafe_code` keeps
   unsafe code in named shim modules, declared as
   `#[allow(unsafe_code, reason = "...")] mod shim;` in its parent. The audit
   surface stays visible in `lib.rs`.
   - Spool adopts this convention.
   - Every unsafe block carries a `// SAFETY:` comment that states the invariant.
   - Global `unsafe_code = "deny"` is not part of the canonical block. Lyra (153
     blocks in 26 files) and terminald (193 blocks in 13 files) first need their
     unsafe code redesigned into shims.
5. **`lib.rs` is an index.** It holds crate documentation and attributes,
   module declarations, re-exports, top-level contract constants, and the
   crate's main type when keeping it at the root avoids wider field visibility.
   - Concerns live in their own modules.
   - Inline test modules become sibling `tests.rs` files or move with the
     module they test.
   - Public paths stay stable through re-exports.
6. **One property engine.** Hegel (`hegeltest`, pinned) is the only Rust
   property engine.
   - Properties use explicit case counts, generators bounded by `max_size`, and
     an independent oracle or round-trip.
   - Each carries a `@cc [label:verification]` note, and the crate's `CONTRACTS`
     describes only coverage that exists.
   - Failure output never contains tokens, keys or terminal bytes.
7. **Drift guard.** [`scripts/check_rust_lints.exs`](../../../scripts/check_rust_lints.exs)
   enforces items 1 and 3. It runs as the `rust-lints` prek hook and Nix check.
   Adoption ratchets: an adopted crate cannot drift, and `--strict` (enabled
   once every crate complies) refuses crates that have not adopted the policy.

## Alternatives

- **Inheriting lints through one Cargo workspace for every crate.** Rejected.
  The crates are deliberately independent builds with their own lockfiles and
  Nix derivations, and Cargo cannot inherit lints across workspaces.
  Verbatim copies plus a drift checker give the same single source.
- **`RUSTFLAGS=-D warnings` or `[lints.rust] warnings = "deny"`.** Rejected. A
  toolchain bump would break release builds, including platform builds that
  are not linted on Linux, instead of failing a gate.
- **`let_underscore_drop`, the `nursery` and `cargo` groups.** Rejected.
  `let_underscore_drop` produced 169 findings, almost all intentional
  best-effort `let _ = child.kill()`. `nursery` lints are unstable across the two
  toolchains. `cargo` metadata lints target published crates.
- **Keeping proptest beside Hegel.** Rejected. Two engines mean two shrinking,
  replay and redaction disciplines. [ADR-0191](0191-elixir-hegel-property-verification.md)
  already uses Hegel for Elixir.

## Consequences

- Readability and review improve: findings name concrete defects such as
  truncating casts, panicking string slices and undocumented unsafe code.
- A toolchain bump can surface new pedantic findings, which the bump must fix.
- The one-time cleanup touches every crate, so it lands crate by crate, each
  with its fixes, to keep CI green.
- The split preserves exported symbols and public paths, so native clients and
  callers are unaffected.

## Invariants and verification

- **Pure-move split.** The test list (`cargo test -- --list`) is unchanged
  except for added properties. mila-ffi's dynamic symbol set
  (`nm -D --defined-only`) is identical to the pre-split set.
- **Policy conformance.** `elixir scripts/check_rust_lints.exs --strict` passes.
  Its regression properties are in
  [`marshall/test/architecture/rust_lints_test.exs`](../../../marshall/test/architecture/rust_lints_test.exs).
- **Lint coverage.** Each crate's gate runs clippy `-D warnings` under its
  pinned toolchain. Mila platform jobs run it on their targets.
- **Disproof.** Any of these would show the design does not hold:
  - a gate that does not run clippy for a crate
  - an exception without a reason
  - a crate `CONTRACTS` claiming property coverage that no test exercises

## Implementation evidence

Partial.
- **Present:**
  - the canonical policy files [`scripts/rust/lints.toml`](../../../scripts/rust/lints.toml)
    and [`scripts/rust/clippy.toml`](../../../scripts/rust/clippy.toml)
  - the checker [`scripts/rust_lints.ex`](../../../scripts/rust_lints.ex) with its
    Hegel regression properties in
    [`marshall/test/architecture/rust_lints_test.exs`](../../../marshall/test/architecture/rust_lints_test.exs)
  - the `rust-lints` hook in [`devenv.nix`](../../../devenv.nix) and the Nix check in
    [`flake.nix`](../../../flake.nix)
- **Recorded crate by crate:** adoption, splits and properties land in later
  changes.
- **Remaining:**
  - adopt the policy in every crate, then run the checker with `--strict`
  - migrate proptest to Hegel in spool, the broker and the receiver
  - add the gap properties
  - add clippy gates to spool, the receiver, observability-runtimes and the Mila
    platform jobs
  - confine unsafe code in Lyra and terminald (follow-up)

## Open questions

- Can the Windows broker run cross-target clippy in Nix, or does a Windows CI
  job need to host the gate?
- When should Lyra and terminald unsafe confinement be scheduled, so that
  `unsafe_code = "deny"` can join the canonical block?

## Related decisions

- [ADR-0191: Elixir Hegel property verification](0191-elixir-hegel-property-verification.md)
- [ADR-0028: Colocated code contracts](0028-colocated-code-contracts.md)
- [ADR-0249: Mila Rust core for native clients](0249-mila-rust-core-native-clients.md)
