# ADR-0145: Block-cloned disks for same-pool clones

- ID: ADR-0145
- Date: 2026-10-07
- Status: accepted
- Implementation: partial
- Components: Lilly Clone, Lilly Transfer, Lilly Host
- Supersedes: none
- Superseded by: none

## Context

After ADR-0143 deployed (compressed same-host streams at a 1 GiB/s local
rate, prompt reporting), a same-host clone on Overalls took 37.8 s: published
at 29.5 s, with the copy effect at 21.5 s. With capture renewal back to
once a second and the local rate configured, the copy moves about 1.3 GB
physical at about 60 MB/s. The bound is therefore native `zfs send | zfs receive`
throughput on a loaded host, not throttling or polling. The copy is the largest
single clone phase. The ADR-0130 template release changes only creation, not
the clone copy.

ADR-0143 natively proved that `copy_file_range` from a same-pool source on
another mount shares blocks: in the image-copy machine test, `bcloneused` grew
by the whole file. Guest disks are plain files (`rootfs.ext4`) in per-placement
datasets. A capture snapshot exposes them read-only under
`.zfs/snapshot/lilly-b/`.

Today adoption trusts a destination dataset because `zfs receive` preserves the
source snapshot GUID lineage and the local nonce. A block-cloned destination
has no receive lineage, so that proof does not apply.

## Decision

When the clone destination is the source's host and pool:
1. **Create the disk.** Lilly creates an ordinary owned destination dataset
   through the existing creating → bound claim, with its own nonce.
2. **Copy by offload.** It materializes each disk file from the GUID-verified
   capture snapshot path with `lilly-image-copy` (kernel offload, with the
   existing allowlisted fallback). No stream, rate limit or hashing is involved.
3. **Record the copy.** A local clone-copy journal records the source dataset
   and snapshot GUIDs, the permit revision, each file's size and identity
   before and after, and the destination claim nonce.
4. **Adopt on a dedicated path.** Adoption for this mode verifies:
   - the destination claim nonce;
   - the source snapshot GUID still matching the permit;
   - unchanged source file identities across the copy;
   - a completed journal.

   This replaces receive-lineage verification for this mode only. Cross-pool
   and cross-host clones keep send/receive.

Marshall's protocol, phases and the destination dataset's independence
(origin `-`, no ZFS clone dependency) are unchanged.

Authorization: the user approved implementing this proposal ("do all",
2026-10-09).

**Historical rollout before ADR-0149.** Lilly's lifecycle audit used a closed
protocol allowlist, requiring two releases:
- **Release A (readers):** `OverallsProtocol.LifecycleAudit` and Marshall accept
  the `CloneCopy` resource (`copying copied adopted retiring retired`). No
  producer exists in this release.
- **Release B (producer):** the Lilly journal and the copy, adopt and cleanup
  paths, behind an off-by-default host switch. It is enabled only after native
  evidence exists.

[ADR-0149](0149-independent-observability.md) retires those diagnostic-wire
readers. The current copy path retains its local Ash state machine, state-only
journal, native ownership proofs and capacity accounting. Compatible native
journals and closed accounting reports, native evidence and a controlled rollout
remain prerequisites; a diagnostic ACK confers no adoption or cleanup authority.

## Alternatives

- **`zfs clone` plus `zfs promote`.** This creates origin dependencies that
  block independent deletion, violating ADR-0112 and ADR-0143 independence.
- **Keep send/receive and tune it** (larger pipe windows, `-L`, bypassing
  `lilly-transfer-stream` locally). This gives smaller gains, still bounded by
  pool throughput.
- **Content hashing at adopt.** That reintroduces the full-disk read that this
  decision removes.

## Consequences

- **Speed:** same-pool clone copies would take about as long as block-pointer
  cloning, typically seconds for multi-GB disks.
- **Code:** a second adoption mode adds journal, recovery and verification
  code. It needs crash-recovery properties and native tests equivalent to
  today's receive path.
- **Space:** block sharing changes physical accounting. Cloned blocks count
  once per pool until rewritten, so capacity observations must keep counting
  logical commitments, not shared physical blocks.

## Invariants and verification

- Destination datasets MUST remain independent: origin `-`, and deletable
  regardless of the source.
- Adoption MUST refuse a destination whose claim nonce, source snapshot GUID,
  file identities or journal state do not match.
- An interrupted copy MUST leave an unpublished, owned destination that the
  existing cleanup removes.
- Required evidence:
  - native `zfs-guest-clone` variants for the same-pool path, including crash
    after a partial offload and source-snapshot replacement;
  - `bcloneused` growth;
  - unchanged cross-host behaviour.

## Implementation evidence

- **Historical Release A (diagnostic readers):** the
  protocol allowlist (`protocol/lib/overalls_protocol/lifecycle_audit.ex` at overalls revision `a99f74f0`, repository deleted),
  its test (`protocol/test/lifecycle_audit_test.exs` at overalls revision `a99f74f0`, repository deleted) and the
  Marshall mapping (`marshall/lib/marshall/compute/lifecycle_log.ex` at overalls revision `a99f74f0`, repository deleted).
- **Release B prerequisites:**
  - the [snapshot source mode](../../../lilly/native/image-copy/src/lib.rs), with Hegel properties;
  - [capture extraction](../../../lilly/lib/lilly/transfer/source_snapshots.ex).

- **Release B (producer; module option defaults off):**
  - the [clone-copy journal](../../../lilly/lib/lilly/transfer/clone_copy_journal.ex)
    and its [lifecycle resource](../../../lilly/lib/lilly/lifecycle/clone_copy.ex),
    with [property tests](../../../lilly/test/transfer/clone_copy_journal_test.exs);
  - the [copy, adopt and discard paths](../../../lilly/lib/lilly/transfer/clone_copy.ex),
    dispatched from durable local state in
    [clone effects](../../../lilly/lib/lilly/clone/effects.ex);
  - the former `block_clone_copies` configuration and `services.lilly.blockCloneCopies`
    Nix option (both removed by ADR-0159),
    and [unit tests](../../../lilly/test/transfer/clone_copy_test.exs);
  - native coverage in the [`zfs-guest-clone` block-copy subtest](../../../nix/verification/tests/machines/zfs-guest/clone-matrix.py),
    which passed on 2026-10-09. It covers:
    - `bcloneused` growth and independent origins;
    - a chained block copy;
    - guest data in both copies;
    - deleting the sources;
    - discard of a copied, unadopted destination.

**Correction (2026-10-09).** The copy reads the capture snapshot through a
private read-only mount (`/run/lilly-clone-copies/<relocation>`), not the
`.zfs/snapshot/lilly-b/` automount. Automounts would expose the snapshot under
the source placement's path and outlive the copy. The GUID is verified before
the mount and re-verified before completion.

Incoming `e3300040` reports that `blockCloneCopies` has been enabled on both
hosts since `47139d61` (2026-10-09). Current
[Dungarees](../../../fleet/hosts/dungarees/configuration.nix) and
[Overalls](../../../fleet/roles/control-plane/services.nix) declarations set it to
`true`. Source configuration and the incoming author's production report do not
establish an independently captured post-cutover clone measurement.

**Update (2026-10-11, [ADR-0159](0159-remove-legacy-compatibility.md)):** the
`blockCloneCopies` switch and its `block_clone_copies` configuration key were
removed. Every same-host, same-pool clone now block-copies in
[clone effects](../../../lilly/lib/lilly/clone/effects.ex); adopt and discard
still follow the durable copy journal. The native
[`zfs-guest-clone` matrix](../../../nix/verification/tests/machines/zfs-guest/clone-matrix.py)
runs in this single mode: the resized and chained clones are block copies too,
and every run discards a copied, unadopted destination. Same-host clones across
pools keep the local stream receive, which this matrix no longer exercises.

**Correction (2026-10-12).** Discard could not retire a locally adopted copy:
the journal and the `CloneCopy` lifecycle treated adoption as final. A clone
cancelled after Lilly's adopt but before Marshall published it therefore
retried `clone_copy_state_unconfirmed` forever; native `clone-cancellation`
first reached this once block copies became unconditional. An adopted import
stays retirable, and this decision keeps Marshall's protocol unchanged, so the
[journal](../../../lilly/lib/lilly/transfer/clone_copy_journal.ex) and the
[lifecycle](../../../lilly/lib/lilly/lifecycle/clone_copy.ex) now allow
`adopted` to `retiring`. Retirement still fences further adoption, and
deletion still requires the bound GUID
([journal test](../../../lilly/test/transfer/clone_copy_journal_test.exs)).

**Correction (2026-11-01).** `CloneCopy.copy/3` and `adopt/2` folded a failed
pool-lock wait into `clone_copy_unconfirmed`. A concurrent pool observation
can hold the lock for seconds, so native `clone-cancellation` and the
`zfs-guest` clone journey failed intermittently with an unconfirmed copy or
`destination_cleanup_unconfirmed`. Both now return the closed contended reason
`storage_busy`, which Marshall retries as `copy_storage_busy` or
`adopt_storage_busy`, and the
[VM driver](../../../lilly/lib/lilly/vm/driver.ex)'s destination retirement
passes it through
([adoption test](../../../lilly/test/transfer/clone_copy_test.exs), contract
`clone-copy-contention-stays-busy`). The
[native fixture](../../../nix/verification/tests/machines/clone-cancellation/driver.py)
accepts contended labels and slots released by both revoke receipts while
cancelling (contract `clone-stream-slots-require-both-revocations`). The
decision is unchanged.

Remaining:
- native crash-after-partial-offload and source-snapshot-replacement cases;
- a production clone measurement.

## Open questions

- Whether same-pool placement should be preferred once copies are cheap; today
  placement takes the first eligible host and pool by id.
- Interaction with ADR-0130 templates, which share blocks across VM disks.

## Related decisions

- [ADR-0143](0143-faster-create-clone-delete.md)
- [ADR-0037](0037-workload-placement-and-relocation.md)
- [ADR-0112](0112-zfs-namespace-delete.md)
- [ADR-0130](0130-verified-provisioning-fastpath.md)
- [ADR-0149](0149-independent-observability.md)
