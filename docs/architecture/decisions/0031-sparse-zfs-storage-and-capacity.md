# ADR-0031: Sparse ZFS storage and capacity

- ID: ADR-0031
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: Lilly Host, Lilly VM, Lilly Control, Marshall Compute, shared protocol, NixOS storage
- Supersedes: ADR-0013, ADR-0015
- Superseded by: ADR-0035

## Context

[ADR-0035](0035-zfs-only-provisioning.md) replaces the ext4/provisioner-v1
compatibility portions and carries forward the other requirements. The decision
and implementation evidence below describe the historical revision.

The user selected native ZFS datasets and explicitly rejected physical space
reservation: sparse disks are acceptable and compression must be LZ4/.
When asked separately about admission, the user retained a logical disk
commitment cap and selected mixed workloads. Sparse allocation does not
authorize disk overcommit, CPU/RAM overcommit or admission based on idle usage.

ADR-0013 and ADR-0015 require plain ext4 pools, fully preallocated disks and
allocation credit derived from fully allocated files. Those storage requirements
need replacement. Their unrelated receipt, supervision, confinement, networking
and recovery requirements remain applicable as specified below. The user
authorized this decision through the storage choices and the ADR implementation
request. Implementation and executed acceptance evidence are recorded separately below.

## Decision

Add a native ZFS backend alongside the existing ext4 backend. Use a managed
parent dataset and one owned child dataset per VM, containing a raw sparse guest
disk. The guest filesystem remains ext4; there is no host ext4 filesystem inside
a ZVOL. Create sparse copies of the verified image and extend their logical
length without fallocate or full preallocation. Preserve atomic disk publication
and durable readiness metadata. A missing previously initialized disk remains
an error, not permission to recreate guest storage.

Set `compression=lz4` on the pool's root dataset and managed Lilly datasets;
compression is a dataset property inherited by descendants. Keep
`reservation=none` and `refreservation=none` on the Lilly parent and VM datasets.
The reference parent's 1 TiB quota is a ceiling, not a physical reservation.
Remove the earlier plan's 110%-plus-64-MiB per-VM disk charge and reservation;
the requested virtual disk size remains the logical ledger commitment. Do not
confuse this with the existing 64 MiB VMM **memory** allowance, which remains.
Performance candidates belong in [ADR-0034](0034-mixed-workload-storage-tuning.md).

Identify the backend with the zpool and dataset GUIDs, canonical mount and
durable host/pool/VM ownership. Do not represent ZFS as an ext4 filesystem ID or
enroll sibling datasets as independent copies of the same pool's free space.
Initially allow one schedulable Lilly parent per zpool per host; its children
are VM allocations, not separately schedulable pools. Detect duplicate pool
identity and reject unsupported/ambiguous backing arrangements.

Keep the disk a regular single-link file owned by its VM identity, bind-mounted
into the jail. Serialize privileged create/delete and accounting mutations with
the existing ownership locks, using fixed executables and argv arrays. Add ZFS
operations to that boundary rather than executing arbitrary shell text. Preserve
claims after partial failures; delete a child only after its VMM/cgroup and mounts
are confirmed absent and its ownership matches. Keep deduplication off. Unknown
snapshots, clones or unaccounted descendants fail validation. Snapshot/clone provisioning, replication
and automatic resizing are outside this implementation.

### Logical commitments and physical observations

Extend enrollment, pool resources and the shared protocol with explicit backend
identity and ZFS accounting. Preserve user VM request shapes. Report logical
disk commitments separately from physical usage, effective available bytes,
quota, compression ratio and observation time. Compression cannot manufacture
additional logical budget. Stopped VMs retain their disk commitment.

Use the existing conservative admission structure with backend-specific evidence.
For a coherent fresh observation, let B be the configured usable budget, F the
effective ZFS available bytes after quota/ancestor/pool constraints, C all retained
logical disk commitments, H configured accounting headroom, and A the sum of
exclusive physical bytes attributable to those commitments, each capped at its
VM's commitment. Remaining disk capacity is:

```text
max(0, min(B, F + A) - H - C)
```

Sparse apparent size, compressed logical usage and unmatched allocations are not
physical credit. Exclude reservations and shared/snapshot blocks from A. Never
count the same backing capacity twice. Only credit deletion when reclamation is
observed; ZFS space reporting and freeing can lag mutations. Withhold uncertain
observations rather than combining incompatible samples or reporting fabricated
capacity. Headroom is an admission deduction, not a ZFS reservation; the proposed
20% value has not been accepted as a measured optimum.

Serialize admission/report acceptance with the existing shared database host-row
lock. Preserve fresh-session, architecture, image, profile-address and lifecycle
checks. Reject new admission on stale observations, insufficient space or
conflicting identities/properties. Physical write failures and pressure must be
observable without automatically deleting guests or releasing their commitments.
No software ledger can guarantee physical space against unrelated pool writers
when ZFS space is not reserved; the reference quota, headroom and pressure checks
bound this operational risk without claiming a reservation guarantee.

Continue reporting CPU architecture/cores, effective cgroup limits, memory and
I/O observations with units, scope, provenance and freshness. ZFS I/O metrics must
identify their pool/device scope; do not reuse an ext4 diskstats mapping by
assumption. Unknown maxima remain null and IOPS remains monitor-only.

### Continuing execution and receipt requirements

All requirements of [ADR-0013](0013-capacity-collection-and-local-receipt.md) and
[ADR-0015](0015-jailed-execution-and-host-networking.md), as refined by subsequent
ADRs, remain normative except the ext4-only restriction and storage materialization/
credit requirements replaced above. Host colocation follows
[ADR-0030](0030-nixos-deployment-and-tls.md), while guest UID ranges and cgroup
budgets remain exclusive to Lilly guests. Ext4 retains its existing allocation path.
In particular, carry forward:

- Private state, stable OS lock ownership, bounded fixed-argv utilities, durable
  command receipt, monotonic generations, session fencing and secret-free logs.
- Bounded collection/exchange, explicit unknowns, monotonic rate clocks and
  capacity measured from the actual guest cgroup and all ancestor limits.
- Independent systemd guest supervision, matching pinned static Firecracker/
  jailer, namespace/UID/seccomp confinement, resource limits and physical readiness.
- All three profile address ranges, routed public egress, default-deny direct
  guest communication on/across hosts, anti-spoofing, protected infrastructure
  denial, IPv6 denial and ownership-safe network setup/cleanup.
- Persistent disks across daemon restart and VM stop/start, tombstones, and
  outcome-confirmed release. V1 remains receipt-only; V2 alone executes guests
  under [ADR-0016](0016-executable-generations-and-lifecycle.md) and
  [ADR-0017](0017-durable-vm-actors-and-host-ownership.md).

Explicitly configure Firecracker `cache_type=Writeback` so guest flush requests
reach the backing file, with ZFS `sync=standard` and the synchronous I/O engine.
Do not trade away acknowledged flush durability for density. Discard remains
disabled initially; guest file deletion is not proof of host reclamation.

Upgrade all Marshall instances and shared validation before enrolling or enabling
ZFS provisioners. Preserve ext4 enrollment and stored data. Do not silently reinterpret
old pool identifiers or downgrade a live ZFS host to an ext4-only release.

## Alternatives

Full ZFS reservations or thick ZVOLs conflict with the selected sparse native
dataset model. Physical-use-only admission could overcommit quiet guests.
Crediting apparent sparse size or compression ratios could promise the same
future growth twice. Keeping ext4-only support would not deploy the selected host.

## Consequences

Physical consumption grows with writes while logical commitments remain stable.
Shared-pool pressure, ZFS metadata and delayed accounting need conservative
observations and explicit headroom. Sparse support changes disk validation,
enrollment and accounting together; weakening only the preallocation check is
insufficient. Existing local source contracts must change with the implementation.

## Invariants and verification

- Check LZ4 inheritance, no reservations and logical-size-greater-than-allocation
  using real datasets. Compression changes must not add logical admission budget.
- Property-test admission, ownership, rounding, stale reports, asynchronous
  reclamation and allocation attribution; race requests across three Marshalls.
- Exercise incompressible/compressible writes, full-disk growth, quota/pool
  pressure, unexpected snapshots/properties and creation/deletion interruption.
- Verify guest flush persistence after abrupt simulated host loss, reboot
  reconciliation, surviving daemon restart, missing-disk refusal and isolation.
- Run the real ZFS/Firecracker suites in [ADR-0033](0033-nixos-machine-verification.md)
  and regression-check ext4 before enabling the new backend.

## Implementation evidence

The [shared storage contract](../../../protocol/lib/overalls_protocol/storage.ex)
and [report codec](../../../protocol/lib/overalls_protocol.ex) add bounded ZFS
GUID identity and separate physical/logical/quota/compression observations to v2
reports. V1 exchanges reject this extension; existing ext4 messages retain their
shape. GUIDs use canonical unsigned 64-bit decimal strings rather than lossy
JSON numbers. The report timestamp remains the observation timestamp.

[Enrollment validation](../../../marshall/lib/marshall/compute/enrollment_request.ex)
accepts version 2 ZFS entries with an explicit logical budget and rejects two
parents from one zpool. The [Ash pool resource](../../../marshall/lib/marshall/compute/storage_pool.ex)
and generated migrations persist identity/budget, enforce backend consistency
and uniqueness, and preserve legacy ext4 rows. The migration that removes these
fields refuses rollback while any ZFS pool remains enrolled.
[Report ingestion](../../../marshall/lib/marshall/compute/host_reports.ex) binds
observations to that immutable identity under the existing host-row lock.
[Budget arithmetic](../../../marshall/lib/marshall/compute/budget.ex) applies the
enrolled logical cap separately from physical availability and retained credits;
history (`marshall/lib/marshall/telemetry/observations.ex` at overalls revision `a99f74f0`, repository deleted) keeps their
units and provenance separate. Existing
[VM reservation costs](../../../protocol/lib/overalls_protocol/vm_shape.ex) already
charge the requested disk size and retain the 64 MiB VMM memory allowance.

[Protocol properties](../../../protocol/test/storage_test.exs),
[admission properties](../../../marshall/test/marshall/compute/budget_test.exs) and
[database tests](../../../marshall/test/marshall/compute/zfs_pools_test.exs) cover
this control-plane foundation. The [enrollment test](../../../marshall/test/marshall/compute/enrollment_test.exs)
also exercises the actual Lilly client over verified TLS, preserving unsigned
GUID strings and rejecting changed dataset identity without advancing the report.
Its observations are synthetic protocol fixtures. The
[implementation review](../reviews/2026-09-16-zfs-capacity-contract.md) records
execution results and limits.

The [native ZFS reader](../../../lilly/lib/lilly/host/zfs.ex) now resolves the
actual parent mount, zpool/dataset GUIDs and plain disk/mirror extents. It checks
LZ4 and managed properties, brackets consecutive property-tree reads with identity
checks, and verifies physical decomposition and quota bounds. It returns child
dataset GUIDs and exclusive physical usage, **not** a VM allocation-credit map;
durable ownership is established separately by the lifecycle integration below.
[Reader properties](../../../lilly/test/host/zfs_test.exs) and the
[NixOS storage suite](../../../nix/verification/tests/machines/native-zfs/default.nix) cover this foundation; the
[native observation review](../reviews/2026-09-16-native-zfs-observations.md)
records actual results and limitations. Equal reads are observations, not an
atomic ZFS transaction, a reservation or proof against concurrent guest writes.

The [pool adapter](../../../lilly/lib/lilly/host/pool.ex),
[configuration](../../../lilly/lib/lilly/control/config.ex),
[session matching](../../../lilly/lib/lilly/control/runtime.ex) and
[collector](../../../lilly/lib/lilly/host/collector.ex) now connect native identity
and capacity to Lilly's v2 runtime. Duplicate zpool capacity and mixed ext4/ZFS
backing overlaps are rejected. Durable host bindings include native identity and
logical budget. The mount's virtual device number is never interpreted as a
physical diskstats source.

[Native I/O sampling](../../../lilly/lib/lilly/host/zfs_io.ex) uses one batched
`zpool iostat -Hpy ... 1 1` interval for up to 64 configured pools, omitting boot
averages. It checks the configured permanent GUID and unchanged `load_guid`
before and after collection. Exact bounded rows supply read/write operations
and bytes per second at **logical zpool scope**, including activity outside
Lilly's dataset. They are not VM, dataset or physical leaf-device rates. The
native utility computes rates from vdev timestamp deltas and truncates them to
integers; zero means zero at that reporting precision. A requested interval of
1000 ms and measured collection elapsed time are separate fields; the exact
native sample interval is unavailable and stays null. Latency, queue depth,
in-flight requests and busy percentage remain null in this source.

*Implementation note (2026-10-03).* The [runtime](../../../lilly/lib/lilly/control/runtime.ex)
measures native I/O on its own single-flight cadence, independently of
capacity samples. A host report carries the latest completed measurement no
older than 15 seconds, or unavailable I/O. Earlier, every capacity sample waited
for the one-second `zpool iostat` interval. Under load that made each report
seconds old on arrival, and idle capacity lapsed between reports in
`ssh-bootstrap-fleet`.

Malformed output, missing pools, utility failure/timeouts or an import change
leave all native rates unknown without discarding otherwise valid dataset
capacity. I/O columns never replace effective dataset availability or owned
physical credit. Capacity has its own source/scope fields. The
telemetry mapper (`marshall/lib/marshall/telemetry/observations.ex` at overalls revision `a99f74f0`, repository deleted)
retains both scopes and the import identity; an explicitly configured maximum
must use the matching I/O scope. No ceiling is inferred and admission arithmetic
is unchanged. [Parser properties](../../../lilly/test/host/zfs_io_test.exs), the
[real I/O machine suite](../../../nix/verification/tests/machines/zfs-io/default.nix) and
[I/O review](../reviews/2026-09-16-native-zfs-io.md) record verification and limits.

[Dataset ownership](../../../lilly/lib/lilly/host/zfs_dataset.ex) stores private
parent bindings and per-VM creation intents outside the child dataset. An
unpredictable nonce is written before creation; matching user properties allow
recovery before the child's GUID is bound. Once bound, a missing or replaced
child cannot be adopted or recreated. [Disk creation](../../../lilly/lib/lilly/vm/disk.ex)
copies the verified image sparsely, extends logical size with truncate, syncs and
publishes it atomically, then records readiness. Only ready owned disks receive
capped exclusive physical credit; partial creation/deletion receives none.

Deletion follows the existing driver's physical-stop and jail/network-cleanup
proof. It checks ownership, GUID, contents and mount aliases, persists a deletion
fence, and uses nonrecursive, nonforced ZFS destruction. A retained tombstone
outside the removed dataset permits reconciliation and prevents UUID reuse.
The [lifecycle machine fixture](../../../nix/verification/tests/machines/zfs-lifecycle/driver.py) exercises
actual Lilly disk APIs, verified images and interruption after real utility
mutations. The [lifecycle review](../reviews/2026-09-16-owned-zfs-lifecycle.md)
records executed results and limits.

The [NixOS Lilly module](../../../nix/domains/system/lilly.nix) now accepts explicit
native identity and logical budget and supplies the host's matching ZFS package.
It requires an existing correctly mounted parent; enabling the service does not
format disks, create/import pools or change properties. The separate
mirrored installation module (`nix/domains/system/mirrored-zfs.nix` at overalls revision `16e8dbe4`, repository deleted) declares
the root mirror and a dedicated Lilly parent with LZ4, no reservations and an
explicit quota. Its [firmware installation check](../../../nix/verification/tests/machines/mirrored-installation/default.nix)
passed actual property and surviving-disk checks. Exported disk images cleanly
export the root pool inside the image builder before shutdown. The
[installation review](../reviews/2026-09-16-mirrored-installation.md) records the
separate image-builder verification. The existing reference host's storage and
installation adapter still require its actual reviewed configuration.

The [jail configuration](../../../lilly/lib/lilly/vm/jail.ex) explicitly selects
Writeback/Sync. The [nested guest check](../../../nix/verification/tests/machines/zfs-guest/default.nix) exercises
actual Firecracker on ZFS, physical confinement, console data across stop/start,
stopped allocation retention and recovery of a distinct acknowledged guest write
after simulated host loss. It imports Lilly's module for host prerequisites and
uses isolated API workers; it does not run a complete control-plane fleet. QEMU
loss with the outer host alive does not prove physical power-loss durability.
Concurrent guest-write coherence, native collector-to-Marshall
admission and the complete multi-machine failure suites remain outstanding.

The [fleet review](../reviews/2026-09-16-nixos-fleet.md) records native storage
integration through the actual service modules, including a correction to
OpenZFS JSON device-alias collection. The
[reader](../../../lilly/lib/lilly/host/zfs.ex) preserves stored device paths for
metadata lookup and independently resolves their canonical physical extents;
missing identity or health metadata still withholds capacity. The fleet also
identified avoidable collection/dispatch latency: one native I/O task now runs
alongside the unchanged capacity reads, and completed reports dispatch promptly
when the single-request/backoff/fencing guards allow it. Tasks remain bounded and
reaped, and timestamps remain the observation start time. The review records
cadence measurements and the complete passing whole-fleet result.

The same review localized a concurrent launch failure to initial dataset
preparation before a durable dataset claim or VMM launch attempt. Usage-only differences
between independently valid property trees now remain a withheld observation but
return `storage_busy` through dataset/disk preparation for the existing executor
to retry. Non-usage properties, child identities and bracketing backing identity
must match; malformed accounting, changed quota or unsafe policy do not qualify.
The [native reader fixture](../../../nix/verification/tests/machines/native-zfs/driver.py) defines real between-read
usage, quota and child-identity mutations, and the
[lifecycle fixture](../../../nix/verification/tests/machines/zfs-lifecycle/driver.py) checks no initial claim or
dataset is created on a usage race before a normal retry. The complete native
reader suite passed all three mutations, and the full lifecycle suite passed
busy preparation, retry and existing ownership/crash-recovery cases. The complete
fleet also passed concurrent admission and all six guest launches. No changed observation becomes
schedulable capacity, and existing initialized storage is never recreated.

The fleet's stop/start case retained disk identity, but deletion of an older VM
exposed mount references held by unrelated waiting launcher parents. The
[launcher](../../../lilly/lib/lilly/vm/unit.ex) now creates its temporary mount
namespace only in the child, preserving the host namespace for the waiting PID
supervisor. The [fleet review](../reviews/2026-09-16-nixos-fleet.md) records the
observed references, retained cleanup uncertainty and passing fleet cleanup:
older VMs were deleted on both hosts while all survivors retained their identities.
This fixes independent VM cleanup within the accepted confinement design;
existing running launchers are unchanged until their VM is restarted normally.
Dataset deletion also handles interruption between unmount and destruction:
only an already-deleting, GUID-bound owned child can be remounted at an empty
canonical location. The read-only mount-state check returns no capacity, and
all normal ownership, content and destruction checks still apply. The native
lifecycle suite now includes actual unmount interruption and refusal of changed
ownership, policy, hidden host files and a replacement with copied tags. The
complete native lifecycle suite passed these cases in 797.35 seconds, alongside
the project gate. The focused two-guest launcher regression passed in 696.22
seconds, proving deletion of an older VM while the later VM retains its process
identity and continues reading/writing its disk.

*Correction (2026-10-07).* Restart readiness deferred for the whole lifetime
of any owned import on the pool, so a clone's source could not restart until
its same-pool copy was adopted, and every VM on a receiving pool waited for
adoption. A finished receive is now staged rather than busy: restart readiness
validates it under receive policy with its journal-fixed snapshot expectations
([staging](../../../lilly/lib/lilly/transfer/received_dataset.ex),
[accounting](../../../lilly/lib/lilly/host/zfs.ex)), still defers while a stream
may be writing or counters are settling, and capacity accounting never adopts
staging. Evidence: [focused tests](../../../lilly/test/host/zfs_test.exs) and the
native [clone matrix](../../../nix/verification/tests/machines/zfs-guest/cloning.exs).

### Transient contention keeps the previous observation (2026-10-09)

Native fleet evidence ([review](../reviews/2026-10-09-transient-pool-contention.md))
showed both pools withheld for 1-5 s many times a minute during ordinary VM
activity: the zero-wait pool lock was held by another storage operation
(`storage_busy`) or usage counters moved between the two exact reads. Each
`unavailable` entry cleared Marshall's pool freshness, so an admission landing
in such a window found unknown capacity and refused, which is what failed the
fleet release race and the clone-cancellation restart. A pool report now has a
third, identity-only entry, `busy`, for exactly those two transient causes:
Marshall leaves the pool row untouched, so the previous honest observation keeps
its original sample time and credit and ages out of the five-second capacity
window as if the report were late (ADR-0140: slowness is not evidence). Every
other failure is still `unavailable` and revokes freshness at once. Marshall
accepts `busy` before Lilly sends it (rolling deploy, server first).

### Usage drift is resampled and a busy entry extends a recent measurement (2026-10-13)

[ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md): a sample whose
two exact reads pass accounting and differ only in usage counters is retried
three times and then reports the latest coherent tree instead of withholding
`usage_moving`; the pool lock is awaited 200 ms before `storage_busy`. Marshall
records the last real measurement time and lets a `busy` entry extend that
measurement's freshness for at most 15 s, never past host authority.

### Machine-fixture faults that never armed (2026-11-01)

Two zfs-lifecycle checks asserted refusals whose faults never reached Lilly.
The usage-drift preparation check expected `storage_busy`, but the probe never
put the observation-fault wrapper on its private hostd's PATH, and ADR-0163
decision 4 makes a preparation under moving usage succeed anyway. The check is
now `moving-prepare`: the fault is armed only just before `Disk.prepare`, which
must succeed and agree with a later quiet preparation. The parent-sync-failure
deletion check planted a `sync` stub on PATH, but lilly-hostd performs `sync`
natively, so the stub never ran and `reject-delete` succeeded; that case has
not been exercised since 840c79834.

The interrupted-mutation checks failed the same way: lilly-hostd runs each
utility with only PATH and LC_ALL, so `ZFS_PAUSE_OPERATION` never reached the
fault wrappers and no operation paused. The driver now names the paused
operation in a root-owned file. The copy wrapper pauses only on a copy, not on
the `identity` reads that share its executable. Evidence: zfs-lifecycle passed
every subtest on dungarees with local builders only (test script 1864.74 s),
except the explicitly skipped parent-sync case.

Open gap: the parent-sync-failure deletion path has no machine evidence, and
the driver skips it explicitly. Proposed follow-up, not decided: a fault seam
for hostd's native sync compiled only into test builds, in the pattern of
Lilly's test-only root-owner seam (778e73821).

## Open questions

Validate ZFS accounting consistency and metadata headroom under concurrent guest
writes. The tuning proposal and physical-host benchmarks remain outstanding.
The requirement to retain a logical cap and avoid filesystem reservations is
settled; numerical tuning is not.

## Related decisions

[ADR-0013](0013-capacity-collection-and-local-receipt.md),
[ADR-0015](0015-jailed-execution-and-host-networking.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0023](0023-retained-capacity-telemetry.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0034](0034-mixed-workload-storage-tuning.md),
[architecture review](../reviews/2026-09-16-nixos-and-sparse-zfs.md).

Interface references: [OpenZFS dataset properties](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html),
[OpenZFS pool properties](https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html),
[Firecracker 1.16.1 caching](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/docs/api_requests/block-caching.md).

Native I/O references: [OpenZFS interval and scope](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-iostat.8.html),
[pool/import identities](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zpoolprops.7.html),
[2.4.4 rate calculation and integer output](https://github.com/openzfs/zfs/blob/zfs-2.4.4/cmd/zpool/zpool_main.c),
[2.4.4 monotonic vdev timestamps](https://github.com/openzfs/zfs/blob/zfs-2.4.4/module/zfs/vdev.c).

[ADR-0035](0035-zfs-only-provisioning.md) supersedes this decision as described above.
