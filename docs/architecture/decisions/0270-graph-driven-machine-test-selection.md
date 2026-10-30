# ADR-0270: Select pull-request builds and NixOS machine tests from the Buck2 graph

- ID: ADR-0270
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: verification, CI, build
- Supersedes: none
- Superseded by: none

## Context

About 200 NixOS machine checks, including 66 fleet variants, run only from
[nixos-machine-tests.yml](../../../.github/workflows/nixos-machine-tests.yml)
as a daily batch or on dispatch.
[select-checks.sh](../../../.github/scripts/select-checks.sh) and
[ci.nix](../../../nix/verification/tests/ci.nix) select by name and feature,
not by change. A regression in a module or application therefore lands on
trunk, and the daily run reports it later. Recent examples are the fixes in
`ab3816ebb` and `8fab8c411`.

The user decided on 2026-10-30 that every pull request runs the machine tests
affected by its change, chosen from the Buck2 build graph
([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)).

## Decision

1. **Machine tests are targets.** Every NixOS machine suite, and every fleet
   variant, is a `nixos_machine_test` target.
   - Its declared dependencies are the artifacts, modules and scenario files
     it uses.
   - Its labels include `nested_kvm` exactly when the suite requires that
     system feature.
2. **Ownership.** Every tracked file outside `docs/` has an owning target
   (`buck/bxl/ownership.bxl`). A changed file without an owner selects
   everything.
3. **Selection.** A changed target is one whose unconfigured target hash,
   computed with `--target-hash-file-mode=paths_and_contents` over the
   modified paths, differs between the base and head revisions.
   - Deleted and renamed files resolve against the base graph.
   - The affected set is the changed targets plus their reverse dependencies.
   - The output is JSON grouped as `machine_tests` (with labels), `tests` and
     `builds`.
   - Changes to `flake.lock`, the cells or `.buckconfig` change every
     toolchain hash, and so select everything.
4. **CI.** Each pull request and trunk push runs these jobs: affected, build,
   test, a machine-test matrix routed by label, and precommit.
   - The daily full run stays as a backstop.
   - Selection never forces a Nix derivation build, and it reports errors per
     target.

Authorization: the user's 2026-10-30 instruction ("trigger nixos machine
tests based off the changes made to buck2 build graph"), the answer that every
PR runs the affected machine-test set, and the approved migration plan.

## Alternatives

- **buck2-change-detector (BTD).** It implements the same comparison and
  handles more edge cases, but it is not packaged in nixpkgs and would be a new
  pinned Rust dependency. Buck2's built-in target hashes covered the M1 spike.
  BTD can replace the selector later without changing this decision.
- **Path globs per suite.** These are cheap, but they are another hand-kept
  list that drifts from the real dependencies, which is the problem the
  migration removes.
- **Nix derivation diffing.** Comparing `drvPath`s between revisions is exact
  for Nix outputs. It needs full evaluation of about 300 checks per revision
  with import-from-derivation, which costs minutes, and it says nothing about
  Buck2-built inputs.

## Consequences

- Pull requests catch machine-test regressions before trunk.
- Until modules have their own targets (M11), a module change selects about 60
  suites plus all the fleet variants. Selection is correct but broad.
- CI cost rises for changes that touch shared modules. The NativeLink cache
  and Nix's own substitution of passing test outputs reduce reruns.

## Invariants and verification

- Unowned files select everything, and ownership keeps the unowned set empty
  outside `docs/`: `ownership.bxl`.
- A content change to an owned file changes its owner's target hash. The M1
  spike showed this on a filegroup with `--target-hash-modified-paths`.
- A toolchain path change changes every consumer's recursive hash. The M1
  spike showed this with `-c nix.elixir=…`.
- Planned selection fixtures:
  - a docs-only change selects nothing;
  - a `flake.lock` change selects everything;
  - a `lilly/lib` change selects the Lilly-dependent tests and fleet variants;
  - a single fleet scenario selects only its variants;
  - a deleted file resolves against base;
  - replays of `ab3816ebb` and `8fab8c411`.
- The `nested_kvm` label equals the suite's `requiredFeatures`. A planned
  test checks this.
- **Failure case:** a machine test whose Nix assembly reads a file it does not
  declare would not be selected. `restrict-eval` over a declared-only tree
  ([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)) makes that an
  evaluation error instead.

## Implementation evidence

- [ownership.bxl](../../../buck/bxl/ownership.bxl) and the `nix_owned` targets
  in [buck/nix.bzl](../../../buck/nix.bzl) give every tracked file an owner.
- The [toolchain probe](../../../buck/probes/BUCK) is the configuration-sensitive
  target from the M1 spike; the [migration review](../reviews/2026-10-30-buck2-migration.md)
  records the content-hash results.

Remaining gaps:

- `nixos_machine_test` and the per-suite BUCK files (M4a);
- `buck/bxl/affected.bxl` and its fixtures;
- the CI workflow, and deleting `catalog.nix`, `ci.nix` and `select-checks.sh`.

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md) defines the graph.
- [ADR-0033](0033-nixos-machine-verification.md) and its successors define
  NixOS machine verification. This record only adds the change-based choice of
  which tests run.
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
