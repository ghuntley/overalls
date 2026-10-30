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

The `pins` check (`elixir scripts/check_pins.exs`; also a prek hook and a flake
check) refuses all of these:

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
- **Go:** put `vendorHash` in the registry.
- **npm:** use `importNpmLock` from the committed lock.
- **Mix:** the `fetchMixDeps` hash lives in the registry under the
  application's key. Refresh it with `scripts/dependency_pins.ex`.
- **Python:** add wheels to the registry, or put packages in the cells'
  `python3.withPackages` environment.

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
- **Assembly** (`lib.assemble`, milestone M3) evaluates
  `builtins.getFlake "path:<copied tree>"` under
  `--option restrict-eval true`, so only declared files are readable. Pass
  the revision as an argument; never read `self.rev`.
- **Exemptions.** Sealed outputs and evaluation assertions keep literal hashes
  on purpose. Read the exemption reasons in `scripts/pins.ex` before you
  change them.

## Verification

- Run `elixir scripts/check_pins.exs .`.
- Build the affected leaves.
- For moved hashes, compare `nix derivation show` drvPaths with trunk.
- Run the machine tests that consume a changed module. A successful
  evaluation does not show runtime behaviour.
