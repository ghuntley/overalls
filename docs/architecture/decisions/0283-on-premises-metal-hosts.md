# ADR-0283: On-premises metal hosts

- ID: ADR-0283
- Date: 2026-11-25
- Status: accepted
- Implementation: partial
- Components: host provisioning tool, host profile, Lilly enrollment
- Supersedes: none
- Superseded by: none

## Context

The host tool knew three platforms: `hetzner` (exactly two mirrored system
disks, shared ZFS root with a quota-bounded `zroot/lilly`), `hcloud` (one disk,
DHCP, no KVM or Lilly) and `ec2` (EBS root, local NVMe guest pool). On
2026-11-25 the user asked to replace the lost Panterloons control plane with an
on-premises machine on a private LAN: a single 4 TiB virtual disk, BIOS
firmware, nested KVM and a static uplink (10.10.10.1 and 10.10.10.2/24 behind a
10.10.10.254 gateway). None of the existing platforms describes it.

## Decision

Add the `metal` platform. It shares the `hetzner` storage model — one ZFS
`zroot` carrying `zroot/root` and a reviewed, quota-bounded `zroot/lilly` — but
accepts one or two system disks; the pool mirrors exactly when two are selected
(contract `metal-shared-zfs-root`). KVM, Lilly, the resource-policy receipt and
the guest quota checks apply as on `hetzner`. Addressing follows ADR-0233: the
uplink is declared through `addresses.uplink` and the fleet-addresses SOPS
document, recorded at installation from the observed static addresses, and the
declaration carries no address literals except DNS resolvers.

## Alternatives

Declare the machine as `hetzner` with a second virtual disk: misdescribes the
hardware and adds a pointless mirror on one physical array. Use `hcloud`: no
KVM, no Lilly and DHCP-only addressing, so it cannot run the control-plane
roles. Non-ZFS single-disk root: rejected by the user; ZFS is required.

## Consequences

A single-disk `metal` host has no storage redundancy; disk loss is host loss and
recovery follows the backup runbook. The platform name, like the others, is part
of the installation binding, so changing it is maintenance, not an update.

## Invariants and verification

Validation refuses `metal` declarations without one or two system disks, with
guest disks, or without a positive guest quota; the profile asserts the same
and selects `mirror` mode only for two disks. Enrollment storage headroom stays
below the quota (contract `enrollment-storage-headroom-below-capacity`).

## Implementation evidence

- [Host tool validation](../../../nix/domains/artifacts/host/cli.py),
  [storage readiness](../../../nix/domains/artifacts/host/remote.py),
  [enrollment preparation](../../../nix/domains/artifacts/host/preparation.py),
  [resource policy](../../../nix/domains/artifacts/host/enrollment.py) and the
  [host profile](../../../nix/platform/hosts/profile.nix).
- [Overalls](../../../fleet/hosts/overalls/host.json) is the first `metal` host.
- No machine test installs a `metal` fixture yet; the hetzner/hcloud/ec2
  fixtures cover the shared code paths.

## Open questions

Whether a `metal` fixture should join the machine-test installs, and whether
two-disk `metal` hosts need a separate disk-replacement runbook.

## Related decisions

[ADR-0233](0233-fleet-addresses-from-sops.md), [ADR-0246](0246-panterloons-control-plane-deployment.md)
