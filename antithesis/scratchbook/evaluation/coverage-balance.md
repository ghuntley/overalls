---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Coverage balance evaluation

> **Snapshot note (2026-10-13):** This cold lens evaluated the initial 75-property catalog and its then-current zero-callsite scan. The later shared-worktree [assertion rescan](../existing-assertions.md) found 18 startup/bootstrap/Control callsites, two partially instrumenting Control catalog properties. The final [synthesis](synthesis.md) records the 104-property result and dispositions.

## Scope and method

This is a fresh portfolio evaluation of all 75 canonical rows in
[`property-catalog.md`](../property-catalog.md), read against the complete
[`sut-analysis.md`](../sut-analysis.md),
[`deployment-topology.md`](../deployment-topology.md),
[`existing-assertions.md`](../existing-assertions.md), and
[`property-relationships.md`](../property-relationships.md). The user selected
"Repository only (Recommended)"; no external system references were supplied.
Official Antithesis documentation is permitted for platform mechanics but no
external incident claim is a premise here. The source and native inventories
cited below are repository evidence. The retired harness and its history were
not inputs. Source and ADR contracts are claims to test, not passing results.

The catalog has 64 `Always`, five `AlwaysOrUnreachable`, and six `Sometimes`
primary assertions; several safety rows propose supplementary `Reachable` or
conditional `Sometimes` checks. There is no primary reachability property. It
assigns 50 rows P0 and 25 P1. The fresh assertion scan found zero implemented
Antithesis SDK callsites. The topology is a design, not built images or a hosted
baseline. Existing native test presence and the removal-phase application gates
do not establish a current native campaign or hosted coverage.

## Section-by-section and component balance

| SUT risk area and selected topology | Canonical coverage | Balance assessment |
| --- | --- | --- |
| Marshall admission, PostgreSQL commits, capacity and Control transport in `control-core` | `marshall-admission-*`, `marshall-crash-recovery-budget-and-stale-capacity`, nine `control-*` rows, two host-session/credential rows, lost-hint progress | Strong coverage of request identity, durable allocation, uncertain replies, bounded Control memory and reconnection. Two Marshall containers over one primary are appropriate for application races; they make no database HA claim. |
| Lilly Store/Runtime/actor/journal, native custody and physical boot in `control-core`, `guest-journey`, `storage-router`, native KVM | Ten Lilly/execution/boot properties, `native-utility-descendant-custody`, stop/delete/readiness and progress rows | Strong intent/effect/ACK separation. TCG can check real boot and disk bytes; native KVM remains necessary for Firecracker, cgroups and ZFS ownership. The catalog is less complete for actual resize/clone disk lineage and independent guest isolation. |
| Audi/Porsche private ingress, public SSH/DNS/editor, browser sign-in in `access` and `guest-journey` | Current membership, web lease, stale execution, terminal create/input/backpressure, Porsche wait, GuestAccount custody | Current private-web byte fencing is represented. Browser login/MFA/cookie revocation, SSH key/certificate and DNS route convergence, and personal editor effect/custody have no direct equivalent. A web lease property does not prove these different interfaces. |
| Ziggy, Galileo and Lyra agent/integration effects in focused `upstream` templates | Ziggy spool/replay/accounting, generic lease expiry, Galileo accounting-delay aging | Inference cost custody is well represented. Agent tool effects and the normal named-integration attachment/renewal path are thin; Galileo's one accounting-delay row is a valuable corner but does not cover ordinary effect authorization. |
| Enrico and Brady in `upstream` and `storage-router` | Three Enrico mirror/admission rows; three Brady completeness/headroom/listener rows | Git publication and physical admission are represented. Brady's credential/privacy bypass and pre-NAT attribution/egress policy remain outside those cache-storage checks. Enrico read authorization after revocation is also separate from published-head continuity. |
| Request recorder, trace spool, backup graph in `observability`, `storage-router`, native KVM | Four recorder/spool rows; three backup rows | Durable measurement and retained backup references have good coverage. Diagnostic independence of user progress and interrupted restore-target publication need explicit checks beyond custody of telemetry/manifest references. |
| Update, migration, service roles, host bootstrap in native KVM | Six upgrade/version/readiness rows | Candidate health, migration order and surviving VMMs are represented. Enrollment, secret bundle custody and the guest CLI updater are independent operational boundaries. Native fixture viability is unresolved; current native test presence is not execution. |
| Optional paths: Customer/OSS, Ubuntu/NixOS, Inception, multi-disk, source providers | Source-v2 admission/delivery, identity, workspace rows; scattered generic lifecycle assertions | The portfolio has no explicit recursive Inception property or configuration matrix requiring both guest families, Customer refusals, provider revision cases and multi-disk effects. Template selection must preserve those distinctions. |

This assessment follows the SUT analysis in order: architecture and real
deployment; persistence/uncertain effects; concurrency and native ownership;
protocol/access/user journeys; operations and cross-layer recovery; and each
hosted/TCG/native environment. The relationship file confirms the represented
clusters but does not add missing behavior to the catalog.

## Findings

### 1. Browser identity and administrative authorization are absent

**Scope:** Catalog-wide across Marshall browser authority and public user
journeys. **Properties affected:** no direct row; nearest are
`current-membership-gates-new-private-web`, `control-bound-credential-revalidated`
and `guest-identity-never-transfers-on-email-reuse`.

The SUT analysis calls sign-in/usable authority a user priority, while
[`focus-10-product-context.md`](../discovery/focus-10-product-context.md) §1
identifies distinct magic-link GET versus POST consumption, SMTP uncertainty,
MFA routing, remembered-cookie revocation and cross-replica reads. The concrete
sources are `marshall/lib/marshall/accounts/auth_emails.ex:9-75`,
`marshall/lib/marshall_web/automatic_magic_sign_in_live.ex:7-33`,
`marshall/lib/marshall_web/controllers/auth_controller.ex:23-41`, and
ADR-0123. Existing catalog membership checks begin after a usable browser
identity exists; Control credential rows concern machine/service sockets. Neither
tests that a preview GET leaves a token intact, one POST consumes it, or a copied
remembered cookie cannot authorize a mutation after sign-out/reset/retirement on
another Marshall replica. The same omission reaches Control room admin demotion
and stale-tab mutations (§8 of focus 10). A targeted identity/administrative
history should count stored login and domain effects independently of UI status,
and treat ambiguous SMTP acceptance as unknown, not exactly-once mail.

### 2. Physical guest isolation and egress authority have no direct property

**Scope:** Catalog-wide across Lilly, Audi and Brady; strongest in `native-kvm`
and the TCG `storage-router`. **Properties affected:** nearest are
`stale-local-execution-cannot-forward-guest-bytes`, `brady-cache-complete-publication`
and `brady-cache-physical-headroom-and-leases`.

The guest/native architecture inventory identifies Firecracker jail, cgroup,
namespace, guest UID and actual packet isolation as independent physical claims
([`focus-01-architecture.md`](../discovery/focus-01-architecture.md) §Guest and
native interfaces). The native campaign inventories six actual guest/peer/
protected-network probes and spoof/MAC/VLAN/IPv6 drop counters
([`native-campaign-inventory.md`](../native-campaign-inventory.md) §Actual packet
isolation), while `marshall/priv/hldd/10-services.md:45-70` states Brady must
derive original destination and current guest attribution, bypass private or
credentialed responses, and never open direct web egress on proxy failure.
Three Brady catalog rows test complete public objects, physical headroom and
listener capacity. None tests private/cache-key separation, source-attribution
refusal, forbidden destination/QUIC bypass or the real guest network policy.
`stale-local-execution-*` is a stream-fence property, not a jail/cgroup or packet
isolation witness. A native property needs concrete packets, counters, process
identity and forbidden effect observations; a TCG router may cover interception
and cache policy but cannot establish Firecracker isolation.

### 3. Clone, resize and relocation data lineage are thin relative to impact

**Scope:** Catalog-wide for physical workflow paths. **Properties affected:**
`source-stop-after-committed-placement-holds`,
`cancelled-relocation-restores-after-revocation`,
`relocation-handoff-one-current-execution`, `stop-retains-disk-until-restart`,
and `delete-release-follows-physical-retirement`.

These rows establish preparation order, one authority and cleanup custody.
They do not directly require copied data bytes/GUID lineage, independence after
source deletion, disk-growth preservation, stable guest identity through a
successful move, or destination readiness before source reclamation. The
distinct physical contracts are described by
`marshall/priv/hldd/06-workflows.md:135-162`, ADR-0155 and
[`focus-10-product-context.md`](../discovery/focus-10-product-context.md) §6.
The native inventory maps `zfs-guest-clone`, `zfs-transfer`,
`cloning-fleet` and `relocation-fleet` to distinct component versus composed
evidence. A transfer stream or committed handoff can be correct while the new
guest's retained bytes or old route are wrong. The topology explicitly requires
two Lilly boundaries or native fleet for full relocation and says
`storage-router` is not Lilly's production backing pool. Targeted discovery
should specify independent per-drive sentinel hashes, source/destination GUIDs,
guest reads and physical execution/route witnesses across faulted successful
clone/resize/move histories, including initially stopped sources and cancellation.

### 4. Agent tools and named integrations are underrepresented

**Scope:** Catalog-wide across Marshall Agents, Lyra, Ziggy and Galileo.
**Properties affected:** `ziggy-interrupted-inference-never-reexecutes`,
`ziggy-spool-capacity-before-provider`,
`galileo-accounting-delay-does-not-renew-old-grant`, and
`lease-expiry-independent-of-blocked-renewal` are adjacent but narrower.

The Agents domain stores durable prompt/turn/model/command identity and Lyra
reports `started` before guest tool side effects
(`marshall/priv/hldd/11-agents.md:63-110`, `lyra/src/agent.rs:135`;
[`focus-01-architecture.md`](../discovery/focus-01-architecture.md)
§Inference and agents). A Ziggy provider effect oracle cannot prove that a
guest command or web-search action is not repeated after uncertain start, that
an executor lease is renewed for a long tool, or that revoked CLI approval
refuses a fresh action. Galileo's current attachment, named origin, injected
credential/header and no-retry rule (`galileo/lib/galileo/http.ex:19,94`,
`marshall/priv/hldd/10-services.md:248-263`) are not checked by a property
focused on an aged grant during recorder delay. A realistic local provider and
integration origin can count effects, while a guest-vmm/native path must count
actual tool effects. These should be distinct targets and preconditions, not a
claim that the one Galileo hypothesis proves an existing bug.

### 5. SSH, DNS route convergence and personal editor effects remain a blind spot

**Scope:** Catalog-wide for user access after admission and relocation.
**Properties affected:** `current-membership-gates-new-private-web`,
`expired-web-lease-stops-existing-guest-bytes`,
`guest-identity-never-transfers-on-email-reuse`, and terminal rows are adjacent.

`focus-10-product-context.md` §§5,7 calls for stable strict SSH host identity,
fresh DNS and actual HTTPS/SSH through the destination after relocation, with
stale-source refusal. It also requires an editor workbench, save/search/PTY
effect and correct UID/home across broker/worker crashes, sign-out and stop/start.
The editor authority's one-use code/state exchange and renewable binding are in
`marshall/lib/marshall/editor/authority.ex:80-223`; Audi Origin checking and
broker peer UID/worker ownership are traced in
`focus-01-architecture.md:240-260,336-345`. Current catalog private-web and
GuestAccount rows can pass while an SSH key/certificate is stale, DNS routes to
the old host, or a personal editor opens an origin but cannot save under its
owner. Native campaign inventory lists separate `sharing-surfaces`, editor
family, Audi relocation and SSH-host-certificate fixtures. Targeted properties
should state which route, actor and guest byte/file witness are required; a
gateway refusal-only hosted case cannot establish editor usability.

### 6. Optional recursive and profile-specific deployments need explicit selection

**Scope:** Catalog-wide across `guest-journey`, native KVM and template roster.
**Properties affected:** `source-v2-capability-gates-admission`,
`guest-readiness-binds-current-physical-boot`, and
`guest-identity-never-transfers-on-email-reuse` require environment-specific
instances.

Inception has an embedded verified-TLS PostgreSQL/Marshall and nested
Lilly/KVM/ZFS with separate identities and publication authority
(`nix/domains/artifacts/guest/inception/default.nix:33,100`,
`focus-01-architecture.md:345-358`). No catalog property names that recursive
control-plane boundary. The native inventory separately identifies NixOS and
Ubuntu guest families, Customer/OSS policy, multiple source providers and
revisions, multi-drive clone/backup, and an `inception` check. A generic boot or
source-v2 property should not be marked covered because one OSS/NixOS/default
GitHub path passes. The topology calls for a final property-to-template roster
but has not frozen it. This is a coverage concern about path selection as well
as potential additional invariants: include exact configuration labels and
required reach witnesses before treating optional-path non-execution as success.

### 7. Backup publication is represented; interrupted restore completion is not

**Scope:** Property-specific around recovery graph operations.
**Properties affected:** `backup-retained-manifest-closure`,
`backup-interrupted-cleanup-owned-only`, and
`backup-time-skew-never-activates-historical-authority`.

Those rows test retained component references, cleanup ownership and isolation
of mixed-time authority. `nix/domains/system/backups/runtime.py:328-345` and
`focus-10-product-context.md` §8 identify a different failure boundary:
interrupt an isolated restore after some components were written but before
complete publication. An individually valid retained manifest does not prove
the partial target is refused or that no final restore manifest appears.
The native campaign distinguishes `guest-backups`, `backup-recovery` and cleanup
fixtures, and records that restored read-only bytes are not restored boot or
historical authority reconciliation. A targeted restore result should inspect
the target's publication marker and restored bytes under staged interruption,
without inventing an automatic safe historical activation policy.

### 8. Operational custody and diagnostic independence lack progress witnesses

**Scope:** Catalog-wide operations; lower priority than the direct data/authority
omissions above. **Properties affected:** upgrade/recorder/spool rows are adjacent.

The updater rows cover candidate migration, promotion and caught restoration,
but the guest Lyra binary updater has its own verified artifact, drain and
registration rollback boundary (`lyra/src/update.rs:420-463`,
`focus-10-product-context.md` §8). Host enrollment and atomic secret-bundle
publication are separately inventoried in `native-campaign-inventory.md`
§Installation/operator boundaries and `focus-04-safety.md` §12. These are
operational entry points that cannot be inferred from `lastHealthy` alone.
Likewise, recorder and spool rows conserve diagnostic bytes/tickets but none
asks whether a valid VM command or provider/integration request finishes when
diagnostic custody is down. ADR-0149 and the SUT analysis explicitly separate
diagnostic failure from lifecycle progress. A conditional progress witness
should establish user effect after finite recorder/collector failure with real
authority and restored service dependencies, while preserving unknown
measurement quality.

### 9. Reach and priority distribution need a deliberate final roster

**Scope:** Catalog-wide assertion and selection balance. **Properties affected:**
all selected templates, especially the optional refusal branches in
`execution-v4-refuses-legacy-document`,
`lilly-corrupt-intent-never-becomes-receipt`,
`private-readiness-v1-gates-new-execution`, and
`source-stop-after-committed-placement-holds`.

Six primary `Sometimes` checks provide actual conditional progress, and several
safety rows have supplementary reach/progress proposals. This is better than a
pure-invariant portfolio. Yet zero primary `Reachable` rows and five optional
`AlwaysOrUnreachable` rows mean a selected template can evaluate a correct
vacuous refusal without executing the branch. The topology explicitly forbids
silent template skips and requires a property-to-template roster. Freeze that
roster with a reach witness for each selected rare refusal, finite-fault
restoration for liveness, and an explicit unexercised result when a native/TCG
precondition fails. Fifty of 75 rows are P0. This may be justified by the
authority-heavy system, but the missing browser identity, isolation and data
lineage boundaries show that priority alone does not currently balance actual
user/physical impact. The nine Control rows are individually distinct and
should not be removed merely to improve a count.

## Passes

- The admission/control/Lilly clusters distinguish database commit, delivery
  receipt, physical attempt, current boot, outcome ACK and actual guest effect.
  This avoids treating a timeout as a rejected mutation.
- The six primary liveness properties and supplementary conditional progress
  conditions address lost hints, retained intent, pool sampling and terminal
  neighbors. They condition progress on restored dependencies rather than an
  invented universal deadline.
- Backup, recorder, Ziggy, Enrico and Brady each have more than one property
  covering independent custody, admission or effect boundaries. Enrico's
  receipt retention is correctly finite, and Brady's cache state is disposable.
- The topology separates PostgreSQL/Marshall races, satellite faults, TCG guest
  and router mechanisms, and native KVM acceptance. It correctly refuses to
  promote a software-emulated boot into Firecracker/jail evidence or two
  containers into independent physical hosts.
- Several source-specific edge cases survive deduplication: Galileo's aged
  grant after accounting delay, continued physical boot with newer generation,
  mixed-time backup authority, and terminal PTY kill under backpressure.

## Uncertainties

- No hosted image, baseline, mutation run or current native campaign has run.
  The selected topology, TCG boot budget, native fixture viability and tenant
  fault enablement therefore limit *execution*, not the source-grounded
  importance of the findings. The removal-phase application gates do not
  substitute for these observations.
- The final property-to-template roster is not frozen. I cannot determine from
  the current artifacts whether each optional refusal, guest family, profile,
  source provider and native effect would actually be exercised.
- Source contracts do not establish an automatic historical restore activation
  or a global backup RPO. The backup finding asks for partial-target refusal and
  publication truth, not an unsupported cross-component consistency promise.
- The Galileo aged-grant and Lyra long-tool lease scenarios are hypotheses;
  composed execution is needed to discriminate intended renewal from a defect.
- Native campaign inventory reports a `service-roles` Galileo option evaluation
  failure and stale revision/control-field fixture requirements. These must be
  corrected and rerun before any native pass can support isolation or lifecycle
  claims at this commit.

## Assumptions and open questions

**Assumptions:** This is a research artifact only. The proposed checks use
synthetic identities and local upstream fixtures, and require exact independent
effect witnesses appropriate to each environment. No architecture decision,
runtime contract or handbook behavior is changed by this evaluation.

**Open questions:** Which missing user/native boundaries receive independent
canonical rows versus required variations of existing rows? Which selected
templates can produce real guest/editor/SSH/agent effects without replacing
their authority paths? Which native fixture corrections and exact current-run
receipts will support the physical claims? These decisions belong to synthesis
and implementation; this lens does not categorize or edit the catalog.
