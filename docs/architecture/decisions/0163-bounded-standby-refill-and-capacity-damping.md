# ADR-0163: Bounded standby refill and capacity damping

- ID: ADR-0163
- Date: 2026-10-13
- Status: accepted
- Implementation: partial
- Components: Lilly host storage, Lilly standby disks, Marshall Compute host reports, NixOS Lilly module, fleet host configuration
- Supersedes: none
- Superseded by: none

## Context

The 2026-10-13 investigation of refused clones, relocations and "stuck"
machines ([review](../reviews/2026-10-13-storage-churn-and-capacity-damping.md))
found that the fleet's own background storage work starved admission. Each
host kept 128 standby root disks per image (ADR-0146) for two images: 256
mounted datasets for seven guests. A guest-image rebuild retired 260 and
filled 257 standbys in seventy-five minutes, each step under the pool lock
(p50 1.2 s, p90 8.8 s, max 18 s per fill). Capacity snapshots were withheld
352 times in that hour and about 150 times per hour at rest, as `storage_busy`
(pool lock held) or `usage_moving` (usage counters moved between the two exact
reads, which ordinary guest writes cause). Marshall keeps a busy pool's previous
row untouched (ADR-0031), so it ages out of the five-second capacity window
(ADR-0140) and every admission landing in that window refused with
`insufficient_capacity`, `source_unavailable` or `host_unavailable`.

## Decision

1. **Standby refill is planned and budgeted.** One pure planner
   (`Lilly.Host.StandbyPlan.plan/3`) turns the pool's standby records, the
   configured images and a budget `{per_image, fills, retirements}` into a
   plan: every claiming record is recovered and every terminal record pruned
   first; at most `retirements` standbys are retired in the order interrupted
   fills, excess sealed standbys of a configured image, then standbys of a
   replaced image; at most `fills` standbys are filled round-robin over the
   configured images below their target. Replaced-image standbys are retired
   only as many as sealed standbys of configured images exist, so old disks
   leave as new ones become ready and a sealed standby within its target is
   never retired. The pass rests one second between effects and yields early
   whenever a pool-lock waiter is announced.
2. **Pool-lock waiters are announced.** A caller retrying the pool lock is
   counted for its retry window (`Lilly.Host.Storage.contended?/1`), so bulk
   work can yield between disks to capacity snapshots, clone effects and
   creation. The count is advisory and grants no ownership.
3. **Budgets are configuration.** `services.lilly.standbyDisks.fillsPerPass`
   and `retirementsPerPass` (1..32, default 4) travel through the pool
   configuration to the host; `perImage` is bounded to 1..32 and the module
   asserts `perImage × images ≤ 64` mounted standby datasets per pool. The
   fleet runs 32 per image with 4 fills and 4 retirements per pass.
4. **Usage drift is resampled, not withheld.** A capacity sample whose two
   exact reads both pass accounting and differ only in usage counters is
   retried up to three times, 25 ms apart; if the counters keep moving the
   latest coherent tree is the observation. Identity, ownership and
   accounting failures still withhold, and the pool lock is now awaited for
   200 ms before a snapshot reports `storage_busy`.
5. **A busy entry extends a recent measurement.** Marshall records the time of
   a pool's last real measurement (`observed_at`). A `busy` entry keeps the
   numbers untouched and extends their freshness only while that measurement
   is within `pool_busy_grace_ms` (15 s); beyond it the row ages out as
   before, and `unavailable` still revokes at once. The grace plus the capacity
   window can never exceed the host authority window, checked at application
   start.

## Alternatives

- Keeping 128 standbys and only slowing the refill: rejected; the resident
  metadata of hundreds of mounted datasets does not fit the ARC budget and the
  count buys nothing once one disk per image is sealed ahead of each create.
- Extending capacity freshness globally: rejected; a late or absent report
  must still age out in five seconds (ADR-0140). Only a positive busy entry,
  which proves the host reached the pool, extends a recent measurement.
- Serializing standby work behind admission in Marshall: rejected; the host
  owns the pool lock and can yield locally without a round trip.

## Consequences

Image changes converge over minutes instead of a storm, pools are withheld only
for real contention, and an admission during ordinary guest writes sees the
latest coherent accounting. Hosts keep 64 standbys at most. Marshall gains one
timestamp column on `compute_storage_pools`; Lilly's pool configuration gains
two counts, and old configurations without them are refused by the closed pool
shape (ADR-0159).

## Invariants and verification

- A plan never exceeds its fill or retirement budget, recovers every claim, and
  never retires a sealed standby of a configured image within its target.
- Replaced-image retirements never exceed the number of sealed standbys of
  configured images.
- A busy pool entry never changes measured numbers and never extends freshness
  past the busy grace from the last real measurement.
- `busy_grace + capacity_freshness ≤ host_authority`.
- Property tests: `lilly/test/host/standby_plan_test.exs`,
  `lilly/test/host/zfs_test.exs`, `marshall/test/marshall/compute/host_reports_test.exs`.

## Implementation evidence

- Planner and bounded refill: `StandbyPlan` (`lilly/lib/lilly/host/standby_plan.ex`, removed by ADR-0177),
  `standby disks` (`lilly/lib/lilly/host/standby_disk.ex`, removed by ADR-0177),
  `refill process` (`lilly/lib/lilly/host/standby_refill.ex`, removed by ADR-0177),
  [pool-lock waiters](../../../lilly/lib/lilly/host/storage.ex),
  [pool configuration](../../../lilly/lib/lilly/host/pool.ex),
  [Nix module](../../../nix/domains/system/lilly.nix),
  [overalls](../../../fleet/roles/control-plane/services.nix) and
  [dungarees](../../../fleet/hosts/dungarees/configuration.nix).
- Usage resample: [ZFS observation](../../../lilly/lib/lilly/host/zfs.ex).
  Observation and [dataset preparation](../../../lilly/lib/lilly/host/zfs_dataset.ex)
  contract comments now preserve the same bounded coherent usage resampling;
  genuine contention, identity/policy drift and exhausted accounting still refuse.
  The [coding CLI checkpoint](../reviews/2026-10-13-native-guest-coding-clis.md)
  records the corrected parent-incoherence refusal fixture and passing Lilly gate,
  separately from pending full native/integrated acceptance. No resampling
  implementation or accepted decision changed in that contract reconciliation.
- Busy grace: [StoragePool](../../../marshall/lib/marshall/compute/storage_pool.ex),
  [host reports](../../../marshall/lib/marshall/compute/host_reports.ex),
  [HostLiveness windows](../../../marshall/lib/marshall/compute/host_liveness.ex).
- Properties: `standby plan` (`lilly/test/host/standby_plan_test.exs`, removed by ADR-0177),
  [usage resample](../../../lilly/test/host/zfs_test.exs),
  [busy grace](../../../marshall/test/marshall/compute/host_reports_test.exs).
- Native `image-template` standby retirement by reason and the fleet
  activation (standby count converging to 64 per host, withheld rate) are
  recorded in the [review](../reviews/2026-10-13-storage-churn-and-capacity-damping.md)
  when they run.
- Observed entries (2026-10-30): pools are now observed off the report path
  ([ADR-0140 update](0140-event-driven-liveness-and-single-writer-views.md)),
  and an observed entry carries the time its read began. The busy grace bounds
  those entries too: a re-sent or delayed observation refreshes the pool only
  within `pool_busy_grace_ms` of that time
  ([host reports](../../../marshall/lib/marshall/compute/host_reports.ex),
  `pool-observation-time-bounds-freshness`). The grace and its start check are
  unchanged.
- Fenced snapshots (2026-10-31): a capacity read now holds the pool lock only
  for its bind and is fenced by a generation token
  ([ADR-0274](0274-fenced-capacity-snapshots.md)). A read that straddles a
  pool section is reported `busy`, so this grace bounds it, and two
  consecutive `busy` reads trigger one locked read. The 200 ms snapshot wait
  now applies to the bind only.

## Open questions

- Whether the refill cadence (one pass per minute or per claim) should also
  back off while the host is under memory pressure.

## Related decisions

- [ADR-0146](0146-standby-guest-disks.md): standby disks; its refill open
  question is closed here.
- [ADR-0031](0031-sparse-zfs-storage-and-capacity.md): the busy entry; this
  decision extends it with usage resampling and the busy grace.
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md): capacity
  freshness windows; the busy grace is bounded by host authority.
- [ADR-0010](0010-capacity-admission-transactions.md): admission against fresh
  pool capacity.
- [ADR-0143](0143-faster-create-clone-delete.md): pool-lock contention retried.
