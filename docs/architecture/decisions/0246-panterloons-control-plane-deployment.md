# ADR-0246: Panterloons control-plane deployment

- ID: ADR-0246
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: NixOS hosts, Marshall, secrets, fleet network
- Supersedes: none
- Superseded by: none

## Context

The operator asked on 2026-10-20 for Panterloons to be a copy of the Overalls
deployment: Marshall, PostgreSQL, the proxy, Porsche, Lilly, Audi, Brady,
Ziggy, Galileo, Enrico, Underclass, the log store and monitoring. It should
have an empty database and fresh secrets, serve `ghuntley.dev` after a DNS
cutover, and use Dungarees as its worker. Overalls keeps serving until the
operator copies data by hand and retires it. [ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md)
already gives Panterloons its own tunnel.

The Overalls roles in `fleet/roles/control-plane/` for shared roles; the Overalls host identity is retired named their own secrets,
addresses and administrative listener directly. A fresh deployment also cannot
start every role at once: Porsche, Audi, Audi DNS, Ziggy and Galileo
credentials, and the Lilly binding, are issued by that deployment's own
Marshall.

## Decision

The operator directed this on 2026-10-20.

- The Overalls roles take a typed `overalls.controlPlaneHost` option (name,
  peer DNS replica addresses, Tailscale administrative address, telemetry
  worker, Audi relay, bootstrap). Its defaults are Overalls' values, so
  Overalls' system is unchanged. Secrets come from
  `secrets/<name>-*.enc.json`, and addresses from `<name>Primary` and
  `<name>Service`.
- `fleet/hosts/panterloons/configuration.nix` imports those roles with
  Panterloons' values; there is one copy of the role code and of its
  contracts.
- `bootstrap = true` is the first activation of a new deployment. Porsche,
  Audi, Audi DNS, Audi's private frontend, Brady and guest telemetry intake
  stay off, and administrative SSH keeps the base host's port 22. Once the
  deployment's Marshall has bound Lilly and issued those credentials, the
  operator commits them and sets `bootstrap = false`. That performs the
  documented Porsche port handoff to Tailscale-only port 2222.
- Fresh secrets: a new database password, new Marshall application keys and
  token, Underclass and Enrico tokens, log-store passwords and WireGuard and
  builder keys. New TLS leaves and a new Brady signer are issued from the
  shared recovery CAs, so clients and guests keep trusting them at cutover.
- Some material is shared. The SSH host CA key, SMTP, GitHub OAuth, Cachix and
  Serper credentials keep their values. The Enrico leaf is reused because its CA
  key has no recovery document; it names only the host-local
  `enrico.fleet.internal`.
- Panterloons' Cloak keyring encrypts with a new key. It retains Overalls' key
  for decryption only, so data copied by hand from Overalls stays readable.

## Alternatives

- **Copy the role files:** two diverging copies, and duplicate contract IDs.
- **Move the roles to a shared directory:** breaks links from many accepted
  ADRs and reviews for no behavioural gain.
- **Placeholder credentials for the first activation:** services would start
  and fail authentication instead of staying deliberately off.
- **Share Overalls' Cloak key only:** "fresh everything" was the operator's
  choice. The retained key decrypts copied data without granting old
  ciphertext any new authority.

## Consequences

- Panterloons becomes a fleet builder (96 logical CPUs). Overalls, previously
  without an enrolled peer, gains it as a remote builder.
- Until the operator moves `ghuntley.dev` DNS, Panterloons' public proxy and
  wildcard issuance cannot obtain certificates, and its fleet clients reach
  Overalls, which refuses them harmlessly ([ADR-0095](0095-dns-resolved-fleet-control-origin.md)).
- Anyone holding the recovery identity can decrypt Overalls' Cloak key, as
  before. Panterloons' host key can now decrypt it too.

## Invariants and verification

- Overalls' evaluated system was byte-identical before and after the option
  was introduced; its later change adds only Panterloons as a builder.
- `remote-builders-configuration` checks each builder against its measured
  CPU count; `fleet-firewall-configuration`, `module-configuration`,
  `enrollment-configuration`, `underclass-configuration` and the telemetry
  checks evaluate the fleet including Panterloons.
- `secrets check` passes with every `panterloons-*` document sealed to
  Panterloons and the recovery users.
- No machine test exercises the bootstrap-to-full transition.

## Implementation evidence

- [`control-plane.nix`](../../../fleet/roles/control-plane/control-plane.nix) and
  [Panterloons' configuration](../../../fleet/hosts/panterloons/configuration.nix).
- The [fleet host roster](../../../nix/policy/fleet/hosts.nix) supplies the control plane's administrative address and
  telemetry worker defaults.
- [Remote builders](../../../fleet/remote-builders.nix) and its
  [evaluation](../../../nix/verification/tests/evaluation/remote-builders.nix).
- Remaining: activation, Lilly enrollment against Panterloons' own Marshall,
  the issued credentials, `bootstrap = false`, Dungarees' enrollment, and the
  DNS cutover.

## Open questions

None.

## Related decisions

Builds on [ADR-0238](0238-panterloons-deployment-and-per-deployment-tunnels.md),
[ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) and
[ADR-0241](0241-sops-tailscale-auto-join.md).
