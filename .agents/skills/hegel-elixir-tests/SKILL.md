---
name: hegel-elixir-tests
description: Create, migrate, run, and review Elixir property tests using the repository's Hegel engine; use for StreamData migration, generator design, stateful/concurrent BEAM verification, replay, and evidence reporting.
metadata:
  short-description: Maintain Hegel property tests in Elixir
---

# Hegel property tests for Elixir

Use this skill when changing generated tests in an Overalls Mix application or when
reviewing a Hegel property. It applies to BEAM-level behavior and test tooling; it
does not replace NixOS machine tests, native Rust tests, browser probes, or fixed
ExUnit tests where those provide the required evidence.

## Before editing

1. Read the repository `AGENTS.md`, the target application's `AGENTS.md`, ancestor
   `CONTRACTS` files, and relevant ADRs.
2. Find the application's reviewed Events catalog before adding diagnostics. Hegel
   failures and test telemetry must use catalogued metadata and must not expose
   credentials, tokens, terminal bytes, command arguments, or payloads.
3. Identify the existing property runner, dependency pin, fixtures, sandbox ownership,
   and whether the property crosses a native, host, distributed, or machine boundary.
   Record architecture impact before implementation.

## Write properties

- Keep Hegel development/test-only (`runtime: false`) and use the repository-pinned
  native engine. Fail clearly when the NIF or ABI version is unavailable.
- When changing the `hegel_ex` Git revision in any `mix.exs` or `mix.lock`, update
  the corresponding fixed-output Mix dependency hash in
  `nix/domains/artifacts/dependency-hashes.json` for every affected application.
  Rebuild the relevant Nix artifact (or run the repository's hash-refresh workflow)
  and record the resulting hash; a Mix lock update alone leaves offline Nix builds
  inconsistent.
- Prefer explicit typed generators and bounded values. Give collections finite size;
  do not generate arbitrary atoms, PIDs, references, resources, secrets, or unbounded
  terms implicitly. Use assumptions only for genuinely unreachable combinations.
- Draw values through the explicit test-case API (`Hegel.draw/2` or `/3`) and label
  draws. Keep process-dictionary convenience APIs at the boundary rather than in
  domain helpers.
- Set up and tear down every mutable fixture per generated case and replay: SQL
  sandboxes, processes, sockets, temporary files, registries, and distributed nodes.
  Cleanup errors are failures and must not be swallowed. Make setup idempotent so
  shrinking and replay cannot observe leftovers from a previous case.
- For stateful behavior, model commands, preconditions, transitions, postconditions,
  and invariants separately. Use engine-managed pools for values produced by earlier
  commands; rejected commands should be distinguishable from failed assertions.
- For concurrency, use controlled Hegel schedules and inspect the complete history
  against a reference model or linearizability oracle. Keep real multi-node, KVM,
  isolation, and recovery claims in their existing machine/integration suites.
- Preserve refusal, malformed-input, stale-generation, duplicate, restart, and
  redaction assertions from the migrated property. A Hegel property may strengthen
  coverage but must not weaken an existing contract.
- Treat `test_cases` as a verification-strength setting, not a generic timeout
  workaround. Never clamp an ordinary property to one generated case merely to
  make a suite finish. Preserve default exploration (currently 100 cases) and
  existing larger budgets, including for real sockets and fresh OTP processes.
  A small count is appropriate for a deliberate failing replay control, not for
  making a generated success property pass. Audit truncated mutation lists as
  well as runner counts. A fixed exhaustive matrix belongs in an ordinary test.
- Use one `property` runner with labelled draws. Standalone `check all` runs its
  own engine, but nested `check all` at older pins silently ignores its options.
  `max_runs` and `max_shrinking_steps` are not supported Hegel settings. Inspect
  the exact pinned frontend before relying on compatibility syntax. The Elixir
  labelled convenience form is `draw(label, generator)`; the explicit Erlang
  API is `:hegel.draw(test_case, label, generator)`.
- Diagnose slow cases before changing their budgets. Keep per-operation
  deadlines and assertions; size a finite aggregate ExUnit timeout from measured
  case duration and the full exploration budget. Use Astra for stalled BEAM/NIF
  diagnosis when authorized, inspecting progress, stacks, CPU and memory. Do not
  kill an owned run merely because it is quiet. ExUnit `--trace` disables
  aggregate timeouts, including explicit tags and `--timeout`; omit it when
  verifying finite test budgets. Profile names alone do not prove
  effective case counts, randomness, replay-database or health-check settings.
- Keep diagnostics redacted by default. Include labels, locations, seeds, and bounded
  structural metadata; opt into values or replay blobs only when the test explicitly
  proves they are safe. Failure rendering must preserve the original exception.

## Migration and review

When replacing StreamData, first inventory all `property`, `check all`, generator,
fixture, and dependency usages. Convert mechanical syntax with an AST-assisted tool,
then review every property for Hegel size, shrinking, assumptions, context setup,
and replay cleanup. Remove stale `StreamData`/`ExUnitProperties` dependencies and
lock entries only after all applications compile.

Review each property for:

- a precise input/output type and bounded generator;
- deterministic seed/replay behavior;
- setup and teardown ownership on pass, failure, rejection, and timeout;
- secret-safe diagnostics and catalogued events;
- evidence limits (BEAM behavior versus native or deployment guarantees);
- meaningful shrinking rather than filtering away the interesting state space.

## Run and report

Run the smallest focused property or replay first, then the target application's
Buck2 `:check` and `:test` (`tools/precommit` selects them). Shared protocol changes require both Marshall and Lilly consumer
checks. Run contract, ADR, logging, and conflict-marker checks required by the
repository. Record exact seeds/replay identifiers, test counts, and known skipped
boundaries; do not describe a passing BEAM property as proof of physical isolation or
production recovery.

The native installer must publish a complete sibling file with atomic rename.
Never copy over a loaded `.so` in place: truncating its mapped inode can crash
another BEAM, even when the replacement bytes are identical. Before `b0dec2a`,
avoid concurrent Mix compilation and tests in the same application.

Before recording execution, compare the dependency checkout with `mix.lock` and
identify the loaded NIF and its ABI. A stale `deps/` checkout or an external NIF
override does not verify the packaged current pin. Exercise both successful
generation and a deliberate failure/replay through the native engine. For a
full-suite request, inventory every Mix application and default exclusions;
enable required distributed/host/capacity fixtures in an isolated environment.
Report unfinished and excluded tests separately from passes.

For failures, retain the minimized replay and original exception, identify whether the
cause is a generator, oracle, fixture cleanup, engine, or product defect, and add a
regression property when appropriate. If the engine or NIF cannot load, report the
pinned version and reproducible build command rather than silently falling back to a
weaker runner.

## References

- Existing machine Hegel patterns and redaction rules: [`docs/development/testing-with-hegel.md`](../../../docs/development/testing-with-hegel.md)
- Contract scope and evidence limits: [`docs/development/code-contracts.md`](../../../docs/development/code-contracts.md)
- Architecture review requirements: [`architecture-review`](../architecture-review/SKILL.md)
- Contract discovery and enforcement: [`code-contracts`](../code-contracts/SKILL.md)
