# ADR-0239: Salopettes joins the Panterloons tunnel

- ID: ADR-0239
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: fleet network, Susan placement, Audi relay, Marshall wildcard ACME
- Supersedes: none
- Superseded by: none

## Context

[ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md) gave
Panterloons and Dungarees their own tunnel and kept Salopettes, the Susan relay
host, in the Overalls tunnel. Marshall's Susan origin is the compiled constant
`https://notifications.overalls.dev`, and ADR-0233 routes it over `fleet0` to
Salopettes (`10.90.0.3`). Overalls is to retire once its data is copied to
Panterloons.

ADR-0238 also lowered the wildcard issuer's DNS peer minimum to one so that
Overalls could name only its own Audi DNS replica.

## Decision

The operator directed both changes on 2026-10-20.

- Salopettes moves to the Panterloons tunnel at `10.90.0.3` and peers only with
  Panterloons. Panterloons' Marshall therefore reaches Susan over `fleet0` with
  the unchanged compiled origin, and no per-deployment Susan origin is needed.
- Overalls remains alone in its tunnel. A tunnel host may now have no peers;
  every other fleet transport invariant is unchanged. Overalls' Audi relay is
  disabled because no gateway peer remains.
- Overalls no longer maps the Susan origin to `10.90.0.3`; Marshall resolves it
  through public DNS.
- The wildcard issuer again requires two to eight distinct DNS peers, in the
  Nix module and in Marshall's parser. Overalls keeps naming both Audi DNS
  replica addresses (`OVERALLS_SERVICE_IPV4` and `DUNGAREES_SERVICE_IPV4`). This
  reverts that part of ADR-0238.

## Alternatives

- **Salopettes in both tunnels:** both tunnels use `10.90.0.1` for their
  control plane, so one `fleet0` interface cannot peer with both.
- **Keep Salopettes with Overalls until it retires:** contradicts the operator's
  direction and leaves Panterloons without a tunnel path to Susan.

## Consequences

- Overalls' push pokes depend on the public `notifications.overalls.dev` path.
  On 2026-10-20 that name resolved to a proxy that answered HTTPS with a
  redirect to itself, so Overalls cannot deliver pokes until the proxy forwards
  HTTPS to Salopettes or Overalls retires.
- `DUNGAREES_SERVICE_IPV4` now holds the replacement Dungarees' additional
  address (correction, 2026-10-20; `PANTERLOONS_SERVICE_IPV4` was added
  alongside it). Dungarees serves Audi DNS only for Panterloons, so Overalls'
  second DNS peer stays unreachable and wildcard renewal waits on it, as it has
  since the hardware failed.

## Invariants and verification

- Evaluation asserts that tunnel peers share a deployment, and the existing
  fleet transport assertions still apply to a host with no peers.
- `fleet_acme_test.exs` and the Nix assertion keep the two-to-eight peer bound.

## Implementation evidence

- [`fleet-network.nix`](../../../fleet/fleet-network.nix) and the [fleet host roster](../../../nix/policy/fleet/hosts.nix) (tunnel membership)
  and [`nix/domains/system/fleet-network.nix`](../../../nix/domains/system/fleet-network.nix)
  (no-peer host).
- [`overalls/configuration.nix`](../../../fleet/roles/control-plane/configuration.nix),
  [`overalls/services.nix`](../../../fleet/roles/control-plane/services.nix) and
  [`salopettes/configuration.nix`](../../../fleet/hosts/salopettes/configuration.nix).
- Remaining gaps: Panterloons is not enrolled, so no handshake between
  Panterloons and Salopettes has run; the public Susan path is not repaired.

## Open questions

None.

## Related decisions

Amends [ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md)
(Salopettes' tunnel and the DNS peer minimum) and
[ADR-0233](0233-fleet-addresses-from-sops.md) (Susan fleet path).
