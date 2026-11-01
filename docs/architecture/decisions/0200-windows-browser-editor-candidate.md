# ADR-0200: Account-bound Windows browser editor candidate

- ID: ADR-0200
- Date: 2026-10-18
- Status: superseded
- Implementation: partial
- Components: Marshall Editor, Audi, Lilly, shared protocol, Windows image, Code OSS package, Windows editor broker, Lyra account reconciler
- Supersedes: none
- Superseded by: ADR-0208

## Context

[ADR-0171](0171-windows-guest-agents.md) explicitly excludes the browser editor
from the `windows-v1` capability row. The version-5 Windows image contract has
no editor descriptor. The personal editor's existing browser, current-login,
write-grant, execution and package fences therefore cannot be enabled by merely
installing Windows runtime bytes or porting the Linux executable.

The user authorized continuing the guest OS matrix plan in this repository and
implementing the Windows editor candidate. A Windows implementation needs native
account and kernel-object custody rather than Linux UID/systemd assumptions.
Source staging, portable tests, bounded native pipe/ACL library tests and a
completed reviewed native Windows bundle import exist. Candidate image and
authenticated browser acceptance remain unrecorded.
This decision records the candidate boundary without changing ADR-0171's
accepted capability exclusion.

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
2. **Keep one LocalSystem broker and personal account workers.** The broker
   binds the MMDS guest address on dedicated TCP port 4444 and accepts only the
   current MMDS gateway. It validates the existing closed preface and immutable
   package descriptor against the placement/execution boot identity before
   account reconciliation or forwarding. Public guest web publication cannot
   authorize this port. Marshall, Audi and Lilly retain their current-login,
   current-write, personal-origin, transport and execution checks.
3. **Use current local SAM accounts and verified S4U identity.** Resolve the
   canonical `u<uid>` account through Lyra's locked roster authorizer before
   every worker admission. Require an enabled ordinary local account, an exact
   local SAM SID and a matching primary S4U token SID. Use its native profile
   and bounded explicit environment. Validate executable and PATH custody,
   ancestors, ACLs and reparse-point refusal before launch. A username, supplied
   UID, arbitrary SID, cached successful login or environment search cannot
   substitute for these checks.
4. **Bind every worker and recovery receipt to exact custody.** Launch direct
   Node under the personal token, suspended until assigned to the named
   SYSTEM-owned Job Object. Bind the pipe/job identity and private receipt to
   placement, execution epoch, GuestAccount UUID, UID, account name, SID,
   personal origin and release descriptor. Reuse requires the retained PID,
   creation time, token SID, executable, job membership and pipe-server PID.
   A foreign, ambiguous, replaced or incompletely observed process is refused
   without terminating it. Broker restart may adopt the exact retained worker;
   repair or termination requires established ownership.
5. **Bound pending native I/O and startup work.** Overlapped pipe operations
   own their buffers and completion state. Timeout cancels and retires the
   operation without allowing the kernel to reference caller storage. Live
   pipes and undrained cancellations share a finite global reservation budget;
   exhaustion refuses new work. Account startup, readiness and connection
   admission also remain bounded. Portable models establish finite state rules,
   while native tests must establish actual Win32 cancellation and custody.
6. **Install the candidate through a supervised fixed SYSTEM task.** The image
   installer validates the broker manifest and release tuple, restricts package
   and configuration writes to SYSTEM/Administrators, keeps receipts private
   to SYSTEM, and registers the fixed startup action with unlimited execution,
   single-instance policy, restart-on-failure settings and a private task DACL.
   The wrapper obtains the reviewed trust bundle before running the broker.
   Task registration is source evidence; native crash/reboot execution must
   prove that supervision works. This console process does not claim an SCM
   service entry point.
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

## Alternatives

Running the workbench as SYSTEM was rejected because browser admission must
select the current personal guest account. A shared VM origin or path-only
account separation was rejected because browser storage and extension state
are origin-wide. A loopback server plus a connection token cannot establish
current SAM SID, execution or process custody. Reusing Linux process groups,
Unix sockets or systemd units would invent native guarantees they do not provide
on Windows. Downloading a prebuilt server or building with first-boot network
access would weaken the official-source and immutable offline image boundary.
Declaring capability after cross-compilation was rejected because linking does
not exercise Windows account, pipe, scheduler or browser behavior.

## Consequences

The candidate preserves the personal editor's authority model while adding
native Windows source, image and process boundaries that need their own
execution evidence. Native bundle imports require an explicit reviewed hash;
updates change the release/image identity and require coordinated rollout.
Account or package ambiguity refuses access rather than cleaning up a process
without custody. Retained worker state and bounded cancellation add operational
complexity. Guest Administrators retain their existing native authority; these
checks do not establish confidentiality from an administrator, physical VM
isolation or independent-host recovery.

## Invariants and verification

- Portable property/unit checks reject malformed prefacing, stale execution,
  mismatched descriptor/account/SID/origin, ambiguous paths, foreign process or
  pipe identity, and capacity exhaustion. They do not prove Windows APIs.
- Cross-target compilation and linking cover the maintained Windows code and
  locked inputs; native tests separately exercise SAM/S4U, profile custody,
  Job Objects, exact pipe-peer identity and overlapped timeout completion.
- Image checks require matching broker bytes/digest and release descriptor,
  SYSTEM custody, no reparse-point escape, fixed task action/DACL and dedicated
  gateway-only firewall admission. Native reboot/crash tests must establish
  actual task restart and refusal when trust or custody is missing.
- The real Windows browser journey must pass authenticated personal opening,
  edit/readback, language/terminal functionality, two-account separation,
  foreign gateway/release/epoch/account refusal, broker restart/adoption,
  worker-loss recovery and current-login/write-grant revocation for the exact
  image and package. A local bridge or terminal-only test cannot satisfy it.
- Versioned image/protocol and consumer tests must keep old Windows images
  editor-ineligible and reject missing, stale or mismatched descriptors. No
  source/build success may promote the accepted capability table by inference.

## Implementation evidence

The [manifest codec](../../../protocol/lib/overalls_protocol/image_manifest.ex),
[bundle codec](../../../protocol/lib/overalls_protocol/workload_bundle.ex),
[capability table](../../../protocol/lib/overalls_protocol/guest_agents.ex),
[Lilly bundle writer](../../../lilly/lib/lilly/vm/workload_bundle.ex) and
[Marshall image facts](../../../marshall/lib/marshall/compute/image.ex)
implement the separate v7/v4 candidate contract. The
[protocol properties](../../../protocol/test/windows_editor_image_test.exs),
[retained-bundle test](../../../lilly/test/vm/windows_editor_bundle_test.exs) and
[consumer properties](../../../marshall/test/marshall/compute/image_editor_capability_test.exs)
cover declared identity and release behavior; their execution and native limits
are recorded separately in the cross-platform review.

The [target registry](../../../marshall/lib/marshall/editor/releases.ex),
[per-release receipt](../../../marshall/lib/marshall/ingress/editor_assets_receipt.ex),
[publication query](../../../marshall/lib/marshall/ingress/publications.ex) and
[receipt-index migration](../../../marshall/priv/repo/migrations/20261018192955_editor_asset_releases.exs)
implement concurrent target admission and complete asset-set discovery. The
[registry properties](../../../marshall/test/marshall/editor/releases_test.exs)
and [publication tests](../../../marshall/test/marshall/editor_publication_test.exs)
inspect finite targets, exact tuple selection, independent receipts and expiry;
they do not establish native multi-gateway DNS or TLS behavior.

The [runtime recipe](../../../nix/domains/artifacts/vscode-web/windows-runtime.nix)
and [source kit](../../../nix/domains/artifacts/vscode-web/windows-source.nix)
stage pinned native inputs with false capability metadata. The
[bundle importer](../../../nix/domains/artifacts/vscode-web/windows-bundle.nix)
enforces the hash, descriptor, product-policy and native provenance checks.
The cross-platform review records the completed native build and exact imported
bundle identity. These are package/source boundaries, not browser execution.

The [portable worker model](../../../nix/domains/artifacts/vscode-web-broker/src/windows_model.rs),
[Win32 launcher](../../../nix/domains/artifacts/vscode-web-broker/src/windows/mod.rs),
[listener](../../../nix/domains/artifacts/vscode-web-broker/src/windows_main.rs)
and [pipe implementation](../../../nix/domains/artifacts/vscode-web-broker/src/windows_pipe.rs)
implement the candidate custody path. The
[Windows broker build](../../../nix/domains/artifacts/vscode-web-broker/windows.nix)
preserves the locked-source build boundary and false capability marker.
Portable and cross-target results retain the exact scope recorded in the
[cross-platform review](../reviews/2026-10-18-cross-platform-editor-status.md).

The [installer](../../../nix/domains/artifacts/guest/windows/install-editor.ps1),
[custody checks](../../../nix/domains/artifacts/guest/windows/editor-custody.ps1)
and [startup wrapper](../../../nix/domains/artifacts/guest/windows/start-editor.ps1)
describe candidate task, trust, package and firewall installation. The linked
review records 30 actual native Windows library tests, including pipe timeout,
idle cancellation and ACL refusals; this is narrower than account or worker
lifecycle acceptance. The native bundle is completed and imported. The later candidate installer
completed, and a separate 2-vCPU/4096-MiB Firecracker boot reached Windows Server
build 26100 SAC; exact evidence is recorded in the cross-platform review. No
production image admission, listener/worker journey, scheduler crash/reboot run
or authenticated Windows browser acceptance is recorded here.
The [native acceptance harness](../../../nix/verification/tests/machines/windows-editor/README.md)
defines actual gateway-relay, personal account, browser edit/trust/PTY and
broker/worker recovery assertions. Static harness compilation or boundary tests
do not execute those native assertions. Implementation remains partial.

## Open questions

Run native account/pipe/task acceptance for the reviewed imported bundle and
the complete image-bound browser journey.
Then review the exact candidate image and bundle needed for production
selection, including retained-image refusal and rollout ordering. Task Scheduler
restart semantics and interrupted native cancellation require executed evidence.
None of these gaps authorizes changing the current false capability row.

## Related decisions

[ADR-0208](0208-windows-editor-job-custodian.md) supersedes this decision in full,
carrying forward the candidate identity and promotion requirements while
replacing broker-owned job lifetime with an independent SYSTEM custodian.

[ADR-0153](0153-official-source-browser-editor.md),
[ADR-0158](0158-durable-guest-identities.md),
[ADR-0161](0161-monospace-web-presentation.md),
[ADR-0169](0169-firmware-booted-windows-guests.md),
[ADR-0171](0171-windows-guest-agents.md),
[ADR-0173](0173-windows-images-winget-desktop-experience.md),
[ADR-0190](0190-native-kernel-provenance-and-admission.md).

The new agent namespace is additive. ADR-0171's existing `windows-v1` exclusion
remains valid and this decision does not supersede it.
