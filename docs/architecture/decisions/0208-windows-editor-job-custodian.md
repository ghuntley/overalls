# ADR-0208: Independent Windows editor job custodian

- ID: ADR-0208
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Windows editor broker, Windows job custodian, Windows image, Task Scheduler, Marshall Editor, Audi, Lilly, shared protocol, Lyra account reconciler
- Supersedes: ADR-0200
- Superseded by: none

## Context

The authorized Windows browser editor implementation continues the separate
candidate from [ADR-0200](0200-windows-browser-editor-candidate.md). Its official
source, personal account, transport, immutable image and production-selection
requirements remain binding. This record replaces that entire decision and
carries its clauses 1, 3, 5, 7 and 8 unchanged. It replaces the process-lifetime
and supervision design; it does not partially supersede metadata or change
ADR-0171's existing `windows-v1` editor exclusion.

The stock native fixture opened the workbench, exercised its extension, saved a
file and used a real PowerShell PTY, then failed broker recovery. A retained
real worker could remain alive while reopening its exact named job failed with
Win32 error 2. A disposable SYSTEM experiment subsequently created and assigned
a child, verified its creation identity, opened the job, then closed the final
job handle: the child remained live while the name could no longer be opened.
The observed result disproves the old assumption that a running child preserves
a reopenable named Job Object after broker handle loss. A receipt alone cannot
restore that kernel custody. These are bounded native observations of the old
architecture, not acceptance of the replacement.

The user has authorized completing the Windows implementation. A reviewed
independent SYSTEM custodian is accepted under that authorization. It owns the
full worker launch transaction and job handles, while a separate broker owns
gateway TCP admission. The inherited image/protocol implementation is partial;
the new custodian, installation, native failure bounds and exact candidate
browser journey require separate implementation and executed evidence.

## Decision

1. **Build the Windows payload from the reviewed official Code OSS source.**
   Keep the pinned source, maintained browser/policy patches, product policy,
   signed extension inputs, Windows Node/ripgrep runtime and native build inputs
   in the release identity. Stage an offline source kit for a native Windows
   build. Import a completed bundle only against its caller-reviewed recursive
   NAR hash, exact protocol/source/release descriptor, native completion marker
   and required payloads. Neither a source kit nor a successful import grants
   image capability. Desktop Electron and a downloaded server distribution are
   outside this candidate.

2. **Separate gateway admission from independent SYSTEM job custody.** The
   LocalSystem broker binds the MMDS guest address on dedicated TCP port 4444,
   accepts only the current MMDS gateway, and validates the existing closed
   preface and immutable package descriptor against the placement/execution boot
   identity. It then connects to the local custodian and proxies the accepted
   stream. Public guest web publication cannot authorize this port. Marshall,
   Audi and Lilly retain their current-login, current-write, personal-origin,
   transport and execution checks. The custodian runs from the same pinned
   executable in a separate SYSTEM task and independently validates its own
   MMDS boot, release, binding and current roster account before worker use.

3. **Use current local SAM accounts and verified S4U identity.** Resolve the
   canonical `u<uid>` account through Lyra's locked roster authorizer before
   every worker admission. Require an enabled ordinary local account, an exact
   local SAM SID and a matching primary S4U token SID. Use its native profile
   and bounded explicit environment. Validate executable and PATH custody,
   ancestors, ACLs and reparse-point refusal before launch. A username, supplied
   UID, arbitrary SID, cached successful login or environment search cannot
   substitute for these checks.

4. **Keep the entire worker transaction and every job handle in the
   custodian.** Launch direct Node with the personal token, no inherited handles
   and suspended state. Attach it to the exact SYSTEM-only job atomically at
   process creation with `PROC_THREAD_ATTRIBUTE_JOB_LIST`, before any personal
   code can execute; do not create an unattached child and assign it later.
   Configure `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Bind the pipe/job identity and
   complete private receipt to placement, execution epoch, GuestAccount UUID,
   UID, account name, SID, personal origin and release descriptor. Retain the job
   handle throughout that runtime; never transfer or duplicate it to the broker
   or worker. The custodian owns launch, receipt publication, resume, validation,
   readiness and the exact worker-pipe connection. It commits a runtime entry
   only after its complete receipt has been published and the launch transaction
   succeeds. Partial launches retain cleanup ownership through RAII and must not
   become live map entries. A worker root/pipe reuse requires its retained PID,
   creation time, token SID, executable, job membership and pipe-server PID.
   Foreign, ambiguous or incompletely observed custody refuses without
   terminating it. This decision removes broker adoption of jobs after losing
   their final handles.

5. **Bound pending native I/O and startup work.** Overlapped pipe operations
   own their buffers and completion state. Timeout cancels and retires the
   operation without allowing the kernel to reference caller storage. Live
   pipes and undrained cancellations share a finite global reservation budget;
   exhaustion refuses new work. Account startup, readiness and connection
   admission also remain bounded. Portable models establish finite state rules,
   while native tests must establish actual Win32 cancellation and custody.

6. **Install two independent fixed SYSTEM tasks.** `EditorBroker` runs the
   fixed `start.ps1` action with `broker.json`; `EditorCustodian` runs the fixed
   `start-custodian.ps1` action with `--custodian custodian.json` on the same
   pinned executable. Each startup wrapper validates its exact executable,
   configuration, private state and reviewed trust bundle. Their closed
   descriptor and worker configuration agree; their copied trust bundle paths
   are separate so restarting one role cannot overwrite the other's live input.
   Both tasks have boot triggers, unlimited execution time, `IgnoreNew`, 999
   restart attempts at one-minute intervals, and the exact private scheduler
   DACL. Their settings remain independent of generic guest task configuration.
   Native failure maps every nonzero process result to ordinary task failure one;
   only actual zero remains success. Package/configuration writes remain
   SYSTEM/Administrators-controlled and receipts SYSTEM-only. Only the broker
   receives the existing gateway-only TCP 4444 firewall rule. These console
   tasks do not claim an SCM service entry point. Registration alone does not
   prove restart, crash or reboot behavior.

7. **Give the editor candidate a separate immutable protocol contract.**
   Add `windows-editor-v1`; never widen `windows-v1`. Version-7 manifests
   require exactly Windows/x86_64, firmware boot with PCI, a raw-GPT root,
   resource minima, workspace-source version null or 2, and the required
   closed `EditorRelease` protocol/commit/release tuple. The ordered
   `lilly-image-v7` identity includes every requirement, descriptor and artifact
   byte length/digest. Portable firmware bundle version 4 retains the same OS,
   agent row and editor tuple; the optional version-1 Git identity capability
   remains independently explicit. Closed v5/v2 codecs continue to reject
   editor fields and the new row. Marshall binds capability to the exact
   immutable row ID and the release configured for its validated target;
   Lilly preserves the tuple on placement-local starts. Marshall and Audi use
   a closed version-1 target registry containing only `linux-x64` and
   `win32-x64`, with exact descriptors and distinct release digests. Unknown or
   malformed entries refuse; an empty registry disables the editor. No legacy
   singleton reader remains. Each gateway reports a separate five-second
   receipt per full release tuple under its current service/session identity.
   Every advertised editor or neutral webview gateway needs the complete
   configured set because shared webview DNS cannot route by release. Apply
   the receipt-index migration first, then atomically rebuild each host's
   application and configuration; an old Linux-only gateway under a two-target
   registry remains absent from discovery until both receipts are current.
   This candidate protocol is implementation support,
   not evidence that a particular native image passed acceptance.

8. **Keep promotion as a separate image-bound acceptance step.** Candidate
   runtime, broker, source/bundle imports and installation continue to declare
   `editor_capability = false`. No existing Windows manifest, agent-set row,
   catalog image or origin is widened by this decision. Only the separately
   constructed optional v7 candidate image may declare the new row. Production
   selection requires reviewed native Windows/browser evidence for its exact
   bundle and image identity, plus protocol and both consumer checks. Until
   that evidence is recorded, the candidate stays outside the selected catalog
   and ADR-0171's existing false editor row remains in force.

9. **Use one fixed boot-bound local streaming proxy.** The custodian endpoint
   is derived from the validated MMDS physical boot state key and is not
   configurable by a request or image argument. The named pipe is local-only
   and SYSTEM-only. Both sides verify the peer's kernel PID, creation identity,
   SYSTEM token and exact pinned executable, retaining process handles while
   relying on that identity. A path, client claim or PID alone is insufficient.
   The custodian uses a closed, versioned, bounded admission exchange, validates
   the binding independently, opens the exact worker pipe, and returns readiness
   only after its checks succeed. HTTP/WebSocket bytes then pass through this
   streaming proxy; no raw job handle or arbitrary process-management operation
   is exposed. Existing bounded overlapped-I/O and cancellation custody applies
   to both pipe hops. Logs contain only closed event/reason enums.
10. **Bound and account for retained runtimes.** The custodian owns at most 64
    stable account slots during its lifetime, including empty reservations,
    live workers and quarantined launches, with single-flight admission per
    account. A root process loss requires terminating its exact owned job
    and observing zero descendants before retiring that entry or replacing it.
    Failed accounting or drainage quarantines the slot; it cannot silently
    release capacity or authorize a replacement. Release/account drift and
    stale boot/receipt identity refuse. Use a new `custodian-v1` receipt namespace;
    the old broker-only receipts cannot authorize custody in this design.
11. **Keep broker and custodian failures distinct.** Broker death ends its
    streams and closes its proxy connections while the independent custodian
    retains workers and job handles. A new broker must repeat gateway/preface
    and local-peer validation before reconnecting. Custodian death closes its
    handles and must terminate all owned job descendants through kill-on-close;
    a restarted custodian creates a new validated worker, preserving personal
    files, rather than claiming adoption from a vanished job name. Native tests
    must establish the termination and restart bounds. Missing, foreign or
    incomplete custody still refuses cleanup or replacement; process exit,
    receipt presence and successful task registration do not establish those
    bounds.

## Alternatives

Keeping the last job handles in the network broker was rejected because the
native experiment showed that its death can remove the name while a child
survives. Duplicating handles into editor workers was rejected because personal
processes must not receive SYSTEM job ownership, and their lifetime would still
control recovery custody. Running only a handle keeper while the broker launches
workers was rejected because a broker crash could leave an incomplete launch or
an unaccounted process between creation and ownership transfer. The custodian
therefore owns the whole transaction and atomic job-list creation. Retaining a
single task or placing the custodian under the broker would preserve the same
failure boundary. Task registration and exit normalization alone cannot repair
lost kernel job custody.

The rejected alternatives and rationale in ADR-0200 remain applicable: personal
workers cannot run as SYSTEM or share an origin; loopback tokens do not replace
SAM/process custody; Linux process groups and systemd are not Windows semantics;
prebuilt or first-boot-downloaded servers violate the official-source/offline
boundary; compilation cannot establish native account, pipe or browser behavior.

## Consequences

The broker can restart without becoming the lifetime owner of personal workers.
The custodian is a separate privileged component and local IPC boundary, with
its own bounded registry, pipe reservations, startup and supervision. Its crash
intentionally ends owned workers; personal files remain independent of worker
processes. Recovery must distinguish broker stream loss, worker root loss,
quarantined drainage and custodian death. This adds failure cases and native
verification obligations; it does not establish confidentiality from guest
Administrators, physical VM isolation or multi-host recovery.

All official-source, SAM/S4U, exact image/release, finite I/O and promotion
requirements carried from ADR-0200 remain binding. The existing immutable
candidate contains the old broker and is unqualified for this design. A changed
broker/installer requires a newly bound image and the complete image-specific
acceptance journey before production selection; no package or capability marker
is promoted by this decision.

## Invariants and verification

- Preserve all ADR-0200 image, bundle, registry, receipt, account, package/PATH,
  privacy, terminal and current authority refusal properties. Shared protocol
  changes, if any, require library and both consumer gates.
- Model and test per-account single-flight, at most 64 reserved/live/quarantined
  slots, incomplete launch cleanup, receipt publication, zero-descendant
  retirement and refusal on failed accounting. Portable results cannot prove
  Win32 process or job semantics.
- Native tests must fault each launch stage and prove that atomic job-list
  attachment plus RAII leaves no unowned child, receipt or runtime entry.
- Native peer tests must reject a non-SYSTEM, wrong-executable, PID-reused,
  foreign-boot or remote pipe peer, and stale/mismatched account/release bindings.
  Both roles must independently establish their stated admission boundaries.
- The packaged browser journey must prove broker restart retaining the exact
  worker, custodian termination killing all owned descendants within the bounded
  deadline, task restart obtaining a new worker while preserving files, worker
  root-loss drainage, two-account separation and current-login/write revocation.
  It must execute through the local proxy and both independently installed tasks.
- Re-run overlapped-I/O idle, cancellation, timeout and worker-loss tests across
  both pipe hops, including shared pipe-budget exhaustion and refused startup.
- Record the exact native bundle/image and source revision for every result.
  Preserve the old candidate's exclusion until complete native acceptance.

## Implementation evidence

The existing [image codec](../../../protocol/lib/overalls_protocol/image_manifest.ex),
[bundle codec](../../../protocol/lib/overalls_protocol/workload_bundle.ex),
[capability table](../../../protocol/lib/overalls_protocol/guest_agents.ex),
[Lilly bundle writer](../../../lilly/lib/lilly/vm/workload_bundle.ex) and
[Marshall image facts](../../../marshall/lib/marshall/compute/image.ex) support the
inherited v7/v4 candidate boundary. The existing
[target registry](../../../marshall/lib/marshall/editor/releases.ex) and
[per-release receipts](../../../marshall/lib/marshall/ingress/editor_assets_receipt.ex)
retain exact-target asset discovery. ADR-0200 preserves their historical
implementation and verification record; none establishes the new custodian.

The [Win32 launcher](../../../nix/domains/artifacts/vscode-web-broker/src/windows/worker.rs)
now creates suspended workers with an atomic job-list attribute, no inherited
handles and a retained kill-on-close job. The
[custodian entry](../../../nix/domains/artifacts/vscode-web-broker/src/windows_main.rs)
owns complete receipts, per-account single-flight, the bounded runtime map,
resume/readiness and failed-launch quarantine. Its
[account map](../../../nix/domains/artifacts/vscode-web-broker/src/windows_model.rs)
retains all 64 stable account reservations, including empty failed attempts,
for the custodian lifetime. These source paths are implementation evidence,
not executed Win32 acceptance.

The [local IPC implementation](../../../nix/domains/artifacts/vscode-web-broker/src/windows_ipc.rs)
derives the local SYSTEM-only pipe from the physical boot state key. Its closed
version-1 hello binds both sides' kernel process identities to the exact installed
executable, and its length-delimited frames use existing bounded
[overlapped pipe custody](../../../nix/domains/artifacts/vscode-web-broker/src/windows_pipe.rs).
The [installer](../../../nix/domains/artifacts/guest/windows/install-editor.ps1)
and [custodian wrapper](../../../nix/domains/artifacts/guest/windows/start-custodian.ps1)
declare both independent tasks and separate copied trust bundles. Complete
two-role peer, capacity, task and failure execution remains required.

An earlier checkpoint refused every existing receipt in the same physical boot
namespace, because a dead root and vanished job name cannot establish that old
descendants have drained. That conservative refusal did not implement clause
11. [ADR-0237](0237-windows-custodian-same-boot-recovery.md) now supplies the
quiescence mechanism without changing this decision: each custodian lifetime
takes a durable per-boot generation that scopes job, pipe and version-2 receipt
names, and a cold receipt from an earlier generation is retired only after its
job name has vanished and a complete process snapshot shows zero processes of
the worker's exact account logon session, terminating only re-verified
stragglers of that session. Ambiguity still refuses. The source, portable
properties and Windows compilation are ADR-0237 evidence; native custodian
crash and straggler execution remain missing and must stay visible in the
candidate's acceptance record. A retained custodian still replaces only its
exact owned job after zero-descendant accounting.
A retained live root's failed readiness/pipe probe refuses without authorizing
termination; only a verified-dead held root permits drainage of its exact owned
job. Process-observation errors also refuse. Current roster/SAM validation runs
inside that account's reserved single-flight lock.

The exact 38-test library subsequently ran as SYSTEM with verified process exit
zero and no failed or ignored tests. Its four added native tests establish atomic
job-list membership of a disposable suspended SYSTEM root and its exit within a
five-second wait after final job close, endpoint exclusivity/SYSTEM ACL custody,
same-test-process mutual kernel-identity handshake and forged-creation refusal.
They do not execute personal S4U Code OSS launch, descendants, independently
scheduled role processes, custodian crash replacement or an immutable candidate's
browser journey. The review records the exact artifact/result; implementation
remains partial.

The
[architecture review](../reviews/2026-10-18-windows-editor-job-custodian.md)
records native old-design observations, current source boundaries and remaining
acceptance gaps. Implementation remains partial because same-boot custodian
recovery has source and portable evidence only, and the new failure boundary is
not yet accepted in an immutable image.

## Open questions

Native fault injection must establish
atomic launch, complete descendant termination and restart deadlines, including
custodian loss with root and child processes alive. Final source review must
reconcile receipt transactions, quarantine and capacity accounting, peer identity,
cancellation and both task installations. The version-1 local framing remains
closed and bounded; it does not expand process-management authority. Same-boot
replacement after custodian loss follows ADR-0237's logon-session quiescence
proof and still needs native execution. No unresolved acceptance gap authorizes production selection or changes
the existing false capability row.

## Related decisions

[ADR-0237](0237-windows-custodian-same-boot-recovery.md),
[ADR-0200](0200-windows-browser-editor-candidate.md),
[ADR-0153](0153-official-source-browser-editor.md),
[ADR-0158](0158-durable-guest-identities.md),
[ADR-0161](0161-monospace-web-presentation.md),
[ADR-0169](0169-firmware-booted-windows-guests.md),
[ADR-0171](0171-windows-guest-agents.md),
[ADR-0173](0173-windows-images-winget-desktop-experience.md),
[ADR-0190](0190-native-kernel-provenance-and-admission.md).
