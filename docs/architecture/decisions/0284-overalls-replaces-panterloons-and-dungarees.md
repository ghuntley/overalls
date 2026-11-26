# ADR-0284: Overalls replaces Panterloons and Dungarees

- ID: ADR-0284
- Date: 2026-11-26
- Status: accepted
- Implementation: partial
- Components: NixOS hosts, fleet host roster, fleet network, fleet builds, Ziggy, secrets
- Supersedes: ADR-0246
- Superseded by: none

## Context

On 2026-11-25 the operator reported that Panterloons (the control plane serving
`ghuntley.dev`) and Dungarees (its Lilly worker and build peer) were both
permanently lost, and asked for them to be deleted from the repository. In
their place a new on-premises machine, `overalls`, is to run a copy of
Panterloons' deployment. It is declared as a `metal` host
([ADR-0283](0283-on-premises-metal-hosts.md)) on a private LAN: primary
10.10.10.1 and service 10.10.10.2 behind gateway and DNS 10.10.10.254.

The name was used once before. An earlier `overalls` host was retired on
2026-10-30 (see [ADR-0246](0246-panterloons-control-plane-deployment.md)
evidence). Its deleted `secrets/overalls-*` documents are not restored.

[ADR-0246](0246-panterloons-control-plane-deployment.md) named Panterloons
and Dungarees directly. Its typed `overalls.controlPlaneHost` option and
two-stage bootstrap stay in use.

## Decision

The operator directed this on 2026-11-25. They chose the options for
addressing, secrets and Salopettes in the same session.

- **One deployment, `overalls`.** It is the control plane, the central
  telemetry host and the only Lilly host. It has no telemetry worker
  (`telemetry.worker = null`), and Lilly guests run on overalls itself.
- **No build delegation.** The roster's `builds` may be `null` for a
  deployment without delegation, and `overalls` declares `null`. Fleet builds
  ([ADR-0248](0248-fleet-build-scheduling.md)) and reciprocal remote-builder
  caches ([ADR-0086](0086-reciprocal-nix-caches.md)) are off until a second
  builder exists. The control plane enables remote builders only when it is
  itself a registered builder with at least one peer.
- **The control-plane role is retained from ADR-0246.**
  `fleet/hosts/overalls/configuration.nix` imports the shared control-plane
  role with `name = "overalls"` and no peer Audi DNS replicas. The default
  `peerNameservers` is now empty, so the wildcard issuer has one DNS peer
  ([ADR-0285](0285-single-dns-peer-wildcard-issuer.md)). The first activation uses
  `bootstrap = true`, and the second stage follows ADR-0246: once the
  deployment's own Marshall has bound Lilly and issued the Porsche, Audi, Ziggy
  and Galileo credentials, they are committed and `bootstrap` is set to `false`.
- **Addressing.** `overallsPrimary` (10.10.10.1) carries Marshall, the proxy
  and Porsche. `overallsService` (10.10.10.2) carries the Audi gateway and DNS.
  Both values live only in the fleet-addresses SOPS document. The
  `dungarees*` and `panterloons*` address names and allowed-host grants are
  removed.
- **Salopettes stays in the overalls tunnel with no peer.** It keeps tunnel
  address 10.90.0.3, and only the Panterloons peer is removed. Re-peering
  Salopettes with Overalls is a later, separate change.
- **Ziggy's remote Underclass origin** ([ADR-0280](0280-remote-underclass-and-safe-agent-retries.md))
  is renamed to the exact `https://overalls.lorikeet-bangus.ts.net` origin.
  Nothing currently selects it.
- **Secrets are reused under new names and resealed.** Each shared
  `panterloons-*` document becomes `overalls-*` and is resealed to the
  installed overalls host key plus the recovery recipients. That covers the
  database, Marshall, TLS, Brady signer, SSH host CA, OAuth, SMTP, Cachix and
  service tokens, so CA chains and external credentials keep working. Material
  bound to the lost hosts is regenerated: the WireGuard key and the Git deploy
  bundle. The fleet-builds and remote-builders documents, and all `dungarees-*`
  documents, are deleted. The database starts empty because Panterloons' data
  is lost.

## Alternatives

- **Rename Panterloons in place:** this would keep the panterloons name for a
  different machine. That conflicts with every receipt, host key and address
  the dead host held.
- **Keep a telemetry worker or build peer slot:** no second machine exists.
  Fixture-based tests keep those shapes covered instead.
- **Re-peer Salopettes now:** this needs a UDP port forward on the home
  router, and the operator deferred it.
- **Regenerate every secret:** this would break the shared CA chains and
  external OAuth, SMTP and Cachix credentials for no security gain, because
  only the hosts were lost, not the recovery identity, and the operator
  confirmed on 2026-11-26 that all data on both hosts was destroyed.

## Consequences

- `ghuntley.dev`, `ns1` and `ns2` must be repointed at the LAN's public
  address, and the router must forward the public ports to 10.10.10.1 and
  10.10.10.2. Until then public ingress and ACME issuance fail.
- One host now carries the whole deployment, including guests, with no
  failover. Losing it loses the deployment again, apart from off-host backups.
- Salopettes' Susan pokes from Marshall stop until it is re-peered.
- `scripts/provisioning_benchmark.py` and its tests are removed. The runner
  measured the two-host fleet only, and the operator does not need
  provisioning benchmarks for the single-host deployment. ADR-0130 has no
  accepted matched performance result.

## Invariants and verification

- The roster accepts `builds = null` and still rejects malformed delegation
  shapes. `fleet-roster-configuration` checks this against a synthetic
  three-host fixture fleet, as well as the production roster.
- `fleet-builds-configuration` exercises the module with a synthetic
  scheduler and peer, and checks that production `overalls` delegates nothing.
- `remote-builders-configuration` checks that the production fleet has no
  reciprocal builders.
- `secrets check` passes with every `overalls-*` document sealed to the
  installed host key and the recovery users.

## Implementation evidence

- [Fleet host roster](../../../nix/policy/fleet/hosts.nix),
  [fleet address names](../../../nix/policy/network/fleet-addresses.nix) and
  [Overalls' configuration](../../../fleet/hosts/overalls/configuration.nix).
- The [fleet roster](../../../nix/verification/tests/evaluation/fleet-roster.nix),
  [fleet builds](../../../nix/verification/tests/evaluation/fleet-builds.nix) and
  [remote builders](../../../nix/verification/tests/evaluation/remote-builders.nix) evaluation checks.
- [Architecture review](../reviews/2026-11-26-overalls-replaces-panterloons.md).
- 2026-11-26: the base system was installed on overalls from `d1462b206`, and
  its installed host key was recorded.
- 2026-11-26: the `overalls-*` documents, fleet addresses and the new
  WireGuard document were resealed with `secrets rekey`, `secrets check`
  passed for all 34 inventoried documents, and `host.json` lists the
  credentials.
- Remaining: enrollment (including the `overalls-git` document written by
  `host enroll --deploy-key`), the tailnet join and roster tailnet address, the second-stage
  credentials with `bootstrap = false`, DNS and router cutover, and
  re-peering Salopettes.

## Open questions

- When a second machine is added, decide whether it becomes a telemetry
  worker, a build peer or both.

## Related decisions

Supersedes [ADR-0246](0246-panterloons-control-plane-deployment.md). Builds on
[ADR-0283](0283-on-premises-metal-hosts.md),
[ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md),
[ADR-0239](0239-salopettes-joins-panterloons-tunnel.md),
[ADR-0248](0248-fleet-build-scheduling.md) and
[ADR-0280](0280-remote-underclass-and-safe-agent-retries.md).
