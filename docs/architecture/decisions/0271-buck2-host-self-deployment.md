# ADR-0271: Hosts self-deploy by building their Buck2 deployment target

- ID: ADR-0271
- Date: 2026-10-30
- Status: accepted
- Implementation: planned
- Components: host updates, build, NixOS deployment
- Supersedes: none
- Superseded by: none

## Context

Each fleet host updates itself with
[runtime.py](../../../nix/domains/system/auto-update/runtime.py). It clones
the candidate revision into `checkouts/<revision>` and runs
`nix build <checkout>#nixosConfigurations.<host>…` through an isolated Nix
daemon (the `update-builds-use-isolated-daemon` contract). The flake loses its
`nixosConfigurations` once Buck2 becomes the only build entry point
([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)). The user decided
on 2026-10-30 that hosts run buck2 locally.

## Decision

1. **Deployment target.** Each host has a Buck2 target,
   `//fleet/hosts/<host>:deployment`, whose output is the NixOS system
   closure. Its per-host parameters (crash-dump encryption, antithesis flags,
   private service roots) are target attributes. An assembly assertion checks
   that they match the module options.
2. **Updater.** The updater runs
   `tools/buck2 build //fleet/hosts/<host>:deployment --show-output`.
   - It always uses one fixed checkout path and isolation directory, rather
     than a new directory per revision, so the daemon and buck-out stay warm.
   - It activates exactly the closure that buck2 reports.
   - It runs `buck2 kill` when it times out or cleans up, because buckd
     outlives the updater's process group.
3. **Cache.** Hosts read the NativeLink cache
   ([ADR-0272](0272-nativelink-remote-cache-and-execution.md)) and fall back to
   building locally. They never upload to it.
4. **Revision.** Assembly receives the candidate revision as an argument in
   place of `self.rev`, so deployment telemetry
   ([ADR-0259](0259-deployment-revision-telemetry.md)) keeps naming the
   deployed source.
5. **Activation gate.** No change removes `nixosConfigurations` until every
   host, including the `-base` fixtures, reports the Buck2 updater active.

Authorization: the user's 2026-10-30 answer that hosts run buck2 locally, and
the approved migration plan (M2).

## Alternatives

- **CI builds closures and hosts substitute them.** This is less work on each
  host, but it makes hosts depend on CI to update and changes the recovery
  model, where each host verifies and builds its own candidate.
- **Keep a flake output only for hosts.** This is a backwards-compatibility
  layer, which the user rejected, and it would leave two build definitions of
  every system.

## Consequences

- Hosts gain buck2, the cells closure, git and Nix. Their disk use and their
  first cold build grow.
- The updater's in-VM fixtures must become offline Buck2 fixture repositories.
- Machine tests for auto-update, credential rotation, host conversion and host
  enrolment verify the change.

## Invariants and verification

- The updater activates only the closure printed by the deployment target for
  the verified candidate revision.
- buckd never survives an updater timeout. A test is planned for the
  auto-update machine suite.
- Telemetry names the candidate revision. Checked by the
  `deployment-revision-source` contract, which will be updated in M2.
- **Failure case:** a cache entry produced from a different revision would be
  activated without being caught. Actions are content-addressed and hosts
  never upload, so a poisoned entry would need a compromised CI uploader.
  [ADR-0272](0272-nativelink-remote-cache-and-execution.md) covers that
  boundary.

## Implementation evidence

No implementation yet (milestone M2).

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md),
  [ADR-0272](0272-nativelink-remote-cache-and-execution.md),
  [ADR-0259](0259-deployment-revision-telemetry.md) and
  [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
- [ADR-0036](0036-automatic-host-updates.md) and its successors define
  verified automatic host updates. This record changes only how the candidate
  is built.
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
