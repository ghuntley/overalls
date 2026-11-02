---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Property evaluation synthesis

The four cold lenses reviewed the initial 75-property catalog against the SUT analysis, deployment topology, assertion scan and selected evidence. Their findings plus one subsequent source-traced topology constraint collapse into nine targeted discovery briefs, 14 catalog edit proposals, nine implementation prerequisites and two genuine policy questions in [the action queue](action-queue.json). The [template roster](template-roster.json) maps every current property ID to a proposed hosted/native proof boundary. These are review outputs and implementation plans: the catalog and evidence now include the completed per-property question investigations and 32 distinct gap properties. The moving shared worktree now has authored checks for a subset of catalog properties; the exact as-of callsites and source hashes are in [the assertion inventory](../existing-assertions.md). No hosted catalog baseline or mutant result exists.

The user authorized the **entire repository**, including real hosted services, TCG and native KVM work. A perceived preference for core control paths is resolved by that scope and requires no further prioritization question. Coverage must still carry exact environment limits: TCG boot does not prove Firecracker isolation, and native machine evidence is not a hosted SDK result.

A source trace after the cold reviews tightened the hosted topology: [Lilly’s report](../../../lilly/lib/lilly/control/runtime.ex#L478) marks the current harness release `execution_ready=false`; [Marshall admission](../../../marshall/lib/marshall/compute/admission.ex#L202) requires readiness and a fresh measured available pool, while [host report validation](../../../marshall/lib/marshall/compute/host_reports.ex#L272) binds ZFS identity/observation. A Control-only identity/unavailable pool can exercise handshake, report, authentication, refusal and reconnect, but **cannot** produce accepted placement. The accepted-placement and guest/satellite rows now require a prospective integrated real inner-ZFS-backed Lilly host or native KVM. The standalone storage-router is a different pool boundary. No fake admission or bypass is an acceptable oracle (`T1`, `R14`, `I9`).

## Findings and dispositions

| Category | Count | Disposition |
| --- | ---: | --- |
| Gap | 12 | Nine briefs yielded 32 distinct catalog properties; one historical restore reentry candidate remains deferred. |
| Refinement | 20 | Fourteen proposals now appear as catalog, evidence and roster research requirements; implementation is unbuilt. |
| Bias | 1 | Preserve historical restore activation as a separate policy question. Galileo grant anchoring is also an unresolved product-policy question; build its timing witness meanwhile. |

Every numbered lens concern is accounted for below. Source links lead to the full report and its primary evidence; action IDs lead to the structured briefs and edit text in [action-queue.json](action-queue.json).

| Lens finding | Category | Concern and action |
| --- | --- | --- |
| [F1](antithesis-fit.md) | Refinement | Existential Sometimes cannot prove every eligible operation eventually finishes. → `R1` |
| [F2](antithesis-fit.md) | Refinement | Optional AlwaysOrUnreachable can pass without danger path. → `R2` |
| [F3](antithesis-fit.md) | Refinement | Hosted/TGC/native proof scopes are mixed without a row roster. → `R3`, `I6`, `I7` |
| [F4](antithesis-fit.md) | Refinement | Static decoder/version/migration matrices should be ordinary tests; preserve fault transition slice. → `R4` |
| [F5](antithesis-fit.md) | Refinement | High-value intermediate search checkpoints remain prose only. → `R5` |
| [F6](antithesis-fit.md) | Refinement | Terminal kill needs observed blocked PTY write. → `R6` |
| [F7](antithesis-fit.md) | Refinement | Pool sampling progress can pass without contention. → `R7` |
| [F8](antithesis-fit.md) | Refinement | Exact production cap setup may be too large for routine hosted search. → `R8` |
| [F9](antithesis-fit.md) | Refinement | Control version refusal combines permanent and recoverable owner behavior. → `R9` |
| [F10](antithesis-fit.md) | Refinement | Guest identity cutover fixed conversion dominates unless later reuse race is retained. → `R10` |
| [C1](coverage-balance.md) | Gap | Browser magic-link/MFA/remembered login and administrative revocation absent. → `G1` |
| [C2](coverage-balance.md) | Gap | Physical guest isolation and Brady egress/attribution authority absent. → `G2` |
| [C3](coverage-balance.md) | Gap | Clone, resize and relocation byte/GUID/route lineage thin. → `G3` |
| [C4](coverage-balance.md) | Gap | Agent tools and normal named integration effects thin. → `G4` |
| [C5](coverage-balance.md) | Gap | SSH, DNS route and personal editor effects absent. → `G5` |
| [C6](coverage-balance.md) | Gap | Inception and guest/profile/provider variants need explicit selection and possibly properties. → `G6`, `R13` |
| [C7](coverage-balance.md) | Gap | Interrupted isolated restore publication absent. → `G7` |
| [C8](coverage-balance.md) | Gap | Lyra updater/enrollment/secret custody and diagnostic-independent user progress absent. → `G8` |
| [C9](coverage-balance.md) | Refinement | Optional reach, liveness restoration and priority distribution need an exact roster. → `R2`, `R3`, `R13` |
| [W1](wildcard.md) | Gap | Catalog begins after customer browser authority already exists. → `G1` |
| [W2](wildcard.md) | Gap | Safe handoff does not imply useful copied bytes or new route. → `G3` |
| [W3](wildcard.md) | Gap | No assertion joins acknowledged create to same-customer usable persistent guest. → `G9` |
| [W4](wildcard.md) | Gap | Backward clock step may publish complete manifest invalid for later retention. → `G7` |
| [W5](wildcard.md) | Bias | Historical restore reentry requires policy receipt absent from source. → `B1`, `R11` |
| [I1](implementability.md) | Refinement | Every row needs executable history, independent typed oracle, assertion evaluation and unexercised state. → `I1`, `R3` |
| [I2](implementability.md) | Refinement | Control requires real authenticated wire and effect histories. → `I3` |
| [I3](implementability.md) | Refinement | Lease requires causal effect barrier; Galileo anchor remains unsettled. → `I4`, `B2`, `R12` |
| [I4](implementability.md) | Refinement | External effects require faithful local origins and full-cap witnesses. → `I5`, `R8` |
| [I5](implementability.md) | Refinement | Physical lifecycle needs real lower boundary and two-host transfer for full claims. → `I6`, `I7`, `R3` |
| [I6](implementability.md) | Refinement | Backup/measurement custody needs actual Restic, SQLite, systemd producer and quota faults. → `I8` |
| [I7](implementability.md) | Refinement | Guest/workspace/terminal need boot-bound independent effect witnesses. → `I6`, `R6` |
| [I8](implementability.md) | Refinement | Updater/migration need native NixOS closure/systemd/migrator evidence. → `I8`, `R3` |
| [T1](../../../lilly/lib/lilly/control/runtime.ex#L478) | Refinement | Control-only hosted pool has identity without measured available ZFS or execution readiness; Marshall refuses accepted placement. → `R14`, `I9` |

## Catalog edits applied after question investigation

The 14 queue proposals have been reconciled as explicit research requirements in the affected catalog entries, evidence files and template roster. Their implementation and baseline remain unbuilt. The highest-impact requirements are:

- `R1`: Keep `Sometimes` for one meaningful reached recovery state. For a designated eligible operation, use a separate per-operation terminal check after witnessed dependency restoration and a **measured** quiet interval. A passing existential assertion does not prove all requests eventually complete.
- `R2`: Pair every selected optional `AlwaysOrUnreachable` with a distinct `Reachable` of the dangerous path itself. A compatible positive path cannot prove malformed/corrupt/restart/negative-status coverage.
- `R3`: Add the roster’s hosted claim limit, native companion and independent witness to each selected row. Report an absent oracle or unselected variant as **unexercised**.
- `R4`–`R5`: Put exhaustive fixed codec/version/migration matrices in ordinary tests, and spend fault search on their stateful transition. Add SUT-side search anchors only at observed intermediate commit/effect states; retain independent final safety checks.
- `R6`–`R10`: Make blocked PTY write and real pool contention observed preconditions; measure exact production saturation separately; split Control permanent refusal from recoverable reconnect; keep static GuestAccount migration acceptance distinct from post-cutover races.
- `R11`–`R13`: Preserve historical restore quarantine without promising automatic reentry; leave Galileo TTL anchor open until policy is established; require explicit guest-family/profile/source variants and reach witnesses.
- `R14`: Remove accepted-placement claims from Control-only hosted selection. Require the prospective integrated ZFS-backed Lilly host or native KVM, with current measured pool and positive real admission before asserting placement/effect properties.

The nine completed gap briefs cover browser identity and admin authority (`G1`), native isolation and Brady policy (`G2`), clone/resize/relocation data and route lineage (`G3`), Lyra tools and Galileo attachment (`G4`), SSH/DNS/editor effects (`G5`), Inception and other optional variants (`G6`), interrupted restore and backward-clock backup publication (`G7`), operations plus diagnostic independence (`G8`), and a same-customer useful create journey (`G9`). Targeted discovery promoted 29 distinct source-grounded properties with evidence; the proposed historical restore reentry candidate is deferred because no activation receipt exists. Each brief records its resulting IDs, independent effect witness and necessary environment in [action-queue.json](action-queue.json). Static variants remain mandatory roster configurations.

## Template and proof boundary

[template-roster.json](template-roster.json) has exactly one entry for each of the current 107 canonical IDs. Each entry records the primary assertion kind and unique planned literal message, proposed hosted template(s), hosted proof limit, native companion and decisive independent witness. It remains a **proof design** with an as-of authored-source snapshot: a literal in source is not a full property result. `hosted_templates: []` means a current native-only acceptance target, not a silent hosted pass. All 32 gap additions are included. The currently staged `control-core` profile selects only its named Control commands and dependencies; unselected authored modules do not become run evidence. Restage changed commands and freeze the exact manifest before any hosted result can be attributed to a row.

The [deployment topology](../deployment-topology.md) currently describes a Control core and standalone TCG storage router as separate focused configurations. Source tracing requires an additional **integrated real inner-ZFS-backed Lilly host** before accepted placement. The roster uses prospective `integrated-zfs-host`, `integrated-zfs-guest` and `integrated-zfs-satellite` labels to keep those branches unexercised until built. `control` remains a protocol/authority refusal template; `storage` remains a standalone router mechanism. Full NixOS closure/migrator/secret upgrades and two-host ZFS relocation currently belong to `native-kvm` acceptance outside hosted Compose. Guest TCG covers software-emulated boot/bytes only. The proposed `AlwaysOrUnreachable` and `Sometimes` support semantics are explicit in the roster; a test template must fail or report unexercised when its required effect observer is unavailable.

Implementation order follows the independent-oracle boundary: build source-pinned images and SDK declaration/evaluation smoke; construct typed append-only attempt/effect ledgers and authenticated Control/origin peers; build and measure the integrated ZFS-backed host before accepted placement; boot and measure guest/storage TCG; run real focused baselines; execute native KVM acceptance with current-run receipts; only then consider targeted mutants. A requested fault is not an observed branch. The total remote ceiling remains `5N`, but `N` is **not frozen** until the final catalog, actual assertion scan and selected executable roster are reconciled. No mutant should run before its matching baseline and oracle are green.

## Priority and selection

The gap pass adds 24 P0 rows among 32 additions, yielding 74 P0 rows among 107 properties. P0 denotes potential product impact, not that a template or independent oracle is ready. Start selected campaigns only after their physical prerequisites and real positive controls pass; the 107-row roster records the full claim and any narrower hosted support. In particular, `authoritative-dns-follows-current-placement` needs a native two-Lilly destination-effect witness for its full claim, while hosted `access` can check DNS packets only. `authenticated-create-to-retained-guest-file` requires a healed-restart reread `Reachable` and a designated per-attempt terminal ledger in addition to its safety `Always`.

## Remaining uncertainty and policy

- Historical backup restore has an isolated/quarantined target in source and an explicit UID/sequence reconciliation limit. No inspected operator activation receipt establishes a safe return to serving authority. Keep the negative quarantine oracle; a later activation drill needs a separately defined receipt (`B1`).
- Galileo’s 2-second grant and synchronous accounting wait can be observed against first upstream effect, but the intended TTL anchor is not established by the inspected code/decision trail. Do not label the timing branch a defect before resolving this policy (`B2`).
- Tenant fault enablement, hosted persistence, TCG boot/pressure budgets, exact 4,096-worker and 1,025-Git-attempt cost, and fully faithful fault seams remain measured implementation questions. Source comments, existing tests, scoped native fixture repair and local passes do not substitute for a hosted baseline or full native acceptance receipt.

## Assumptions

- Repository-only source scope and the pinned commit remain the research baseline; official Antithesis references in lens reports establish SDK semantics only.
- No accepted ADR, runtime behavior, configuration, protocol or HLDD content changes in this synthesis. Harness implementation or new documented verification evidence will require its own architecture, contracts and HLDD assessment.

## Open Questions

- Resolve the two genuine policy questions above while continuing source-grounded fixture and oracle work.
- Build and execute the selected topology and oracles before interpreting any research assertion as passing verification.


## New property disposition

The fresh gap audit added `bootstrap-setup-complete-single-owner`, a process-level join absent from the prior catalog. It covers marker cardinality, probe ordering, and post-marker owner liveness; profile-specific readiness properties remain complementary. Hosted process-lifetime evidence and profile quiet intervals remain open questions.
