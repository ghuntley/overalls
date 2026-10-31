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
5. **`nix_flake_attr` is bootstrap only.** When you move an output to a real
   rule, delete its bootstrap use in the same change. Never add new uses.
   After the flake gains or loses an output, regenerate the list with
   `nix/buck/bootstrap-attrs.sh`; `//buck:bootstrap_attrs_fresh` fails until
   you do.
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
  native_libs = [...], test_env = {...})`. It reads the member from
  `rust//:workspace.bzl` and defines `<pkg>-lib`, one target per binary,
  `<pkg>-unittest`, `<pkg>-test-<name>`, and the `<pkg>-clippy` and
  `<pkg>-rustfmt` precommit checks (`[rustfmt/<path>]` checks one file).
  Native libraries are `[nix] <name>_lib` directories in `cells.nix`.
  Adding a crate, dependency or Rust file name rebuilds the cell.
- **Replacing a Nix leaf.** Bundle the binaries in the layout the Nix
  consumer expects, `nix_store_import` it with every rpath store path in
  `runtime_refs`, add the name to `RUST_ARTIFACTS`
  (`buck/rust_artifacts.bzl`) and to `rustArtifactNames` in
  `nix/domains/artifacts/default.nix`, and make the consumer read
  `swapLeaf "<name>" <Nix build>` (keeps `meta`, exposes
  `passthru.nixBuild`). Anything that patches or rebuilds the source must
  override `.nixBuild`, never the import. Add a `rust_leaf_parity_test`
  (label `heavy`) against a flake attribute with exactly the same
  executables; `tools/precommit` runs
  `//buck/bxl/rust_parity_coverage.bxl:main`, which fails when a
  `RUST_ARTIFACTS` import has no parity test. The flake (host self-deploy) keeps
  the Nix build until the M2 activation gate; deletions wait for M11.
- **Machine tests** receive `ASSEMBLY_ARTIFACTS` (`buck/artifacts.bzl`), the
  merge of `RUST_ARTIFACTS` and `MIX_ARTIFACTS`; every key must be a name the
  package set consumes, or evaluation fails.

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
  own OS (`target_compatible_with` uses `toolchains//:non_hermetic_enabled`).
  `buck2 build //...`, `buck2 test //...`, verification and `tools/affected`
  skip them.
- **Targets.**
  - Apple (macOS): `apple-ffi`, `apple-ffi-clippy`, `apple-swift-test`,
    `{macos,ios}-{dev,release}` (wrapping `mila/native/mila-build`).
  - Android (Linux): `android-debug`, `android-release`, `android-ffi-clippy`.
  - Windows: `windows-ffi-msvc`, `windows-ffi-msvc-clippy`, `windows-dotnet`,
    `windows-smoke`.
  - Hermetic, on Linux: `windows-ffi-gnu` and `windows-ffi-gnu-clippy`
    cross-build the FFI crate for `x86_64-pc-windows-gnu` with cargo-zigbuild
    and the `rust//` cell's vendored crates. They are a compile and Clippy
    check only; the shipped DLL stays MSVC.
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
- **Example (Android, on Linux):** install JDK 17, Gradle 9.3.1, the Android
  SDK and NDK and cargo-ndk on `PATH`, then
  `tools/buck2 build -c overalls.non_hermetic=true //mila:android-debug`.

**Not yet Buck2.** Checks that evaluate NixOS (`nix-compact-*`,
`fleet-builds-configuration`) stay bootstrap targets until `nix_assemble`
(M3).

## NixOS machine tests

- **Targets.** Every machine check in `nix/verification/tests/catalog.nix` is a
  `nixos_machine_test` (`buck/nixos.bzl`) in
  `nix/verification/tests/machines/<suite>/BUCK`, named after the check. Fleet
  variants carry their flags as `params` and only their own scenario files as
  inputs. Each target builds `lib.assemble {}.checks.<name>` through
  `nix_assemble` over a copy of its declared `inputs` only, so reading an
  undeclared file is an evaluation error: add the owning group to `inputs`
  (in `buck/inputs.bzl` or the generator), not a workaround.
- **Evaluate without running:** `tools/buck2 build '<test>.assembly[drv]'`
  evaluates the same declared tree under the same restrictions and writes the
  derivation path, building no VM. To check every machine test's declared
  inputs, build `[drv]` for each target in
  `tools/buck2 uquery 'attrfilter(labels, machine_test_assembly, //...)'`.
  This takes about 15 minutes at `-j 24`.
- **Run one:** `tools/buck2 test //nix/verification/tests/machines/sysctl:sysctl`.
  Buck2 builds the assembly (the VM run) first; the test command then checks
  that the `nested_kvm` label matches Nix's `meta.ci.nestedKvm` and, for fleet
  variants, that the declared scenarios match the composed script.
- **Never edit the generated BUCK files.** After changing `catalog.nix` or a
  suite's `requiredFeatures`, run `python3 buck/machine_tests.py generate`.
  After changing which scenario files a fleet variant reads, run
  `python3 buck/machine_tests.py refresh-scenarios` (evaluation only, a few
  minutes) and then `generate`. `//buck:machine_tests_fresh` fails when they
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

## Remote cache and execution (NativeLink)

Panterloons serves a REv2 cache (CAS and action cache) and the remote-execution
scheduler on its tailnet address; workers run on Panterloons and Dungarees
([ADR-0272](../../../docs/architecture/decisions/0272-nativelink-remote-cache-and-execution.md)).
Everything is optional: without configuration, credentials or a reachable
service, every action runs locally.

- **Listeners** (all on 100.98.214.120, mTLS, one CA each; ports come from
  `nix/policy/fleet/ports.nix`):

  | Port | Who | CA | Can |
  | --- | --- | --- | --- |
  | 50071 | hosts | `ca.crt` (reader) | read the cache; uploads refused or discarded |
  | 50072 | CI | `uploader-ca.crt` | read, upload, execute |
  | 50073 | developers | `executor-ca.crt` | read, upload inputs, execute; never write the action cache |
  | 50074 | workers | `worker-ca.crt` | worker API, CAS, action-cache results |

  Every server certificate is issued by `ca.crt`, so clients always trust
  `fleet/buck-re/ca.crt`.
- **Developers** write the untracked `.buckconfig.local` (never commit it):

  ```ini
  [buck2_re_client]
    address = grpc://100.98.214.120:50073
    tls = true
    instance_name = main
    tls_ca_certs = /path/to/overalls/fleet/buck-re/ca.crt
    tls_client_cert = /private/buck-re-executor.pem
  [overalls]
    remote_execution = true
  ```

  `tls_client_cert` is one PEM file holding the certificate and then its key,
  outside the checkout and the Nix store. The developer identity is
  `overalls-buck-re-executor.production.EXECUTOR_IDENTITY` in the
  recovery-only `buck-re-executor-recovery` document. Without
  `remote_execution = true` the same file gives cache reads only.
- **CI** uses `.github/actions/buck-re` in ci.yml's build, test and precommit
  jobs. It is off by default and acts only when the repository variable
  `BUCK_RE` is `enabled`, the `BUCK_RE_TAILSCALE_AUTHKEY` (ephemeral, tagged
  `tag:buck-re-ci`) and `BUCK_RE_UPLOADER_IDENTITY` secrets exist, and the run
  is a trunk push or dispatch in this repository. The step continues on
  error, so a failed join or an unreachable listener leaves CI local. It joins the
  tailnet, and writes `.buckconfig.local` for port 50072 with
  `default_allow_cache_upload = true` and `remote_execution = true`.
- **Hosts** only read. The `overalls.buckRemoteCache.client` module installs
  root's `~/.buckconfig.d/overalls-remote-cache` while the decrypted identity
  exists. The host updater runs Buck2 with its own `HOME`, so it writes the
  same read-only section into its checkout's `.buckconfig.local` itself, only
  while the identity file exists and the listener accepts a connection
  (`update.remote_cache` event: `enabled`, `identity_missing`, `unreachable`,
  `not_configured`; `fallback` when an enabled build failed and was retried
  once without the cache), always with `default_allow_cache_upload = false` and
  `remote_execution = false`. Port 50071 has no execution service.
- **What runs remotely** (`toolchains//:execution_platform`, from
  `buck/platforms.bzl`): Linux x86_64 only, with a `[buck2_re_client]` address,
  `[nix] cells_id` and `[overalls] remote_execution = true`. Execution is
  remote first; Buck2 runs an action locally when remote execution fails as
  infrastructure (scheduler unreachable, or no worker holds these cells, which
  the scheduler fails after `unmatchedTimeout`, 15 s). `local_only` actions
  (`nix_store_import`, `nix_assemble`, `repo_check(local_only)`, anything
  touching `/nix/store` or the Nix daemon) and test commands
  (`nixos_machine_test`, script tests, check stamps) never go remote. Rules
  for non-hermetic targets (`non_hermetic`, the Mila platform builds) must set
  `local_only = True` on every action.
- **The cells property.** `nix/buck/cells.nix` writes `[nix] cells_id`, a
  hash of every toolchain store path, the rust cell and buck2. Every action
  carries `overalls-cells=<cells_id>` (part of its digest, cached or
  executed). A worker advertises the id of the one cells closure it holds:
  the host updater's checkout `.buck-cells` (the deployed revision's cells,
  realised from Cachix), rooted under `/var/lib/nativelink-worker-cells`. A
  client on another cells revision runs locally after the scheduler's
  timeout; set `remote_execution = false` while working on cells changes.
- **Workers** run in their own mount namespace with every Lilly pool mount
  removed first (ADR-0144), as `nativelink-worker` without capabilities,
  reaching only loopback and the scheduler. Actions run through
  `buck-re-action-sandbox` as `nativelink-action` with no network, no view
  of other actions or the worker, and a private `/tmp`; they cannot read the
  worker identity. Execute rights are still trusted like upload rights.
  Remote actions have no network: anything that needs it must be
  `local_only`.
- **What is never uploaded.** `local_only` actions keep
  `allow_cache_upload = False` (rule 4).
- **Checking.** The build summary prints
  `Commands: N (cached: C, remote: R, local: L)`. Force local with
  `buck2 build --local-only`, or remote-or-fail with `--remote-only`.

## Precommit

`tools/precommit` is the one precommit entry point: the devenv `precommit`
command, the single prek hook and CI call it.

- **Scopes:** the named files or the staged changes (default), `--base REV`
  (merge-base to working tree), `--all`. `--plan` prints the selection as JSON;
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
- **Not yet covered:** `mix precommit` in each project (compile, format,
  tests, Covenant, Dialyzer, gettext, Marshall's extra gates) until the Mix
  rules land; CI's `mix precommit` matrix stays.

### Adding a check to precommit (the convention)

1. Label the target `precommit` (and `check`, so `buck2 test` reads it). Never
   label bootstrap flake checks or machine tests `precommit`.
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
5. Mix rules: `mix_check` and `mix_test` carry `precommit`; a `PrecommitInfo`
   with `shared = ["format", "logging", "gettext", "dialyzer"]` (or the
   default output) and `fix = {path: "fix/" + path}` from `mix format` gives
   `precommit --fix` Elixir formatting.

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

## Troubleshooting

- **Socket path too long** (Chromium, Postgres). `buck-out` paths are deep.
  Point `TMPDIR` at a short `mktemp -d /tmp/…` directory.
- **Go stamps VCS data or reads `.git`.** Build outside the checkout, as
  `go.bzl` does.
- **`cmd` paths in `script_check`.** They are relative to the project root,
  not to the package.


- **"function is unavailable during analysis".** Move the
  `read_root_config` call into a macro (rule 2).
- **"File not found … Included in X/BUCK".** A glob matched a dangling
  symlink or a build directory. Add an ignore pattern, or remove the
  committed build output.
- **"duplicate names" from a filegroup.** Nested filegroups that share short
  paths cannot be merged. Use `owned_set` from `buck/nix.bzl`.
- **Stale toolchain.** Check that `readlink .buck-cells` matches
  `nix build --print-out-paths .#buckCells.x86_64-linux`, then run
  `tools/buck2 kill`.
- **Remote cache or execution errors.** Move `.buckconfig.local` aside to
  confirm the build works locally. Then check the tailnet route to
  Panterloons, that the PEM holds the certificate and key, and that the port
  matches the certificate: a host certificate on 50072 fails the TLS
  handshake. Every remote action falling back after about 15 s means no
  worker holds your `cells_id` (`grep cells_id .buck-cells/toolchains.buckconfig`
  against `/var/lib/nativelink-worker-cells/id` on the workers).
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
