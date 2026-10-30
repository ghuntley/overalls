# ADR-0267: Single dependency pin registry

- ID: ADR-0267
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: build, Nix artifacts, verification, CI
- Supersedes: none
- Superseded by: none

## Context

Third-party inputs are pinned in two reviewed registries:

- `flake.lock` pins flake inputs.
- `nix/domains/artifacts/dependency-hashes.json` pins fixed-output hashes, which
  `scripts/dependency_pins.ex` refreshes through `lib.dependencyPins`.

An audit on 2026-10-30 found pins outside both registries:

- **62 inline fixed-output hashes** in Nix files. They cover the OTP and Elixir
  sources, the prebuilt Rust 1.97.1 toolchain, guest base images, gh, git-lfs,
  smtprelay, underclass, libhegel, kernel sources, vscode inputs, Python wheels
  and test fixtures.
- **A stale registry key.** `lyraVendor` in the registry was never read.
  `infrastructure/lyra.nix` had its own copy, and commit `aaadafd55` refreshed
  only that copy. The scheduled cargo upgrade therefore wrote a hash with no
  effect, and its refresh could not converge.
- **Unregistered Cargo locks.** `mila/native/linux/Cargo.lock` and
  `nix/domains/system/observability-runtimes/Cargo.lock` were missing from
  `lib.dependencyPins.cargo`. `scripts/cargo_security_upgrades.exs` refuses to
  run while any tracked lock is unregistered.
- **Duplicated pins elsewhere.**
  - `nix-compact` was pinned in both `flake.nix` and `devenv.yaml`, and nothing
    checked that the two agreed.
  - The Nix installer was downloaded in CI without a checksum.
  - The OSS scanner image used an unpinned base and installer.

The migration plan for Buck2 builds requires every Cargo, Go, Python, Mix and
npm dependency to come from Nix pins. Those pins may come from only these two
registries, or from an ecosystem lock file that pins each package by digest.

## Decision

Third-party inputs are pinned in exactly one of three places.

1. **`flake.lock`**, for flake inputs.
2. **`dependency-hashes.json`**, for fixed-output hashes.
   - Nix files read the registry through `nix/domains/artifacts/pins.nix`. The
     release hub reads application keys as `hashes.<application>`.
   - Keys are flat, descriptive names.
3. **A reviewed ecosystem lock file** that pins each package by digest:
   `Cargo.lock` (consumed by `importCargoLock`), `package-lock.json`
   (`importNpmLock`), `mix.lock` (verified against the fetched set) and the guest
   domain locks.
   - Vendors derived from a lock carry no separate hash.
   - `infrastructure/locked-cargo-vendor.nix` keeps the `fetchCargoVendor`
     layout, so cross-toolchain builds substitute it unchanged.

The `pins` check (`scripts/check_pins.exs`, `scripts/pins.ex`, the `pins` flake
check and prek hook) enforces this:

- It refuses hash literals assigned to fixed-output attributes outside a short
  list of reviewed exemptions. Each exemption records its reason:
  - sealed Overalls outputs and their evaluation assertions;
  - the illumos SDK package table, which is a domain lock;
  - the Windows editor recipe, whose text is bound into the editor release id;
  - an installed-binary identity digest.
- It refuses registry keys that no file reads.
- It refuses reads of keys the registry does not contain.

`package-input-lock` also requires `devenv.lock` to agree with `flake.lock` on
`nix-compact`, alongside the application nixpkgs. CI checksums the Nix installer
script, and the OSS scanner pins its base image digest and installer checksum.
GitHub Actions stay pinned by commit SHA in their workflows.

Authorization: the user's 2026-10-30 instruction that pins come only from
`flake.lock` and `dependency-hashes.json`, and the approved Buck2 migration
plan (track T1).

## Alternatives

- **Keep inline hashes and add a checker that compares them with the
  registry.** This keeps two copies of every pin. It is the drift that broke the
  Lyra refresh.
- **Make every source a flake input.** Large OS sources, guest images and wheels
  would then be fetched as flake inputs on every evaluation that touches the
  lock. Non-flake inputs also lose the hash-mismatch refresh mechanism that
  `dependency_pins.ex` relies on.
- **Separate hash files per domain.** This is smaller per file, but recreates
  the multiple-registry problem that the refresh tooling and reviewers would
  have to reconcile.

## Consequences

- One place to review and refresh third-party hashes.
- Refreshing Lyra and terminald vendors no longer needs a hash: changing
  `Cargo.lock` is enough. The vendor derivations change, so Lyra, terminald and
  the guests that embed them rebuild once.
- Moving the literals into the registry left those derivations unchanged.
  Evaluation-time drvPaths for the toolchain, smtprelay, underclass, vscode,
  Windows runtime, gh, kernels and coding CLIs were compared against trunk and
  are identical.
- The Windows editor recipe keeps three inline Node and Python archive hashes
  until the next editor source bump, because its release id binds the recipe
  text.
- Refresh automation does not yet cover the moved fetch keys. They are updated
  by editing the registry, which is the same manual process as before but now
  in one file.

## Invariants and verification

- No Nix file outside the exemption list assigns a fixed-output hash literal.
  Checked by the `pins` flake check and prek hook, and by the property and
  repository tests in `marshall/test/architecture/pins_test.exs`.
- Every registry key is read, and every `pins.nix` read names an existing key.
  Same checks.
- Every tracked `Cargo.lock` has a `lib.dependencyPins.cargo` entry. Checked by
  the refusal in `scripts/cargo_security_upgrades.exs`. Since ADR-0273 the
  only tracked lock is the root one; the same script and `pins` refuse others.
- `flake.lock` and `devenv.lock` agree on the application nixpkgs and
  `nix-compact`. Checked by `package-input-lock`.
- **Failure case:** a new fetcher written with an attribute name the pattern
  does not match, such as an unusual `*Digest`, would escape the check. Review
  and the domain-lock exemption list remain the backstop.

## Implementation evidence

- The registry is [dependency-hashes.json](../../../nix/domains/artifacts/dependency-hashes.json), read through [pins.nix](../../../nix/domains/artifacts/pins.nix).
  Readers that replaced inline literals with registry reads include
  [toolchain.nix](../../../nix/domains/artifacts/infrastructure/toolchain.nix),
  [lyra.nix](../../../nix/domains/artifacts/infrastructure/lyra.nix),
  [guest/github](../../../nix/domains/artifacts/guest/github/default.nix),
  [native-kernels](../../../nix/domains/artifacts/guest/native-kernels/default.nix),
  [vscode-web inputs](../../../nix/domains/artifacts/vscode-web/inputs.nix),
  [python-wheels.nix](../../../antithesis/nix/python-wheels.nix) and
  [libhegel.nix](../../../nix/verification/hegel/libhegel.nix). Their evaluation-time drvPaths match trunk.
- [locked-cargo-vendor.nix](../../../nix/domains/artifacts/infrastructure/locked-cargo-vendor.nix) vendors Lyra and
  terminald from their `Cargo.lock`, which removes the `lyraVendor` and
  `terminaldVendor` keys. Marvin uses `importNpmLock` in
  [its build](../../../nix/domains/artifacts/marvin/default.nix).
- [default.nix](../../../nix/domains/artifacts/default.nix) registers the `mila-linux-native` and
  `observability-runtimes` Cargo locks in `lib.dependencyPins.cargo`.
- Track T2 ([ADR-0273](0273-single-rust-workspace-and-toolchain.md)) then
  merged every first-party Cargo lock into the root
  [`Cargo.lock`](../../../Cargo.lock). `lib.dependencyPins.cargo` has the
  single `workspace` entry, whose build links every Rust consumer.
  [cargo-workspace.nix](../../../nix/domains/artifacts/infrastructure/cargo-workspace.nix)
  vendors that lock once with `importCargoLock`, which removes the
  `cedarCargo` hash, the last separately hashed first-party Cargo vendor.
  `pins` refuses any other tracked lock (`cargo_locks/1` in
  [pins.ex](../../../scripts/pins.ex)).
- The check is [pins.ex](../../../scripts/pins.ex) and [check_pins.exs](../../../scripts/check_pins.exs). It runs as the `pins` check in
  [flake.nix](../../../flake.nix) and as a prek hook in [devenv.nix](../../../devenv.nix). Its regression and
  repository tests are in [pins_test.exs](../../../marshall/test/architecture/pins_test.exs). `package-input-lock` in
  `flake.nix` covers `nix-compact`.
- [The CI devenv action](../../../.github/actions/devenv/action.yml) and [the OSS scanner image](../../../.oss-scanner/Dockerfile)
  pin the Nix installer checksum and the base image digest.

Remaining gaps:

- A `fetch` ecosystem in `lib.dependencyPins`, so scheduled refreshes cover the
  moved keys.
- Registering the guest domain locks (Ubuntu, Windows, native Git, vscode
  extensions) with their updaters.
- Pinning `mix local.hex` and `mix local.rebar` in the upgrade workflows, and
  `cargo-ndk` in the Mila workflows.
- Moving the Windows editor recipe literals at its next source bump.
- Replacing the prebuilt Rust archives with a single rust-overlay toolchain
  (Buck2 plan, M5).

## Open questions

None.

## Related decisions

- [ADR-0188](0188-signed-overalls-cachix-substitution.md) covers signed binary
  substitution of the paths these pins produce.
- [ADR-0265](0265-rust-code-quality.md) covers the Rust gates that build the
  lock-vendored crates.
- [ADR-0273](0273-single-rust-workspace-and-toolchain.md) reduces the Cargo
  locks to the one root workspace lock.
