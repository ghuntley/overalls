# Overalls replaces Panterloons and Dungarees (2026-11-26)

## Scope

This review covers [ADR-0283](../decisions/0283-on-premises-metal-hosts.md)
(the `metal` host platform) and
[ADR-0284](../decisions/0284-overalls-replaces-panterloons-and-dungarees.md)
(one on-premises control plane, `overalls`, in place of the lost Panterloons and
Dungarees). It reviews the fleet roster, fleet network, fleet builds, remote
builders, Ziggy's remote Underclass origin, the secret inventory and the
operator documentation. It does not claim the live host is enrolled or serving:
enrollment, the tailnet join, the second bootstrap stage and the DNS and router
cutover are still open.

## Findings and decisions

1. **High — a single host carries the whole deployment.** Marshall, the
   database, telemetry, Audi gateway and DNS, Porsche and every Lilly guest now
   share one machine and one system disk. No failover exists. Off-host Restic
   backups ([ADR-0070](../decisions/0070-host-recovery-backups.md)) are the only
   recovery path, and production backups still need their S3 document. The
   operator accepted this because no second machine exists; ADR-0284 records it
   as a consequence and leaves the second machine's role as an open question.

2. **Resolved — reused secrets depend on the lost disks being unrecoverable.** The
   CA signers, database and Marshall keys, OAuth, SMTP and Cachix credentials
   are carried over under `overalls-*` names and resealed to the new host key.
   Resealing changes who can decrypt the ciphertext. It does not revoke the
   plaintext the lost hosts held in `/run/overalls-secrets` or their own SOPS
   identities. Host-bound material is regenerated (WireGuard key, Git deploy
   document) and the build and remote-builder keys are deleted. On 2026-11-26
   the operator confirmed that all data on both lost machines was destroyed, so
   no carried-over value is rotated. Should that ever prove wrong, rotate the
   carried-over values through `encrypt --replace` and the CA rotation
   procedures.

3. **Medium — the roster had to admit a deployment without delegation.** The
   roster, `fleet-builds.nix` and the control-plane remote-builder wiring
   assumed at least one build peer. `builds = null` is now an explicit roster
   shape, and the control plane enables remote builders only when it is itself
   a registered builder with a peer. Evaluation tests moved to synthetic
   fixture fleets so they keep covering the multi-host shapes without depending
   on production hosts.

4. **Low — Salopettes keeps a tunnel slot with no peer.** Its fleet-network
   module still evaluates against the overalls deployment, but Marshall's Susan
   pokes stop until the operator forwards the WireGuard port and re-peers it.

5. **Low — first activation is bootstrap-only.** As in ADR-0246, Porsche,
   Audi, Ziggy, Galileo, Brady and guest telemetry intake wait for this
   deployment's own Marshall to issue credentials. `overalls-ziggy` still holds
   a credential issued by the lost Marshall and must be reissued.

## Verification

- `tools/buck2 run //:secrets -- rekey` reconciled 21 documents and
  `secrets -- check` passed for all 34 inventoried documents. Every document in
  overalls' credentials list carries the installed host key's recipient.
- The base system was installed from `d1462b206`. The host was reached over
  SSH after reboot, with both LAN addresses, an ONLINE `zroot` pool, the Lilly
  quota and `/dev/kvm`.
- Evaluation checks, both deployment builds and precommit are recorded in the
  change that lands this review.

## Remaining gaps

Enrollment and `host verify`, the tailnet address in the roster, second-stage
credentials with `bootstrap = false`, public DNS and router forwarding, backups,
and Salopettes re-peering.
