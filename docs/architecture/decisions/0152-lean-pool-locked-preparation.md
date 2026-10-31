# ADR-0152: Lean pool-locked disk preparation

- ID: ADR-0152
- Date: 2026-10-10
- Status: accepted
- Implementation: partial
- Components: Lilly Host, Lilly VM
- Supersedes: none
- Superseded by: none

## Context

With ADR-0146 standbys, no disk copy remains on the create path. The
2026-10-10 absolute campaign (latency review, same date) measured these
create-to-SSH medians:
- NixOS 13.4 s;
- Ubuntu 11.3 s.

A 12.9 s NixOS create spent:
- about 1.8 s before the host starts provisioning;
- 3.8 s materializing;
- 0.3 s launching;
- 6.4 s in guest boot and trust;
- 0.6 s waiting for SSH.

Within materializing, the drive steps themselves take milliseconds. About 2 s
is pool-locked verification, which runs roughly 20–25 native ZFS commands at
about 100 ms each over 268 datasets on Overalls:
- `ZFSDataset.claim/2` observes the whole pool to prove the child is absent.
- `prepare/2` observes again and runs `allocations/2`. That runs:
  - an owner listing;
  - findmnt;
  - `ImageTemplate.audit/3`, which costs about four commands per template:
    `zfs get`, two `read_datasets` calls and another owner listing;
  - the claim and disk audit.
- The standby claim runs `standby_child` both before and after its
  `zfs set`, then re-reads owners.
- `verify_child` observes the pool a third time.

Because the pool lock is held throughout, four concurrent creates serialize
about 3 s apart. Each waiting create defers with `storage_busy`, and the four
took 23–33 s.

## Decision

Each pool-locked preparation acquires one validated native snapshot and derives
every check from it.
- **One logical snapshot.** The validated `zfs list` row set retains the existing
  two consecutive tree reads and identity checks. One owner listing and one
  mount table are read under the same lock and passed to classification, the
  allocation audit, the template and standby audits, and the claim.
- **Templates validated from the rows.** `ImageTemplate.audit/3` joins the
  observation's rows for mountpoint, seal and GUID, as the standby audit has
  done since `6195e392`. The exec, setuid and devices seal is checked when
  the template is sealed and when a reader validates it, not on every
  observation.
- **Snapshot passed into the claim.** `claim/3`, `materialize_dataset/5` and
  `StandbyDisk.claim/4` receive the snapshot instead of re-observing. After
  `zfs set` and `zfs rename`, only the target child is re-read, with one
  targeted owner read and one `zfs get` covering the shape.
- **One re-verification after the claim.** After a native mutation, the pool
  is re-read once through `PoolSnapshot.reread/3` and checked by `verify_snapshot/4`,
  not re-observed before each step.

The checks and the refusal semantics stay exactly as they are. The change
removes redundant reads, not verification.

## Alternatives

- **Pool-lock sharding** (per-placement locks). Rejected: capacity and
  ownership classification needs a whole-pool view.
- **Caching observations across lock acquisitions.** Rejected: a stale
  snapshot could authorize a claim against changed native state.
- **Fewer standbys.** Rejected: this reduces rows but not the number of
  commands, and the user set 128 per image.

## Consequences

- **Expected savings:** pool-locked time drops from about 2–3 s to about
  0.4–0.6 s per create (about 4–6 commands), cutting about 1.5–2 s from every
  create.
- **Concurrency:** four concurrent creates should finish within about 2 s of
  a single one.
- **Remaining time:** guest boot and trust (about 6 s) becomes the dominant
  remaining phase. It needs separate guest-side measurement (kernel, initrd
  and systemd to the trust agent) before any decision.

## Invariants and verification

- Every refusal reachable today MUST remain reachable:
  - unknown or foreign children;
  - GUID changes;
  - unsealed templates;
  - mismatched standby shapes;
  - mounts;
  - capacity.
- No check may consult native state read before the lock was acquired.
- Required evidence:
  - existing native `image-template`, `zfs-guest` and `zfs-guest-clone`
    subtests;
  - a property test that snapshot-derived classification equals the current
    per-command classification over generated trees;
  - an absolute campaign showing reduced `materializing` and 4-way
    concurrency.

## Implementation evidence

Update (2026-10-31): capacity reports no longer read the snapshot under the
lock. [ADR-0274](0274-fenced-capacity-snapshots.md) fences them with a pool
generation token instead, and a fenced snapshot fails `held?/1`, so the
invariant that no check consults native state read before the lock was
acquired still holds for every check that authorizes a mutation. Preparations,
readiness and claims are unchanged.


The [2026-10-18 retained-bundle review](../reviews/2026-10-18-retained-bundle-capacity.md)
records a capacity-audit correction: a child with exact claim, owner, GUID,
mount, drive and ready-disk metadata may be recognized without allocation credit
when only its current launch bundle is invalid and bounded boot-file custody
remains safe. Those storage refusals remain
strict, and launch/readiness still refuse the invalid bundle. The correction
does not decode or rewrite a retired format under ADR-0159; native execution
evidence and remaining gaps are recorded separately in the review.

The user accepted this decision on 2026-10-10 in the implementing session.

**Code:**
- [`PoolSnapshot`](../../../lilly/lib/lilly/host/pool_snapshot.ex) reads the
  snapshot expectations, the observation, one owner listing and one mount table
  under the held lock. `held?/1` refuses a snapshot after its lock is released.
- [`ZFSDataset.prepare/3`](../../../lilly/lib/lilly/host/zfs_dataset.ex) reads one
  snapshot after `bind/1`. The absence proof, `classify_allocations/2` and
  `materialize_dataset/5` derive from it. A native create or standby rename is
  followed by one `PoolSnapshot.reread/3`; otherwise the snapshot verifies the
  child. A new child's owner tags are re-read for that child only.
- [`ImageTemplate.audit/3`](../../../lilly/lib/lilly/host/image_template.ex) joins
  observed rows through `ZFS.observed_artifact/6` and keeps the private-directory
  stat. Template sealing and reader validation still check exec, setuid and devices.
- `StandbyDisk.claim/4` (`lilly/lib/lilly/host/standby_disk.ex`, removed by ADR-0177) takes the
  standby's owner, mount state and sealed shape from the snapshot. After its
  `zfs set` it makes one targeted `ZFS.standby_target/2` read. Sweep recovery
  keeps its remount and native reads.
- `Disk.prepare` no longer repeats the parent identity check and `vms/`
  creation that `bind/1` already performs under the same lock.
- [`Pool.snapshot/1`](../../../lilly/lib/lilly/host/pool.ex) and backup capture
  classify from the same snapshot type.

**Redundancy evidence.** Each removed read repeated data from the same lock
window:
- the second and third whole-pool observations;
- owner listings repeated per template, before and after the claim and for binding;
- `findmnt` repeated in classification;
- the claim-time `zfs get mounted`, which the observation's mounted policy
  already establishes;
- the pre-set `standby_child` read;
- classification's snapshot expectations.

Merge review clarified the earlier phrase "single `zfs list` row set" as one
validated logical snapshot, not permission to omit the existing consecutive
consistency reads or pool identity checks. The implementation and measured
command counts retain those checks. Snapshot-taking claim arities above are
corrected to the implemented interfaces; the refusal and lock-window decision
is unchanged.

A new `creating` claim contributes no expectation: no transfer index pointer
exists, and backup and transfer expectations require `ready` or `deleting`
claims.

**Measured before and after** (native `image-template` trace subtest; one
template, two standbys; only `zfs`, `zpool` and `findmnt` are traced):

| Pool-locked preparation | Traced utilities | `zfs`/`zpool` | Whole-pool recursive listings | Lock held |
| --- | --- | --- | --- | --- |
| Standby claim, before (`e4d5b6cc` + trace subtest) | 56 | 46 | 12 | 2.005 s |
| Standby claim, after | 33 | 26 | 6 | 1.629 s |
| Bound resume, before | 36 | 28 | 7 | 1.200 s |
| Bound resume, after | 16 | 12 | 3 | 0.679 s |

The fixture pool holds only a few datasets. The listings removed per claim each
scale with pool size, about 268 datasets on Overalls. The kept identity checks
(`inspect_path` before and after each observation, and two equal reads) explain
the gap from the estimate of 4–6 commands. That estimate counted an
observation as one command.

**Tests:**
- the [pool snapshot properties](../../../lilly/test/host/pool_snapshot_test.exs):
  - snapshot-derived artifact shape equals the targeted per-command read over
    generated accepted trees;
  - the template audit join equals the per-template native audit;
  - a stale snapshot is refused;
  - each property passed and failed a seal mutant; the first also failed a
    mountpoint mutant;
- the native [`image-template` trace subtest](../../../nix/verification/tests/machines/image-template/driver.py)
  bounds the claim at 26 `zfs`/`zpool` commands and 6 whole-pool listings, and
  the resume at 12 and 3;
- native `image-template` passed on 2026-10-10 at the implementation revision,
  including the standby claim, fault-recovery and sweep subtests. The script
  took 334.82 s. A rerun with the bounds asserted took 344.46 s; that rerun
  measured holds of 1.461 s for the claim and 0.602 s for the resume, with
  identical counts.
- native `zfs-guest-clone` passed on 2026-10-10 at the implementation revision
  (2129.30 s script). Later revisions change only formatting, a type name and an
  unreachable Dialyzer clause.

**Remaining:** an absolute production campaign showing reduced `materializing`
and four-way concurrency; until then the implementation is partial.

## Open questions

- Guest boot and trust (about 6 s): whether a NixOS guest boot profile
  (kernel command line, initrd and early-unit ordering) or earlier trust
  delivery can reach the under-10 s target. This needs guest-side timing
  first.

## Related decisions

- [ADR-0130](0130-verified-provisioning-fastpath.md)
- [ADR-0143](0143-faster-create-clone-delete.md)
- [ADR-0146](0146-standby-guest-disks.md)
