# ADR-0191: Elixir Hegel property verification

- ID: ADR-0191
- Status: accepted
- Date: 2026-10-17
- Implementation: partial
- Components: protocol, marshall, lilly, verification
- Supersedes: none
- Superseded by: none

## Context

Elixir applications already use generated tests alongside fixed examples,
contracts and machine verification. Their property engine needs bounded input
generation, deterministic replay, isolated fixtures and redacted diagnostics.
The existing suite is not yet fully migrated, and a test dependency alone cannot
establish either migration completion or native acceptance.

## Decision

Elixir applications use the pinned `hegel_ex` binding as the property engine for
new and migrated test-only properties. The dependency is development/test only,
runtime disabled, and is consumed from a reviewed upstream revision. Properties
must use bounded, typed generators; deterministic seeds and replay metadata; and
redacted diagnostics by default. Fixture-backed properties create and tear down
isolated state for each generated case. Stateful and concurrent properties
explicitly define a model, command history, oracle, and schedule boundary.

Hegel properties complement ordinary ExUnit tests, Covenant contracts, native
Rust tests, and NixOS machine tests. A BEAM property does not establish KVM,
physical isolation, host recovery, deployment, or production guarantees.
Those claims require the corresponding native or machine evidence.

## Rationale

The existing StreamData suite provides broad input coverage but has inconsistent
replay, shrinking, fixture cleanup, and diagnostics. Hegel gives the applications
one engine shared with the native verification stack while preserving the
separation between BEAM and machine evidence. Redacted traces avoid leaking
credentials, terminal bytes, command arguments, or payloads into CI artifacts.

## Alternatives

Retaining StreamData alone would preserve the current generator APIs but would
not establish the shared replay and diagnostic policy. Replacing machine tests
with BEAM properties would lose native isolation and recovery evidence. Hegel is
therefore test-only and complements the existing verification layers.

## Invariants and verification

Generators remain bounded and typed; fixed seeds and replay metadata reproduce
failures without exposing drawn secrets. Every generated fixture is cleaned up
on success, refusal and failure. Application compiler, contract, Dialyzer and
ExUnit gates remain required. Passing BEAM properties never establishes KVM,
storage durability, physical recovery or deployed fleet behavior.

## Implementation evidence

- [Elixir Hegel testing guide](../../development/testing-with-hegel.md)
- [Hegel Elixir skill](../../../.agents/skills/hegel-elixir-tests/SKILL.md)
- [Protocol test-only dependency pin](../../../protocol/mix.exs)
  currently selects frontend ref `b0dec2a`, resolved as
  `b0dec2abf868c7036950c00256a2ebf5af2929e7`,
  as do Marshall and Lilly. The historical complete protocol gate at
  `2c9f7a4a9f2cf156de063bbc8058bcf297be5cf0` passed 299 tests and properties;
  the linked review retains that source hash and the earlier `6a62795` result.
  Those historical results do not establish execution at the current pin.
  The final merged-source protocol gate at `132bc28b5` subsequently passed
  303 tests, Covenant 14/14 and Dialyzer with zero errors or skips; the linked
  matrix review records its exact log, seed and frozen source ledger.
  The frontend propagates supported standalone `check all` options and rejects
  unsupported options, nested execution settings and unsupported binding/filter
  syntax. Current consumer repairs use one runner with labelled draws, preserve
  default 100-case exploration and larger existing budgets, and isolate mutable
  fixtures per case. The atomic NIF installer preserves loaded library inodes.
  The [exploration and native custody review](../reviews/2026-10-18-hegel-exploration-and-native-custody.md)
  records the current repairs and their still-incomplete application verification.
  These repairs preserve generated assertions and production interfaces.
  The complete final-repair Marshall gate at `02cd8bd` passed 1,694 tests,
  Covenant 24/24 and zero-error forced Dialyzer; the historical `f1ad336`
  checkpoint retained a failing bounded context/options
  compilation probe. The earlier `08cd428` pin passed an isolated three-form context
  compilation/runtime probe and the preserved two-case distributed lock
  property. A complete `08cd428` Marshall gate subsequently passed 1,694
  tests with four exclusions, Covenant 24/24 and zero-error forced Dialyzer
  against frozen pre-machine-pin sources; it does not verify the later
  machine-pin integration. Final merged-source Marshall execution subsequently
  passed 1,712 tests with four exclusions, Covenant 27/27 and zero-error forced
  Dialyzer against unchanged frozen runtime sources. The linked matrix review
  records exact receipts and excludes later fixture/CSS corrections from that
  runtime gate. Final Lilly and Porsche consumer gates subsequently passed
  610 and 100 tests, Covenant15/15 and4/4 and zero-error forced Dialyzer;
  the frozen runtime ledger remained unchanged. These BEAM results do not
  complete the migration or establish native guarantees.
  At that earlier pin, all eight refreshed fixed-output dependency snapshots
  equalled the normalized source locks and their actual recursive NAR hashes
  equalled the configured values. The imported `8fe9786` update changes all
  eleven application pins and eight configured dependency hashes; those
  historical builds do not qualify its snapshots or native NIF. At completed
  merge `0de23e24d`, all eight ordinary-production dependency outputs were
  realized from existing caches: each lock snapshot equals its immutable
  evaluated source and checkout lock, and its independently computed recursive
  NAR hash equals configuration. The qualified receipt
  `/tmp/overalls-8fe-fod-custody.6EMduL/receipt-qualified.json` has SHA-256
  `9ab22b9dd67c43eb37c66d38c79defb5093495500718b83baaeab688c6bdc09b`.
  This establishes cached snapshot custody, not fresh-fetch reproducibility,
  release builds, native NIF execution, harness variants or Cargo custody.
  New source-bound smoke/replay and consumer evidence remain separate.
- [Protocol terminal properties](../../../protocol/test/hegel_terminal_test.exs)
  define bounded frame round trips and truncation cases with deterministic seeds.
  Their presence does not record execution or completion of the wider migration.
- [Protocol bounded generators](../../../protocol/test/support/test_generators.ex)
  retain exact alphabets, collection bounds, malformed peer shapes and unsigned
  64-bit values within the pinned engine's signed integer interface.
- [Protocol draw boundary](../../../protocol/test/support/test_properties.ex) and
  its [native failure replay test](../../../protocol/test/hegel_support_test.exs)
  keep generated values out of draw diagnostics while preserving the original
  exception. Control transport cases clean up owned listeners and supervised
  children before another generated case or replay.

Migration status is tracked by the test inventory and review record; properties
are only marked migrated after the new test has executed successfully with the
pinned native engine. StreamData removal is a completion criterion, not an
implicit result of adding the dependency.

## Open questions

Remaining application migrations need an inventory, executed property and replay
results, and verified fixture cleanup before their existing engines are removed.
Native Hegel smoke and full consumer gates retain their own execution records.
Protocol's workspace-source and View histories now use Hegel and ran in the
recorded final 303-test gate. The wider migration and supported
stateful/concurrent interfaces still require their own inventory and evidence;
the dependency pin alone establishes neither.

## Related decisions

- [ADR-0186: Covenant contract verification](0186-covenant-contract-verification.md)
- [Elixir Hegel verification review](../reviews/2026-10-17-elixir-hegel-property-verification.md)
- [ADR-0265: Rust code quality](0265-rust-code-quality.md) adopts Hegel as the Rust property engine

## Consequences

Each application gate must run the Hegel native smoke/replay checks and its
normal compiler, contract, Dialyzer, and ExUnit checks. Fixture-heavy and
multi-node suites may migrate incrementally, but must retain their existing
contract and machine evidence until equivalent coverage is recorded.
