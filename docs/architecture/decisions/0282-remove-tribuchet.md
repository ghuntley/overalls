# ADR-0282: Remove tribuchet from fleet builds

- ID: ADR-0282
- Date: 2026-11-25
- Status: accepted
- Implementation: partial
- Components: NixOS, Nix daemon, fleet secret delivery, Panterloons, Dungarees
- Supersedes: ADR-0248 (tribuchet hub and workers only)
- Superseded by: none

## Context

ADR-0248 scheduled Panterloons' and Dungarees' builds through a tribuchet hub on
Panterloons, workers on both hosts and a patched hub Nix using the experimental
`external-builders` hook. On 2026-11-25 the user asked to remove tribuchet. The
same change moves compact Nix to 2.36.0 (ADR-0281), onto which tribuchet's
external-builder patches would otherwise have had to be stacked.

## Decision

Remove the tribuchet flake input, hub, workers, external-builder wrapper, hub
Nix patches, tribuchet CA and certificates, the roster's `hub` role and the
`TRIBUCHET_WORKER_KEY`/`TRIBUCHET_HUB_KEY` entries from the fleet-build SOPS
documents. Keep the rest of ADR-0248: Panterloons remains the one scheduler,
without `nix.buildMachines`; Dungarees delegates through the ordinary build hook
to Panterloons' mTLS `grpc://` store; both substitute from each other over
`grpc://` with the same trusted/read-only access rules, closed listeners and
required signatures. Both hosts run the unmodified compact Nix package.

## Alternatives

Rebase tribuchet's patches onto Nix 2.36.0 and keep the hub: not requested.
Remove the whole ADR-0248 setup and return both hosts to ADR-0086 ssh-ng caches:
the user asked only to remove tribuchet.

## Consequences

Panterloons builds its own derivations locally; Dungarees' builds run on
Panterloons. Dungarees' CPUs no longer serve Panterloons' builds, and identical
derivations requested by both hosts are no longer deduplicated by a hub; they
are shared through the `grpc://` caches once built. No host runs a patched Nix or
`external-builders`. While Panterloons' grpc daemon is down, Dungarees builds
locally.

## Invariants and verification

ADR-0248's grpc invariants hold unchanged; additionally neither host configures
`external-builders` and both use exactly the nix-compact package. The
[evaluation check](../../../nix/verification/tests/evaluation/fleet-builds.nix)
and [two-machine check](../../../nix/verification/tests/machines/fleet-builds/default.nix)
assert delegation to the scheduler, scheduler-local builds, reciprocal grpc
substitution, refusals and the scheduler-down fallback.

## Implementation evidence

- [Module](../../../nix/domains/system/fleet-builds.nix),
  [registry](../../../fleet/fleet-builds.nix),
  [roster](../../../nix/policy/fleet/hosts.nix) and [flake](../../../flake.nix)
  no longer reference tribuchet; the SOPS documents hold only `GRPC_KEY`.
- On 2026-11-25 the fleet-builds evaluation cases (restricted to the fleet
  module's own assertions, since full evaluation fails on trunk in
  devenv-nixpkgs' nodejs) all passed on the real Panterloons and Dungarees
  configurations; no assembled system defines a tribuchet unit or
  `external-builders`. The two-machine test was updated but not run.

## Open questions

None. Existing hosts drop the hub and workers on their normal rebuild; this
does not claim a live fleet rollout.

## Related decisions

[ADR-0248](0248-fleet-build-scheduling.md),
[ADR-0086](0086-reciprocal-nix-caches.md),
[ADR-0281](0281-nix-compact-own-package-input.md).
