---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Antithesis Fit evaluation

> **Snapshot note (2026-10-13):** This cold lens evaluated the initial 75-property catalog and its then-current zero-callsite scan. The later shared-worktree [assertion rescan](../existing-assertions.md) found 18 startup/bootstrap/Control callsites, two partially instrumenting Control catalog properties. The final [synthesis](synthesis.md) records the 104-property result and dispositions.

This pass evaluates all 75 canonical rows of the current [property catalog](../property-catalog.md) against the [SUT analysis](../sut-analysis.md), [deployment topology](../deployment-topology.md), [existing assertion scan](../existing-assertions.md), and selected per-property evidence. It is a research review of proposed checks: the current source scan found zero Antithesis SDK assertion callsites, and no new hosted baseline, fault campaign, or native acceptance run is claimed. Priority denotes product importance; the findings below concern what Antithesis can usefully search and what each SDK assertion can actually establish. The user selected “Repository only (Recommended)” and supplied no external system references. Official Antithesis documentation was consulted only for platform and SDK semantics.

## Findings: catalog-wide

### F1 — Existential `Sometimes` is weaker than the catalog's eventual-progress wording

**Properties:** `control-hint-loss-reconciles-authority`, `lost-host-hint-eventually-delivers-command`, `lilly-finite-obstruction-recovery-progress`, `lilly-pool-sampling-does-not-starve-mutation`, `terminal-kill-progress-under-pty-backpressure`, `terminal-stalled-viewer-neighbor-progress`, and supplementary progress clauses in `cancelled-relocation-restores-after-revocation`, `delete-release-follows-physical-retirement`, `guest-readiness-binds-current-physical-boot`, `stop-retains-disk-until-restart`, `runtime-restart-requires-fresh-readiness`, `updater-failed-activation-recovers-live-roles`, and `upgrade-preserves-owned-guests`.

**Concern:** `Sometimes` succeeds after *one* true encounter over the run. That is valuable evidence that a meaningful recovery state is reachable and gives Antithesis a search checkpoint, but it does not refute starvation of a different eligible operation or show that every designated operation eventually finishes. The catalog's “eventually” and “after finite obstruction” prose is stronger than an existential assertion by itself. The per-property files often choose a designated operation ID and good preconditions, which is the right start; the assertion alone still cannot establish a universal conditional liveness guarantee. `terminal-stalled-viewer-neighbor-progress` is especially explicit about the combined state, while `lilly-finite-obstruction-recovery-progress` has no source-defined general deadline.

**Evidence:** Catalog rows at `property-catalog.md:79,241,668,716,1129,1162`; [Lilly progress evidence](../properties/lilly-finite-obstruction-recovery-progress.md) requires accepted work, physical result and a neighbor after a real lock obstruction; [terminal neighbor evidence](../properties/terminal-stalled-viewer-neighbor-progress.md) requires a still-stalled viewer when neighbor bytes arrive. The topology's “Fault classes and liveness windows” section reserves quiet windows for measured recovery. [Antithesis assertions](https://antithesis.com/docs/product/writing_tests/assertions/) defines `Sometimes` as true at least once per test run; [Sometimes Assertions](https://antithesis.com/docs/best_practices/sometimes_assertions/) describes its coverage and search-guidance role.

**Suggested action:** Retain `Sometimes` where it names a rare semantic state. For claims about a designated eligible operation, also record a per-operation terminal check after a measured, fault-free interval, tied to exact committed operation and physical witness; report missing preconditions and unavailable oracle separately. Do not infer fairness for all work from one passing `Sometimes`.

### F2 — Optional-path safety checks can report green without exercising the danger path

**Properties:** `execution-v4-refuses-legacy-document`, `lilly-corrupt-intent-never-becomes-receipt`, `lilly-view-restart-withdraws-stream-authority`, `source-stop-after-committed-placement-holds`, `private-readiness-v1-gates-new-execution`; the optional profile rewrite branch of `store-v3-host-binding-survives-upgrade` is similar.

**Concern:** The primary `AlwaysOrUnreachable` type is semantically appropriate for a truly optional path. Its no-hit result passes, however. In a focused template intended to test incompatible Execution documents, corrupt Store intent, a real View restart, clone source interruption, or enabled private readiness, an unhit path would leave the substantive risk unexplored while the safety property appears green. Several companion `Reachable` suggestions mark only *successful* compatible behavior, so they do not prove that the dangerous path was entered.

**Evidence:** Catalog rows `:603,:651,:749,:864,:896,:1215`; [Execution v4 evidence](../properties/execution-v4-refuses-legacy-document.md) proposes a compatible-session `Reachable`; [private readiness evidence](../properties/private-readiness-v1-gates-new-execution.md) proposes a positive ready-path `Reachable`. [Antithesis assertions](https://antithesis.com/docs/product/writing_tests/assertions/) explicitly says `AlwaysOrUnreachable` passes if never encountered and `Reachable` fails if never encountered.

**Suggested action:** Keep `AlwaysOrUnreachable` for general runs, but catalog a distinct `Reachable` for the actual incompatible/corrupt/restart/stop/negative-status entry in each template that promises this coverage. Require both the danger-path witness and the safety assertion when accepting that template's result.

### F3 — The property set mixes hosted Antithesis search targets with native-only acceptance claims

**Properties:** especially `backup-interrupted-cleanup-owned-only`, `backup-retained-manifest-closure`, `backup-time-skew-never-activates-historical-authority`, `cancelled-relocation-restores-after-revocation`, `relocation-handoff-one-current-execution`, `native-utility-descendant-custody`, `stop-retains-disk-until-restart`, `healthy-revision-requires-live-candidate`, `migration-finishes-before-upgrade-activation`, `updater-failed-activation-recovers-live-roles`, and `upgrade-preserves-owned-guests`.

**Concern:** These are strong failure hypotheses, but full claims need Firecracker, production ZFS/systemd, distinct hosts or activation closures. The topology puts the `native-kvm` campaign outside hosted Compose and says the TCG seams have narrower proof. A primary `Always` cataloged in a hosted template without the required physical effect will either never be hit or check a surrogate that cannot establish the named claim. Conversely, native tests outside Antithesis cannot provide an Antithesis SDK search checkpoint or hosted result merely by retaining an SDK-style planned message in this catalog.

**Evidence:** [Deployment topology](../deployment-topology.md), “Scope and decision,” “Focused configurations,” and “Acceptance gates”; [SUT analysis](../sut-analysis.md), “Architecture and real deployment” and “Operational and cross-layer hypotheses.” Per-property examples [migration](../properties/migration-finishes-before-upgrade-activation.md) needs real systemd migrator/advisory-lock custody across hosts and [native utility](../properties/native-utility-descendant-custody.md) needs actual descendant/process/lock evidence. The catalog labels all 75 rows as unimplemented research targets, which correctly avoids claiming coverage today.

**Suggested action:** Freeze an explicit property-to-template roster before instrumentation. Give each row an evidence scope: hosted real, hosted TCG-limited, or native-only. Catalog only assertions whose check actually runs in a selected hosted template; retain native-only rows as acceptance targets with native results, without treating them as hosted Antithesis properties. If a row has both scopes, name the narrower hosted claim and separate physical acceptance witness.

### F4 — Fixed decoder/version matrices and one-time migration fixtures should not dominate fault-search budget

**Properties:** `control-service-dispatch-closed`, `execution-v4-refuses-legacy-document`, `store-v3-host-binding-survives-upgrade`, `source-v2-capability-gates-admission`, `private-readiness-v1-gates-new-execution`, `guest-identity-cutover-preserves-uid-custody`.

**Concern:** Their baseline negative examples are finite input matrices: wrong op/body version, foreign Store identity, absent capability, wrong readiness document, or legacy rows passed through a single transaction. Those cases can be exhaustively and cheaply checked in protocol/unit or targeted integration tests. The same properties *do* gain Antithesis value when the bad input races a valid request, when an old process survives a cutover, or when reply/commit order is uncertain. A template that simply loops static bad documents with no concurrent valid state or fault point spends search on deterministic validation rather than on the catalog's actual timing hypothesis. The migration row's same-user email and retirement races are the valuable second phase; migration conversion of a frozen fixture alone is deterministic.

**Evidence:** The catalog's “Antithesis Angle” fields for these rows explicitly add coalesced frames, cross-service valid/invalid races, restart/replay, catalog changes, old running guests, or email edits. [Control dispatch evidence](../properties/control-service-dispatch-closed.md) calls this a stateful authorization test and asks for an independently observable effect; [Store v3 evidence](../properties/store-v3-host-binding-survives-upgrade.md) distinguishes fixed binding refusal from restart/owner continuity; [guest identity evidence](../properties/guest-identity-cutover-preserves-uid-custody.md) distinguishes database migration from native home reconciliation. [Optimizing for testing](https://antithesis.com/docs/best_practices/optimizing/) recommends configuring workloads to reach rare, sensitive states efficiently.

**Suggested action:** Keep exhaustive fixed matrices in ordinary tests. For hosted Antithesis, select a small representative invalid input and spend schedule/fault variation on its collision with a valid effect, restart, revocation, or cutover. Keep the same invariant and independent effect oracle where the interleaving matters.

### F5 — Several high-value search checkpoints are only prose suggestions

**Properties:** `marshall-admission-atomic-allocation`, `lilly-outcome-replay-exact-ack`, `lilly-interrupted-launch-at-most-once`, `brady-cache-complete-publication`, `ziggy-interrupted-inference-never-reexecutes`, `enrico-native-git-admission-after-manager-restart`, `guest-workspace-restart-publication-no-clobber`, and `terminal-create-reply-loss-one-pty`.

**Concern:** These rows have the strongest Antithesis fit because a narrow crash/reply-loss interval separates durable intent from an independent physical or external effect. Yet many catalog rows name only the final `Always` and put intermediate state or branch instrumentation in their evidence files. Workload-only final checks can detect an error but give the search engine little guidance toward a rare commit-before-reply, marker-before-launch, rename-before-done, or producer-effect-before-accounting state. The scan confirms none of the proposed SUT assertions exist yet.

**Evidence:** [SUT analysis](../sut-analysis.md), “Persistence and the uncertain-effect boundary” and “Concurrency, supervision and ownership,” distinguishes PostgreSQL commits, replies, native custody and external effects. Catalog rows `:501,:518,:684,:700,:765,:1013,:1095` name crash/replay windows. [Antithesis assertions](https://antithesis.com/docs/product/writing_tests/assertions/) says assertions guide search; [Sometimes Assertions](https://antithesis.com/docs/best_practices/sometimes_assertions/) explains rare checkpoints. Existing-assertions scan reports zero callsites.

**Suggested action:** In the first implemented high-value templates, place surgical SUT-side `Sometimes`/`Reachable` anchors at *observed* intermediate states (for example, durable commit with lost reply, old outcome pending after reconnect, source rename before done), with stable IDs and no payload secrets; retain independent workload `Always` checks for the final invariant. Do not claim an anchor reached merely because a fault was requested.

## Findings: property-specific

### F6 — `terminal-kill-progress-under-pty-backpressure` needs a demonstrated blocked write before a progress failure is meaningful

The proposed `Sometimes` asks kill to retire a PTY while input is blocked and companion `Reachable` names the overlap. Source shows `write_all` under `SessionInner` and a blocking PTY master, but no composed run yet proves the master remains blocked with a non-reading child. If the workload never reaches that precise state, the `Sometimes` failure is a workload/precondition result, not evidence of a terminald liveness defect. [Evidence file](../properties/terminal-kill-progress-under-pty-backpressure.md) records this distinction and the relevant `session.rs:506-525` / `pty.rs:157-163` source. First establish the blocked-write event from the deployed daemon, then measure kill retirement while the event remains true; retain the separate neighbor probe to locate the scope of any stall.

### F7 — `lilly-pool-sampling-does-not-starve-mutation` can pass without proving contention

The proposed condition says the selected mutation and neighbor finish while sampling continues. The failure mode is a held pool lock, zero-wait sampling and repeated ticks. Without a separately witnessed contested acquisition and release for the *same pool and operation*, completion may be an ordinary uncontended success that satisfies `Sometimes` and gives little evidence about sampler starvation. The [property evidence](../properties/lilly-pool-sampling-does-not-starve-mutation.md) proposes a `Reachable` after sampled contention and identifies real two-pool ZFS as required for physical fairness; the catalog row at `:716` does not carry that witness requirement. Make contention reached and later released an acceptance precondition for the targeted template, keep its operation ID in the progress condition, and measure the post-release window.

### F8 — Fixed production caps may be impractical search targets at full scale

**Properties:** `request-recorder-capacity-does-not-admit-phantom-work` and `enrico-attempt-replay-bounded-receipts`.

The former needs 4,096 live admitted workers before the 4,097th probe; the latter's eviction subcase needs 1,025 actual completed native Git attempts to cross a 1,024-receipt cap. Those exact boundaries matter for production acceptance, but repeated setup at that scale can crowd a focused Antithesis timeline and reduce interleaving search. Both evidence files acknowledge the cost and refuse to claim a scaled threshold proves the exact contract. [Recorder evidence](../properties/request-recorder-capacity-does-not-admit-phantom-work.md) traces the 4,096 cap; [Enrico evidence](../properties/enrico-attempt-replay-bounded-receipts.md) traces 1,024 retention and separately identifies lost-status/replay races. Keep exact full-cap tests as a measured dedicated campaign. Let early hosted search emphasize a few active attempts and lost replies; if using a test-configured smaller cap, label that as mechanism evidence and still require an exact production-cap receipt elsewhere.

### F9 — `control-version-refusal-remains-terminal` combines opposite recovery modes under one row

The primary `Always` checks permanent 426/4001 refusal and no retry. A supplementary `Sometimes` checks reconnection only after a *recoverable* socket loss. These are distinct histories with opposite owner behavior; a generic healthy reconnection can satisfy the `Sometimes` without checking the permanent-refusal boundary. The [catalog row](../property-catalog.md) and [property evidence](../properties/control-version-refusal-remains-terminal.md) explicitly distinguish transport version, service-document version, and transient outage. Run separate version-refusal and recoverable-outage commands/templates or branch-correlated assertions; record the exact connection/owner ID and refusal class so the permanent and recovery outcomes cannot be conflated.

### F10 — `guest-identity-cutover-preserves-uid-custody` is primarily a migration acceptance test unless its later race is retained

The conversion of seeded legacy names and UIDs is a one-way, transactional database migration. Its fixed before/after table and sequence checks are strong ordinary integration evidence. The Antithesis value comes from the *later* same-user email edit versus retire/new-user same-email admission amid a lost reply or restart, which overlaps `guest-identity-never-transfers-on-email-reuse`. [Identity cutover evidence](../properties/guest-identity-cutover-preserves-uid-custody.md) says an interrupted PostgreSQL migration should be reconciled at the transaction boundary, not represented as half-migrated state. Keep the static migration fixture in native/integration acceptance, and only spend hosted fault search on committed cutover followed by identity reuse and competing admission with exact UUID/UID history.

## Passes

- The highest-risk authority/effect rows (`marshall-admission-atomic-allocation`, `host-session-successor-fences-old-exchanges`, `lilly-outcome-replay-exact-ack`, `ziggy-completion-once-accounted`, `brady-cache-complete-publication`, and guest boot/stream fencing) have genuine commit/reply, restart, independent-effect or stale-authority interleavings. Their primary safety `Always` direction is appropriate when evaluated at real effects with independent witnesses.
- `AlwaysOrUnreachable` is a defensible primary type for optional configurations and corruption paths; the concern is proof of reaching the path in a focused acceptance run.
- `Sometimes` is used for meaningful composite states in `guest-ready-does-not-claim-workspace-checkout`, `terminal-stalled-viewer-neighbor-progress` and lost-hint recovery, rather than mechanically replacing `Reachable(true)`. The limitations above concern what those states prove and whether workloads can reach them.
- The catalog and topology consistently distinguish uncertain replies from definite refusals, shared-PostgreSQL application concurrency from database HA, TCG guest evidence from native Firecracker/KVM evidence, and test presence from passing execution. These distinctions improve Antithesis fit and prevent false positives.

## Uncertainties

- No hosted run, tenant fault inventory, or implemented SDK callsite exists yet, so reach rates, simulation efficiency, available node/clock faults, and whether the proposed rare `Sometimes` states occur are unmeasured. The [topology](../deployment-topology.md) lists these as acceptance gates.
- TCG guest/router boot time, retained volumes, real ZFS contention and exact native custody are unmeasured here. Some property scopes may move between hosted and native-only after measured feasibility; this review does not assert that any currently works in Antithesis.
- The right finite quiet interval for Lilly pool progress, terminal kill/neighbor progress and selected recovery checks is not supplied by a universal source SLA. The per-property evidence calls for a measured interval tied to the selected environment.
- No product restore consistency/RPO promise was found beyond sequential component capture. This fit pass does not infer one from the backup rows.

## Assumptions

- “Repository only (Recommended)” limits system facts to this repository at the pinned SUT commit. Official Antithesis pages above establish assertion/platform semantics, not Overalls behavior.
- Findings assess the catalog as a proposed portfolio. They do not classify synthesis outcomes or edit property definitions.

## Open Questions

- Which focused templates will actually execute each primary and supplementary assertion, and which native-only rows should remain acceptance records without hosted SDK cataloging?
- Which rare-state anchors can be placed inside the real source-built services without changing the authorization/effect path or exposing sensitive payloads?
- Which measured quiet windows and full-cap workloads are practical after the first real image and oracle smoke?
