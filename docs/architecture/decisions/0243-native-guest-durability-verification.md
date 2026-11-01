# ADR-0243: Native guest durability across interrupted growth, host power loss and relocation

- ID: ADR-0243
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: Lyra native agent, Nix guest builders, native machine tests
- Supersedes: none
- Superseded by: none

## Context

[ADR-0190](0190-native-kernel-provenance-and-admission.md) admits exact
FreeBSD and OmniOS images whose native flush agent returns a receipt only after
filesystem writes complete. Recorded native evidence covered one durability
case: the Firecracker process gets SIGKILL and the same disk restarts on the
same host. That process kill leaves every completed host write in the host page
cache, so it cannot show that a flush receipt survives the loss of volatile
host or device state. Interrupted root expansion, host power loss and moving a
stopped disk to another host were all listed as unproven gaps.

Lilly configures native drives as regular files inside a per-VM ZFS dataset,
with Firecracker `cache_type: Writeback` and the `Sync` I/O engine
([jail configuration](../../../lilly/lib/lilly/vm/jail.ex)). With Writeback,
the virtio device advertises a volatile write cache. Firecracker reaches the
host file's stable storage only when the guest sends a flush, so a guest that
never flushes the device has no durability across host power loss, whatever
its filesystem did internally.

Observed while implementing the tests: pinned FreeBSD 14.3 UFS never issues
BIO_FLUSH, because `vfs.ffs.softdep_flushcache` defaults to 0. UFSSUSPEND waits
for completed writes but does not flush the device cache. A power-loss replay
of a pre-fix FreeBSD image lost the marker file that had been written before an
acknowledged flush. The illumos ZFS `sync` path already issues device cache
flushes, and its replay kept the acknowledged bytes.

## Decision

The task that requested native durability tests, fixes and evidence for
FreeBSD and OmniOS authorizes this decision.

1. **A flush receipt means durable across host power loss.** A native flush
   receipt MUST NOT be returned until the guest's acknowledged writes would
   survive the loss of all volatile host and virtual-device state under Lilly's
   Writeback drive mode. On FreeBSD the agent therefore issues one `DIOCGFLUSH`
   after UFSRESUME. It sends this through the image's fixed `gpt/swapfs`
   provider, which is on the same virtio disk and is not held exclusively. If
   the flush fails, the agent refuses the receipt. OmniOS keeps `sync`, which
   reaches ZFS's device-flushing commit path.
2. **Power loss is modelled by discarding unflushed state.** The host machine
   test puts its ZFS pool on a `dm-log-writes` device. That target records
   completed writes in order and makes them visible only through a later FLUSH
   or FUA. At the cut, the test kills the VMM and marks the journal. Only the
   journal prefix before the mark is replayed onto a zeroed device, which is
   then imported. Writes the host or guest never flushed are absent, exactly as
   after an abrupt loss of power to a write-back disk. The receipt counts the
   device flushes that happened between the guest-flush-requested and
   guest-flush-acknowledged marks.
3. **Interrupted growth must be recoverable at any write.** The test SIGKILLs
   Firecracker after a counted number of writes at or beyond the old disk end
   during boot-time root growth. The next boot MUST pass the native filesystem
   check (UFS fsck or a zero-error ZFS scrub), report either the old or the new
   root size, and then complete growth idempotently.
4. **Relocation requires fresh authority and exact bytes.** A stopped guest
   disk moved to another host MUST boot only under a new placement, epoch,
   boot challenge and boot identity. It MUST keep its flushed workspace bytes
   and MUST refuse flush, workspace and terminal requests that carry the old
   placement's authority.
5. **Scope stays explicit.** Receipts record `native_admission: false` and
   do not claim Lilly transfer, Marshall relocation orchestration, physical
   media or production admission.

## Alternatives

- **SIGKILL only.** This was rejected because completed writes stay in the host
  page cache and survive, so it cannot test whether flushes are durable.
- **Resetting a nested host with QEMU, or dropping the host page cache.** QEMU's
  own caches and host file buffering make the lost set unknowable, and dropping
  caches discards no completed write. The dm-log-writes prefix is an exact,
  replayable model.
- **Mounting UFS with softdep flushcache enabled.** This would change every
  guest's write path and still relies on a sysctl default. A single explicit
  flush at the receipt boundary is narrower and fails closed.
- **Unsafe drive caching in tests.** This was rejected because it removes the
  flush semantics that production relies on.

## Consequences

- Each FreeBSD flush receipt costs one device cache flush. Under Writeback, that
  makes Firecracker call `fsync` on the host disk file.
- The FreeBSD change alters the native agent binary and therefore the image
  digest. Promoted FreeBSD images built before this change still carry the
  defect until a new image is qualified and promoted under ADR-0190.
- The tests need nested KVM, ZFS, `dm-log-writes`, `strace` and roughly 30 GiB
  of scratch disk per power-loss run.

## Invariants and verification

- A FreeBSD flush receipt implies a successful `DIOCGFLUSH`. The ABI gate in
  [native growth](../../../nix/domains/artifacts/guest/native-growth.nix) pins
  the ioctl number.
- After replaying a prefix that ends at the power cut, the acknowledged marker
  MUST exist with exact bytes, and the canary dataset written after the last
  host commit MUST be absent. The test fails if the cut does not actually
  discard unflushed host state.
- Interrupted growth MUST have killed the VMM at or after the requested write
  count. Recovery MUST show a strictly larger capacity at each stage and three
  distinct boot identities.
- A relocated disk MUST match the source snapshot GUID, keep the workspace
  SHA-256 and refuse the stale authorities.

## Implementation evidence

- [Native agent flush](../../../lyra/src/native_guest.rs) (`flush_disk_cache`,
  contract `native-freebsd-device-cache-flush`).
- [Machine test](../../../nix/verification/tests/machines/native-durability/default.nix),
  [scenario runner](../../../nix/verification/tests/support/native_durability.py)
  and [journal replay](../../../nix/verification/tests/support/native_write_log.py),
  with host unit tests
  [native_durability_test.py](../../../nix/verification/tests/support/native_durability_test.py)
  and [native_write_log_test.py](../../../nix/verification/tests/support/native_write_log_test.py).
- The [native-durability suite](../../../nix/verification/tests/machines/native-durability/BUCK) declares six checks:
  `native-{freebsd,omnios}-{interrupted-growth,power-loss,relocation}`.
  The OmniOS checks use the promoted `packages.omniosGuest`. The FreeBSD checks
  use the source candidate, because the fix changes the image.
- The [guest OS matrix review](../reviews/2026-10-18-guest-os-matrix.md)
  ("Native durability: interrupted growth, power loss and relocation") records
  every pass, the pre-fix FreeBSD power-loss failure, and receipt digests.
- 2026-10-22 regression repair: FreeBSD guests in the native service,
  transport and reset runners now use the production `Writeback`/`Sync` drive
  policy, without which `flush_disk_cache` correctly refused (`EOPNOTSUPP`).
  OmniOS keeps the default there, because host fsync per ZFS flush made
  `native-omnios-services` miss its deadlines; the durability checks cover OmniOS
  on Writeback. The UFS integrity check now polls a detached snapshot fsck
  instead of exceeding one SSH probe. All twelve FreeBSD native checks then
  passed; the [review](../reviews/2026-10-18-guest-os-matrix.md) lists them.

Remaining gaps: the method kills at one point per growth stage. Only the first
FreeBSD stage hit a pre-resize state, and the OmniOS kills landed after the pool
expansion had committed; there is no
physical media or firmware cache; Lilly and Marshall relocation orchestration
are not exercised; split-brain with a live source is not tested; and the fixed
FreeBSD image has not been promoted.

## Open questions

- Whether a promoted FreeBSD image with the device flush should replace the
  current selection before production durability is claimed.
- An intermittent OmniOS first-boot failure, seen in two early runs on
  ZFS-hosted disks, put the growth service into SMF maintenance. Its cause has
  not been established.

## Related decisions

- [ADR-0190](0190-native-kernel-provenance-and-admission.md)
- [ADR-0180](0180-multi-os-guest-image-contract.md)
- [Guest OS matrix review](../reviews/2026-10-18-guest-os-matrix.md)
