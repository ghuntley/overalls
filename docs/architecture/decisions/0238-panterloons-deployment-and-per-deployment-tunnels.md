# ADR-0238: Panterloons deployment and per-deployment fleet tunnels

- ID: ADR-0238
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: fleet network, fleet addresses, fleet telemetry, Audi DNS, Nix fleet hosts
- Supersedes: none
- Superseded by: none

## Context

This decision was first published under the number 0235 (commit 644810bd). It
was renumbered because the Mila desktop work had already reserved that number
and the next one.

The Dungarees hardware failed and was replaced on 2026-10-20. The operator also
provisioned Panterloons, a second control-plane host intended to replace
Overalls: it runs the Overalls roles against its own empty database, uses the
same public names (`ghuntley.dev`, `apps.ghuntley.dev`), and receives data by
hand before Overalls retires. The operator asked that Dungarees serve
Panterloons rather than Overalls.

Until now the fleet had one WireGuard tunnel (`fleet0`, `10.90.0.0/24`) in which
Overalls (`.1`) was the only control plane, Dungarees (`.2`) its worker and
Salopettes (`.3`) the Susan relay. Fleet telemetry hard-coded the Overalls and
Dungarees host names, and Overalls' wildcard issuer named both Audi DNS replicas.

## Decision

The operator authorized this decision while provisioning Panterloons
(2026-10-20): Panterloons is a separate deployment with its own tunnel, fresh
secrets and an empty database, and Dungarees joins it.

- `fleet/fleet-network.nix` declares one tunnel per deployment. The Overalls
  tunnel holds Overalls `10.90.0.1` and Salopettes `10.90.0.3`; the Panterloons
  tunnel holds Panterloons `10.90.0.1` and Dungarees `10.90.0.2`. Addresses
  repeat across tunnels, every host peers only inside its own tunnel (checked at
  evaluation), and only a tunnel's `10.90.0.1` admits the control-plane ports.
- Fleet telemetry takes a per-deployment roster (`services.overallsOtelFleet.hosts`:
  a central host at `10.90.0.1` and an optional worker at `10.90.0.2`). Rules,
  objectives, scrape targets and collector counts follow the roster, so Overalls
  expects only itself and Panterloons expects Panterloons and Dungarees.
- Panterloons' public address and the replaced Dungarees' addresses are
  ADR-0233 names in the shared fleet-addresses document; Panterloons joins the
  reviewed fleet-wide source grants. Panterloons and Dungarees share one on-link
  network and route each other through the gateway, as Overalls and the former
  Dungarees did.
- Overalls' wildcard issuer names only its own Audi DNS replica until the DNS
  cutover; the operator accepted one replica for that period. The issuer's
  peer list therefore accepts one to eight distinct peers (previously two to
  eight) in both the Nix module and Marshall's configuration parser.
  [ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) reverts this bullet
  and moves Salopettes into the Panterloons tunnel.
- Public names stay on Overalls until the operator repoints DNS. ADR-0095 still
  applies: no host maps the control origin locally, so Panterloons cannot issue
  public certificates and its clients are refused by Overalls until cutover.

## Alternatives

- **One shared tunnel with two control planes:** both use `10.90.0.1` for the
  control-plane role and fleet clients resolve one origin, so a shared tunnel
  would need a renumbering of every literal and still mix two Marshall
  databases' workers.
- **Keep Dungarees on Overalls until cutover:** contradicts the operator's
  request and requires a second migration later.
- **Hosts-file override for the control origin on Panterloons:** rejected by
  ADR-0095.

## Consequences

- Each deployment's tunnel, telemetry roster and grants are independent; a
  mistake in one cannot route traffic into the other's control plane.
- Until the DNS cutover the `apps.ghuntley.dev` zone is split between the two
  deployments, and Panterloons has no public certificates.
- Data copied from Overalls into Panterloons must be re-keyed, because every
  Panterloons secret, including Marshall's application keys, is fresh.
- The former Dungarees control-plane row on Overalls is disabled and revoked;
  its recorded workload placements remain until reconciled.

## Invariants and verification

- Evaluation asserts that tunnel peers share a deployment.
- The otel rule evaluation tests cover an explicit Panterloons/Dungarees fixture
  roster and single-host and Panterloons rosters.
- `secrets check` confirms fleet-address recipients; the `fleet-addresses`
  machine test continues to exercise runtime uplinks and the firewall chain.

## Implementation evidence

- [`fleet-network.nix`](../../../fleet/fleet-network.nix) (per-deployment tunnels),
  reading tunnel membership, addresses and peers from the [fleet host roster](../../../nix/policy/fleet/hosts.nix)
  and tunnel ports from the [service roster](../../../nix/policy/fleet/services.nix);
  the roster's assertions and the [`fleet-roster` check](../../../nix/verification/tests/evaluation/fleet-roster.nix)
  enforce reciprocal same-tunnel peers and the `10.90.0.1` control plane.
- [`fleet-addresses.nix`](../../../nix/policy/network/fleet-addresses.nix) and
  [`allowed-hosts.nix`](../../../nix/policy/network/allowed-hosts.nix).
- [`otel-fleet/default.nix`](../../../nix/domains/system/otel-fleet/default.nix)
  (`hosts` roster) and the rule files it parameterizes. Since the Overalls host
  retired (2026-10-30), `hosts.central` and `hosts.worker` have no defaults and
  the rule files take `hosts` as a required argument, so every deployment and
  fixture names its own roster; production hosts read it from the
  [fleet host roster](../../../nix/policy/fleet/hosts.nix).
- Remaining gaps: Panterloons' roles and secrets, Dungarees' enrollment into
  Panterloons, the Susan origin for Panterloons, automatic Tailscale joining,
  and the DNS cutover are not yet implemented.

## Open questions

None.

## Related decisions

Amended by [ADR-0239](0239-salopettes-joins-panterloons-tunnel.md).
Amends [ADR-0090](0090-second-audi-dns-replica-on-worker.md) (the worker replica
moves with Dungarees), [ADR-0129](0129-fleet-otel-slos.md) (per-deployment
roster) and [ADR-0233](0233-fleet-addresses-from-sops.md) (new address names).
Keeps [ADR-0095](0095-dns-resolved-fleet-control-origin.md) and
[ADR-0075](0075-fleet-overlay-and-source-access.md).
