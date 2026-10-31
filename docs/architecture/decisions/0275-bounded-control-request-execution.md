# ADR-0275: Bounded control request execution per Lilly socket

- ID: ADR-0275
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: Marshall, Lilly
- Supersedes: none
- Superseded by: none

## Context

[ADR-0142](0142-overallsprotocol-control-websocket.md) moved Lilly's control
exchanges onto one WebSocket per host. It advertises 64 requests in flight, and
`Marshall.Control.Socket` started a supervised task for every accepted request
at once. The retired HTTPS design ([ADR-0012](0012-provisioner-control-transport.md),
carried through [ADR-0126](0126-bounded-database-client-recovery.md)) ran one
request in flight per loop.

Every Lilly exchange authenticates through `Marshall.Compute.Credentials.with_host/2`.
That function locks the host row `FOR NO KEY UPDATE` and holds the lock for the
whole transaction. So a host's exchanges always run one after another in
PostgreSQL, however many Marshall starts. Lilly runs 14 control utilities (the
execution exchange, clone, and twelve relocation loops). Each one exchanges at
once on a `host_commands` hint. A hint therefore starts up to 14 transactions
on one Marshall node, and each holds a pooled connection while it waits for the
same row lock.

Observed in NixOS machine-test run 41126173301 (trunk 3b1ef8fe7), suites
`account-lifecycle-ubuntu` and `audi-fleet`, against a 10-connection pool per
Marshall node:

- Database errors appear only on the two nodes holding Lilly sockets, starting
  right after each socket bound: m1 853 and m3 888, against m2 23
  (`marshall.runtime_metrics`). PostgreSQL logged only 68 lock timeouts and
  9 statement timeouts, with no journal suppression. So almost all of these
  errors were client-side, consistent with DBConnection checkout (queue)
  timeouts. Those were invisible: `database_queue_errors` was hard-wired to 0.
- All 176 `lilly.control_exchange_failed` events pair one-to-one with
  `lilly.control_request_refused reason=unknown`. That is the socket's
  `unavailable` answer for a request task that raised. They hit all 14
  utilities in bursts of 4 to 9 per host.
- Audi's catalog and publication reads take the host row `FOR SHARE` with a
  1 s lock timeout. They timed out behind the queue
  (`while locking tuple ... in relation "compute_hosts"`), producing 99
  `audi.control_unavailable`. Agent loops and notification polls on the same
  nodes failed for lack of connections (111 `agent.loop_failed`).
- The BEAM run queue stayed at 0 to 5, and no Marshall unit restarted.
- The same signature, at smaller scale, appears in `audi-fleet` at 93847a6cf
  (run 41111309494: 99 refusals). The problem predates this run and gets worse
  with load.

The review is
[2026-10-30 control request concurrency](../reviews/2026-10-30-control-request-concurrency.md).

## Decision

Authorized by the operator's task of 2026-10-30, which asked for this fix in
place of a lock-timeout mitigation.

- **Running bound.** A control service may declare `running`, the number of its
  accepted requests that execute at once on one socket. It defaults to, and
  never exceeds, `in_flight`. Lilly's `running` comes from
  `Marshall.Control.Concurrency`, whose default is 2. The value can be set with
  `MARSHALL_CONTROL_LILLY_RUNNING` (1 to 64) and is validated at boot.
  Other services keep `running = in_flight`, which is today's behaviour.
- **FIFO queue in the socket process.** Accepted requests beyond `running` wait
  in arrival order in the socket process. They are not spawned. Each finishing
  task starts the next one. The busy check counts running plus queued against
  `in_flight` (64 for Lilly), so `busy` fires exactly where it did before.
- **Queue deadline.** A queued request that has waited `queue_deadline_ms`
  (default 4000, at most 5000, Lilly's request deadline) is answered
  `temporarily_unavailable` instead of being started, and
  `control.request_expired` is emitted. The client has (nearly) given up on
  it by then, so starting it would make a domain effect whose answer is lost.
  `temporarily_unavailable` is already a closed refusal that Lilly classifies.
- **Protocol unchanged.** The frames, welcome limits (`in_flight` is still
  advertised as 64), reply names and envelope version stay the same. Only the
  time at which a reply is sent changes. Replies may still arrive out of order
  among the requests running at once, as before. Clients match replies by id.
- **Pool pressure is reported.** DBConnection `queue_timeout` drops count as
  `database_queue_errors`. The interval's longest pool wait is reported as
  `database_queue_max_us` in `marshall.runtime_metrics` and in the
  log-to-metrics gauge list.
- **`Credentials.with_host/2` keeps its unbounded lock wait.** The bound
  removes the convoy at its source. A short lock timeout there would turn
  ordinary contention between hint-triggered exchanges into
  `temporarily_unavailable` retries. It would also do nothing for the pool, since
  connections would still be parked up to the timeout. Audi's own 1 s lock
  timeout already bounds the one reader that must not wait.

## Amendment 2026-10-31: report lane

Authorized by the operator's task of 2026-10-31 to fix the regression below
while keeping this record's pool protection.

**Observed.** Fleet run 41179645145, suite `clone-destination-loss`, failed
after this record landed. The suite passed in runs 41164441328 and
41126173301.

- Marshall accepted clone `b4e614e3` at 08:17:32.325 and failed it with
  `insufficient_capacity` at 08:17:32.958. `Marshall.Compute.ClonePlacement`
  answers that when no destination pool is `HostLiveness.capacity_fresh?`,
  that is, when its `reported_at` is older than `capacity_freshness_ms`
  (5000 in `marshall/config/config.exs`; the fleet tests do not override it).
- `reported_at` is Lilly's `sampled_at`, clamped to database time
  (`Marshall.Compute.HostReports`, `reports-sample-time`). It is not Marshall's
  receipt time, so every millisecond the report waits before its transaction
  commits is counted against freshness.
- The report travels only in the execution exchange (`lilly.exchange`).
  Lilly keeps one exchange in flight (`one-control-request-in-flight`) and
  sends the next sample only after the reply. The 13 utility loops share the
  same socket and wake together on a tick or `host_commands` hint.
- In this record's FIFO, the exchange waits behind every utility request
  queued before it, drained two at a time and serialized on the host row.
  That grows both the sample's age at commit and the gap to the next
  accepted sample. This is inferred from the code and the ages below:
  Marshall does not record per-request queue wait, and `control_duration_us`
  covers only running time.
  The enrollment cadence probe (`Public capacity cadence`) shows host ages of
  2.2 to 4.3 s on both hosts, against 1.1 to 2.5 s (one outlier at 3.75 s)
  in the four passing-era suites of run 41164441328. No queued request
  reached the 4 s deadline (`control.request_expired` never fired). Lilly's
  side was healthy: all 40 `lilly.pool_section` events in 08:16 to 08:17
  were `acquired`, and the last `pool.snapshot_withheld` was at 08:15:56.

**Decision.** A control service may name `priority_ops`. Each socket keeps
two queues: queued priority ops start before any other queued request, and
each queue is FIFO. Lilly names `lilly.sessions` and `lilly.exchange`, the
one request its runtime keeps in flight. The lane adds no running slot:
`running`, the deadline, the `in_flight` count over both queues, the frames
and the reply names are unchanged. So the per-socket pool bound is unchanged,
and the report waits for at most one running request's remainder instead of
a whole burst. Starvation is bounded because a conforming Lilly has at most
one report-lane request in flight. A client that sends more only delays its
own utilities, which then hit the existing deadline.

Alternatives rejected for the amendment:

- **A reserved third slot.** The exchange would still wait on the host row
  lock in PostgreSQL behind the running utilities. It would gain little, and
  it would raise the per-socket connection bound this record exists to keep.
- **Raising `capacity_freshness_ms` or easing the clone refusal.** That hides
  the queueing delay and admits work on older capacity numbers.
  [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md) sets that
  window for capacity safety, not to absorb transport delay.
- **Receipt-time `reported_at`.** That would make a delayed sample look
  current, which is what the freshness check exists to prevent.
- **Shorter report transactions.** The exchange also commits outcomes,
  acknowledgements and resumed recoveries under the same lock (ADR-0140).
  Splitting it changes the domain transaction, not the queueing.

## Alternatives

- **Lower `in_flight` to 2.** This would make Lilly's loops collide with `busy`
  (unknown to Lilly, so `http_error`) on every hint. That is more failures, not
  fewer.
- **Lock timeout in `with_host`.** This only shortens how long connections stay
  parked, and it changes successful exchanges into refusals. It was rejected
  as the fix, and is not kept as defence in depth, for the reason above.
- **Larger pool.** Production already moved from 10 to 20 after the
  2026-10-23 convoy ([ADR-0259](0259-deployment-revision-telemetry.md) review).
  The demand is 14 per host per hint, and it grows with every Lilly loop
  added, so pool size cannot be the bound.
- **Coalescing in Lilly.** This would also work, but needs a Lilly protocol
  change and a coordinated rollout. Marshall's bound protects every client
  version.

## Consequences

- A host's exchanges reach PostgreSQL at most two at a time per socket. Its
  host row still serializes them, so throughput is unchanged, but at most two
  pooled connections are parked per host instead of up to 14.
- Under a long-running exchange, queued utilities wait in Marshall instead of
  in PostgreSQL. If they wait past the deadline, Lilly receives
  `temporarily_unavailable`, or its own timeout fires first, and it retries
  with its existing backoff. This is the same outcome as before, without the
  pool damage to other work on that node.
- The bound is per socket. Several hosts on one Marshall node still each take
  up to `running` connections. Total Lilly demand per node is
  `hosts × running`, which the pool size and connection budget must cover.

## Invariants and verification

- Accepted requests start at most `running` at once. A queued priority op
  (Lilly's session open or execution exchange) starts before every other
  queued request, and each lane starts in arrival order. Running plus both
  queues stays within `in_flight`. (Before the 2026-10-31 amendment: one
  FIFO.)
- Every accepted request is answered exactly once: with its result, with
  `unavailable` if its task dies, or with `temporarily_unavailable` after the
  queue deadline, in which case it never starts.
- Pool checkout timeouts are counted as `database_queue_errors`.
- What would disprove the design: a single exchange that needs more than one
  pooled connection at a time, or a domain path that relies on two exchanges
  of the same host running concurrently. Neither exists today, because each
  exchange is one host-locked transaction.

## Implementation evidence

- [`marshall/lib/marshall/control/socket.ex`](../../../marshall/lib/marshall/control/socket.ex) (`dispatch/2`,
  `control-bounded-fifo-dispatch`), [`marshall/lib/marshall/control/service.ex`](../../../marshall/lib/marshall/control/service.ex)
  (`running` limit), [`marshall/lib/marshall/control/services/lilly.ex`](../../../marshall/lib/marshall/control/services/lilly.ex),
  [`marshall/lib/marshall/control/concurrency.ex`](../../../marshall/lib/marshall/control/concurrency.ex) (typed, validated
  configuration, checked at boot in [`marshall/lib/marshall/application.ex`](../../../marshall/lib/marshall/application.ex)),
  [`marshall/config/runtime.exs`](../../../marshall/config/runtime.exs).
- [`marshall/lib/marshall/observability.ex`](../../../marshall/lib/marshall/observability.ex) (`database-pool-pressure-visible`)
  and [`marshall/lib/marshall/events.ex`](../../../marshall/lib/marshall/events.ex) (`control.request_expired`,
  `database_queue_max_us`). [`nix/domains/system/logging/default.nix`](../../../nix/domains/system/logging/default.nix) adds the
  gauge.
- [`marshall/test/marshall/control/socket_concurrency_test.exs`](../../../marshall/test/marshall/control/socket_concurrency_test.exs) contains:
  - a 14-exchange burst against a 3-connection pool, with an advisory
    transaction lock standing in for the host row. All exchanges complete,
    with no checkout timeout and a peak of at most 2 running. The same burst
    with the bound lifted does time out checkouts;
  - a Hegel property over bursts of 1 to 70 and random completion orders;
  - deadline expiry and task death cases;
  - report lane (2026-10-31 amendment, `control-report-lane-before-burst`):
    an exchange that arrives behind 13 queued utilities starts at the next
    free slot, ahead of them, with no extra running slot, and both lanes
    count toward `busy`;
  - a model-based Hegel property (`control-report-lane-property`) over random
    interleavings of utility and report-lane arrivals and releases. The
    socket starts exactly the request the two-lane model predicts, never
    more than `running`, and answers each request once;
  - `Service.priority_ops/1` is `lilly.sessions` and `lilly.exchange` for
    Lilly and empty for every other service.
- [`marshall/test/marshall/observability_test.exs`](../../../marshall/test/marshall/observability_test.exs) covers counting checkout
  timeouts and the max-wait gauge. Covenant obligation `marshall.compute.I5`
  is in [`marshall/contracts/marshall/compute.obligations.md`](../../../marshall/contracts/marshall/compute.obligations.md).
- The report lane is in `Marshall.Control.Service.priority_ops/1`,
  `Marshall.Control.Services.Lilly.priority_ops/0`
  (`control-lilly-report-lane`) and the socket's `next/1`.
- Remaining: no NixOS fleet machine test has run with this change. The BEAM
  test uses an advisory lock in place of the real host row and a stub service
  in place of `ProvisionerRequests`. It does not prove fleet-level recovery.
  Acceptance is the next `account-lifecycle-ubuntu`, `audi-fleet`,
  `clone-destination-loss` and relocation fleet runs. They should show
  enrollment cadence ages back near the passing-era 1 to 2.5 s, no
  `lilly.control_request_refused reason=unknown` bursts, and
  `database_queue_errors` at 0 on Lilly-facing nodes.

## Open questions

- Should Lilly coalesce hint-triggered exchanges so it sends fewer than 14
  per hint? This is not required for correctness, and Lilly belongs to another
  workstream.
- Is a `running` of 2 right for production pool sizes? It can be tuned with
  `MARSHALL_CONTROL_LILLY_RUNNING`, and runtime metrics now show the pressure.

## Related decisions

- [ADR-0142](0142-overallsprotocol-control-websocket.md): this record replaces
  its "run each request in a supervised task" concurrency for Lilly sockets.
  The rest of ADR-0142 stands, and its amendment links back here.
- [ADR-0012](0012-provisioner-control-transport.md) and
  [ADR-0126](0126-bounded-database-client-recovery.md): the earlier
  one-request-in-flight design.
- [ADR-0259](0259-deployment-revision-telemetry.md) and the
  [2026-10-23 host-row lock convoy review](../reviews/2026-10-23-host-row-lock-convoy.md):
  the earlier production convoy on the same row.
