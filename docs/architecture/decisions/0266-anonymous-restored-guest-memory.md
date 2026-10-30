# ADR-0266: Restored guest memory is anonymous

- ID: ADR-0266
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: Lilly, native execution, NixOS
- Supersedes: none
- Superseded by: none

## Context

[ADR-0199](0199-memory-suspension-and-demand-wake.md) accepts full-memory
checkpoints, paused relocation and restore into a fresh VMM. It does not state
how restored RAM is backed. Lilly loads checkpoints with Firecracker 1.16.1's
`File` memory backend (`/restore.memory` inside the jail). Upstream maps that
file `MAP_PRIVATE` as guest RAM. Each VM runs in `lilly-vm-<placement>.service`
with `MemoryMax` equal to the shape's accounted host memory, and hosts set
`panic_on_oom`.

Observed in the `audi-relocation-fleet` machine test (provisioner `l2`, kernel
6.18.59, ZFS): the first relocation of a cold-booted guest succeeded; the return
relocation's checkpoint of the restored guest ran Firecracker's memory dump as
a `write(2)` of guest RAM to the new checkpoint file. `zfs_write` prefaults the
source buffer (`zfs_uio_prefaultpages`), so every page of the private file
mapping not yet copied was read in through `filemap_fault` and charged to the VM
cgroup as page cache. The OOM report showed usage = limit = 589824 kB, `file`
511 MB of which 424 MB was mapped, `anon` 88 MB, `pgscan` 223 and
`workingset_refault_file` 0. Reclaim did not free the mapped, just-referenced
file pages; the memory cgroup OOM became a host panic.

Two accounting faults combine. A file-backed private mapping charges each page
the guest reads as file page cache and each page it writes again as an anonymous
copy, so a restored guest's charge is not bounded by its guest size. And a later
full checkpoint touches every page, which turns the whole checkpoint file into
mapped page cache in the cgroup at once. A cold-booted guest has neither fault:
its RAM is anonymous and charged once.

## Decision

Restored guest RAM is anonymous private memory charged to the VM cgroup at most
once per guest page, exactly as for a cold boot. The pinned Firecracker is
patched so that a `File` backend load allocates anonymous memory and copies the
memory file into it before KVM registration and before the VMM seccomp filter
is installed. All-zero host pages are skipped so they stay unpopulated. A memory
file shorter than the guest's regions is refused; the copy never restores a
zero-filled tail. The snapshot API, file format and reported version are
unchanged; Lilly keeps requesting the `File` backend.

`MemoryMax` stays equal to the accounted shape memory. Raising it, or charging
checkpoint page cache elsewhere, would hide the double charge rather than remove
it. The checkpoint slot remains sealed read-only and is retired under ADR-0199's
existing rules; that it is no longer mapped grants no earlier retirement.

The owner's task authorized fixing this root cause to restore trunk CI, required
that a restored VM checkpoint and relocate again within its accounted capacity,
and refused a larger `MemoryMax`.

## Alternatives

- Raise `MemoryMax`: rejected by the owner. It still double charges and only
  moves the panic to a larger guest or a busier restore.
- Firecracker's `Uffd` backend with an external page-fault handler: fills
  anonymous memory lazily and is upstream's recommended production path, but
  adds a new privileged-adjacent handler process per VM, a socket handshake in
  the jail, handler lifetime and crash custody (a dead handler hangs the guest
  on its next missing page) and new seccomp/jailer review. Loading is not on a
  latency-critical path that needs lazy faults.
- Evict checkpoint writes with `O_DIRECT` or `POSIX_FADV_DONTNEED`: does not
  address the fault. The charged pages are the restore file's mapped pages, read
  as the write source, not the destination's pages; ZFS writes go through ARC.
- Charge checkpoint page cache to another cgroup: the pages are faulted by the
  VMM in its own memory context; moving the charge needs kernel support Lilly
  does not have and would still leave a guest larger than its accounted size.
- Prefault the file mapping before checkpoint: still charges file pages plus
  anonymous copies and relies on reclaiming hot mapped pages.

## Consequences

A restored guest's resident memory equals its non-zero checkpoint pages; zero
pages fault on demand like a cold boot. A memory restore now reads the whole
memory file once at load instead of on demand, which lengthens the load by the
file read time. Loading charges the non-zero pages immediately, so restore must
keep reserving the shape's full memory before the load. Pages the guest freed
but did not zero are copied; this is bounded by guest size. The patched VMM's
store identity changes, so ADR-0199's exact VMM compatibility check treats hosts
on either side of this change as incompatible for memory moves until rollout
converges (ADR-0159). Huge-page (`hugetlbfs`) restore remains refused for the
`File` backend, as upstream refuses it.

## Invariants and verification

- A `File` backend restore never maps the checkpoint file; each region's bytes
  equal the file's bytes at the cumulative region offset; only pages with a
  non-zero byte are populated; dirty tracking starts clean; a short file fails.
  The patched unit tests and a property over random region layouts verify this
  in `firecracker-patch-tests`.
- A memory-restored guest's VM cgroup has no large mapped-file charge, and a
  second checkpoint of that guest completes within the unchanged `MemoryMax`
  without an OOM: the `audi-relocation-fleet` machine test asserts the restored
  unit's `file_mapped` and performs the return relocation.
- Disproving evidence: an OOM or `file_mapped` growth in a restored VM cgroup,
  restore failure on any non-hugetlb checkpoint, or guest memory corruption
  after relocation.

## Implementation evidence

- [Firecracker anonymous-restore patch](../../../nix/platform/patches/firecracker-snapshot-anonymous-restore.patch),
  applied by the [pinned VMM derivation](../../../nix/domains/artifacts/infrastructure/firecracker.nix)
  (contract `snapshot-restore-anonymous-memory`), replaces the private file
  mapping with an anonymous copy and adds the unit and property tests.
- [Patch test derivation](../../../nix/verification/tests/evaluation/firecracker-patch-tests.nix)
  runs those tests with the upstream snapshot-file and discard tests against the
  patched crate; the [Windows guest evaluation](../../../nix/verification/tests/evaluation/windows-guest.nix)
  pins the patch list.
- [Lilly checkpoint load](../../../lilly/lib/lilly/vm/api.ex) records that the
  `File` backend depends on this patch.
- [Audi relocation scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi-relocation.py)
  asserts the restored guest's cgroup `file_mapped` and returns the restored
  guest to its first host.

The [restored memory review](../reviews/2026-10-30-restored-guest-memory-accounting.md)
records passing `firecracker-patch-tests` and `audi-relocation-fleet` runs: the
restored unit had 1.6 MB mapped and the return relocation completed. Remaining:
physical-fleet rollout and repeated restore/checkpoint cycles beyond one return
are not recorded.

## Open questions

None.

## Related decisions

- [ADR-0010](0010-capacity-admission-transactions.md)
- [ADR-0159](0159-remove-legacy-compatibility.md)
- [ADR-0199](0199-memory-suspension-and-demand-wake.md)
- [Restored memory review](../reviews/2026-10-30-restored-guest-memory-accounting.md)
