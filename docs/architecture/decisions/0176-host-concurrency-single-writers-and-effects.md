# ADR-0176: Host concurrency through single writers, reconcilers and a host-effects engine

- ID: ADR-0176
- Date: 2026-10-16
- Status: accepted
- Implementation: planned
- Components: Lilly Host, Lilly VM, Lilly Control, Lilly native, NixOS lilly module
- Supersedes: none
- Superseded by: none

## Context

The user asked how to stop "the host lock" from blocking host work, and asked
for the best possible design with everything open to reconsideration. They
approved the redesign plan on 2026-10-16. The facts below are from the code
and from read-only production measurements; the review is
[2026-10-16 host concurrency](../reviews/2026-10-16-host-concurrency.md).

**There is no single host lock.** `Lilly.Host.Lock` is a per-directory
`flock`. A native `lilly-host-lock` helper holds each lock, and that same
helper also runs every mutating utility. So each lock does two other jobs:
crash custody (on caller EOF it kills and reaps the utility before
releasing), and the only route for executing mutations. Lilly has about 20
lock inodes: host owner, runtime, placement, actor, journal audit, launch
intent, pool, template lease, standby refill, network and transfer. A
root-disk copy holds only the placement lock and a shared template lease.
ADR-0173 decision 10 said otherwise and has been corrected.

**Production evidence** (dungarees, 7 days):

- **Copies are not the problem.** Root-disk `image_copy` p50 is 15 ms and p95
  126 ms, because creates take block-cloned standbys. The 30-minute 64 GiB
  copy happens only on stores that cannot clone, such as the nested test's
  9p share.
- **Creates are slow in the preparation step.** From pending to ready, a
  create takes p50 50 s and p95 149 s, and almost all of that is in
  `materializing`: p50 46.8 s, p95 144 s. On the quieter overalls host,
  `materializing` takes p50 1.3 s.
- **Bursts are serialized on the pool lock.** Bursts of 23–26 creates
  arriving within about one second drain at one launch every 1.9–2.3 s, so
  the last create waits 77–149 s.
- **Each create does 90–210 utilities under the pool lock.** It runs two
  exact whole-pool observations, and the usage counters move under load, so
  each retries up to three times. It also runs identity probes. The capacity
  credits this computes are thrown away (`ZFSDataset.prepare`): Marshall is
  the admission authority.
- **Waiters poll instead of queueing.** A waiter polls a non-blocking flock
  every 10–30 ms, starting a new helper process each time. It gives up after
  one second with `storage_busy` (99 such deferrals in two burst hours) and
  retries on the actor's one-second tick. There is no FIFO.
- **Other work competes for the pool lock:**
  - the capacity reporter;
  - roughly 1,300 standby fills and 1,550 retirements a week, each taking the
    lock two or three times;
  - template builds. While one runs (copy up to 35 s, in-BEAM SHA-256 up to
    67 s), creates of the same image get `storage_busy`.
- **Observation runs through the mutation path.** Every running VM is
  re-adopted through `Driver.launch/5` every second. Each re-adoption takes
  the placement, intent and host-wide network locks and runs `systemctl
  show`. 62 `systemctl` calls hit the 3 s timeout.
- **A create cannot be cancelled.** It is one opaque actor task. A stop or
  delete waits for the whole create.
- **No privilege boundary.** Lilly runs as root without hardening, and the
  helper provides custody, not privilege separation.

**Root cause.** A lock, crash custody and the executor are the same thing, so
the scope of a lock grows to cover everything executed under it. Owners are
implicit (`Lock.current`, about 45 call sites). Contention becomes a polling
retry instead of a queue. Every create repeats the same whole-pool work on
its own.

## Decision

Six decisions are adopted. Each one ships separately, and its implementation
evidence is recorded here as it lands.

1. **One writer per pool, with group commit.**
   - `Lilly.Host.PoolWriter` (one per pool) holds the pool `flock` for its
     whole lifetime. It keeps the same inode and the same caller-death
     fencing. It is the only process that runs pool mutations and writes
     claim journals. Its in-memory index is rebuilt from the durable
     journals, which remain authoritative and write-ahead.
   - Callers wait in FIFO order within priority classes: claim and ready
     first, then transfer, clone, delete and resize, then audit, then upkeep.
     They block on a reply with a deadline. `storage_busy` means only that
     the queue overflowed.
   - A batch of claims takes one identity-mode gate read. It then journals
     each claim and applies one native step per claim (`zfs create`, or
     `zfs set` plus `zfs rename`). ZFS refuses an existing name atomically.
     One targeted verification follows for the whole batch.
   - Readies are batched the same way, using targeted reads.
   - The exact whole-pool audit (classification and credit) runs inside the
     writer between batches, with a guaranteed slot at least every 2 s. It
     publishes a lock-free capacity view (ADR-0140).
   - Marshall stays the admission authority, and the parent quota stays the
     physical ceiling.
   - The whole-pool classification that ADR-0152 requires is kept, in the
     audit. A claim needs only a gate read taken after the last Lilly
     mutation, which the single writer guarantees, plus facts about its own
     name.
2. **Reconciler actors, and observation off the mutation path.**
   - `Lilly.VM.Actor` becomes a state machine. A pure step planner drives it
     through: await template, claim, materialize, bundle, network attach,
     launch commit, observe boot, trust.
   - Each step holds the placement lock only for its own duration.
   - A newer stop or delete cancels any step before the single launch commit,
     and the completed steps are compensated.
   - Steady-state observation takes no mutation lock and spawns no
     utilities. Re-adoption runs only at startup and when the command
     changes.
   - Waits are event-driven, not retry ticks.
3. **Templates build once per image and are verified natively.**
   - A template steward runs one build per (pool, image), and creates
     subscribe to it.
   - `lilly-image-copy` gains single-pass `digest` and `copy-digest` modes,
     bounded by the pool's image I/O deadline. Digests are cached by store
     path and nanosecond identity.
   - BEAM hashing is deleted.
   - *Revision (2026-10-16, after measurement):* the digest cache is built,
     but the native single-pass modes are deferred and BEAM hashing stays.
     It already runs through native OpenSSL `:crypto`, and the remaining
     cost is I/O. The restart cost the decision targeted comes from
     re-hashing unchanged images, which the cache removes. A native mode
     would add a crypto dependency to a privileged helper for little gain.
     It is reconsidered only if a measured build is bound by CPU rather
     than I/O.
4. **`lilly-hostd`, a native host-effects engine.**
   - One privileged Rust daemon in its own unit is the only host mutator.
     All policy stays in the BEAM.
   - Commands form a typed, closed set over one authenticated `SOCK_SEQPACKET`
     session.
   - Explicit leases with a strict rank order and FIFO queues replace
     `Lock.current`. Real `flock`s remain only for the host owner and for the
     launch intent lock that crosses `exec`.
   - An outcome ledger gives at-most-once execution per request. A lease is
     released only after its effects finish and their subprocesses are
     reaped.
   - Every placement effect is fenced on `{epoch, generation}`, and the
     launch commit is atomic.
   - Native executors:
     - files: `openat2` and `renameat2`;
     - systemd: D-Bus;
     - ZFS: channel programs and `libzfs_core`, with the CLI as a fallback;
     - network: atomic nftables batches and rtnetlink;
     - subprocesses: the subreaper custody ported from `lilly-host-lock`.
5. **Durable host jobs.** Template builds, standby fills, clone copies and
   backup captures become checkpointed jobs run by `lilly-hostd`. They survive
   BEAM restarts and resume after a `lilly-hostd` restart. Clone copies run in
   parallel up to a per-pool bound.
6. **Standbys only on evidence.** A 26-create burst runs with standbys
   disabled. If on-demand clones stay below 1 s p95, a follow-up ADR deletes
   the standby subsystem. Otherwise standbys become the lowest-priority
   writer jobs.

**Security end state.** Units are hardened, then the BEAM runs unprivileged
and `lilly-hostd` is the only root component. That privilege drop needs its
own audit.

**Migration order:**

1. Correct the documentation and add instrumentation.
2. Quick wins in the current code: identity-mode observations, targeted
   readiness checks, and no per-second re-adoption.
3. Pool writer.
4. Reconciler actors and the template steward.
5. Native digest.
6. `lilly-hostd` core.
7. `lilly-hostd` effects: files, then D-Bus, then ZFS, then network.
8. Durable jobs.
9. Standby evidence.
10. Hardening and the privilege drop.

## Alternatives

- **Shard the pool lock per placement.** Rejected, as in ADR-0152. It loses
  the whole-pool view. A single writer centralizes the pool instead of
  sharding it.
- **Cache pool observations across lock acquisitions.** Rejected: the gate
  must follow the last mutation. That holds by construction only because
  there is a single writer.
- **Keep the current helper and add queueing in the BEAM only.** Accepted
  only as the first migration steps. It cannot remove process spawns,
  implicit owners or uncertain outcomes, and it adds no privilege boundary.
- **A NIF instead of a separate daemon.** Rejected. Custody and privilege
  separation need a separate process lifetime, and a crashing NIF takes the
  whole BEAM down.
- **A durable log of every effect.** Rejected. An in-memory ledger, plus
  durable jobs, intents and launch markers, plus re-observation after a
  daemon restart, is enough.
- **A transient systemd unit per job.** Rejected. Checkpointed jobs as
  `lilly-hostd` children are simpler, and only VMMs need custody across
  `exec`.
- **Physical ZFS reservations for admission.** Rejected by the earlier user
  decision for sparse storage (ADR-0031).
- **Standbys as clones of template snapshots.** Rejected. Accounting refuses
  clones, and a clone ties the template's lifetime to every VM made from it.

## Consequences

- **Burst latency:** creates become one or a few batches instead of a queue
  served one at a time. Contention is queued, not polled.
- **No noise from observation:** running VMs no longer generate per-second
  lock or `systemctl` traffic.
- **Cancellable creates:** stop and delete can preempt a create before its
  launch commit.
- **Survives restarts:** long work outlives BEAM restarts.
- **Privilege boundary:** the host gains a real privilege boundary at the
  end.
- **Costs:**
  - a new privileged Rust daemon, which becomes a single point of failure
    for host effects;
  - a protocol between two units, which needs a version handshake;
  - FFI to ZFS and D-Bus;
  - a changed rule on caller death: an atomic effect that has started now
    completes instead of being killed. That is safe only together with
    generation fencing and the ledger, and ADR-0017 must be reviewed against
    it.
- Each step amends the affected ADRs (0015, 0017, 0140, 0146, 0152, 0163,
  0165) with reciprocal links when it lands.

## Invariants and verification

- **Pool writer:** it is the only pool mutator. Each batch's gate is read
  after the previous batch's mutations. The result of a batch equals
  applying its claims one by one, in order (property test with a mutant
  check). Credit comes only from the writer's audit.
- **Launch commit:** it runs at most once per placement, epoch and
  generation, across crashes and command interleavings (property test).
  Preemption before the commit always reaches the newer intended state.
- **Leases:**
  - a lease is held only for the resource it names;
  - acquisition follows a strict rank order;
  - waiters are served FIFO within a priority;
  - a lease is released only after its effects are terminal;
  - a caller's death never lets a successor run before the caller's
    utilities are reaped.
  - These are tested with Hegel properties and the new machine test
    `host-effects-custody`.
- **Other guarantees:**
  - a request runs at most once per id;
  - an effect older than the current intent is refused;
  - a job's checkpoint only moves forward;
  - the native digest equals the reference implementation.
- **Production targets** (dungarees, 26-create burst):
  - the last create's materializing-to-launching < 10 s;
  - zero `storage_busy` deferrals during create preparation;
  - `systemctl` timeouts near zero;
  - template build p95 < 10 s.
- **Machine tests:** `zfs-guest` (burst, and preempting a create),
  `image-template` (one build for N creates, restart during a build),
  `zfs-lifecycle`, `executor-loss`, `auto-update`, `windows-lilly-guest` and
  the clone and transfer tests.

## Implementation evidence

Migration steps 1 and 2 (documentation, instrumentation and quick wins in the
current code):

- **Corrected statement.** ADR-0173 decision 10 and the HLDD storage chapter
  now give the copy's actual locks.
- **Pool-section event.**
  [`Lilly.Host.Storage.locked/4`](../../../lilly/lib/lilly/host/storage.ex)
  tags every pool section with a fixed kind. For any busy acquisition, and
  any section whose wait plus hold time is 500 ms or more, it emits
  `lilly.pool_section` (contract `pool-section-diagnostics`;
  [storage test](../../../lilly/test/host/storage_test.exs)).
- **Identity-usage snapshots.** Preparation, readiness and owned-identity
  checks read
  [`PoolSnapshot`](../../../lilly/lib/lilly/host/pool_snapshot.ex) with
  identity usage, so moving usage counters no longer resample them.
  `ZFSDataset.classify_allocations/2` returns credit only for an exact
  snapshot (contracts `prepare-reads-native-state-once`,
  `allocation-classification-from-one-snapshot`).
- **Steady-state reconcile backstop.**
  [`Lilly.VM.Actor`](../../../lilly/lib/lilly/vm/actor.ex) skips per-tick
  reconciles once it is steady: three unchanged running outcomes and an
  armed watcher on the proof's VMM. It then reconciles every 10 s, and any
  evidence ends steadiness (contract `steady-state-reconcile-backstop`;
  [actor watch test](../../../lilly/test/vm/actor_watch_test.exs)
  `steady-actor-skips-ticks-until-evidence`).
- **Settled failed outcome.** A placement whose launch failed but whose
  desired state is still running kept its command, so its actor re-ran the
  failure fence, with its placement, intent and network locks, every second
  until Marshall sent a newer command (production, 2026-10-17). The actor now
  settles once it has durably recorded a failed outcome for the exact current
  command: ticks and unchanged reconcile casts start no work, and a newer
  command or delete drives at once. A replacement actor re-observes once, so
  readiness still needs a current-runtime observation (contract
  `failed-outcome-settles-command`;
  [settled-failure property](../../../lilly/test/vm/actor_failure_settled_test.exs)).
  This refines the cadence and keeps ADR-0017's rule that a failed launch
  needs a new explicit command; Marshall's outcome path is unchanged.

Decision 1, first stage (FIFO turns):
[`Lilly.Host.PoolQueue`](../../../lilly/lib/lilly/host/pool_queue.ex)
grants one turn per pool lock directory, with priority classes
(observations, then mutations, then upkeep), first come first served within
a class (contract `pool-turns-fifo-per-priority`).
[`Storage.locked/4`](../../../lilly/lib/lilly/host/storage.ex) takes a turn
before the native `flock`. A create's preparation and readiness sections wait
up to 30 s for their turn, and `Storage.contended?/1` reports queued waiters.
Evidence:
- the [queue property test](../../../lilly/test/host/pool_queue_test.exs)
  (`pool-turns-order-oracle`) checks exclusive turns and their order against
  an independent sort;
- the queue tests also cover expiry, caller death and forfeiture;
- the [storage test](../../../lilly/test/host/storage_test.exs)
  `burst-drains-without-busy` runs 10 overlapping create sections, one at a
  time, with no `storage_busy`.

A BEAM that runs no queue (eval tools, probes) contends only on the native
lock, polling it for at most 2 s. Decision 1, second stage (group commit by flat combining):
[`Storage.combine/5`](../../../lilly/lib/lilly/host/storage.ex) lets the
turn holder take up to 15 queued items of the same kind
(`PoolQueue.take/3`, contract `pool-turn-combining`) and run them as one
batch, answering each waiter with its own result (contract
`pool-batch-flat-combining`).

[`ZFSDataset.prepare_batch/3`](../../../lilly/lib/lilly/host/zfs_dataset.ex)
prepares every create in a batch from one identity snapshot, one allocation
audit and one re-read after the batch's mutations
(`prepare-reads-native-state-once`). A failure in one placement is isolated
from the others; a failure of a shared read or audit fails every placement.
[`Disk`](../../../lilly/lib/lilly/vm/disk.ex) routes create preparation
through it.

Evidence:

- **Property test.** `combined-batches-answer-each-item` in the storage test
  checks that batches run exclusively, that each item gets its own result,
  and that some batches hold more than one item.
- **Native machine test.** `checks.image-template` passed on this change on
  2026-10-16, with a 294 s test script. It ran native preparation of
  standby-claimed and ordinary disks through `prepare_batch/3` (in single-item
  batches, because the probe BEAM runs no queue), plus the ADR-0152 trace
  limits and crash recovery.
- **Probe fixes for ADR-0163.** That ADR had left the probe stale. The probe
  now passes the ADR-0163 refill budget map. It also expects an unconfigured
  image's sealed standbys to stay until configured replacements are sealed.

The pool lock is still taken in the holder's process; a dedicated
long-lived writer process is not needed while combining reaches the same
batching.

Decision 3, first stage:
[`Lilly.Host.TemplateSteward`](../../../lilly/lib/lilly/host/template_steward.ex)
runs at most one build per pool and image (contract
`template-build-single-flight`). `ImageTemplate.ensure/3` keeps the ready
fast path inline and sends a miss to the steward. A create waits at most
2 min; prewarm waits 4 × the image I/O deadline. The
[steward property test](../../../lilly/test/host/template_steward_test.exs)
(`template-builds-coalesce`) checks one build per image under concurrent
callers, that an expired wait does not cancel the build, and that a crashed
build is reported.

[`Image.load_cached/2`](../../../lilly/lib/lilly/host/image.ex) skips
rehashing an unchanged configured image after a Lilly restart. It uses a
private digest cache keyed by path, manifest ID and native nanosecond file
identities (contract `image-digest-cache-exact-identity`; the
[image tests](../../../lilly/test/host/image_test.exs) check reuse, replaced
and corrupted files, and that a non-private cache is ignored).
`ImageCatalog` uses it. On dungarees, after the 64 GiB Windows image was
added, startup verification took 60–85 s per restart, and Windows was not
advertised during that time. Measured on dungarees after the change:

- the first restart (deploy of `df4544624`, 2026-10-16 03:03 Z) hashed all
  images in 60 s and wrote the cache: 3 entries, mode 0600 in a 0700
  directory;
- the next restart (deploy of `47a08f0a1`, 03:18:52 Z) verified every image
  0.08 s after `lilly.started`.

The single-pass native copy-and-digest is not built. Hashing already runs
through `:crypto` (native OpenSSL), and the remaining cost is I/O, which a
Rust rewrite would not remove. It would also add a crypto dependency to a
privileged helper.

Decision 2, first stage (preemptible creates):

- **Commit check.** [`Driver.launch/5`](../../../lilly/lib/lilly/vm/driver.ex)
  calls a commit check immediately before persisting `launch-attempt.bin`
  (contract `launch-commit-check`).
- **Actor side.** [`Lilly.VM.Actor`](../../../lilly/lib/lilly/vm/actor.ex)
  grants the commit only to its in-flight task while that task's command is
  still the newest stored command (`launch-commit-single-decision`). A newer
  command kills an uncommitted task and starts at once
  (`newer-command-preempts-uncommitted`), emitting `vm.execution_preempted`.
- **Unit evidence.** The
  [preemption test](../../../lilly/test/vm/actor_preemption_test.exs)
  (`preemption-before-commit-only`) covers an uncommitted start killed by a
  stop, a committed start that is not preempted, and a superseded commit
  being refused.
- **Updated contract.** The cadence test `actor-cadence-no-lost-request` now
  states the preemption rule.
- **Not yet proven natively.** No machine test exercises actor-driven
  preemption. The probe-based native tests call `Driver` without a commit
  check, so they cover only the unchanged default path. The whole-fleet
  `executor-loss` test is too heavy to run on the production development
  host.
- **Step-wise launch (second stage).**
  [`Driver.launch/5`](../../../lilly/lib/lilly/vm/driver.ex) runs as six
  steps: begin, disk, boot, jail, network and commit. Each holds the
  placement lease only for its own duration, waiting at most 2 s in
  hostd's queue (`launch-steps-fenced`). Every step after begin re-reads
  `launch_fence/3` (`launch-fence-exact`): the exact intent begin set, no
  tombstone, a stopped unit and no attempt at or beyond the revision. A
  changed fence returns `:preempted` before that step's effects. Commit
  checks the actor's grant, persists `launch-attempt.bin` and starts the
  unit in one section. Native evidence is recorded below.

Production burst measurement (user-approved, 2026-10-16 03:49 Z), after
deploying `47a08f0a1`:

- **Setup.** 26 concurrent Ubuntu creates through Porsche (1 vCPU, 2 GiB,
  5 GiB). Marshall placed 23 on overalls and 3 on dungarees.
- **End to end.** All 26 reported `running` within 18.7 s of the first
  request.
- **Overalls (23 creates).**
  - `materializing → launching` took p50 7.3 s and max 10.7 s. Before the
    change, bursts of 23–26 left the last create waiting 77–149 s.
  - There were no `storage_busy` deferrals.
  - Dataset preparation ran in three batches of 1, 15 and 7 creates,
    holding the pool for 549 ms, 1 997 ms and 1 287 ms, about 3.8 s in
    total. Before, it was about 2 s per create, about 46 s.
  - Readiness was not yet batched. It ran once per create at about 0.27 s
    under the pool lock, which accounted for most of the remaining wait.
- **Cleanup.** All 26 VMs were then deleted (56 s) and confirmed absent.

Decision 1, readiness batch:
[`ZFSDataset.ready_batch/2`](../../../lilly/lib/lilly/host/zfs_dataset.ex)
reads the owner set, mount table, staged imports and one identity
observation once per batch, then checks each placement on its own (contract
`readiness-batch-shared-reads`). A create's readiness section goes through
`Storage.combine/5` like preparation.

Decision 6, evidence campaign (user-approved): the Ubuntu image is
standby-ineligible in
[`fleet/guest-images.nix`](../../../fleet/guest-images.nix). Its existing
standbys retire like a replaced image's. The 26-create Ubuntu burst is then
repeated, so on-demand creates can be compared with the standby burst above.
NixOS keeps its standbys.

Measured on 2026-10-16 04:24 Z, after deploying `cd6f0c513` and retiring
Ubuntu's standbys (each host went from 64 standbys to 32). All 26 creates
were running 15.7 s after the first request; the standby burst took
18.7 s. Marshall placed 22 on overalls and 4 on dungarees.

| Overalls burst | Standbys (03:49 Z, 23 creates) | On demand (04:24 Z, 22 creates) |
|---|---|---|
| `materializing` | p50 7.3 s, max 10.7 s | p50 4.1 s, max 4.9 s |
| Disk source | standby claim (rename) | `image_copy` block-clone offload from the template |
| Image copy time | none (no copy) | p50 966 ms, p95 1 044 ms, max 1 046 ms, outside the pool lock |
| Preparation batches | 1, 15, 7 | 7, 14 |
| Readiness | not yet batched | batches of 8 and 13, 0.26–0.31 s hold each |

The two bursts are confounded: readiness batching shipped between them.
On-demand copy p95 (1.04 s) is just above the 1 s threshold this decision
named, while total create latency was lower than with standbys. Removing the
standby subsystem is therefore left to the user. All burst VMs were deleted.
The user chose to retire standbys:
[ADR-0177](0177-retire-standby-guest-disks.md) drains them and then deletes
the subsystem.

Production effect against the step-1 baseline: after deploying `fdf7e896e`,
dungarees showed no slow or contended pool sections, `systemctl` timeouts or
deferrals in its first minutes. There were no creates in that window, so the
effect on bursts is not yet measured.

Decision 4, first stage (hostd core):
[`lilly-hostd`](../../../lilly/native/hostd/src/lib.rs) replaces one
`lilly-host-lock` process per held lock, and `LockedCommand`, with one
daemon that holds every lease.

- **Leases.** [`Leases`](../../../lilly/native/hostd/src/leases.rs) keeps
  the `flock` on the existing `owner.lock` inodes, opened beneath configured
  roots with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS`. It grants waiters per
  inode in arrival order (`lease-queue-fifo-per-inode`). Other processes
  still contend on the same inodes.
  [`Lock`](../../../lilly/lib/lilly/host/lock.ex) keeps its API, with a
  `Lease` handle instead of a port. `Lock.await/2` replaces the pool
  section's polling with one queued wait.
- **Closed utilities.** Lilly names a utility by index
  ([`utilities.rs`](../../../lilly/native/hostd/src/utilities.rs),
  `hostd-utility-table-closed`). hostd resolves executables from its own
  PATH, clears the environment and refuses mutating utilities without a
  lease. Lease-less reads run in hostd too (third stage): Lilly spawns no
  host utility itself.
- **Custody.** In production each command runs in its own child of hostd's
  delegated cgroup. A reply, release or session end follows `cgroup.kill`
  and a confirmed empty cgroup (`hostd-command-reaped-before-reply`,
  `lease-release-after-commands-reaped`, `session-close-custody`). The lease
  descriptor is inherited by the utility, so a utility that outlives hostd
  still holds the lock.
- **Session.** [`Lilly.Host.Hostd`](../../../lilly/lib/lilly/host/hostd.ex)
  is the BEAM's one `SOCK_SEQPACKET` session. A holder's death releases its
  leases. A lost session stops the process, which every holder monitors. A
  BEAM without `LILLY_HOSTD_SOCKET` (eval tools, probes, unit tests) starts
  a private daemon with process-group custody.
- **Deployment.** The [Lilly module](../../../nix/domains/system/lilly.nix) adds
  `lilly-hostd.service` (`Type=notify`, `Delegate=yes`, root peers in
  `lilly.service` only), and binds Lilly to it (`hostd-unit-custody`). The
  auto-updater's health units include it.

Evidence:
- 12 [hostd tests](../../../lilly/native/hostd/src/tests.rs): Hegel decoder
  and lease-order properties against independent models, plus real-utility
  session tests for timeouts, busy leases, release and session-death custody;
- the [lock test](../../../lilly/test/host/lock_test.exs)
  `holder-death-kills-leased-command` and `waiters-granted-in-arrival-order`;
- Lilly `mix test`, 550 passed, against the real daemon;
- `checks.lilly-native-actor-recovery` passed in 893 s (baseline `87826bb3a`
  840 s). Its probe BEAM used the production `lilly-hostd.service` unit
  (cgroup custody, the unit's PATH) for real guest creates, reads, deletes
  and an abrupt worker BEAM loss. Two startup defects it found are fixed;
- the [hostd core review](../reviews/2026-10-16-lilly-hostd-core.md).

Not done in this stage: explicit rank-ordered leases at the ~45 sites, the
outcome ledger, generation fencing and typed native effects.

Decision 4, second stage (lease order, fencing and the ledger):
- **Lease order.** [`LockOrder`](../../../lilly/lib/lilly/host/lock_order.ex)
  classifies every lease directory and records each nesting a process
  performs, in the manner of the kernel's lockdep. Acquiring a class while
  holding one previously acquired under it is reported as
  `lilly.lease_order_inverted` (`lease-order-inversion-reported`; property
  test `lease-order-inversion-oracle` against an independent model). This
  stage reports and never refuses: a strict refusal is enabled only after
  production shows no inversions. First data (2026-10-16): overalls
  reported `pool` then `other` twice in six hours, dungarees twice; the
  machine runs reported `transfer` under `pool` and `placement` against
  `other`. `other` still groups several unrelated directories (socket
  custody, permit journals), so its pairs are not yet evidence of one
  inverted pair; the next step is to give those directories their own
  classes, then review the remaining real inversions before enforcing.
- **Generation fencing** is met without a hostd copy of the intent: every
  launch step re-reads `intent.bin`, the tombstone, the unit state and the
  attempt under the placement lease (`launch-fence-exact`), and only the
  commit step writes `launch-attempt.bin` and starts the unit
  (`launch-steps-fenced`). hostd holds that lease, and a dead holder's
  commands are reaped before anyone else is granted it, so a hostd-side
  fence would re-check the same file under the same lease.
- **Outcome ledger.** Ordinary commands are killed and reaped when their
  session ends, so they never complete after their caller and need no
  ledger. Commands that do outlive the caller are durable jobs; their keys
  give at-most-once execution while running and an attachable result for
  ten minutes (`durable-job-outlives-session`).

Decision 4, typed commands, first command (the VM launch): `systemd-run`
started each guest's root process chain from a command line Lilly built,
which let a compromised BEAM run any root command through hostd. hostd now
offers a typed `LaunchVm` instead (operation 10,
[`vm_launch.rs`](../../../lilly/native/hostd/src/vm_launch.rs)): Lilly sends
the placement, epoch, generation, jail uid, memory, vCPUs, boot kind,
logging switch, VM state directory, network namespace and pool, and hostd
validates each (reserved uid range, bounds, a configured pool root, a
state directory beneath its lease roots) and builds the command line from
executable paths the [Lilly module](../../../nix/domains/system/lilly.nix) gives
it (`vm-launch-argv-derived-by-hostd`). Direct `systemd-run` requests are
refused by the decoder, and Lilly's utility tables no longer name it.

Decision 4, native file executor: `chmod`, `chown`, `mv`, `rm`, `truncate`,
`mkfifo` and `sync` are no longer run as programs. hostd accepts only the
argument shapes Lilly uses (`chmod MODE -- P`, `mv [--no-clobber]
--no-target-directory -- A B`, `rm [--force|-rf --one-file-system] -- P`,
`truncate --size N -- P`, `mkfifo --mode=0600 -- P`, `chown U:G -- P`,
`sync -- P…`) and performs each on descriptors: every path is resolved
from an open root with `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)`, the
final component is never followed, modes are limited to 0400, 0444, 0600
and 0700, and owners to the VM uid range or the service uid
([`files.rs`](../../../lilly/native/hostd/src/files.rs),
`native-file-effects-beneath-roots`). The roots are Lilly's state
directories, pools and its own `/run/lilly*` and backup directories, not
all of `/run`. Lilly's call sites are unchanged. Tests cover each shape and
the refusals, including a symlinked component whose outside target stays
untouched. `mount`, `umount`, `cp`, the ZFS mutations, `nft` and `ip` still
take Lilly's arguments.

Decision 4, argument grammar for the remaining utilities: an inventory of
every argv Lilly sends found that the closed executable table did not
close behaviour. `zfs` and `zpool`, marked read-only, would still destroy;
`systemctl` could stop any unit; `sysctl -w` could set any kernel
parameter; and `Command.in_namespace` sent `ip netns exec NS <absolute
executable>`, arbitrary root execution. hostd now checks every program's
argv against Lilly's shapes before running it
([`policy.rs`](../../../lilly/native/hostd/src/policy.rs),
[`zfs_policy.rs`](../../../lilly/native/hostd/src/zfs_policy.rs),
`utility-arguments-grammar`, `zfs-arguments-within-pools`): ZFS names
strictly beneath the configured pool datasets with an allowlist of
properties; `ip` and `sysctl` only on Lilly's devices and namespaces;
`netns exec` only for `ip`, `nft`, `sysctl` and the flow labeller, whose
path hostd replaces with its own; `systemctl` only on `lilly-vm-*` units;
image copies, the backup `cp` and `ssh-keygen` beneath the file roots.
Durable jobs are checked the same way. The grammar applies to the
production unit (pool datasets configured); a private daemon started by an
eval tool runs with its owner's own privilege and is not confined. Residual
risks: `nft` rule-file content, the ZFS snapshot mount's `mount(8)` target,
and the peer-supplied resume token, which only its helper's parser checks.

Steady-state spawns, measured: on 2026-10-16 a 60 s trace of `lilly-hostd`
on a nearly idle overalls counted about 94 utilities a second (`realpath`
2704, `zfs` 1194, `stat` 836, `zpool` 507, `findmnt` 419), mostly the pool
identity check behind each one-second report. Mount, path and device facts
are now read natively ([`MountTable`](../../../lilly/lib/lilly/host/mount_table.ex),
`mount-table-matches-findmnt`; [`Paths`](../../../lilly/lib/lilly/host/paths.ex),
`canonical-path-matches-realpath`, `block-device-numbers-from-sysfs`), each
checked against the utility it replaces on both hosts' real tables. Native
executors were weighed against the same measurement: pool listings take
about 15 ms for 8 datasets, network changes are already one `nft --file`
batch per guest, and `systemctl` reported no failures in 24 hours, so
`libzfs_core`, rtnetlink and D-Bus are deferred until a measured section is
bound by them.

Decision 1, queued deletes: a disk delete waits up to 30 s in the pool's
FIFO queue, like a create's sections. Before this change it gave up after
one second and rejoined at the back: 228 of 526 slow or contended pool
sections on overalls in 24 hours (2026-10-16) were deletes refused as busy
after exactly 1001 ms.

Decision 5, first stage (durable jobs):
[`lilly-hostd`](../../../lilly/native/hostd/src/session.rs) runs a
`RunDurable` command on its own thread under the caller's lease and stores
its result under a 32-byte key for ten minutes (`durable-job-outlives-session`,
`durable-job-attach`). Closing the session neither cancels the job nor frees
its lease; the job frees the lease when it finishes if its session has gone.
Template file copies use it
([`ImageTemplate`](../../../lilly/lib/lilly/host/image_template.ex),
`template-copy-durable`): after a Lilly restart the rebuilt template attaches
to the copy already in flight instead of killing and restarting it. The
template's Ash journal stays the checkpoint across a hostd restart, which
still kills running jobs with hostd's cgroup. Evidence: the hostd test
`durable-job-survives-session` (13 hostd tests pass) and the Lilly suite
(image template tests run through a private daemon). Clone file copies are
durable jobs too ([`CloneCopy`](../../../lilly/lib/lilly/transfer/clone_copy.ex),
`clone-copy-durable`): a re-entered copy attaches to the copy in flight,
and starts again only when hostd knows no job for its key or the finished
job's temporary file is gone.

Backup captures need no hostd job: `Lilly.Backup.main` runs in the
`overalls-backups` service, a separate process with its own private
hostd, whose Lilly-side steps (snapshot, metadata copy, mount) take seconds;
restic then reads the mounted snapshot itself. A Lilly restart cannot
interrupt a capture, which is what this decision guards against. After a
hostd restart, which kills its jobs with its cgroup, template copies start
again from their Ash journal, and clone copies resume per file from their
`file_copied` journal records, so no copy restarts from nothing.

Security end state, first stage (hardening): the
[Lilly module](../../../nix/domains/system/lilly.nix) applies namespace-free
hardening to both units (`lilly-units-namespace-free-hardening`): a reduced
capability bounding set, native syscall architecture, locked personality and
no realtime scheduling. `RestrictSUIDSGID` was in the first deployment and is
removed: systemd cannot inspect `openat2`'s argument struct, so that filter
fails every `openat2` with ENOSYS; every hostd lease was refused and Lilly
could not start on either host (2026-10-16, `fb691e517`). Mount namespaces
(`ProtectSystem`, `PrivateMounts`) are ruled out for both units, because hostd
mounts guest datasets for the host and the private pool propagation of
ADR-0144 would hide new guest mounts from a Lilly namespace. The privilege
drop followed in [ADR-0182](0182-unprivileged-lilly-beam.md): the BEAM runs
only as the unprivileged `lilly` user, and hostd is the only root component.

## Open questions

- **ZFS:** channel-program instruction and memory limits for about 300
  datasets, and whether `lzc_rename` and `zfs.sync.set_prop` exist on the
  fleet's OpenZFS.
- **D-Bus transport:** the system bus or `/run/systemd/private`, tested
  under `auto-update`.
- **Batch rules:** batch size cap, fairness, and isolating a failed item from
  the rest of its batch.
- **Fencing window:** when an orphan dataset fences the pool, the window
  grows from about 1 s to one batch.
- **Privilege drop:** feasibility for netns, terminal, ingress, vsock and
  secret reads.

## Related decisions

- [ADR-0015](0015-jailed-execution-and-host-networking.md) and
  [ADR-0017](0017-durable-vm-actors-and-host-ownership.md): the lock helper
  and host ownership.
- [ADR-0031](0031-sparse-zfs-storage-and-capacity.md): sparse storage, no
  reservations.
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md):
  single-writer views.
- [ADR-0146](0146-standby-guest-disks.md): standbys.
- [ADR-0152](0152-lean-pool-locked-preparation.md): lean pool-locked
  preparation.
- [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md): bounded
  standby refill.
- [ADR-0165](0165-restart-only-changed-units.md): restart only changed units.
- [ADR-0173](0173-windows-images-winget-desktop-experience.md): decision 10's
  corrected lock statement.
