# 2026-10-30: Control request concurrency and database pool exhaustion

## Scope

This review covers the Marshall errors returned to Lilly and Audi in NixOS
machine-test run 41126173301 (trunk 3b1ef8fe7), and the fix recorded in
[ADR-0275](../decisions/0275-bounded-control-request-execution.md). The
dimensions reviewed are:

- protocol: the control WebSocket and ADR-0142;
- coordination: host row locks;
- capacity: the database pool;
- observability.

Lilly code, capacity reporting and the trace schema generator belong to other
workstreams and were not changed.

## Observations

The sources are the uploaded `machine-test-log-*` artifacts for
`account-lifecycle-ubuntu` and `audi-fleet` from run 41126173301, compared with
`audi-fleet`, `account-lifecycle` and `account-lifecycle-ubuntu` from run
41111309494 (93847a6cf).

- **What Marshall returned.**
  - Lilly and Audi use long-lived control WebSockets, so HAProxy shows only
    one 101 per socket and no per-request status codes.
  - Inside the socket, all 176 `lilly.control_exchange_failed` events
    (`reason=http_error`) pair one-to-one with
    `lilly.control_request_refused reason=unknown`. `unknown` is any name
    outside Lilly's refusal list. No `provisioner.transaction_failed` was
    emitted, which rules out `temporarily_unavailable`. The remaining name is
    the socket's `unavailable`, sent when a request task raises
    (`Marshall.Control.Socket.request/4`).
- **Where the errors were.**
  - Lilly bound to m1 at 21:03:18 and to m3 at 21:04:16.
  - `marshall.runtime_metrics` `database_errors` rose on those two nodes right
    after binding: m1 853 and m3 888 in total, against 23 on m2.
  - `agent.loop_failed` (111) and `agent.notification_poll_failed` (35) fired
    only on m1 and m3.
- **Not PostgreSQL errors.**
  - The database VM logged 68 `lock timeout`, 9 `statement timeout` and 45
    client resets in total, with no journald suppression.
  - The client resets match the baseline run (50), so they are not part of
    this failure.
  - Almost all of Marshall's roughly 1,760 errors were therefore client-side.
    The candidate consistent with the evidence is DBConnection's queue drop
    (`ConnectionError` reason `queue_timeout`). Marshall did not report these:
    `database_queue` used the `:none` error classifier.
- **The lock holder.**
  - Every Lilly exchange locks its host row `FOR NO KEY UPDATE` for the whole
    transaction, inside `Credentials.with_host/2`.
  - All 14 Lilly utilities exchange at once on a `host_commands` hint, and the
    socket allowed 64 running.
  - The lock timeouts all come from Audi's ingress catalog and publication,
    which set a 1 s `lock_timeout` and take the host row `FOR SHARE`. The
    PostgreSQL log shows `while locking tuple (0,3) in relation "compute_hosts"`.
- **Not CPU starvation.** The BEAM run queue stayed at 0 to 5. Query time
  averaged 50 to 240 ms, which includes time waiting on the row lock.
- **Not a crash loop.** There were no Marshall restarts. The 136
  `otp.process_crash` events in acme-http01 on the same trunk all happened
  before each node's migration finished, and are unrelated.
- **Not new.**
  - `audi-fleet` at 93847a6cf already shows 99 refusals and 44
    `agent.loop_failed`, with about 380 database errors on each Lilly-facing node.
  - The account-lifecycle runs at that commit failed earlier, on an image
    copy timeout, before reaching the burst.
  - No commit in 93847a6cf..3b1ef8fe7 touches Marshall's `lib/`.

## Findings

1. **High: unbounded per-socket execution exhausts the pool.**
   - Evidence: `Marshall.Control.Socket` spawned a task per accepted request.
     All of a host's exchanges serialize on its row, so only one does useful
     work, while the rest park pooled connections. With 14 utilities and a
     10-connection pool, every hint can drain the pool. The failure spreads
     to every other query on the node and to Audi through the row lock.
   - Decision: ADR-0142's concurrency rule needed replacing, not an
     implementation fix. ADR-0275 bounds Lilly sockets to `running`
     (default 2) with a FIFO queue and a deadline.
2. **Medium: pool exhaustion was not observable.**
   - Evidence: `database_queue_errors` was always 0, and only an average queue
     time was reported.
   - Fix: count `queue_timeout` drops and report the interval's longest wait
     (`database_queue_max_us`).
3. **Low: Lilly classifies `unavailable` and `busy` as `unknown`.**
   - Consequence: diagnostics are less specific. Behaviour is still correct,
     because both are retried as `http_error`.
   - Recommendation: left to the Lilly workstream.

## Decisions on alternatives

- **Lock timeout in `with_host`.** Not added, even as defence in depth. With
  the bound in place it would only turn legitimate waits between two running
  exchanges into refusals, and it never protected the pool, because
  connections stay parked until the timeout.
- **Lower advertised `in_flight`.** Rejected. It moves the failure into `busy`
  refusals.
- **Pool size.** Not changed here. Production already runs 20. The fleet
  fixture stays at 10, so it keeps exercising the bound.

## Checks run

These ran on panterloons against a private PostgreSQL instance
(`max_connections` 1000), inside `devenv shell`.

- **Every non-test `mix precommit` step passed.** Each was run separately with
  `MIX_ENV=test`: toolchain, architecture, contracts, logging,
  `compile --warnings-as-errors`, `deps.unlock --unused`, format,
  static Covenant, terminal, workspace, monospace, the localization checks,
  gettext and `dialyzer --force-check`.
- **The full test phase did not complete on this host.** It was run as
  `mix test --include distributed --warnings-as-errors` with 32 schedulers,
  so a pool of 64.
  - It hung after about 2 hours, with 18 failures recorded by then.
  - `SharingMatrixDistributedTest` timed out after 120 s inside Ash
    expression evaluation. That test commits rows outside the sandbox, and
    after the timeout it left them behind.
  - The other 17 failures assert empty or exact committed row sets and found
    the leftover rows: a stray host, reservation, VMs, operations, or an
    `UPDATE` touching 104 rows. They are in `ImageAdmissionTest` (4),
    `SSHTransportTest` (5), `ServiceLevelsTest` (5), `GitIdentityTest` (1),
    `CommittedFixtureCleanupTest` (1) and the second sharing test (1).
  - Two earlier attempts (pool 384 against 300 connections, then 8
    schedulers) were stopped. One was hitting PostgreSQL's connection limit
    and the other had stalled.
- **Re-run on a recreated database.** All six failing modules, the control,
  contract and observability tests and the control API tests ran together:
  135 tests passed, distributed included. `covenant.check --no-run` reports
  that the Contract holds.
- **Focused tests.** `socket_concurrency_test.exs` covers:
  - the 14-exchange burst against a 3-connection pool, with an unbounded
    control that does time out checkouts;
  - a 100-case Hegel property;
  - deadline expiry and task death.
  These passed under several seeds. An order-dependent failure, a service
  module not yet loaded when its limits were read, was fixed with
  `Code.ensure_loaded?/1` in `Marshall.Control.Service.limits/1`.
- `elixir scripts/check_adrs.exs` passed.
- `mix schema.check` in `elixir/diagnostics` passed after regenerating the
  vocabulary.

## Follow-up

- Acceptance needs fleet machine runs (`account-lifecycle-ubuntu`,
  `audi-fleet`, the relocation fleets) with no `reason=unknown` bursts and
  `database_queue_errors` at 0 on Lilly-facing nodes. None has run yet.
- Lilly-side coalescing of hint-triggered exchanges and specific
  classification of `unavailable` and `busy` (Lilly workstream).
- Size the production connection budget for `hosts × running` per node.
