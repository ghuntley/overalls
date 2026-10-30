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
  `tools/buck2 targets //... --show-unconfigured-target-hash --target-hash-file-mode=paths_and_contents --target-hash-modified-paths=<files>`.
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
   `nix/buck/bootstrap-attrs.sh`.
6. **`.buckconfig` ignores are root-relative.** Use `**/name` for nested
   build directories.
7. **Default globs skip dotfiles.** `nix_owned` adds `**/.*` patterns; do the
   same anywhere hidden files matter.

## Troubleshooting

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
- **Bumping buck2.** buck2 comes from `buildNixpkgs`. Bump `flake.lock`, rerun
  the spikes in the [migration review](../../../docs/architecture/reviews/2026-10-30-buck2-migration.md),
  and expect every target to be selected.

## Verification

Run the changed targets, the ownership BXL and `elixir scripts/check_adrs.exs`
when records change. Buck2 success does not establish NixOS behaviour; that
needs machine tests.
