---
name: nix-builds
description: Maintain the Nix side of the Overalls build — dependency pins, the Buck2 cells, toolchains, NixOS modules and assembly. Use for every .nix, flake.lock, devenv.lock or dependency-hashes.json change, when adding a third-party dependency in any ecosystem, and when refreshing hashes.
---

# Nix builds in Overalls

Nix supplies pinned toolchains and third-party dependencies to Buck2, and it
assembles NixOS systems, images and machine tests
([ADR-0269](../../../docs/architecture/decisions/0269-buck2-build-system-with-nix-toolchains.md)).
First-party code is built by Buck2; use the `buck2` skill for that.

## Pins

Third-party inputs are pinned in exactly one place
([ADR-0267](../../../docs/architecture/decisions/0267-single-dependency-pin-registry.md)):

1. **`flake.lock`**, for flake inputs. `devenv.lock` must agree on the
   application nixpkgs and `nix-compact`; the `package-input-lock` check
   enforces this.
2. **`nix/domains/artifacts/dependency-hashes.json`**, for fixed-output
   hashes. Read them with `(import <rel>/nix/domains/artifacts/pins.nix).<key>`.
   Keys are flat and descriptive, and the file is sorted.
3. **An ecosystem lock file:**
   - `Cargo.lock`, through `infrastructure/locked-cargo-vendor.nix` or
     `importCargoLock`, with no hash;
   - `package-lock.json`, through `importNpmLock`;
   - `mix.lock`, verified against `fetchMixDeps`;
   - the guest domain locks.

The `pins` check (`elixir scripts/check_pins.exs`, run as the Buck2 `//:pins`
precommit check) refuses all of these:

- inline `hash`/`sha256` literals outside its reviewed exemptions;
- registry keys that nothing reads;
- reads of keys that do not exist.

### Adding a dependency

- **Fetch** (`fetchurl`, `fetchFromGitHub`):
  1. Add a registry key with `lib.fakeHash`.
  2. Build, and copy the reported hash into the registry.
  3. Read the key through `pins.nix`.
- **Cargo:** register the lock in `lib.dependencyPins.cargo` in
  `nix/domains/artifacts/default.nix`. `scripts/cargo_security_upgrades.exs`
  refuses unregistered locks.
- **Go:** put `vendorHash` in the registry. Expose the source and modules
  for Buck2 in `inputs.go` in `nix/buck/cells.nix`.
- **npm:** use `importNpmLock` from the committed lock. Buck2 takes the
  `buildNodeModules` tree from `inputs.npm`.
- **Mix:** the `fetchMixDeps` hash lives in the registry under the
  application's key. Refresh it with `scripts/dependency_pins.ex`.
- **Python:** add wheels to the registry, or add packages to
  `nix/buck/python.nix`. That file is the one interpreter closure for Buck2's
  `//:py-static`, the precommit hook's direct fallback and the `python-static` check.

Never use `fetchTarball` or `builtins.fetchGit` without a pin. Never add a
second nixpkgs except as a flake input.

## Buck2 cells

`nix/buck/cells.nix` builds `buckCells`. It contains the pinned buck2, the
prelude, and `toolchains.buckconfig` with a `[nix]` section that maps each
tool name to its store path.

To add a tool:

1. Add it to `tools` in `cells.nix`.
2. Add a `nix_tool` entry in `toolchains/BUCK`.
3. If it comes from a file that `tools/buck2` does not hash, add that file to
   the wrapper's key list.

## Modules and assembly

- **Modules take `{ packages }:`.** Do not build first-party code inside a
  module; take it from `packages`.
- **Assembly.** `nix/assemble/default.nix` is `lib.assemble
  { revision, artifacts, params }`.
  - It builds one package set, instantiates every module over it
    (`nix/assemble/modules.nix`), and returns `systems`, `checks`, `kexec`,
    `packages`, `hostPackages` and `imported`.
  - The flake exports only `buckCells`, `lib.assemble`,
    `lib.dependencyPins` and `nixosModules`; `packages`, `checks`,
    `legacyPackages`, `apps` and `nixosConfigurations` are not entry points.
    Add package outputs and non-script checks to `nix/assemble/outputs.nix`
    (contract `assembly-flake-outputs`) and machine tests to
    `nix/verification/tests/catalog.nix`, then regenerate the Buck2 lists
    (`nix/buck/assembly-attrs.sh`, `python3 buck/machine_tests.py generate`).
    Never add an output or host wiring to `flake.nix`.
  - Buck2's `nix_assemble` evaluates it with
    `builtins.getFlake "path:<copied tree>"` under
    `--option restrict-eval true`, so only declared files are readable. Pass
    the revision as an argument; never read `self.rev`.
- **Swapping in a Buck2 artifact.** Its rule provides `RuntimeRefsInfo`. A
  `nix_store_import` target imports it, and `nix_assemble`'s `artifacts`
  passes it on. In `artifacts/default.nix`, the leaf uses
  `artifacts.<name> or <nix build>`.
  - Every consumer then gets the imported copy, whose closure is rebuilt from
    the declared references.
  - Compare `nix-store -qR` against the Nix build before switching.
- **Exemptions.** Sealed outputs and evaluation assertions keep literal hashes
  on purpose. Read the exemption reasons in `scripts/pins.ex` before you
  change them.

## Flake inputs and devenv

- `flake.lock` pins every flake input. `buildNixpkgs` (the application and
  toolchain nixpkgs) follows the same `devenv-nixpkgs` branch as
  `devenv.yaml`; the `//:package-input-lock` check fails when `flake.lock`
  and `devenv.lock` lock different revisions of the inputs both carry
  (`buildNixpkgs`/`nixpkgs` and `nix-compact`). Update both locks together.
- Inputs that take a nixpkgs `follows` the flake's, so one nixpkgs serves
  each role. `nix-upgrades.yml` runs `devenv update`, pins `buildNixpkgs` to
  devenv's revision and commits both locks. A bump can invalidate registry
  hashes: `scripts/dependency_pins.ex` `refresh!` (used by the Mix and Cargo
  security-upgrade scripts) builds `lib.dependencyPins.<ecosystem>.<name>.build`
  until every hash converges.
- The devenv shell imports the same toolchain files as the cells
  (`infrastructure/toolchain.nix`, `nix/rust-toolchain.nix`,
  `nix/buck/python.nix`) and runs `tools/buck2` as `buck2`; it never
  installs a second buck2 or toolchain.

## Guest lock files

Guest images pin their distribution inputs in domain locks next to the
image: `guest/ubuntu/packages.lock.json` (refreshed by
`guest/ubuntu/update-lock.py`) and `vscode-web/extensions.lock.json`
(`tool-update-vscode-extensions`). Fetched files read their hashes from
those locks or the registry, never from inline literals. Read the guest's
README before refreshing one, and rebuild the image's `//:package-guest-*`
target and the machine tests that boot it.

## Verification

- Run `elixir scripts/check_pins.exs .`.
- Build the affected targets (`tools/affected` lists them).
- For moved hashes, compare `nix derivation show` drvPaths with trunk.
- Run the machine tests that consume a changed module. A successful
  evaluation does not show runtime behaviour.
