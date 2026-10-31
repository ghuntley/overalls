# ADR-0274: Fenced capacity snapshots outside the pool lock

- ID: ADR-0274
- Date: 2026-10-31
- Status: accepted
- Implementation: partial
- Components: Lilly Host
- Supersedes: none
- Superseded by: none

## Context

Since [ADR-0152](0152-lean-pool-locked-preparation.md), a capacity
observation (`Pool.snapshot/1`) used the same `PoolSnapshot` as a disk
preparation: bind the pool, read the snapshot expectations, two whole-pool
`zfs list` trees, one owner listing and one mount table, then classify
allocations, templates and checkpoints. All of this ran under the pool
mutation lock. ADR-0152 needs the lock for a preparation, whose checks
authorize native mutations. A capacity report authorizes nothing: Marshall
admits from it, and every preparation re-reads the pool under the lock and
refuses exhausted accounting itself.

Observed facts from CI fleet machine-test run 41164441328:

- `lilly.pool_section` snapshot holds were 1.7-4.7 s per observation on
  8-vCPU runners. The split between the bind, the native reads and the
  file-backed audits was not measured. Apart from the bind's directory claims,
  every step only reads native state or Lilly's journals.
- In account-lifecycle and account-lifecycle-ubuntu, 58 transfer and clone
  sections that wait 1-2 s went `storage_busy` behind those holds (36 after
  1 s, 19 after 2 s), and transfer receive and import effects failed
  `storage_busy`. Both suites timed out in the same subtest.
- Proportional rest after each read (ADR-0140 update, 2026-10-31) halved the
  observer's share of the lock, but it cannot help a section that arrives
  while one read holds the lock longer than that section's wait.

## Decision

A capacity snapshot holds the pool lock only to bind the pool and read a
generation token. Its native reads and classification run without the lock
and are fenced by that token.

- **Generation token.** `Lilly.Host.Storage` keeps a random 128-bit token in
  the pool's lock directory (`.lilly-storage/generation`). Every pool section
  except `:snapshot` replaces it after acquiring the native lock and before
  its callback runs. This includes sections in other BEAMs (operator and
  machine-test probes) that use `Storage`. A failed write that leaves the
  previous token readable refuses the section. A write that fails after
  truncation, as on a full pool where deletes must keep working, counts as an
  advance.
- **Fenced observation.** `Storage.observe/4` runs a short `:snapshot`
  section (the bind, with the existing 200 ms wait), reads the token under
  that lock, releases the lock and runs the read. A held lock still means
  `storage_busy`, as before. The read's result, success or error, is
  returned only if the token is unchanged afterwards. Otherwise it is
  `storage_busy`, which `Pool.report/2` reports as `busy`. A read that
  straddles the start of any pool section is never reported as fresh, and its
  incoherent intermediate errors are never reported as `unavailable`.
- **Reports only.** A fenced `PoolSnapshot` has no lock.
  `PoolSnapshot.held?/1` is false for it, and `ZFSDataset.allocations/2` and
  every preparation, readiness and claim path require `held?/1`. Only
  capacity classification accepts it, through `PoolSnapshot.current?/1`,
  while the token is unchanged. ADR-0152's rule that no check may consult
  native state read before the lock was acquired still holds for everything
  that authorizes a mutation.
- **Locked fallback.** `Lilly.Host.PoolObserver` reads fenced. After two
  consecutive `busy` results it takes one read in `:locked` mode, the
  previous behaviour, so sustained mutation traffic cannot hold capacity
  `busy` past Marshall's 15 s busy grace (ADR-0163). A non-busy result
  returns it to fenced reads.

Authorization: the coordinating session directed this work on 2026-10-31
(take the snapshot outside the lock and fence it with a generation counter
that every mutation section bumps; discard or mark stale a straddled
observation; amend the ADRs as needed).

## Alternatives

- **Keep the snapshot under the lock and lengthen every section's wait.**
  Rejected. Dozens of call sites wait 1-2 s by design, some under
  GenServer call timeouts, and every mutation would still queue behind
  multi-second reads.
- **An in-BEAM counter instead of a token file.** Rejected. Machine-test and
  operator probes run `Storage` sections from separate BEAMs, so a
  BEAM-local counter would miss their mutations and could report a straddled
  read as fresh.
- **Bump at section start and end (a seqlock) with no locked prologue.**
  Rejected. A section killed between its bumps leaves the counter odd, and an
  idle pool would never be observed again. The prologue proves that no
  section is in progress when the token is read, so one bump per section is
  enough.
- **Cache observations across lock acquisitions for preparations.** Still
  rejected, as in ADR-0152 and ADR-0176: a gate must follow the last
  mutation. This decision gives fenced reads to capacity reports only.

## Consequences

- Mutations wait on an observation only for the prologue (the bind) and for
  the rare locked fallback, not for the native reads.
- Under steady mutation traffic, fenced reads are withheld (`busy`) more
  often. Marshall keeps the previous observation until the busy grace
  expires. The locked fallback bounds that to two withheld reads.
- Each pool section writes one 32-byte file. A token that cannot be replaced
  blocks mutations on that pool, which keeps the fence safe.
- Pool sections that do not use `Storage`, such as tests and probes holding
  the native lock directly, do not advance the token. They are not
  mutations, and a lock they hold still makes the prologue `busy`.
- Native state changed without any pool section, such as root-disk copies
  under a placement lock, moves usage. The two-tree read still detects that
  and reports `usage_moving`, as it did under the lock.

## Invariants and verification

- A fenced read never makes a mutation section wait for the read:
  `fenced-read-never-blocks-mutation` in
  [storage_observe_test.exs](../../../lilly/test/host/storage_observe_test.exs)
  runs a 4 s fenced read while a section with a 1 s wait acquires the lock in
  under 0.5 s.
- A straddled observation is never reported: the Hegel property
  `straddled-observation-never-fresh` interleaves mutation sections of every
  kind before and during a read, with a successful or failing read. The read's
  outcome is returned exactly when no mutation section began during it, and
  `:snapshot` sections do not withhold it.
- A section that cannot replace a readable token does not run
  (`generation-advance-gates-mutation`).
- A held native lock still makes the observation `busy` before any read
  ([pool_report_test.exs](../../../lilly/test/host/pool_report_test.exs),
  [pool_availability_test.exs](../../../lilly/test/host/pool_availability_test.exs)).
- Two busy reads lead to one locked read
  ([pool_observer_test.exs](../../../lilly/test/host/pool_observer_test.exs),
  `observer-locked-after-two-busy`).
- Disproof: a fleet run in which transfer or clone sections still go
  `storage_busy` behind `snapshot` holds longer than the bind, or in which a
  pool is reported `unavailable` while a mutation was in progress.

## Implementation evidence

- [`Storage.observe/4`, `generation/1` and the advance in each section](../../../lilly/lib/lilly/host/storage.ex)
  (contracts `pool-generation-advances-per-mutation` and
  `fenced-observation-never-straddles`).
- [`PoolSnapshot.read_fenced/2` and `current?/1`](../../../lilly/lib/lilly/host/pool_snapshot.ex)
  (contract `fenced-snapshot-reports-only`), with
  [`ZFSDataset.allocations/2`](../../../lilly/lib/lilly/host/zfs_dataset.ex)
  requiring a held lock.
- [`Pool.snapshot/2` and `report/2`](../../../lilly/lib/lilly/host/pool.ex)
  (contract `fenced-capacity-snapshot`) and
  [`PoolObserver`](../../../lilly/lib/lilly/host/pool_observer.ex)
  (contract `pool-observer-fenced-first`).
- BEAM tests listed above. They use the real `PoolQueue`, hostd leases and
  lock directory, but no ZFS.

Remaining gaps: no native ZFS or fleet evidence yet. The fenced read path
(`read_fenced/2` against real `zfs list` output) runs only in machine tests,
and the account-lifecycle suites have not been rerun.

## Open questions

- How the bind's cost (one `zfs` identity probe plus directory claims), which
  still holds the lock in the prologue, compares with the native reads on CI.
  If it is significant, the bind could run only when the token has changed
  since the last successful bind.

## Related decisions

- [ADR-0152](0152-lean-pool-locked-preparation.md): preparations keep the
  locked snapshot. This record narrows ADR-0152's lock rule for capacity
  reports only.
- [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md): the busy
  grace bounds withheld fenced reads.
- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md): FIFO turns
  and the rejected cross-acquisition cache for gates.
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md): the
  background pool observer.
- Review: [2026-10-31 fenced capacity snapshots](../reviews/2026-10-31-fenced-capacity-snapshots.md).
