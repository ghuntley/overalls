# ADR-0234: Installer source grant for administrative SSH

- ID: ADR-0234
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: host tool, host profile, runtime firewall, fleet perimeter
- Supersedes: none
- Superseded by: none

## Context

[ADR-0233](0233-fleet-addresses-from-sops.md) moved every fleet public address
into a SOPS document that is sealed to installed host keys. A freshly installed
base system has no such document. Its fleet perimeter therefore grants no
reviewed public source and trusts only `tailscale0`, while a fresh install has
no Tailscale login. On 2026-10-20 the replacement Dungarees completed a guarded
installation and then refused every connection, including the authenticated
operator's, so enrollment could not start. Base systems do not poll Git, so no
published fix could reach it; recovery needed a provider rescue boot.

An enrollment can also move a host to a deployment whose reviewed sources do
not include the operator's workstation (for example a host joining a new
control plane while the operator works from another fleet host).

## Decision

The operator authorized this grant while reprovisioning Dungarees (2026-10-20).

- During a guarded installation the host tool records the source IPv4 address
  of its authenticated installer SSH connection (`SSH_CONNECTION`) in the
  root-only file `/var/lib/overalls-host/base-source` on the installed system.
  The address never enters the repository, the Nix store or operator output.
- Every fleet host publishes that file to `/run/overalls-host/base-source`
  when it exists, and an optional runtime firewall rule admits that one
  source to the administrative SSH ports only (`@cc base-installer-source`).
- Runtime firewall rules gain an `optional` flag: an optional rule whose
  runtime file is absent is skipped and every other rule still applies. A
  present but malformed address still empties the chain, as ADR-0233 requires.
- Deleting the recorded file withdraws the grant at the next boot or
  activation. Reviewed fleet sources, public service listeners and Tailscale
  are unchanged.

## Alternatives

- **Public administrative SSH on base systems:** reachable from anywhere, with
  key-only authentication as the sole barrier. Rejected as a wider perimeter.
- **Tailscale credentials at installation:** the profile must not hold Tailscale
  credentials, and SOPS cannot reach a host before its key is enrolled.
- **Address literals in the base declaration:** reverses ADR-0233.

## Consequences

- A newly installed host is reachable for enrollment from the machine that
  installed it, and stays reachable from there through a deployment change.
- The grant persists until an operator deletes the file; it is limited to the
  administrative SSH ports and the installer's single address.
- Hosts installed before this decision have no file and behave as before.

## Invariants and verification

- `host-planning` checks that the installer source is written once, privately
  (mode 0600 in a 0700 directory), holds only the address, and is refused for
  a missing, IPv6, loopback, unspecified, link-local or malformed connection.
  The same check runs runtime-firewall unit cases: an absent optional file skips
  only its rule; a present optional address is admitted; an absent required file
  or a malformed optional address leaves the chain flushed.
- `enrollment-configuration` checks that the profile declares exactly this
  optional rule for the administrative SSH ports and that the publishing unit is
  conditional on the installation file.
- The `fleet-addresses` NixOS machine test continues to exercise the runtime
  chain on both firewall backends.

## Implementation evidence

- [`remote.py`](../../../nix/domains/artifacts/host/remote.py) (`install-base-source`)
  and [`cli.py`](../../../nix/domains/artifacts/host/cli.py) (installation phase
  `base-source`).
- [`profile.nix`](../../../nix/platform/hosts/profile.nix) (`overalls-base-source`
  and the `base-installer` rule);
  [`runtime-firewall.nix`](../../../nix/domains/system/runtime-firewall.nix) and
  [`runtime-firewall.py`](../../../nix/domains/system/runtime-firewall.py)
  (`optional`).
- Tests: [`host-planning.py`](../../../nix/verification/tests/evaluation/host-planning.py),
  [`runtime-firewall-test.py`](../../../nix/verification/tests/evaluation/runtime-firewall-test.py)
  and [`enrollment-configuration.nix`](../../../nix/verification/tests/evaluation/enrollment-configuration.nix).
- The `host-images` NixOS machine test boots the exported base images without
  instrumentation; its fixture images
  ([`configurations.nix`](../../../nix/verification/tests/fixtures/hosts/configurations.nix),
  `exported-image-installer-source`) carry the file `install-base-source`
  would write for QEMU user networking (10.0.2.2). Before this, every run since
  2026-10-17 timed out on SSH because the base perimeter dropped the driver.
- Remaining gap: no recorded passing `host-images` execution with the
  recorded file yet; physical evidence is recorded with the Dungarees reinstall.

## Open questions

None.

## Related decisions

Amends [ADR-0233](0233-fleet-addresses-from-sops.md) (base systems without the
address document) and [ADR-0091](0091-fleet-perimeter-public-listeners.md)
(perimeter grants). Builds on [ADR-0043](0043-declarative-host-provisioning.md).
