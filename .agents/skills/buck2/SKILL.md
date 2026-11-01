---
name: buck2
description: Build, test, query and extend the Overalls Buck2 graph. Use for every BUCK, .bzl, .bxl, .buckconfig, toolchains/ or tools/buck2 change, when adding a target in any language, when selecting affected tests, and when a Buck2 build, cache or daemon misbehaves.
---

# Buck2 in Overalls

Buck2 is the only build entry point
([ADR-0269](../../../docs/architecture/decisions/0269-buck2-build-system-with-nix-toolchains.md)).
Nix supplies the cells. Use the `nix-builds` skill for pins and NixOS assembly.

## Running

- **Always run `tools/buck2 …`**, never a buck2 from `PATH`. The wrapper
  rebuilds `.buck-cells` from the flake-pinned `buckCells` output, and it
  restarts the daemon only when the cells store path changes.
- **Common commands:**
  - build: `tools/buck2 build //path:target --show-full-output`
  - test: `tools/buck2 test //path:target`
  - query: `tools/buck2 uquery 'owner(path/to/file)'`,
    `tools/buck2 uquery 'rdeps(//..., //lilly:srcs)'`
- **Target hashes,** which feed the selector:
  `tools/buck2 targets //... --show-unconfigured-target-hash --target-hash-file-mode=paths_and_contents --target-hash-recursive=true`.
  Pass `--target-hash-recursive=true` explicitly: without it a dependency's
  change (including a toolchain path) does not change the hash.
  `--target-hash-modified-paths` only applies in `paths_only` mode.
- **Affected targets:** `tools/affected [--base REV] [--all] [--output FILE]`
  compares the base revision with the working tree and prints JSON grouped
  as `machine_tests` (with labels), `tests` and `builds`. It only loads targets;
  it never builds. `buck2` and `affected` in the devenv shell are these
  wrappers.
- **Finding the target for a Nix output.** Never use `nix build .#…`;
  every output has a Buck2 target:
  - a `lib.assemble` package output `<name>` (`nix/assemble/outputs.nix`,
    listed in `nix/buck/assembly_attrs.bzl`) is `//:package-<name>`;
  - a machine test is `//nix/verification/tests/machines/<suite>:<name>`, and
    any other check is `//:check-<name>`; the generated "Find a test" table
    in `nix/verification/tests/README.md` lists every one with its target;
  - a host system is `//fleet/hosts/<host>:deployment` (`:base`, `:install`);
  - `tools/buck2 uquery 'attrregexfilter(attr, "<regex>", //...)'` finds the
    `nix_assemble` target for a `lib.assemble` attribute.
  A `nix_assemble` output is a file holding the store path:
  `cat "$(tools/buck2 build //:package-host --show-full-simple-output)"`.
  A `nix_store_run` target makes one runnable (`tools/buck2 run
  //mila:journey-fixture`).
- **Generated documentation.** `tools/docs` rewrites the sections that
  `buck/bxl/docs.bxl` renders from the graph (the "Find a test" table, from
  every test target plus `nix/verification/tests/find_a_test.bzl`);
  `tools/docs --check` fails when one is stale.
- **Ownership:**
  `tools/buck2 bxl //buck/bxl/ownership.bxl:main -- --files $(git ls-files)`.
  Pass list arguments after `--`; an `@argfile` is not expanded there.

## Layout

- **Cells.** `root` is the repository. `prelude` is
  `.buck-cells/prelude`, the Nix-pinned buck2's bundled prelude.
  `toolchains` is `toolchains/`. `none` is a stub.
- **Configuration.** The `[nix]` section comes from
  `.buck-cells/toolchains.buckconfig`, which `nix/buck/cells.nix` generates.
- **Rules** live in `buck/*.bzl`, and BXL scripts in `buck/bxl/`.
- **Ownership.** Each top-level directory has a `BUCK` file with
  `nix_owned()`. A new directory without one is owned by the root package.
  That is correct, but coarse.

## Rules for writing targets

1. **Tools come from `toolchains//:<name>`.** These are `nix_tool` targets.
   Never call a tool by bare name inside an action. To add a tool:
   1. Add it to `tools` in `nix/buck/cells.nix`.
   2. Add its name to the `nix_tool` list in `toolchains/BUCK`.
2. **Read configuration at load time.** `read_root_config` cannot be called
   during analysis. Read it in a macro and pass the value as an attribute, so
   it enters the target hash.
3. **Declare every input.** Undeclared reads break affected-test selection
   ([ADR-0270](../../../docs/architecture/decisions/0270-graph-driven-machine-test-selection.md)).
4. **Actions that touch `/nix/store` or the Nix daemon** are `local_only = True`
   and `allow_cache_upload = False`.
5. **Nothing evaluates the flake's build outputs.** Every Nix output Buck2
   builds goes through `nix_assemble` over `lib.assemble`. Package outputs
   and non-script checks are defined in `nix/assemble/outputs.nix`, never in
   `flake.nix`, and BUCK.v2 declares `//:package-<name>` and
   `//:check-<name>` for each (label `flake_output`). After lib.assemble
   gains or loses one, regenerate the list with `nix/buck/assembly-attrs.sh`;
   `//buck:assembly_attrs_fresh` fails until you do. The flake itself only
   exports `buckCells`, `lib.assemble`, `lib.dependencyPins` and
   `nixosModules`; never add a `packages`, `checks`, `apps` or
   `nixosConfigurations` consumer.
6. **`.buckconfig` ignores are root-relative.** Use `**/name` for nested
   build directories.
7. **Default globs skip dotfiles.** `nix_owned` adds `**/.*` patterns; do the
   same anywhere hidden files matter.

## Adding targets by language

Shared helpers live in `buck/checks.bzl`:

- `tool(dep)` reads a `nix_tool` path, and `search_path` builds `PATH` from
  tools only.
- A **check** is a cached build action that writes a stamp. `buck2 test`
  only reads the stamp (`check_providers`), so an unchanged check is a cache
  hit.
- `nix_owned()` also defines `srcs_files`. It maps each owned file's
  repository path to its artifact, for checks that run per file.

**Go** (`buck/go.bzl`). Third-party source and modules come from Nix:
1. Keep the `fetch*` hash and `vendorHash` in the pin registry.
2. Expose the source and modules in `inputs.go` in `nix/buck/cells.nix`, and
   list them in `toolchains/BUCK`.
3. Use `go_binary(source, modules, vendor_mode = "vendor"|"proxy", patches,
   vendor_patches, overlay, package, ldflags, goos)` and
   `go_test(packages)`. Cross-compile by setting `goos`.

The rule reproduces buildGoModule and stdenv's strip, so outputs should
match Nix byte for byte. Compare them with `diff -r`.

**JavaScript** (`buck/npm.bzl`):
- **Packages.** Add the project's `importNpmLock` tree to `inputs.npm` in
  `cells.nix`. The wrapper already hashes every `package-lock.json`. Then use
  `npm_package(srcs, node_modules, commands, install)`:
  - with `install` (dest to package path), the output is a directory;
  - without it, the target is a check.
  - Tools such as Chromium come in through `tools = {"CHROME": …}`.
- **Bundles.** Use `esbuild_bundle(srcs, entry, out, args)`. It runs the one
  pinned esbuild. Never use `esbuild.install`.

**Python.** `//:py-static` covers every owned `.py` file and
`pyproject.toml`:
- It runs ruff format, ruff check and `antithesis/verification/static-check.sh`
  (ty) with the closure from `nix/buck/python.nix`, the same one the
  precommit hook's direct fallback uses.
- One file: `tools/buck2 build '//:py-static[ruff/<path>]'`; ty alone:
  `[ty]`; the fixed copy of a file: `[fix/<path>]`.
- A new third-party import goes in `nix/buck/python.nix`.

**Scripts:**
- `script_check(cmd, srcs, path)` runs a command from the project root over
  declared inputs. Reference a file in another package with an
  `export_file`.
- `//:conflict-markers[<path>]` checks one file.
- `repo_check(cmd, include, owned, deletions, inventory, local_only)` runs a
  repository-wide command over the owned files matching `include` (one `*`
  matches anything, `/` included). It carries `PrecommitInfo`, so precommit
  runs it only when a matching file changes. `//:adrs`, `//:pins`,
  `//:rust-lints`, `//:toolchain-versions`, `//:package-input-lock`,
  `//:contracts-tests` and `//:logging-<app>` use it.
- `//:contracts` (`contract_check`) is the contract format and coverage
  check; `[contracts/<path>]` checks one file with its ancestor `CONTRACTS`.
- `nix_store_run(package, program)` makes a Nix-built program runnable with
  `buck2 run`, for example `//mila:journey-fixture`.

**Rust** (`buck/rust.bzl`, ADR-0273):
- **One toolchain.** `toolchains//:rust` is the rust-overlay toolchain from
  `nix/rust-toolchain.nix` (`[nix] rust`), and `toolchains//:cxx` links with
  the Nix cc wrapper under `env -i` (`[nix] cc_hermetic`), so a dev-shell
  `NIX_LDFLAGS` never reaches a link.
- **Third-party crates** come from the generated `rust//` cell
  (`nix/buck/rust.nix`): `reindeer buckify` over a pseudo-package of every
  member's direct dependencies at the root `Cargo.lock` versions, with
  sources from `importCargoLock`. It is generated because the lock is the
  only pin; nothing under `rust//` is committed. A crate needing a fixup gets
  `nix/buck/rust/fixups/<crate>/fixups.toml` (libc's is the example).
- **First-party crates.** In the top-level directory's `BUCK`, call
  `overalls_rust_crate("<member path>", profile = "hardened"|"release",
  native_libs = [...], test_env = {...})`; a Rustler NIF passes
  `lib_test = False` (its harness cannot link outside the BEAM; Marshall's
  Cedar crate is the example). It reads the member from
  `rust//:workspace.bzl` and defines `<pkg>-lib`, one target per binary,
  `<pkg>-unittest`, `<pkg>-test-<name>`, `<pkg>-example-<name>`, and the
  `<pkg>-clippy` and `<pkg>-rustfmt` precommit checks (`[rustfmt/<path>]`
  checks one file). A test-only fault-injection build uses
  `overalls_rust_crate_variant(path, name, replace = {"src/x.rs": ":gen"},
  bins = [...])`, with the patch made by `//buck:replace_boundary.sh`
  (fails if the boundary moves); nix/BUCK's commit-reply cut is the example.
  Native libraries are `[nix] <name>_lib` directories in `cells.nix`.
  Adding a crate, dependency or Rust file name rebuilds the cell.
- **Replacing a Nix leaf.** Bundle the binaries in the layout the Nix
  consumer expects, `nix_store_import` it with every rpath store path in
  `runtime_refs`, add the name to `RUST_ARTIFACTS`
  (`buck/rust_artifacts.bzl`) and to `rustArtifactNames` in
  `nix/domains/artifacts/default.nix`, and make the consumer read
  `swapLeaf "<name>" <Nix build>` (keeps `meta`, exposes
  `passthru.nixBuild`). A reference constraint goes on the import
  (`allowed_references = []` for Lyra's Windows agents). A fixture that
  patches or rebuilds the source is its own Buck2 target in
  `TEST_ARTIFACTS`, never an override of the leaf. Add a `rust_leaf_parity_test`
  (label `heavy`) against a flake attribute with exactly the same
  executables; `tools/precommit` runs
  `//buck/bxl/rust_parity_coverage.bxl:main`, which fails when a
  `RUST_ARTIFACTS` import has no parity test. The flake (host self-deploy) keeps
  the Nix build until the M2 activation gate; deletions wait for M11.
- **Cargo-driven leaves** (Lyra's cross builds, `buck/lyra.bzl`): when a
  build needs Cargo itself (zig linkers, SDKs, `-sys` build scripts), put
  the Nix build phase in a script both systems run, give Buck2 its tools
  as a realised `.drv` in the cells, and compare with
  `rust_leaf_parity_test(compare = "bytes")`. Pin `SOURCE_DATE_EPOCH` and
  `TZ` in the script; mask only what differs between two Nix builds.
- **Machine tests** receive `MACHINE_TEST_ARTIFACTS` (`buck/artifacts.bzl`):
  `ASSEMBLY_ARTIFACTS` (the merge of `RUST_ARTIFACTS` and `MIX_ARTIFACTS`,
  which hosts also get) plus the test-only `TEST_ARTIFACTS`; every key must
  be a name the package set consumes, or evaluation fails.

**Mila platforms** (`buck/mila.bzl`, `mila/BUCK`, ADR-0269 M9). Xcode,
Gradle and .NET need SDKs that Nix does not supply, so these are
`non_hermetic` targets:
- **What they are.** `mila_platform(name, os, steps, outputs, env, path_env,
  require, srcs, check)` runs `steps` in the checkout through
  `buck/mila_platform.py`, with the SDKs from the **daemon's** `PATH`, then
  copies `outputs` (repository paths) into buck-out with a `SHA256SUMS`. The
  actions are `local_only` and never use a cache. Third-party packages are
  pinned by lock files, which `//:pins` requires: Gradle's
  `gradle/verification-metadata.xml` and NuGet `packages.lock.json` restored
  in locked mode.
- **When they build.** Only with `-c overalls.non_hermetic=true` and on their
  own OS (`target_compatible_with` uses `toolchains//:non_hermetic_enabled`;
  `os` may list several hosts, as the Android targets do).
  `buck2 build //...`, `buck2 test //...`, verification and `tools/affected`
  skip them.
- **Targets.**
  - Apple (macOS): `apple-ffi`, `apple-ffi-clippy`, `apple-swift-test`,
    `{macos,ios}-{dev,release}` (wrapping `mila/native/mila-build`).
  - Android (Linux or macOS): `android-debug`, `android-release`, `android-ffi-clippy`.
  - Windows: `windows-ffi-published`, `windows-dotnet`, `windows-smoke`, and
    the local fallback `windows-ffi-msvc`, `windows-ffi-msvc-clippy`.
  - Hermetic, on Linux: `windows-ffi-gnu` cross-builds the shipped FFI DLL
    for `x86_64-pc-windows-gnu` with cargo-zigbuild and the `rust//` cell's
    vendored crates, deterministically (`SOURCE_DATE_EPOCH=0`, remapped
    paths). `windows-ffi-gnu-reproducible` compares it with the independent
    `windows-ffi-gnu-rebuild`; `windows-ffi-gnu-abi` checks its exports
    against `include/mila_ffi.h` and the .NET imports;
    `windows-ffi-gnu-clippy` lints it. mila-builds.yml publishes the DLL.
  - Windows imports that DLL: `windows-ffi-published` copies
    `mila/build/windows-ffi-gnu/mila_ffi.dll` (the downloaded artifact) and
    checks it against its `SHA256SUMS` and `-c mila.windows_ffi_sha256=<hex>`.
    `-c mila.windows_ffi=msvc` builds the local MSVC fallback instead.
- **The daemon's environment is the SDK.** Buck2 local actions inherit the
  environment of the daemon, not of the command. Install the SDKs first. Run
  `tools/buck2 kill` after changing `PATH` or a variable a build reads (the
  release signing inputs, for example).
- **macOS.** `tools/buck2` builds `buckCells.aarch64-darwin`: buck2, the
  prelude and a few host tools. Every other `[nix]` tool is a stub, and the
  `rust//` cell is empty. Its patched nixpkgs source comes from devenv's
  Cachix.
- **Windows (no Nix).** `tools/buck2 --no-nix …` downloads the buck2 release
  and the prelude named in `tools/buck2-no-nix.json` and checks them against
  the pin registry (`buck2WindowsBinary`, `buck2Prelude`). It needs `python`
  and `zstd` (or Python 3.14). It writes a real `.buck-cells` directory whose
  configuration sets `[overalls] no_nix` and `non_hermetic`. Tools resolve
  from `PATH`, and any hermetic target fails at analysis.
  - `OVERALLS_BUCK2_KIT` may name a `//tools:buck2-no-nix-<os>` output
    instead of downloading. Building those kits also checks that the no-Nix
    pins are exactly the buckCells buck2 and prelude: refresh
    `tools/buck2-no-nix.json` and the three registry keys with every buck2
    bump.
  - The Linux kit runs this mode on a development host.
- **Example (Android, on Linux or macOS):** install JDK 17, Gradle 9.3.1, the Android
  SDK and NDK and cargo-ndk on `PATH`, then
  `tools/buck2 build -c overalls.non_hermetic=true //mila:android-debug`.

**Dockerfile images** (`buck/container_image.bzl`). `container_image(name,
dockerfile, repository, stores)` declares `<name>` (`docker buildx build
--load` with the repository root as context, then a layer scan for the
Namespace token prefix) and the `buck2 run` target `<name>-publish` (`--
--registry REG --tag TAG...`: push with a registry cache, pull back, scan).
`stores` maps a build-context name to a `nix_assemble` target; its closure
goes in as a Nix binary cache the Dockerfile imports with `nix copy`, so
nothing builds Nix or Buck2 outputs inside the image. Both are
`non_hermetic` and Linux-only like the Mila platforms; docker and the buildx
builder come from the daemon's environment for the build, so run
`tools/buck2 kill` after changing them. The OSS scanner image is
`//.oss-scanner:image`.

**Checks that evaluate NixOS** (`nix-compact-*`,
`fleet-builds-configuration`) are `//:check-<name>` assemblies of
lib.assemble's `checks`; `tools/buck2 build '//:check-<name>[drv]'` evaluates
one without building it.

## NixOS machine tests

- **Targets.** Every machine test is a `nixos_machine_test` (`buck/nixos.bzl`)
  stanza in `nix/verification/tests/machines/<suite>/BUCK`, named after the
  check. Its `test` attribute is the Nix expression that instantiates it,
  evaluated beside `nix/verification/tests/scope.nix` with that scope's names
  (`testPkgs`, `packages`, `service`, `serviceOf`, `featureFleet`, …); there is
  no other list of machine tests. Fleet variants take only their own scenario
  files as inputs. Each target builds lib.assemble's `machineTest` through
  `nix_assemble` over a copy of its declared `inputs` only, so reading an
  undeclared file is an evaluation error: add the owning group to `inputs`
  (in `buck/inputs.bzl` or the generator), not a workaround. `[meta]` holds
  the features (and a fleet variant's script) the test command checks, and
  `[driver]` the interactive driver.
- **Evaluate without running:** `tools/buck2 build '<test>.assembly[drv]'`
  evaluates the same declared tree under the same restrictions and writes the
  derivation path, building no VM. To check every machine test's declared
  inputs, build `[drv]` for each target in
  `tools/buck2 uquery 'attrfilter(labels, machine_test_assembly, //...)'`.
  This takes about 15 minutes at `-j 24`.
- **Run one:** `tools/buck2 test //nix/verification/tests/machines/sysctl:sysctl`.
  Buck2 builds the assembly (the VM run) first; the test command then checks
  that the `nested_kvm` label matches the check's required features and, for fleet
  variants, that the declared scenarios match the composed script.
- **Edit only `name` and `test`.** To add a machine test, add a stanza with
  just those two attributes to its suite's BUCK file (create the file for a
  new suite); after adding one, changing a `test` or a suite's
  `requiredFeatures`, run `python3 buck/machine_tests.py generate`, which
  derives every other attribute.
  After changing which scenario files a fleet variant reads, run
  `python3 buck/machine_tests.py refresh-scenarios` (evaluation only, a few
  minutes; it builds each variant's `[meta]`) and then `generate`. `//buck:machine_tests_fresh` fails when they
  are stale.
- **Labels.** `machine_test` and `nested_kvm` come from the macro.
  `known_inception_failure` keeps Inception (known broken) out of `ci.yml`;
  the daily run reports it without failing.
- **CI.** `ci.yml` runs on every trunk push and on dispatch:
  affected → build → test → one job per affected machine test. When
  everything is selected it leaves the machine tests to the daily run unless
  dispatched with `-f machine_all=true`. The daily
  backstop is `nixos-machine-tests.yml`; dispatch it with
  `gh workflow run nixos-machine-tests.yml --ref trunk -f checks="a b"`.

## Remote cache and execution (Namespace)

Namespace (namespace.so) is the Buck2 remote cache and remote-execution
backend for developers, hosts and CI under one tenant token
([ADR-0276](../../../docs/architecture/decisions/0276-namespace-buck2-remote-cache-and-execution.md)).
It replaced the fleet's NativeLink services
([ADR-0272](../../../docs/architecture/decisions/0272-nativelink-remote-cache-and-execution.md)),
which have been removed from the repository.

- **How it turns on.** `tools/buck2` looks for a token in
  `NAMESPACE_RBE_TOKEN`, then `/run/overalls-secrets/fleet-namespace/token`
  (fleet hosts: root and `wheel`), then `~/.config/overalls/namespace-rbe-token.json`
  (`bearer_token`). With one, it writes the untracked
  `.buck-remote.buckconfig` (`<file:tools/namespace.buckconfig>`), which
  `.buckconfig` includes optionally, and exports the token for buckd; the
  tracked config expands `$NAMESPACE_RBE_TOKEN` in its `http_headers`.
  Without one, or with `OVERALLS_BUCK2_REMOTE=off`, it removes the include and
  builds stay local. Switching restarts the daemon. Namespace's addresses
  name the cluster's instances and change when Namespace recreates it; where
  `nsc` is logged in, the wrapper re-reads them hourly into the untracked
  `.buck-remote.endpoints` (delete it to force a re-read), otherwise the
  committed ones in `tools/namespace.buckconfig` apply. A dead address
  (404 or no answer to a five-second probe, remembered in
  `.buck-remote.probe` for ten minutes) turns the cache off for the build
  instead of letting Buck2 retry forever.
- **Nested daemons.** A test that runs `.buck-cells/bin/buck2` itself sees
  the checkout's include but not the token (test environments do not carry
  it), and Buck2 then retries the connection for about 45 s. Pass
  `-c buck2_re_client.engine_address= -c buck2_re_client.action_cache_address=
  -c buck2_re_client.cas_address= -c buck2_re_client.http_headers=`, as
  `buck/tests/mix_test_failure_uncached.py` does.
- **Never write the token** into a file in the checkout, argv or the Nix
  store. `tools/namespace-token-scan` fails if the `nsrt_` prefix appears in
  the include, `buck-out/v2/log` or `~/.buck`; CI runs it after each Buck2 job.
- **Who writes.** Every token holder uploads. `default_allow_cache_upload =
  true` sits in the root `.buckconfig`, because Buck2 ignores that key in an
  included file (it read `false` from the include and uploaded nothing until
  2026-11-01); without a token there is no remote cache, so nothing uploads.
  `local_only` actions keep `allow_cache_upload = False` (rule 4). The host
  updater's `.buckconfig.local` keeps `remote_execution = false` and retries
  a failed build once with `OVERALLS_BUCK2_REMOTE=off`
  (`update.namespace_cache` event: `enabled` or `token_missing`;
  `update.remote_cache` `fallback`).
- **CI.** ci.yml's Buck2 jobs and nixos-machine-tests.yml set
  `NAMESPACE_RBE_TOKEN` from the repository secret; mila-builds.yml sets it
  only on the hermetic source-bundle job. Forks get no secret and build
  locally.
- **Rotation and revocation.** See `secrets/README.md` (`nsc bazel
  create-token`, `overalls-secrets encrypt fleet-namespace --replace`,
  `nsc token revoke`).
- **What runs remotely** (`toolchains//:execution_platform`, from
  `buck/platforms.bzl`): Linux x86_64, with a cache configured, `[nix]
  cells_id` and `[overalls] remote_execution = true`. Remote execution is
  the default wherever a token and a matching worker image exist, on
  developer machines and in CI (the user's decision, 2026-11-01);
  `OVERALLS_BUCK2_REMOTE_EXECUTION=off` keeps one build cache-only. Host
  deployments stay cache-only. `tools/buck2` sets `[overalls] re_image`
  whenever `tools/namespace-re-image.lock` names a worker image for the
  checkout's `cells_id`, so every action carries `overalls-cells=<cells_id>`
  and `container-image=docker://<image>@<digest>` in its digest. Namespace
  starts 16x32 workers on demand inside the workspace's shared 64-vCPU cap
  and cannot bound or scale them to zero: `nsc list` shows them
  (`bazel.purpose=worker`) and `nsc destroy <id> --force` frees an idle one.
  `local_only` actions and test commands never go remote. A
  remote action that fails is retried locally
  (`allow_hybrid_fallbacks_on_failure`), so a real failure costs two runs and
  still fails.
- **Worker image.** `tools/namespace-re-image --push` (needs `nsc login`)
  builds the image from the buckCells closure without `.drv` files, plus
  `/bin` links to coreutils, findutils, grep and sed, pushes it to
  `nscr.io`, runs `nsc base-image optimize`, and rewrites the lock.
  `.github/workflows/namespace-re-image.yml` does this, and commits the lock,
  after every trunk change to the cells' inputs; until it lands, those cells
  build locally with the cache. Optimising starts a temporary 8x16 Namespace
  maintenance instance.
- **Checking.** The build summary prints `Cache hits: N%` and
  `Commands: N (cached: C, remote: R, local: L)`. Force local with
  `OVERALLS_BUCK2_REMOTE=off` or `buck2 build --local-only`.

## Precommit

`tools/precommit` is the one precommit entry point: the devenv `precommit`
command, the single prek hook and CI call it.

- **Scopes:** the named files or the staged changes (default), `--base REV`
  (merge-base to working tree), `--all`. `--exclude-label LABEL` drops checks
  carrying it (CI's precommit job drops `expensive`: the `mix` job runs the
  suites). `--plan` prints the selection as JSON;
  `--fix` first copies each changed file's `fix` sub-target output over it
  (the only mode that rewrites files).
- **How it selects** (`buck/bxl/precommit.bxl`): the universe is every target
  labelled `precommit`. A check's `PrecommitInfo` (`buck/checks.bzl`) says which
  paths it reads, which sub-targets check one file, which run beside them
  (`shared`) and which deleted paths matter. A check without the provider runs
  whole when an owner of a changed file is among its deps, or a deleted file is
  below its package. A `BUCK`, `.bzl`, `.bxl`, `.buckconfig`, `toolchains/`,
  `nix/buck/`, `flake.lock` or wrapper change selects every check, and
  unchanged ones are cache hits. Everything selected is one `ctx.build`.
- **Fallback.** When `tools/buck2 server` fails, or with
  `OVERALLS_PRECOMMIT_DIRECT=1`, the hook scripts run directly with the pinned
  tools devenv passes in `OVERALLS_PRECOMMIT_*`. The ADR, contract,
  package-input-lock and toolchain checks are then reported as skipped.
- **Mix projects.** Each project's `:check` carries `PrecommitInfo`
  (contract mix-check-precommit): a changed test module selects `[format]`
  alone, top-level prose (`*.md`, `CONTRACTS`) selects nothing, and any other
  source change or a deletion runs the whole check. The `:test` shards have
  no provider yet, so a change in a project runs them (cache hits when
  unchanged). There are no `[fix/<path>]` sub-targets for `mix format` yet.
  CI runs the suites in ci.yml's `mix` job and the checks in its `precommit`
  job. There is no `mix precommit` alias any more: every gate it ran is a
  Buck2 check (ADR-0269 M8), including `[unused_deps]`, diagnostics
  `[schema]`, Marshall's `[monospace]` and `[localization_*]`,
  `//:marshall-browser` and `//:marshall-workspace-types`.

### Adding a check to precommit (the convention)

1. Label the target `precommit` (and `check`, so `buck2 test` reads it). Never
   label `flake_output` assemblies or machine tests `precommit`.
2. The default output runs the whole check and fails on any violation.
3. Name sub-targets `[<kind>/<repo path>]` for one file (`[ruff/<path>]`,
   `[contracts/<path>]`, `[format/<path>]`), `[<kind>]` for one part of the
   whole check (`[ty]`, `[format]`, `[dialyzer]`, `[logging]`, `[gettext]`,
   `[test_result]`, `[covenant]`), and `[fix/<repo path>]` for a fixed copy of
   one file. `//:conflict-markers[<path>]` predates the convention.
4. Return `PrecommitInfo(inputs, per_file, shared, fix, deletions)` to get
   per-file selection. Leave a checker, configuration or `CONTRACTS` path out
   of `per_file`, so changing it runs the whole check. Without the provider,
   put the check in the package that owns its sources: precommit then runs its
   default output when those sources change.
5. Mix rules: `mix_check` and `mix_test` carry `precommit`. `mix_check`'s
   `PrecommitInfo` maps test modules to `[format]`; a check with an empty
   `shared` runs whole on a matching deletion. A `fix = {path: "fix/" + path}`
   from `mix format` would give `precommit --fix` Elixir formatting.

## Host deployment targets

- **Targets.** `fleet/hosts/<host>/BUCK` calls `fleet_host()` from
  `buck/fleet.bzl`. That declares `:deployment` (the enrolled
  `overallsDeployment` bundle the updater activates), `:base` and
  `:install`. `//nix/platform:kexec` is the installer kexec.
- **Revision.** Pass `-c overalls.revision=<full commit>` so the system names
  its source. Without it, the system names `unknown`
  ([ADR-0271](../../../docs/architecture/decisions/0271-buck2-host-self-deployment.md)).
- **A new host directory** needs its `BUCK` file and an entry in the root
  `OWNED_PACKAGES`; otherwise its files are missing from the assembly tree.
- **The updater** runs the candidate's own `tools/buck2 --isolation-dir
  overalls-update` in `/var/lib/overalls-auto-update/checkout`, with `HOME`
  set to `/var/lib/overalls-auto-update/buck2-home` and `OVERALLS_GCROOT_DIR`
  set to `/var/lib/overalls-auto-update/gcroots`. To inspect the updater's
  daemon on a host, use the same flags; never leave a daemon running there.
- **Updater machine tests** build `nix/verification/tests/support/update-fixture.nix`
  repositories. Restricted evaluation refuses `path:` inputs, so fixture
  `lib.assemble` names prebuilt candidates with `builtins.storePath`.

## Elixir targets

Rules are in `buck/mix.bzl`; their contracts are in `buck/CONTRACTS`.

- **Per project.** A project's `BUCK` declares two `mix_sources` targets and
  calls `overalls_mix_project`:
  - `release_srcs` is the release source allowlist (contract
    `release-source-allowlist`); there is no Nix release any more;
  - `test_srcs` holds the whole project plus its path dependencies.

  The macro creates:
  - `:compile` (prod) and `:compile_test`;
  - `:test`, whose `[test_result]` and `[covenant]` are subtargets;
  - `:check`, with `[format]`, `[logging]`, `[dialyzer]` (using `[plt]`) and,
    where the project has catalogues, `[gettext]`;
  - for applications, `:release`, `:release_probe` and `:<app>_import` (the
    release as a store path with its `self_reference`, for
    `nix_assemble(artifacts = …)`).

  `:test` and `:check` carry the `precommit` label, and `:test` also carries
  `expensive`. A failed shard fails its run action and prints every failed
  test plus the log tail, so no cache keeps it; `[test_result]` holds every
  shard's passing record.
- **Shards.** `test_shards = N` (Marshall: 16) splits a suite into N cached
  `mix test <files>` actions, `[shard-1]` … `[shard-N]`, each with its own
  sandbox and PostgreSQL and only its own test files in its tree. One test
  file's change reruns one shard; a change under `lib/` reruns them all.
  - Unweighted files go to the shard their path hashes to (FNV-1a), so
    adding a file moves no other file. Slow files listed in
    `test_shard_weights` (seconds) go heaviest-first to the lightest shard.
  - `repository_tests` prefixes (Marshall: `test/architecture/`) form a
    `[repository]` shard, the only one that sees `repository_support`
    (`root//:mix_repository`), so a docs or ADR change reruns only it.
  - `[shard_plan]` is a JSON map of shard -> files: build it to find which
    shard runs a test.
  - `test_schedulers` (default 4) sets `+S n:n` and the action's local
    weight, so Buck2 never starts more scheduler threads than job slots.
  - `[covenant]` checks the union of the shards' Covenant results.
  - **Seeds.** A cached shard keeps the ExUnit and Hegel draws of the run
    that recorded it; the shard log has ExUnit's `Randomized with seed`.
    `tools/buck2 build -c mix.test_salt=$(date +%s) //marshall:test` reruns
    every shard with fresh seeds.
  - Run one shard: `tools/buck2 build '//marshall:test[shard-3]'`.

  Libraries in `elixir/` use a target prefix, for example
  `//elixir:diagnostics_test`.
- **Dependencies.** Mix dependencies come from the `[mix]` cells section.
  - `deps_<project>_prod` and `deps_<project>_test` are fixed-output fetches
    keyed in `dependency-hashes.json`.
  - A new project needs entries in `testDependencyProjects` in
    `nix/domains/artifacts/default.nix`, plus a hash.
  - To find a new hash, put a fake one in the registry, run
    `nix build --impure --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).packages.testDependencies.<project>'`, and
    copy the `got:` value.
- **Sandbox.** Every Mix action runs in `buck/mix_sandbox.sh`:
  - bubblewrap, no network, uid 1000;
  - `/build` as the work directory, as in the Nix sandbox, because Mix and
    Spark embed absolute paths;
  - a writable overlay on `/nix/store`.

  Unprivileged user namespaces are required, so these actions are local only.
- **Shell state.** Actions source the `mixRelease` shell state captured from
  `beam.mixRelease` (`nix/buck/mix.nix`). Releases therefore run the same
  hooks and compiler flags as the Nix build.
- **Self-reference.** A release names itself as
  `/nix/store/00000000000000000000000000000000-overalls-<app>-0.1.0`.
  Assembly rewrites that placeholder to its `$out`. The probe copies the
  release to that path inside a sandbox and runs it there.
- **Variants.**
  - Encrypted crash dumps and Antithesis builds are `select()`s on
    `//buck:encrypted_crash_dumps` and `//buck:antithesis_*`. Pick one with
    `--target-platforms //buck:<variant>_platform`.
  - Fixture releases are `release_variants`, which take extra `srcs`, a
    `pre_build` source patch and `post_install` lines.
- **Parity.** To compare a release byte for byte with a Nix build, pass
  `-c mix.random_seed_<app>=<first 10 characters of the Nix output hash>`.
  This makes stdenv's `-frandom-seed` match. Then compare the trees after
  replacing the Nix output path with the placeholder.
- **Hermetic tests.** Tests run offline:
  - Hegel's NIF comes from `HEGEL_NIF_PATH` (the `hegelNif` Nix build);
  - LazyHTML's precompiled NIF is in the test fetch;
  - Postgres runs on a socket under `/build/pgs`.

  Marshall's validator tests read the whole repository, so its
  `[repository]` shard depends on `root//:mix_repository`; the other shards
  and `:check` do not. Other suites get the default
  `test_support`: the scripts helpers, Marshall's TLS fixtures and the
  protocol's test support and vectors. A suite that reads another file
  outside its project needs a `mix_sources` for it, or it fails with
  `File.Error` in the sandbox.

## Troubleshooting

- **Socket path too long** (Chromium, Postgres). `buck-out` paths are deep.
  Point `TMPDIR` at a short `mktemp -d /tmp/…` directory.
- **Go stamps VCS data or reads `.git`.** Build outside the checkout, as
  `go.bzl` does.
- **`cmd` paths in `script_check`.** They are relative to the project root,
  not to the package.


- **`nix_assemble` fails with "access to absolute path … is forbidden in
  restricted mode" or "path … does not exist".** The assembly read a file
  outside its declared tree. Add the owning group to the target's `srcs` or
  `inputs` (for machine tests, in `buck/inputs.bzl` or the generator), never
  an `--impure` escape. Reproduce without building:
  `tools/buck2 build '<target>[drv]'` (machine tests: `<test>.assembly[drv]`).
- **A failed machine test.** `tools/machine-test-log <target> <file>` writes
  the full Nix build log; `<test>.assembly[drv]` names the exact derivation
  without building it.
- **"function is unavailable during analysis".** Move the
  `read_root_config` call into a macro (rule 2).
- **"File not found … Included in X/BUCK".** A glob matched a dangling
  symlink or a build directory. Add an ignore pattern, or remove the
  committed build output.
- **"duplicate names" from a filegroup.** Nested filegroups that share short
  paths cannot be merged. Use `owned_set` from `buck/nix.bzl`.
- **"[mix] … is missing".** `.buck-cells` predates the Mix section; run
  `tools/buck2` once so it rebuilds the cells.
- **A Mix action fails with `bwrap: … Operation not permitted`.** The host
  has no unprivileged user namespaces; run the build where they are enabled.
- **Stale toolchain.** Check that `readlink .buck-cells` matches
  `nix build --print-out-paths .#buckCells.x86_64-linux`, then run
  `tools/buck2 kill`.
- **Remote cache or execution errors.** Rerun with
  `OVERALLS_BUCK2_REMOTE=off` to confirm the build works locally, then check
  that the token has not expired or been revoked (`nsc token list`).
- **Bumping buck2.** buck2 comes from `buildNixpkgs`. Bump `flake.lock`, rerun
  the spikes in the [migration review](../../../docs/architecture/reviews/2026-10-30-buck2-migration.md),
  and expect every target to be selected. Update `tools/buck2-no-nix.json` and
  the `buck2WindowsBinary`, `buck2LinuxBinary` and `buck2Prelude` pins in the
  same change; `//tools:buck2-no-nix-linux` fails until they match.
- **A `non_hermetic` target is "incompatible".** Pass
  `-c overalls.non_hermetic=true`, and build it on its own OS.

## Verification

Run the changed targets, the ownership BXL and `elixir scripts/check_adrs.exs`
when records change. Buck2 success does not establish NixOS behaviour; that
needs machine tests.
