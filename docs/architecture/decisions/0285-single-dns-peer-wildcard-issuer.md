# ADR-0285: Wildcard issuer accepts a single DNS peer

- ID: ADR-0285
- Date: 2026-11-26
- Status: accepted
- Implementation: partial
- Components: Marshall wildcard ACME, NixOS Marshall module, fleet control-plane role
- Supersedes: none
- Superseded by: none

## Context

Before issuing the public `apps.ghuntley.dev` wildcard, Marshall's wildcard
issuer checks that every listed authoritative Audi DNS peer serves the DNS-01
TXT proof. [ADR-0090](0090-second-audi-dns-replica-on-worker.md) placed a
second Audi DNS replica on the worker so that two independent replicas
existed. [ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) then restored
a two-to-eight peer bound in the Nix module and in Marshall's parser.

[ADR-0284](0284-overalls-replaces-panterloons-and-dungarees.md) left one
machine, `overalls`, with no peer Audi DNS replica, and set the default
`peerNameservers` to empty. The issuer was therefore configured with one peer
(overalls' own `overallsService` address). On 2026-11-26 the first
`host enroll` of overalls failed at evaluation of `fleet/hosts/overalls:system`
with "Wildcard ACME requires a local issuer instance, ingress zone and two to
eight distinct DNS peers." Marshall's `FleetACMEConfig` and
`CertificateAuthority` would also have rejected the configuration at runtime.

## Decision

The wildcard issuer accepts one to eight distinct authoritative DNS peers.
The Nix assertion in `nix/domains/system/marshall.nix`, Marshall's
`FleetACMEConfig.from_env/1` and `CertificateAuthority` all apply the same
bound, matching `ACME.Propagation.check/3`, which already accepts one to eight.
Every other check is unchanged: peers stay distinct, each peer gives exactly
one of `address` or `addressFile`, and the issuer instance and ingress zone
are still required.

This changes only the issuer's propagation peers. Audi's zone keeps two to
eight NS names (`ns1`/`ns2.ghuntley.dev`), and the Inception public endpoint
bound in `OverallsProtocol.InceptionPublic` is unchanged.

The operator authorized this on 2026-11-26 by choosing "Allow one DNS server"
over disabling wildcard ACME or running a second replica on overalls. This
reverts the wildcard-issuer part of ADR-0239.

## Alternatives

- **Disable wildcard ACME on overalls:** keeps the two-peer bound but leaves
  `apps.ghuntley.dev` without a certificate even after the DNS cutover.
- **A second Audi DNS replica on overalls:** satisfies the count without real
  independence, which ADR-0090 already rejected as a hidden single point of
  failure.
- **List the one replica twice:** the distinctness checks reject it, and it
  would misstate what was checked.

## Consequences

- A single-host deployment can issue and renew its wildcard. The one replica
  is a single point of failure for the delegated zone, as the host already is
  for the whole deployment (ADR-0284).
- A deployment with two or more replicas still checks every listed peer, so
  restoring a second replica needs only a non-empty `peerNameservers`.
- A misconfiguration that drops a peer is no longer caught by the bound. The
  control-plane role still always lists the host's own service address.

## Invariants and verification

- Exactly 1..8 distinct peers are accepted; zero, nine, or duplicate peers
  are rejected. `fleet_acme_test.exs` checks this as a Hegel property over 0..10
  peers, and the `wildcardNameserverCount` case in the module-configuration
  evaluation check covers 1, 8, 0, 9 and duplicate peers.
- `fleet/hosts/overalls:system` evaluates with `peerNameservers = [ ]`.

## Implementation evidence

- [`marshall.nix`](../../../nix/domains/system/marshall.nix) assertion,
  [`fleet_acme_config.ex`](../../../marshall/lib/marshall/ingress/fleet_acme_config.ex)
  (contract `fleet-acme-issuer-selection`) and
  [`certificate_authority.ex`](../../../marshall/lib/marshall/ingress/certificate_authority.ex).
- [`fleet_acme_test.exs`](../../../marshall/test/marshall/ingress/fleet_acme_test.exs)
  and the [module-configuration evaluation](../../../nix/verification/tests/evaluation/module-configuration.nix).
- Remaining: overalls' enrollment with this change, and a live issuance after
  the DNS and router cutover in ADR-0284.

## Open questions

None.

## Related decisions

Reverts the wildcard-issuer peer bound of
[ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) for single-replica
deployments. Follows [ADR-0284](0284-overalls-replaces-panterloons-and-dungarees.md).
Related to [ADR-0090](0090-second-audi-dns-replica-on-worker.md) and
[ADR-0199](0199-memory-suspension-and-demand-wake.md).
