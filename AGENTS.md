# Overalls repository guidance

Overalls is the monorepo for Marshall (control plane), Lilly (provisioner), and
their shared protocol library. Read the [architecture overview](docs/architecture/README.md) and
relevant [ADRs](docs/architecture/decisions/README.md) before changing a component.
Also read [Marshall guidance](marshall/AGENTS.md), [Lilly guidance](lilly/AGENTS.md)
or [Mila guidance](mila/AGENTS.md) for the component being changed.

## Concurrent agents

- Assume other Claude Code and Codex agents may be working in this repository at
  the same time. Check the shared workspace before editing and keep unrelated
  work intact.
- Coordinate with those agents through the message board functionality built
  into Claude Code and Codex. Share discoveries, file ownership, planned
  edits, conflicts and handoff details there rather than relying on local
  assumptions.
- For new work, clone the repository into `~/src/overalls-<featurename>` rather
  than creating a new Git worktree. Use a short, descriptive feature name and
  coordinate the clone path with other agents through the message board.

## Architecture maintenance

- Assess architecture impact for **every change**, before implementation and
  again against the final diff. A brief “no architecture impact” explanation
  suffices for changes that preserve existing decisions and contracts.
- Use the [architecture-review skill](.agents/skills/architecture-review/SKILL.md)
  for changes to domain boundaries, APIs/protocols, persistence, authorization,
  isolation, capacity, recovery, or significant dependencies, and at milestone
  completion. Record substantive reviews in `docs/architecture/reviews/`.
- Use the [adr-maintenance skill](.agents/skills/adr-maintenance/SKILL.md) to update
  affected decisions in the same change. Update the overview and index when
  their descriptions or statuses change.
- Distinguish an accepted decision from its implementation. Link actual
  code/configuration/tests as evidence for `partial` or `implemented`; dependency
  installation alone does not establish that an architectural capability works.
- Reconcile discrepancies explicitly: fix code that violates the decision, or
  propose a replacement decision with its rationale. Do not silently rewrite
  accepted decisions to match accidental behavior.
- Preserve accepted rationale. Corrections, evidence and implementation status
  updates can edit an ADR; material changes require a new ADR with reciprocal
  supersession links. Use authorization already provided by the task or plan;
  leave unresolved new decisions proposed without stopping independent work.
- Summaries and PR descriptions state architecture impact, affected ADR IDs,
  validation performed, and any remaining gaps. Cosmetic changes do not need an
  empty ADR or review report.

## Temporary reminder: eMudhra compromise follow-ups (from 2026-10-22)

The October 2026 eMudhra intermediate-key compromise left temporary workarounds and
pending upstream fixes. On or after 2026-10-22 check each item below; recheck any
still pending every two days. Delete an item once it is done and this section when
it is empty.

1. **Non-NixOS guest images.** Ubuntu, Arch, Alma, FreeBSD and Windows guests use their
   distribution's trust store. Rebuild those images once their `ca-certificates`
   (or equivalent) updates ship.

## Builds

- Buck2 is the only build entry point (ADR-0269). Run `tools/buck2`, never a
  buck2 from `PATH` or a new `nix build .#…` entry point. Use the
  [buck2 skill](.agents/skills/buck2/SKILL.md) for BUCK, `.bzl`, BXL,
  toolchain and wrapper changes. Use the
  [nix-builds skill](.agents/skills/nix-builds/SKILL.md) for pins, the Buck2
  cells, NixOS modules and assembly.
- Until an output moves to a Buck2 rule, it builds through the bootstrap
  `nix_flake_attr` targets (`tools/buck2 build //:package-<name>` or
  `//:check-<name>`). Delete the bootstrap use in the same change that moves
  the output.

## Verification and implementation

- Prefer NixOS machine integration tests and property-based tests above other
  evidence. Distinguish test presence from recorded passing execution and explain
  missing preferred coverage. Unit tests cannot establish native isolation.
- Inception is known broken and out of scope. Ignore Inception-related
  failures, including the zfs-guest "Inception retains a separate sparse data
  drive" subtest and the Inception machine tests: do not investigate or fix
  them, and do not let them block other work. Report them as known Inception
  failures.
- Elixir diagnostic events MUST go through each application's reviewed Events
  catalog (`Marshall.Events`, `Lilly.Events`, `Audi.Events`, `Brady.Events`,
  `Ziggy.Events`, `Porsche.Events`, `Susan.Events`): add a `defevent` entry first, then emit
  with catalogued metadata keys only. Never log credentials, authentication
  tokens, terminal bytes, command arguments or payloads; the catalogs have no
  string metadata type on purpose. Outcome events follow the outer transaction
  commit. The `logging.check` precommit gate enforces this structurally, and the
  per-application prek commit hooks enforce it on changed Elixir files; see
  the [fleet logging review](docs/architecture/reviews/2026-09-19-structured-logging-fleet.md).
- Use types in every programming language, for production code, scripts and
  tests. Use the language's native type system, annotations or typespecs; define
  explicit input/output types at interfaces and structured types for domain data.
  Use inference where it preserves precise types. Validate external data before
  treating it as typed, and avoid unrestricted escape hatches such as `Any` or
  unchecked casts. For languages without static typing, use the available schema,
  option types and runtime validation to make contracts explicit. Run the relevant
  type checker when available; do not claim typing is verified from syntax alone.
- Python targets Python 3.13 and is gated by the pinned Rust toolchain in
  `pyproject.toml`: ruff format and ruff check (including required annotations)
  and ty type checking. Run all three with `prek run --all-files` inside
  `devenv shell`; the hooks install automatically and CI enforces the same gate
  as the `python-static` check. Machine-test driver fragments under
  `nix/tests/machines` are formatted, linted and annotation-checked standalone;
  their type checking happens on the Nix-composed driver inside the NixOS test
  framework. Narrow parsed JSON through `object`-typed boundaries or TypedDict
  validators (`nix/modules/backups/schema.py` is the pattern), and document any
  runtime-only import with a targeted `ty: ignore` naming its source.
- Many sessions share this repository through `git worktree`, and the stash is
  shared by all of them. Do not use `git stash`: a failed `stash push` followed
  by `stash pop` applies another session's work. To compare against a baseline,
  use a separate detached worktree (`git worktree add --detach <dir> <rev>`) or
  copy files aside instead.
- Committed merge-conflict markers are refused by `elixir scripts/check_conflict_markers.exs`,
  which runs as a prek hook at commit and merge-commit time (merge commits skip
  ordinary pre-commit hooks) and as the `conflict-markers` Nix check. Resolve
  every conflict before committing a merge; never commit with hooks bypassed.
- Run `elixir scripts/check_adrs.exs` from the repository root for architecture
  changes. From Marshall, use `elixir ../scripts/check_adrs.exs`. The checker
  validates structure and ADR references, not whether the design is sound or implemented.
- Enter `devenv shell` for the pinned Elixir/OTP runtime. Run `mix precommit` in
  each changed project (`marshall/`, `lilly/`, `protocol/`); all enforce the runtime,
  ADR, compiler, test and Dialyzer gates. For shared governance tooling, run
  Marshall's suite too because it contains the shared validator regression tests.
- Shared protocol changes require checks in both consumers as well as the
  library. Marshall's test-only Lilly dependency exercises the real client
  against its API; neither production release depends on the other application.
  Keep `dialyzer --force-check` in both consumer gates: local dependency changes
  do not necessarily change `mix.lock`, so Dialyxir's quick cache check can miss
  new or changed protocol modules.
- Use Ash domains and resources for domain modeling. Follow the accepted ADRs
  for typespecs, Dialyzer, structured logging, property tests and Ash extensions.
  Record unmet requirements honestly; do not claim tools are enforced before
  they run. Keep unrelated existing work intact.
- Marshall's web presentation follows The Monospace Web (ADR-0161). Use the
  [monospace-web skill](.agents/skills/monospace-web/SKILL.md) for every
  template, stylesheet, presentation JavaScript or browser-probe change.
- Use the `code-contracts` skill for every code change and code review. Follow its
  contract discovery, writing, and enforcement procedures before submitting commits
  or pull requests.
- Read ancestor `CONTRACTS` files and local source notes before edits. See the
  [contract guide](docs/development/code-contracts.md) for the pinned tool installation,
  native-language annotation conventions and discovery limits. All three
  `mix precommit` gates include `mix contracts.check`; syntax success is not
  semantic verification.

## Covenant contract verification

Use the [Covenant skill](.agents/skills/covenant/SKILL.md) when adding or maintaining Covenant contracts in any Elixir application. Keep Covenant development/test-only (`only: [:dev, :test]`, `runtime: false`) and preserve existing test-helper behavior while including `Covenant.Formatter`. Contract obligations belong under each application's `contracts/` tree and tagged executable tests under `test/contract/`, with stable IDs `<mix_app>.<component>.I<n>`. Run static and runtime Covenant checks plus the application's normal precommit gate; protocol changes also require Marshall and Lilly consumer checks.

Covenant evidence is limited to behavior observable in the BEAM test VM. Do not use it to claim native Rust/KVM, physical isolation, multi-host recovery, browser, or production deployment guarantees. Preserve the existing `CONTRACTS`, ADR, native, machine, and integration evidence, and update architecture records when verification scope changes.

## Localization

- Use the [localization skill](.agents/skills/localization/SKILL.md) for every change involving user-facing strings, locale selection, translation catalogs, formatting, bidirectional presentation, or Elixir Localize integration.
- Before editing, inventory human-facing text and inspect the pinned Localize/Gettext APIs and existing catalogs. Preserve stable source identifiers and machine-facing contracts; do not invent a parallel translation-key system.
- Centralize typed locale validation, canonicalization, browser negotiation, fallback, and direction. Validate user overrides and keep them isolated per account/session. Bundle deterministic locale data and test malformed input, fallback, placeholders, plural rules, RTL layout, and catalog completeness.
- Update architecture evidence when localization changes documented behavior, configuration, protocols, operations, or verification scope.
- Assign new messages to the feature domains documented in the localization skill; use native explicit domain APIs and keep catalogs per locale and feature. Only public `/docs/*` prose is translated.
