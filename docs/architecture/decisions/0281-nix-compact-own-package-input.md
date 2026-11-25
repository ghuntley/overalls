# ADR-0281: nix-compact builds Nix from its own pinned package input

- ID: ADR-0281
- Date: 2026-11-25
- Status: accepted
- Implementation: partial
- Components: Nix CLI, NixOS, development shell
- Supersedes: ADR-0087
- Superseded by: none

## Context

ADR-0087 had overalls build the patched Nix with
`nix-compact.lib.mkPackage` against overalls' own package sets: the devenv
package set for the development shell and the stable NixOS input for hosts.
nix-compact now supports only Nix 2.36.0, and its package factory requires
Nixpkgs `nixVersions.nix_2_36`. On 2026-11-25 neither overalls package set
ships it: devenv-nixpkgs `rolling` (958ba64) and nixos-26.05 offer only
`nix_2_34` and `nix_2_35`. Only nixos-unstable and nixpkgs-unstable carry 2.36.0.
The user moved nix-compact to 2.36.0 without backwards compatibility and chose
this option over adding an unstable input to overalls or holding the old pin.

## Decision

Overalls uses the package the pinned nix-compact flake builds from its own
immutable Nixpkgs input (`packages.<system>.default`), not `lib.mkPackage` with an
overalls package set. Hosts take it through the public module's default
`programs.nix-compact.package`; the development shell and the `tool-nix-compact`
and `tool-nix-compact-host` targets name it directly. Both native checks test that
package, with build and stable test tooling respectively. The offline
host-enrollment fixture builds the same package from preloaded nix-compact and
nix-compact-Nixpkgs sources. ADR-0087's logging, privacy, budget and
build-result decisions and its opt-out/override precedence are unchanged.

## Alternatives

- Add a pinned nixpkgs-unstable input to overalls for `mkPackage`: the same
  contract change with one more lock to keep in step with nix-compact.
- Keep nix-compact at 2.34.9 in overalls until a stable channel ships 2.36: does
  not adopt the requested version.
- Move overalls' host input to unstable: changes every host package.

## Consequences

The hosts' Nix client, store and daemon libraries come from nix-compact's
unstable snapshot instead of nixos-26.05. Updating the nix-compact pin also
updates that Nix. `tool-nix-compact` and `tool-nix-compact-host` are now the same
derivation. The host-enrollment VM preloads one more Nixpkgs source.

## Invariants and verification

- Without an explicit override, hosts select exactly the nix-compact flake's
  package; `programs.nix-compact.enable = false` and an explicit `nix.package`
  keep ordinary NixOS precedence (configuration check).
- The patched package changes only the CLI relative to its upstream
  `nixVersions.nix_2_36` (configuration check).
- The enrollment fixture's in-VM package and its prebuilt `enrolled` package use
  the same expression, so the offline VM reuses the prebuilt output.

## Implementation evidence

- [Host module](../../../nix/domains/system/nix-compact.nix),
  [development shell](../../../devenv.nix),
  [package and check outputs](../../../nix/assemble/outputs.nix),
  [configuration check](../../../nix/domains/artifacts/nix-compact/configuration-check.nix)
  and [enrollment fixture](../../../nix/verification/tests/machines/host-enrollment/default.nix).
- nix-compact [`404e675`](https://github.com/ghuntley/nix-compact/commit/404e6750c864cf8e0c8e6b0e704994db90a29907)
  adapts the logger to the Nix 2.36 API; its core, native (50 real-build cases
  plus daemon, remote-protocol, TTY and SIGINT fixtures), native-development and
  configuration checks and its default package with upstream test gates passed
  on x86_64-linux on 2026-11-25. aarch64-darwin was not built (no builder).
- On 2026-11-25 all six assembled systems (dungarees, panterloons, salopettes
  and their `-base` variants) evaluated `nix.package` to exactly the flake's
  package, and the configuration check evaluated with every assertion true. The
  enrollment fixture's package expression evaluated to the same output path.
  Full host toplevels and the machine tests were not run: toplevel evaluation
  fails on trunk too, in devenv-nixpkgs' nodejs (`unexpected argument 'python'`).

## Open questions

None. Existing hosts receive the new package on their normal rebuild; this does
not claim a live fleet rollout.

## Related decisions

- [ADR-0087](0087-compact-nix-build-logs.md): compact Nix build logs.
- [ADR-0159](0159-remove-legacy-compatibility.md): removed the legacy adapters.
