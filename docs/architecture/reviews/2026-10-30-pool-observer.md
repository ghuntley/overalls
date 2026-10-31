# Pool observer off the report path (2026-10-30)

Scope: fleet machine tests failed enrollment with "Idle capacity expires
between reports" after the host report cadence drifted past Marshall's 5 s
capacity freshness. This review covers the cause, the background pool
observer recorded as an update to
[ADR-0140](../decisions/0140-event-driven-liveness-and-single-writer-views.md),
and its relation to
[ADR-0163](../decisions/0163-bounded-standby-refill-and-capacity-damping.md),
[ADR-0010](../decisions/0010-capacity-admission-transactions.md) and
[ADR-0159](../decisions/0159-remove-legacy-compatibility.md).

## Findings

1. **High, capacity: a slow pool read delayed every host report.**
   `Lilly.Host.Collector` read each pool inline under its pool lock before
   building the report, and took `sampled_at` before those reads. On 8-vCPU CI
   runners, `lilly.pool_section` recorded snapshot holds of p50 1496 ms, p90
   2005 ms and max 2654 ms (run 41126173301, audi-ubuntu-relocation-fleet, 29
   snapshots), against about 557 ms locally. Fresh reports arrived 2-3 s old,
   the host advanced about one sequence per 2 s, and one missed report on both
   hosts gave ages of 5.00 s and 5.16 s against the `< 5 s` steady-state check.
   That run had no control-plane loss (0 `lilly.control_unavailable`), so the
   drift alone fails enrollment. This was an unstated gap in ADR-0140: the
   decision gave sampling a `Cadence`, but pool reads stayed on the report path.
   Resolution: one background observer per ZFS pool, publishing to an
   `OverallsProtocol.View`. Collection reads it without waiting.
2. **Checked: freshness stays honest (ADR-0140, ADR-0163).** Each observation
   carries `observed_at`, the time its read began, so it never claims a later
   time than its data. Marshall records it as the pool's `observed_at` and
   refreshes the pool only while that time is within `pool_busy_grace_ms`
   (15 s) of the report. That is the bound ADR-0163 already sets for `busy`
   entries, and `HostLiveness.check_windows!/0` still keeps grace plus capacity
   inside host authority. Older observations never replace newer ones. A pool
   with no observation yet is reported `busy`, which grants no credit.
   `unavailable` still revokes at once.
3. **Checked: the lock is not held more.** Each observer runs on its own
   `Cadence`: one read in flight, and a tick during a read is dropped. The pool
   lock sees one snapshot per read plus a rest gap, as before. Reads no longer
   line up with report construction.
4. **Medium, protocol compatibility and rollout.** `observed_at` is an
   optional field. When it is absent it means `sampled_at`, so a newer
   Marshall accepts older hosts unchanged. An older Marshall rejects the
   unknown field. Hosts self-deploy trunk independently, with up to five
   minutes of random delay, so delivery is two-phase: Marshall and the
   protocol first, then Lilly's observer only after that revision has
   deployed. ADR-0159 forbids long-lived legacy paths, and none is added.
5. **Low, failure modes.** A crashed read emits
   `lilly.pool_observation_failed` (pool UUID only) and keeps the previous
   observation, which then ages out under the grace. If the observer view is
   not running, collection reports every pool `busy`. It never reads inline,
   and it emits `lilly.pool_observer_absent` once the view has been absent
   for longer than two observation cadences (2 s), then
   `lilly.pool_observer_present` on return. A shorter absence, such as the
   first samples of every boot before the observer starts, emits neither, so
   the warning is not routine noise. Capacity then ages out visibly rather
   than reverting quietly to the old report path.

## Affected decisions

- ADR-0140: update paragraph (pool observer, `observed_at`, two-phase rollout).
- ADR-0163: evidence note that the busy grace also bounds observed entries.

## Checks run

- Lilly: `mix precommit`, including the new
  `test/host/pool_observer_test.exs`: a 6 s read with one-second collection,
  busy entries, the read-start stamp, crashed-read retention and busy entries
  when no observer runs (phase 2).
- Marshall: `mix precommit`, including `pool-observed-at-ingest` in
  `host_reports_test.exs`.
- Protocol: `mix precommit`, including the `pool-observed-at-round-trip`
  property.
- `elixir scripts/check_adrs.exs`.

## Follow-up

- Native evidence: a fleet machine-test run on CI showing report ages below
  5 s with snapshot holds above 1 s. Until that run, the update is BEAM-test
  evidence only.

## Update (2026-10-31): lock share

Finding 3 was wrong for slow reads. The one-second tick began the next read
at most 1 s after the previous read finished, so 2.5-3.5 s CI reads held the
pool lock about 80% of the time. In run 41164441328 template reservations,
which waited only 1 s, lost to them four times on one host. The observer now
rests after each read for max(interval - d, min(d, 3 s)), so reads of up to
3 s hold the lock at most half the time. The worst-case observation age is
3d up to 3 s and 2d + 3 s beyond, within the 15 s busy grace while reads stay
under 6 s. Template sections now wait in the FIFO turn queue for up to 30 s.
Both changes are recorded as updates to ADR-0140 and ADR-0176.

Remaining gap: other pool sections still wait 1-2 s. In the same run's
account-lifecycle subtest, 58 transfer and clone sections went
`storage_busy` after 1 s (36) or 2 s (19) behind observation holds of up to
3.7 s. Halving the observer's lock share lowers that rate but cannot remove
it while a single read holds the lock longer than those waits. Shorter
observation holds, or waits that cover one hold, remain open.
