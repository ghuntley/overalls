# ADR-0015: Jailed execution and host networking

- ID: ADR-0015
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Lilly VM, Lilly Network, Linux host, NixOS guest
- Supersedes: none
- Superseded by: ADR-0031

## Context

Superseded by [ADR-0031](0031-sparse-zfs-storage-and-capacity.md) for native sparse
ZFS storage and explicit guest flush handling. That record carries forward the
confinement, supervision, networking and recovery requirements and retains the
ext4 path. The rationale and verification below describe the earlier implementation.

The authorized implementation plan requires persistent Firecracker guests,
independent VM/TTY lifetime, Internet egress and direct guest isolation. Image and
address admission now exist, but v1 provisioner commands only acknowledge durable
receipt. This record selects local execution details within that authorization.
It does not make those receipts executable or claim fleet readiness.

## Decision

Use matching statically linked musl Firecracker/jailer 1.17.0 binaries from the
pinned Nix package. Validate ELF architecture and absence of a dynamic
interpreter. The earlier unjailed GNU image smoke remains historical evidence;
GNU binaries are unsupported by the jailer. Pin the ordinary Linux utilities
used by privileged operations and invoke fixed executables with argv arrays.

A small non-setuid C lock helper owns each OS flock and executes bounded utility
requests received over a private binary pipe. It uses no shell. EOF from Lilly
kills/reaps the in-flight utility before releasing the lock. Utility children
inherit the lock descriptor and receive a parent-death kill signal, so killing
the helper also cannot expose the protected resource while its child executes.
Timeout/output-limit handling reaps children before replying. Nested pool/network
operations execute through the owner of that resource's lock. Elixir owns domain
logic; this helper supplies the process/descriptor lifetime boundary that a
separate `flock ... cat` process could not establish. Standalone read-only
probes still use bounded GNU timeout. Asynchronous systemd/kernel requests still
need durable outcome reconciliation; terminating a client is not cancellation.

Run each VM as a transient systemd service under `lilly.slice`, independent of
Lilly's BEAM. The operator must activate/configure that slice and collect capacity
from its actual cgroup subtree. Bound the whole console/VMM process tree with a
CPU quota, guest RAM plus 64 MiB VMM allowance, zero swap and 64 tasks.
[ADR-0016](0016-executable-generations-and-lifecycle.md) now makes admission and
restart reservations include the allowance and backfills prior guest-only rows.

Keep dtach attached to a waiting `unshare --fork --pid --mount-proc` parent, then
run the jailer without its independently forking PID option. Firecracker becomes
PID 1 in its PID namespace, joins the owned network namespace, drops to its
dedicated numeric UID/GID, uses the jailer's mount/pivot-root confinement and the
default Firecracker seccomp filters. dtach/unshare remain privileged trusted host
helpers. Do not forward their output or guest terminal bytes into host logs.
Disable Firecracker's routine logger with its supported `--level Off` option:
otherwise private API polling messages are mixed into the serial TTY. Lilly's
structured lifecycle/outcome events remain the operational record. Detailed VMM
logging would need a separate bounded host sink before it can be enabled.

Use private immutable VM/disk claims and per-VM OS locks. Keep one fully allocated,
single-link ext4 disk at `vms/<uuid>/rootfs.ext4`. Copy without reflinks or sparse
holes, preallocate, sync, rename and persist readiness before launch. A missing
previously ready disk is an error, never permission to recreate a user's disk.
Serialize disk mutation with capacity snapshots using a pool lock. Firecracker's
pinned block device advertises no discard; verify this in the guest. Bind-mount
verified kernel/initrd read-only and the disk read-write into a disposable jail.
Only remove mounts after the service/cgroup is confirmed stopped. Unexpected
mounts or identities leave cleanup unconfirmed.

Distinguish a live systemd process tree from a ready VMM. Readiness checks the
dedicated UID/GID, PID namespace, zero effective capabilities, no-new-privileges,
seccomp, jail/network/executable inode identity, cgroup limits and a bounded
private API response with the matching VM ID/version in Running state. Request
`SendCtrlAltDel` for orderly x86 shutdown; after a bounded grace period stop the
whole systemd unit. A completed transient unit may disappear; confirm an absent
unit and empty cgroup before recognizing a stop. A durable deletion tombstone
precedes cleanup and permanently rejects a later start of that VM identity.

Use one routed network namespace per dedicated host and one TAP per VM. A /16
profile is an allocation pool; guests receive a /32 and an explicit gateway route.
Derive a unique locally administered MAC and UID/GID from profile/slot; reserve
the UID range 1,000,002–1,196,606 for Lilly on provisioner hosts. Host enrollment
must verify that ownership before automatic execution is enabled.

Route namespace egress through an owned veth pair on 169.254.255.0/30, with NAT in
the namespace and on the host's configured egress interface. Require existing
host IPv4 forwarding. Reject a conflicting transit allocation. Do not bridge
guest TAPs. Apply nftables atomically to owned tables, preserving unrelated host
rules. Default-deny namespace input/output/forwarding; allow only guest public
IPv4 egress and replies to established outbound flows. Host input from the owned
veth is denied. Deny private, link-local, reserved/multicast ranges and configured
protected infrastructure CIDRs, including infrastructure's public addresses.

At each TAP ingress, reject incorrect source MAC/IP and ARP identity; allow ARP
only for the assigned gateway. Deny VLANs, IPv6 and other Ethernet types. Disable
IPv6 and source routing/redirects in the owned namespace. Guests use public DNS
resolvers. A public external relay remains outside direct network isolation.
Operators must supply all protected infrastructure addresses for fleet use.

Persist network ownership before mutation. Recover partial veth/TAP setup only
with matching ownership and kernel device identities. Install filtering before
bringing interfaces up. Stop/delete cleanup removes owned TAPs, mounts and disks
before any future control-plane release/archival. Preserve claims after uncertain
failures so reconciliation can retry without assuming that resources are free.

## Alternatives

Lilly-owned child VMMs violate process-lifetime requirements. The jailer's
independent PID fork would detach Firecracker from dtach's command lifetime;
the waiting namespace parent avoids that mismatch. Per-VM kernel copies consume
unaccounted disk; hardlinks complicate image integrity and allocation accounting.
Bind mounts preserve separate disk ownership. Shared bridges or profile-only
firewalls allow lateral access. Host-wide firewall replacement risks unrelated
networking. IPv6 requires its own reviewed addressing/routing policy before use.

## Consequences

This implementation requires a dedicated root-capable x86-64 KVM host, systemd,
cgroup v2, plain ext4, nftables and an explicitly reserved UID/transit range.
Network namespace and VMM resources outlive Lilly and require durable recovery.
Double NAT simplifies host routing but adds conntrack state. Default private
destination denial can exclude private package mirrors; that is intentional.

The local driver is not reachable from v1 transport. ADR-0016 adds the v2
server/client, local launch fence and lifecycle ledger, including crash budgets
and cleanup-gated release. [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
adds global host ownership, VM actors and runtime reconciliation. Cross-host
acceptance and remote terminal integration keep the platform partial.

## Invariants and verification

- A launching BEAM can exit while the VM and console remain usable.
- Exact guest identity, jail, network namespace and resource limits precede a
  Running observation; process presence alone does not establish readiness.
- Stop/start preserves disk contents; a missing ready disk fails closed.
- Sparse/partial materialization cannot earn full allocation credit.
- Cleanup and tombstones prevent a deleted identity from recreating its disk.
- Public DNS/HTTPS succeeds; direct same-profile/cross-profile connections fail.
- Source spoofing, VLAN and IPv6 traffic increment ingress drop counters.
- Host/private access fails even with a known listening host socket.
- Required cross-host cases and fault/fencing tests remain acceptance obligations.

## Implementation evidence

The [adopted-child custody review](../reviews/2026-10-05-host-lock-descendant-custody.md) records
actual native premature-completion counterexamples, repaired expanded package
properties and scoped selector mutations. Source/test identity after integration
is checked separately from exact-helper consumer execution and physical
storage/host acceptance. Accepted rationale and partial status are preserved.


OS lock helper (`lilly/native/host-lock/src/lib.rs`), pipe client
(`lilly/lib/lilly/host/locked_command.ex`) and fault-injection tests
(`lilly/test/host/locked_command_test.exs`), all (removed by ADR-0176 decision 4; replaced by [`lilly-hostd`](../../../lilly/native/hostd/src/lib.rs)),
[driver](../../../lilly/lib/lilly/vm/driver.ex),
[systemd unit](../../../lilly/lib/lilly/vm/unit.ex),
[jail](../../../lilly/lib/lilly/vm/jail.ex),
[disk](../../../lilly/lib/lilly/vm/disk.ex),
[observation](../../../lilly/lib/lilly/vm/observation.ex) and
[API client](../../../lilly/lib/lilly/vm/api.ex) implement local execution.
[Network ownership](../../../lilly/lib/lilly/network.ex),
[nftables policy](../../../lilly/lib/lilly/network/policy.ex),
[guest configuration](../../../nix/domains/artifacts/guest/configuration.nix) and
[pinned builds](../../../devenv.nix) implement host/guest routing prerequisites.

[Root KVM smoke](../../../lilly/scripts/smoke_jailed.exs) exercises three real
guests using independent launching BEAM processes. It checks local isolation,
confinement, persistence, disk accounting and cleanup; it does not substitute for
the second-host matrix. [Specification properties](../../../lilly/test/vm/spec_test.exs),
[ELF properties](../../../lilly/test/vm/executable_test.exs),
[network identity tests](../../../lilly/test/network/identity_test.exs) and
[API failure tests](../../../lilly/test/vm/api_test.exs) run without privileges.
The [execution review](../reviews/2026-09-15-jailed-execution.md) records actual
verification outcomes and remaining integration gaps.

[V2 startup validation](../../../lilly/lib/lilly/control/config.ex) now rejects
canonical pool paths that cannot fit the jail API's Unix socket address before
advertising execution readiness. [Socket-path tests](../../../lilly/test/vm/jail_test.exs)
cover byte lengths and a real socket at the maximum, and the
deployment fixture (`lilly/scripts/deployment_fixture.exs` at overalls revision `9fe1e493`, repository deleted) verifies
rejection with a complete real host configuration. The
[three-node browser harness](../../../nix/verification/tests/README.md)
provisions a fresh guest through the packaged Lilly service; see the
[review](../reviews/2026-09-16-terminal-failover.md).

## Open questions

Measure VMM/console overhead at all supported sizes and concurrent boot loads.
ADR-0017 integrates physical ownership, local UID checks, fencing and the
ADR-0016 ledger with executable actors. Complete operator enrollment, protected
address distribution and shared terminal access.
Obtain the second independent KVM host for cross-host acceptance.

## Related decisions

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0004](0004-lilly-and-vm-actors.md), [ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md), [ADR-0007](0007-profile-networking.md),
[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0013](0013-capacity-collection-and-local-receipt.md),
[ADR-0014](0014-image-and-address-admission.md).

Interface references: [Firecracker 1.17.0 jailer](https://github.com/firecracker-microvm/firecracker/blob/v1.17.0/docs/jailer.md),
[Firecracker API](https://github.com/firecracker-microvm/firecracker/blob/v1.17.0/src/firecracker/swagger/firecracker.yaml),
[nftables](https://www.netfilter.org/projects/nftables/manpage.html),
[IANA special IPv4 registry](https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml).
