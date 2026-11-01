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
- [buck/nix.bzl](../../../buck/nix.bzl) defines `nix_owned` and `owned_set`.
  The bootstrap `nix_flake_attr` rule is deleted: no Buck2 target evaluates
  a flake output. The root [BUCK.v2](../../../BUCK.v2) declares
  `//:package-<name>` and `//:check-<name>` as `nix_assemble` targets (label
  `flake_output`) over lib.assemble's `outputPackages` and `checks`, listed
  in [assembly_attrs.bzl](../../../nix/buck/assembly_attrs.bzl), which
  [assembly-attrs.sh](../../../nix/buck/assembly-attrs.sh) regenerates and
  `//buck:assembly_attrs_fresh` checks. They take `ASSEMBLY_ARTIFACTS` like
  hosts and machine tests. The seven script checks with Buck2 rules of their
  own (`py-static`, `conflict-markers`, `pins`, `rust-lints`,
  `package-input-lock`, `overalls-install-ps1`, `//marvin:check`) have no
  assembly twin.
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
  - `tools/buck2 run //mila:journey-fixture` runs
    `//:package-mila-journey-fixture` (`nix_store_run` over its assembly).
    The fixture alone assembles without Buck2 artifacts, so its drvPath is
    the flake's: the plain Ubuntu runners in `mila-builds.yml` substitute it
    from Cachix, where `publish-cache.yml` puts it, and have no Namespace
    cache to supply Buck2 leaves. `mila-builds.yml`'s Linux, Android emulator and tailnet journey
    jobs build `//mila:journey-fixture` with `tools/buck2`, gate on that
    target rather than the flake, and start the fixture from its store path.
  - `nix-compact-core`, `-native`, `-native-host`, `-configuration` and
    `fleet-builds-configuration` are `//:check-*` assemblies. On 2026-10-31
    their `[drv]` evaluated under restrict-eval with the same drvPaths as the
    flake checks.

- **M8 (precommit).** [precommit.bxl](../../../buck/bxl/precommit.bxl) selects
  the `precommit`-labelled checks that the changed files affect and builds
  them in one `ctx.build`. [tools/precommit](../../../tools/precommit) computes
  the files from git and is the devenv `precommit` command and the single prek
  hook ([devenv.nix](../../../devenv.nix)), and the `precommit` job in
  [ci.yml](../../../.github/workflows/ci.yml) runs it over the selected range.
  - `PrecommitInfo`, `repo_check` and `contract_check` are in
    [checks.bzl](../../../buck/checks.bzl). The root [BUCK.v2](../../../BUCK.v2) adds
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

- **M6 test shards.**
  - `mix_test` runs a suite as separately cached shard actions
    ([mix.bzl](../../../buck/mix.bzl), contract `mix-test-sharded` in
    [buck/CONTRACTS](../../../buck/CONTRACTS)). Each shard has its own
    sandbox and PostgreSQL, and its tree holds only its own test files, so
    one test file's change reruns one shard. Files are assigned by a stable
    hash of their path, and the slow ones in `test_shard_weights` go
    heaviest-first to the lightest shard. The weights come from the shards'
    `--slowest-modules` reports, via
    [mix_test_weights.py](../../../buck/mix_test_weights.py). Marshall runs 16
    shards at `+S 2:2`, replacing the blanket `+S 4:4`, and each action
    weighs its scheduler count. Its validator tests (`test/architecture/`)
    form a `[repository]` shard, the only one that depends on
    `root//:mix_repository`. `:check` no longer depends on it either.
    `[covenant]` checks the union of the shards' Covenant results, and
    `[shard_plan]` maps shards to files.
  - Known Inception failures (AGENTS.md) run in a `[known_failures]` shard
    instead of being excluded (contract `mix-test-known-failures`):
    - `Marshall.Compute.InceptionTest` and `Audi.Inception.AuthorityTest` run
      there whole;
    - MachinesLiveTest's single "Inception selection…" test runs there by
      name, and the rest of its file stays in the blocking shards;
    - any other failure fails the shard;
    - known.txt marks each entry failing or now passing, and ci.yml's `mix`
      job prints it under "known Inception failures".
  - Seeds (contract `mix-test-seeds-explicit`, `_mix_test_seeds` in
    [mix_phases.sh](../../../buck/mix_phases.sh)). Every seed comes from the
    action's inputs, so a cached verdict is the one a fresh run would reach.
    - Every shard selects Hegel's `ci` profile (`CI=true`; the sandbox
      clears the environment), with `HEGEL_DATABASE=disabled`. That profile
      suppresses the wall-clock TooSlow health check, which failed Lilly's
      fresh-boot properties under load.
    - One seed drives both `--seed` and `HEGEL_SEED`: the 32-bit FNV-1a
      hash of the salt and the shard's input digest (SHA-256 over every file
      of its source tree and its test arguments). A cache hit replays exactly
      the draws of the run that recorded it, and every changed input explores
      new draws.
    - `-c mix.test_salt=<salt>` changes every shard's action key, so the run
      explores new draws and can be replayed.
      `HEGEL_SEED` reaches BEAM properties from hegel-erlang `44b4c8e`;
      before it, the NIF cleared the seed.
    - Each shard log starts with its salt and seeds, and a failing shard
      prints a reproduction command.
    - [mix-nightly-seeds.yml](../../../.github/workflows/mix-nightly-seeds.yml)
      reruns every `mix_test` target daily with the salt `nightly-<UTC date>`
      (contract `mix-nightly-fresh-seeds`).
  - `//buck:mix_test_failure_uncached` now runs its fixture in two shards.
  - ci.yml's `mix` job builds the affected suites on at most two runners:
    Marshall, and the rest. It also runs on same-repository pull requests,
    and fork pull requests run nothing.
  - Timings on panterloons (96 threads): a cold 16-shard Marshall run at
    `+S 4`, before the weights existed, finished 12 shards in 200–1045 s
    with a hash-only tail past 50 minutes; the weights come from those
    shards, and the weighted plan's heaviest shard is estimated at about
    20 minutes. A measured cold and warm wall time is still open.

- **M6 (Elixir).** [mix.bzl](../../../buck/mix.bzl) defines `mix_sources`,
  `mix_compile`, `mix_release`, `mix_check`, `mix_test` and
  `mix_release_probe`, plus the `overalls_mix_project` macro used by every
  project's `BUCK`. Their contracts are in [buck/CONTRACTS](../../../buck/CONTRACTS).
  - The `[mix]` cells section carries the prod fixed-output dependency sets,
    new test-environment sets (keyed `<project>Test` in
    [dependency-hashes.json](../../../nix/domains/artifacts/dependency-hashes.json)),
    the encrypted-crash-dump OTP, the Hegel NIF (`hegelNifCargo`), esbuild,
    PostgreSQL and a `runtime_refs` closure.
  - Actions source the shell state captured from a real `beam.mixRelease`
    ([mix.nix](../../../nix/buck/mix.nix)), so the release runs nixpkgs' own
    hooks and fixup. They run in a bubblewrap sandbox
    ([mix_sandbox.sh](../../../buck/mix_sandbox.sh)) that mirrors the Nix
    sandbox's `/build` layout, because Spark and Mix embed build paths.
  - Each `//<app>:release` names itself by a zero-hash placeholder, and
    `//<app>:<app>_import` imports it with that `self_reference`.
  - Parity on 2026-10-30, after `importArtifact`, against
    `nix build .#service-<app>` at the same revision:
    - audi, brady, enrico, galileo, lilly, peach, porsche, susan and ziggy
      are NAR-identical once the store path is normalised, and their
      `nix-store -qR` closures and references are equal;
    - Marshall's closure and references are equal. With the vendor remap
      from 9619afe9f, neither side retains the Cargo vendor, and the cells'
      `runtime_refs` no longer list it, so the rule refuses it too. Its tree
      differs only where the Nix build is itself not reproducible:
      `nix-store --check` of the Nix release changes the same four beams
      (Cinder.Collection, MarshallWeb.MachinesLive, MarshallWeb.ThreadsLive,
      Tz.PeriodsProvider: atom, literal and fun tables) and
      `cache_manifest.json`. `sys.config` matched once the release action
      sets the builder's `TERM`, which decides its map order.
  - Two clean Marshall builds in separate isolation directories differed
    only in those four beams. Their causes were in two dependencies, which
    [marshall/dep_patches](../../../marshall/dep_patches) fixes before
    compilation (contract `mix-dep-patches`; the Nix release applies the
    same patches, but has not been rebuilt to compare): Phoenix
    LiveView's engine emitted change tracking in the order of maps keyed by
    atoms, which follows atom creation order and so the parallel compiler's
    schedule, and tz stamped `compiled_at` with the wall clock. On
    2026-11-01 two clean `//marshall:release` builds (`--no-remote-cache`,
    isolation directories `det1` and `det2`) were byte-identical: 8772
    files, one aggregate `sha256sum` 16f5ccd109f953bb. Their
    `//marshall:compile` trees still differ in the `Dbgi` (debug info) or
    `ExCk` (type checker) chunk of 12 dependency beams, which the release
    strips, so they affect only the cache keys of checks and tests. `phx.digest` stamps `cache_manifest.json` with the
    build time; Nix keeps it, and Buck2 pins it to `SOURCE_DATE_EPOCH`.
  - `buck2 test` passes for protocol (cold 15m25s, mostly its 900 s
    property suite; warm 0.2 s from the action cache), peach, susan,
    porsche, request_accounting and diagnostics. Suites read sibling fixtures
    through declared `mix_sources` and take openssl, ssh-keygen, python3 and
    Enrico's git-owner helper from the cells instead of the developer PATH.
    `mix_test` patches the shebangs under `test/`, because the sandbox, like
    Nix's, has no `/usr/bin/env`, and binds the cells' CA bundle at the OS
    trust-store path that `:public_key.cacerts_get/0` reads. Marshall's
    suite also takes the cells' Lilly host tools on PATH, as devenv does.
    That is where its Lilly connector fixture finds the private
    `lilly-hostd`. The Dialyzer PLT and check run with
    `--no-compile`: Dialyxir reloads dependencies after its own `compile`,
    and recompiling a path dependency (Hegel) prunes the code path, which
    drops OTP `extra_applications` such as `:ssh`.
  - Buck2 leaves a local action's process tree running when its daemon
    exits. [mix_sandbox.sh](../../../buck/mix_sandbox.sh) therefore kills
    bwrap, and with it the sandbox's PID namespace, once the script is
    reparented. Otherwise a survivor writes into a scratch path that the next
    daemon reuses. The
    [orphan test](../../../buck/tests/mix_sandbox_orphan.py)
    (`//buck:mix_sandbox_orphan`) fails without this.
  - A failed suite fails the `mix_test` run action itself, which prints the
    log tail. Buck2 caches only successful actions, so neither the daemon
    nor a shared cache can replay a flaky failure as a result. Only passing
    runs reach `[test_result]`. The
    [failure test](../../../buck/tests/mix_test_failure_uncached.py)
    (`//buck:mix_test_failure_uncached`) builds a deliberately failing
    fixture suite twice on one daemon, and both builds must fail.
- [nix/assemble](../../../nix/assemble/default.nix) is `lib.assemble`.
  - It holds the single package set and its parameterised variants. Today
    these are the default set and the host set with private service roots.
  - The module set is instantiated over that package set in
    [modules.nix](../../../nix/assemble/modules.nix).
  - It also builds the host systems, kexec and the machine-test catalog.
  - [outputs.nix](../../../nix/assemble/outputs.nix) holds the flake's
    package outputs (`outputPackages`) and its non-script extra checks, which
    join the catalog in `checks` (contract `assembly-flake-outputs`). On
    2026-10-31 all 89 flake packages, the moved checks and the dungarees
    toplevel kept their drvPaths when they moved there.
  - The flake's `nixosConfigurations`, `nixosModules`, `packages`, `checks`
    and `host-kexec` were views of it, with the same drvPaths for all six
    host systems. M11 removed every view but `nixosModules`: the flake now
    exports only `buckCells`, `lib.assemble`, `lib.dependencyPins` and
    `nixosModules` (contract `flake-exports-pins-and-assembly` in
    [flake.nix](../../../flake.nix)). `buckCells` and the pin builds kept
    their drvPaths across the removal.
- The antithesis harness takes lib.assemble's package-set constructor instead
  of importing the set four times; its 21 contexts are drvPath-identical.
- First-party builds are made once, in the package set, and modules take them
  from `packages` (contract `package-set-first-party-builds` in
  [default.nix](../../../nix/domains/artifacts/default.nix)).
  - The OTLP receiver (`otelReceiver`) serves the ziggy, underclass, enrico,
    otel-guest and otel-fleet modules: storage, service levels, request
    recorder, request sources and browser probes.
  - `observabilityRuntimes` serves the logging and fleet-exporter modules.
  - `traceSpool` is the default trace-spool package.
  - `enricoGitOwner` serves the enrico module.
  - The machine tests (fleet, otel-fleet, otel-request-recorder, trace-spool
    and the request-source fixture) and the antithesis harness use the same
    builds.
  - Previously each module built its own copy with the system's nixpkgs.
    Enrolled hosts now carry one Rust toolchain's builds instead of two. The
    `-base` systems are drvPath-identical.
  - The logging and request-recorder modules take `{ packages }` and set a
    module `key`, so importing them more than once still yields one
    instance, as the path imports did.
- Fluent Bit is a patched nixpkgs package, not a first-party build. It stays
  on the system's nixpkgs: building it in the package set would move hosts
  from the reviewed 5.0.x to buildNixpkgs' 5.1.x (contract
  `logging-chunked-input-routes`).
- Encrypted-crash-dump variants are part of the same set. Buck2 supplies them
  as `encrypted-<app>` artifacts. An assembly assertion
  (`host-params-match-artifacts`) refuses a host that enables encrypted dumps
  for an application whose plain release is a Buck2 artifact when no
  encrypted artifact exists.
- Per-target parameters reach lib.assemble through `nix_assemble`'s `params`
  (a host's `fleet_host(params = ...)`). lib.assemble refuses unknown keys,
  wrong types and paths outside the repository (contract
  `assembly-params-validated`; `//buck:assembly_params`), and absent keys keep
  the fleet-wide defaults ([ADR-0271](0271-buck2-host-self-deployment.md)).
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
- Every machine test's `nix_assemble` receives `ASSEMBLY_ARTIFACTS`
  ([artifacts.bzl](../../../buck/artifacts.bzl)), the merge of the Rust
  ([rust_artifacts.bzl](../../../buck/rust_artifacts.bzl), M5) and Mix
  ([mix_artifacts.bzl](../../../buck/mix_artifacts.bzl), M6) imports, so a
  leaf switched there is what the tests run. Host deployments are to read the
  same dict (M2). The package set
  ([default.nix](../../../nix/domains/artifacts/default.nix)) refuses an
  artifact name it does not consume, so a misspelt key cannot silently leave
  the Nix build in place. M5 switched five Rust leaves there (the Lilly host
  helpers, Enrico's git owner, the guest telemetry receiver,
  observability-runtimes and the trace spool); each has a `heavy`
  `rust_leaf_parity_test` against its Nix build.

- M9 (partial) builds the Mila platforms as Buck2 targets
  ([mila/BUCK](../../../mila/BUCK), [mila.bzl](../../../buck/mila.bzl)).
  Xcode, Gradle and .NET are `non_hermetic` targets: they run the platform
  SDK from the daemon's environment, are `local_only` with
  `allow_cache_upload = False`, and are compatible only with
  `-c overalls.non_hermetic=true` and their host OS (the Android targets
  with Linux or macOS, through a select over the OS constraints), so `buck2 build //...`
  and [affected.bxl](../../../buck/bxl/affected.bxl) skip them. Their
  third-party inputs are pinned by Gradle dependency verification metadata
  and NuGet `packages.lock.json` in locked mode; the Swift packages have no
  dependencies. Those locks are no Nix inputs, so `check_pins`
  ([pins.ex](../../../scripts/pins.ex) `platform_locks`, tested in
  [pins_test.exs](../../../marshall/test/architecture/pins_test.exs)) refuses
  a platform project that restores without them. `buckCells.aarch64-darwin`
  evaluates and keeps the host tools; Linux-only tools become a stub there.
  `tools/buck2 --no-nix` downloads the buckCells buck2 release and prelude,
  verified against the pin registry, and enables only `non_hermetic`
  targets; [no-nix.nix](../../../nix/buck/no-nix.nix) fails when those pins
  stop matching the buckCells buck2. A hermetic `//mila:windows-ffi-gnu`
  cross-build and Clippy check run on Linux. Since 2026-11-01 (the user's
  decision) that gnu DLL, not an MSVC build, is the shipped Windows FFI
  artifact: see the reproducible Windows FFI DLL evidence below.
  `mila-builds.yml` builds Apple, Android and Windows through these
  targets, and `mila-release.yml` builds its source bundles and Linux tarball
  through `//:package-tool-mila-*`, the Android APK through
  `//mila:android-release`, and the Apple FFI and signed apps through
  `//mila:apple-ffi` and `//mila:<platform>-release`, with a check that no
  signing value reaches a Buck2 log, buck-out or the daemon's files. Runs
  without a pushed `mila-v*` tag (dispatch, or trunk pushes touching
  `mila/native/**` or `mila/BUCK`) build the unsigned APK and the ad-hoc
  `//mila:<platform>-unsigned` DMG and IPA instead, outside the
  `mila-release` environment, and never publish.
  Since 2026-11-01 the Android targets build on Namespace macOS runners with
  `tools/buck2` over `buckCells.aarch64-darwin`, as the Apple targets do:
  `mila-builds.yml`'s `android-native` on `cached-arm64` and
  `mila-release.yml`'s `android` on the uncached `release-arm64`. The
  emulator instrumentation and the hermetic journey fixture need KVM, which
  an Apple Silicon macOS VM lacks, so the Linux `android-emulator` job runs
  the macOS-built APKs (an artifact checked against its `SHA256SUMS`).
  The `cached-arm64` image runs macOS 27 with Xcode 27. There, rustc's
  release debuginfo strip of a proc macro built for the 15.0 deployment
  target leaves a dylib that dyld rejects, so `//mila:<platform>-dev` failed
  with E0463 for `thiserror_impl`.
  [build.sh](../../../mila/native/apple/build.sh) therefore leaves host units
  unstripped through `CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false`.
  Local evidence: the Android targets build and pass
  their unit tests, the Windows gnu targets build, and `--no-nix` loads and
  tests a non_hermetic target on Linux. CI run 41114668466 built every
  Apple, Android and Windows target; the review records the runs and the
  two faults the first one found.

- Tracked and untracked files (M7, settled in M11). Buck2 globs see
  untracked files. The commit hook (`tools/precommit`), CI and the former
  flake checks used to differ here, but the hook and CI now run the same
  Buck2 checks, so they see the same files. `py-static` is not restricted to
  `git ls-files`. An action that read Git state would leave its key without
  that input or make it depend on the index, and either would break caching.
  The remaining effect is local only: ty's whole-tree pass also checks
  untracked Python in a developer's checkout. A clean CI checkout has none.
- M11 (partial) generates the tests README "Find a test" table from the
  graph: [docs.bxl](../../../buck/bxl/docs.bxl) lists every machine test and
  assembled check, joins the curated text in
  [find_a_test.bzl](../../../nix/verification/tests/find_a_test.bzl) and fails
  on a key that names no target; [tools/docs](../../../tools/docs) writes the
  table and `tools/docs --check` fails on a stale README.
  The Project Glasswing (Anthropic OSS Scanner) image builds only through
  Buck2: `container_image` ([container_image.bzl](../../../buck/container_image.bzl),
  driver [container_image.py](../../../buck/container_image.py)) declares
  `//.oss-scanner:image` (build, load into the local image store and scan
  every layer for the Namespace token prefix) and the `buck2 run` target
  `//.oss-scanner:image-publish` (push with the registry layer cache, then
  pull back and scan). They run `docker buildx` with the builder in the
  environment, so like the Mila platforms they are `non_hermetic`, Linux
  only, `local_only` and uncached; `oss-scanner.yml` calls them through
  `tools/buck2` with Namespace's remote BuildKit builder and publishes only
  from trunk. The Marshall release is a Buck2 dependency
  (`//:package-service-marshall`) whose closure the driver exports as a Nix
  binary cache and passes as a named build context; the Dockerfile imports
  it with `nix copy`. Building it inside the image (92b89ea0e) could not
  work: Lyra's cross-build actions run bubblewrap, which an unprivileged
  BuildKit step cannot start, and it would have put Buck2 state in a layer.
  The image stays a Dockerfile rather than a `lib.assemble` dockerTools
  output: it must carry the checkout's full `.git` history, which a flake
  source never contains, and a mutable single-user Nix with a registered
  store database that the offline auditor's own layer extends
  ([.oss-scanner/CONTRACTS](../../../.oss-scanner/CONTRACTS)). The scan's
  fixtures are `//buck:container_image_scan`.

Remaining gaps, by milestone of the migration plan:

- the Rust leaves not yet on Buck2 (terminald, the broker, Lyra, the Cedar
  NIF, Mila) (M5);
- M6 leftovers:
  - Assembly still uses `beam.mixRelease`
    ([source.nix](../../../nix/domains/artifacts/applications/source.nix))
    until the coordinator switches each application to its
    `<app>_import`; both stay until every consumer moves.
  - The six fleet fixtures built with `overrideAttrs` need
    `release_variants`.
  - Marshall's dev `assets.setup` alias still calls `esbuild.install`;
    Buck2 builds use the cells esbuild. Changing `mix.exs` would change the
    Nix release before the switch.
  - Mix actions need unprivileged user namespaces, so they run locally only
    until remote workers provide them (ADR-0272).
  - `mix_check`'s `PrecommitInfo` is per file kind, not per file
    ([mix.bzl](../../../buck/mix.bzl), contract mix-check-precommit): a
    changed test module builds `[format]` alone and top-level prose nothing,
    but any other change runs the whole check, because every check reads the
    compiled project. `mix_test` has no provider, so a change in a project
    runs its shards, and `mix format` has no `[fix/<path>]` sub-targets.
  - Lilly's suite passes in the sandbox and is a precommit check, but two
    host reads stay outside the action key: `test_host_cgroup` binds
    `/sys/fs/cgroup` read-only for the collector, and `test_host_identity`
    binds `/etc/machine-id` and leaves `/nix/store` the read-only host
    store, so the uid-0 ownership checks see the overflow uid that test
    builds alone accept (`Lilly.Host.RootOwner`, contract
    root-owner-exact-in-production).
  - Marshall's compile tree (not its release) keeps 12 dependency beams
    whose `Dbgi` or `ExCk` chunk follows the parallel compiler's schedule.
  - The known Inception failures run in the `[known_failures]` shards of
    `//audi:test` and `//marshall:test`, as above, not excluded.
  - Within one shard every property without a `seed:` starts from the same
    HEGEL_SEED, because hegel_ex sets no per-property database key. A
    per-property key would also enable the engine's `.hegel/examples` replay
    database; that is an upstream hegel_ex follow-up.
- M7 leftovers:
  - The flake leaves stay. Guest images, the Marshall and Ziggy modules and
    the module-configuration test consume `githubTools` and `marvin`
    through Nix until assembly takes Buck2 artifacts (M3).
- M9 leftovers: `mila-release.yml`'s signed Buck2 builds, Android signing
  and signing-leak checks have not run: the repository has no `mila-release`
  environment or signing secrets yet, and its publish job creates a public
  release, so no test release was made (its unsigned Android and Apple
  builds run without a tag); its legacy Flutter Windows job is unchanged;
  the
  Robolectric `android-all` jar Gradle downloads at test time is outside the
  verification metadata. (The gap "the gnu Windows DLL is a check, not a reproducible
  artifact" is closed; see the next item);
- the reproducible Windows FFI DLL (implemented, 2026-11-01): the user
  decided that the gnu DLL, cross-built on Linux, is the published Windows
  FFI artifact. [mila.bzl](../../../buck/mila.bzl) `mila_windows_ffi` builds
  it with the single toolchain's rustc (ADR-0273), cargo-zigbuild and zig in
  a clean environment with `SOURCE_DATE_EPOCH=0`, which zig's lld writes as a
  zero PE `TimeDateStamp` (`zig cc` refuses `-Wl,--no-insert-timestamp`),
  and remaps the vendor, checkout and Cargo target paths.
  [mila/BUCK](../../../mila/BUCK) adds `:windows-ffi-gnu-rebuild`, an
  independent local, uncached build in other output and target directories;
  `:windows-ffi-gnu-reproducible` fails unless both DLLs are byte-identical,
  and `:windows-ffi-gnu-abi` ([mila_windows_dll.py](../../../buck/mila_windows_dll.py))
  parses the PE file and fails unless its `mila_*` exports equal the
  hand-written `include/mila_ffi.h` (cbindgen cannot produce it, see the
  review), every .NET `EntryPoint` is exported, it imports only system and
  API-set DLLs (no libgcc or winpthread), its COFF, export and debug
  timestamps are zero and it holds no build path.
  [mila-builds.yml](../../../.github/workflows/mila-builds.yml)'s Linux
  `windows-ffi` job runs those checks and publishes the DLL with its SHA-256;
  `windows-native` no longer installs Rust or builds a DLL. It verifies the
  download against that digest, and `//mila:windows-ffi-published` enforces
  it again (`-c mila.windows_ffi_sha256`) before `:windows-dotnet` stages it
  as `mila_native.dll` and `:windows-smoke` runs the production .NET interop
  against it. `:windows-ffi-msvc` stays only as a local fallback
  (`-c mila.windows_ffi=msvc`). Evidence: two local builds produced
  `04ef3b4227e7a578c4cac7036b5c8ffc6e2583bd2557847b22855cfa8c2453eb`; the
  CI run is recorded in the migration review. Release signing of the DLL
  and of the .NET client remains with `mila-release.yml`;
- the `publish-cache.yml` gates job, which reaches Buck2 through
  `prek run --all-files` and still repeats the ADR and contract steps that the
  `ci.yml` precommit job now runs;
- M8 leftovers: each project's `mix precommit` (compile, format, tests,
  Covenant, Dialyzer, gettext, Marshall's extra gates) stays, and CI keeps its
  matrix, until the M6 Mix rules provide `precommit` sub-targets. The Rust
  `<pkg>-rustfmt` and `<pkg>-clippy` checks exist for the Buck2-built crates
  (M5).

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
- [ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md) built Mila checks
  in Nix. M9 moved the native platform builds to Buck2 targets, and
  [ADR-0277](0277-mila-native-builds-on-buck2.md) supersedes it.
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
