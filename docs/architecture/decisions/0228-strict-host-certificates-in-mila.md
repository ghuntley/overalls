# ADR-0228: Strict SSH host-certificate verification in Mila

- ID: ADR-0228
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Mila, protocol
- Supersedes: none
- Superseded by: none

## Context

Porsche presents an Ed25519 host certificate from the deployment's SSH CA and
publishes the CA in `https://HOST/bin/ssh-trust.json`
([ADR-0124](0124-unified-ssh-host-ca.md)); Lyra already trusts deployments this
way. A phone on hostile networks must not fall back to trust-on-first-use.

## Decision

1. Mila fetches the trust document over HTTPS with the system trust store and
   no redirects, and validates it like Lyra: strict keys, version 1, the
   management host equal to the origin, an unretired document within 8 KiB.
2. The first valid document is pinned. A later document with a different CA,
   host or zone is refused; a failed fetch falls back only to an unretired pin.
3. Mila negotiates only `ssh-ed25519-cert-v01@openssh.com` and accepts the host
   only if the certificate is a host certificate from the pinned CA naming the
   management host, inside its validity window, with a valid signature. The
   check runs in the key exchange, before user authentication, so an untrusted
   host never sees the device key's signature.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Trust on first use.** Rejected: the first connection is the one an
  attacker controls.
- **Pinning the host key.** Rejected: it breaks on certificate rotation that
  ADR-0124 performs routinely.

## Consequences

A deployment that rotates its CA must be re-added by the user; that is the
intended explicit reconciliation.

## Invariants and verification

- Elixir-issued certificates in `protocol/test/fixtures/ssh_host_certificates.json`
  get the same verdict in Dart as in `OverallsProtocol.SSHHostCertificate`.
- Against a stock OpenSSH server: a certificate from another CA, for another
  principal or expired is refused before any command runs, and a host without
  a certificate cannot negotiate. Disabling the check makes those tests fail
  (mutation-checked).
- Against the real Porsche release: refusal happens before Porsche records an
  authentication; the pinned CA's certificate and the device key connect.

## Implementation evidence

- [`mila/packages/mila_core/lib/src/host_trust.dart`](../../../mila/packages/mila_core/lib/src/host_trust.dart) and `test/host_trust_test.dart`.
- [`mila/packages/mila_transport/lib/src/ssh_porsche.dart`](../../../mila/packages/mila_transport/lib/src/ssh_porsche.dart) (`resolveTrust`,
  `checkHostKey`, `SshPorscheConnector`) and `test/ssh_porsche_test.dart`, run
  in the `mila-transport` Nix check.
- The dartssh2 patch (ADR-0227).
- [`nix/verification/tests/machines/mila-porsche/`](../../../nix/verification/tests/machines/mila-porsche), passed against the
  real Porsche release ([M1 review](../reviews/2026-10-18-mila-m1.md)).

## Open questions

None.

## Related decisions

[ADR-0124](0124-unified-ssh-host-ca.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md),
[ADR-0264](0264-hermetic-mila-journey-fixture.md) (hermetic journey that
exercises strict certificate enrollment and browser approval end to end).
