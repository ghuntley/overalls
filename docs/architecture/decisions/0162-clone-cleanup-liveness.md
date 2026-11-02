# ADR-0162: Clone cleanup liveness and transfer slot release at quiescence

- ID: ADR-0162
- Date: 2026-10-13
- Status: accepted
- Implementation: partial
- Components: Marshall Compute, Lilly clone effects, shared clone protocol, Porsche, machine LiveViews
- Supersedes: ADR-0055
- Superseded by: none

## Context

On 2026-10-13 a same-host clone on the overalls host published its copy and
then sat in `cleaning` for more than ninety minutes because its source-side
`prune` effect never confirmed. Lilly's clone runtime reduced every failure to a
bare unconfirmed result and logged nothing; Marshall recorded
`prune_unconfirmed` with no event. While the request stayed active it held the
host's only transfer slot, so every later clone on the host failed within a
second (`source_unavailable`, folded from a busy slot), two relocations were
refused `transfer_busy`, and the owner saw "Needs attention / Retry" with a
retry that failed again at once. The 2026-09-25 production review had seen the
same shape and judged a forced release unsafe without evidence.

ADR-0055 releases reservations and transfer slots only at the end of the
request. Relocation already releases its slots earlier, at stream quiescence
(both endpoint revocation receipts), while cleanup continues. Clone cleanup had
no deadline, no durable record of refusals in active phases, no failure branch
for a source stop that completes in another state, and a 60-second scheduler
wait after every finish.

## Decision

1. **Unconfirmed effects carry a closed reason.** The clone effect exchange is
   version 5. An unconfirmed result names exactly one reason from the closed
   set in `OverallsProtocol.CloneControl.unconfirmed_reasons/0`; a bare or
   unknown reason is invalid. Lilly classifies every internal failure totally
   (`Lilly.Clone.Reason`) and logs `lilly.clone_effect_unconfirmed` (or
   `lilly.clone_effect_contended` for lock contention) once per effect and
   reason change. Marshall stores the reason, attempt count and time on the
   effect, records the request failure as `<effect>_<reason>`, emits
   `clone.effect_unconfirmed` and `clone.effect_confirmed` after commit on
   changes only, and `clone.failed` carries the real reason and effect
   (`Marshall.Compute.CloneFailure`). Admission refuses a busy source slot as
   `transfer_busy` and a retained previous snapshot as `source_cleanup_pending`.
2. **Transfer slots release at stream quiescence.** A clone's slots release
   once both endpoint `revoke` receipts are on record, in the cleaning and
   cancelling phases, exactly as relocation's do. Pruning, destination
   settlement and source restoration never need the slot. A host is clone-busy
   only while an active request has not published its destination.
3. **Cleanup has a deadline that retains the physical obligation.** Publishing
   stamps `cleanup_deadline_at` (`MARSHALL_CLONE_CLEANUP_DEADLINE_MS`, default
   five minutes). A published, restored, settled and quiescent request whose
   prune is still unconfirmed at the deadline completes: the copy is an ordinary
   machine and the request leaves the per-source queue. It does not release the
   source temporary disk hold, keeps the source excluded from destructive
   operations and another copy, and keeps offering the prune. The prune receipt
   settles the hold, stamps `cleanup_completed_at` and wakes the next request.
   No deadline ever releases a physical resource.
4. **Refusals are durable and scheduling is immediate.** A queued head refused
   by a transient condition (`transfer_busy`, `source_cleanup_pending`) is
   deferred with the reason recorded, not failed, and is re-scheduled when the
   condition clears. Other queued refusals fail with their real reason. A
   refusal in an active phase is recorded on the request. Finishing, failing or
   settling a request schedules the next queued request of the source at once.
5. **A failed source stop is recorded.** When the clone's stop operation
   completes in another state or is cancelled, the request records
   `source_stop_failed`; an owner retry issues one new stop while the source
   generation is unchanged, and cancellation hands the source back to its
   ordinary lifecycle without owing a restart.
6. **Cleanup effects wait for locks.** Lilly's prune waits up to two seconds
   for the placement lock and the pool lock instead of failing on the first
   contended tick. Re-execution after a Lilly restart relies on idempotent
   effects and durable journals; no pending-result journal is added.
7. **Claims are matched by storage shape, and diagnostics name the stage.**
   The first reasoned diagnostic from decision 1 showed why the production
   prune never confirmed: the source restarted after capture with a start
   command carrying a repository workspace source (ADR-0128), and
   `snapshot_source` pinned the full spec struct against the claim its
   stopped predecessor had journaled without one. Claim, snapshot-source and
   import-adoption comparisons use `Lilly.VM.Spec.storage/1`, the spec with
   its guest-delivery source cleared, which is exactly what `Spec.encode/1`
   persists. Snapshot cleanup passes the closed internal stage atom through
   instead of folding every refusal, and both Lilly clone-effect events carry
   it as `stage` beside the wire reason; the runtime reports once per change
   of reason or stage.

## Alternatives

- Forced slot or hold release by an administrator: rejected, because a release
  without a prune receipt could free capacity still occupied by the snapshot.
- Failing the request at the deadline: rejected, because the copy is already
  published and usable; failing it would misreport a finished machine.
- Keeping the bare unconfirmed result and adding host-side logging only:
  rejected, because operators and owners need the reason where the request is
  shown, and the folded `activation_failed` hid distinct causes.

## Consequences

Published copies no longer block a host's other transfers. A source may remain
excluded from deletion, relocation and another copy for as long as its
snapshot cleanup is unconfirmed, now visibly, with a reason. Consumers deploy
together (ADR-0159): an old Lilly against a new Marshall receives
`invalid_message` for one exchange and recovers after its own update. Three
columns are added to `compute_clone_effects` and four to
`compute_clone_requests`; finished rows are backfilled as cleaned up.

## Invariants and verification

- An unconfirmed clone effect result always carries a closed reason; both
  consumers reject any other shape.
- Clone transfer slots are released only when both endpoint revocation receipts
  exist; replays preserve first release timestamps.
- The source temporary disk hold is released only by the prune receipt.
- A request completed with cleanup pending keeps its source excluded
  (`CloneGuard.vm_busy?`) and keeps offering the prune.
- A queued request deferred for a transient reason allocates nothing and is
  activated after release without a user retry.
- A ready claim matches its placement's spec with or without a workspace
  source and refuses any change to the persisted shape.
- Property tests: `clone_cleanup_deadline_test.exs`,
  `clone_restoration_history_test.exs`, `clone_history_test.exs`,
  `clone_matrix_test.exs`; protocol `clone_control_test.exs`; Lilly
  `clone/runtime_failures_test.exs`, `host/claim_shape_test.exs`.

## Implementation evidence

- The closed reason set lives in the
  [clone control protocol](../../../protocol/lib/overalls_protocol/clone_control.ex);
  Lilly classifies failures in [Lilly.Clone.Reason](../../../lilly/lib/lilly/clone/reason.ex)
  and reports them from the [clone runtime](../../../lilly/lib/lilly/clone/runtime.ex);
  Marshall stores and logs them in [CloneEffects](../../../marshall/lib/marshall/compute/clone_effects.ex)
  with the [CloneFailure](../../../marshall/lib/marshall/compute/clone_failure.ex)
  vocabulary (commit `2be51b48c`, trace schema regenerated).
- Slot release at quiescence, deadline completion, cleanup settlement, deferral,
  immediate scheduling and the stop failure branch are in the
  [clone coordinator](../../../marshall/lib/marshall/compute/clone_coordinator.ex),
  the [clone request resource](../../../marshall/lib/marshall/compute/clone_request.ex),
  the [clone guard](../../../marshall/lib/marshall/compute/clone_guard.ex) and
  [clone placement](../../../marshall/lib/marshall/compute/clone_placement.ex);
  Lilly's prune waits for locks in the [driver](../../../lilly/lib/lilly/vm/driver.ex)
  and [clone effects](../../../lilly/lib/lilly/clone/effects.ex).
- Storage-shape claim matching and stage diagnostics: [Spec.storage/1](../../../lilly/lib/lilly/vm/spec.ex),
  [ZFSDataset.claim_matches?/2](../../../lilly/lib/lilly/host/zfs_dataset.ex),
  [SourceSnapshots.cleanup/5](../../../lilly/lib/lilly/transfer/source_snapshots.ex),
  [Reason.stage/1](../../../lilly/lib/lilly/clone/reason.ex),
  [claim shape property](../../../lilly/test/host/claim_shape_test.exs).
- Generated histories:
  [clone cleanup deadline](../../../marshall/test/marshall/compute/clone_cleanup_deadline_test.exs),
  [restoration history](../../../marshall/test/marshall/compute/clone_restoration_history_test.exs),
  [clone history](../../../marshall/test/marshall/compute/clone_history_test.exs),
  [Lilly runtime failures](../../../lilly/test/clone/runtime_failures_test.exs).
- Native clone matrix, cancellation and restart tests: rerun pending; recorded
  in the [review](../reviews/2026-10-13-clone-cleanup-liveness.md) when they run.

**Correction (2026-11-01).** The native published-clone restart scenario in
`cloning-fleet` ([Porsche scenario](../../../nix/verification/tests/machines/fleet/scenarios/porsche.py),
contract `published-clone-native-recovery`) still asserted the superseded
ADR-0055 retention: both slots held while the source restart had failed, a
relocation of the published copy refused `transfer_busy`, and a clone of the
copy failed `source_unavailable` (the busy-slot fold this decision removed).
Its restart fault never fired until 2026-10-31, so the stale expectation went
unexercised. Daily run 41321201081 then failed on the slot count because the
revoke receipts had already released the slots, as decision 2 requires. The
scenario now waits for both revoke receipts and every slot's release while the
request is still cleaning with the source unrestored, asserts that relocating
the unrestored source is refused `clone_in_progress` (`CloneGuard.vm_busy?`),
and asserts that retry and cleanup keep the first release timestamps. The
decision and the Marshall implementation are unchanged.

## Open questions

- Whether the deadline should also complete a request whose destination settled
  as failed; it currently waits for the prune like before.
- Whether a very long unconfirmed prune should escalate to an administrator
  view beyond the control-room audit.

## Related decisions

- [ADR-0055](0055-queued-machine-cloning.md): queued cloning; its slot clause
  is superseded here.
- [ADR-0145](0145-same-pool-block-cloned-clones.md): same-pool copies and the
  prune mount release.
- [ADR-0143](0143-faster-create-clone-delete.md): pool-lock contention retried.
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md): slowness
  is never evidence of loss; deferral instead of failure.
- [ADR-0061](0061-maintenance-evacuation.md): host-busy narrowing for drains
  and evacuations.
- [ADR-0159](0159-remove-legacy-compatibility.md): no compatibility path for
  the protocol version.
- [ADR-0128](0128-repository-launch-links.md) and its successor
  [ADR-0157](0157-multi-provider-authenticated-repository-launch.md): the workspace source is
  carried on `provision`/`start` commands and never persisted in dataset
  identities; decision 7 makes the claim comparisons honour that.
