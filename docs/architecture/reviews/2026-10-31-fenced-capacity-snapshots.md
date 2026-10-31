# Fenced capacity snapshots (2026-10-31)

Scope: why a capacity observation held the pool mutation lock for 1.5-4.7 s,
and the change recorded as
[ADR-0274](../decisions/0274-fenced-capacity-snapshots.md). Checked against
[ADR-0152](../decisions/0152-lean-pool-locked-preparation.md),
[ADR-0163](../decisions/0163-bounded-standby-refill-and-capacity-damping.md),
[ADR-0176](../decisions/0176-host-concurrency-single-writers-and-effects.md)
and the [pool observer review](2026-10-30-pool-observer.md).

## Findings

1. **High, capacity and concurrency: the report path reused the
   preparation's locked snapshot.** `Pool.snapshot/1` ran the bind,
   `PoolSnapshot.read/3` (expectations, two whole-pool trees, owners and
   mounts) and every allocation, template and checkpoint audit inside one
   `:snapshot` section. ADR-0152 needs the lock for preparations, because
   their checks authorize native mutations. A capacity report authorizes
   nothing: Marshall admits from it, and the preparation re-reads under the
   lock and refuses exhausted accounting. Apart from the bind's directory
   claims, every step only reads. In run 41164441328 the holds were 1.7-4.7 s,
   and 58 transfer and clone sections that wait 1-2 s went `storage_busy` in
   account-lifecycle. The per-step split was not measured.
   Resolution: ADR-0274. Only the bind and a generation-token read stay
   under the lock. The rest is fenced by the token.
2. **Checked: single writer and gates (ADR-0152, ADR-0176).** Fenced
   snapshots fail `held?/1`. `ZFSDataset.allocations/2` and every
   preparation, readiness and claim path still require a locked snapshot, so
   the rejected "cache observations across lock acquisitions" alternative
   stays rejected for gates. Only capacity classification accepts a fenced
   snapshot, through `current?/1`.
3. **Checked: freshness (ADR-0163, ADR-0140).** A straddled read is
   `busy` (Marshall keeps the previous observation within the 15 s grace),
   never fresh and never `unavailable`. Two consecutive `busy` reads trigger
   one locked read, so sustained mutations cannot age capacity out. The
   observer's proportional rest and worst-case age are unchanged.
4. **Medium, coverage of the fence.** Only `Storage` sections advance the
   token. They are the only production acquirers of the pool lock, including
   probe BEAMs. Direct `Lock.acquire` holders (tests and probes) do not
   mutate, and a lock they hold makes the prologue `busy`. Native changes
   made without any pool section, such as root-disk copies under a placement
   lock, only move usage, and the existing two-tree check still reports
   `usage_moving`.
5. **Low, failure mode of the token.** A section that cannot replace a still
   readable token does not run, which keeps the fence safe. A write that
   fails after truncation, as on a full pool, counts as an advance, so
   deletes on a full pool keep working.

## Checks run

- Lilly `mix precommit` with `+S 32:32`, including
  `test/host/storage_observe_test.exs` (a 4 s fenced read beside a 1 s
  section, the Hegel straddle property and the advance gate) and the observer
  fallback test.
- `elixir scripts/check_adrs.exs`.

## Follow-up

- Native evidence: rerun account-lifecycle, account-lifecycle-ubuntu and
  the fleet suites, and confirm that `snapshot` holds drop to the bind's
  duration with no transfer or clone `storage_busy` behind them.
- Measure the bind under the lock, and bind only when the token has changed
  if it is significant.
