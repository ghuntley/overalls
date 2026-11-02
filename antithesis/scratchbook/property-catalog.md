---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Property catalog

This catalog synthesizes 113 source-grounded candidates into 104 canonical properties. The current as-of [assertion scan](existing-assertions.md) records 164 authored callsites and 30 primary catalog messages; the source is moving and no hosted baseline or mutation result is claimed. Source contracts and ADRs state intended behavior to test; a timeout or lost reply is an unproven effect until independently reconciled.

Each entry gives one primary SDK assertion with a unique literal message. Evidence files retain source paths, independent oracles, value menus, environment limits, and any supplementary branch or progress assertions. P0/P1 and confidence rate importance and source grounding, not passing execution.

## Assumptions

- The user scoped this pass to repository evidence only; external references are empty. Provenance pins the base commit, while the refreshed assertion scan includes uncommitted harness startup/smoke source in this shared worktree.
- Hosted real services and PostgreSQL can test durable control and accounting. Guest bytes, ZFS, native process custody, NixOS activation, and isolation need the specific TCG or native environment named in each evidence file.
- Conditional progress runs require valid authority, available capacity, healed faults, and a measured observation interval; no generic five-second completion target or backup RPO is assumed.

## Open Questions

- Historical restore reentry remains a deferred policy candidate: no operator activation/reconciliation receipt exists in source.
- Which tenant faults and hosted persistence semantics are actually enabled? Resolve per property before claiming coverage.
- What native/TCG fixtures and independent observers are available for guest, ZFS, updater, and inherited-descendant claims?
- What product restore consistency or RPO policy, if any, exists beyond complete sequential component capture?

## Control, credentials, and leases

These properties exercise the control, credentials, and leases boundaries and their failure interleavings.

### audi-authority-request-start-deadline — Audi authority request start deadline

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | accepted Audi leases cannot outlive request-start TTL or change full binding on renewal; late replies expire. |
| **Invariant** | `Always` at grant installation and use; `Reachable` for a refused late reply. Delay response across expiry/revocation. Planned literal SDK message: **"Audi authority never extends beyond request-start TTL or changes its binding"**. |
| **Antithesis Angle** | `Always` at grant installation and use; `Reachable` for a refused late reply. Delay response across expiry/revocation. |
| **Why It Matters** | Late authority replies must not extend private access beyond the issued deadline. |
| **Evidence** | [Source and oracle](properties/audi-authority-request-start-deadline.md); discovery focus 04. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-bind-before-domain-effects — Control bind before domain effects

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | upgrade plus service-matched hello must precede any dispatch or scoped hint. |
| **Invariant** | `Always` on connection/effect ledger; `Reachable` for refused first application request. Planned literal SDK message: **"Control domain effects require the authenticated service hello"**. |
| **Antithesis Angle** | hello deadline, wrong binding and coalesced frames. |
| **Why It Matters** | Unbound traffic must not acquire service-specific domain authority. |
| **Evidence** | [Source and oracle](properties/control-bind-before-domain-effects.md); discovery focus 04. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: authored Control scenario only; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/scenarios.py:149`. Current real Marshall first-frame/Lilly session refusal path; separate client-only pre-welcome send assertion and full service matrix remain missing. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-bound-credential-revalidated — Control bound credential revalidated

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | a previously welcomed socket cannot authorize a new domain effect with a rotated, revoked or expired credential. |
| **Invariant** | `Always` at post-fence effects; `Reachable` for current-credential refusal. Planned literal SDK message: **"Bound control sockets revalidate current credentials before each domain effect"**. |
| **Antithesis Angle** | credential-domain lock with task dispatch and socket loss. |
| **Why It Matters** | A stale authenticated socket must not outlive a committed credential rotation. |
| **Evidence** | [Source and oracle](properties/control-bound-credential-revalidated.md); discovery focus 04. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: authored Control scenario only; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/scenarios.py:246`. Lilly credential rotation through a live old Control socket and durable session oracle; Audi/Porsche/Ziggy/Galileo mutation routes remain outside this authored scenario. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-hint-loss-reconciles-authority — Control hint loss reconciles authority

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / medium / researched; primary unimplemented |
| **Property** | hints never substitute for authority; after finite loss and recovery, real readers reconcile committed state. |
| **Invariant** | `Always` at effect checks plus `Sometimes(reader_reconciled_after_hint_loss)` in a specific restored-fault scenario. Drop/duplicate hints and restart notifier. Planned literal SDK message: **"Control reader reconciles committed authority after lost hint"**. |
| **Antithesis Angle** | `Always` at effect checks plus `Sometimes(reader_reconciled_after_hint_loss)` in a specific restored-fault scenario. Drop/duplicate hints and restart notifier. |
| **Why It Matters** | Hint loss must neither grant authority nor permanently strand committed work. |
| **Evidence** | [Source and oracle](properties/control-hint-loss-reconciles-authority.md); discovery focus 04. |

**Supporting assertion snapshot (2026-10-17):** The harness-only BEAM `Reachable` **"Marshall notifier recovered after losing a host command hint"** at `marshall/lib/marshall/control/hints/relay.ex:37` marks an observed notifier `:isolated` to connected transition followed by local `resync_local`. It does not observe a reader's full re-read, a committed authority change or reconciliation, so the `Sometimes` primary **"Control reader reconciles committed authority after lost hint"** and the effect-boundary `Always` remain unimplemented. This records source presence, not a hosted result.

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-inflight-limit-and-retirement — Control request memory

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Pending Control calls never exceed the validated welcome window, and busy calls create no outbound request frame. |
| **Invariant** | Always compares pending calls with negotiated limit and proxy-observed wire IDs. Planned literal SDK message: **"control client pending requests fit negotiated window and busy calls send no frame"**. |
| **Antithesis Angle** | Held replies, timeouts, half-close and reconnect with a server task committing after reply loss. |
| **Why It Matters** | Bounds connection memory and prevents hidden replay under saturation. |
| **Evidence** | [Source and oracle](properties/control-inflight-limit-and-retirement.md); discovery focus 05. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/bounds.py:44`. Real BEAM Control client against an independent controlled WebSocket frame ledger; Marshall domain effects are outside the peer fixture. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-no-hidden-redelivery — Control no hidden redelivery

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | one explicit transport call sends at most one request frame; reconnect does not replay an unproven call. |
| **Invariant** | `Always` on independent call/wire ledger. Planned literal SDK message: **"Control transport never redelivers an uncertain application call"**. |
| **Antithesis Angle** | response after durable commit, reconnect and observe a fresh sentinel call. |
| **Why It Matters** | Hidden replay of an unproven call can repeat a committed physical effect. |
| **Evidence** | [Source and oracle](properties/control-no-hidden-redelivery.md); discovery focus 04. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/delivery.py:126`. Real BEAM Control client with independent frame ledger; the separate terminal Marshall SQL receipt command (`control_delivery` singleton) is selected in control-core since 2026-10-17 but unexecuted in hosted Compose. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-pending-response-retirement — Control pending response retirement

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | only a live wire ID settles its caller once, and retired replies cannot settle successor work. |
| **Invariant** | `Always` against peer ID/caller ledger; `Reachable` for late response ignored while fresh work completes. Planned literal SDK message: **"Control responses settle only their live pending request"**. |
| **Antithesis Angle** | deadline, close and reordered replies. |
| **Why It Matters** | A late reply must not settle a different operation after reconnect. |
| **Evidence** | [Source and oracle](properties/control-pending-response-retirement.md); discovery focus 04. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/pending.py:42`. Real BEAM Control client and independent held/late response peer ledger; no hosted execution recorded. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-service-dispatch-closed — Control service dispatch closed

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | a valid bound socket cannot use another service's op or invalid domain document to cause an effect. |
| **Invariant** | `Always` on independently inventoried effects after wrong-prefix, version and body probes; race valid and invalid calls. Planned literal SDK message: **"Control rejects cross-service and invalid documents before domain effects"**. |
| **Antithesis Angle** | `Always` on independently inventoried effects after wrong-prefix, version and body probes; race valid and invalid calls. |
| **Why It Matters** | A bound service cannot borrow another service’s operation authority. |
| **Evidence** | [Source and oracle](properties/control-service-dispatch-closed.md); discovery focus 04. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-17):** Primary `always` message is present at `antithesis/workload/control/dispatch.py:195`. A Lilly-bound socket sends one valid foreign-service document per invocation (Audi `ssh_open`, Porsche `commands`, Ziggy v2 `agent_next` or Galileo `authorize`, each accepted by its own decoder) plus drawn invalid Lilly documents. The verdict requires a correlated refusal, an absent fresh Lilly session row and unchanged read-only counts of `ingress_sessions`, `ssh_requests`, claimed `agent_model_calls` and `galileo_peer_tokens`; a lost reply without an effect stays unknown. Scope: the bound service is Lilly only; Audi, Porsche, Ziggy and Galileo sockets, native effects and external upstreams are not bound or observed. The `control_dispatch` singleton is in the staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### control-version-refusal-remains-terminal — Control version refusal remains terminal

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | 426/4001 stops the Control owner with a distinct version class, including pending calls; wrong service-document version remains a request refusal. |
| **Invariant** | `Always` on adapter class and transport handshake count; separate `Always` for document refusal; `Sometimes(recoverable_socket_reestablished)` only after a healthy recoverable loss. Planned literal SDK message: **"Control transport version refusal stops its owner without losing its class"**. |
| **Antithesis Angle** | `Always` on adapter class and transport handshake count; separate `Always` for document refusal; `Sometimes(recoverable_socket_reestablished)` only after a healthy recoverable loss. |
| **Why It Matters** | Unsupported peers must fail distinctly so owners do not silently retry incompatible authority. |
| **Evidence** | [Source and oracle](properties/control-version-refusal-remains-terminal.md); discovery focus 04, 10. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-17):** Primary `always` message is present at `antithesis/workload/control/version_refusal.py:54`. `control/serial_driver_version_refusal.py` runs the real shared `OverallsProtocol.Control.Client` against the loopback peer's `version_refusal` mode: after welcome the peer holds one observed request, sends close 4001, then counts TCP accepts for 5,000 ms (beyond the 4,000 ms backoff ceiling). The verdict requires the `unsupported_version` disconnect class, the held call retired as `unproven`, retained status, zero handshakes and an immediate `disconnected` refusal for a new call. Scope: 4001 on the shared client only; the bounded quiet window is not proof of no later retry, and Marshall's 4001/426 emission, service-adapter owner stop and the recoverable reconnect `Sometimes` are not observed here (426 pre-upgrade refusal is the separate outer-version support check). It is in the staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R9`: Use distinct command/branch IDs for permanent 426/4001 refusal and recoverable outage reconnect. A healthy reconnect does not satisfy permanent-refusal coverage. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### galileo-accounting-delay-does-not-renew-old-grant — Observer wait and grant age

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / researched; primary unimplemented |
| **Property** | A synchronous accounting wait cannot make an already aged Galileo authorization usable for a new upstream effect without successful current renewal. |
| **Invariant** | `Always` **"Galileo accounting delay cannot start an upstream effect on an aged grant"** compares grant age, renewal result and first real upstream accept/read; each new effect must have live authority. |
| **Antithesis Angle** | Stall or crash the independent request recorder after Marshall grants the 2-second TTL, revoke authority during the stall, then release Galileo to race lease creation and upstream connection. |
| **Why It Matters** | An observability dependency could unintentionally extend execution authority. |
| **Evidence** | [Source and oracle](properties/galileo-accounting-delay-does-not-renew-old-grant.md); discovery focus 11. |

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: original grant/renewal order and controlled integration first accept/read; current real placement/execution authority required. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R12`: Record original grant return, elapsed accounting wait, renewal and first upstream accept. The intended TTL anchor remains a human policy question; an observed aged branch is not automatically a defect. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Is grant TTL anchored at Marshall response or deliberately at later upstream lease creation? `(needs human input)`

### host-credential-rotation-fences-old-socket — Rotation fences live Control sockets

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | After host credential rotation/revocation commits, an already-open socket carrying the archived token cannot make a new domain request effective. |
| **Invariant** | `Always` **"Committed host credential rotation fences old Control request authority"** checks effect rows after the host-lock order is known; a request serialized before rotation may commit first. |
| **Antithesis Angle** | Race old socket request tasks against rotation on separate Marshall replicas, then reconnect old and new credentials. |
| **Why It Matters** | Upgrade-time authentication alone would leave a stale transport with live host power. |
| **Evidence** | [Source and oracle](properties/host-credential-rotation-fences-old-socket.md); discovery focus 07. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/host_sessions.py:348`. Current Lilly old-socket/new-credential route only; other services and physical effects are separate. It is in the staged control-core selection as a terminal singleton template (selected 2026-10-17). This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### host-session-successor-fences-old-exchanges — Successor host session fence

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Once a successor host session commits, an old nonce/session and connection epoch cannot add outcomes, refresh reports or receive new executable commands through another Marshall replica. |
| **Invariant** | `Always` **"Superseded Lilly host session cannot change exchange state or dispatch work"** compares committed rows and host effect IDs after the successor's linearization point; safety must hold at every sampled stale exchange. |
| **Antithesis Angle** | Race session opens and stale replay across two independently pooled Marshall processes, losing replies on either side of commit. |
| **Why It Matters** | An old host connection could resurrect stale command authority. |
| **Evidence** | [Source and oracle](properties/host-session-successor-fences-old-exchanges.md); discovery focus 07. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/host_sessions.py:272`. Current Lilly host-session/successor route only; physical guest/execution authority is separate. It is in the staged control-core selection as a terminal singleton template (selected 2026-10-17). This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### lease-expiry-independent-of-blocked-renewal — Deadline fences service effects

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / researched; primary unimplemented |
| **Property** | Audi, Ziggy and Galileo admit no new downstream effect after their lease expires without current renewal. |
| **Invariant** | `Always` **"Expired service lease cannot forward a new upstream effect"** at independently witnessed effect admission. |
| **Antithesis Angle** | Block renewal and transport simultaneously, then deliver a late renewal or revocation across owner/watchdog races. |
| **Why It Matters** | Transport backpressure must not extend revoked authority into provider, integration or guest access. |
| **Evidence** | [Source and oracle](properties/lease-expiry-independent-of-blocked-renewal.md); discovery focus 02. |

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: Audi post-deadline guest nonce plus Ziggy/Galileo first upstream accept, each with own grant clock and renewal; current real placement/execution authority required. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which irreversible admission boundary can each service expose independently of bytes buffered before expiry? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### lost-host-hint-eventually-delivers-command — Lost hint recovery

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | Given a committed host command, finite notifier/Control isolation and available host/database, Lilly eventually accepts and physically resolves that exact command after healing. |
| **Invariant** | `Sometimes(condition)` **"Committed host command reached Lilly after notifier isolation healed"** requires the semantic accepted-command plus physical-result condition at least once; it does not equate a resync event with progress. |
| **Antithesis Angle** | Drop the cross-replica hint during notifier isolation and allow relay resync and Lilly's periodic exchange to race after healing. |
| **Why It Matters** | Hints are latency aids; losing one must not strand durable work. |
| **Evidence** | [Source and oracle](properties/lost-host-hint-eventually-delivers-command.md); discovery focus 07. |

**Supporting assertion snapshot (2026-10-17):** A harness-only BEAM `Reachable` **"Marshall notifier recovered after losing a host command hint"** is authored at `marshall/lib/marshall/control/hints/relay.ex:37`, behind the `ANTITHESIS_HARNESS` compile guard and declared through `declare_catalog`. It fires on every observed Oban notifier `:isolated` to `:solitary`/`:clustered` transition, which is the window in which hints can be dropped; it does not observe that a host command hint was actually lost, that any command was committed, or that Lilly accepted or physically resolved it. It is a search anchor only. The `Sometimes` primary below remains unimplemented, and no workload cuts only the notifier while a committed command and Lilly witness are tracked. This records source presence, not a hosted result.

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can one Marshall notifier be isolated independently of its Repo and the other replica? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### porsche-wait-never-resubmits-mutation — Poll without second mutation

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A Porsche CLI invocation submits one mutation and waits through read-only, receipt-correlated polls; eligible transient polling can still reach a matching terminal receipt. |
| **Invariant** | `Always` **"Porsche wait submits one mutation and only polls its receipt"** on ingress command history; conditional `Sometimes(matching_terminal_receipt_seen)` has its own message and finite tail precondition. |
| **Antithesis Angle** | Lose admission/poll replies, inject transient errors and mismatched receipt IDs. |
| **Why It Matters** | Automatic resubmission could repeat physical effects; premature failure hides a still-running command. |
| **Evidence** | [Source and oracle](properties/porsche-wait-never-resubmits-mutation.md); discovery focus 09. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: single CLI mutation ingress ID and exact terminal receipt; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a selected physical command reach a matching terminal receipt before the CLI timeout in hosted TCG? `(partial: 120-second wait is source-backed; real TCG progress needs measured tail)`

## Recovery and independent custody

These properties exercise the recovery and independent custody boundaries and their failure interleavings.

### backup-interrupted-cleanup-owned-only — Physical cleanup authorization

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Backup recovery destroys only positively matched owned snapshots and retains uncertainty. |
| **Invariant** | `Always(destroy matches nonce/GUID/local marker; unavailable inspection preserves journal)`. Planned literal SDK message: **"Backup recovery destroys only positively owned snapshots and retains uncertain cleanup"**. |
| **Antithesis Angle** | Snapshot created before GUID receipt, uncertain destroy/unmount and same-name foreign dataset/snapshot. |
| **Why It Matters** | Prevents cleanup from deleting unrelated data or abandoning still-owned physical resources. |
| **Evidence** | [Source and oracle](properties/backup-interrupted-cleanup-owned-only.md); discovery focus 03. |

**Proof boundary:** Draft selection: `storage`. hosted-restic-or-tcg-zfs-limited; independent witness: owned ZFS GUID/marker, independent Restic enumeration/isolated restore hash and fenced target. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can hosted storage observation stay independent through pool inspection faults? `(partial: native source/proof histories exist; hosted split-view fault unproven)`

### backup-retained-manifest-closure — Retained restore graph

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / authored primary; hosted unexecuted; scope partial |
| **Property** | Each component referenced by a retained complete backup manifest remains present and restorable to the workload's recorded sentinel hash. |
| **Invariant** | `Always` **"Retained backup manifest references restorable component snapshots"** after settled publication/retention, verified by independent Restic list and isolated restore. |
| **Antithesis Angle** | Interrupt component capture, manifest publication and batched forget while prior retained points remain. |
| **Why It Matters** | A manifest with missing components creates a false recovery point. |
| **Evidence** | [Source and oracle](properties/backup-retained-manifest-closure.md); discovery focus 01, 03. |

**Proof boundary:** Draft selection: `storage`. hosted-restic-or-tcg-zfs-limited; independent witness: owned ZFS GUID/marker, independent Restic enumeration/isolated restore hash and fenced target. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `backup-restic` selects the five `backup` commands with `compose.backup.yaml`, which gives each command a disposable encrypted Restic file repository on a dedicated private named volume. Bootstrap requires the production operator, pinned Restic and a real probe repository that initializes and enumerates empty there. A local file backend is deliberate: the production operator returns one failure status for repository unavailability and validator refusal, so a network-attached repository would make unavailable reads look like refusals. This profile exercises no ZFS, host capture, S3 or live recovery target and has no hosted run or baseline yet.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/backup/scenarios.py:73`. Real Restic IDs, production prune/inspect and independent per-reference restore hashes; selected guest/ZFS capture completeness is separate. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which disposable guest-disk sentinel can be restored independently? `(partial: isolated host/database sentinels already exist)`

### backup-time-skew-never-activates-historical-authority — Mixed-time recovery graph

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / medium / researched; primary unimplemented |
| **Property** | A complete backup whose guest, database and host components represent different moments remains isolated until historical authority and guest identity reservations are explicitly reconciled. |
| **Invariant** | `Always` **"Restored mixed-time backup remains isolated from live fleet authority"** checks restore target, live endpoints/processes and UID allocation effects, not the manifest's `complete` flag alone. |
| **Antithesis Angle** | Create/relocate/delete guests and allocate a new guest UID between sequential captures, then restore an individually valid manifest beside the live fleet. |
| **Why It Matters** | A locally valid restore graph can still be unsafe as immediate current authority. |
| **Evidence** | [Source and oracle](properties/backup-time-skew-never-activates-historical-authority.md); discovery focus 11. |

**Proof boundary:** Draft selection: `storage`. hosted-restic-or-tcg-zfs-limited; independent witness: owned ZFS GUID/marker, independent Restic enumeration/isolated restore hash and fenced target. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R11`: The current safety claim is quarantine of a mixed-time restored graph. No later serving activation is promised until a separate reconciliation receipt binds database sequence, UID/home, disk GUID, Store host binding, execution epoch and live endpoints. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### request-recorder-capacity-does-not-admit-phantom-work — Measurement slots

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Saturated recorder admission yields unrecorded coverage, never an invented durable ticket or clean interval, while application effects retain their own authority. |
| **Invariant** | Always checks durable pending count, ticket IDs and quality marker against 4096 slots and effect witnesses. Planned literal SDK message: **"request recorder saturation cannot fabricate admitted tickets or a clean quality interval"**. |
| **Antithesis Angle** | Hold 4096 workers, attempt one more, lose replies and retire a worker. |
| **Why It Matters** | Measurement saturation must be visible and cannot fabricate SLO coverage. |
| **Evidence** | [Source and oracle](properties/request-recorder-capacity-does-not-admit-phantom-work.md); discovery focus 05. |

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:145`. Real Producer 4096/4097 admission boundary and fsynced fixture effect; exact UID/systemd cgroup and hosted/native saturation run remain absent. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R8`: Keep exact production-capacity saturation in a measured campaign. Use lower-cost bounded replay or refusal histories for routine search; do not claim the full 4,096-worker or 1,025-receipt cap without reaching it. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Is a full 4096-worker hosted run feasible without unrelated OS limits? `(partial: exact Rust bound tested; BEAM/hosted resource envelope unmeasured)`
- Can hosted deployment preserve the native fixture's exact systemd producer identity? `(partial: native two-unit fixture exists; hosted equivalent unproven)`

### request-recorder-restart-conserves-custody — Independent recorder recovery

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Recorder restart preserves lifetime and settles admitted work once only after valid finish, proven producer death or expiry. |
| **Invariant** | `Always(no fabricated death, duration or duplicate settlement; monotonic identity/counters)`. Planned literal SDK message: **"Request recorder recovery conserves admissions without inventing producer death"**. |
| **Antithesis Angle** | Admit/Finish reply loss, recorder death with producer alive, proc/pidfd uncertainty and checkpoint poison. |
| **Why It Matters** | Separates measurement outage from producer death and conserves durable numeric custody. |
| **Evidence** | [Source and oracle](properties/request-recorder-restart-conserves-custody.md); discovery focus 03. |

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:219`. Checkpoint conservation and conditional socket-inode restart witness; independent forced-restart orchestration and shared /proc producer identity remain incomplete. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which hosted topology preserves exact systemd producer authentication while faulting parties independently? `(partial: native NixOS fixture passes this shape; hosted equivalent unproven)`

### trace-archive-ack-loss-preserves-replay — SQLite observation archive

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Accepted trace bytes/digest/original expiry survive intake/export ACK loss and archive replay until original expiry. |
| **Invariant** | `Always(unexpired accepted custody remains immutable)`; duplicate export is permitted. Planned literal SDK message: **"Trace archive recovery preserves accepted immutable custody through acknowledgment loss"**. |
| **Antithesis Angle** | FULL WAL commit/reply windows, Collector response loss, quota poison and interrupted 128-row replay chunks. |
| **Why It Matters** | Retains independent observability without making diagnostic delivery business authority. |
| **Evidence** | [Source and oracle](properties/trace-archive-ack-loss-preserves-replay.md); discovery focus 03. |

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:269`. Reviewed OTLP, SQLite body/digest, discarded intake ACK/retry, and conditional production replay; no hosted outage/replay or native identity result. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which hosted fault reaches actual SQLite commit uncertainty beyond process restart? `(partial: SIGKILL/reopen and ACK replay covered; media fault unproven)`

### trace-spool-physical-quota-with-retained-custody — Archive saturation

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / medium-high / authored primary; hosted unexecuted; scope partial |
| **Property** | Quota or ENOSPC refusal cannot erase unexpired accepted trace bytes, including exported batches; exhausted backing stops new ACKs until recovery. |
| **Invariant** | Always compares independently reread SQLite digests and physical ENOSPC history with admitted IDs. Planned literal SDK message: **"trace spool saturation preserves accepted archive bytes and refuses on exhausted backing"**. |
| **Antithesis Angle** | Fill pending and retained quotas, exporter ACK/replay, WAL checkpoint, restart and disk exhaustion. |
| **Why It Matters** | Keeps trace custody under storage pressure without gating business progress. |
| **Evidence** | [Source and oracle](properties/trace-spool-physical-quota-with-retained-custody.md); discovery focus 05. |

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:494`. Retained SQLite bytes, logical 429 and guarded physical ENOSPC branch; dedicated bounded archive filesystem and hosted/native exhaustion run remain absent. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What exact transient SQLite/WAL footprint envelope applies? `(partial: one 8 MiB native run measured below 12 MiB; no general bound)`
- Can hosted storage enforce recoverable real ENOSPC? `(partial: no hosted trace-spool ENOSPC fixture found)`

## External effects and caches

These properties exercise the external effects and caches boundaries and their failure interleavings.

### brady-cache-complete-publication — Complete cache hits

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | Every hit for a controlled cache key returns one complete observed origin object; incomplete or aborted writes never become hits. |
| **Invariant** | `Always` **"Brady cache hit serves a complete committed object"** on every hit, comparing independent origin bytes and client bytes. |
| **Antithesis Angle** | Cut around chunk append, sync, metadata and rename, then restart and check recovered objects. |
| **Why It Matters** | A partial cached response could silently corrupt many downstream consumers. |
| **Evidence** | [Source and oracle](properties/brady-cache-complete-publication.md); discovery focus 01. |

**Proof boundary:** Draft selection: `storage`. hosted-tcg-router-limited; independent witness: real TPROXY/origin count, cache object digest, ZFS pressure and socket inode. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Does hosted storage permit a persisted power-cut test, or process kills only? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### brady-cache-physical-headroom-and-leases — Shared disk pressure

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | New and growing cache writes require fresh native pool and guest-parent headroom after pending reservations; stale pressure preserves completed leased reads. |
| **Invariant** | Always checks admitted writes against independent physical headroom and retained reader bytes; Reachable targets safe bypass at the floor. Planned literal SDK message: **"brady cache writes fit fresh physical headroom and retain leased objects on uncertainty"**. |
| **Antithesis Angle** | Guest growth, snapshots, chunked writes, stale samples and live readers during eviction. |
| **Why It Matters** | Cache traffic must preserve physical guest safety margin and active reads. |
| **Evidence** | [Source and oracle](properties/brady-cache-physical-headroom-and-leases.md); discovery focus 05. |

**Proof boundary:** Draft selection: `storage`. hosted-tcg-router-limited; independent witness: real TPROXY/origin count, cache object digest, ZFS pressure and socket inode. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which fault reaches uncertain temporary deletion safely? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### brady-listener-socket-worker-bound — Transparent socket capacity

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | A listener owns at most configured live workers, closes overload sockets and accepts a valid successor after a slot frees. |
| **Invariant** | Always checks live worker socket inodes against max_connections; Sometimes checks origin receipt after saturation and retirement. Planned literal SDK message: **"brady listener overload never creates an extra live worker or leaked accepted FD"**. |
| **Antithesis Angle** | Hold incomplete headers, race excess accepts, transfer failure and worker death. |
| **Why It Matters** | Bounds accepted FDs and leaves later connections usable. |
| **Evidence** | [Source and oracle](properties/brady-listener-socket-worker-bound.md); discovery focus 05. |

**Proof boundary:** Draft selection: `storage`. hosted-tcg-router-limited; independent witness: real TPROXY/origin count, cache object digest, ZFS pressure and socket inode. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What measured freed-slot quiet interval is justified? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### enrico-attempt-replay-bounded-receipts — Finite local deduplication

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Replaying an active or retained completed Enrico attempt starts no second Git fetch; local deduplication ends on eviction/restart. |
| **Invariant** | `Always` **"Enrico retained attempt replay starts no second fetch"** while within receipt retention, using external Git fixture fetch count. |
| **Antithesis Angle** | Duplicate same attempt amid status loss, generation races and 1024-receipt eviction. |
| **Why It Matters** | Duplicate fetches waste quota and obscure which attempt Marshall can safely settle. |
| **Evidence** | [Source and oracle](properties/enrico-attempt-replay-bounded-receipts.md); discovery focus 09. |

**Proof boundary:** Draft selection: `repository`. real-hosted-git-and-native-helper; independent witness: fixed-origin Git request log, bare mirror SHA/blob and original flock inode. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/repository/scenarios.py:231`. Direct Enrico native Git receipt/origin journal, including separate 1025-attempt cap; hosted campaign unexecuted. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R8`: Keep exact production-capacity saturation in a measured campaign. Use lower-cost bounded replay or refusal histories for routine search; do not claim the full 4,096-worker or 1,025-receipt cap without reaching it. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How can a real-effect fixture reach 1025 completions cheaply? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### enrico-native-git-admission-after-manager-restart — Inherited Git slots

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Manager replacement cannot admit a ninth live native Git ownership tree or a competing mutator for one repository. |
| **Invariant** | Always counts process-held slot locks and per-repository mutators; Reachable targets ninth-request refusal while eight locks remain. Planned literal SDK message: **"Enrico native Git ownership bounds physical concurrent refreshes"**. |
| **Antithesis Angle** | Helper/caller death, inherited descriptors, result-before-exit and Manager restart. |
| **Why It Matters** | A fresh BEAM counter must not hide old physical Git work. |
| **Evidence** | [Source and oracle](properties/enrico-native-git-admission-after-manager-restart.md); discovery focus 02, 05. |

**Proof boundary:** Draft selection: `repository`. real-hosted-git-and-native-helper; independent witness: fixed-origin Git request log, bare mirror SHA/blob and original flock inode. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/repository/scenarios.py:439`. Native Git slot-inode and passive /proc lock snapshot across an exact Enrico service restart; no hosted campaign or general descendant-custody acceptance. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Does hosted Linux preserve inherited-FD and descendant custody with observable locks? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### enrico-published-head-remains-addressable — Published Git content

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / medium-high / authored primary; hosted unexecuted; scope partial |
| **Property** | A commit SHA that Marshall still publishes remains resolvable with the same controlled blob through failed or interrupted mirror refresh. |
| **Invariant** | `Always` **"Enrico published Git head remains addressable through failed refresh"** after settled failure, comparing pinned SHA/object bytes with an independent workload ledger. |
| **Antithesis Angle** | Force-push upstream and cut Enrico around fetch/retained-ref updates or Marshall settlement. |
| **Why It Matters** | Losing the published commit makes a registered mirror unusable despite durable catalog state. |
| **Evidence** | [Source and oracle](properties/enrico-published-head-remains-addressable.md); discovery focus 01, 03. |

**Proof boundary:** Draft selection: `repository`. real-hosted-git-and-native-helper; independent witness: fixed-origin Git request log, bare mirror SHA/blob and original flock inode. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/repository/scenarios.py:143`. Fixed native Git origin/blob plus Marshall worker and SQL head/audit; hosted origin/worker campaign unexecuted. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What safe hook can interrupt real Git between atomic fetch and retained-ref update? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### ziggy-completion-once-accounted — One completion, one accounting contribution

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / partially instrumented; primary unimplemented |
| **Property** | An acknowledged inference completion persists one immutable projection and contributes exactly once to its Marshall daily aggregate despite duplicate delivery. |
| **Invariant** | `Always` **"Ziggy completion acknowledgment conserves one Marshall accounting update"** at settled snapshots; optional `AlwaysOrUnreachable` at slot removal checks exact ACK before deletion. |
| **Antithesis Angle** | Lose completion replies, restart Ziggy around spool deletion, duplicate reporters and vary unknown versus complete usage. |
| **Why It Matters** | Lost or doubled usage distorts billing and operational SLOs. |
| **Evidence** | [Source and oracle](properties/ziggy-completion-once-accounted.md); discovery focus 01, 03. |

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: durable Ziggy spool ID, independent provider accept log and Marshall aggregate; current real placement/execution authority required. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `satellite-standin` selects this command with the origin and satellite overlays and a labelled guest stand-in. The command still needs a current running VM; the hosted controlled Lilly pool reports unavailable capacity, so it records unexercised in that graph. The stand-in is not a guest and supplies no VM binding. No hosted run exists.

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/satellite/scenarios.py:73`. A normal admitted guest inference joins one private provider acceptance to one settled Request and a Daily delta. Exact ACK-loss/replay and restart witnesses are absent, and the hosted guest-to-Audi graph is not ready. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which current-credential fixture isolates one owner/day/provider/model bucket? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### ziggy-interrupted-inference-never-reexecutes — External effect recovery

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Restart/reporter replay never repeats an original inference effect and unfinished work remains interrupted/unknown. |
| **Invariant** | `Always(zero additional recovery-originated provider effects && unproven usage unknown)`. Planned literal SDK message: **"Ziggy recovery replays accounting without repeating an inference effect"**. |
| **Antithesis Angle** | Kill around durable admission, upstream acceptance/streaming/completion and spool publication uncertainty. |
| **Why It Matters** | Prevents duplicated provider cost or fabricated known usage from uncertain execution. |
| **Evidence** | [Source and oracle](properties/ziggy-interrupted-inference-never-reexecutes.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: durable Ziggy spool ID, independent provider accept log and Marshall aggregate; current real placement/execution authority required. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### ziggy-spool-capacity-before-provider — Durable effect-slot admission

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Provider or agent effects require a previously durable bounded spool slot; full or unavailable spool refuses new effects while preserving admitted receipts. |
| **Invariant** | Always compares provider fixture accepts with durable admitted IDs and slot count; Reachable targets intended full-spool refusal. Planned literal SDK message: **"ziggy provider effects require a previously durable bounded spool slot"**. |
| **Antithesis Angle** | Fill slots, lose completion ACKs, restart Ziggy and attempt new HTTP/agent work. |
| **Why It Matters** | Prevents unaccountable external effects when completion custody is exhausted. |
| **Evidence** | [Source and oracle](properties/ziggy-spool-capacity-before-provider.md); discovery focus 05. |

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-inner-zfs-backed-current-VM-plus-satellite; unbuilt; independent witness: durable Ziggy spool ID, independent provider accept log and Marshall aggregate; current real placement/execution authority required. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can hosted faults expose directory-sync uncertainty? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

## Placement, execution, and physical ownership

These properties exercise the placement, execution, and physical ownership boundaries and their failure interleavings.

### cancelled-relocation-restores-after-revocation — Cancellation restoration and custody

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Pre-commit cancellation restores source execution only after source revocation and fresh-epoch physical proof, retaining each destination and stream hold until its required receipts; a healable cancellation eventually regains its original state. |
| **Invariant** | `Always` **"Cancelled relocation restores source only after revocation and retains cleanup custody"** checks every settled phase. `Sometimes(condition)` **"Cancelled relocation regained its original source state after physical proof"** requires one finite-fault restoration to complete, so it is a meaningful progress assertion. |
| **Antithesis Angle** | Race cancellation with handoff and lose revocation/stop/start replies across Marshall and Lilly restarts. |
| **Why It Matters** | Premature restart or custody release risks double execution or leaked transfer authority; stalled restoration harms availability. |
| **Evidence** | [Source and oracle](properties/cancelled-relocation-restores-after-revocation.md); discovery focus 07. |

**Proof boundary:** Draft selection: `no selected hosted template`. no-hosted-full-claim-currently; independent witness: two real Lilly boundaries with source/destination VMM, ZFS, network and committed handoff receipts. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the native fixture cut between source revocation and stop without breaking the owner lock? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### continuing-boot-advances-generation-without-second-boot — Logical and physical identity

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Adopting newer running intent on the same placement/VM epoch preserves one physical boot while old-generation delivery cannot settle the new journal. |
| **Invariant** | `Always` **"Logical generation adoption retains one physical boot and fences old delivery"** joins native VMM identity, boot challenge, current intent and exact delivery journal on every adoption/replay. |
| **Antithesis Angle** | Delay trust/workspace replies across actor or Control restart while intent generation advances on a continuing guest. |
| **Why It Matters** | A generation number alone neither proves a new boot nor authorizes an old reply to finish new work. |
| **Evidence** | [Source and oracle](properties/continuing-boot-advances-generation-without-second-boot.md); discovery focus 11. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which native fixture can delay a guest workspace reply through a committed generation advance while retaining the VMM? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### delete-release-follows-physical-retirement — Delete releases only proven absence

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A delete cannot archive the VM or free reservation/address until exact-current VMM, network and disk cleanup is physically confirmed and accepted. |
| **Invariant** | `Always` checks each archive/release against matching accepted deleted outcome and independent native absence; `Sometimes(cond)` requires an initially unconfirmed cleanup to reach confirmed retirement after faults heal. Planned literal SDK message: **"lifecycle.delete_release_requires_current_physical_retirement"**. |
| **Antithesis Angle** | Fail unit stop, network detach or ZFS deletion; crash actor before/after outcome journal and acknowledgement; replay an old generation. |
| **Why It Matters** | Premature reuse can overlap old effects or lose deletion custody. . |
| **Evidence** | [Source and oracle](properties/delete-release-follows-physical-retirement.md); discovery focus 08. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: exact current outcome plus VMM/network/overlay absence; native ZFS GUID retirement separately required; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which native observer establishes VMM, network, and ZFS absence before Marshall releases reservation/address? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### execution-v4-refuses-legacy-document — Execution v4 refuses legacy documents

| | |
|---|---|
| **Type** | Safety (`AlwaysOrUnreachable` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | An unsupported inner Execution document cannot create executable Lilly intent, acknowledge an outcome, or erase the last durable command. |
| **Invariant** | `AlwaysOrUnreachable` checks each optional incompatible-document refusal against Store, Journal, and physical launch marker; the path may be absent in a run. Planned literal SDK message: **"Execution v4 refuses legacy authority without changing durable command"**. |
| **Antithesis Angle** | Vary inner versions inside a valid Control v1 socket, lose a response, and reconnect with a compatible peer. |
| **Why It Matters** | A legacy receipt must not acquire current execution authority. |
| **Evidence** | [Source and oracle](properties/execution-v4-refuses-legacy-document.md); discovery focus 10. |

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-17):** Primary `always_or_unreachable` message is present at `antithesis/workload/control/dispatch.py:351`. After a valid v4 session, inner Execution v1/v3/v5 session documents on an authenticated Control v1 socket must receive `unsupported_version`, leave their fresh session row absent and leave Marshall's committed host session and epoch unchanged; a concurrent change by the live Lilly runtime leaves that request unexercised. The distinct danger-branch `Reachable` is `Execution legacy inner session reaches authenticated decoder refusal`. Scope: Marshall's request decoder and durable host row only; Lilly's response parser, Store, Journal and physical launch marker are not observed. The `control_legacy_request` singleton is in the staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a test peer inject malformed inner documents over the real authenticated Control transport? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### guest-readiness-binds-current-physical-boot — Readiness follows the current boot

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A guest-ready running outcome must match current placement, epoch, generation and physical boot after authority is rechecked on both sides of guest waiting. |
| **Invariant** | `Always` compares every positive readiness/outcome receipt to the current boot and command; `Sometimes(cond)` requires a new physical boot to reach matching accepted readiness after a recovered interruption. Planned literal SDK message: **"lifecycle.guest_ready_receipt_matches_current_physical_boot_and_execution"**. |
| **Antithesis Angle** | Replace a VMM or advance generation while a vsock readiness response is delayed, then replay an older trust or boot response. |
| **Why It Matters** | Stale boot readiness can authorize access to the wrong or no guest. . |
| **Evidence** | [Source and oracle](properties/guest-readiness-binds-current-physical-boot.md); discovery focus 08. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Guest-lifecycle profile (2026-10-17):** The launchable `guest-lifecycle` selection runs `guest_lifecycle/serial_driver_physical_boot_cycle.py` against a real QEMU TCG guest with a STUB-storage container Lilly (fixed synthetic pool, no ZFS). Its support `Always` joins each guest-ready outcome to the current tuple, live QEMU/backend start ticks and port-1024 readiness, and a fresh start must show a new kernel boot UUID. The primary stays unimplemented: there is no Lilly boot-journal join, delayed or replaced boot, ZFS pool or native evidence, and no hosted run is recorded.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### lilly-async-result-keeps-command-identity — Old results cannot gain new authority

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A result for an older Lilly command cannot publish a newer command's live, capacity or outcome proof. |
| **Invariant** | `Always` **"Lilly asynchronous result retains its original command generation"** across Store, Journal, Execution and physical receipt observations. |
| **Antithesis Angle** | Pause executor, commit a replacement generation, and release the old result amid actor restart/exchange. |
| **Why It Matters** | Relabeling stale work could grant VM authority to the wrong physical execution. |
| **Evidence** | [Source and oracle](properties/lilly-async-result-keeps-command-identity.md); discovery focus 02. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### lilly-corrupt-intent-never-becomes-receipt — Corrupt intent refusal

| | |
|---|---|
| **Type** | Safety (`AlwaysOrUnreachable` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A malformed or differently bound durable placement command cannot justify a new successful delivery receipt. |
| **Invariant** | `AlwaysOrUnreachable` **"Lilly refuses receipt when stored placement intent is unreadable"** at the optional corruption path: if reached, refusal must hold. |
| **Antithesis Angle** | Restart the real host owner with truncated, wrong-versioned, wrong-bound or unsafe command files and deliver newer intent. |
| **Why It Matters** | Reinterpreting corrupt storage as absence could authorize execution without durable identity. |
| **Evidence** | [Source and oracle](properties/lilly-corrupt-intent-never-becomes-receipt.md); discovery focus 01. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### lilly-finite-obstruction-recovery-progress — Eligible retained intent progress

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | A designated still-eligible retained operation and its neighbor progress after restart and finite obstruction removal. |
| **Invariant** | `Sometimes(probe physically completed and committed && neighbor completed)` under valid authority/capacity and quiet interval. Planned literal SDK message: **"Lilly retained eligible intent progresses after finite obstruction and restart"**. |
| **Antithesis Angle** | Lost dispatch hint, supervisor restart, sampling contention and journal/pool lock release. |
| **Why It Matters** | Detects starvation that pure safety checks tolerate; consumed-before-submission generations are excluded. |
| **Evidence** | [Source and oracle](properties/lilly-finite-obstruction-recovery-progress.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: real ZFS GUID/content plus original lock holder and sampled pool state; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What measured baseline interval supplies the workload budget? `(partial: cadence/retries found, no universal SLA)`

### lilly-interrupted-launch-at-most-once — Interrupted launch authority

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Recovery never physically resubmits the same placement/epoch/generation launch authority. |
| **Invariant** | `Always(actual submissions <= 1)`; conservative consumed-but-unsubmitted refusal is permitted. Planned literal SDK message: **"Lilly recovery never resubmits one physical launch authority"**. |
| **Antithesis Angle** | Actor/release/helper loss before and after separate actor and physical launch marker commits, systemd acceptance and outcome recording. |
| **Why It Matters** | Prevents duplicate physical execution and crash-budget bypass. |
| **Evidence** | [Source and oracle](properties/lilly-interrupted-launch-at-most-once.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the hosted adapter retain independently durable submission witnesses with production marker semantics? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### lilly-outcome-replay-exact-ack — Physical outcome custody

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Identical physical facts retain outcome identity and only exact current ACK can clear pending custody. |
| **Invariant** | `Always(stable identical-fact ID/sequence && old ACK cannot clear newer pending outcome)`. Planned literal SDK message: **"Lilly recovery preserves outcome identity until its exact acknowledgment"**. |
| **Antithesis Angle** | DB commit/reply loss, reconnect, newer generation and delayed ACK/old task completion. |
| **Why It Matters** | Prevents loss of pending evidence and release of newer authority from stale facts. |
| **Evidence** | [Source and oracle](properties/lilly-outcome-replay-exact-ack.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### lilly-pool-sampling-does-not-starve-mutation — Sampling fairness

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / medium-high / researched; primary unimplemented |
| **Property** | Repeated samples leave an eligible queued pool mutation and a separate pool neighbor able to finish after finite lock obstruction. |
| **Invariant** | Sometimes checks both physical receipts while sampling continues, under valid authority, capacity and a measured quiet interval. Planned literal SDK message: **"Lilly independent pool mutation completes during sustained sampling pressure"**. |
| **Antithesis Angle** | Slow one-in-flight samples, zero-wait busy observations and clone/refill/delete locks. |
| **Why It Matters** | Monitoring must not starve physical work needed to restore capacity. |
| **Evidence** | [Source and oracle](properties/lilly-pool-sampling-does-not-starve-mutation.md); discovery focus 02, 05. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: real ZFS GUID/content plus original lock holder and sampled pool state; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. `R7`: Bind contested pool-lock acquisition and release to the same designated operation before measuring post-release progress. An uncontended completion cannot establish this property. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which measured post-release interval is sufficient for each selected operation? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Can hosted TCG maintain two independent real pools with genuine contention under faults? `(partial: two real hosted pools and lock fault fixture remain unbuilt)`

### lilly-receipt-survives-control-loss — Durable delivery acknowledgment

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Acknowledged command remains backed by matching or newer host-bound durable intent after restart. |
| **Invariant** | `Always(ACK implies valid durable reread after reopen)`; receipt is not physical completion. Planned literal SDK message: **"Lilly command receipt remains backed by matching durable intent after restart"**. |
| **Antithesis Angle** | Control loss, release death and write/rename/directory sync uncertainty around ACK. |
| **Why It Matters** | Keeps accepted work available without fabricating rollback on unproven writes. |
| **Evidence** | [Source and oracle](properties/lilly-receipt-survives-control-loss.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which hosted filesystem faults exercise directory fsync uncertainty? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### lilly-view-restart-withdraws-stream-authority — Production View restart fencing

| | |
|---|---|
| **Type** | Safety (`AlwaysOrUnreachable` primary) |
| **Priority / Confidence / Status** | P0 / medium / researched; primary unimplemented |
| **Property** | A View restart cannot permit an old stream to forward a new guest effect before dependent components reestablish current authority. |
| **Invariant** | `AlwaysOrUnreachable` **"Lilly View restart withdraws stale stream authority before forwarding"** on the optional real-supervisor restart path. |
| **Antithesis Angle** | Kill Execution under `rest_for_one` while racing command replacement and stream bytes; observe actual connector teardown. |
| **Why It Matters** | A direct ETS lookup race matters only if later stream/effect fences fail. |
| **Evidence** | [Source and oracle](properties/lilly-view-restart-withdraws-stream-authority.md); discovery focus 02. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### marshall-admission-atomic-allocation — Joined admission allocation

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Each acknowledged new admission has one joined VM, placement, reservation, address, provision operation and persisted dispatch job; definite failed new admission leaves none. |
| **Invariant** | `Always` **"Marshall acknowledged admission has one joined allocation and dispatch job"** on a consistent PostgreSQL snapshot; each sampled settled admission must satisfy it. Timed-out calls are reconciled by ID. |
| **Antithesis Angle** | Race same-key callers across nodes and cut near commit or job insertion; a lost reply must preserve original allocation identity. |
| **Why It Matters** | Partial allocation or absent dispatch work can strand capacity and VM intent. |
| **Evidence** | [Source and oracle](properties/marshall-admission-atomic-allocation.md); discovery focus 01. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/admission/scenarios.py:212`. One serial trusted-operator admission joins a terminal domain receipt to one-statement PostgreSQL VM, placement, reservation, address, provision-operation and dispatch-job rows; no cross-node same-key race, commit-cut run, or positive integrated-host checkpoint. It is outside the currently staged control-core selection. The separate `admission-stub` selection profile runs this command against real Marshall admission on a harness **stub** storage substrate (configured pool totals, measured container cgroup compute, a non-bootable digest-verified stub image); a stub-backed result is admission-logic evidence only, never ZFS, physical-capacity, KVM or isolation evidence. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which PaperTrail/audit row is mandatory for new admission? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### marshall-admission-key-survives-archive — Permanent admission identity

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | One owner/key always refers to its original VM ID across lost replies and archival; changed shape refuses without allocation. |
| **Invariant** | `Always` **"Marshall replayed admission key never allocates a second VM"** against independent request ledger and PostgreSQL history. |
| **Antithesis Angle** | Drop first reply, race cross-node retries, then physically delete/archive and replay again. |
| **Why It Matters** | Duplicate VMs under one request can consume capacity or bypass intended lifecycle history. |
| **Evidence** | [Source and oracle](properties/marshall-admission-key-survives-archive.md); discovery focus 09. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/admission/scenarios.py:244`. Observed first-key SQL contradictions fail, identical replay and exact idempotency conflict are checked, and archived replay waits for real delete plus SQL archival; integrated physical cleanup and hosted execution remain unverified. It is outside the currently staged control-core selection. The separate `admission-stub` selection profile runs this command against real Marshall admission on a harness **stub** storage substrate (configured pool totals, measured container cgroup compute, a non-bootable digest-verified stub image); a stub-backed result is admission-logic evidence only, never ZFS, physical-capacity, KVM or isolation evidence. The stub's controlled executor never completes a delete, so the archived-replay branch stays unexercised there. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which TCG/native deletion path reaches archival with physical cleanup? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### marshall-admission-measured-physical-capacity — Locked placement budget

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Each committed placement fits fresh measured CPU, memory and disk headroom after startup, copy and resize holds. |
| **Invariant** | Always reconstructs the exact locked report and retained holds for each new reservation. Planned literal SDK message: **"marshall placement fits fresh measured physical headroom and all outstanding holds"**. |
| **Antithesis Angle** | Competing creates, host reports, pool contention, clone/resize holds and lost admission replies. |
| **Why It Matters** | Prevents oversubscription from stale samples or virtual sizes used as physical credit. |
| **Evidence** | [Source and oracle](properties/marshall-admission-measured-physical-capacity.md); discovery focus 05. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: exact locked report revision and holds correlated with independent CPU/memory/ZFS sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/admission/physical_scenario.py:69` (template `test/v1/admission_physical`, selected by no profile; the stub profile deliberately excludes it because a stub sample is not an independent ZFS witness). Dedicated host/pool brackets unchanged SQL report and holds, waits for a newer independent inner-ZFS sample, and checks shape/overhead arithmetic; changing frames and physical free disagreement remain unknown without commit-time and CPU/memory interval correlation. No live admission has run. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which adapter preserves Collector freshness while providing independent usage/ZFS samples? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Can hosted faults produce real pool-lock busy reports? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### marshall-crash-recovery-budget-and-stale-capacity — Bounded recovery decision

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Crash recovery charges durable budget once and keeps stale-capacity work held until a fresh decision. |
| **Invariant** | `Always(no unauthorized/exhausted restart && stale capacity retains hold)`; future timestamps remain charged. Planned literal SDK message: **"Marshall crash recovery preserves its budget and waits for fresh capacity proof"**. |
| **Antithesis Angle** | Crash/report/ACK replay, concurrent coordinators, DB restart/time reversal and fresh capacity arrival. |
| **Why It Matters** | Avoids retry storms, oversubscription and permanent refusal caused solely by stale telemetry. |
| **Evidence** | [Source and oracle](properties/marshall-crash-recovery-budget-and-stale-capacity.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can supported hosted DB-time faults reach backward time with real Ledger.now? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### native-utility-descendant-custody — Descendants retain mutation custody

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | An exclusive native mutation cannot overlap another on the same lock inode while a first utility or adopted descendant remains active. |
| **Invariant** | `Always` **"Native utility descendant custody blocks a second mutation until retirement"** at each competing acquisition and completion, using PID and inode evidence. |
| **Antithesis Angle** | Kill caller/helper, let the leader exit, create a new-session grandchild, then race a second mutator. |
| **Why It Matters** | Premature ownership release can overlap destructive ZFS/transfer effects. |
| **Evidence** | [Source and oracle](properties/native-utility-descendant-custody.md); discovery focus 02, 03. |

**Proof boundary:** Draft selection: `storage`. hosted-tcg-zfs-limited; independent witness: real ZFS GUID/content plus original lock holder and sampled pool state. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Does hosted Linux preserve subreaper and inherited-descriptor behavior with stable pidfd/inode evidence after helper death? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### relocation-handoff-one-current-execution — One current relocation authority

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A relocation handoff publishes one destination placement, successor VM execution epoch and activation outbox together, while source and destination do not both exercise current writable execution authority. |
| **Invariant** | `Always` **"Relocation handoff has one current placement epoch and one activation outbox"** checks each committed snapshot and correlates native execution identities; safety must hold across every coordinator replay. |
| **Antithesis Angle** | Race two or three Marshall coordinators, final import delivery and process cuts around the handoff transaction for running and stopped VMs. |
| **Why It Matters** | A split handoff could create two writers or a VM with no activation path. |
| **Evidence** | [Source and oracle](properties/relocation-handoff-one-current-execution.md); discovery focus 07. |

**Proof boundary:** Draft selection: `no selected hosted template`. no-hosted-full-claim-currently; independent witness: two real Lilly boundaries with source/destination VMM, ZFS, network and committed handoff receipts. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which native observer can identify both VMM custody and guest write authority during handoff? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### source-stop-after-committed-placement-holds — Prepared clone source stop

| | |
|---|---|
| **Type** | Safety (`AlwaysOrUnreachable` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / researched; primary unimplemented |
| **Property** | A clone source interruption follows committed destination placement, source temporary-disk hold, destination reservation and transfer slots. |
| **Invariant** | `AlwaysOrUnreachable` **"Clone source interruption follows committed placement and capacity holds"** on the optional source-stop path, using PostgreSQL and physical source witnesses. |
| **Antithesis Angle** | Race host report, admission, cancel and source-stop delivery around the commit boundary. |
| **Why It Matters** | Interrupting the sole recoverable source before copy preparation can strand a VM. |
| **Evidence** | [Source and oracle](properties/source-stop-after-committed-placement-holds.md); discovery focus 02. |

**Proof boundary:** Draft selection: `no selected hosted template`. no-hosted-full-claim-currently; independent witness: two real Lilly boundaries with source/destination VMM, ZFS, network and committed handoff receipts. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### stop-retains-disk-until-restart — Stop removes execution, retains workload

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | A completed stop has no running VMM or network attachment but retains the same disk and address, which a fresh start can use again. |
| **Invariant** | `Always` checks each accepted stop completion against native absence and retained disk GUID/address; `Sometimes(cond)` requires a new boot from the same disk after healed interruption. Planned literal SDK message: **"lifecycle.completed_stop_has_no_vmm_and_retains_disk_identity"**. |
| **Antithesis Angle** | Interrupt between non-running intent, unit exit, network detach and accepted physical outcome; retry stop/start. |
| **Why It Matters** | Early compute release risks overcommit; disk loss destroys stopped user data. . |
| **Evidence** | [Source and oracle](properties/stop-retains-disk-until-restart.md); discovery focus 08. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Guest-lifecycle profile (2026-10-17):** The launchable `guest-lifecycle` selection's support `Always` requires an accepted stop to show no QEMU/backend process and a retained qcow2 overlay hash in the separate guest-vmm container. The pool is a STUB, so ZFS dataset GUID, retained guest content, address and network detach remain unexercised; the primary stays unimplemented and no hosted run is recorded.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the hosted storage/guest fixture inspect disk GUID, network detach, and fresh boot without substituting modeled physical effects? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### store-v3-host-binding-survives-upgrade — Store v3 host binding survives upgrade

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | An incompatible Store identity or command version refuses Runtime startup before execution and preserves existing command bytes. |
| **Invariant** | `Always` compares refused startup, command-file hashes, owner identity, and launch effects; optional bound profile rewrite gets a distinct `AlwaysOrUnreachable` message. Planned literal SDK message: **"Lilly Store v3 refuses foreign or changed host binding without reinterpretation"**. |
| **Antithesis Angle** | Restart Runtime with foreign host/version binding or corrupt command files, then restore valid binding and replay. |
| **Why It Matters** | Local durable intent cannot be reinterpreted as authority for another host or format. |
| **Evidence** | [Source and oracle](properties/store-v3-host-binding-survives-upgrade.md); discovery focus 10. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger; current measured ZFS pool required for accepted placement. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which seam changes host/version across complete Runtime lifetimes while retaining real ownership? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### transient-observation-is-not-absence — Unavailable physical evidence

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | Retryable observation/ownership failure cannot fabricate absent physical state or release allocation. |
| **Invariant** | `Always(retry leaves durable physical outcome and held allocation intact)`. Planned literal SDK message: **"Lilly temporary observation failure never fabricates physical absence"**. |
| **Antithesis Angle** | Running adoption under pool/VM/network contention, transitional systemd status and unavailable probes. |
| **Why It Matters** | Preserves surviving guests and custody during control or sampling outage. |
| **Evidence** | [Source and oracle](properties/transient-observation-is-not-absence.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which hosted probe faults preserve real production observation? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

## Guest access and workspace

These properties exercise the guest access and workspace boundaries and their failure interleavings.

### current-membership-gates-new-private-web — Current membership gates new private web

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | a private request newly admitted after role revocation commits cannot reach the guest using a historical grant/cookie. |
| **Invariant** | `Always` on committed revocation order plus guest nonce; `Sometimes(authorized_private_web_nonce_observed)` requires current-member progress. Planned literal SDK message: **"Revoked membership cannot deliver a newly admitted private web request to the guest"**. |
| **Antithesis Angle** | VM lock, membership replacement, stale cookie and lost replies. |
| **Why It Matters** | Revoked membership must stop new guest web effects despite historical cookies. |
| **Evidence** | [Source and oracle](properties/current-membership-gates-new-private-web.md); discovery focus 06. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which minimal guest app and browser-login fixture gives a full Audi private route and independent nonce recorder? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### expired-web-lease-stops-existing-guest-bytes — Expired web lease stops existing guest bytes

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | old Audi web/editor stream cannot deliver a new guest nonce after the last valid local grant deadline. |
| **Invariant** | `Always` on post-deadline guest effect; `Sometimes(current_lease_resumed_guest_bytes)` confirms a new authorized stream after recovery. Planned literal SDK message: **"Expired Audi web authority cannot forward new guest bytes"**. |
| **Antithesis Angle** | renewals, lose hints and suspend guard/worker. |
| **Why It Matters** | A retained stream must stop forwarding new bytes after its local grant expires. |
| **Evidence** | [Source and oracle](properties/expired-web-lease-stops-existing-guest-bytes.md); discovery focus 06. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How will a hosted guest fixture mark post-deadline ordering without synchronized clocks? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Which hosted fault controller can suspend the guard while retaining production ownership? `(partial: production guard suspension in hosted TCG remains unproven)`

### guest-identity-cutover-preserves-uid-custody — Guest identity cutover preserves UID custody

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / researched; primary unimplemented |
| **Property** | The one-way name migration preserves existing GuestAccount UUID and UID, canonicalizes the home to `u<uid>`, and never reassigns historical UIDs. |
| **Invariant** | `Always` compares each settled migration and later allocation to a pre-cutover identity and UID ledger. Planned literal SDK message: **"Guest identity cutover preserves UUID and UID custody across mailbox history"**. |
| **Antithesis Angle** | Interrupt a migration transaction and race same-user email edits, retirement, and same-email registration. |
| **Why It Matters** | Ownership must stay bound to an immutable user identity across mailbox history. |
| **Evidence** | [Source and oracle](properties/guest-identity-cutover-preserves-uid-custody.md); discovery focus 10. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: pre-cutover UUID/UID ledger and guest home owner/read effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. `R10`: Treat pre/post GuestAccount migration conversion as native/integration acceptance. Antithesis races post-cutover same-user email edit with retirement, reuse, lost reply and real guest identity effects. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### guest-identity-never-transfers-on-email-reuse — Guest identity never transfers on email reuse

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | retirement permanently reserves old GuestAccount UUID/UID/home and a fresh same-email User cannot use the old guest identity; active same-user email edits preserve it. |
| **Invariant** | `Always` on persisted identities plus guest home owner/read effects; two `Sometimes` conditions require same-user continuity and distinct-home replacement progress. Planned literal SDK message: **"Retired guest identity and home never transfer to a replacement account"**. |
| **Antithesis Angle** | retirement, same-email registration, admission and lost replies. |
| **Why It Matters** | Email reuse must not transfer a prior user’s UID, home, or guest data. |
| **Evidence** | [Source and oracle](properties/guest-identity-never-transfers-on-email-reuse.md); discovery focus 06. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: pre-cutover UUID/UID ledger and guest home owner/read effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R10`: Treat pre/post GuestAccount migration conversion as native/integration acceptance. Antithesis races post-cutover same-user email edit with retirement, reuse, lost reply and real guest identity effects. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which guest fixture covers SSH, browser terminal and editor on one retained identity across both guest families, versus capability-specific cases? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### guest-ready-does-not-claim-workspace-checkout — Separate guest and checkout status

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | VM ready may coexist with a pending or failed Git checkout, while any checkout-complete claim requires the actual guest's durable completion and content. |
| **Invariant** | `Always` **"Guest readiness does not claim repository checkout completed"** checks checkout claims against guest marker/HEAD. `Sometimes(condition)` **"Guest remained ready while workspace checkout was pending"** requires one meaningful independent-state observation. |
| **Antithesis Angle** | Boot a real guest while Git is unavailable, then heal/move a ref and interrupt clone around rename and completion publication. |
| **Why It Matters** | Conflating ready VM with ready workspace misleads users and hides checkout failures. |
| **Evidence** | [Source and oracle](properties/guest-ready-does-not-claim-workspace-checkout.md); discovery focus 11. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### guest-workspace-restart-publication-no-clobber — Guest checkout recovery

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | Recovery preserves accepted source and published developer checkout, including rename-before-done interruption. |
| **Invariant** | `Always(no source replacement/published checkout overwrite)`; supplementary `Sometimes(real accepted unpublished source completes)` under restored preconditions. Planned literal SDK message: **"Guest workspace recovery preserves its accepted source and published developer checkout"**. |
| **Antithesis Angle** | Source accepted reply loss, partial clone death, rename/done/status gaps, branch movement and redelivery. |
| **Why It Matters** | Keeps user edits intact and distinguishes source receipt from actual checkout completion. |
| **Evidence** | [Source and oracle](properties/guest-workspace-restart-publication-no-clobber.md); discovery focus 03. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How does the TCG restart retain filesystem and independently witness publication durability? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### guest-workspace-source-replay-once — One source per boot

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A boot-bound source delivery persists before acceptance; identical redelivery preserves it, while changed or stale-boot delivery cannot replace it. |
| **Invariant** | `Always` **"Guest workspace source replay preserves one boot-bound source"** against guest file/checkout and independent Git fixture effect history. |
| **Antithesis Angle** | Lose accepted reply and cut before/after source publication, checkout rename and done marker. |
| **Why It Matters** | Replay could clone a second repository or replace the source after a guest begins work. |
| **Evidence** | [Source and oracle](properties/guest-workspace-source-replay-once.md); discovery focus 09. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How can clone effects be counted without exposing source? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### source-v2-capability-gates-admission — Source v2 capability gates admission

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A sourced admission or first launch requires a matching validated image-v4 manifest that explicitly declares workspace source protocol 2. |
| **Invariant** | `Always` joins each definite admission result to catalog capability, PostgreSQL allocation rows, and physical disk/launch effects. Planned literal SDK message: **"Workspace source admission requires matching image v4 source-v2 capability"**. |
| **Antithesis Angle** | Race retries with image catalog changes, mismatched content IDs, and unsupported capability versions. |
| **Why It Matters** | An unqualified image must not receive a source workload or consume host resources. |
| **Evidence** | [Source and oracle](properties/source-v2-capability-gates-admission.md); discovery focus 10. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: catalog image digest/capability, committed allocation and physical disk/launch marker; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### source-v2-delivery-envelope-v1-boot-bound — Source delivery envelope is boot bound

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / medium-high / researched; primary unimplemented |
| **Property** | A delivered source-v2 journal requires an exact v1 envelope response bound to current placement, epoch, boot challenge, nonce, and source digest. |
| **Invariant** | `Always` compares each settled delivery journal with the current physical boot and independent guest acceptance. Planned literal SDK message: **"Workspace source-v2 delivery accepts only matching v1 boot envelope"**. |
| **Antithesis Angle** | Delay, duplicate, or alter replies across a reboot and generation change. |
| **Why It Matters** | Stale guest responses must not settle new boot authority or confuse workspace delivery with VM readiness. |
| **Evidence** | [Source and oracle](properties/source-v2-delivery-envelope-v1-boot-bound.md); discovery focus 10. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Where can a controlled guest responder inject invalid envelopes through the actual vsock broker? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### stale-local-execution-cannot-forward-guest-bytes — Stale local execution cannot forward guest bytes

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | a retired placement/epoch stream cannot send a new nonce to its old physical guest after Lilly withdraws local authority and the old guardian ends. |
| **Invariant** | `Always` on old-boot recorder after guardian-death barrier; `Sometimes(current_execution_nonce_observed)` requires new-boot progress. Planned literal SDK message: **"Retired local execution cannot receive new Audi guest bytes"**. |
| **Antithesis Angle** | stop/start or stopped relocation with View, guardian and connector traffic. |
| **Why It Matters** | Retired execution authority must not keep access to an old physical guest. |
| **Evidence** | [Source and oracle](properties/stale-local-execution-cannot-forward-guest-bytes.md); discovery focus 06. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How can the harness independently observe old guardian death? `(partial: local view and guardian path traced)`
- Can TCG retain two distinguishable boot recorders? `(partial: two distinguishable TCG boot recorders remain unbuilt)`

### terminal-create-reply-loss-one-pty — One terminal creation

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | One create request ID binds at most one guest PTY, registry Session and opened receipt despite duplicate or lost replies. |
| **Invariant** | `Always` **"Terminal create replay retains one guest PTY and one opened receipt"** with guest effect witness and consistent DB snapshot. |
| **Antithesis Angle** | Cut after guest PTY birth but before Marshall receipt, duplicate request and race cancellation. |
| **Why It Matters** | Duplicate PTYs can consume guest resources and create ambiguous authority. |
| **Evidence** | [Source and oracle](properties/terminal-create-reply-loss-one-pty.md); discovery focus 09. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/terminal/scenarios.py:96`. Browser LiveView create-reply loss and same-ID duplicate deliveries join SQL opening/session receipt with guest terminald PTY birth and live PID/start; internal guest-create reply loss and hosted physical result remain unverified. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How can the guest count past PTY births? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Does TCG composition use real terminal host stream end to end? `(partial: composed authenticated TCG terminal route remains unrun)`

### terminal-input-frame-replay-once — Ordered channel input

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / partially instrumented; primary unimplemented |
| **Property** | Repeating one input sequence on the same authorized terminal channel cannot write bytes twice to the guest; gaps fence the channel. |
| **Invariant** | `Always` **"Terminal replayed input sequence reaches guest once"** against guest-recorded token count/order; conditional `Sometimes(guest_recorded_two_contiguous_tokens_in_order)` tests useful progress. |
| **Antithesis Angle** | Suppress input ACK, duplicate a frame, then send contiguous/gapped frames under the same channel. |
| **Why It Matters** | Duplicate terminal input can execute a command twice. |
| **Evidence** | [Source and oracle](properties/terminal-input-frame-replay-once.md); discovery focus 09. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/terminal/scenarios.py:226`, `antithesis/workload/terminal/scenarios.py:249`. Authenticated HostStream duplication, Lilly cumulative ACK, and a stable guest daemon fsynced digest ledger cover one same-channel duplicate. The planned gap/order branch is absent and no integrated VM or hosted execution exists. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which transport seam can replay an authenticated frame on the same channel? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Which guest program can witness tokens with low perturbation? `(partial: independent fsynced guest token observer remains unbuilt)`

### terminal-kill-progress-under-pty-backpressure — Kill while input stalls

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / medium / partially instrumented; primary unimplemented |
| **Property** | A controlled terminal with blocked input/output can still be explicitly killed and have its process and quota retired. |
| **Invariant** | `Sometimes(condition)` **"Terminal explicit kill retires session under blocked PTY input"** after synchronized blocked-write/kill overlap; `Reachable` **"Terminal PTY input write blocked while kill requested"** proves the precondition. |
| **Antithesis Angle** | Stop the guest's PTY reader, saturate input, withhold viewer credit and kill through a second connection. |
| **Why It Matters** | A held session mutex could keep a dead session and quota indefinitely; source alone does not establish a defect. |
| **Evidence** | [Source and oracle](properties/terminal-kill-progress-under-pty-backpressure.md); discovery focus 02. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/terminal/scenarios.py:460`, `antithesis/workload/terminal/scenarios.py:497`. An independent input-stall witness precedes kill and a 30-second retired-process/quota Sometimes check. The planned input/output-pressure breadth and measured TCG quiet bound remain absent; no integrated VM run exists. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. `R6`: Require independent evidence that an actual PTY master write is blocked while authorized kill is pending. An absent blocked-write precondition is unexercised, not product liveness failure. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the PTY buffer be saturated and its blocked write witnessed in the deployed daemon? `(partial: source opens master without O_NONBLOCK)`

### terminal-physical-scrollback-budget — Actual terminal ring backing

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | Concurrent PTY creates, growth and overwrite keep allocated ring backing within aggregate reservations; full-budget refusal preserves survivors. |
| **Invariant** | Always checks live deque allocation against ring_total and configured cap; Reachable targets an intended valid create refusal at saturation. Planned literal SDK message: **"terminal physical scrollback backing stays within reserved aggregate budget"**. |
| **Antithesis Angle** | Mixed growth, full-ring overwrite, pump death and retirement while viewer references remain. |
| **Why It Matters** | Prevents memory growth beyond quota without sacrificing live terminals. |
| **Evidence** | [Source and oracle](properties/terminal-physical-scrollback-budget.md); discovery focus 05. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/terminal/scenarios.py:296`. Real guest PTY output checks deque allocation against reserved ring backing; full-budget failed create does not independently identify refusal reason, and no integrated guest or hosted result exists. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can hosted TCG expose exact backing snapshots without perturbing allocation? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Which guest-vsock route preserves concurrent PTYs under outer faults? `(partial: concurrent guest-vsock route remains unrun)`

### terminal-stalled-viewer-neighbor-progress — Terminal queue isolation

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / high / authored primary; hosted unexecuted; scope partial |
| **Property** | A viewer withholding read credit leaves another authorized terminal able to create, attach and deliver bytes during a healthy finite interval. |
| **Invariant** | Sometimes checks designated neighbor nonce bytes while the first viewer remains credit-stalled; the combined state is meaningful progress. Planned literal SDK message: **"terminal neighbor completes create attach and byte delivery while another viewer is credit stalled"**. |
| **Antithesis Angle** | Queue high-water waits, socket backpressure, viewer kill and shared registry locks. |
| **Why It Matters** | One stuck reader should not freeze neighboring sessions. |
| **Evidence** | [Source and oracle](properties/terminal-stalled-viewer-neighbor-progress.md); discovery focus 05. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `sometimes` message is present at `antithesis/workload/terminal/scenarios.py:398`. Observer-confirmed blocked write and viewer queue beyond the high-water mark, with nonce bytes on a second real viewer while pressure remains; no hosted physical result exists. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What measured native/TCG quiet interval is appropriate? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`
- Can hosted faults retain a stalled but open viewer socket? `(partial: hosted fault must retain open stalled viewer socket)`

## Upgrade and version boundaries

These properties exercise the upgrade and version boundaries boundaries and their failure interleavings.

### healthy-revision-requires-live-candidate — Healthy revision reflects the active candidate

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / high / researched; primary unimplemented |
| **Property** | A new `lastHealthy` revision names the exact active closure after current candidate secret preparation and bounded affirmative health of enabled roles. |
| **Invariant** | `Always` at every new healthy advancement compares revision, closure, current secret material and health; `Reachable` marks the verified identical-closure/current-secrets branch. These fit a must-hold transition and a rare successful outcome, respectively. Planned literal SDK message: **"lifecycle.update_healthy_requires_active_closure_current_secrets_and_role_health"**. |
| **Antithesis Angle** | Interrupt stage, switch, secret-unit restart and consecutive health checks; change encrypted secret source at the same closure or fail a private role endpoint. |
| **Why It Matters** | A false healthy receipt could bless a host using old credentials or failed control/ingress services. . |
| **Evidence** | [Source and oracle](properties/healthy-revision-requires-live-candidate.md); discovery focus 08, 10. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a native fixture vary status documents through each real service health implementation? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### migration-finishes-before-upgrade-activation — Explicit migration precedes activation

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | A candidate serving closure activates only after its explicit candidate migrator succeeds; plain serving startup does not migrate, and failed health never triggers schema rollback. |
| **Invariant** | `Always` checks migration completion before activation; `Reachable` marks a second real migrator waiting on the advisory owner. The first is mandatory order, the second a useful concurrency branch. Planned literal SDK message: **"lifecycle.candidate_activation_follows_successful_explicit_migration"**. |
| **Antithesis Angle** | Kill an updater while its systemd migrator survives, race two Marshall hosts on one PostgreSQL primary, and interrupt around schema commit. |
| **Why It Matters** | Serving new code on an unprepared schema or racing DDL can break the control plane. . |
| **Evidence** | [Source and oracle](properties/migration-finishes-before-upgrade-activation.md); discovery focus 08. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which native fixture can fault the real migrator and observe advisory-lock custody across two Marshall hosts? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### private-readiness-v1-gates-new-execution — Private readiness v1 gates new execution

| | |
|---|---|
| **Type** | Safety (`AlwaysOrUnreachable` primary) |
| **Priority / Confidence / Status** | P0 / medium-high / researched; primary unimplemented |
| **Property** | A new Lilly guest start with private services enabled requires exact affirmative Ziggy and Audi-private readiness for the configured role and host. |
| **Invariant** | `AlwaysOrUnreachable` checks each optional private-service start against exact v1 response documents and native launch effects. Planned literal SDK message: **"Private readiness v1 must match role and host before new guest execution"**. |
| **Antithesis Angle** | Delay, corrupt, or stale one local readiness response while a fresh start and an old running guest coexist. |
| **Why It Matters** | A socket or process being up cannot stand in for current private dependency readiness. |
| **Evidence** | [Source and oracle](properties/private-readiness-v1-gates-new-execution.md); discovery focus 10. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- None.

### runtime-restart-requires-fresh-readiness — Restart cannot inherit readiness

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | A restarted Lilly Runtime needs a new authenticated, delivered report and current actor reconciliations before exposing readiness, while surviving guests rejoin after recovery. |
| **Invariant** | `Always` checks every new-incarnation true readiness against current session/report and commands; `Sometimes(cond)` requires reauthentication, true readiness and unchanged VMMs after the database heals. Planned literal SDK message: **"lifecycle.restored_journal_cannot_authorize_fresh_runtime_readiness"**. |
| **Antithesis Angle** | SIGKILL Lilly one or two times during a PostgreSQL outage and restore database service across the 15-second report freshness boundary. |
| **Why It Matters** | Stale journals cannot safely certify new control authority; recovery should retain existing guests. . |
| **Evidence** | [Source and oracle](properties/runtime-restart-requires-fresh-readiness.md); discovery focus 08. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the hosted composition restart real Runtime during database outage while preserving the same physical guest? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### updater-failed-activation-recovers-live-roles — Interrupted activation handling

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | Caught incomplete activation attempts every prior live role independently and cannot advance unverified health. |
| **Invariant** | `Always(no skipped role after restoration failure && lastHealthy requires verification)`; supplementary `Sometimes(all prior roles restored)` after finite fault. Planned literal SDK message: **"Updater failed activation attempts every prior live role without claiming unverified health"**. |
| **Antithesis Angle** | Canceled systemd jobs, secret/switch/socket/role failure and surviving migration effects; whole-updater SIGKILL is separately scoped. |
| **Why It Matters** | Keeps one failed role from hiding neighbor restoration and avoids false healthy deployment receipts. |
| **Evidence** | [Source and oracle](properties/updater-failed-activation-recovers-live-roles.md); discovery focus 03. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which source-built native fixture can independently observe updater/migrator death and all restoration effects? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

### upgrade-preserves-owned-guests — Upgrade preserves physical guest custody

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / high / researched; primary unimplemented |
| **Property** | Lilly release and credential-only upgrades preserve unrelated guests' VMM and disk identities while the new release resumes authenticated control. |
| **Invariant** | `Always` compares physical PID/start-time/cgroup and disk GUID through each upgrade for control guests; `Sometimes(cond)` requires a healthy upgraded release, fresh host session and guest traffic through the same VMM after faults heal. Planned literal SDK message: **"lifecycle.upgrade_preserves_owned_vmm_and_disk_identity"**. |
| **Antithesis Angle** | Interrupt before/after consumer restart or switch, rotate same-closure credential bytes, and delay reconnection. |
| **Why It Matters** | Control-plane upgrades must not destroy running user work. . |
| **Evidence** | [Source and oracle](properties/upgrade-preserves-owned-guests.md); discovery focus 08. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which native fixture can retain and independently identify guest VMM/cgroup and disk across the release switch? `(partial: source investigated; selected composed fault/effect fixture remains unrun)`

## Public routes, SSH and editor effects

These properties join public route authority to real DNS, SSH and editor outcomes.

### authoritative-dns-follows-current-placement — Authoritative dns follows current placement

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | After route convergence, authoritative A answers name the current placement and connect to that guest; invalid publications fail closed. |
| **Invariant** | `Always` on each observed authoritative A answer against current converged route, with unique planned SDK message **"Authoritative DNS addresses follow the current published placement"**. A separately named `Sometimes` must witness an actual destination A answer and independently observed destination guest request after relocation; repeated SERVFAIL cannot satisfy the full claim. |
| **Antithesis Angle** | Lose responses, change current route or credential authority, and verify real DNS, SSH or editor effects. |
| **Why It Matters** | A stale successful answer can send a user to the former VM owner after a move. |
| **Evidence** | [Source, values and oracle](properties/authoritative-dns-follows-current-placement.md); evaluation gap access-routes. |

**Proof boundary:** Full DNS-plus-connection claim is a native two-Lilly KVM/ZFS acceptance target: observe each Audi authoritative DNS packet, the current destination physical boot and a real destination SSH/HTTPS nonce, with old-source refusal. The hosted `access` template can check only DNS packets against current Marshall publication; it cannot prove destination guest usefulness or a completed relocation. No full-property hosted template is selected. Current state: unexercised; no hosted catalog-property baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which event exposes each Audi replica’s accepted post-relocation revision without replacing the actual DNS query?

### editor-login-code-single-use-after-reply-loss — Editor login code single use after reply loss

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / authored primary; hosted unexecuted; positive path precondition-blocked |
| **Property** | One approved editor code and browser state create at most one personal credential despite duplicate callbacks or a lost reply. |
| **Invariant** | `Always` with unique planned SDK message **"Editor login code creates at most one credential after reply loss"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Lose responses, change current route or credential authority, and verify real DNS, SSH or editor effects. |
| **Why It Matters** | Duplicate redemption could mint extra editor credentials after a browser retry. |
| **Evidence** | [Source, values and oracle](properties/editor-login-code-single-use-after-reply-loss.md); evaluation gap access-routes. |

**Proof boundary:** Draft selection: `access`. real-hosted-browser-identity-or-DNS-packets; physical guest route separate; independent witness: actual public callback/DNS packet plus consistent PostgreSQL authority rows. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** The primary `Always`, a `Sometimes` positive exchange witness and a reply-loss `Reachable` are authored in `antithesis/workload/satellite/editor.py` and selected through `antithesis/test/v1/satellite/serial_driver_editor_login_reply_loss.py` in `satellite-standin`. The history uses a real browser login, Marshall launch and approval, two raced Audi callbacks (one optionally reply-lost), same-state replay and a wrong-state callback, and classifies only committed `editor_logins` and `editor_credentials` rows keyed by the ticket digest. Marshall's `begin_login` requires a current running VM on the Audi gateway's host and an editor-capable image release. The hosted controlled Lilly pool reports unavailable capacity, and that profile configures no editor release, editor wildcard or Audi editor gateway, so the command records unexercised and evaluates no assertion. The `Sometimes` witness will therefore show zero hits until an integrated host and editor gateway exist. Wrong-actor and wrong-hostname replays are not authored. No hosted run exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the selected public callback fixture race two Audi replicas and read committed credential cardinality without fabricating responses?

### editor-save-survives-worker-recovery — Editor save survives worker recovery

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | An acknowledged personal editor save remains readable under the same guest UID after worker recovery. |
| **Invariant** | `Always` with unique planned SDK message **"Personal editor save survives worker recovery under its owner's UID"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Lose responses, change current route or credential authority, and verify real DNS, SSH or editor effects. |
| **Why It Matters** | An acknowledged browser save must not disappear when its guest worker restarts. |
| **Evidence** | [Source, values and oracle](properties/editor-save-survives-worker-recovery.md); evaluation gap access-routes. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the selected editor-capable TCG image drive a real browser save acknowledgment and independent file read after worker recovery?

### editor-signout-fences-active-guest-write — Editor signout fences active guest write

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | After sign-out commits, an old editor session or cookie cannot admit a new guest write. |
| **Invariant** | `Always` with unique planned SDK message **"Signed-out editor session cannot write new guest bytes"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Lose responses, change current route or credential authority, and verify real DNS, SSH or editor effects. |
| **Why It Matters** | A signed-out browser must lose the ability to mutate guest files. |
| **Evidence** | [Source, values and oracle](properties/editor-signout-fences-active-guest-write.md); evaluation gap access-routes. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What lease deadline bounds closure of an existing editor stream after committed sign-out?

### revoked-ssh-key-refuses-fresh-guest-login — Revoked ssh key refuses fresh guest login

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | A removed SSH key cannot open a fresh guest login after its revocation commits. |
| **Invariant** | `Always` with unique planned SDK message **"Revoked SSH key cannot open a fresh guest login"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Lose responses, change current route or credential authority, and verify real DNS, SSH or editor effects. |
| **Why It Matters** | A removed key must not retain fresh shell access through cached gateway state. |
| **Evidence** | [Source, values and oracle](properties/revoked-ssh-key-refuses-fresh-guest-login.md); evaluation gap access-routes. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How can a live outer SSH session be retained across key removal while forcing a genuinely fresh inner authentication?

### strict-ssh-host-trust-reaches-current-guest — Strict ssh host trust reaches current guest

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Strict host-certificate validation accepts only the currently routed guest identity after placement changes. |
| **Invariant** | `Always` with unique planned SDK message **"Strict SSH host certificates reach only the current guest execution"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Lose responses, change current route or credential authority, and verify real DNS, SSH or editor effects. |
| **Why It Matters** | A valid host certificate must bind the shell to the newly current guest, not a stale route. |
| **Evidence** | [Source, values and oracle](properties/strict-ssh-host-trust-reaches-current-guest.md); evaluation gap access-routes. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which adapter captures the strict OpenSSH host-certificate transcript and pins the source address through relocation?

## Agent and named integration effects

These properties cover tool dispatch, renewable work and approved external origins.

### agent-long-fetch-result-retains-live-lease — Agent long fetch result retains live lease

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | One permitted slow guest fetch completes with the same command result while its renewable lease remains live. |
| **Invariant** | `Sometimes` with unique planned SDK message **"A permitted slow guest fetch reaches a durable completed tool result"**; one meaningful reached condition anchors conditional progress. |
| **Antithesis Angle** | Interrupt the tool or integration across durable start, renewal and upstream effect; compare command and origin ledgers. |
| **Why It Matters** | A permitted slow tool could finish its external fetch yet lose the durable command result. |
| **Evidence** | [Source, values and oracle](properties/agent-long-fetch-result-retains-live-lease.md); evaluation gap agent-integration. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `Sometimes` is existential; any selected per-operation progress claim needs a separate measured post-heal terminal check. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Does a controlled fetch lasting more than 30 seconds lose its final transition without an in-tool heartbeat? `(partial: 30-second lease and synchronous fetch are source-backed; composed timing run is absent)`

### agent-started-tool-effect-not-redispatched — Agent started tool effect not redispatched

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | A durably started agent command is never redispatched after uncertain executor loss. |
| **Invariant** | `Always` with unique planned SDK message **"A started agent command is never redispatched after uncertain executor loss"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt the tool or integration across durable start, renewal and upstream effect; compare command and origin ledgers. |
| **Why It Matters** | Retrying a started tool after executor loss could repeat an irreversible guest or provider effect. |
| **Evidence** | [Source, values and oracle](properties/agent-started-tool-effect-not-redispatched.md); evaluation gap agent-integration. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- The hosted `guest-vmm` must run real Lyra and its private verified TLS/relay path; a mock RPC or command-status-only test is insufficient. A TCG guest can establish actual file effect and software restart behavior, not Firecracker isolation. The prior native fixture is one strict sequence, not a?

### galileo-named-origin-credential-and-revocation-bound — Galileo named origin credential and revocation bound

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / partially instrumented; primary unimplemented |
| **Property** | Named integration requests use only their authorized origin and injected headers, and later effects stop after authority withdrawal. |
| **Invariant** | `Always` with unique planned SDK message **"Named integration uses its authorized origin and headers and stops after revoked renewal"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt the tool or integration across durable start, renewal and upstream effect; compare command and origin ledgers. |
| **Why It Matters** | A stale integration grant could send credentials or user data to a wrong origin after detachment. |
| **Evidence** | [Source, values and oracle](properties/galileo-named-origin-credential-and-revocation-bound.md); evaluation gap agent-integration. |

**Proof boundary:** Draft selection: `integrated-zfs-satellite`. proposed-real-guest-attached-named-integration; unbuilt; independent witness: actual pre-NAT guest identity, current attachment, exact origin/header and upstream effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `satellite-standin` selects this command with the origin and satellite overlays and a labelled guest stand-in. The command still needs a current running VM; the hosted controlled Lilly pool reports unavailable capacity, so it records unexercised in that graph. The stand-in is not a guest and supplies no VM binding. No hosted run exists.

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/satellite/scenarios.py:143`, `antithesis/workload/satellite/scenarios.py:207`, `antithesis/workload/satellite/scenarios.py:232`, `antithesis/workload/satellite/scenarios.py:270`. Separate checks cover origin A/headers, detached held-stream EOF, fresh no-effect refusal, and reattach progress. The canonical composed primary is absent without the exact aged-grant, recorder-delay and refused-renewal witnesses; the hosted guest-to-Audi graph is not ready. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a hosted fixture retain actual pre-NAT guest binding and live origin socket through ordinary attachment withdrawal? `(partial: native precedent exists; hosted composition is unbuilt)`

## Browser identity and administration

These properties test browser sign-in and current administrative authority across replicas.

### magic-link-preview-post-mfa-boundary — Magic link preview post mfa boundary

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / authored primary; hosted unexecuted; scope partial |
| **Property** | Preview GETs and pending MFA cannot turn a magic link into browser work authority. |
| **Invariant** | `Always` with unique planned SDK message **"Magic-link preview and pending MFA cannot grant browser work authority"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race preview, MFA, sign-out or role withdrawal across real browser sessions and Marshall replicas. |
| **Why It Matters** | Mail preview and unfinished MFA must not silently establish a working browser session. |
| **Evidence** | [Source, values and oracle](properties/magic-link-preview-post-mfa-boundary.md); evaluation gap browser-authority. |

**Proof boundary:** Draft selection: `access`. real-hosted-browser-identity-or-DNS-packets; physical guest route separate; independent witness: actual public callback/DNS packet plus consistent PostgreSQL authority rows. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-17 UTC):** Primary `always` message is present at `antithesis/workload/access/browser.py:298`. Marshall HTTPS/SQL token and login receipts after two preview GETs; then, per ADR-0160 (the earlier read-redirect expectation came from superseded ADR-0123/ADR-0131), the pending-MFA login on replica B is served an ordinary `/overview` read without verification or extra login, and a SecurityLive passkey rename on B is refused with no stored effect. Same-login WebAuthn positive is optional; Control room administrator step-up, guest bytes, same-origin failover and hosted execution remain unverified. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which exact browser fixture can control JS suppression for GET preview and resume the auto-submit POST without bypassing the real CSRF path? `(partial: existing native browser fixture exercises automatic visit; no hosted Antithesis browser fixture is defined)`

### remembered-cookie-revocation-cross-replica — Remembered cookie revocation cross replica

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / authored primary; hosted unexecuted; scope partial |
| **Property** | A revoked remembered cookie cannot mint or use new browser authority through another Marshall replica. |
| **Invariant** | `Always` with unique planned SDK message **"Revoked remembered cookie cannot mint or use browser authority across Marshall replicas"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race preview, MFA, sign-out or role withdrawal across real browser sessions and Marshall replicas. |
| **Why It Matters** | Copied cookies must not outlive sign-out through a second Marshall replica. |
| **Evidence** | [Source, values and oracle](properties/remembered-cookie-revocation-cross-replica.md); evaluation gap browser-authority. |

**Proof boundary:** Draft selection: `access`. real-hosted-browser-identity-or-DNS-packets; physical guest route separate; independent witness: actual public callback/DNS packet plus consistent PostgreSQL authority rows. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/access/browser.py:442`. Replica B exchange, replica A sign-out, replica B refusal, and exact SQL JTI sets; no guest byte witness, ordinary same-origin failover, or hosted execution. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which exact browser event provides the smallest deterministic committed mutation after remembered exchange, without requiring a guest boot? `(partial: MachinesLive provision has a durable admission path but needs a prepared image/host capacity fixture)`

### stale-admin-tab-current-mutation-authority — Stale admin tab current mutation authority

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / authored primary; hosted unexecuted; scope partial |
| **Property** | A mounted Control room tab cannot commit an administrative mutation after its actor loses current authority. |
| **Invariant** | `Always` with unique planned SDK message **"Stale Control room tab cannot commit an admin mutation after authority withdrawal"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race preview, MFA, sign-out or role withdrawal across real browser sessions and Marshall replicas. |
| **Why It Matters** | A stale tab could otherwise commit a privileged change after role withdrawal. |
| **Evidence** | [Source, values and oracle](properties/stale-admin-tab-current-mutation-authority.md); evaluation gap browser-authority. |

**Proof boundary:** Draft selection: `access`. real-hosted-browser-identity-or-DNS-packets; physical guest route separate; independent witness: actual public callback/DNS packet plus consistent PostgreSQL authority rows. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/access/browser.py:576`. Replica B mounted LiveView, real pre-fence set-role target/audit pair, closed Ash demotion, and processed post-fence event with unchanged inventory; hosted execution and guest effects remain unverified. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which user-facing control supplies the cleanest stale-event inventory with no dependent asynchronous worker effect? `(partial: set-role has target and audit rows; invite additionally creates outbox and mail jobs)`


## Customer create to retained guest use

This composed property tests whether a customer can use the identity and bytes produced by a create.

### authenticated-create-to-retained-guest-file — Authenticated create to retained guest file

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | One authenticated create binds its request, user and guest identity to a retained file usable after recovery. |
| **Invariant** | `Always` on every settled full-success claim with unique planned SDK message **"Authenticated create-to-guest-file success preserves request VM boot UID and fsynced bytes"**. A distinct mandatory `Reachable` fires only after healed reply uncertainty, real restart and a fresh authorized reread; a per-attempt ledger checks terminal state after a measured post-heal interval. One successful reach does not prove every create progresses. |
| **Antithesis Angle** | Lose create replies and restart guest owners while correlating public identity with a guest fsynced marker. |
| **Why It Matters** | A successful create is not useful if it yields the wrong user, boot or lost guest file. |
| **Evidence** | [Source, values and oracle](properties/authenticated-create-to-retained-guest-file.md); evaluation gap customer-journey. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a browser driver preserve one hidden create key through a lost LiveView reply and retry against Marshall B without changing the submitted shape? A fresh key would test another request, invalidating the idempotency portion.
- What exact read-only projection exposes the authoritative owner/key/VM/placement/epoch/GuestAccount tuple at the same snapshot as the journey ledger, and how is it tied to QEMU boot ID without trusting a stale UI row?
- Can the planned TCG image and browser-terminal path complete normal stop/start with persistent overlay, fresh boot and second personal terminal within a measured test budget? If not, hosted scope must report infeasible and native evidence cannot be inferred from it.
- Which selected fault and observed restoration point define the post-heal deadline for each attempt? Without those, report pending/inconclusive rather than universal per-op liveness.


## Clone, resize and relocation data

These properties test retained bytes and real routes through physical lifecycle changes.

### clone-two-drive-copy-survives-source-deletion — Clone two drive copy survives source deletion

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | A published two-drive clone retains acknowledged root and data bytes after its source is deleted. |
| **Invariant** | `Always` with unique planned SDK message **"Cloned root and data drives retain independent acknowledged bytes after source deletion"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Fault copy, resize or handoff boundaries and compare independent disk bytes, GUIDs and current route. |
| **Why It Matters** | Deleting a clone source must not erase or alias the clone’s second drive. |
| **Evidence** | [Source, values and oracle](properties/clone-two-drive-copy-survives-source-deletion.md); evaluation gap data-journeys. |

**Proof boundary:** Draft selection: `no selected hosted template`. two-host-native-KVM-and-ZFS-required-for-full-claim; independent witness: two independently current VMMs, retained root/data GUID and bytes, committed handoff and actual DNS/SSH route. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which Inception guest path/mount exposes a stable, fsyncable marker on the `data.raw` inner filesystem, and how can the workload obtain a bounded independent digest without logging terminal bytes?

### resize-retains-exact-guest-bytes-and-grown-shape — Resize retains exact guest bytes and grown shape

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | A confirmed resize preserves acknowledged guest bytes and exposes the requested physical shape. |
| **Invariant** | `Always` with unique planned SDK message **"Confirmed resize preserves fsynced guest bytes and reports exact physical shape"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Fault copy, resize or handoff boundaries and compare independent disk bytes, GUIDs and current route. |
| **Why It Matters** | A successful resize must preserve data and expose the capacity it reports. |
| **Evidence** | [Source, values and oracle](properties/resize-retains-exact-guest-bytes-and-grown-shape.md); evaluation gap data-journeys. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the composed Antithesis guest fixture expose the VMM API and retained block device across a Lilly crash while preserving exact boot/placement identity?

### stopped-relocation-retains-bytes-and-routes-to-destination — Stopped relocation retains bytes and routes to destination

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | After stopped relocation settles, retained guest bytes are served at the destination and old-source routing refuses. |
| **Invariant** | `Always` with unique planned SDK message **"Stopped relocation serves retained guest bytes at destination and refuses former source route"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Fault copy, resize or handoff boundaries and compare independent disk bytes, GUIDs and current route. |
| **Why It Matters** | A committed move is unusable if bytes or public routes still point at the old host. |
| **Evidence** | [Source, values and oracle](properties/stopped-relocation-retains-bytes-and-routes-to-destination.md); evaluation gap data-journeys. |

**Proof boundary:** Draft selection: `no selected hosted template`. two-host-native-KVM-and-ZFS-required-for-full-claim; independent witness: two independently current VMMs, retained root/data GUID and bytes, committed handoff and actual DNS/SSH route. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the native fixture hold the source disk at a documented point after destination readiness but before cleanup and read the destination then?


## Physical isolation and egress

These properties require actual packet and process witnesses at the guest boundary.

### brady-flow-attribution-requires-current-incarnation — Brady flow attribution requires current incarnation

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Brady assigns each new flow only to the current labeled guest execution incarnation. |
| **Invariant** | `Always` with unique planned SDK message **"Brady resolves flow ownership only for the current labeled execution incarnation"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race guest/proxy/owner loss with forbidden and allowed traffic; observe receiver packets and physical confinement. |
| **Why It Matters** | Address reuse must not give a new guest the old guest’s egress policy. |
| **Evidence** | [Source, values and oracle](properties/brady-flow-attribution-requires-current-incarnation.md); evaluation gap isolation-egress. |

**Proof boundary:** Draft selection: `storage`. standalone-real-TPROXY-router-and-TCG-ZFS; does-not-prove-Lilly-backing; independent witness: real guest packet/origin/cache-object/connection ledger and independent flow labels. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How can the harness retain and identify one accepted Brady socket through address reuse without exposing the URL or guest bytes?

### brady-forbidden-destinations-never-reach-upstream — Brady forbidden destinations never reach upstream

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Forbidden original destinations never receive a Brady upstream connection or enter its shared cache. |
| **Invariant** | `Always` with unique planned SDK message **"Forbidden original destinations never reach Brady upstream or shared cache"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race guest/proxy/owner loss with forbidden and allowed traffic; observe receiver packets and physical confinement. |
| **Why It Matters** | A forbidden destination must not be reachable through proxy fallback or cache. |
| **Evidence** | [Source, values and oracle](properties/brady-forbidden-destinations-never-reach-upstream.md); evaluation gap isolation-egress. |

**Proof boundary:** Draft selection: `storage`. standalone-real-TPROXY-router-and-TCG-ZFS; does-not-prove-Lilly-backing; independent witness: real guest packet/origin/cache-object/connection ledger and independent flow labels. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How will the router fixture create several routable but forbidden addresses without accidentally crossing the host's real network?

### brady-proxy-loss-preserves-web-and-quic-denial — Brady proxy loss preserves web and quic denial

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Loss of the proxy cannot open direct guest HTTP, HTTPS or QUIC egress. |
| **Invariant** | `Always` with unique planned SDK message **"Proxy loss never opens direct guest web or QUIC egress"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race guest/proxy/owner loss with forbidden and allowed traffic; observe receiver packets and physical confinement. |
| **Why It Matters** | Proxy failure must not create a direct web or QUIC escape path. |
| **Evidence** | [Source, values and oracle](properties/brady-proxy-loss-preserves-web-and-quic-denial.md); evaluation gap isolation-egress. |

**Proof boundary:** Draft selection: `storage`. standalone-real-TPROXY-router-and-TCG-ZFS; does-not-prove-Lilly-backing; independent witness: real guest packet/origin/cache-object/connection ledger and independent flow labels. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the TCG router expose origin TCP/UDP effect logs and nft counters as one monotonic private oracle during crash/reload?

### brady-sensitive-exchanges-never-reuse-shared-cache — Brady sensitive exchanges never reuse shared cache

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Credentialed requests never reuse, and private responses never populate, Brady’s shared cache. |
| **Invariant** | `Always` with unique planned SDK message **"Credentialed requests never reuse and private responses never enter Brady shared cache"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race guest/proxy/owner loss with forbidden and allowed traffic; observe receiver packets and physical confinement. |
| **Why It Matters** | Shared cache reuse could disclose credentialed or private responses across guests. |
| **Evidence** | [Source, values and oracle](properties/brady-sensitive-exchanges-never-reuse-shared-cache.md); evaluation gap isolation-egress. |

**Proof boundary:** Draft selection: `storage`. standalone-real-TPROXY-router-and-TCG-ZFS; does-not-prove-Lilly-backing; independent witness: real guest packet/origin/cache-object/connection ledger and independent flow labels. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- What harness-private cache inventory API can associate an object with a synthetic response hash without reading production-like payloads?

### native-firecracker-confinement-survives-owner-recovery — Native firecracker confinement survives owner recovery

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Every current Firecracker execution retains its jail UID, namespace and cgroup confinement after owner recovery. |
| **Invariant** | `Always` with unique planned SDK message **"Current Firecracker execution retains its jail UID namespace and cgroup confinement"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race guest/proxy/owner loss with forbidden and allowed traffic; observe receiver packets and physical confinement. |
| **Why It Matters** | Re-adoption must not turn a jailed VMM into an unconstrained host process. |
| **Evidence** | [Source, values and oracle](properties/native-firecracker-confinement-survives-owner-recovery.md); evaluation gap isolation-egress. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-KVM-physical-boundary-only; independent witness: actual Firecracker PID/start, jail namespace/UID/cgroup, TAP/nft packet receiver and guest profile. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- How will a test-only root monitor expose a stable per-PID process-start/pidfd sample under concurrent exit?

### native-guest-packets-obey-profile-and-tap-boundaries — Native guest packets obey profile and tap boundaries

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Guest packets cannot cross forbidden profile, TAP or destination boundaries. |
| **Invariant** | `Always` with unique planned SDK message **"Physical guest packets cannot cross forbidden profile TAP or destination boundaries"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Race guest/proxy/owner loss with forbidden and allowed traffic; observe receiver packets and physical confinement. |
| **Why It Matters** | A profile or TAP escape could cross the guest network isolation boundary. |
| **Evidence** | [Source, values and oracle](properties/native-guest-packets-obey-profile-and-tap-boundaries.md); evaluation gap isolation-egress. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-KVM-physical-boundary-only; independent witness: actual Firecracker PID/start, jail namespace/UID/cgroup, TAP/nft packet receiver and guest profile. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a workload-owned packet collector capture both accepted and refused attempts without relying on a client timeout?


## Operational publication and independent user effects

These properties test host/guest update, enrollment, secrets and diagnostic fault separation.

### diagnostic-outage-preserves-authorized-user-effect — Diagnostic outage preserves authorized user effect

| | |
|---|---|
| **Type** | Liveness (`Sometimes` primary) |
| **Priority / Confidence / Status** | P1 / source-grounded / researched; primary unimplemented |
| **Property** | A designated authorized guest effect completes through a finite diagnostic outage without treating measurement gaps as success. |
| **Invariant** | `Sometimes` with unique planned SDK message **"Authorized guest effect completes during a finite diagnostic outage"**; one meaningful reached condition anchors conditional progress. |
| **Antithesis Angle** | Interrupt activation, secret publication or diagnostics and compare actual effects with durable receipts. |
| **Why It Matters** | A measurement outage should not strand valid user work or masquerade as a successful effect. |
| **Evidence** | [Source, values and oracle](properties/diagnostic-outage-preserves-authorized-user-effect.md); evaluation gap operations. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `Sometimes` is existential; any selected per-operation progress claim needs a separate measured post-heal terminal check. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Which hosted or native fixture can fault recorder, spool and Collector separately while preserving the real authenticated producer, Lilly Control exchange and a booted guest independent effect oracle?

### host-enrollment-receipt-follows-live-health — Host enrollment receipt follows live health

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / source-grounded / researched; primary unimplemented |
| **Property** | A host enrollment receipt follows exact identity and storage binding plus live role health. |
| **Invariant** | `Always` with unique planned SDK message **"Host enrollment receipt follows authenticated binding and live role health"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt activation, secret publication or diagnostics and compare actual effects with durable receipts. |
| **Why It Matters** | An enrollment receipt should not advertise a host whose pinned identity or live roles failed. |
| **Evidence** | [Source, values and oracle](properties/host-enrollment-receipt-follows-live-health.md); evaluation gap operations. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-NixOS-systemd-secrets-storage-only; independent witness: exact physical GUID/credential generation/binary digest, live role health and durable receipt. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a native source-built fixture independently capture exact Marshall operation identity, Lilly polling status and physical storage GUID during the same interrupted enrollment?

### lyra-guest-update-fences-executor-handoff — Lyra guest update fences executor handoff

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / source-grounded / researched; primary unimplemented |
| **Property** | A Lyra update runs only verified candidate bytes after the old executor exits; failed registration restores the prior executor. |
| **Invariant** | `Always` with unique planned SDK message **"Lyra guest update never runs unverified or overlapping executors"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt activation, secret publication or diagnostics and compare actual effects with durable receipts. |
| **Why It Matters** | An update could duplicate tool effects or run unverified guest code during handoff. |
| **Evidence** | [Source, values and oracle](properties/lyra-guest-update-fences-executor-handoff.md); evaluation gap operations. |

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-integrated-ZFS-backed-Lilly-with-TCG-guest; unbuilt; independent witness: current authority and boot tuple plus independent guest editor/SSH/file/PTY effect. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a source-built real guest fixture control candidate registration and stop/interrupt the seed at each durable handoff without replacing the real supervisor or guest executable?

### runtime-secret-bundle-complete-or-previous — Runtime secret bundle complete or previous

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / source-grounded / researched; primary unimplemented |
| **Property** | Secret publication exposes either a complete new bundle or the previous complete bundle. |
| **Invariant** | `Always` with unique planned SDK message **"Runtime secret bundle publication is complete or retains the previous bundle"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt activation, secret publication or diagnostics and compare actual effects with durable receipts. |
| **Why It Matters** | Partial secret publication can break live services or expose wrong ownership. |
| **Evidence** | [Source, values and oracle](properties/runtime-secret-bundle-complete-or-previous.md); evaluation gap operations. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-NixOS-systemd-secrets-storage-only; independent witness: exact physical GUID/credential generation/binary digest, live role health and durable receipt. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the native secret-custody fixture schedule a crash immediately before and after `RENAME_EXCHANGE` while the independent consumer samples the published directory?


## Optional recursive profile

This property requires both outer and inner authority in an enabled Inception environment.

### inception-parent-publication-cannot-confer-child-authority — Inception parent publication cannot confer child authority

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / researched; primary unimplemented |
| **Property** | Nested forwarding requires current parent authority and each child effect still requires independent child authorization. |
| **Invariant** | `Always` with unique planned SDK message **"Inception nested forwarding requires a current parent lease and child effects require child authorization"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Withdraw parent or child authority while an Inception stream and inner effect are live. |
| **Why It Matters** | Outer forwarding must not grant access that the nested child never authorized. |
| **Evidence** | [Source, values and oracle](properties/inception-parent-publication-cannot-confer-child-authority.md); evaluation gap optional-profiles. |

**Proof boundary:** Draft selection: `no selected hosted template`. native-KVM-physical-boundary-only; independent witness: actual Firecracker PID/start, jail namespace/UID/cgroup, TAP/nft packet receiver and guest profile. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can the current builder execute the full nested-KVM fixture and retain two inner stacks under its actual capacity?


## Backup publication and isolated restore

These properties compare actual Restic publication and isolated target markers under interruption.

### backup-interrupted-restore-target-unpublished — Backup interrupted restore target unpublished

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P0 / source-grounded / authored primary; hosted unexecuted; scope partial |
| **Property** | An interrupted component restore never publishes a partial isolated target as complete. |
| **Invariant** | `Always` with unique planned SDK message **"Interrupted backup restore leaves its partial target unpublished"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt real Restic publication or restoration and compare repository/target markers with independent hashes. |
| **Why It Matters** | An incomplete restore must not look like a recoverable published point. |
| **Evidence** | [Source, values and oracle](properties/backup-interrupted-restore-target-unpublished.md); evaluation gap restore-publication. |

**Proof boundary:** Draft selection: `storage`. real-Restic-isolated-target; native-guest-ZFS-companion; independent witness: actual Restic tag/manifest parser, target publication marker and independent restored component hash. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `backup-restic` selects the five `backup` commands with `compose.backup.yaml`, which gives each command a disposable encrypted Restic file repository on a dedicated private named volume. Bootstrap requires the production operator, pinned Restic and a real probe repository that initializes and enumerates empty there. A local file backend is deliberate: the production operator returns one failure status for repository unavailability and validator refusal, so a network-attached repository would make unavailable reads look like refusals. This profile exercises no ZFS, host capture, S3 or live recovery target and has no hosted run or baseline yet.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/backup/scenarios.py:172`. Production restore CLI with fixed Restic interruption gate, marker/prefix and fresh retry; no hosted run. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can an interrupted guest-disk restore retain an independently inventoried partial target? `(partial: generated Restic interruption and native host/DB restore exist; guest-disk campaign is absent)`

### backup-published-manifest-retention-compatible — Backup published manifest retention compatible

| | |
|---|---|
| **Type** | Safety (`Always` primary) |
| **Priority / Confidence / Status** | P1 / source-grounded / authored primary; hosted unexecuted; scope partial |
| **Property** | Every newly published backup point passes the same manifest schema and time validation used for retention. |
| **Invariant** | `Always` with unique planned SDK message **"Newly published backup point passes its retention manifest validator"**; each reached effect or settled observation must satisfy the invariant. |
| **Antithesis Angle** | Interrupt real Restic publication or restoration and compare repository/target markers with independent hashes. |
| **Why It Matters** | A complete-looking point that retention cannot parse can poison later recovery cleanup. |
| **Evidence** | [Source, values and oracle](properties/backup-published-manifest-retention-compatible.md); evaluation gap restore-publication. |

**Proof boundary:** Draft selection: `storage`. real-Restic-isolated-target; native-guest-ZFS-companion; independent witness: actual Restic tag/manifest parser, target publication marker and independent restored component hash. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `backup-restic` selects the five `backup` commands with `compose.backup.yaml`, which gives each command a disposable encrypted Restic file repository on a dedicated private named volume. Bootstrap requires the production operator, pinned Restic and a real probe repository that initializes and enumerates empty there. A local file backend is deliberate: the production operator returns one failure status for repository unavailability and validator refusal, so a network-attached repository would make unavailable reads look like refusals. This profile exercises no ZFS, host capture, S3 or live recovery target and has no hosted run or baseline yet.

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/backup/scenarios.py:235`. Actual coordinator publication plus raw Restic/production inspect; backward wall-clock step remains unimplemented. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

**Open Questions:**

- Can a scoped clock fault step the coordinator backward while Restic and TLS S3 remain healthy? `(partial: source exposes independent time samples; no actual clock-step campaign)`
- Does an actual backward-step capture reach a tag-visible point, or does an earlier check refuse it?
