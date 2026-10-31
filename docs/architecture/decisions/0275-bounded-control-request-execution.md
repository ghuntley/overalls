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

- Accepted requests start in arrival order, at most `running` at once, and
  running plus queued stays within `in_flight`.
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
  - deadline expiry and task death cases.
- [`marshall/test/marshall/observability_test.exs`](../../../marshall/test/marshall/observability_test.exs) covers counting checkout
  timeouts and the max-wait gauge. Covenant obligation `marshall.compute.I5`
  is in [`marshall/contracts/marshall/compute.obligations.md`](../../../marshall/contracts/marshall/compute.obligations.md).
- Remaining: no NixOS fleet machine test has run with this change. The BEAM
  test uses an advisory lock in place of the real host row and a stub service
  in place of `ProvisionerRequests`. It does not prove fleet-level recovery.
  Acceptance is the next `account-lifecycle-ubuntu`, `audi-fleet` and
  relocation fleet runs, with no `lilly.control_request_refused reason=unknown`
  bursts and `database_queue_errors` at 0 on Lilly-facing nodes.

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
