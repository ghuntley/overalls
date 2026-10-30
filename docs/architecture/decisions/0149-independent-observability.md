# ADR-0149: Independent observability and control documents

- ID: ADR-0149
- Date: 2026-10-09
- Status: superseded
- Implementation: partial
- Components: Marshall, Lilly, Protocol, Ziggy, OpenTelemetry, Rust, NixOS, Grafana, Tempo, VictoriaLogs
- Supersedes: ADR-0023, ADR-0037, ADR-0060, ADR-0062, ADR-0063, ADR-0074, ADR-0127, ADR-0132, ADR-0133
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for v1 envelope acceptance and archive import, the lost-legacy-ACK compare, retired archive retention and the cursor migration. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

Service diagnostics have become application protocol obligations. Lilly's native
journals combine execution state with a 64-event diagnostic outbox; a remote audit
acknowledgement gates reconciliation and eventually further journal transitions.
Every host report writes diagnostic summaries while holding Marshall's host lock.
An independent fleet sampler uploads into another application API, database and
set of application dashboards. These boundaries make observability outages affect
control progress and duplicate the existing Grafana, Tempo and VictoriaLogs stack.

The user authorized this replacement in a new worktree, comprehensive Elixir/Rust
observability improvements, automatically created NixOS dashboards, coordinated
breaking protocol changes and publication to main. The accepted scope preserves
transactional security/business audits and accounting, and requires an independent
durable observability spool. Diagnostic durability cannot depend on Tempo's HTTP
ACK: the pinned Tempo 2.10.5 distributor acknowledges before durable WAL custody.

## Decision

Carry forward the superseded records' unrelated Ash state machines, native locks,
host-before-VM transactions, exact placement/epoch/generation fences, immutable
physical receipts, ownership tombstones, capacity holds, secret exclusion,
historical evidence and bounded recovery. Marshall's transactional lifecycle
events, administrative/security audits, SSH login recheck and accounting remain
application data. Diagnostics confer no authority and never release reservations.

Lilly control documents advance to **v4**. The generic authenticated control
WebSocket remains **v1**, and terminal/native credential/execution/transfer formats
remain independently versioned. Remove `lilly.lifecycle_audit`, audit cursors,
receive-progress envelopes and runtime diagnostic acknowledgement gates. Reports
retain sequence/time, effective CPU/memory, capacity coverage bound to physical
execution, observed pools and physical storage identity/usage/quota, architecture,
images and execution readiness. Utilization, pool I/O, decorative hardware fields,
logical storage use and compression belong to infrastructure export.

Native lifecycle **journal v2** stores authoritative state only. Under the existing
native writer lock, validate a v1 journal, durably archive its exact private bytes,
and publish v2 without changing ID, revision, payload or ownership. Malformed
source journals fail closed. An independent importer can replay validated pending
diagnostics from the archive; poison or exporter refusal preserves the archive
and does not gate authoritative v2 progress. No destructive journal reset is part
of the migration.

An optional closed **`guest_ready: true`** belongs to a running physical outcome
for provision/start only. Lilly emits it after `Driver.provisioned` verifies the
exact-generation durable readiness and current boot. Marshall uses the earliest
validated matching physical receipt's database arrival time for readiness SLOs;
absence remains unknown. Later missing evidence cannot erase an earlier proof.
Carry forward ADR-0133's durable attempt admissions, original deadlines, immutable
numeric settlement, seven source lifetimes and workflow exclusions. Traces and
replayed diagnostics never become authoritative SLO inputs.

Ziggy control documents advance to **v2**. Completion carries only outcome, token
counts, completeness and optional price estimate with provenance. Duration, byte
counts, provider request IDs and HTTP status remain local diagnostic data. A lost
legacy ACK compares the canonical accounting projection, preserving the original
immutable archive and exactly-once totals. Provider effects are never replayed.
`ziggy.ssh_login` remains a final authorization recheck and security audit.

Retire Marshall's fleet sample API, diagnostic cache/history writers, diagnostic
Ash resources and fleet/log/SLO views. Keep host, credential, PaperTrail and
historical database archives and foreign keys; revoke all monitoring credentials
without restoring them on rollback. Cancel only unfinished jobs of the retired
`ExpireHistory` and `ExpireSummaries` workers; preserve completed history and
all lifecycle, accounting and security workers. Management controls and
usage/security audit views remain. The host sampler becomes a credential-free loopback Prometheus
infrastructure exporter. Missing, stale or invalid collection remains explicitly
unknown; bounded aggregate VM measurements do not infer allocatable capacity.

Applications use a shared typed observability library **outside `protocol/`**, the
official OpenTelemetry SDK and protobuf encoder, and their reviewed Events
catalogs. The shared catalog validates int64 measurements, units, optional values,
finite schemas and exact trace/span identifiers without strings or payload data.
Generate event registration from application declarations and reviewed Rust/Nix
bindings. Instrument native callers where helper stdout/private streams must
remain exact, and avoid counting one effect at both helper and wrapper boundaries.
Authenticated existing execution bindings supply correlation; no public unchecked
baggage becomes service or host provenance.

Host-local Rust spool services authenticate producers using Unix peer UID and
exact systemd cgroup. Trusted Nix bindings replace service/host provenance. ACK
follows bounded schema validation, stable IDs and checksum publication in a
SQLite WAL transaction with `synchronous=FULL`. The independent spool database
provides indexed pending/expiry storage and immutable batch custody; application
state and PostgreSQL do not participate. Batching and an on-disk index avoid
millions of per-span files and a growing in-memory archive index. Immutable accepted batches remain archived until retention expiry
**even after Tempo ACK**; Tempo is a replayable searchable projection. Retained
archive and pending delivery budgets are separate, bounded per producer and host.
No unexpired ACKed archive is silently evicted. Quota/poison/export/fsync failures
are visible. Routine emission uses bounded asynchronous work; lifecycle handoff
runs after commit, outside short native critical sections, with a bounded timeout.
Unacknowledged gaps are explicit and do not fail physical outcomes.

Every application publishes a reviewed numeric producer-health event every
thirty seconds through its log catalog, outside trace admission. Availability,
pending count, queue refusals and export failures remain observable when trace
intake is full or absent. These volatile counters reset with the application;
independent durable spool health supplies retained custody and backlog evidence.

NixOS owns Grafana datasource and dashboard JSON provisioning with stable UIDs:
services, lifecycle, transfers, fleet, SLOs, pipeline health and logs. Provision
the pinned VictoriaLogs plugin, reader-only credentials through systemd custody,
verified TLS and log/trace links. Keep cardinality bounded and guest-origin claims
outside outer-fleet SLO arithmetic. Collector delivery uses fsynced persistent
queues, unlimited elapsed retry and no volatile batching before durable intake.
Independent health scrapes and backend canaries expose freshness, validity, queue
age, refusal, gaps, storage and replay. Infrastructure alerts have an explicit
private destination rather than the empty fallback route. Do not test against a
live notification destination.

Retain provisional seven-day objectives. Coverage requires actual elapsed retained
Prometheus history as well as cadence-derived sample coverage and source lifetime;
a ten-second scrape must not satisfy a thirty-second sample-count guard after
only 2.33 days. Default full service traces aid this development cutover, with Nix
sampling and byte controls. Ninety-day configured retention is an upper limit,
not a throughput promise: 20 GiB over 90 days is about 2.76 kB/s before overhead.

## Alternatives

Keeping the audit operation with a larger outbox only postpones the same lifecycle
backpressure. Removing all application audits loses transactional security and
accounting evidence. A stock volatile SDK batch processor or deleting archives
on Tempo ACK cannot meet accepted durability. Handwritten per-service tracing
schemas repeat catalog defects and omit SDK context propagation. Manual dashboard
imports drift from deployment and cannot reproduce recovery.

## Consequences

This is a coordinated development cutover, requiring compatible application and
host packages together. Unsupported old documents fail with permanent version
refusal. Diagnostics no longer add writes under control transactions. The
observability plane owns additional independent storage, credentials, replay,
retention and health responsibilities; measurable byte rates determine archive
sizing. Failed diagnostic acceptance remains possible and observable. Historical
archives retain their original revision and cannot prove current deployment.

## Invariants and verification

- Control, VM lifetime and state publication progress with all diagnostic stores down.
- More than 64 valid transitions preserve native fences and physical receipts.
- v1 migration preserves exact archive bytes and state; corrupt input fails closed.
- Readiness and accounting replay conserve authority, timing and numeric totals.
- Spool kill/reboot/ACK-loss/quota/poison histories preserve every accepted archive.
- Credentials, payloads, command arguments and terminal data never enter diagnostics.
- Collector cursor migration preserves backlog and each journal input has at most eight routes.
- Unknown source health stays unknown; backend failure can be observed independently.
- Grafana reprovisioning creates all dashboards and real datasource queries work.
- Fresh Prometheus storage cannot fabricate seven days of coverage from an older source.
- Native/property evidence, full consumer gates and measured traffic/retention remain distinct.

## Implementation evidence

[Accounting validation](../../../protocol/lib/overalls_protocol/inference.ex) and
[Ziggy's private completion schema](../../../ziggy/lib/ziggy/completion.ex) separate
wire accounting from local diagnostics. [Replay tests](../../../marshall/test/marshall/inference/requests_test.exs)
cover retained old receipts. The credential migration (`marshall/priv/repo/migrations/20261009120000_retire_monitor_credentials.exs` at overalls revision `9fe1e493`, repository deleted)
revokes monitor authority while preserving tables.

The [infrastructure exporter](../../../nix/domains/system/fleet-exporter/exporter.py) and
[freshness tests](../../../nix/verification/tests/evaluation/fleet-exporter.py) cover bounded
aggregate numeric export and unknown health. The
[retirement property](../../../marshall/test/marshall_web/diagnostic_retirement_test.exs)
checks closed application ingestion. The [implementation review](../reviews/2026-10-09-observability-decoupling.md)
records actual executed checks, native evidence and remaining acceptance gaps.

The current Elixir cutover extends the existing `elixir/diagnostics/` application,
rather than adding a second general library. Its supervised typed metric
registry, catalog log/trace projection, shared source-redaction helper and
canonical JSON formatter are exercised by
[the shared unit suite](../../../elixir/diagnostics/test/shared_observability_test.exs)
and the focused Lilly/Porsche collector tests. Application catalogs still own
event names and metadata, while Marshall's Phoenix/Oban/Repo adapters retain
their external Telemetry boundaries. Native journal/collector recovery and
production sizing remain open; the scoped review is recorded in
[the 2026-10-10 observability-library review](../reviews/2026-10-10-observability-library.md).

The [spool forwarder](../../../elixir/diagnostics/native/spool/src/main.rs) decodes the
official OTLP response before retiring pending delivery. The pinned Collector's
`0a00` success and zero-rejection warnings are valid; malformed framing, truncated
protobuf and any nonzero rejected count retain pending custody. The reply remains
bounded to 4,096 bytes and a two-second read deadline; response text stays private.
Rust regression checks pass. The first combined native recovery run established
physical control progress during observer loss but failed pending drain on the
previous response parser. Post-fix native spool checks passed in 34.90 seconds
using a synthetic sink with the exact pinned Collector success reply, including
pending drain, immutable ACK retention/replay, identity and producer independence.
The tested production parser and sink match the current source; that snapshot
predates the subsequent eager drain-loop change. A second combined run with the
corrected parser again failed pending drain after physical control passed.
Its failure helper did not capture usable counters, so it establishes no backlog
cause. Neither failed snapshot established combined real Lilly-to-Tempo delivery;
later combined execution retains the original assertions and deadlines.

An independent actual-spool/pinned-Collector reproduction accepted 64 batches at
eight per second but retained 32 pending at producer completion. The former fixed
250-millisecond sleep after each success imposed a four-batch-per-second ceiling.
The exporter now continues after each validated, durably recorded delivery and
backs off only when idle or failed. Network I/O remains outside the custody mutex;
admission gets a scheduling opportunity after each success. Expiry and numeric
health publication run no faster than every 250 milliseconds, including a health
attempt before propagating an expiry failure. Archive/pending quotas and the
existing process resource limits remain unchanged. This repairs the accepted
independent-custody design; it does not establish strict scheduling fairness,
production throughput or the cause of either combined native failure.
The repeated actual-spool/pinned-Collector fixture accepted all 64 batches at
eight per second in 8.224 seconds and SQL counted zero pending at producer
completion, without export failures. This establishes the isolated rate correction,
not Collector/Tempo durability or combined native recovery. Locked Rust checks
pass thirteen tests covering eager Unix forwarding, immutable replay and
forwarding/delivery/expiry failure custody; rustfmt, all-target Clippy with warnings
denied and the locked build pass.
The corrected-loop native spool gate passed in 32.28 seconds (100 seconds including
Nix build), covering identity refusal, reboot/SIGKILL, pending drain, immutable
archive/replay, quota, privacy and corruption. Its production source matches the
current loop; later changes only bounded the unit-test upstream cleanup. The
isolated old-delay mutant fails the backlog regression with exit 101 in a
2.03-second test run, without changing the live source. Combined real
Lilly-to-Tempo recovery remains a distinct gate.
The final parser fixture also bounds missing-client acceptance to two seconds and
request/response I/O to 250 milliseconds, joining its upstream before cleanup and
result assertions. The thirteen Rust checks, format, Clippy and build pass after
this test-only change; the native-tested production runtime remains unchanged.

The corrected combined native gate passed with exit 0 and a 686.22-second driver
footer at
`/nix/store/84zd12k7zm71fiqynsg0wgq81dyskqxy-vm-test-run-overalls-lilly-observability-recovery`.
Its observer-outage recovery subtest passed in 113.04 seconds: exact
VMM/guest/receipt conservation, fresh public stop/start readiness, the original
180-second pending-drain assertion and nondecreasing retained archive counts.
That subtest includes a successful 12.29-second real Tempo query for the fresh
running Execution transition's exact native UUID/revision 16 and enrolled
host/placement. Submission recovery passed in 291.72 seconds across two fixed
histories and one generated draw: six real before/after launch checkpoints and
eight subsequent daemon reopens preserve authenticated settlement and native
ownership. Original assertions, deadlines and fault schedules remain unchanged.
The recorded duration is the native driver, not an exact whole-Nix build timer.
This is disposable native-machine acceptance; production retention/sizing,
physical-host failure and notification receipt remain separate open work.

Completion review found a stale nine-panel assertion in the native log-store
fixture after the operations dashboard grew to fifteen panels. The corrected
fixture checks Grafana's actual provisioned inventory against typed stable
IDs, titles and visualization types, and requires every panel to bind the
Prometheus datasource with nonempty query expressions. The current native
log-store gate passed with exit 0 in 50.56 seconds (68 seconds including Nix), at
`/nix/store/hl7q3blr08cixnvfsjdygy4hnq0dwxdp-vm-test-run-overalls-log-store`.
It also exercises the pinned log plugin, verified TLS, private reader credential,
log/trace correlation, refused writes and queued outage backfill. The prior
58.45-second log-store result is historical and cannot establish the current
dashboard inventory. Composed-driver type checking, Ruff format/lint and contract
checks pass. This strengthens evidence for the accepted declarative provisioning
decision without changing production behavior or closing deployment acceptance.

The current control-room native gate removes the obsolete `/admin/fleet`
navigation target and retains all nine current admin pages and role, elevation,
audit and refusal checks. Its final fresh-request refusal now establishes the
real sign-out revocation of the independent remembered credential after login
expiry, as required by [ADR-0123](0123-remembered-browser-authority.md). Expiring only
the current login leaves remembered resumption valid; changing stored remembered
timestamps does not change the signed token's expiry. Both earlier fixture
assumptions failed and remain historical failures. No production authentication
behavior changed. The corrected complete native gate passed with exit 0 in
63.59 seconds (367 seconds including Nix), at
`/nix/store/71j99s7x7hdacy7dgvkqnybnddb5csw2-vm-test-run-overalls-control-room-browser`.
Its actual browser authority journey passed in 33.60 seconds, including current
login expiry, application remembered revocation and subsequent admin/export
refusals. Packaged browser typing, composed-driver checks, Ruff and contract
checks pass; the tested packaged helper is byte-identical to the current fixture.

A later fixture still asserted an export refusal immediately after the
current login expired. The mounted page correctly leaves for sign-in, which
drops the expired login from the session; the next request then exchanges the
still-valid remembered credential for a new stored login, so the ordinary
export read succeeds as ADR-0123 and ADR-0160 require. The fixture now asserts
that resumption (200 and a new unexpired login) before the real sign-out
revocation and the final admin/export refusals. No Marshall behavior changed.
The corrected native gate passed locally on 2026-10-30 at
`/nix/store/bjpadwzarfg15q2wwbfqnifjbfdpbn9x-vm-test-run-overalls-control-room-browser`
(browser subtest 38.78 seconds).

The current Marshall observability native gate also passed with exit 0 in
113.32 seconds, at
`/nix/store/q4qgzxakvmrc90kjg5n3vxh9kddsbvx2-vm-test-run-overalls-otel-marshall`.
It reaches the retired page's strict 404 before and after ordinary login,
absence of overview navigation links, current/remembered revoked-authority
refusals and all forty evaluated Prometheus alert rules. The browser fixture
supplies its disposable CA to Node's request client as well as Chromium's trust
store, preserving verified TLS; the earlier Node trust failure is historical.
Recorder/producer loss and clean deployment checks also pass. This records the
current fixture's authority and telemetry acceptance without changing production
transport or establishing deployed notification receipt.

Formatter review found that Brady's actual health records are flat, unlike the
seven services using nested `LoggerJSON.Basic` metadata. The diagnostic bridge
now admits that flat shape only for the trusted Brady journal unit and exact
catalogued health event with no nested metadata. A source-built fixture invokes
the actual Brady catalog/formatter, preserving its four reviewed numeric fields
and discarding undeclared metadata. The current Fluent Bit process/transport gate
passed with exit 0 in 431.15 seconds including Nix, at
`/nix/store/h8qj1h046ayniqc1hc36dxv1c6k98ria-overalls-logging-transports`.
It covers the actual formatter shape, source/shape/numeric refusals, metric-only
privacy, trusted routing and cursor isolation; the other seven nested health
fixtures remain synthetic. Fixture compilation with warnings denied and scoped
Dialyzer pass. This corrects production bridge compatibility within the accepted
finite source boundary; it is process evidence, not native-machine/live SDK
supervision or deployed throughput acceptance.

Final custody review found that both Collector file-storage extensions relied
on the pinned default `fsync=false`, contradicting the fsynced-queue requirement
above. Guest trace delivery also retained an asynchronous batch before queue
custody and a 300-second elapsed retry limit. The correction explicitly sets
`fsync=true` on both separate bounded queues, removes only the guest trace
prequeue batch and uses unlimited elapsed retry for both trace exporters.
An evaluated-module regression checks these exact bindings and limits.
Architecture impact is reconciliation with the accepted custody guarantee;
neither the independent immutable archive nor control/accounting authority is
changed. Current evaluated/native Collector and combined Lilly-to-Tempo recovery
execution remains separately scoped. The evaluated `collectorTraceCustody` case
passes and the first corrected native Collector gate passes in 432.85 seconds
(597.34 seconds including the combined Nix invocation), at
`/nix/store/hh20hzz0n8cqa4s87bamwvm9r0nlfyh9-vm-test-run-overalls-otel-fleet`.
That snapshot predates the strengthened immediate-SIGKILL-after-ACK assertions:
both twelve-second worker waits are removed, and all three queue journeys now
kill the Collector immediately after acceptance. Original trace identities,
refusal/recovery assertions and deadlines remain. That strengthened native gate
passed with exit 0 in 500.09 seconds (nested script 500.02 seconds; whole shell
527.36 seconds), at
`/nix/store/lc896lmvjjzs72pg8hf88p73ay0yyanr-vm-test-run-overalls-otel-fleet`.
All three exact trace journeys recover after accepted intake, immediate SIGKILL
and restart. This establishes the tested process-crash boundary, not physical-host
power-loss durability. The final complete real Lilly-to-Tempo gate also passes
with the corrected typed watcher and Collector custody configuration in 707.93
seconds (nested script 707.60 seconds; whole shell 796.360 seconds), at
`/nix/store/n30gqwncgn0w9r0j8lahs370x8mb75rp-vm-test-run-overalls-lilly-observability-recovery`.
Collector/spool outages preserve native control and physical readiness, then
drain within the original 180-second bound and deliver the exact fresh native
transition to Tempo. That subtest passes in 113.51 seconds. The three launch
histories, six before/after submission checkpoints and eight settled reopens pass
in 299.61 seconds, preserving exact guests/VMMs and receipts across whole-daemon
loss. This captured runtime predates incoming Starship guest/fixture changes;
it does not establish merged guest execution or physical power-loss durability.
The intentionally interrupted pre-correction launch is not passing evidence.

Final Lilly contract reconciliation replaces stale audit-sender/outbox wording
with the retained authoritative journal, physical outcome ACK and state-only v2
or validated legacy v1 history boundaries. Five files change comments only;
execution, assertions, deadlines and locks are unchanged. That captured complete
Lilly precommit gate passes 524 checks (103 properties and 421 tests) in
98.3 seconds, followed by forced Dialyzer with zero errors/skips in 16.1 seconds.
This clarifies existing ADR-0149/ADR-0140 obligations and preserves the executable
scope of captured native journeys; it does not establish the corrected Collector
configuration's native acceptance or physical isolation from unit checks.

A subsequent real Brady fault run identified a separate execution-watcher race:
revoking a target's routing after `outcome_unknown` can close its sole native exit
watcher before a genuine `exited` report arrives. The runtime correction retains
that exact watcher without retaining authority, and binds its longer backstop
to the exact current proof target, as reconciled in
[ADR-0140](0140-event-driven-liveness-and-single-writer-views.md). Thirteen
deterministic actor/port checks pass; the pre-correction actor with the corrected
fixture fails the retention regression. After a closed-map type-contract failure,
the equivalent precisely typed private helper passes the full 530-check Lilly
gate and forced Dialyzer with zero errors/skips. The renewed native Brady gate
also passes with exit 0 in 359.64 seconds (625 seconds including Nix), at
`/nix/store/xy3r24b2qadnwj7w00lsfgpr5j57vc9x-vm-test-run-overalls-brady-fleet`.
The exact native watcher reports actual exit and revokes the placement in 99 ms;
address-reuse refusal, independent infrastructure export without Marshall
ingestion, restart/history and guest lifetime checks pass. This is captured
current watcher/Brady evidence before the incoming Starship guest/fixture changes,
not merged guest execution. Real Lilly recovery now has separately recorded
complete native acceptance above; component checks and the independent Collector
crash gate remain distinct evidence.

The complete captured base fleet gate passes with exit 0 in 2,324.23 seconds
(nested script 2,323.94 seconds; whole shell 2,785.364 seconds), at
`/nix/store/r6n7bdg75gngrblwrpdv63r9r4795p95-vm-test-run-overalls-fleet`.
Both deleted host victims retain exact initiating-user intent and accepted system
deletion outcomes with zero provisioner diagnostics. Physical storage cleanup,
capacity races, network isolation, terminal reconnect, machine/database loss,
daemon death and authority refusals also pass. This fixture predates the watcher
correction and remains evidence for that captured runtime.

The complete corrected Porsche lifecycle gate passes with exit 0 in 869.30
seconds (nested script 868.92 seconds; whole shell 1,057.869 seconds), at
`/nix/store/vhq2w5qkr8448q90y240y8vyv5bzmafd-vm-test-run-overalls-porsche-lifecycle-fleet`.
The browser/native SSH lifecycle passes in 703.71 seconds, including independent
guest disks/data, relocation and source/copy cleanup. Both completed clone audits
then pass in 0.49 seconds with exact source, destination, workflow/request,
initiating user and successful system completion identities, and no provisioner
diagnostic rows. This executes the frozen corrected typed watcher runtime before
the incoming Starship guest/fixture changes; it does not establish merged guest
execution.

The corrected typed-procfs relocation run fails with exit 1 after a whole-shell
1,958.249 seconds and produces no complete output artifact. Its frozen derivation
is `/nix/store/pbdc9djqlng5ld8hk4akpkgzdkg16www-vm-test-run-overalls-relocation-fleet.drv`,
with wrapper `/tmp/overalls-relocation-kernel-thread-native-final.log`.
Live move/return, stopped move, pre-handoff cancellation, Delete, actual nonempty
stream cancellation (90.33 seconds) and both-endpoint restart recovery
(368.53 seconds) pass with unchanged bounds and physical/audit oracles. The next
fresh guest fails to reach running before the completed-final-receive fault is
injected. Native evidence reports `private_services_unavailable`: reboot removes
the fixture's volatile `/run/galileo-audi-root.pem`, preventing Galileo and required
Audi-private startup. The trust-custody fixture correction retains the exact
public root across reboot and checks actual private-service readiness. Its full
passing rerun is recorded separately below. The failed run stays failed; its
passing prefix does not establish the remaining fault matrix or merged incoming
guest/profile deployment.

The complete corrected relocation gate exits 0 with all 19 subtest footers. Its
frozen derivation is
`/nix/store/vqmp9ypkb52nnq7w93nl3410wb8vjxkn-vm-test-run-overalls-relocation-fleet.drv`,
with driver
`/nix/store/hp58jifzd3dzlrwjkc9viif6l22sydcx-nixos-test-driver-overalls-relocation-fleet`
and realized output
`/nix/store/11ibfwp2xv1jdf53vn3gr3q22mhdc3hg-vm-test-run-overalls-relocation-fleet`.
The VM-run footer is 3,643.75 seconds, the following script footer 3,643.99 seconds,
and the Bash wrapper 3,654.445 seconds, recorded at
`/tmp/overalls-relocation-trust-native-final.log`. Actual nonempty stream
cancellation passes in 84.28 seconds, both-endpoint restart recovery in 381.13,
completed-final-receive loss in 232.39, actual endpoint updates in 336.29,
new-boot readiness retry in 389.19, physical source-pressure fallback in 484.63
and destination ENOSPC recovery in 269.67. Live/return/stopped moves, source-stop
cancellation, readiness timeout, unavailable cleanup and final Delete also pass
with the original physical/audit/fault/deadline oracles. Both trust-custody source
files remain frozen with matching checksums.

This native capture includes the incoming profile implementation and Starship
guest source. Later Nix descriptions, fleet comments, the separate incoming
image-template fixture and decision-status documentation change no relevant
runtime values. It does not establish a packaged retained-state upgrade, native
Starship prompt rendering, the full clone/Ubuntu matrix, physical-host failure,
live deployment, retention sizing or notification receipt. The Ubuntu and
additional cloning matrix reruns remain outstanding.

ADR-0159 Push 6 removed the superseded clauses from code: the
[lifecycle journal](../../../lilly/lib/lilly/lifecycle/journal.ex) accepts only v2
envelopes and no longer migrates v1 or writes `.lifecycle-v1`/`.lifecycle-legacy`
archives; the archive importer (`lilly/lib/lilly/lifecycle/diagnostics.ex` at overalls revision `9fe1e493`, repository deleted),
legacy event vocabulary (`lilly/lib/lilly/lifecycle/legacy_event.ex` at overalls revision `9fe1e493`, repository deleted),
standby terminal-archive custody branch and `persist_transition` are deleted; and
the shared [custody API](../../../elixir/diagnostics/lib/overalls/diagnostics/custody.ex)
keeps only bounded `enqueue/3` (synchronous `persist/3` and its processor/sampler
modes are gone). Earlier evidence in this section describing the importer and v1
archives is historical.

## Open questions

Measure producer traffic, spool fsync latency, query cost and effective retention
under the deployed workload. Complete physical multi-host crash/reboot acceptance
and independently observed notification delivery before claiming fleet acceptance.

## Related decisions

[ADR-0042](0042-host-observability.md) retains restricted host evidence and independent
Fluent Bit custody. [ADR-0088](0088-legacy-vm-journal-import.md) retains the separate
native execution import. [ADR-0136](0136-durable-application-request-accounting.md)
retains independent request SLO recorders. [ADR-0138](0138-telemetry-retention-and-measurement-diagnostics.md)
retains metric/trace retention and additive latency measurement.
[ADR-0142](0142-overallsprotocol-control-websocket.md) retains authenticated transport.
[ADR-0145](0145-same-pool-block-cloned-clones.md) and
[ADR-0146](0146-standby-guest-disks.md) retain native copy/standby state, ownership
and capacity-accounting requirements; their old diagnostic-reader rollout clauses
are historical. Independent diagnostics confer no copy, claim or cleanup authority.
