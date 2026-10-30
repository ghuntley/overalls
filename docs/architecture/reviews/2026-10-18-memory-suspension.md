# Memory-preserving suspension and demand wake

## Scope and architecture assessment

The approved task changes execution, persistence, capacity, recovery and ingress
contracts. [ADR-0199](../decisions/0199-memory-suspension-and-demand-wake.md)
partially supersedes the inherited memory-migration, stopped-only relocation and
cross-host relay prohibitions and extends owner pins. Historical rationale and
unrelated boundaries remain in force. The final diff and execution evidence must
be reviewed before this milestone is described as complete.

This review covers feature checkpoint `c3f3b821`, its uncommitted integration
with canonical trunk `ae783fdbe`, and the subsequent sealing and capture-journal
repairs described below. Execution records retain their captured source scope;
an earlier full application run does not verify later changed sources.

## Reviewed findings

- A Firecracker Paused API call retains RAM. Full snapshot plus proven process
  absence is required before compute credit can be released.
- The pinned upstream block snapshot preparation logs and suppresses drain/flush
  errors. A reviewed VMM patch now aborts before snapshot publication on that
  failure; no successful API reply can authorize incomplete I/O continuation.
  The final fleet must qualify this changed executable. Native block-error fault
  injection remains distinct from ordinary successful continuation evidence.
- Snapshot restoration requires an unconfigured fresh VMM. Native hostd now
  carries a typed restore launch bit and omits both cold configuration and MMDS
  metadata arguments while preserving firmware PCI and launch custody.
- A restored RAM file remains immutable while mapped. Two prebound checkpoint
  leaf datasets permit the next full capture without modifying that backing.
- Same-boot continuation cannot rewrite cached guest identity into current
  placement authority. Those identities require a validated continuation binding.
- Paused route/key discovery cannot authorize a guest stream. A waiting connection
  needs fresh authority after restore, including when accepted by the old gateway.
- Native vsock permanent-reset contracts need a recoverable valid-reset branch;
  malformed/configuration changes must retain their fail-closed behavior.
- A successful resume observation must include the exact commanded checkpoint;
  an ordinary running observation without continuation evidence cannot complete
  that operation or restore private-service authority.
- Lock-free Lilly execution reads verify both publisher processes directly.
  Queued monitor cleanup cannot extend the authority of a dead actor or runtime.
  Observer port closure tolerates only the already-closed-port race.
- Interrupted capture/restore terminal cleanup rereads the exact durable intent,
  validates the local checkpoint binding and revision, requires the host lease
  and a confined paused process, and then independently proves unit/cgroup
  absence. It never promotes an unfinished capture to a ready checkpoint or
  retries a consumed restore. Native systemctl mutation admits one owned VM unit;
  slices and wildcard selectors cannot acquire that authority.
- Resume commands encode nested checkpoints through their closed wire schema.
  Sending atom-keyed application data to the strict peer decoder was a concrete
  merged-source defect, not a reason to widen the decoder.
- Built and supplied command snapshots pin resume authority to the VM's current
  validated checkpoint. A caller cannot replace its checkpoint ID or hashes;
  the same authoritative reconstruction already used for Git/workspace metadata
  now also preserves memory continuation.
- Actual fleet capture exposed a sealing call that supplied two paths to
  hostd's single-path ownership grammar. The caller now issues two existing
  native requests. Interrupted sealing also verifies both output files before
  skipping repair, and repairs incomplete files only in an independently
  confirmed writable dataset. The native grammar remains closed; local
  parser/metadata tests and the resumed fleet run retain separate evidence.
- A later fleet capture exposed a second crash window: successful native
  snapshot creation was followed by a competing pool-lock acquisition solely
  to record `copied`. Pool contention could lose the caller's acknowledged-copy
  proof while leaving a deliberately nonrecoverable `capturing` journal. The
  repair records this private journal transition under exact placement/capture
  authority without reacquiring the pool. It changes neither physical ownership
  nor allocation credit; sealing and publication remain pool-serialized. Its
  selected live lease must name the configured placement directory passed by
  the driver. Source review and the real-contention/reopen property, including
  an unrelated selected live-lease refusal, passed within that bounded scope.
  Retrying the snapshot or inferring success from files remains forbidden.

## Merged documentation and contract reconciliation

Canonical assignments retain pins as ADR-0193, localization as ADR-0201,
Git attribution as ADR-0198 and suspension as ADR-0199. Reciprocal supersession
links, indexes and source references use those distinct IDs. Accepted rationale
and historical evidence remain intact. Suspension is accepted with partial
implementation status. ADR-0200 remains a separate Windows editor candidate;
its additive manifest and bundle contracts do not promote the selected Windows
image's false editor capability or establish native browser acceptance.

The restored lifecycle, storage, workflows, guest, interactive, networking,
agent, operations, security, domain and topology chapters preserve the incoming
account/localization/guest documentation. The source-derived option, Ash and
topology inventories were regenerated from the actual declarations. Scenario
evidence distinguishes test presence from recorded execution, retains historical
retry results under their former scope and records narrow wake/relay/capture
refusals without claiming native continuation.

The account route had also selected the Git-only SettingsLive while ADR-0196's
combined AccountLive and tests remained present. The repaired route serves the
combined page, with ADR-0198's Git preferences appended as a fourth section.
Profile, passkey, SSH, strict fresh-login and removed-URL boundaries are preserved.
This is reconciliation of existing accepted decisions, not a new authority model.
The separate Reference navigation tree and its Control-room hiding guard were
also restored to the existing handbook, source contracts and LiveView assertions.

The shared HLDD evidence classifier now recognizes the actual parenthesized
property macros and exact Hegel check/run callbacks. Qualified and similarly
named calls remain refused. Its regression suite preserves the separate
assertion, execution-record and native-evidence requirements; lexical recognition
alone grants none of them.

## Recorded reconciliation evidence

- Native `lilly-hostd`: `cargo test --locked` passed **59 tests**, with
  `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings`
  passing against the repaired native sources. A later rerun after the
  single-path ownership repair passed **60 tests**, formatting and the same
  warning-denying Clippy command. These establish local lease,
  selector, process and stream contracts; they do not establish KVM continuity,
  physical cleanup or multi-host recovery.
- The reconciled handbook review, generated coverage/options/views checks,
  ADR structure/link check (**197 decisions**), contract structure check
  (**142 CONTRACTS files, 3,424 notes**) and conflict-marker check passed at
  their earlier reconciliation snapshot.
  `nix build .#checks.x86_64-linux.hldd` passed in **9 seconds**, including
  evaluated placement. These are source, documentation and contract-structure
  checks, not browser rendering or runtime fleet acceptance.
- The pre-Windows-merge Nix HLDD gate passed again in **42 seconds**. The
  merged ADR structure/local-link check passed **198 decisions** after canonical
  ADR assignment and reciprocal-supersession reconciliation. The final merged
  source/receipt/reference check, generated coverage/options/Ash/topology views
  and conflict-marker check (**8,580 files**) passed. Code-contract checks
  passed **144 CONTRACTS files, 3,450 notes, 472 parsed source files and 3,419
  maintained source files**, plus **19 validator regressions**. The merged
  Nix HLDD gate passed in **13 seconds**, including evaluated placement.
  These remain structural documentation/contract evidence.
- The exact sealing property passed **100 default Hegel cases**, seed
  **527600**, in **0.2 seconds**, with no warnings. It uses current-source
  compiled BEAM modules and actual local files to check interrupted metadata
  repair and malformed output refusals. It does not execute privileged ownership
  changes, ZFS readonly transitions, KVM or a full Lilly Mix gate.
- The current exact-placement focused Lilly run passed **28 tests** across
  **six files** in **8.4 seconds**. This includes **100 default Hegel cases**
  for held-pool contention, durable reopened `copied` phase and wrong-selected-
  native-lease refusal, plus the sealing property's **100 cases**. Native
  hostd leases are real; Firecracker capture, ZFS effects and full consumer/fleet
  continuation remain outside this focused BEAM execution.
- The packaged NixOS `hldd-browser` check passed in **640 seconds**; the
  VM driver took **90.79 seconds**. Its captured source from **19:19:48**
  included the Reference navigation repair last modified at **19:10:57**.
  Real Marshall, PostgreSQL and Chromium checked unauthenticated redirect,
  aborted token-login redaction, ordinary reader authority, the exact Reference
  and Source navigation, at least 22 sections and 14 diagrams, desktop/dark/
  mobile/print presentation, removed-route refusal and mounted/stale-cookie
  revocation. Result:
  `/nix/store/80z6kqz96i6h8as4bvs4b0jsy664xcb4-vm-test-run-overalls-hldd-browser`.
  This precedes later sealing/evidence prose and the Windows merge; it does not
  exercise Account forms, suspended ingress or native VM continuation.
- Pinned all-files Python `prek` checks passed Ruff format, Ruff lint and ty
  on the merged tree. These are Python static checks, not machine execution.
- Merged Diagnostics full `mix precommit` passed **32 tests** in **7.0 seconds**,
  seed **677271**, Covenant **8/8**, and forced Dialyzer with **zero errors and
  zero skipped**. Its generated schema adds only the fixed `windows_editor_v1`
  atom; no arbitrary editor payload or identity values enter diagnostics.
- Before the Windows merge and latest Lilly journal repairs, full precommit
  runs passed Protocol **353**, Lilly **646** and Porsche **105** tests, with
  Covenant respectively **14/14**, **15/15**, **4/4**, and forced Dialyzer with
  **zero errors and zero skipped**. Diagnostics passed **32** tests, Covenant
  **8/8**, and zero-error/zero-skip forced Dialyzer before its additive merged
  Windows atom schema update. Audi passed **225/226** tests, Covenant **10/10**,
  and zero-error/zero-skip forced Dialyzer; the sole failure is the known
  excluded Inception suspended-renewer test. These counts retain premerge
  source scope and are not final changed-source gate results.

## Post-pull local hostd verification

At integrated `3e25e8218`, the local hostd cargo suite passed **61 tests**,
with **0 failed** and **0 ignored**, in **1.51 seconds**. The captured command
was `cargo test --manifest-path lilly/native/hostd/Cargo.toml`; log:
`/tmp/osmatrix-hostd-integrated-tests.log`. It includes checkpoint stream
custody, API-only restore launch and closed systemctl query/lifecycle policy.
These are local native-process and argv/lease results. They do not execute
ZFS checkpoint transitions, KVM continuation, suspended ingress or multi-host
recovery, and do not replace the current Lilly consumer gate.
The same integrated local source passed `cargo clippy --all-targets -- -D warnings`;
log: `/tmp/osmatrix-hostd-integrated-clippy.log`. This is native static evidence.

## Post-pull Lilly BEAM and type checks

The post-pull Lilly full gate later exited **0**: **649 tests passed** in
**883.0 seconds**, seed **749313**, Covenant covered **15 of 15 obligations**,
and forced Dialyzer passed with **0 errors and 0 skips**. Log:
`/tmp/osmatrix-lilly-postpull-precommit.log`. After the shared optional-prefix
typespec correction, Lilly's forced Dialyzer passed again with **0 errors and
0 skips**, in **12.88 seconds**; log:
`/tmp/osmatrix-lilly-null-prefix-dialyzer.log`. These are local BEAM/type results,
not execution of the memory-suspension-fleet NixOS test or native continuation.

## Historical recorded validation

These runs preceded the merged-tree repairs described below. Their exact scope
and revision remain historical evidence; their application counts do not establish
that the current merged sources pass.

- Native `lilly-hostd`: `cargo test --manifest-path
  lilly/native/hostd/Cargo.toml` inside `devenv shell`: **57 passed**. Includes
  Hegel restore launch/round-trip, fixed checkpoint stream custody and unknown-flag refusal. This proves argv and
  native custody behavior in the local test process, not KVM memory continuity.

- Exact-source `native-freebsd-reset` NixOS/KVM machine check passed together
  with `illumos-kernel-candidate-objects` in the recorded 432-second build.
  The actual FreeBSD machine script took 208 seconds. Its receipt is
  `/nix/store/2dmnb2gz3vp32adcflczpk459ww2kbcw-vm-test-run-overalls-freebsd-native-reset/reset-receipt.json`
  (SHA-256 `a63ac733b64157d3644fc2c508411f5ffd81c974861bd4174276d1d21115a2fa`).
  Full fresh-VMM memory restore retained the RAM-only nonce and PID; the original
  listener accepted another connection while connected/unbound sockets fenced.
  This test-only candidate explicitly records `native_admission=false`; it does
  not qualify the immutable production FreeBSD image. The illumos result proves
  candidate cross-object compilation only.
- The final patched-VMM `native-freebsd-reset` machine script passed in
  **417.48 seconds**. Receipt:
  `/nix/store/clz8vdcxd8h1falfzn3pj2r0m9svla5d-vm-test-run-overalls-freebsd-native-reset/reset-receipt.json`,
  SHA-256 `9f82f3fe828fab8261d488827367e53fb16b9c9ef985b9521a8e2c574ee75326`.
  VMM SHA-256 `9815649a9bed84194ca45c5aef4c9307a596c7ffbe1f9f0e881c1ae536226d02`.
  RAM-only nonce/PID and the original listener survived a fresh-VMM restore.
  This supersedes the prior executable's continuation evidence above, while
  retaining `native_admission=false`: it qualifies only the test candidate.
- Focused Lilly terminal tests: **4 passed**, including Hegel original guest
  hello continuity across generated destination epochs. This is HMAC/BEAM
  evidence, not guest or network continuity.
- Shared SSH command tests: **14 passed**, including generated pause/resume/
  unpause codec validation.

- Shared protocol full `mix precommit`: **314 tests passed**, Covenant **14/14**,
  forced Dialyzer **0 errors**. These are local codec/BEAM contracts, not KVM
  continuation evidence.
- Audi full precommit test phase: **221/222 passed**. The sole failure is the
  unchanged Inception suspended-renewer timeout, explicitly out of scope.
  The new wake, configuration, SSH and editor tests passed; forced Dialyzer completed with **0 errors and 0 skipped**; Covenant **10/10**.
- Porsche full `mix precommit`: **100 tests passed**, Covenant **4/4**, forced
  Dialyzer **0 errors and 0 skipped**. The fresh-OTP invalid-configuration
  property runs three complete shuffled refusal menus, with its external-process
  budget declared on the property rather than an ignored generator option.
- Lilly final full `mix precommit`: **627 tests passed**, Covenant **15/15**,
  forced Dialyzer **0 errors**. The watcher race regression additionally passed
  **21 consecutive executions**. This includes checkpoint shape binding,
  paused-live restore recovery and refusal while publisher-monitor cleanup is
  delayed; these BEAM checks do not establish multi-host RAM continuity.
- Covenant static checks passed for protocol **14/14**, Audi **10/10** and
  Porsche **4/4**, independently of the executable contract results above.
- Isolated Marshall ingress history: **2 tests passed**, including **10 generated
  histories**. The model now independently accounts for route replacement after
  VM-generation changes. Live PostgreSQL inspection during replay found no
  retained competing transaction or advisory-lock blocker.
- Isolated publication capacity: **100 gateways, 10,000 routes, 10 samples**;
  each refresh completed in **187–280 ms** under the unchanged production
  deadlines. This is local PostgreSQL throughput evidence, not a fleet SLA.

## Cutover and recovery review

The schema migration refuses every unfinished relocation. Operators must finish
or cancel those moves and confirm cleanup before migration; a mixed stopped-copy
and paused-copy coordinator is not retained. Existing completed relocation
history remains disk-only. Pause admission requires a fresh checkpoint capability
from Lilly, so an old host report cannot receive an unsupported memory command.
Consumer deployment and private relay enrollment must precede producer enablement;
see the operations handbook. Git integration does not perform live deployment.
The converged host inventory additionally requires `checkpoint_image_ids`;
old producers lacking it are refused rather than assigned default qualification.
Coordinate reporter and consumer rollout before enabling memory operations.
The qualification set is independent of physical checkpoint compatibility, so
hosts with different qualified-image supersets can still exchange compatible RAM.

## Remaining verification

The 2026-10-19 admission review found that the Linux/kernel predicate admitted
unqualified images without requiring an immutable identity. The corrected
predicate requires an exact content-addressed image ID from trusted Lilly
configuration on both pause and resume. `services.lilly.checkpointImageIds`
defaults empty; ordinary starts remain available. The disposable suspension
fixture supplies only its own derived candidate image ID. No production image
is promoted by that configuration. This repairs an ADR-0199 implementation
violation without changing the accepted decision or guest wire format.

Qualification is also required in authenticated host inventory. Marshall checks
the exact VM image before pause, restored capacity and memory relocation
selection, revalidates both endpoints before source pause, and revalidates the
destination before handoff. This closes the late-driver-refusal gap: a destination
with matching physical compatibility but no image qualification must not acquire
authoritative memory custody. Source review separately confirmed that cold-start
and stopped disk-only relocation remain independent of checkpoint qualification.
New tests cover qualification withdrawal before pause/handoff, durable wake waiting
and qualified supersets; application execution remains separately required.

Focused verification: Marshall lifecycle/wake suites **18 passed** (ExUnit seed
344801), including generated actual Ash WakeRequest transition histories.
Protocol admission **12 passed**, including the default 100-case Hegel property
checking validated image/bundle identity and changed artifact refusal. Lilly
configuration/checkpoint/sealing **16 passed**. These are BEAM-level admission
and state-machine checks; they do not qualify any native artifact. Current full
consumer gates and the changed-fixture native run remain required.

Before the additional inventory propagation change, the full protocol gate
passed **419 tests** in 916.5 seconds and Dialyzer reported **0 errors**.
The final strict-inventory focused protocol run passed **29 tests**. Its final
full `mix precommit` passed **420 tests** in 903.6 seconds, with **0 Dialyzer
errors**, no skips and passing runtime/ADR/contracts gates. High-concurrency Marshall and Lilly runs were stopped
after recorded database/timing/property-health failures; isolated lower-scheduler
runs preserve the full generated case counts. None of those interrupted runs is
recorded as a passing full gate. The known Inception failure remains out of scope.

The 2026-10-19 native rerun exposed missing suspension-fixture prerequisites:
the fixture excluded the Galileo/Audi private issuer and skipped its runtime
credential/trust enrollment even though guest SSH host-certificate bootstrap
requires that edge. The fixture now includes the same private-service module
and enrollment as ordinary fleet guests, without bypassing guest readiness.
The composed NixOS driver passed its type and lint checks. The subsequent run
completed private-service enrollment but exited with status 137 while waiting
for the fleet wildcard certificate, before guest launch. This is not passing
pause/resume or relocation evidence. Concurrent native builds were present;
the exit status alone does not establish why the process was killed.
These driver and native results precede the dependency refresh in `1da714ef2`;
they do not validate its refreshed locked closure.

A subsequent execution of
`0jx1wjrk12g9j78bjgh0kk729hzbv27f-vm-test-run-overalls-memory-suspension-fleet.drv`
activated the wildcard certificate and reached native guest provisioning readiness.
It failed before suspension in the SSH journey because the client CA file was
installed only by an excluded browser subtest. The SSH journey now installs its
own pinned fixture CA independently, preserving HTTPS certificate verification.
That failed execution establishes neither RAM continuation nor relocation.

The accepted decision is unchanged by the merge reconciliation and bounded
repairs. Source review and focused contention/reopen execution resolve the
specific capture-journal lock defect within their stated scope. Source and
code-contract review cannot substitute for changed-source native continuation
evidence; current full consumer and fleet runs remain separately required.

Control-plane integration, admitted exact guest images, gateway wait/relay
authorization, actual capacity-driven relocation, current full application gates,
and full NixOS fleet execution remain in progress. Fault-injected block-barrier
failure and complete retained-image qualification remain distinct gaps.
No production rollout or physical-host acceptance is
claimed. Known Inception failures remain out of scope.

The final strict-inventory Marshall focused run passed **98 tests** in 72.3
seconds (seed 794721), including actual Ash wake histories, suspension admission,
restored-capacity waiting, stopped relocation independence and qualification
withdrawal before handoff. The final Nix HLDD gate also passed. These checks do
not establish native memory continuation.

The diagnostic native run `frx45xy50jay1a400nz4jzpx4g26gr69-vm-test-run-overalls-memory-suspension-fleet.drv`
captured a checkpoint and reached restoring without the earlier intent conflict,
but reported `vmm_process_ambiguous` before snapshot load. Source inspection of
the pinned Firecracker builder confirmed its main-thread seccomp filter is
installed at the end of snapshot restoration. Lilly had required that filter
before submitting the snapshot-load request. A dedicated preboot observation
now requires exact unconfigured API state and the expected unfiltered main
thread, retaining jail, namespace, UID/GID, empty capabilities, no-new-privileges,
resource limits and stable unit checks. Post-load paused and running observations
still require the configured seccomp filter before execution can resume. The
new generated process-evidence property checks phase separation and malformed
confinement refusal. The final-source focused Lilly observer/configuration run
passed **6 tests** (seed 200378), including that 100-case property; changed-source
native verification remains pending. This is a bounded restore-order correction, not native qualification.

The preceding Lilly full gate completed naturally: **652 tests passed** in
1400.0 seconds, Covenant **15/15** and Dialyzer **0 errors/skips**. That launch
snapshot preceded strict-inventory propagation and the preboot correction; a
fresh final-source gate is running. Quiet fresh-boot properties were preserved
at their complete generated counts.

Read-only triage of the interrupted broad Marshall run identified five
independent initial failures: retention coverage omits
`notification_devices_versions`; reviewed FreeBSD cold admission conflicts
with the inherited `GitIdentity.require_image!` capability requirement; the
bootstrap duplicate-claim model expects a stable attempt while implementation
rotates it; and two remote TLS properties failed health/restart timing. The
admission and bootstrap mismatches are inherited from trunk commits 0230a8131
and 8d1fcf41e respectively, outside checkpoint admission; they are not labelled
environmental failures. Subsequent application shutdown caused 623 missing-Repo
and one missing-endpoint-ETS failures. All recorded suspension and relocation
capacity failures in that run were missing-Repo cascades; final focused checks
passed, but this does not turn the interrupted broad gate into passing evidence.

## Relocated guest networking correction (2026-10-30)

The `galileo-fleet` subtest "source relocation resolves new private routing and
retires the stale source" failed intermittently (two of four captured runs) on
its first guest request after a memory-preserving relocation. Closed-value
diagnostics showed the restored guest's first private-service exchange stalled
for 3–15 seconds (a DNS lookup or a TCP connect that bypassed DNS), then
recovered; the guest never reached Audi or Galileo during the stall. Two host
networking defects violated ADR-0199's "validates destination networking"
before resume:

- The destination TAP had a kernel-random MAC, so the restored guest's cached
  gateway neighbour named the source host's TAP and its frames were dropped
  until that entry expired.
- The namespace used the default `arp_announce=0`, so the destination
  solicited the guest's MAC from 169.254.254.1 (the source of the reply it was
  sending). The TAP guard correctly drops guest ARP addressed anywhere but the
  gateway, and the restored guest had no reason to ARP itself, so the host
  neighbour stayed incomplete (nft guard counters recorded the dropped replies).

[Guest.new/3](../../../lilly/lib/lilly/network/guest.ex) now derives a
host- and slot-independent, locally administered gateway MAC per profile, which
[Lilly.Network](../../../lilly/lib/lilly/network.ex) sets on every created or
adopted TAP before link-up. The router namespace pins `arp_announce=2`.
[hostd's grammar](../../../lilly/native/hostd/src/policy.rs) admits only a
namespaced guest-TAP address change to a locally administered unicast MAC and
the per-namespace `arp_announce` key. The fleet scenario now asserts that the
restored guest's gateway neighbour already holds that MAC before its first request.

Evidence: hostd policy tests passed (12 matching tests), the full Lilly gate
passed (670 tests, contracts, Dialyzer with 0 errors) including the new
gateway-MAC property,
and `galileo-fleet` passed in two of three runs with both corrections; in both
passes the relocated guest's first direct request took about 1.5 seconds. The third run
failed earlier, in the attachment subtest, on a PostgreSQL deadlock between
integration creation and a concurrent Marshall read. That failure predates
this change and also appears in other fleet checks; it is left open here. The run with
only the MAC correction still failed, and the guard counters showed why. Native
ARP behaviour is machine-test evidence, not BEAM evidence.
