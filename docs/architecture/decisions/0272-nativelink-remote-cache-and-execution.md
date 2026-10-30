# ADR-0272: NativeLink remote cache and execution for Buck2

- ID: ADR-0272
- Date: 2026-10-30
- Status: accepted
- Implementation: planned
- Components: build, fleet infrastructure, CI
- Supersedes: none
- Superseded by: none

## Context

Buck2 caches actions locally ([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)).
Without a shared cache, CI runners, developers and self-deploying hosts
([ADR-0271](0271-buck2-host-self-deployment.md)) would each compile cold. The
fleet already runs Nix build scheduling over the tailnet with a private CA and
SOPS client credentials ([ADR-0248](0248-fleet-build-scheduling.md)). The user
chose a NativeLink cache plus remote execution on 2026-10-30.

## Decision

1. **Placement.** NativeLink's scheduler and its content and action caches
   (CAS/AC) run on panterloons. Remote-execution workers run on panterloons
   and dungarees.
2. **Network and credentials.** The service listens only on the tailnet, with
   an assertion that its port is never open on public interfaces. Clients
   authenticate with certificates from a private CA (`fleet/buck-re/`), and
   each host's client certificate is held in SOPS.
3. **Who may write.** CI runners may upload and use remote execution. They
   join with an ephemeral Tailscale key. Hosts may only read the cache.
   Developers use the tailnet.
4. **Workers.**
   - Workers run in the pool-mount-free namespace of
     [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
   - They fetch the `buckCells` closure from the signed Cachix
     ([ADR-0188](0188-signed-overalls-cachix-substitution.md)).
   - Actions carry an `overalls-cells=<hash>` platform property, so they run
     only on workers that have those toolchains.
5. **What stays local.** Nix store imports, NixOS assembly, machine tests and
   the non-hermetic Mila platform builds always run locally, and their
   outputs are never uploaded.
6. **Order.** The cache ships before the Rust and Elixir moves (M4b), so host
   updates do not cold-compile. Remote-execution workers follow in M10.
7. **Fallback.** Without credentials, actions run locally.

Authorization: the user's 2026-10-30 answer choosing a NativeLink cache plus
remote execution, and the approved migration plan.

## Alternatives

- **Buck2 local cache only.** This is simplest, but every host deployment and
  CI job compiles cold.
- **Cachix or a Nix binary cache for Buck2 outputs.** Buck2 needs a REv2
  action cache, and Nix caches store paths, not action results.
- **BuildBuddy or EngFlow as a hosted service.** They are mature, but they put
  build inputs off the fleet and add a vendor credential.

## Consequences

- Warm builds for CI, developers and hosts.
- New fleet services to operate. A cache outage degrades builds to local
  only and does not block them.
- Remote execution covers Linux x86_64 only.

## Invariants and verification

- Only CI identities can write to the action cache, and host credentials are
  read-only. Planned test: a NixOS machine test with a client upload refusal.
- The listener is never reachable off the tailnet. Planned: a module
  assertion and a machine test.
- Outputs of `local_only` actions are never uploaded (`allow_cache_upload =
  False` in the rules).
- **Failure case:** a compromised CI runner could upload poisoned action
  results that hosts then trust. The mitigation is that the CI uploader runs
  only on trunk and pull-request jobs from this repository. The residual risk
  is recorded in the migration review.

## Implementation evidence

No implementation yet (milestones M4b and M10).

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md),
  [ADR-0271](0271-buck2-host-self-deployment.md),
  [ADR-0248](0248-fleet-build-scheduling.md),
  [ADR-0188](0188-signed-overalls-cachix-substitution.md) and
  [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
