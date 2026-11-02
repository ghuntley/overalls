---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Wildcard evaluation of the property portfolio

> **Snapshot note (2026-10-13):** This cold lens evaluated the initial 75-property catalog and its then-current zero-callsite scan. The later shared-worktree [assertion rescan](../existing-assertions.md) found 18 startup/bootstrap/Control callsites, two partially instrumenting Control catalog properties. The final [synthesis](synthesis.md) records the 104-property result and dispositions.

## Summary and scope

This is a fresh evaluation of the 75 canonical, unimplemented properties in
[`property-catalog.md`](../property-catalog.md), the complete
[`sut-analysis.md`](../sut-analysis.md),
[`deployment-topology.md`](../deployment-topology.md), and
[`existing-assertions.md`](../existing-assertions.md). Per-property evidence and
the discovery reports were consulted where a concern required source detail.
The other evaluation lenses ask whether properties fit Antithesis, whether the
portfolio is balanced, and whether its oracles and topology are implementable.
This pass questions the assumed customer and recovery journeys that connect
otherwise well-specified component properties. Repository evidence only was
authorized. The Antithesis research skill supplied the evaluation method; no
external system claim or hosted result is used below.

The portfolio has unusually clear distinctions between a committed intent, a
transport acknowledgement, physical execution, guest effect, and independent
receipt. That prevents several false positive oracles. Its main remaining risk
is *composition*: separate focused templates can pass every local assertion
while a real user still cannot sign in, reach a new machine, retain data through
a copy, or recover a valid point. The following concerns identify concrete
histories and witnesses. They are research findings, not claims of defects.

## Concerns

### 1. The catalog starts after browser authority already exists

**Scope:** Catalog-wide customer-entry perspective. **Properties involved:**
`current-membership-gates-new-private-web`,
`guest-identity-never-transfers-on-email-reuse`,
`marshall-admission-atomic-allocation`, and
`guest-ready-does-not-claim-workspace-checkout` cover later pieces; none covers
the transition from a real magic-link visit, through MFA and remembered login,
to the first authorized guest action. The catalog has no property for magic-link
consumption or copied remembered-cookie revocation across Marshall replicas.

**Evidence:** The product-context discovery identifies the actual sequence and
its different proof points
([`focus-10-product-context.md`](../discovery/focus-10-product-context.md),
sections 1–3). The link GET renders a CSRF-protected POST without consuming the
token (`marshall/lib/marshall_web/automatic_magic_sign_in_live.ex:7-10,29-33`);
the callback routes incomplete MFA before a launch resume
(`marshall/lib/marshall_web/controllers/auth_controller.ex:23-41`). ADR-0123
requires remembered exchange/revocation serialization. The current
`access` template selects Audi/Porsche but names neither a browser login flow nor
an independently logged local SMTP fixture. Its gateway refusal may therefore
be reached with a pre-seeded identity while the real path to that identity is
untested. `current-membership-gates-new-private-web` checks role withdrawal for
a private request, which is different from global login revocation or a copied
remembered credential on another Marshall process.

**Suggested action:** Research a browser-authority history using two Marshall
replicas, a fixed local SMTP accept log, one controlled token and two copied
browser sessions. Preview GET must leave the token unused; a real POST/MFA
transition must issue usable authority once; after committed sign-out/global
revocation/retirement, neither an old mounted session nor a fresh request on
the second replica may cause a guest nonce or domain mutation. Lost SMTP ACK
must not be treated as guaranteed inbox delivery or exactly-once email. Split
positive journey and post-revocation safety assertions if one oracle would
blur their linearization points. A pre-seeded login fixture remains useful for
focused gateway tests, but cannot satisfy this customer-entry question.

### 2. Physical copy and route usefulness are not implied by safe handoff

**Scope:** Cross-layer customer data journey. **Properties involved:**
`source-stop-after-committed-placement-holds`,
`relocation-handoff-one-current-execution`,
`cancelled-relocation-restores-after-revocation`,
`delete-release-follows-physical-retirement`, and
`stop-retains-disk-until-restart` protect custody and authority, but do not
require a clone to contain the correct independent bytes, survive divergent
source writes/deletion, or become reachable through its intended route. Resize
has only capacity-hold coverage in
`marshall-admission-measured-physical-capacity`; it has no property for retained
guest bytes after disk growth or CPU/RAM change.

**Evidence:** The product-context report's section 6 proposes per-drive hashes,
source/destination GUIDs, independent reads, divergent writes, and source
deletion as the meaningful copy history. Section 7 notes that moving placement
does not by itself establish fresh DNS or successful SSH/HTTPS at the
destination. ADR-0155's accepted stopped-only sequence requires one full stream,
fenced handoff, destination readiness, then source cleanup
(`docs/architecture/decisions/0155-stopped-only-relocation.md:43-62`). The
catalog's handoff property checks one current placement/epoch and one outbox;
its own evidence asks for both VMMs, not destination file content or the user's
access route. The topology explicitly places complete transfer/relocation in a
two-Lilly native campaign; a single hosted `control-core` emulator receipt
cannot close this issue.

**Suggested action:** Add a native or explicitly scoped real-storage journey:
write distinct incompressible sentinels on every source drive, clone, mutate
source and copy independently, delete the source, and read the copy through its
authorized guest path. For relocation, read the same bytes through new DNS and
SSH/HTTPS, while old-source ingress refuses, after destination readiness and
before source cleanup. For resize, compare pre/post guest bytes and actual disk
size. Name the exact known content and route witnesses. These histories can
share setup but must not turn a stopped-only full copy into an assumed live
pre-copy guarantee.

### 3. No property makes an acknowledged create useful to the same customer

**Scope:** Catalog-wide composition across focused templates. **Properties
involved:** `marshall-admission-atomic-allocation`,
`lilly-receipt-survives-control-loss`,
`guest-readiness-binds-current-physical-boot`,
`terminal-create-reply-loss-one-pty`, and
`upgrade-preserves-owned-guests` each prove a different step. None states that
one authenticated customer's accepted create, after finite faults heal, reaches
a real shell/editor that can write a file and read it after a restart. The
catalog's liveness assertions are local: `lilly-finite-obstruction-recovery-progress`
can complete a physical operation, and terminal progress can deliver bytes, but
they need not identify the same VM, boot, account, and durable file.

**Evidence:** The SUT analysis explicitly ranks usable create, terminal and
personal editor continuity as user priorities, with public acknowledgements
paired to independent guest bytes. Product-context section 2 says “Machine
requested” is weaker than a usable shell. The topology divides `control-core`,
`access`, and `guest-journey` into focused templates, and permits gateway-only
refusals without a guest. That division is sensible for search cost, yet passing
their separate local oracles would not prove the end-to-end sequence. In
particular, `guest-ready-does-not-claim-workspace-checkout` correctly separates
VM and checkout readiness; neither state establishes an authorized customer
read/write operation.

**Suggested action:** Retain focused templates and define at least one bounded
composed progress witness on `guest-journey`: preserve request key, user UUID,
GuestAccount UID, VM/placement/boot identity, and sentinel hash in a workload
ledger; lose an admission or Control reply, heal faults, then use actual
authenticated terminal or SSH to write and reread the file; restart Lilly or
the guest as the chosen variant and reread it again. Record the different
admission, ready, shell and persistence milestones. A browser editor variant
should require real saved bytes and personal origin when that capability is
selected. The conditional progress deadline must be measured, not invented.
This is a search scenario and a distinct customer-level assertion, not a claim
that all 75 properties need one giant Compose graph.

### 4. Backward wall-clock movement can create a backup that poisons retention

**Scope:** Specific recovery-history interaction. **Properties involved:**
`backup-retained-manifest-closure` verifies components of a retained complete
manifest, and `backup-time-skew-never-activates-historical-authority` verifies
quarantine of component time skew. Neither requires a *newly published* complete
manifest to pass the same temporal schema that retention will later apply.

**Evidence:** Backup runtime samples start and completion wall time separately,
constructs a complete manifest, uploads it, marks the journal completed, and
only then invokes retention (`nix/domains/system/backups/runtime.py:208-225`). The
retention validator requires `started_at <= completed_at` and validates every
manifest before forgetting (`nix/domains/system/backups/restic.py:239-242,272-274`).
The assumptions discovery documents an isolated modeled start=2000,
completion=1000 counterexample to the schema, while explicitly saying that
full clock-step/Restic/native execution has not run
([`focus-11-assumptions.md`](../discovery/focus-11-assumptions.md), A12).
This is a source-grounded hypothesis about the publication boundary, not an
established backup defect. It differs from a sequentially captured but
well-formed manifest, which may legitimately represent multiple times.

**Suggested action:** Investigate a native or appropriately controlled
wall-clock-step history with real Restic: start capture, step the producer clock
backward before completion, and check every newly advertised complete point
against the repository's own validator. Then run a later normal backup and
retention; the malformed earlier point must not prevent retention of valid
points or cause deletion of referenced snapshots. If platform clock faults are
unavailable, use a typed native fault seam that preserves actual runtime and
Restic paths, labeling that scope. A deterministic schema test alone would
confirm parser behavior but not the publication ordering under interruption.

### 5. Historical restore quarantine is covered; successful reentry is a policy question

**Scope:** Cross-cutting boundary and claim limit, chiefly
`backup-time-skew-never-activates-historical-authority` with
`guest-identity-never-transfers-on-email-reuse` and
`store-v3-host-binding-survives-upgrade`. The existing backup property correctly
refuses to turn a complete mixed-time recovery graph into current authority.
The phrase “until historical authority and guest identity reservations are
explicitly reconciled” can, however, be read as an eventual successful
activation promise. No catalog property defines a tested safe transition from
the quarantined restored DB/disk/host tuple back to serving authority.

**Evidence:** The property evidence cites ADR-0070's isolated recovery target
and ADR-0158's explicit limitation: an older database alongside newer retained
disks cannot establish safe UID reuse until reservations and sequence are
reconciled. It says no automatic activation command was found. The topology
keeps physical HA and cross-host restore outside the hosted claim. The important
identity axes are independent: restored DB sequence and User/GuestAccount UUID,
retained guest UID/home and disk GUID, Lilly host binding, current execution
epoch, and live fleet endpoint ownership. A locally valid Restic graph cannot
settle any of those axes alone.

**Suggested action:** Preserve the negative quarantine oracle, including old
endpoint and UID-allocation refusal, and label any staged activation drill as
a separate proposed workflow with a named reconciliation receipt. If product
policy does not yet define that receipt, do not imply liveness or promise that
the backup becomes executable. This is also a useful boundary for fault
campaigns that create an account or guest between component captures.

## Passes

- The portfolio explicitly separates request keys, logical generation,
  execution epoch, physical boot, and GuestAccount UUID/UID. In particular,
  `continuing-boot-advances-generation-without-second-boot` and
  `guest-readiness-binds-current-physical-boot` avoid treating a new generation
  as a new boot.
- `guest-identity-never-transfers-on-email-reuse` includes a retained old home
  inside a survivor-owned shared VM and old login/editor refusal. It does not
  mistake separate personal homes for isolation from another already authorized
  shared-VM writer.
- `backup-retained-manifest-closure` and
  `backup-time-skew-never-activates-historical-authority` correctly distinguish
  restorable component bytes from a simultaneous, live fleet state. The
  catalog does not invent a recovery RPO.
- The topology names two Marshall processes over one PostgreSQL primary as an
  application race fixture, not database HA, and distinguishes hosted TCG
  guest/storage evidence from native Firecracker/ZFS/systemd acceptance.

## Uncertainties

- No new hosted baseline or native campaign has run, and the assertion scan
  found zero current SDK callsites. These findings rank hypotheses and property
  omissions; they cannot establish a current SUT failure.
- The smallest browser fixture that can exercise actual MFA, launch resume,
  local SMTP ACK loss and copied cookies across two Marshall replicas remains
  to be designed. Do not silently substitute pre-seeded sessions for this
  particular journey.
- The exact safe reconciliation/activation receipt for historical backup
  restore is absent from the inspected source/decision trail. The portfolio
  should keep this as an open product-policy question.
- Tenant clock-fault availability and current native execution of full
  clone/relocation/storage routes are unverified. A fixture's existence or a
  historical passing record would not close those current evidence limits.

This document changes only research guidance. It changes no architecture,
protocol, implementation, configuration, or documented system behavior.
