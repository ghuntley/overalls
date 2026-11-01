# ADR-0130: Verified provisioning templates and boot readiness

- ID: ADR-0130
- Date: 2026-09-26
- Status: accepted
- Implementation: partial
- Components: Lilly, Marshall, protocol, Porsche, NixOS, Ubuntu
- Supersedes: none
- Superseded by: none

## Context

The Porsche investigation measured 17.40 seconds to receipt completion, including
4.4 seconds hashing 3.64 GB of immutable artifacts and 3.2 seconds copying the
root disk. The 371 MB kernel contains approximately 228 MB of debug information.
The user approved immutable templates, independent copy-on-write VM disks,
stripped kernels, SSH readiness, Ash state machines, structured lifecycle audit,
property tests and NixOS integration tests in a separate implementation worktree.

## Decision

Lilly owns one immutable template incarnation per pool and image identity.
`staging → verifying → sealing → ready → retiring → deleted` separates physical
effects from confirmed state; corruption quarantines an incarnation. A deleted
incarnation cannot resurrect. Staging hashes the staged bytes, flushes them,
records native dataset GUID and file identities, and seals the dataset read-only
before publication. Warm use verifies that exact ownership, GUID, sealing and
artifact identity still hold. This adds an alternative to per-launch full hashing
under ADR-0098; its artifact bounds and immutable image identity remain intact.

VM disks remain independent placement datasets. A Rust helper using safe rustix APIs attempts
file reflinks, falls back to sparse copying only for recognized unsupported
cloning errors, and reports the actual method. Permission, space and I/O failures
do not trigger fallback. Boot bundles remain portable; deletion of a template
must not prevent VM restart, clone or relocation. Disk extension and publication
retain their existing flush and ownership boundaries.
The helper forbids unsafe Rust, uses a locked Hegel dependency for generated
properties, and emits only a bounded private result protocol. Lilly's reviewed
Events catalog owns operational logs; native paths and errors are not log fields.

One builder per pool/image works outside the pool-wide mutation lock. Reader
leases exclude retirement. Standard NixOS and Ubuntu templates prewarm with
bounded asynchronous concurrency. A configurable 32 GiB per-pool budget charges
artifact sizes conservatively, retires unused LRU entries, and sends oversized
or over-budget images through the existing verified path. Native capacity
observations include template allocation; logical VM reservations are unchanged.
Budget reduction prevents oversized warm use and new over-budget allocation;
active readers and unconfirmed ownership can defer reclamation. The bounded
catalog retains up to 4,096 record directories, including tombstones and
interrupted empty publications. At that limit new images use the verified
uncached path. Catalog history is not deleted to make room. Quarantined templates
can only be replaced after fenced retirement and full verification of a new
incarnation; an old incarnation never regains readiness.

A separate Ash provisioning machine records `pending → materializing → launching
→ awaiting_trust → awaiting_ssh → ready`, with terminal failure and supersession.
Execution, dataset and trust machines retain physical authority. Durable intent
precedes effects; confirmations require current placement, epoch, generation and
boot bindings. The readiness budget starts at launch, after materialization.
Recovery preserves that original readiness deadline and cleanup
obligations. Ready receipts are reused only for the same confirmed boot. Inception
retains its forty-minute core budget. Ordinary initial provision success requires
trust, certified SSH/account bootstrap, networking and writable-root readiness.
Porsche syntax, request identity, `--no-wait` and client timeout semantics stay
unchanged. Guest readiness does not prove arbitrary external client access.

Both distributions consume a shared stripped uncompressed ELF kernel derivation.
Its separate debug output preserves debugging; a build-time check compares all
loadable bytes and addresses. Exact manifests and image IDs are regenerated.

Transitions and pending audit publish atomically under native locks. Existing
Events catalogs emit fixed messages with UUIDs, integers and closed atoms only;
no paths, commands, credentials, payloads or raw exceptions enter events. Template
audit uses explicit host/pool authority, never invented placement identities.
Protocol readers, ingestion authorization and outbox discovery deploy before new
producers are enabled. Audit receipt never grants execution or cleanup authority.
Replays retain event identity and late ACKs cannot remove newer transitions.

## Alternatives

Per-launch hashing/copying retains the measured hot-path cost. ZFS dataset clones
introduce origin dependencies that complicate independent placement retirement.
Trusting arbitrary unchanged files lacks a sealed, owned native boundary. A
single-pass copy competes with template materialization and is deferred. Initrd
and polling changes await measurements after these changes.

## Consequences

Template publication, eviction and recovery add persistent state and physical
storage overhead. Failures retain uncertainty and reservation authority. New
image identities require staged rollout. Running guests retain their independent
disks and boot bundles. No production journal reset is permitted; rollback uses
a compatible corrective release or feature disable.

## Invariants and verification

- Model-based generated histories cover stale bindings, crashes, conflicting
  builders/readers/retirement, deadline reuse, invalid transitions and audit ACKs.
- Native disposable machines measure actual ZFS reflink support and sparse fallback,
  independent writes, template deletion, interrupted publication and recovery.
- NixOS and Ubuntu Firecracker guests must prove certified SSH readiness,
  clone/relocation/restart and delayed certificate/roster/SSH behavior.
- Compare ten sequential creations per distribution and four concurrent, recording
  warm/cold/fallback modes, median/range/failures and separate prewarming cost.
  The target is at least 30% lower warm median; under ten seconds is a goal.
- Run all affected precommit, protocol consumer, native, types, logging, contracts
  and handbook gates before rollout. Live canaries use Porsche's advertised
  `ssh_host` and execute `ls`; only run-owned fixtures may be cleaned up.

## Implementation evidence

The shared [kernel derivation](../../../nix/domains/artifacts/guest/kernel.nix) and
[load-image verifier](../../../nix/domains/artifacts/guest/verify-kernel.py) implement debug
separation for both image builders. Remaining template, provisioning, audit,
native verification and deployment work is tracked in the
[implementation ledger](../../history/ledgers/provisioning-fastpath.md).
The [Rust helper](../../../lilly/native/image-copy/src/lib.rs) and
[Hegel properties](../../../lilly/native/image-copy/src/tests.rs) implement bounded
independent copies. The [template adapter](../../../lilly/lib/lilly/host/image_template.ex)
drives the [Ash resource](../../../lilly/lib/lilly/lifecycle/image_template.ex),
and [provisioning adapter](../../../lilly/lib/lilly/vm/provisioning.ex) journals
current-boot readiness. Compatible protocol and authenticated pool-audit readers
were deployed as `153db737`: both enrolled hosts reported that exact healthy
revision with the additive `pool_id` migration installed, while both new
producers remained disabled. One-off NixOS and Ubuntu Porsche-to-authenticated
SSH canaries confirmed run-owned cleanup on that reader path; they do not
establish enabled readiness, warm performance or complete native journeys.
Recorded tests, deployed observations and their revision limits are in the
[review](../reviews/2026-09-26-provisioning-fastpath.md).
The reader-revision NixOS Porsche lifecycle subtest subsequently passed real
guest restart, clone, relocation and cleanup, but its combined fleet test
failed later at a separate terminal/browser stage. A scoped subtest is not a
green native fleet or Ubuntu readiness result.
Separately, the Ubuntu reader-revision native SSH journey passed real client
login, revocation, renewal, relocation, reboot and clone with VM-test cleanup;
its disposable fixture enables both readiness and templates. It does not
assert a native template hit, exact-boot readiness journal, delayed-readiness
refusal or production activation; the complete Ubuntu Porsche variant is
still unverified.
The revised disposable ZFS `image-template` machine check passed on reader
revision `153db737`, including native warm record/incarnation UUID and lease
propagation and a verified uncached callback with none. That result does not
establish production template use, guest SSH or a warm median.
Revised disposable NixOS/Ubuntu user-SSH journey checks now include a
host-local validated journal and current boot/intent binding with stale-boot
and foreign-host refusals. The revisions are present but unexecuted; neither
the earlier Ubuntu pass nor driver construction proves those assertions.
The later [SLO activation review](../reviews/2026-10-02-durable-physical-slos.md)
records native NixOS and scoped Ubuntu readiness plus passive exact-boot proof
for all 25 retained running boots. Both enrolled host configurations now enable
readiness while template producers remain disabled. On 2026-10-07 both hosts
advertised identical guest image IDs after `7106dd24`, and live creates showed
per-create verification dominating materialization; the following release enables
template producers (32 GiB per pool) on both hosts. The matched enabled
campaign (2026-10-09) met the ≥30% target for NixOS (28.5 s → 17.9 s) but
not for Ubuntu (14.8 s → 13.7 s). No warm create reached the under-10-second
target; see the [provisioning ledger](../../history/ledgers/provisioning-fastpath.md). Both hosts activated
`c98a375c` healthy; passive exact-boot verification found 17 Overalls and five
Dungarees current boots with ready journals. Three deletions preceded activation.
Default switches and original deadlines are preserved; future-boot performance
and the complete fastpath matrix remain separate requirements.
**Update (2026-10-11, [ADR-0159](0159-remove-legacy-compatibility.md)):** the
`imageTemplates.enable` and `provisioningReadiness` switches were removed with
their off paths. Sealed templates and durable boot-bound readiness are
unconditional in [Lilly's pool model](../../../lilly/lib/lilly/host/pool.ex),
[template store](../../../lilly/lib/lilly/host/image_template.ex),
[provisioning journal](../../../lilly/lib/lilly/vm/provisioning.ex) and
[executor](../../../lilly/lib/lilly/vm/executor.ex); the per-pool budget
remains a positive capacity size (`imageTemplates.budgetBytes`, default 32 GiB)
and an image larger than it still takes the verified uncached path.
The catalogued [materialization event](../../../lilly/lib/lilly/events.ex)
now includes a closed source kind and optional validated template record and
incarnation UUIDs. This makes the verified uncached path distinguishable from
an actual template use without logging an image ID, path or command. The typed
[benchmark runner](../../../scripts/provisioning_benchmark.py) requires that
native correlation and host/pool-bound construction audit before counting warm
samples; no accepted matched performance result is recorded yet.
The first readers-off campaign obtained ten sequential SSH samples per
distribution but failed two concurrent creations. Their original failed
requests and manifest-planned cleanup IDs were reconciled; all run-owned VMs
were deleted with released reservations and absent datasets. Sequential
medians are exploratory, not an accepted full baseline or speedup result.
An Oct 2 read-only preflight also detected different Ubuntu rootfs digests under
the same derivation path on the two enrolled hosts. The sandboxed guest builder
now normalizes its Nix SQLite registration timestamps and transient WAL/SHM
files; typed unit tests and offline normalization of both observed databases
pass. No rebuilt cross-host image equality, replacement catalog ID, producer
deployment or accepted performance comparison follows from that local fix.
A revised Ubuntu native SSH journey now checks that the pinned development
tools are resolvable through the guest-local Nix registry after boot; that
check is present but unexecuted, so runtime usability is still open.
The benchmark runner subsequently gained a failed-create custody path that
binds cleanup to the original terminally failed request, the current Porsche
owner and the manifest-planned deletion ID. Its local tests pass; native
failure recovery and the complete campaign remain unverified.
The runner also binds terminal-success creates with malformed client identities
back to their original request before using the manifest-planned cleanup ID;
nineteen local custody tests pass. This does not authorize cleanup from audit
alone or establish native failure recovery.
The benchmark runner now refuses before manifest creation when enrolled host
image store paths or NAR identities differ, installed artifact digests/sizes
disagree with the selected catalog ID, offers are stale, or
producer mode/budgets do not match baseline versus enabled measurement.
Enabled mode requires a matching baseline summary, including installed NAR
identities. Twenty-four local
custody/refusal checks pass; complete campaign custody, native image repair and
measured performance remain separate acceptance work.

The [2026-10-13 native guest review](../reviews/2026-10-13-native-guest-coding-clis.md)
records the earlier complete disposable NixOS pass and the corrected complete
Ubuntu pass, preserving two original Ubuntu template-quarantine failures
separately from built production artifacts or activation.
Later retained-state inspection after a new pool import found only `st_dev`
identity changes with matching artifact hashes and native ownership; strict
`Image.sealed/2` refusal was preserved. This does not prove the failure-instant
cause, and two successful diagnostic slices did not reproduce either failure.
The test-only [post-import cache action](../../../nix/verification/tests/machines/zfs-guest/template-post-import.exs)
covers exact reuse or explicit device-only refusal followed by fenced retirement,
deletion and full verification of a distinct new incarnation. It changes no
production identity, authority or recovery policy and cannot restore a quarantined
incarnation. The corrected full Ubuntu suite passed in 2,203.23 seconds of driver
execution and exercised exact reuse; device-only quarantine/replacement remains
unexecuted. Focused current NixOS also passed exact reuse and its original VM 102
cleanup in 1,246.95 seconds of driver execution. It executes only the current
200-line prefix; the later 161 lines retain the earlier complete NixOS pass's
scope. No passing later run establishes the
unknown failure-instant cause of the original failures.

**Correction (2026-11-01).** The strict `st_dev` refusal above no longer
holds. [ADR-0182](0182-unprivileged-lilly-beam.md) (840c79834) found that
Linux ZFS reassigns a dataset's device number on every mount, so any remounted
or imported template was quarantined; `Image.sealed/2` now compares every
identity field except the device number (contract
`sealed-identity-survives-remount`) while the caller still pins dataset GUID
and mountpoint. The rationale above for recording and checking file identities
stands. The post-import cache action was not updated at the time and failed
once it was first reached (2026-11-01, after the zfs-guest pool-observer fixture
fix): device-only drift entered the reader callback. It now expects
device-only drift to reuse the unchanged incarnation (contract
`post-import-template-device-drift-reuse`), and a separate step drives fenced
quarantine, retirement and replacement from an mtime change on one sealed file,
which ADR-0182 still refuses (contract `drifted-template-fenced-replacement`).
Evidence (2026-11-01, dungarees, local builders only, at ee67cc20b plus this
change): both zfs-guest subtests passed, device-only reuse in 179.93 s and
drifted-template quarantine and replacement in 304.35 s, as did every later
subtest through resize. The run was stopped later, in the clone journey; a
control run at 59b2d87e7 with the drift subtest disabled failed that journey
too (`import_disk_adoption_unconfirmed`), so that failure is independent of
this change and is tracked with the clone-cancellation failure.

## Open questions

The disposable ZFS test used sparse copy across independent datasets, despite
the active block-cloning feature. No cross-dataset CoW speedup is established.
Full guest acceptance and a controlled deployed performance matrix remain open.
The initial timing includes wrong-hostname SSH probes, so it is not a clean
end-to-end baseline.

## Related decisions

[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0074](0074-durable-lifecycle-state-machines.md),
[ADR-0092](0092-portable-workload-bundles.md),
[ADR-0098](0098-image-artifact-limits.md),
[ADR-0113](0113-guest-trust-at-boot.md), and
[ADR-0124](0124-unified-ssh-host-ca.md) retain their authority boundaries.
