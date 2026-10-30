# ADR-0269: Buck2 is the build system; Nix supplies toolchains, pins and NixOS assembly

- ID: ADR-0269
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: build, Nix artifacts, verification, CI, developer tooling
- Supersedes: none
- Superseded by: none

## Context

Every Overalls artifact is built by one Nix flake: about 75 packages, about 298
checks, the `nixosConfigurations` and the images. Developers then repeat those
builds outside Nix with devenv, `mix precommit` in eleven projects, cargo and
npm. An audit on 2026-10-30 found:

- **No change-to-build mapping.** Nix knows derivation inputs, but nothing
  maps a changed file to the packages, checks and machine tests that depend on
  it, so no pull request runs a machine test (see
  [ADR-0270](0270-graph-driven-machine-test-selection.md)).
- **Duplicated build definitions.** The ten application names appear more
  than twenty times, there are six Rust toolchains and about twenty copied
  source filters, and `lilly-host-tools` has four definitions.
- **Coarse caching.** A Nix derivation is the unit of caching, so a one-line
  change in a crate or Mix project rebuilds the whole package. The development
  loops therefore bypass Nix and drift from the release builds.

The user decided on 2026-10-30:

- Buck2 is the only build entry point, with no `nix build .#…` compatibility.
- Nix keeps two jobs: it supplies toolchains and third-party dependencies
  from pins ([ADR-0267](0267-single-dependency-pin-registry.md)), and it is the
  library that Buck2 calls to assemble NixOS systems, images and machine tests.
- NixOS machine tests remain, run as Buck2 tests.

## Decision

1. **Entry point.** `tools/buck2` is the only supported way to build, test and
   check the repository. It runs the buck2 binary from the flake-pinned
   `buckCells` output and nothing from `PATH`.
2. **Cells from Nix.** `nix/buck/cells.nix` builds `buckCells` from
   `flake.lock`-pinned nixpkgs and the pin registry. It contains:
   - the pinned buck2;
   - the prelude, taken from that buck2's bundled prelude;
   - `toolchains.buckconfig`, which maps every tool name to its store path.

   The wrapper rebuilds `.buck-cells` when an input of `buckCells` may have
   changed, and kills the daemon only when the store path actually changes.
3. **Toolchains in action keys.** `toolchains//` defines each tool with a
   `nix_tool` target. It reads the store path from the `[nix]` configuration
   section at load time, so the path becomes a target attribute and part of
   every consuming action's key. A missing or non-store path fails loading.
4. **Ownership.** Every tracked file outside `docs/` is owned by a Buck2 target
   (`nix_owned`). BUCK files are covered by target hashes.
5. **Bootstrap.** Until each flake output moves to a Buck2 rule, it is built by
   a `nix_flake_attr` target.
   - It is `local_only` and never uploads to a cache.
   - It depends on all owned sources, so it reruns on any change.
   - It is not a compatibility layer: each target is deleted in the same
     change that moves its output, and the rule is deleted with the last one.
6. **Assembly boundary.** NixOS systems, images and machine tests are
   assembled by Nix from Buck2-built artifacts.
   - Assembly evaluates `builtins.getFlake` over a copied tree that contains
     only the declared sources.
   - It runs with `restrict-eval` enabled, so an undeclared Nix input is an
     evaluation error.
   - `getFlake` keeps the lock file's `follows`.
7. **First-party code.** First-party code moves from Nix derivations to Buck2
   rules language by language, following the approved migration plan:
   - Rust uses the prelude rules and reindeer.
   - Elixir uses Mix rules with release parity.
   - Go, JavaScript, Python and C follow.

   Nix keeps third-party builds that have no Buck2 equivalent: the kernels,
   firecracker, edk2, the guest bases and the SDKs.

Authorization: the user's 2026-10-30 instructions ("buck2 will be only way to
build, no nix backwards compatibility. we still want nixos machine tests via
buck2"; "build stuff with buck2 but supply dependencies for buck2 via nix") and
the approved migration plan.

## Alternatives

- **Keep Nix as the build system and add a file-to-check mapping.** This would
  give selection, but leaves derivation-sized caching and the duplicated
  developer builds. It also needs a second graph kept in step with the
  derivations.
- **Bazel with rules_nixpkgs.** It has a mature Nix integration, but no
  Starlark-native BXL for precommit, and it has no prior use here. The
  kangaroointernet repository already runs Buck2 with Nix-supplied toolchains.
- **Buck2 wrapping Nix builds (Nix as the build).** This keeps two build
  definitions per artifact. The user rejected backwards compatibility.
- **Toolchains from `PATH` (devenv).** Store paths would not enter action keys,
  so a toolchain bump could reuse stale cached outputs.

## Consequences

- One build graph serves releases, development, precommit and CI selection.
- Per-crate and per-project actions are cached, locally and later in NativeLink
  ([ADR-0272](0272-nativelink-remote-cache-and-execution.md)).
- Contributors and hosts need Nix to materialise the cells. Windows runners
  without Nix are limited to non-hermetic targets.
- buck2 snapshot releases move fast. Each bump is a `flake.lock` change, which
  selects every target.
- During the migration, bootstrap targets rebuild their flake attribute for
  any owned change. Nix's own cache keeps that cheap, but it is coarse.

## Invariants and verification

- `tools/buck2` execs only `.buck-cells/bin/buck2` from the pinned
  `buckCells`. Checked by its `@cc buck2-wrapper-pinned-cells` contract and by
  review.
- Each toolchain path is a store path read from configuration, and changing it
  changes the recursive target hash of every consumer. The M1 spike showed
  this with `-c nix.elixir=…` on `//buck/probes:elixir_version`; a Buck2 test will
  keep it.
- The prelude loads from a cell root symlinked into `/nix/store`, and globs and
  `uquery owner()` work through it (M1 spike).
- Every tracked file outside `docs/` has an owner: `buck/bxl/ownership.bxl`.
- An undeclared Nix read under assembly fails. The M1 spike showed
  `restrict-eval` refusing `/etc/hostname`, and `getFlake "path:…"` keeping
  `follows`. The `nix_assemble` regression test is planned for M3.
- **Failure case:** an action that reads a tool through `PATH`, or a store
  path that is not declared in the cells, would break hermeticity without
  failing. Rule reviews and the planned remote-execution workers, which have
  no ambient toolchains, are the backstops.

## Implementation evidence

- [cells.nix](../../../nix/buck/cells.nix) builds `buckCells`, exported from
  [flake.nix](../../../flake.nix). The [wrapper](../../../tools/buck2) and
  [.buckconfig](../../../.buckconfig) consume it.
- [toolchains/BUCK](../../../toolchains/BUCK) and
  [nix.bzl](../../../toolchains/nix.bzl) define the Nix tools. The
  [probe](../../../buck/probes/BUCK) runs the pinned Elixir through them.
- [buck/nix.bzl](../../../buck/nix.bzl) defines `nix_owned`, `owned_set` and the
  bootstrap `nix_flake_attr`. The root [BUCK](../../../BUCK) generates bootstrap
  targets from [bootstrap_attrs.bzl](../../../nix/buck/bootstrap_attrs.bzl),
  which [bootstrap-attrs.sh](../../../nix/buck/bootstrap-attrs.sh) regenerates.
- [ownership.bxl](../../../buck/bxl/ownership.bxl) checks file ownership.
- **M7 (Go, JavaScript, Python, scripts).** `buckCells` adds the go, node,
  esbuild, ruff, ty, pwsh and Chromium tools, plus pinned inputs: the
  Nix-vendored gh and git-lfs sources and modules (`go/`), the marvin
  `importNpmLock` tree (`npm/`) and one Python closure
  ([python.nix](../../../nix/buck/python.nix), `python/`) that devenv's prek
  hooks and the `python-static` Nix check now share.
  - [go.bzl](../../../buck/go.bzl) and [github.bzl](../../../buck/github.bzl)
    build gh and git-lfs for Linux, Windows, FreeBSD and illumos
    ([BUCK](../../../nix/domains/artifacts/guest/github/BUCK)). On 2026-10-30
    all eight binaries and `manifest.json` of `:release` were byte-identical
    to `.#tool-github-managed`, and both transport `go_test` targets passed.
  - [npm.bzl](../../../buck/npm.bzl) defines `npm_package` and
    `esbuild_bundle`. `//marvin:marvin` was byte-identical to the Nix marvin
    package, and `//marvin:check` (typecheck, tests, Firefox lint, Chromium
    smoke) passed. `//buck/probes:esbuild_bundle` exercises the single
    esbuild; Marshall's assets switch to it in M6.
  - [python.bzl](../../../buck/python.bzl) defines `//:py-static`, with one
    `[ruff/<path>]` sub-target per file. On a clean tree it and the prek
    `ruff-format`, `ruff` and `ty` hooks both passed. With a planted file,
    both reported the same three findings (F401, a format diff and
    `invalid-return-type`).
  - [checks.bzl](../../../buck/checks.bzl) defines `//:conflict-markers`
    (with per-file sub-targets), `//:package-input-lock`
    ([script](../../../scripts/check_package_input_lock.exs)) and
    `//nix:overalls-install-ps1`, which shares
    [its script](../../../nix/verification/tests/overalls-install-ps1.sh) with
    the Nix check. Planted markers and lock mismatches failed.
  - `tools/buck2 run //mila:journey-fixture` runs the same store path as
    `.#mila-journey-fixture` (`nix_store_run` over the bootstrap target).

- **M8 (precommit).** [precommit.bxl](../../../buck/bxl/precommit.bxl) selects
  the `precommit`-labelled checks that the changed files affect and builds
  them in one `ctx.build`. [tools/precommit](../../../tools/precommit) computes
  the files from git and is the devenv `precommit` command and the single prek
  hook ([devenv.nix](../../../devenv.nix)), and the `precommit` job in
  [ci.yml](../../../.github/workflows/ci.yml) runs it over the selected range.
  - `PrecommitInfo`, `repo_check` and `contract_check` are in
    [checks.bzl](../../../buck/checks.bzl). The root [BUCK](../../../BUCK) adds
    `//:adrs`, `//:contracts` (with `[contracts/<path>]`), `//:contracts-tests`,
    `//:pins`, `//:rust-lints`, `//:toolchain-versions` and ten
    `//:logging-<app>` targets; `//:py-static` gains `[ty]` and `[fix/<path>]`.
  - `buckCells` adds git and the `tools/code-contracts` `importNpmLock` tree,
    which [check_contracts.mjs](../../../scripts/check_contracts.mjs) reads
    through `OVERALLS_CODE_CONTRACTS_NODE_MODULES`; its `files <path>` mode
    checks one file with its ancestor `CONTRACTS`
    ([test](../../../scripts/test/check_contracts_test.mjs)).
  - On 2026-10-30 a planted conflict marker, ruff violation, unknown ADR
    reference and lock mismatch each failed exactly the expected check, and
    the [migration review](../reviews/2026-10-30-buck2-migration.md) records
    the selections and timings.
- [nix/assemble](../../../nix/assemble/default.nix) is `lib.assemble`.
  - It holds the single package set and its parameterised variants. Today
    these are the default set and the host set with private service roots.
  - The module set is instantiated over that package set in
    [modules.nix](../../../nix/assemble/modules.nix).
  - It also builds the host systems, kexec and the machine-test catalog.
  - The flake's `nixosConfigurations`, `nixosModules`, `checks` and
    `host-kexec` are now views of it. For the same revision, all six host
    systems have the same drvPaths as before.
- The antithesis harness takes lib.assemble's package-set constructor instead
  of importing the set four times; its 21 contexts are drvPath-identical.
- The OTLP receiver and Enrico's git-owner helper are built once in the
  package set and taken from `packages` by the ziggy, underclass, enrico and
  otel-guest modules. Previously each module built its own copy with the
  system's nixpkgs.
- Encrypted-crash-dump variants are part of the same set. Buck2 supplies them
  as `encrypted-<app>` artifacts. An assembly assertion
  (`host-params-match-artifacts`) refuses a host that enables encrypted dumps
  for an application whose plain release is a Buck2 artifact when no
  encrypted artifact exists.
- Imported artifacts keep their own store-path references:
  `selfReference` is rewritten from the build placeholder to the import's
  `$out`, with lengths checked.
- [import-artifact.nix](../../../nix/assemble/import-artifact.nix) re-records
  the runtime references of imported artifacts. The leaf hook in
  [default.nix](../../../nix/domains/artifacts/default.nix) swaps Mix
  releases for Buck2 artifacts.
- [assemble.bzl](../../../buck/assemble.bzl) defines `nix_store_import`,
  `nix_assemble` and `RuntimeRefsInfo`; the script is
  [nix_assemble.sh](../../../buck/nix_assemble.sh).
- The probes in [buck/probes](../../../buck/probes/BUCK) and the
  [soundness BXL](../../../buck/bxl/assemble_soundness.bxl) show:
  - an imported artifact keeps its declared reference (bash);
  - `packages.hostTools` assembles under `restrict-eval`;
  - a tree that omits `nix/` fails to evaluate.

Remaining gaps, by milestone of the migration plan:

- rust-overlay toolchain and Rust and Elixir rules (M5, M6);
- the remaining M3 items:
  - moving the logging, fleet-exporter, trace-spool and fleet-test builds
    into the package set (the ziggy, underclass, enrico and otel-guest
    builds already moved);
  - deployment and machine-test targets on `nix_assemble` (M2, M4a);
- M7 leftovers:
  - The flake leaves stay. Guest images, the Marshall and Ziggy modules and
    the module-configuration test consume `githubTools` and `marvin`
    through Nix until assembly takes Buck2 artifacts (M3).
  - The `marvin`, `python-static`, `conflict-markers`, `package-input-lock`
    and `overalls-install-ps1` checks stay in the flake until M11, and
    `mila-builds.yml` still runs `nix build .#mila-journey-fixture`. CI calls
    the Buck2 targets once the `ci.yml` from M4a exists.
  - `nix-compact-*` and `fleet-builds-configuration` evaluate NixOS
    configurations rather than run scripts. They stay bootstrap
    `//:check-*` targets until `nix_assemble` (M3).
  - Buck2 globs see untracked files, while prek and the Nix checks see only
    tracked files. `py-static` therefore also checks untracked Python.
- removal of the flake package, check and configuration outputs (M11);
- Darwin cells and the Windows mode without Nix (M9);
- the `publish-cache.yml` gates job, which reaches Buck2 through
  `prek run --all-files` and still repeats the ADR and contract steps that the
  `ci.yml` precommit job now runs;
- M8 leftovers: each project's `mix precommit` (compile, format, tests,
  Covenant, Dialyzer, gettext, Marshall's extra gates) stays, and CI keeps its
  matrix, until the M6 Mix rules provide `precommit` sub-targets; the Rust
  `rustfmt`/clippy sub-targets come with M5.

## Open questions

None. The spikes resolved symlinked cells and `getFlake` with `restrict-eval`.
Selection uses Buck2's own target hashes, because buck2-change-detector is not
packaged in nixpkgs ([ADR-0270](0270-graph-driven-machine-test-selection.md)).

## Related decisions

- [ADR-0267](0267-single-dependency-pin-registry.md) defines the pins that
  `buckCells` consumes.
- [ADR-0270](0270-graph-driven-machine-test-selection.md),
  [ADR-0271](0271-buck2-host-self-deployment.md),
  [ADR-0272](0272-nativelink-remote-cache-and-execution.md) and
  [ADR-0273](0273-single-rust-workspace-and-toolchain.md) build on this
  decision.
- [ADR-0144](0144-nix-builds-exclude-guest-datasets.md),
  [ADR-0188](0188-signed-overalls-cachix-substitution.md),
  [ADR-0189](0189-cachix-watch-store-publishing.md) and
  [ADR-0248](0248-fleet-build-scheduling.md) cover the Nix stores and caches
  that assembly keeps using.
- [ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md) builds Mila checks
  in Nix. Those move to Buck2 targets in M9, and a superseding record follows
  then.
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
