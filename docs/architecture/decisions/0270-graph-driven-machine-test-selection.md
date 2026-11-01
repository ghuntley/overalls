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
`select-checks.sh` and `ci.nix` (both since deleted) selected by name and
feature, not by change. A regression in a module or application therefore lands on
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
- A service module change selects the suites that import it plus the 76
  machine tests that take the whole catalog (fleet variants and host
  installs). A change to a module every host applies (`auto-update`,
  `nix-compact`, `nix-cache`) still selects every `service` suite.
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
- A failure is not cleared by moving the base. A push run compares against
  the newest earlier started run, so a target that failed there and was not
  touched again would otherwise not run again. Every target whose job failed
  or timed out in a trunk push run since the newest green run is therefore
  selected again (contract `ci-reselect-failed`; `//buck:ci_failures` and the
  `affected_fixtures` "failed then untouched target is reselected" fixture).
- **Failure case:** a machine test whose Nix assembly reads a file it does not
  declare would not be selected. `restrict-eval` over a declared-only tree
  ([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)) makes that an
  evaluation error instead.

## Implementation evidence

- [ownership.bxl](../../../buck/bxl/ownership.bxl) and the `nix_owned` targets
  in [buck/nix.bzl](../../../buck/nix.bzl) give every tracked file an owner.
- The [toolchain probe](../../../buck/probes/BUCK) is the configuration-sensitive
  target from the M1 spike. [toolchain_hash.py](../../../buck/tests/toolchain_hash.py)
  (`//buck:toolchain_hash`) now asserts that substituting the elixir store path
  changes its recursive hash.
- **Machine tests are targets (M4a).** [buck/nixos.bzl](../../../buck/nixos.bzl)
  defines `nixos_machine_test`. [machine_tests.py](../../../buck/machine_tests.py)
  generated one `BUCK` per suite under
  [nix/verification/tests/machines](../../../nix/verification/tests/machines/BUCK)
  from `catalog.nix`: 204 targets (two are KVM evaluation checks outside `machines/`), 67 of them fleet variants whose flags are
  `params` and whose own scenario files are `srcs`
  ([scenarios.json](../../../nix/verification/tests/machines/fleet/scenarios.json),
  derived by evaluating each variant's composed script). Each target's inputs
  are its suite (for a fleet variant, the shared files and its own scenarios),
  the suites it references, `NIX_INPUTS` and, when it takes application
  packages, `PACKAGE_INPUTS` ([buck/inputs.bzl](../../../buck/inputs.bzl)). The
  macro builds `lib.assemble {}.checks.<name>` with `nix_assemble` over a copy
  of exactly those inputs under restrict-eval, so the build fails when the test
  reads an undeclared file; the test command then checks the labels.
- **Labels equal requiredFeatures.** The macro derives `nested_kvm` from the
  suite's `requiredFeatures.nested-kvm`, and `//buck:machine_tests_fresh`
  fails when a generated file is stale. Each run also compares the label with
  Nix's `meta.ci.nestedKvm`, and a fleet variant's declared scenarios with its
  composed script, and fails on a mismatch.
- **Selection.** [affected.py](../../../buck/affected.py) (`tools/affected`) and
  [affected.bxl](../../../buck/bxl/affected.bxl). Correction to decision 3:
  `--target-hash-modified-paths` only applies in `paths_only` mode, so the
  selector hashes full contents (`paths_and_contents`) on both sides, and it
  must pass `--target-hash-recursive=true`, without which a dependency's change
  leaves the hash unchanged. Rule files (`buck/*.bzl`) are not part of
  unconfigured hashes, so changing one selects everything, as the cells'
  inputs do. Selection takes about a second per side and builds nothing.
- **Fixtures.** [affected_fixtures.py](../../../buck/tests/affected_fixtures.py)
  (`//buck:affected_fixtures`): docs-only selects no machine test, and only
  repository-wide targets (the whole-tree flake checks and assembly probes,
  and the per-file conflict-marker and Python checks over every owned file);
  `flake.lock` selects everything; a `lilly/lib` change selects the
  package-taking suites and every fleet variant but not `sysctl`, `nix-ld` or
  `fleet-network`; one fleet scenario selects exactly the variants that read
  it; a deleted file resolves on base; an unowned file selects everything.
- **CI.** [ci.yml](../../../.github/workflows/ci.yml) runs on every trunk push
  and on dispatch. Pull requests are not possible under the trunk-only
  ruleset, so "each pull request" in decision 4 applies to each push. The
  daily backstop, [nixos-machine-tests.yml](../../../.github/workflows/nixos-machine-tests.yml),
  lists every target from the graph and keeps its `checks` dispatch input.
  When everything is selected (a change to the cells, toolchains or rule
  files), `ci.yml` runs the builds and tests but leaves the full machine-test
  set to that daily run unless dispatched with `machine_all`; about 200
  nested-KVM jobs per such push would exceed the runner pool. The same
  deferral applies when more than 40 suites are selected without everything
  (a `catalog.nix` or shared-module change, until M11 narrows module inputs):
  run 41059576724 fanned out about 200 jobs for an otel-fleet test fix. This
  is a capacity limit on decision 4, not a change of it; the deferred suites
  run daily, and dispatch with `machine_all` runs them at once.
  A push run also reselects, through `tools/affected --reselect`, every
  target whose job failed or timed out in a completed trunk push run since
  the newest green one, at most 50 runs back.
  [ci_failures.py](../../../buck/ci_failures.py) maps the failed job names to
  targets through each run's own `affected` artifact: `build <target>` names
  its host target, a machine job its suite, `test` and `build` their whole
  lists, and `evaluate N` its shard. An unreadable history is a selection
  error, so the `ci` job fails instead of passing on a narrowed set. A
  precommit failure is not mapped; its range runs again only when a later
  push touches it.
  Whole host systems build one target per runner in the `hosts` job. A host
  deployment realises about 130 GiB: substitutes of 107.6 GiB (the Windows
  Server image alone is 64 GiB raw) plus locally built guest images. That is
  more than the xl cache volume (about 116 GB free; Namespace caps volumes
  near 125 GB), and runs 41169053536 and 41194732683 failed with ENOSPC.
  Verifying substitutes instead of downloading them does not help: a new
  toplevel takes `overalls-images.json`, and so every image, in its input
  closure. The images are mostly zeros (27.2 GiB as zstd NARs), so every
  host job except the known-small `:base`, `:install` and kexec (a
  `:system` job hit the same ENOSPC in run 41257632603) keeps its store on a
  loop-mounted btrfs with forced zstd compression on the xl root disk (`nix-on-cache-volume: "false"` in
  [the devenv action](../../../.github/actions/devenv/action.yml)), still
  realising and publishing the complete closure. A 16x64 profile with a
  288 GB disk was tried first and dropped: it needs half the workspace's
  128 GB Linux memory and waited for capacity.
- **Executed:** `tools/buck2 test` of `sysctl` and `nix-ld` booted their VMs
  and passed; through `nix_assemble`, `sysctl` produced the same store path as
  the flake check, so the declared-only tree evaluates the same test.

- Precommit uses the same ownership for its own selection:
  [precommit.bxl](../../../buck/bxl/precommit.bxl) selects only
  `precommit`-labelled checks, never machine tests or `flake_output`
  assemblies.
- `ci.nix` and `select-checks.sh` are deleted. `publish-cache.yml` selects
  the `flake_output` `check` targets with a Buck2 query that loads targets
  only, deals them into shards (each `isolated_build` target alone) and
  builds them with `tools/buck2 build --keep-going` (contracts
  `cache-build-selection` and `ci-isolated-heavy-builds` in
  [buck/CONTRACTS](../../../buck/CONTRACTS)). It then realises every reported
  store path. Buck2 still looks up `local_only` actions in the remote action
  cache (observed in the event log), and only `allow_cache_upload = False`
  keeps those lookups missing; the realise step makes publication
  independent of that. The set is the former `meta.ci`
  build set minus the seven repository script checks, which are `ci.yml`
  tests. A machine test's command reads its features from lib.assemble
  ([machine_tests.py](../../../buck/machine_tests.py), contract
  `machine-test-required-features`) instead of `meta.ci`.

Remaining gaps:

- Module inputs are narrowed per module (M11). `NIX_INPUTS` names
  `//nix:base`, every `nix/` file except the NixOS modules under
  `domains/system` (it keeps the few files the package set reads there).
  The system catalog ([catalog.nix](../../../nix/domains/system/catalog.nix))
  names each module, and `modules.select` imports only the named ones in
  catalog order. A machine-test catalog entry passes `serviceOf [ … ]` (the
  service inputs with such a selection) instead of `service`.
  [machine_tests.py](../../../buck/machine_tests.py) generates one
  `//nix:module-*` group per module path a test can reach, holding the files
  under `domains/system` that path reads
  ([modules.bzl](../../../nix/verification/tests/machines/modules.bzl)), and
  gives each test the groups of the modules it selects, the module attributes
  it passes, and the module paths its suite, sibling suites and test helpers
  name. A test still declares `//nix:system_modules` when it reaches the whole
  catalog: `service`, `modules.default`, featureFleet or host fixtures, or a
  file that imports `catalog.nix` itself (contract
  `machine-test-module-inputs`). 128 of 204 machine tests narrow (153 took
  every module before); 76 still take every module: the 67 fleet variants and nine host-install,
  host-image and Inception tests, whose hosts are built from the production
  profile with the whole catalog. Three modules apply to every host unconditionally
  (`auto-update`'s deployment descriptor, `nix-compact`'s Nix and
  `nix-cache`'s substituters), so every selection includes them and a change
  to them still selects every narrowed `service` suite.
  Every selection reproduces its test's derivation exactly. On dungarees, at
  trunk `fed7f3e2b`, the 90 non-fleet machine tests that took every module,
  plus `fleet` and `audi-fleet`, were evaluated (`[drv]`) before and after
  over their declared-only trees: 85 drvPaths were identical, and the other
  five embed the repository's own sources (update fixture or project copy),
  which this change edits. Rebased on `70a83356c`, all 128 narrowed tests
  evaluated, and each of the 48 `serviceOf`/`modules.select` tests has the
  same drvPath as its whole-catalog variant in the same tree. `tools/affected` on a one-line change to `susan.nix` selects
  the suites that import it plus the whole-catalog ones (fixture
  `one service module selects only its importers and whole-catalog tests`).
  Fleet variants stay broad until their host fixture stops importing the
  whole catalog, which would change what they test.
  The first pass (parameters only) narrowed 51 suites. On 2026-11-01, at
  trunk `fed7f3e2b`, on Dungarees:
  - every narrowed suite's `.assembly[drv]` evaluated over its declared-only
    tree (51 of 51, 354 s);
  - ten of them ran in full: nix-ld, vm-watch, image-copy, source-export,
    ssh-host-certificates, audi-openssh, susan-image, brady-flow,
    database-recovery and zfs-io. The first nine passed. zfs-io built and
    then failed its capacity assertion (`driver.py:38`), which reproduces
    with local builders only. The failure is in Lilly's pool capacity report
    and is unrelated to narrowing.

  A suite that reads an undeclared file fails its first run, which the daily
  backstop surfaces. The other 41 narrowed suites have evaluated but not run.
- Release artifacts follow the package set. Once assemblies took the Mix
  releases from Buck2 (ADR-0269 M6), every machine test depended on every
  release import, so a `lilly/lib` change selected suites that take no
  application package (`affected_fixtures` failed on `sysctl`). A test now
  receives the Mix release artifacts only when its suite takes the package
  set, the condition that already declares `PACKAGE_INPUTS` (contract
  `machine-test-release-artifacts`). Seven tests take none: access,
  fleet-network, host-images, inception-ssh-host-ca, nix-ld,
  otel-burn-delivery and sysctl. Rust leaves and test fixtures still reach
  every test.
- Replays (2026-11-01). Two regressions reached trunk before graph
  selection. Their changes now select the suites that cover them, and two
  fixtures in
  [affected_fixtures.py](../../../buck/tests/affected_fixtures.py) keep it
  so:
  - `ab3816ebb`: a change to `lilly/lib/lilly/network/guest.ex` and to
    hostd's `policy.rs` selects all 206 machine tests, galileo-fleet and
    memory-suspension-fleet among them.
  - `8fab8c411`: a change to the fleet `scenarios/audi.py` selects exactly
    the six variants that declare it (audi-fleet, audi-relocation-fleet,
    audi-ubuntu-fleet, audi-ubuntu-relocation-fleet,
    memory-suspension-fleet and otel-audi-ssh-native).

  The same commit also changed `scenarios/enrollment.py`. Every fleet
  variant declares that file, so a change to it selects all 67, as it
  should.
- `catalog.nix` stays: it defines the checks that lib.assemble exposes and
  that the generator reads. Removing it means each suite's `BUCK` `params`
  instantiating its suite in lib.assemble, which belongs with the per-module
  targets of M11.
- Each push evaluates or builds every selected assembly exactly once. A
  successful build implies its evaluation. `ci.yml` therefore runs `[drv]`
  only for the machine tests outside its matrix (deferred, or known
  Inception failures) and for the `flake_output` packages. Machine tests in
  the matrix build their own assembly, and `publish-cache.yml` builds every
  `flake_output` check. Machine assemblies shard 20 per runner, because they
  realise guest images while evaluating (up to 32 minutes per shard in run
  41228962477). Package assemblies shard 45 per runner. For an
  everything-selected push this is 13 evaluate shards instead of 20; for a
  ten-suite push, 2 instead of 10.
- The known-broken Inception machine tests (`inception`, `inception-checkout`,
  `inception-ssh-host-ca`) are labelled `known_inception_failure`: `ci.yml`
  skips them, and the daily run reports them without failing. `zfs-guest` and
  `ubuntu-guest` stay required. `zfs-guest`'s driver skips its known-failing
  Inception subtest and logs the skip, without running it
  ([driver.py](../../../nix/verification/tests/machines/zfs-guest/driver.py)).

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md) defines the graph.
- [ADR-0033](0033-nixos-machine-verification.md) and its successors define
  NixOS machine verification. This record only adds the change-based choice of
  which tests run.
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
