# ADR-0271: Hosts self-deploy by building their Buck2 deployment target

- ID: ADR-0271
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: host updates, build, NixOS deployment
- Supersedes: none
- Superseded by: none

## Context

Each fleet host updates itself with
[runtime.py](../../../nix/domains/system/auto-update/runtime.py). It clones
the candidate revision into `checkouts/<revision>` and runs
`nix build <checkout>#nixosConfigurations.<host>…` through an isolated Nix
daemon (the `update-builds-use-isolated-daemon` contract). The flake loses its
`nixosConfigurations` once Buck2 becomes the only build entry point
([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)). The user decided
on 2026-10-30 that hosts run buck2 locally.

## Decision

1. **Deployment target.** Each host has a Buck2 target,
   `//fleet/hosts/<host>:deployment`, whose output is the NixOS system
   closure. Its per-host parameters (crash-dump encryption, antithesis flags,
   private service roots) are target attributes. An assembly assertion checks
   that they match the module options.
2. **Updater.** The updater runs
   `tools/buck2 build //fleet/hosts/<host>:deployment --show-output`.
   - It always uses one fixed checkout path and isolation directory, rather
     than a new directory per revision, so the daemon and buck-out stay warm.
   - It activates exactly the closure that buck2 reports.
   - It runs `buck2 kill` when it times out or cleans up, because buckd
     outlives the updater's process group.
3. **Cache.** Hosts read the NativeLink cache
   ([ADR-0272](0272-nativelink-remote-cache-and-execution.md)) and fall back to
   building locally. They never upload to it.
4. **Revision.** Assembly receives the candidate revision as an argument in
   place of `self.rev`, so deployment telemetry
   ([ADR-0259](0259-deployment-revision-telemetry.md)) keeps naming the
   deployed source.
5. **Activation gate.** No change removes `nixosConfigurations` until every
   host, including the `-base` fixtures, reports the Buck2 updater active.

Authorization: the user's 2026-10-30 answer that hosts run buck2 locally, and
the approved migration plan (M2).

## Alternatives

- **CI builds closures and hosts substitute them.** This is less work on each
  host, but it makes hosts depend on CI to update and changes the recovery
  model, where each host verifies and builds its own candidate.
- **Keep a flake output only for hosts.** This is a backwards-compatibility
  layer, which the user rejected, and it would leave two build definitions of
  every system.

## Consequences

- Hosts gain buck2, the cells closure, git and Nix. Their disk use and their
  first cold build grow.
- The updater's in-VM fixtures must become offline Buck2 fixture repositories.
- Machine tests for auto-update, credential rotation, host conversion and host
  enrolment verify the change.

## Invariants and verification

- The updater activates only the closure printed by the deployment target for
  the verified candidate revision.
- buckd never survives an updater timeout. The auto-update machine suite's
  hanging-candidate subtest checks this.
- Telemetry names the candidate revision. Checked by the
  `deployment-revision-source` contract, revised in M2.
- **Failure case:** a cache entry produced from a different revision would be
  activated without being caught. Actions are content-addressed and hosts
  never upload, so a poisoned entry would need a compromised CI uploader.
  [ADR-0272](0272-nativelink-remote-cache-and-execution.md) covers that
  boundary.

## Implementation evidence

Milestone M2 (2026-10-30) implements decisions 1, 2, 4 and the updater side of 5.
M10 (2026-10-30) implements decision 3.

- **Targets.** [buck/fleet.bzl](../../../buck/fleet.bzl) declares
  `:deployment`, `:base` and `:install` in each
  `fleet/hosts/<host>/BUCK`. It uses `nix_assemble`
  ([buck/assemble.bzl](../../../buck/assemble.bzl)) over `lib.assemble`.
  `//nix/platform:kexec` assembles `kexec`. Every one of them passes
  `ASSEMBLY_ARTIFACTS` ([buck/artifacts.bzl](../../../buck/artifacts.bzl)),
  as machine tests do. Since e5fe2ffde that dict names five Buck2-built Rust
  leaves: lilly-host-helpers, enrico-git-owner, otel-guest-receiver,
  observability-runtimes and trace-spool. A host's first post-M2 update
  therefore activates those binaries instead of their Nix builds, and the
  updater compiles them locally through the pinned Rust toolchain and the
  `rust//` cell.
  - `:deployment` builds `systems.<host>.config.system.build.overallsDeployment`.
    That is the system closure plus its deployment descriptor, which is the
    bundle the updater activates. It is not the bare `toplevel`.
  - For the same tree and revision, `//fleet/hosts/salopettes:deployment`
    produced the same store path as
    `lib.assemble { revision; }.systems.salopettes…overallsDeployment`. This
    holds once [nix_assemble.sh](../../../buck/nix_assemble.sh) keeps
    executable bits. Before that fix, Susan's dependency source hash forked.
- **Updater.** In [runtime.py](../../../nix/domains/system/auto-update/runtime.py),
  `Deployment.build` checks out the candidate at the fixed `checkout` path.
  It then runs the candidate's `tools/buck2 --isolation-dir overalls-update build -c overalls.revision=<rev> //fleet/hosts/<host>:deployment --show-full-output`.
  - It validates the single reported `store-path`, roots that path and
    activates exactly it.
  - If the wrapper is missing or cannot start, the attempt fails closed as
    `build_tool_unavailable`. If the report is unexpected, it fails as
    `build_output_invalid`. There is no other build path.
  - `stop_buck2` runs `buck2 kill` before and after every build, including
    after timeouts. The post-stop cleanup does the same.
  - `buildTimeout` bounds each build command.
  - Every Buck2 invocation runs with private state. `HOME` is
    `buck2-home` and `OVERALLS_GCROOT_DIR` is the root-owned `gcroots`
    directory, both under the updater's 0700 state directory. The updater
    reads only the `store-path` output and never a `result` link.
  - The updater writes the checkout's `.buckconfig.local` to select the
    `fs_hash_crawler` file watcher. `notify` follows buck-out links into the
    system closure, and on a 9p store that took about 100 s per daemon start.
  - `.buckconfig` ignores `.buck-cells.key`, `.buck-cells.gcroot` and
    `.buckconfig.local` (7f4a33af7). The M2 updater test found the need:
    without it, the root package glob picked up the cells GC-root link, and
    `nix_assemble`'s `cp -RL` copied the whole Buck2 closure into every
    assembled tree. That filled the test VM's disk after a few builds.
  - The contracts `updater-buck2-deployment-build` and
    `updater-buck2-daemon-stopped` cover this. `updater-candidate-identity`,
    `deployment-descriptor-baseline`, `deployment-revision-source` and
    `update-builds-use-isolated-daemon` are revised in place, with their
    reasons stated in the text.
  - `status.json` records `builder: "buck2"` after each Buck2 build. This is
    the per-host signal for the activation gate.
- **Cache reads (M10, decision 3).** The updater's `HOME` is its private
  `buck2-home`, so root's `~/.buckconfig.d` cache file never applied to it.
  The buck-re module passes the cache address, CA and identity path as the
  updater's `remoteCache` setting, and `buck2_local_config` in runtime.py
  appends the read-only `[buck2_re_client]` section to the checkout's
  `.buckconfig.local` only while the identity is a non-empty regular file and
  the listener accepts a connection within 5 s. The file always sets
  `default_allow_cache_upload = false` and `remote_execution = false`, and the
  attempt log records `update.remote_cache`. A build that fails while the
  section is enabled is retried once without it (`fallback`), so a cache that
  answers but fails never fails an update. Contracts
  `updater-remote-cache-read-only` and `updater-remote-cache-fail-open`; unit
  tests in the auto-update compatibility check; the `buck-remote-cache`
  machine test builds as the updater does (cache hit for a CI-uploaded
  action; local builds with the cache stopped, the identity absent, and the
  identity rejected by the listener or not a certificate).
- **Fixtures.** [support/update-fixture.nix](../../../nix/verification/tests/support/update-fixture.nix)
  builds an offline Buck2 fixture repository. It contains the real wrapper,
  `.buckconfig`, toolchains and rules, plus the pinned buck2 with cut-down
  cells. [support/update.py](../../../nix/verification/tests/support/update.py)
  publishes candidates through it.
  - The users are the auto-update, credential-rotation and fleet suites, and
    host-enrollment's published update.
  - restrict-eval refuses `path:` inputs, so fixtures name their prebuilt
    candidates with `builtins.storePath`.
- **Machine tests.** The [auto-update driver](../../../nix/verification/tests/machines/auto-update/driver.py)
  adds four checks:
  - the activated bundle equals the target's report;
  - no buckd survives a run;
  - a candidate without `tools/buck2` fails closed;
  - a hanging build times out with its daemon and builder gone.

  The M2 change records each suite's run result in the
  [migration review](../reviews/2026-10-30-buck2-migration.md). auto-update,
  credential-rotation, host-conversion, host-enrollment (nix check and
  `tools/buck2 test`), audi-relocation-fleet and customer-isolation-fleet
  pass. In host-enrollment, the enrolled host's published update builds
  through the Buck2 target.
  - Offline fixtures read their preloaded sources through lookup-path
    entries (`nix.settings.extra-nix-path`), because restrict-eval refuses
    `path:` and `file:` inputs and `builtins.storePath` names a path without
    admitting reads. Production inputs are `github:` and are covered by
    `allowed-uris`.
  - Machine-test assembly declares the new packages. `NIX_INPUTS` names the
    host and `nix/platform` packages, which now own their directories. The
    suites that copy the update fixture also declare `//:buck_project`, the
    `//buck` and `//tools` sources, the toolchains cell and the two BUCK files
    the fixture copies. `owned_set` places toolchains-cell files under
    `toolchains/`.

Remaining:

- The per-host parameters stay fleet-wide `lib.assemble` defaults, because
  no host sets crash-dump encryption, antithesis flags or private service
  roots individually today. `nix_assemble` has no `params` channel yet.
- The operator CLI ([cli.py](../../../nix/domains/artifacts/host/cli.py))
  still builds `nixosConfigurations`. It moves to `:base` and `:install`
  before the gate.
- Hosts compile the `ASSEMBLY_ARTIFACTS` leaves in the updater unless CI has
  uploaded them for the same cells and revision; that needs CI's cache
  secrets (ADR-0272). The offline update fixture holds no
  application sources, so it replaces `buck/artifacts.bzl` with an empty
  dict. Its assemblies take every leaf from Nix, which means the in-VM tests
  do not exercise Buck2-built leaves on the update path. Machine-test
  assemblies and the `[drv]` evaluation of the real host targets do cover
  them.
- The activation gate itself is still open.

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md),
  [ADR-0272](0272-nativelink-remote-cache-and-execution.md),
  [ADR-0259](0259-deployment-revision-telemetry.md) and
  [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
- [ADR-0036](0036-automatic-host-updates.md) and its successors define
  verified automatic host updates. This record changes only how the candidate
  is built.
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
