# ADR-0140: Event-driven liveness and authority with single-writer views

- ID: ADR-0140
- Date: 2026-10-02
- Status: accepted
- Implementation: partial
- Components: Protocol, Lilly, Marshall, Audi, Porsche, Brady, Ziggy, Galileo
- Supersedes: none
- Superseded by: none

## Context

Native fleet runs on 2026-10-02 refused healthy VMs whenever the shared host was
loaded:

- Brady attribution logged "unresolved".
- Terminal creation was refused with `account_refused`.
- Terminal journeys and enrollment freshness failed nondeterministically.

A survey of every component on `origin/main` found that the cause was one
pattern repeated across services:

- **Authority from polling plus a time window.**
  - Lilly's VM actor re-runs the whole reconcile every second, drops ticks while
    one is in flight, and accepts proof only when it is under 2000 ms old.
  - Marshall's `capacity_freshness_ms` (5000 ms) is applied twice: once at host
    report ingest, then again by more than 20 consumers. Terminal viewers and
    DNS records disappear whenever a report is late.
  - Audi renews every stream lease about once a second against a 5000 ms cap,
    using four near-identical mechanisms. The private guard polls Lilly every
    500 ms and kills the request after 2000 ms.
  - Brady drops cache custody, and wipes the cache, when its pressure file is
    older than 3000 ms.

  Under load these windows fail closed for healthy work. After a real loss they
  fail open for the length of the window.
- **Single processes that both read and write, behind short call timeouts.**
  This covers the Lilly runtime and actor, Audi `TLS.Store` and the DNS
  directory, the Marshall terminal relay, the Brady store, and the locked
  Porsche status polls.
- **Implicit or duplicated state machines and plumbing.** Terminal opening is
  implemented three times, and the stream lease four times. There are three
  copies of the control client, the peer-credential UDS client and the conflict
  reason table.

The measured cause of the Lilly failures: observation gaps reached 4.3 s, and
roster boot verification lost a one-second placement-lock race to the actor's
own observation.

## Decision

Liveness and authority are modelled as explicit state machines. Each is owned
by a single writer, published to a versioned read model that readers consult
without locks, and revoked by events. Time-based leases remain only as a
backstop against a lost event stream.

- **Machines.** Volatile machines use `OverallsProtocol.Machine`:
  - a closed `initial`/`edges` table, checked at compile time;
  - `target/2` rejects every undeclared pair;
  - effects are returned as data.

  Durable lifecycles stay on Ash. A volatile authority machine starts unproven
  after any restart, so it fails closed.
- **Scheduling.** Periodic work uses `OverallsProtocol.Cadence`: one run in
  flight, no lost ticks, repeated ticks collapsed into one.

  *Correction (2026-10-03).* "No lost ticks" applies to explicit requests,
  not periodic ticks. A periodic tick during a run is dropped, so periodic
  runs always rest between runs. An event `:request` (a new or superseding
  command) during a run still starts exactly one follow-up on completion.
  Native `ssh-bootstrap-fleet` evidence showed why. Back-to-back host samples
  under load held the pool lock almost continuously: each sample takes a pool
  snapshot under it. A clone source relaunch tried the lock without waiting,
  never acquired it, and never relaunched; main relaunched it in about 9 s.
  The VM actors had the same shape. The runtime casts `:reconcile` to every
  actor each time it processes its command set, so only a first activation
  or a changed durable command is a request; an unchanged cast is a tick. An
  instrumented native run showed the clone source retrying `storage_busy`
  back to back for minutes until this was fixed
  ([actor.ex](../../../lilly/lib/lilly/vm/actor.ex)).
- **Read models.** Read models use `OverallsProtocol.View`: protected ETS, one
  claiming writer per key, rows removed when that writer exits, strictly
  increasing versions, and lock-free `fetch`/`lookup`.
- **Shared foundations.** The shared protocol library hosts these pure and
  in-memory primitives. They use no Ash, database, host I/O or credentials,
  which keeps the shared boundary that protocol already has.
- **Rules for every machine.**
  - Slowness is never evidence of loss: an inconclusive observation leaves
    state unchanged.
  - Revocation events take effect at once.
  - A restart means unproven.
  - Backstop expiries are long and exist only to catch lost events.
- **Phases.** Delivery is phased, and each phase is verified natively before
  it is pushed:
  0. Foundations.
  1. Lilly VM liveness view and cadence.
  2. Kernel watcher revocation.
  3. Audi private binding view.
  4. Marshall host liveness view replacing `Ledger.fresh?`.
  5. Audi gateway views, the fleet-certificate machine and the unified stream
     lease.
  6. Marshall terminal opening machine.
  7. Porsche, Brady, Ziggy and Galileo machines plus the shared clients.
  8. Retiring the time windows.

  Each phase records its own supersession or evidence notes on the affected
  decisions: ADR-0010, the ADR-0052 lineage, ADR-0069, ADR-0125 and the Audi
  lease decisions.

Authorization: the user approved the fleet-wide plan on 2026-10-02 and asked for
state machines, removal of duplication, and property-based or NixOS tests where
appropriate.

## Alternatives

- **Tune the existing loops.** Add catch-up ticks and lengthen the lock retries
  and windows. This was rejected: it keeps the fail-open window after a real
  loss, still breaks at higher load, and leaves the pattern in place in Audi,
  Marshall and Brady.
- **Widen the windows.** This was rejected because it extends the fail-open
  period.
- **Put the primitives in each application.** This was rejected because it
  repeats the duplication the decision removes.
- **Create a separate shared library.** This was rejected for now: every
  component already depends on protocol, and the primitives respect its
  boundary.

## Consequences

**Benefits:**
- Healthy work survives slow hosts.
- A real loss revokes authority within milliseconds instead of after a window.
- Readers stop contending with writers.
- One tested mechanism replaces several hand-written ones.

**Costs:**
- A multi-phase migration with new native test variants.
- A kernel watcher helper in Lilly.
- Explicit revocation streams between components.
- A dependency: a lost event stream must be caught by a backstop, so each tier
  keeps one.

## Invariants and verification

- **Machine tables are closed.** A table with duplicate, unreachable or
  undeclared-initial edges fails compilation. Every undeclared
  (state, event) pair is refused.
- **Cadence never has more than one run in flight.** A request during a run
  starts exactly one follow-up run on completion, and repeated requests never
  build a backlog. A periodic tick during a run never starts or schedules one,
  so periodic work never runs back to back (corrected 2026-10-03, see
  Scheduling).
- **Views are exact.**
  - Only the claiming writer writes a key.
  - Rows vanish when that writer exits.
  - A restarted view is empty.
  - Versions strictly increase.
  - Lookups return only rows whose current terms match.
  - Re-publishing a row never makes it transiently invisible.
- **Per-tier invariants** are verified by model-based properties and NixOS
  machine tests in each phase:
  - never live after revocation or across a restart;
  - an inconclusive observation never revokes;
  - consumers refuse without an exact current row.

## Implementation evidence

Phase 0 (foundations) is implemented:

- [machine.ex](../../../protocol/lib/overalls_protocol/machine.ex): closed tables checked at compile
  time, with exhaustive `cases/1`.
- [cadence.ex](../../../protocol/lib/overalls_protocol/cadence.ex): the scheduling machine.
- [view.ex](../../../protocol/lib/overalls_protocol/view.ex): the single-writer read model.

Verification:

- [machine_test.exs](../../../protocol/test/machine_test.exs): exhaustive tables, plus a property that
  `check/2` accepts exactly the well-formed generated tables, plus compile-time
  rejection.
- [cadence_test.exs](../../../protocol/test/cadence_test.exs): a model-based property over every
  tick/request/done interleaving.
- [view_test.exs](../../../protocol/test/view_test.exs): a model-based property with real writer
  processes that claim, put, delete, release and crash, plus restart-empty.
- Deliberate mutants are caught: losing the pending request, or starting a
  follow-up for a periodic tick, fails the cadence property, and allowing a second claimant fails the view property.

Phase 1 (Lilly VM tier) is implemented:
- [execution.ex](../../../lilly/lib/lilly/execution.ex) is the single read API.
  It joins a runtime-written connected row, a runtime-written durable intent
  and an actor-written live row with a deadline.
- [liveness.ex](../../../lilly/lib/lilly/execution/liveness.ex) is the VM
  liveness machine.
- The [VM actor](../../../lilly/lib/lilly/vm/actor.ex) publishes live rows
  from machine effects and starts observations through `Cadence`.
- [Ingress](../../../lilly/lib/lilly/ingress/guardian.ex),
  [attribution](../../../lilly/lib/lilly/network/attribution.ex) and
  [private services](../../../lilly/lib/lilly/control/runtime.ex) now read the
  view.

Removed:
- the actor's private, ingress and egress snapshot calls;
- `observed_command/1`;
- the runtime ingress and egress route calls;
- `Lilly.Network.FlowIndex`.

Verification:
- [execution_test.exs](../../../lilly/test/lilly/execution_test.exs): an
  exhaustive liveness table, the row-iff-live property, a model-based
  read-equals-join property, ownership, writer-exit revocation, and
  address/flow routing (ambiguity, replacement, stop).
- Migrated security assertions in
  [actor_test.exs](../../../lilly/test/vm/actor_test.exs),
  [ingress_execution_test.exs](../../../lilly/test/ingress_execution_test.exs)
  and [roster_bootstrap_test.exs](../../../lilly/test/roster_bootstrap_test.exs).
- A cadence test showing that a mid-observation request starts the next
  observation on completion.
- Mutants removing the identical-intent or deadline check fail the property.

Phase 1 deliberately keeps the two-second deadline. Native fleet
re-verification is pending.

Phase 2 (kernel watcher revocation) is implemented. Since the backstop is
still two seconds, the system is strictly no weaker than phase 1:
- [lilly-vm-watch](../../../lilly/native/vm-watch/src/lib.rs) binds the
  verified VMM PID with a pidfd and then re-checks membership of the unit
  cgroup. It watches `cgroup.events` and reports `armed`, `exited` or `error`.
- [watch.ex](../../../lilly/lib/lilly/execution/watch.ex) is the watcher
  machine. The [VM actor](../../../lilly/lib/lilly/vm/actor.ex) owns one
  watcher per verified VMM and revokes its live row the moment the watcher
  reports exit, an error or a crash.
- [Executor.watch_target/2](../../../lilly/lib/lilly/vm/executor.ex) reuses
  the full confinement check from
  [Observation.vmm/3](../../../lilly/lib/lilly/vm/observation.ex).

Verification:
- Hegel properties for the argument and parser grammars. One of them found and
  closed `/sys/fs/cgroup/.` being accepted as a cgroup.
- The [vm-watch NixOS test](../../../nix/verification/tests/machines/vm-watch/probe.py):
  SIGKILL is reported within 50 ms (8.1 ms measured), and the test also covers
  an emptied unit cgroup, refusal of a foreign PID, detach on EOF and the
  grammar.
- [actor_watch_test.exs](../../../lilly/test/vm/actor_watch_test.exs): an
  exhaustive watch table, a property that terminal reports always revoke,
  immediate revocation on exit, fail-closed on a crashed watcher, and
  backstop-only operation without the helper.
- A [brady-fleet subtest](../../../nix/verification/tests/machines/fleet/scenarios/brady.py)
  that kills a real guest's Firecracker and requires revocation by the watcher
  in under a second, followed by refused attribution.

Phase 3 (Lilly VM tier time rules) is implemented:
- The [liveness machine](../../../lilly/lib/lilly/execution/liveness.ex) adds
  `:booting` and two row kinds. The boot row is held in booting and live and
  grants roster authority only; the live row is held in live only.
- Proof backed by an armed watcher carries a 30-second backstop instead of two
  seconds. Death, negative evidence, supersession or disconnect still revoke
  immediately; the backstop only bounds inconclusive observations.
- Roster lookups read the boot row
  ([Runtime.roster_binding/2](../../../lilly/lib/lilly/control/runtime.ex)).
- `Driver.boot_proof/4` gathers the physical evidence inside the actor's own
  observation, and from an independent probe while a long reconcile is in
  flight. Lock contention there is inconclusive.
  [Executor.boot_proof/2](../../../lilly/lib/lilly/vm/executor.ex) takes the
  placement lock only when the VM unit is running. A stopped unit is definite
  evidence that nothing booted. Probing a stopped unit under the lock raced
  the relaunch's non-waiting acquisition and starved a clone source restart
  in `ssh-bootstrap-fleet`.
- The host sampler runs on `Cadence`, and capacity proofs are retained while
  the view still proves the placement.

Removed: `verify_boot` (Driver, Executor and its callback),
`Actor.roster_snapshot`, the Runtime `{:private_binding}` route and the
private server's runtime backend.

Tests:
- the two-row liveness property;
- [roster_bootstrap_test.exs](../../../lilly/test/roster_bootstrap_test.exs),
  rewritten;
- watched and unwatched backstop tests in
  [actor_watch_test.exs](../../../lilly/test/vm/actor_watch_test.exs).

Phase 4 (Audi private binding) is implemented:
- `OverallsProtocol.View.subscribe/2` notifies subscribers of every change to
  a subscribed key, including removals when a writer exits.
- `OverallsProtocol.PrivateServices` defines the only private lookup wire
  (version 3): a closed request, a grant validated per purpose, and a fixed
  revocation frame.
- [Lilly's private server](../../../lilly/lib/lilly/private/server.ex) grants
  from the view, subscribes to the binding's rows, re-resolves on each change
  and at the proof deadline, and revokes when the binding ends.
- [Audi's connector](../../../audi/lib/audi/private/connector.ex) subscribes
  once per request. The [guard](../../../audi/lib/audi/private/guard.ex) fences
  the request on revocation or close.
- Removed: the front's double lookup, the guard's 500 ms polling and 2 s kill
  timer, and the v1 and v2 private wires.

Tests:
- the subscription-notification property (a mutant that drops the delete
  notification fails);
- wire properties;
- [subscription_test.exs](../../../lilly/test/private/subscription_test.exs):
  grant, revocation on withdraw, supersession, disconnect and deadline, no
  revocation on identical renewal, roster versus services rows, and refusal of
  malformed requests;
- [private_guard_test.exs](../../../audi/test/private_guard_test.exs).

Phase 5 (Marshall host tier) is implemented:
- [HostLiveness](../../../marshall/lib/marshall/compute/host_liveness.ex) is
  the single classification: disconnected, live, late or lost.
- 25 capacity and display call sites use `capacity_fresh?/2`, which keeps the
  five-second rule.
- Twelve authority call sites (terminal, ingress, DNS publication, inference,
  Galileo, SSH access) use `authority?/3` with the 30-second
  `host_authority_ms` backstop.
- `Ledger.fresh?` is removed.
- [HostReports](../../../marshall/lib/marshall/compute/host_reports.ex) accepts
  samples within the authority window instead of rolling back the exchange.

Tests: a model property for the classification (capacity implies authority,
and authority never returns with age), a late-but-accepted ingest test, and a
viewer that survives a late report and closes once the host is lost.

Remaining:
- phases 6–8: the Audi gateway, the Marshall terminal and the edge services;
- a `slow-observation-fleet` NixOS variant that adds a three-second delay to
  every reconcile.


*Phase 6, Audi gateway (2026-10-03), implemented:*
- The TLS store and DNS directory are single writers that publish to views,
  so SNI and DNS reads are lock-free
  ([store.ex](../../../audi/lib/audi/tls/store.ex),
  [directory.ex](../../../audi/lib/audi/dns/directory.ex)).
- Readiness is proven once per certificate generation.
- A [fleet certificate machine](../../../audi/lib/audi/tls/fleet_certificate.ex)
  keeps a proven generation serving through failed refreshes.
- Inconclusive stream renewals retry within the unchanged lease
  ([renewal.ex](../../../audi/lib/audi/authority/renewal.ex)).
- Supervisor progress reports are dropped, and the unused private Finch pool
  is removed.

Remaining: Marshall-pushed stream revocation, which would allow a longer
backstop than the five-second lease.

*Phase 7, Marshall terminal (2026-10-03), implemented:*
- Automatic opening runs in a supervised task off the LiveView process, at
  most one per view.
- A guest-account refusal (`:rejected`) retries within a budget of five
  attempts per execution before becoming definitive.
- The fleet browser test's notice table matches the current notices.

Remaining:
- Viewer authority is still a one-second poll (against the 30-second host
  authority window). Event-pushed invalidation and a Relay read view are not
  implemented.
- The durable opening and the LiveView phases are not yet one machine.

*Phase 8, edge services (2026-10-03), implemented:*
- **Brady:** evicts only below the 15 percent headroom floor. A late
  observation, or the resume hysteresis band, keeps the cache read-only
  instead of emptying it ([store.ex](../../../brady/lib/brady/cache/store.ex)).
- **Ziggy:** a [recoverable version fence](../../../ziggy/lib/ziggy/version_fence.ex)
  backs off and probes after an HTTP 426, instead of stopping until restart.
- **Porsche reads:** status polls and listings do not queue on the account's
  command advisory lock ([authority.ex](../../../marshall/lib/marshall/ssh/authority.ex)).
- **Porsche waits:** a wait tolerates transient poll failures until its
  deadline ([runner.ex](../../../porsche/lib/porsche/runner.ex)).

Remaining:
- A request-status view.
- A Porsche session machine.
- The shared `OverallsProtocol.Control.Client` and `PeerUnix` deduplication.
- Retiring the remaining time rules (phase 9).

*Resize restart (2026-10-03).* A resize whose disk change is confirmed while
host or pool capacity telemetry is stale no longer fails with
`insufficient_capacity`. [RestartCapacity.check/3](../../../marshall/lib/marshall/compute/restart_capacity.ex)
separates `:stale` from a measured shortfall. The request keeps its holds, and
[Resize.resume_awaiting_locked!/1](../../../marshall/lib/marshall/compute/resize.ex)
re-decides on the host's next accepted report. Lilly retries resize-step lock
contention and inconclusive unit observations instead of reporting a definite
`unknown`. Native `ssh-roster-matrix-fleet` showed both:
`insufficient_capacity` at resize completion, then `identity_mismatch` from a
contended re-reconcile, which fenced the VM.
Automatic crash recovery follows the same rule (2026-10-03). Stale telemetry
keeps the compute hold, and
[Outcomes.resume_recoveries_locked!/1](../../../marshall/lib/marshall/compute/outcomes.ex)
restarts the VM on the host's next accepted report, within the unchanged
three-per-ten-minutes budget.

*Viewer authority under database loss (2026-10-03).* Native `terminal-fleet`
lost a connected terminal after a Marshall machine crash. The lost machine's
abandoned transaction held the VM row until reclaimed; the surviving nodes'
pools queued behind it, and the viewer's one-second login recheck failed and
closed the viewer as `authority_login`. A recheck that fails or crashes while
a `SELECT 1` probe also fails is now inconclusive: the viewer keeps its last
confirmed authority for at most 30 seconds from the first inconclusive
recheck, then closes as `authority_unconfirmed`
([ViewerAuthority](../../../marshall/lib/marshall/terminal/viewer_authority.ex),
[viewer.ex](../../../marshall/lib/marshall/terminal/viewer.ex)). A refusal
while the database answers still closes at once. Revocation latency is
therefore bounded by 30 seconds only while this node cannot reach the database.
The same native run showed the browser leaving the terminal: the LiveView
join crashed on the blocked database, the reload's static mount read the
failed VM lookup as "Machine not found" and redirected to the machine list,
and an earlier run ended on a plain 500 page. Now the terminal mount raises
instead of redirecting when [Marshall.Repo.answers?/0](../../../marshall/lib/marshall/repo.ex)
fails, and a 500 page rendered while the database does not answer refreshes
itself every three seconds
([error_html.ex](../../../marshall/lib/marshall_web/controllers/error_html.ex)).
The next run reached haproxy's own 503: readiness probed with queueing
disabled, so both surviving nodes' saturated pools failed `/health/ready`
together and haproxy had no backend left. An unanswered readiness probe is now
inconclusive and keeps the last ready verdict for at most 30 seconds; definite
answers (read-only, missing migration, database error) still fail at once
([Operations.Health](../../../marshall/lib/marshall/operations/health.ex)).
With readiness held, the browser recovered its page once the database
returned, but terminal tickets were refused for about 30 more seconds. During
the outage Marshall had rejected the hosts' reports, and Lilly's control
backoff (1, 2, 4, 8, then 16 seconds) delayed the first accepted report, so a
healthy host's report gap exceeded the 30-second authority window. The backoff
is now capped at four seconds
([Runtime.retry_delay/1](../../../lilly/lib/lilly/control/runtime.ex)), so
host authority returns within a few seconds of Marshall recovering.

*Host authority backstop raised to 60 seconds (2026-10-03).* The next run
still refused terminal tickets for about 43 seconds after the crash. Marshall
cannot write any host's report while its database is blocked, so the 30-second
window measured Marshall's outage, not the host. `host_authority_ms` is now
60 seconds ([config.exs](../../../marshall/config/config.exs)). This is the
backstop for a silently lost host only: a reset or replaced connection session
still ends authority at once, and capacity decisions keep the five-second
rule. (Narrowed on 2026-10-17 by
[ADR-0192](0192-staged-detached-ingress.md) decision 6: renewal of an admitted
editor, web or guest SSH stream is inconclusive while the host reconnects, within its
unchanged lease; admission is unchanged.) Earlier phase notes record the 30-second value as it was.

*Live pages wait instead of reloading (2026-10-03).* With host authority
held, the browser still lost its terminal: the reconnecting LiveView's join
failed on the blocked database, and this LiveView client reloads the page on
any failed main-view join, so 50 terminal panes were rebuilt on a loaded
machine. A connected mount now waits up to 40 seconds for the database
([DatabaseWait](../../../marshall/lib/marshall_web/database_wait.ex)), the
client join timeout is 60 seconds, and a login recheck that fails only
because the database does not answer halts the triggering event without
redirecting to sign-in
([LiveUserAuth](../../../marshall/lib/marshall_web/live_user_auth.ex)).
The following run refused the viewer as `authority_login` while `SELECT 1`
answered: the login lookup itself had failed on a busy pool, and
`Login.present/2` reported that as a revoked login. [Login.check/2 and
token_check/2](../../../marshall/lib/marshall/accounts/login.ex) now return
`:refused` only for a definite answer and `:unavailable` for a failed lookup,
and a terminal session lookup error is `:unavailable` rather than
`:unknown_session`; the viewer and live-page checks treat `:unavailable` as
inconclusive.
Bounded browser socket timings then showed the last cause: Marshall sent the
attached frame within about 200 ms, but the CPU-starved test browser handled
it 11 to 17 seconds later, and the client's ten-second attach timer closed
each working socket, restarting scrollback replay. The timer now bounds only
the WebSocket handshake ([terminals.js](../../../marshall/assets/js/terminals.js));
the server's five-second attach limit governs the rest.
The next run showed the socket closing about 80 ms after its attached frame
with no server refusal: the workspace hook closed every terminal socket on a
LiveView disconnect, and the loaded page's LiveView connection kept
reconnecting. Terminal sockets now outlive LiveView disconnects; only ticket
requests and creation retries pause. The fleet browser's graphics-replay stage
drops the pane socket itself to keep exercising replay.

*Remaining native gap (2026-10-03).* With these changes the native
`terminal-fleet` Marshall-loss stage now reaches a live terminal after the
crash and the guest's command marker returns over the reattached socket, but
the stage still fails: on the loaded verification host the nested Chromium
pages that replay the session's sixel-heavy scrollback cannot answer DOM
queries within the 120-second rendering bound. This stage also failed on
`main` before this work. The product path is evidenced by the recorded run's
transport counters; a passing native run of the full stage is not yet
recorded.

*Hints (2026-10-05).* [ADR-0141](0141-control-plane-hints-and-resync.md)
delivers commit-gated, cross-node control hints. Terminal viewers now recheck
immediately on a revocation hint, with the one-second poll kept as the
backstop. Marshall-pushed stream revocation to Audi follows in the control
WebSocket phases.

*Watcher custody and proof identity (2026-10-10).* A renewed real Brady fault
run had one native VMM, one watcher, one pidfd and a valid initial cursor, but
a definite `outcome_unknown` observation withdrew proof before the native
watcher's exit report arrived. The actor then closed the port, suppressing that
genuine terminal report. The failed run remains failed; earlier phase evidence
does not establish this ordering.

The [VM actor](../../../lilly/lib/lilly/vm/actor.ex) now retains its exact bound
watcher after proof withdrawal so it can report the actual `exited` or `error`.
No proof row or authority is retained by that custody. A verified replacement,
superseding durable command or actor shutdown closes the old watcher; each actor
still owns at most one. This reconciles implementation with the existing
immediate-revocation decision, without inventing an exit reason or extending a
backstop.

Internal `proof_target` binds the published proof to its verified VMM. The
30-second backstop and delayed `armed` renewal require the armed watcher to match
that exact target; unavailable, unarmed or different targets keep the two-second
backstop. Same-target boot evidence leaves a live deadline unchanged; a different
boot target withdraws the old live authority before publishing roster-only
proof. A failed journal write cannot relabel the held proof.

The deterministic [actor watcher tests](../../../lilly/test/vm/actor_watch_test.exs)
cover withdrawal before actual exit/error, delayed armed reports, ambiguous and
replaced targets, boot-only replacement and explicit command/shutdown cleanup.
The corrected shell helper distinguishes read timeout from EOF; the true
pre-correction actor fails the port-retention regression. The corrected suite
passes 13 checks (one property and twelve tests) in 1.4 seconds, recorded in
`/tmp/overalls-brady-watcher-race-fixed.log`. The corrected-fixture baseline exits
2 with zero of one passing and seven excluded checks, recorded in
`/tmp/overalls-brady-watcher-race-baseline.log`: the original actor's watcher port
is already absent. This is actor/port ordering evidence, not native pidfd or
fleet acceptance.

The first full gate passed 530 application checks but failed Dialyzer with five
warnings: a closed map spec for the private proof predicate excluded the actor's
other fields. The equivalent predicate now accepts precisely typed `Watch.t()`
and `Watch.target() | nil` inputs. The final complete Lilly gate passes 530
checks (103 properties and 427 tests) in 66.8 seconds, with forced Dialyzer zero
errors, skips and unnecessary skips in 11.46 seconds, recorded in
`/tmp/overalls-lilly-watcher-final-precommit.log`. The first failure survives in
the captured tool transcript and explicitly transcribed
`/tmp/overalls-lilly-watcher-first-gate-failure-summary.txt`; its original raw
wrapper was overwritten and the summary is not a raw execution log.
The renewed complete native Brady gate passes with exit 0 in 359.64 seconds
(nested script 359.33 seconds; whole Nix 625 seconds), at
`/nix/store/xy3r24b2qadnwj7w00lsfgpr5j57vc9x-vm-test-run-overalls-brady-fleet`.
One VMM, one watcher, one pidfd and a valid cursor precede the real VMM kill;
the actual `exited` report revokes the exact placement in 99 ms, within the
unchanged 1,000-ms bound, and subsequent attribution is unresolved. Address reuse,
independent export without Marshall ingestion, retained histories and restart
guest lifetime also pass. The wrapper is
`/tmp/overalls-brady-fleet-watcher-typed-final.log`, with raw JSONL
`/home/ghuntley/.local/state/nix/build-logs/1791601298741-1323264-0.jsonl`.
This is current watcher/Brady native evidence captured before the incoming
Starship guest runtime and fixture changes; it does not establish their merged
execution. The complete Porsche lifecycle gate also passes in 869.30 seconds
against the corrected watcher, with exact application clone audits and native
cleanup; it has the same pre-Starship scope and supplies no additional pidfd
fault proof. The complete real Lilly recovery gate also passes in 707.93 seconds
with the corrected watcher and fsynced Collector queues, preserving physical
readiness during observer loss, exact trace delivery and whole-daemon submission
recovery. This retains the captured pre-Starship scope and supplies no physical
power-loss proof. The complete base
gate passes in 2,324.23 seconds but remains scoped to its captured pre-correction
actor. Accepted rationale, phase history and `partial` implementation status
are preserved.

**Update (2026-10-13, [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md)):**
a pool's `busy` report entry may extend the freshness of its last real
measurement for at most `pool_busy_grace_ms` (15 s);
[HostLiveness.check_windows!/0](../../../marshall/lib/marshall/compute/host_liveness.ex)
refuses at start if that grace plus the capacity window exceeds host authority,
so slowness still never becomes evidence beyond the authority window.

**Update (2026-10-30, pool observer):** pool snapshots leave the host
report path. `Lilly.Host.Collector` read every pool inline, under its pool
lock, before each report, and took `sampled_at` before those reads. Fleet
machine-test runs on 8-vCPU CI runners measured snapshot lock holds of p50
1.5 s and p90 2.0-2.6 s (max 2.7 s), so reports arrived 2-3 s old and the
steady-state enrollment check failed at 5.0-5.2 s (run 41126173301,
audi-ubuntu-relocation-fleet). The decision: each configured ZFS pool gets its
own background observer on its own `Cadence`. The observer reads the pool off
the report path and publishes the latest entry to an `OverallsProtocol.View`,
stamped with the time the read began. Collection reads that view without
waiting. A pool with no published observation, including one whose observer
is not running, is reported `busy`, and a missing observer is announced by a
catalogued event, never by silently reading inline.

The wire gains an optional per-pool `observed_at`
([protocol](../../../protocol/lib/overalls_protocol.ex),
`pool-observed-at-optional`). When it is absent it means `sampled_at`.
Marshall ([HostReports](../../../marshall/lib/marshall/compute/host_reports.ex),
`pool-observation-time-bounds-freshness`) records the real observation time as
the pool's `observed_at`. A re-sent or delayed observation refreshes the pool
only within `pool_busy_grace_ms` of that time, the bound ADR-0163 already sets
for busy entries. An observation older than the recorded one never replaces
it.

Hosts self-deploy trunk independently, with up to five minutes of random
delay, so the same revision can reach a Lilly host before the Marshall host.
An older Marshall rejects the new field. Delivery is therefore two-phase:
(1) protocol and Marshall accept and honour `observed_at`, with Lilly
unchanged; (2) only after (1) has deployed does Lilly's observer start
emitting it. Phase 1 evidence: the protocol round-trip property
(`pool-observed-at-round-trip`) and
[host_reports_test.exs](../../../marshall/test/marshall/compute/host_reports_test.exs)
(`pool-observed-at-ingest`). Phase 2 evidence:
[PoolObserver](../../../lilly/lib/lilly/host/pool_observer.ex) and
[Collector](../../../lilly/lib/lilly/host/collector.ex), with the BEAM test
[pool_observer_test.exs](../../../lilly/test/host/pool_observer_test.exs). In
that test a 6 s read keeps one-second collection with busy entries, then
reports the read's start time; a crashed read keeps the previous observation;
and with no observer the pool is reported busy. Native fleet evidence is
pending.
Review: [2026-10-30 pool observer](../reviews/2026-10-30-pool-observer.md).

**Update (2026-10-31, observer lock share):** with a fixed one-second tick, a
2.5-3.5 s read left the pool lock free for only about 0.5 s between reads, so
mutations that wait 1 s for the lock kept losing (run 41164441328,
account-lifecycle-ubuntu: `lilly.pool_section` snapshot holds of 1.7-4.7 s
and four template reservations `busy` after 1001 ms). The observer now rests
after each read for max(interval - d, min(d, 3 s)), where d is the read's
duration (contract `pool-observer-proportional-rest`). Reads of up to 3 s
hold the lock at most half the time, and fast reads still start once a
second. The worst-case age of a published observation becomes interval + d
for d <= 0.5 s, 3d up to 3 s (7.5 s at the CI median) and 2d + 3 s beyond,
which stays inside the 15 s busy grace until reads take 6 s. Host report
freshness is unchanged, because collection never waits for a read. Evidence:
[pool_observer_lock_test.exs](../../../lilly/test/host/pool_observer_lock_test.exs)
(`observer-lock-duty-at-most-half` and a Hegel property for the rest bound).
Template sections wait in the turn queue instead
([ADR-0176](0176-host-concurrency-single-writers-and-effects.md)).

## Open questions

- The backstop lengths for each tier are settled per phase from measurements.
- The transport for Audi private binding revocation (a per-host peer-credential
  subscription) is settled in phase 3.

## Related decisions

- [ADR-0069](0069-brady-egress-cache.md) (egress attribution)
- [ADR-0125](0125-fresh-guest-identities.md) (roster binding)
- [ADR-0010](0010-capacity-admission-transactions.md) (host freshness)
- [ADR-0052](0052-fenced-local-guest-ingress.md) (the two-second VM observation rule)
