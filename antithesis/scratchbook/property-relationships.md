---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Property relationships

These are suspected shared mechanisms and proof boundaries for the [104-property catalog](property-catalog.md). They are hypotheses for workload design, not passing results. A property may appear in more than one cluster because its physical witness crosses a service boundary.

## Clusters

### Admission and measured capacity

Marshall commits identities and holds before Lilly performs physical work. Atomic allocation, permanent idempotency identity and fresh-capacity arithmetic are separate oracles: none alone proves the others.

[`marshall-admission-atomic-allocation`](properties/marshall-admission-atomic-allocation.md), [`marshall-admission-key-survives-archive`](properties/marshall-admission-key-survives-archive.md), [`marshall-admission-measured-physical-capacity`](properties/marshall-admission-measured-physical-capacity.md), [`marshall-crash-recovery-budget-and-stale-capacity`](properties/marshall-crash-recovery-budget-and-stale-capacity.md), [`source-stop-after-committed-placement-holds`](properties/source-stop-after-committed-placement-holds.md), [`lilly-pool-sampling-does-not-starve-mutation`](properties/lilly-pool-sampling-does-not-starve-mutation.md).

### Lilly durable intent and physical effect

A delivery receipt, actor outcome, launch marker and current VMM are different proof points. Corrupt or foreign Store state must refuse before any later phase; stale async results cannot acquire newer command authority.

[`lilly-corrupt-intent-never-becomes-receipt`](properties/lilly-corrupt-intent-never-becomes-receipt.md), [`lilly-receipt-survives-control-loss`](properties/lilly-receipt-survives-control-loss.md), [`lilly-outcome-replay-exact-ack`](properties/lilly-outcome-replay-exact-ack.md), [`lilly-interrupted-launch-at-most-once`](properties/lilly-interrupted-launch-at-most-once.md), [`lilly-async-result-keeps-command-identity`](properties/lilly-async-result-keeps-command-identity.md), [`continuing-boot-advances-generation-without-second-boot`](properties/continuing-boot-advances-generation-without-second-boot.md), [`transient-observation-is-not-absence`](properties/transient-observation-is-not-absence.md), [`lilly-finite-obstruction-recovery-progress`](properties/lilly-finite-obstruction-recovery-progress.md), [`store-v3-host-binding-survives-upgrade`](properties/store-v3-host-binding-survives-upgrade.md), [`execution-v4-refuses-legacy-document`](properties/execution-v4-refuses-legacy-document.md).

### Physical lifecycle and guest readiness

Readiness binds a physical boot; stop retains disk while delete requires exact retirement. A fresh control report cannot substitute for a new guest readiness proof.

[`guest-readiness-binds-current-physical-boot`](properties/guest-readiness-binds-current-physical-boot.md), [`private-readiness-v1-gates-new-execution`](properties/private-readiness-v1-gates-new-execution.md), [`runtime-restart-requires-fresh-readiness`](properties/runtime-restart-requires-fresh-readiness.md), [`stop-retains-disk-until-restart`](properties/stop-retains-disk-until-restart.md), [`delete-release-follows-physical-retirement`](properties/delete-release-follows-physical-retirement.md), [`upgrade-preserves-owned-guests`](properties/upgrade-preserves-owned-guests.md).

### Relocation and native custody

Database handoff must line up with source revocation, physical stop, destination ownership and exact cleanup receipts. Native utility descendant custody protects underlying exclusive mutations, but does not itself prove one current VM writer.

[`relocation-handoff-one-current-execution`](properties/relocation-handoff-one-current-execution.md), [`cancelled-relocation-restores-after-revocation`](properties/cancelled-relocation-restores-after-revocation.md), [`source-stop-after-committed-placement-holds`](properties/source-stop-after-committed-placement-holds.md), [`native-utility-descendant-custody`](properties/native-utility-descendant-custody.md), [`stale-local-execution-cannot-forward-guest-bytes`](properties/stale-local-execution-cannot-forward-guest-bytes.md).

### Control transport and coordination

Outer Control v1 binding/version/refusal is separate from inner service documents. Pending retirement and no hidden redelivery handle uncertain replies, while hint reconciliation supplies progress after finite loss.

[`control-bind-before-domain-effects`](properties/control-bind-before-domain-effects.md), [`control-bound-credential-revalidated`](properties/control-bound-credential-revalidated.md), [`control-service-dispatch-closed`](properties/control-service-dispatch-closed.md), [`control-version-refusal-remains-terminal`](properties/control-version-refusal-remains-terminal.md), [`control-pending-response-retirement`](properties/control-pending-response-retirement.md), [`control-no-hidden-redelivery`](properties/control-no-hidden-redelivery.md), [`control-inflight-limit-and-retirement`](properties/control-inflight-limit-and-retirement.md), [`control-hint-loss-reconciles-authority`](properties/control-hint-loss-reconciles-authority.md), [`host-session-successor-fences-old-exchanges`](properties/host-session-successor-fences-old-exchanges.md), [`host-credential-rotation-fences-old-socket`](properties/host-credential-rotation-fences-old-socket.md), [`lost-host-hint-eventually-delivers-command`](properties/lost-host-hint-eventually-delivers-command.md), [`porsche-wait-never-resubmits-mutation`](properties/porsche-wait-never-resubmits-mutation.md).

### Private access and lease expiry

Current membership and per-request credential checks fence new admission. Local lease expiry and physical execution fences cover already open byte streams; an expired response cannot be rescued by late renewal or a stalled accounting dependency.

[`current-membership-gates-new-private-web`](properties/current-membership-gates-new-private-web.md), [`expired-web-lease-stops-existing-guest-bytes`](properties/expired-web-lease-stops-existing-guest-bytes.md), [`audi-authority-request-start-deadline`](properties/audi-authority-request-start-deadline.md), [`lease-expiry-independent-of-blocked-renewal`](properties/lease-expiry-independent-of-blocked-renewal.md), [`lilly-view-restart-withdraws-stream-authority`](properties/lilly-view-restart-withdraws-stream-authority.md), [`stale-local-execution-cannot-forward-guest-bytes`](properties/stale-local-execution-cannot-forward-guest-bytes.md), [`galileo-accounting-delay-does-not-renew-old-grant`](properties/galileo-accounting-delay-does-not-renew-old-grant.md).

### Guest identity and workspace publication

Immutable GuestAccount identity is separate from mailbox/name history. Image source capability gates admission; boot-bound delivery and guest source replay precede checkout publication. VM-ready must not imply checkout-complete.

[`guest-identity-cutover-preserves-uid-custody`](properties/guest-identity-cutover-preserves-uid-custody.md), [`guest-identity-never-transfers-on-email-reuse`](properties/guest-identity-never-transfers-on-email-reuse.md), [`source-v2-capability-gates-admission`](properties/source-v2-capability-gates-admission.md), [`source-v2-delivery-envelope-v1-boot-bound`](properties/source-v2-delivery-envelope-v1-boot-bound.md), [`guest-workspace-source-replay-once`](properties/guest-workspace-source-replay-once.md), [`guest-workspace-restart-publication-no-clobber`](properties/guest-workspace-restart-publication-no-clobber.md), [`guest-ready-does-not-claim-workspace-checkout`](properties/guest-ready-does-not-claim-workspace-checkout.md).

### Terminal effect and memory custody

Create and input sequence idempotency protect guest PTY effects. Ring backing, viewer queues and explicit kill under backpressure have distinct physical witnesses; bounded memory does not imply neighbor progress.

[`terminal-create-reply-loss-one-pty`](properties/terminal-create-reply-loss-one-pty.md), [`terminal-input-frame-replay-once`](properties/terminal-input-frame-replay-once.md), [`terminal-physical-scrollback-budget`](properties/terminal-physical-scrollback-budget.md), [`terminal-stalled-viewer-neighbor-progress`](properties/terminal-stalled-viewer-neighbor-progress.md), [`terminal-kill-progress-under-pty-backpressure`](properties/terminal-kill-progress-under-pty-backpressure.md).

### Inference effect and accounting custody

Durable spool admission precedes provider effects; interrupted work cannot be reexecuted. Immutable completion replay conserves one aggregate contribution, which does not prove one provider effect by itself.

[`ziggy-spool-capacity-before-provider`](properties/ziggy-spool-capacity-before-provider.md), [`ziggy-interrupted-inference-never-reexecutes`](properties/ziggy-interrupted-inference-never-reexecutes.md), [`ziggy-completion-once-accounted`](properties/ziggy-completion-once-accounted.md).

### Enrico publication and native admission

Published immutable Git content survives failed refresh independently of volatile attempt receipts. Native inherited slot locks limit physical work even when Manager state restarts.

[`enrico-published-head-remains-addressable`](properties/enrico-published-head-remains-addressable.md), [`enrico-attempt-replay-bounded-receipts`](properties/enrico-attempt-replay-bounded-receipts.md), [`enrico-native-git-admission-after-manager-restart`](properties/enrico-native-git-admission-after-manager-restart.md), [`native-utility-descendant-custody`](properties/native-utility-descendant-custody.md).

### Brady cache and listener

Complete object publication is independent of pool headroom and read-lease retention. Socket worker bounds protect a different resource than cache storage.

[`brady-cache-complete-publication`](properties/brady-cache-complete-publication.md), [`brady-cache-physical-headroom-and-leases`](properties/brady-cache-physical-headroom-and-leases.md), [`brady-listener-socket-worker-bound`](properties/brady-listener-socket-worker-bound.md).

### Diagnostics and measurement custody

Recorder and trace archive receipts are independently durable measurements, not lifecycle authority. Capacity refusal must remain visible; ACK loss must not erase unexpired accepted bytes or invent clean coverage.

[`request-recorder-restart-conserves-custody`](properties/request-recorder-restart-conserves-custody.md), [`request-recorder-capacity-does-not-admit-phantom-work`](properties/request-recorder-capacity-does-not-admit-phantom-work.md), [`trace-archive-ack-loss-preserves-replay`](properties/trace-archive-ack-loss-preserves-replay.md), [`trace-spool-physical-quota-with-retained-custody`](properties/trace-spool-physical-quota-with-retained-custody.md).

### Backup graph and historical authority

Manifest reference closure establishes recoverable component bytes but not a simultaneous global snapshot. Owned cleanup cannot destroy foreign resources, and a mixed-time restore remains isolated until authority reconciliation.

[`backup-retained-manifest-closure`](properties/backup-retained-manifest-closure.md), [`backup-interrupted-cleanup-owned-only`](properties/backup-interrupted-cleanup-owned-only.md), [`backup-time-skew-never-activates-historical-authority`](properties/backup-time-skew-never-activates-historical-authority.md).

### Upgrade and versioned activation

Migrator custody, live role restoration and exact current health jointly constrain promotion. A healthy revision does not prove unchanged guest process identity; those need native witnesses.

[`migration-finishes-before-upgrade-activation`](properties/migration-finishes-before-upgrade-activation.md), [`healthy-revision-requires-live-candidate`](properties/healthy-revision-requires-live-candidate.md), [`updater-failed-activation-recovers-live-roles`](properties/updater-failed-activation-recovers-live-roles.md), [`upgrade-preserves-owned-guests`](properties/upgrade-preserves-owned-guests.md), [`store-v3-host-binding-survives-upgrade`](properties/store-v3-host-binding-survives-upgrade.md), [`guest-identity-cutover-preserves-uid-custody`](properties/guest-identity-cutover-preserves-uid-custody.md).

## Suspected dominance and independence

- `backup-retained-manifest-closure` is necessary for a useful restored point but does not imply `backup-time-skew-never-activates-historical-authority`; valid component bytes can still carry historical authority.
- `marshall-admission-atomic-allocation` does not imply `marshall-admission-key-survives-archive`; one joined transaction can still be repeated after archival.
- `lilly-receipt-survives-control-loss` does not imply `lilly-interrupted-launch-at-most-once` or `guest-readiness-binds-current-physical-boot`; durable intent, effect submission and guest proof have different witnesses.
- `control-inflight-limit-and-retirement` does not imply `control-no-hidden-redelivery`; bounded pending memory can still replay a committed call.
- `ziggy-spool-capacity-before-provider` does not imply `ziggy-completion-once-accounted`; safe effect admission and accounting replay close different halves of the external-effect handoff.
- `brady-cache-complete-publication` does not imply `brady-cache-physical-headroom-and-leases`; a complete object can still consume unsafe pool space.
- `healthy-revision-requires-live-candidate` and `updater-failed-activation-recovers-live-roles` cover promotion and caught failure respectively; neither alone proves guest VMM continuity.

## Open questions

- Which hosted/TCG/native topology can share independent physical witnesses across clusters without replacing production authority paths?
- Which observed baseline durations justify conditional liveness windows after faults heal?

## Evaluation gap clusters

### Public routes, SSH and editor effects

These properties join public route authority to real DNS, SSH and editor outcomes. [`authoritative-dns-follows-current-placement`](properties/authoritative-dns-follows-current-placement.md) [`editor-login-code-single-use-after-reply-loss`](properties/editor-login-code-single-use-after-reply-loss.md) [`editor-save-survives-worker-recovery`](properties/editor-save-survives-worker-recovery.md) [`editor-signout-fences-active-guest-write`](properties/editor-signout-fences-active-guest-write.md) [`revoked-ssh-key-refuses-fresh-guest-login`](properties/revoked-ssh-key-refuses-fresh-guest-login.md) [`strict-ssh-host-trust-reaches-current-guest`](properties/strict-ssh-host-trust-reaches-current-guest.md).

### Agent and named integration effects

These properties cover tool dispatch, renewable work and approved external origins. [`agent-long-fetch-result-retains-live-lease`](properties/agent-long-fetch-result-retains-live-lease.md) [`agent-started-tool-effect-not-redispatched`](properties/agent-started-tool-effect-not-redispatched.md) [`galileo-named-origin-credential-and-revocation-bound`](properties/galileo-named-origin-credential-and-revocation-bound.md).

### Browser identity and administration

These properties test browser sign-in and current administrative authority across replicas. [`magic-link-preview-post-mfa-boundary`](properties/magic-link-preview-post-mfa-boundary.md) [`remembered-cookie-revocation-cross-replica`](properties/remembered-cookie-revocation-cross-replica.md) [`stale-admin-tab-current-mutation-authority`](properties/stale-admin-tab-current-mutation-authority.md).

### Customer create to retained guest use

This composed property tests whether a customer can use the identity and bytes produced by a create. [`authenticated-create-to-retained-guest-file`](properties/authenticated-create-to-retained-guest-file.md).

### Clone, resize and relocation data

These properties test retained bytes and real routes through physical lifecycle changes. [`clone-two-drive-copy-survives-source-deletion`](properties/clone-two-drive-copy-survives-source-deletion.md) [`resize-retains-exact-guest-bytes-and-grown-shape`](properties/resize-retains-exact-guest-bytes-and-grown-shape.md) [`stopped-relocation-retains-bytes-and-routes-to-destination`](properties/stopped-relocation-retains-bytes-and-routes-to-destination.md).

### Physical isolation and egress

These properties require actual packet and process witnesses at the guest boundary. [`brady-flow-attribution-requires-current-incarnation`](properties/brady-flow-attribution-requires-current-incarnation.md) [`brady-forbidden-destinations-never-reach-upstream`](properties/brady-forbidden-destinations-never-reach-upstream.md) [`brady-proxy-loss-preserves-web-and-quic-denial`](properties/brady-proxy-loss-preserves-web-and-quic-denial.md) [`brady-sensitive-exchanges-never-reuse-shared-cache`](properties/brady-sensitive-exchanges-never-reuse-shared-cache.md) [`native-firecracker-confinement-survives-owner-recovery`](properties/native-firecracker-confinement-survives-owner-recovery.md) [`native-guest-packets-obey-profile-and-tap-boundaries`](properties/native-guest-packets-obey-profile-and-tap-boundaries.md).

### Operational publication and independent user effects

These properties test host/guest update, enrollment, secrets and diagnostic fault separation. [`diagnostic-outage-preserves-authorized-user-effect`](properties/diagnostic-outage-preserves-authorized-user-effect.md) [`host-enrollment-receipt-follows-live-health`](properties/host-enrollment-receipt-follows-live-health.md) [`lyra-guest-update-fences-executor-handoff`](properties/lyra-guest-update-fences-executor-handoff.md) [`runtime-secret-bundle-complete-or-previous`](properties/runtime-secret-bundle-complete-or-previous.md).

### Optional recursive profile

This property requires both outer and inner authority in an enabled Inception environment. [`inception-parent-publication-cannot-confer-child-authority`](properties/inception-parent-publication-cannot-confer-child-authority.md).

### Backup publication and isolated restore

These properties compare actual Restic publication and isolated target markers under interruption. [`backup-interrupted-restore-target-unpublished`](properties/backup-interrupted-restore-target-unpublished.md) [`backup-published-manifest-retention-compatible`](properties/backup-published-manifest-retention-compatible.md).

The [historical restore reentry candidate](discovery/gaps/restore-publication/backup-historical-restore-reentry-reconciliation.md) remains deferred until an explicit activation receipt is defined; quarantine safety remains in the catalog.

### Android display transport fencing

This protocol boundary is independent of terminal framing but shares generation fencing and bounded-byte custody with guest lifecycle properties. [`android-display-stream-generation-and-frame-bounds`](properties/android-display-stream-generation-and-frame-bounds.md) should be exercised with delayed old-generation frames and independent forwarding observations.

### Team authorization and account lifecycle

[`team-transfer-consent-preserves-single-owner`](properties/team-transfer-consent-preserves-single-owner.md) connects current Cedar team authority, transfer state-machine fencing, and account retirement. It should be exercised with [`stale-admin-tab-current-mutation-authority`](properties/stale-admin-tab-current-mutation-authority.md) and [`guest-identity-never-transfers-on-email-reuse`](properties/guest-identity-never-transfers-on-email-reuse.md): all three depend on committed identity changes remaining ordered under concurrent stale actors.

### Bootstrap readiness and process ownership

This property is a cross-profile gate joining independent readiness probes to process lifetime. [`bootstrap-setup-complete-single-owner`](properties/bootstrap-setup-complete-single-owner.md) dominates profile-specific setup observations: a workload must not classify later properties as exercised until the single setup marker is ordered after all required probes.
