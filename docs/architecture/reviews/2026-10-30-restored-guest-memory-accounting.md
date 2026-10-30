# Restored guest memory accounting (2026-10-30)

Scope: the return relocation in `audi-relocation-fleet` panicked its
provisioner host. This review covers the root cause, the fix accepted as
[ADR-0266](../decisions/0265-anonymous-restored-guest-memory.md), and its
relation to [ADR-0199](../decisions/0199-memory-suspension-and-demand-wake.md),
[ADR-0010](../decisions/0010-capacity-admission-transactions.md) and
[ADR-0159](../decisions/0159-remove-legacy-compatibility.md).

## Findings

1. **High, capacity/isolation: a restored guest was not bounded by its accounted
   memory.** `Lilly.VM.API.load_checkpoint/3` requests the `File` backend.
   Upstream Firecracker 1.16.1 maps the memory file `MAP_PRIVATE`
   (`vstate/memory.rs` `snapshot_file`), so the VM cgroup is charged page cache
   for read pages and anonymous copies for written ones. The next full
   checkpoint's `write(2)` of guest RAM goes through `zfs_write`, whose
   `zfs_uio_prefaultpages` faults the rest of the mapping in via
   `filemap_fault`. Recorded OOM on `l2`: usage = limit = 589824 kB, `file`
   511 MB (424 MB mapped), `anon` 88 MB, `pgscan` 223, then
   `Kernel panic - not syncing: Out of memory: compulsory panic_on_oom`. Cold
   boot memory is anonymous, which is why the first move passed. ADR-0199 does
   not fix the backend, so this was an unstated design gap, not a violation.
   Resolution: ADR-0266 patches the VMM to copy the file into anonymous memory,
   skipping zero pages. `MemoryMax` is unchanged.
2. **Checked: ADR-0199 custody stays as written.** The restore slot is still
   sealed read-only, prebound and retired only after confirmed absence. Not
   being mapped any more grants no earlier retirement; no ADR-0199 text was
   superseded. Its evidence section now links ADR-0266.
3. **Checked: compatibility.** The VMM store path changes, so ADR-0199's exact
   VMM identity comparison refuses memory moves between hosts on different sides
   of the rollout. That is the intended ADR-0159 converged-rollout behaviour.
4. **Not this cause: `github-integration-fleet` relocation timeout.** The
   recorded run at 06:21 on 2026-10-30 (drv `v5gbzpiw…`) repeats
   `relocation.admission_refused reason=source_unavailable` for the
   "owner exclusion survives real relocation" subtest, then times out. The log
   has no `invoked oom-killer`, `memory: usage` or `Kernel panic` line, and that
   subtest is the guest's first relocation after a stop and a fresh native
   start, not a second checkpoint of a restored guest. `source_unavailable` comes from
   `Marshall.Compute.ClonePlacement` (source host missing from the eligible set,
   stale pool capacity, or no disk hold). It still needs its own investigation.

## Alternatives considered

The UFFD backend, `O_DIRECT`/fadvise eviction of the written checkpoint, moving
the page-cache charge elsewhere, prefaulting the mapping and raising
`MemoryMax` are compared in ADR-0266. UFFD is the only other option that fixes
the accounting. It was not chosen because it needs a per-VM handler process
whose crash would hang the guest.

## Verification

- Firecracker `vmm` crate unit tests, run locally against the full patch series
  on tmpfs: all `vstate::memory` tests pass, including
  `test_snapshot_file_restores_into_anonymous_memory` (mincore residency,
  contents, clean dirty bitmap), `test_snapshot_file_copies_across_chunk_boundary`,
  `test_snapshot_file_refuses_short_file` and the property
  `snapshot_file_copy_matches_file_and_populates_nonzero_pages`. The upstream
  `test_dump_dirty` and `dump_dirty_correctness` assert file block counts and
  also fail unpatched on a ZFS temporary directory, so they are not in the
  sandboxed filter list. The TAP-dependent persistence tests need
  `/dev/net/tun` and were not run.
- Nix checks: `firecracker-patch-tests`, `firecracker-vmm` and
  `windows-guest-unit`.
- Machine: `audi-relocation-fleet` asserts that the restored unit's
  `file_mapped` is below 32 MiB and performs the return relocation.

## Results

- `firecracker-patch-tests` passed:
  `/nix/store/0sg6k0l0mn4xzw8bmhyiykkh9qj8c1vy-firecracker-patch-tests-static-x86_64-unknown-linux-musl-1.16.1`
  (63 selected tests, including every new test). `firecracker-vmm`
  (`/nix/store/hvx2512vvvp8cvnahm7riqiww0qyz6h1-firecracker-vmm`) and
  `windows-guest-unit` also passed. After the record was renumbered to ADR-0266,
  which changed only patch comments, `firecracker-patch-tests` re-passed as
  `/nix/store/d1igchap36jx69lqhpvnhp2wifxx3br3-firecracker-patch-tests-static-x86_64-unknown-linux-musl-1.16.1`
  and `firecracker-vmm` as `/nix/store/xik5p8qxydrzhrj481i8997z080p9csz-firecracker-vmm`.
  The machine run below used the pre-renumbering patch text.
- `audi-relocation-fleet` passed:
  `/nix/store/fvmc3f3d4017pcnlkyyfc8yaixv68m1w-vm-test-run-overalls-audi-relocation-fleet`.
  The restored guest's unit reported `file_mapped` 1662976 bytes, against 424 MB
  in the failing run. The return relocation checkpointed the restored guest,
  committed and cleaned up with no OOM or panic.
- `github-integration-fleet` still fails as finding 4 describes (27
  `source_unavailable` refusals, then the fixture timeout), with no OOM or panic
  line. That failure is independent of this change.
