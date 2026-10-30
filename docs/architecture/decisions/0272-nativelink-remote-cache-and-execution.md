# ADR-0272: NativeLink remote cache and execution for Buck2

- ID: ADR-0272
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: build, fleet infrastructure, CI
- Supersedes: none
- Superseded by: none

## Context

Buck2 caches actions locally ([ADR-0269](0269-buck2-build-system-with-nix-toolchains.md)).
Without a shared cache, CI runners, developers and self-deploying hosts
([ADR-0271](0271-buck2-host-self-deployment.md)) would each compile cold. The
fleet already runs Nix build scheduling over the tailnet with a private CA and
SOPS client credentials ([ADR-0248](0248-fleet-build-scheduling.md)). The user
chose a NativeLink cache plus remote execution on 2026-10-30.

## Decision

1. **Placement.** NativeLink's scheduler and its content and action caches
   (CAS/AC) run on panterloons. Remote-execution workers run on panterloons
   and dungarees.
2. **Network and credentials.** The service listens only on the tailnet, with
   an assertion that its port is never open on public interfaces. Clients
   authenticate with certificates from a private CA (`fleet/buck-re/`), and
   each host's client certificate is held in SOPS.
3. **Who may write.** CI runners may upload and use remote execution. They
   join with an ephemeral Tailscale key. Hosts may only read the cache.
   Developers use the tailnet. NativeLink cannot authorise per certificate,
   so reads and uploads use separate listeners, each trusting only its own
   CA under `fleet/buck-re/`.
4. **Workers.**
   - Workers run in the pool-mount-free namespace of
     [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
   - They fetch the `buckCells` closure from the signed Cachix
     ([ADR-0188](0188-signed-overalls-cachix-substitution.md)).
   - Actions carry an `overalls-cells=<hash>` platform property, so they run
     only on workers that have those toolchains.
5. **What stays local.** Nix store imports, NixOS assembly, machine tests and
   the non-hermetic Mila platform builds always run locally, and their
   outputs are never uploaded.
6. **Order.** The cache ships before the Rust and Elixir moves (M4b), so host
   updates do not cold-compile. Remote-execution workers follow in M10.
7. **Fallback.** Without credentials, actions run locally.

Authorization: the user's 2026-10-30 answer choosing a NativeLink cache plus
remote execution, and the approved migration plan.

## Alternatives

- **Buck2 local cache only.** This is simplest, but every host deployment and
  CI job compiles cold.
- **Cachix or a Nix binary cache for Buck2 outputs.** Buck2 needs a REv2
  action cache, and Nix caches store paths, not action results.
- **BuildBuddy or EngFlow as a hosted service.** They are mature, but they put
  build inputs off the fleet and add a vendor credential.

## Consequences

- Warm builds for CI, developers and hosts.
- New fleet services to operate. A cache outage degrades builds to local
  only and does not block them.
- Remote execution covers Linux x86_64 only.
- Known limits of remote execution on guest hosts (M10): worker I/O is
  weighted, not bandwidth-capped; Lilly's capacity admission does not count
  the worker's memory cap; and the tailnet policy restricting
  `tag:buck-re-ci` to Panterloons' port 50072 is an operator action, so until
  it is set only mTLS separates CI from the other listeners.
- **Security gap, fixed in 927d837e9; enabling `BUCK_RE` remains the
  user's decision: cache poisoning through worker-identity exposure.** In M10 remote actions ran as the worker user
  and could read the worker's mTLS identity, which registers workers and
  writes the CAS and action cache on the worker listener (50074), so anyone
  who got an action executed could feed forged outputs to every host that
  reads the cache. M10b runs every action through a sandbox as a separate
  user that cannot reach the identity (see Implementation evidence).
  NativeLink cannot tie action-cache writes to a registered worker: any
  certificate from the worker CA may write, so the worker CA's only leaves
  are the two worker identities and forged ones fail TLS. The Dungarees
  worker stays off until Panterloons has run the fix healthy. The sandbox's
  privileges are an accepted risk, recorded in the migration review (M10c).

## Invariants and verification

- Only CI identities can write to the action cache, and host credentials are
  read-only. Verified by the `buck-remote-cache` machine test.
- The listener is never reachable off the tailnet. Enforced by the module's
  address binding, interface restriction and assertions, and verified by the
  `buck-remote-cache` and `buck-remote-execution` machine tests.
- Workers never see guest datasets and remote execution always falls back to
  local. Verified by the `buck-remote-execution` machine test.
- Outputs of `local_only` actions are never uploaded (`allow_cache_upload =
  False` in the rules).
- **Failure case:** a compromised CI runner could upload poisoned action
  results that hosts then trust. The mitigation is that the CI uploader runs
  only on trunk pushes and dispatches from this repository (corrected in M10:
  ci.yml has no pull-request trigger and the step checks the repository,
  event and ref). The residual risk
  is recorded in the migration review.

## Implementation evidence

M4b (cache) and M10 (remote-execution workers, host updater cache reads)
are implemented in the repository and pass their machine tests. The
implementation stays `partial` until the services are deployed on Panterloons
and Dungarees and CI has its secrets.

- **Package.** NativeLink is not in the pinned nixpkgs. The
  [package](../../../nix/domains/artifacts/nativelink/default.nix) builds
  release v1.8.3 from source, with its source and Cargo hashes in the
  [pin registry](../../../nix/domains/artifacts/dependency-hashes.json). Its
  licence is FSL-1.1-ALv2: self-hosted internal use is a permitted purpose,
  and each release becomes Apache-2.0 two years after publication. v1.x is
  needed for the listener's `freebind` option.
- **Module.** [buck-remote-execution.nix](../../../nix/domains/system/buck-remote-execution.nix)
  runs one NativeLink process with one store set and two mTLS listeners.
  NativeLink cannot authorise per certificate, so the write split is per
  listener and per CA:
  - the read listener (50071) trusts only the reader CA, which issues host
    certificates. Its action cache is `read_only` and refuses updates with
    `PermissionDenied`; its CAS is a read-only view whose uploads are
    discarded, never persisted;
  - the upload listener (50072) trusts only the uploader CA, which issues
    only the CI certificate. Its CAS verifies size and hash on upload.
  Both listeners bind the tailnet address with `freebind`, never a wildcard,
  and `RestrictNetworkInterfaces` limits the process to loopback and
  `tailscale0`. This matters because the fleet firewall admits reviewed
  public fleet sources to every port. Assertions refuse a firewall-opened
  port, a wildcard or loopback address, and storage inside a Lilly pool; the
  pool paths are also inaccessible to the unit (ADR-0144). Storage is
  `/var/lib/nativelink`.
- **Credentials.** The [registry](../../../fleet/buck-re.nix) takes the
  server, readers, tailnet address and ports from the
  [fleet roster](../../../nix/policy/fleet/hosts.nix) and
  [port roster](../../../nix/policy/fleet/ports.nix), and the documents from
  host inventory. Public certificates are in [fleet/buck-re](../../../fleet/buck-re).
  Panterloons' document holds the server key and its reader identity, and
  Dungarees' holds its reader identity. The CI uploader identity is the
  recovery-only `buck-re-uploader-recovery` document. Both CA private keys
  were discarded after issuance, as in ADR-0248, so rotation reissues every
  certificate.
- **Clients.** The [execution platform](../../../buck/platforms.bzl) enables
  the remote cache only when a `[buck2_re_client]` address is configured, and
  uploads only with `[buck2] default_allow_cache_upload = true`. Developers and CI
  put both in the untracked `.buckconfig.local`. On hosts, a unit installs root's
  `~/.buckconfig.d/overalls-remote-cache` only while the decrypted identity
  exists, and withdraws it otherwise. Buck2 ignores symlinks and includes in
  that directory, so the file is a regular copy.
- **Machine test.** [buck-remote-cache](../../../nix/verification/tests/machines/buck-remote-cache/default.nix)
  boots a cache, a CI client, a host and an outsider. It checks the
  tailnet-only binding, that the listeners are unreachable through the public
  interface even when routed there, CA separation per listener, a CI
  action-result and blob write that a host reads, the host's
  `PermissionDenied` and discarded blob, local fallback without credentials,
  and buck2 uploads and cache hits through both client configurations.
  It passed on 2026-10-30, both as the flake check and as the Buck2 target
  `//nix/verification/tests/machines/buck-remote-cache:buck-remote-cache`.

- **Remote execution (M10).** The same process on Panterloons runs the
  scheduler. Execution is served on two listeners, so the per-CA write split
  holds:
  - the upload listener (50072, CI) gains the execution service;
  - a new execute listener (50073) trusts only the executor CA, which issues
    developer certificates. Developers upload inputs and execute, but its
    action cache is `read_only`: only workers and CI record results;
  - a new worker listener (50074) trusts only the worker CA and serves the
    worker API, the CAS and the writable action cache.
  The scheduler accepts one platform property, `overalls-cells` (`exact`), and
  fails an action no connected worker can run, or one queued with no worker,
  after `unmatchedTimeout` (15 s), so the client falls back to local
  execution instead of waiting. The read listener has no execution service,
  so a host identity cannot execute even if a client asks.
- **Workers.** `overalls.buckRemoteCache.worker` runs a NativeLink worker on
  each roster `buildCache.workers` host (Panterloons and Dungarees). Its start
  script runs as root in the unit's private mount namespace, lazily and
  recursively unmounts every Lilly pool there (the
  [ADR-0144](0144-nix-builds-exclude-guest-datasets.md) pattern nix-daemon
  uses), copies the worker identity for the worker user, and drops to
  `nativelink-worker` with no capabilities and `no_new_privs`. It first
  makes its namespace `rprivate`, so a pool or guest dataset mounted later
  never propagates in. The unit reaches only loopback and the scheduler's
  tailnet address (`RestrictNetworkInterfaces`, `IPAddressAllow`), has no
  devices (`PrivateDevices`, so no `/dev/zfs`), and cannot see the secrets
  runtime, the SSH host identity that decrypts SOPS documents, the updater's
  state, or Lilly's control state, sockets, clone, ingress and Firecracker
  directories (`InaccessiblePaths`); its own identity arrives through
  `LoadCredential`. Its cgroup is capped beside the guests: `CPUWeight` and
  `IOWeight` 20, `CPUQuota` 100% per in-flight task (half the host's threads
  in the fleet), `MemoryHigh` 20% and `MemoryMax` 25% of RAM, no swap,
  `TasksMax` 8192, `Nice` 10 and `OOMScoreAdjust` 1000, so the kernel kills
  the worker before a guest or Lilly.
- **Action sandbox (M10b).** The worker's `entrypoint` is
  [buck-re-action-sandbox.c](../../../nix/domains/system/buck-re-action-sandbox.c),
  installed by the start script on a tmpfs private to the unit with
  `cap_setuid,cap_setgid,cap_setpcap,cap_sys_admin+ep` file capabilities,
  owned `root:nativelink-worker`, mode 0750. The worker keeps only those four
  in its bounding set (none effective, permitted, inheritable or ambient;
  `no_new_privs` is off so the file capabilities apply, and `/run/wrappers`
  is hidden so no setuid binary is reachable). For
  each action the sandbox enters fresh mount, PID, IPC, UTS and network
  namespaces, masks every other action directory, the worker's state, runtime
  and sandbox directories, gives the action a private `/tmp` and `/proc`,
  empties the action's bounding and ambient sets, drops to
  `nativelink-action` with no capabilities and `no_new_privs`,
  closes inherited descriptors and runs the action under its own PID 1, so
  nothing the action starts outlives it. The action user shares only the
  `nativelink-build` group with the worker, for the action directory;
  inputs are the worker's read-only hardlinks. Executing is still trusted
  like uploading: executor identities go only to operators, and the CI
  identity was already an uploader.
- **Cells.** [cells.nix](../../../nix/buck/cells.nix) writes `[nix] cells_id`,
  a SHA-256 of every toolchain store path, the rust cell and buck2. The
  [execution platform](../../../buck/platforms.bzl) puts
  `overalls-cells=<cells_id>` on every action, cached or executed, so cache-only
  hosts and executing clients share action digests. A worker advertises the
  id of one cells closure it holds: a root unit reads the host updater's
  checkout `.buck-cells` link (the deployed revision's cells, which the
  updater's `tools/buck2` realised from Cachix), realises and roots it under
  `/var/lib/nativelink-worker-cells`, and restarts the worker when the id
  changes; a path unit watches the checkout's cells key. The plan named "a
  hash of the cells key"; the wrapper's key hashes the wrapper's input files
  with a locale-dependent sort and a worker cannot recompute it, so the id is
  derived from the cells contents and read back from the same file on both
  sides.
- **Clients.** The execution platform enables remote execution only on Linux
  x86_64 with a `[buck2_re_client]` address, a `cells_id` and
  `[overalls] remote_execution = true`, as limited hybrid with fallbacks:
  remote first, local when remote execution fails as infrastructure.
  `local_only` actions (Nix store imports, assembly, repository checks that
  list files) stay local, and test commands, machine tests included, carry a
  local-only executor. No `non_hermetic` target exists yet; its rules must set
  `local_only`. Developer and CI configuration is the untracked
  `.buckconfig.local`.
- **CI.** [.github/actions/buck-re](../../../.github/actions/buck-re/action.yml)
  joins the tailnet with an ephemeral key (`tag:buck-re-ci`) and writes the
  uploader configuration for ci.yml's build, test and precommit jobs. It is
  off by default: it runs only when the repository variable `BUCK_RE` is
  `enabled`, both `BUCK_RE_TAILSCALE_AUTHKEY` and `BUCK_RE_UPLOADER_IDENTITY`
  exist, and the run is a trunk push or a dispatch in `ghuntley/overalls`;
  ci.yml has no pull-request trigger and forks receive no secrets. The step
  continues on error and configures nothing when the upload listener does not
  answer, so the `ci` gate never depends on NativeLink or the tailnet.
- **Who can submit actions.** Every listener binds only the scheduler's
  tailnet address and requires a client certificate from one CA:
  50071 (read) the host CA, no execution; 50072 (upload, executes) the
  uploader CA, held by CI and the recovery-only uploader document;
  50073 (execute) the executor CA, held only by the recovery-only
  `buck-re-executor-recovery` document for operators; 50074 (worker API) the
  worker CA, held by the two worker documents. Neither NativeLink nor the
  tailnet adds a token. GitHub-hosted runners and pull requests, forks
  included, hold no identity; ci.yml's Namespace runners hold the uploader
  identity only on trunk pushes and dispatches. The tailnet policy restricting
  `tag:buck-re-ci` to Panterloons' 50072 is the operator's to set.
- **Host updates read the cache** ([ADR-0271](0271-buck2-host-self-deployment.md)
  decision 3). The updater runs Buck2 with its own `HOME`, so root's
  `~/.buckconfig.d` file never applied to it. The auto-update module now
  receives the cache address, CA and identity path from this module, and
  [runtime.py](../../../nix/domains/system/auto-update/runtime.py) writes the
  read-only `[buck2_re_client]` section into the checkout's
  `.buckconfig.local` only while the identity file exists and the listener
  accepts a TCP connection within 5 s, always with
  `default_allow_cache_upload = false` and `remote_execution = false`. The
  attempt log records `update.remote_cache`. There is no unit dependency on
  the cache.
- **Credentials (M10).** Two more CAs, `executor-ca` and `worker-ca`, with
  private keys discarded after issuance. Worker identities are new per-host
  documents (`<host>-buck-re-worker`) and the developer identity is the
  recovery-only `buck-re-executor-recovery` document.
- **Machine tests.** `buck-remote-cache` adds the updater path: with the
  production runtime and the module's settings, a host build under a private
  `HOME` hits the CI-uploaded action, builds locally when NativeLink is
  stopped or the identity is absent, and hits again once the identity
  returns. [buck-remote-execution](../../../nix/verification/tests/machines/buck-remote-execution/default.nix)
  boots a scheduler with a worker, a second worker host, CI, a developer and
  an outsider. It checks tailnet-only binding of all four listeners (also
  when the tailnet address is routed through the public interface), CA
  separation, the developer's refused action-cache write, that the read
  listener cannot execute, CI remote execution and a cache hit afterwards
  (also for the developer), execution on each worker host in turn, that
  workers see no pool mounts (including one mounted after they started) and
  run without capabilities, that remote probes see no guest dataset and no
  Lilly, secret or SSH host-identity path, that the unit's sandbox settings
  and the running cgroup's CPU, swap and task caps hold, that a
  `local_only` action stays local, and local fallback for an action no worker
  can run and for a stopped scheduler. Recorded passing on 2026-10-30 through
  `tools/buck2 test` (all 12 subtests): the unmatched-cells action fell back to
  a local build after the scheduler's 15 s timeout (subtest 14.9 s), and with
  the scheduler stopped a developer build fell back and completed locally
  (subtest 71.0 s, including the stop and a fresh Buck2 daemon). This is test
  evidence only; the decision stays `partial` until a deployment receipt.
  M10b adds two subtests, recorded passing on 2026-10-30 with the other 12:
  a remote action runs as `nativelink-action` and cannot open the worker
  identity, its runtime, state or sandbox directories, the secrets bundle or
  the credential, cannot write the worker's store, sees only its own two
  processes under the sandbox's PID 1, inherits no worker environment or
  descriptor above stderr, and cannot connect to the scheduler; and a
  forged worker (the worker's name from an untrusted CA) and every non-worker
  identity are refused on 50074 for action-cache and CAS writes and worker
  registration, with nothing reaching the action cache hosts read.
  M10c extends the first (passing, all 14 subtests, 2026-10-30): inside the
  action `CapInh`, `CapPrm`, `CapEff`, `CapBnd` and `CapAmb` are all zero and
  `NoNewPrivs` is 1, and neither the sandbox's path nor `/proc/1/exe` can be
  opened or executed.

Remaining gaps:
- No deployment receipt on Panterloons or Dungarees yet; the hosts pick the
  services up through their updater. The rollout is single-host: Dungarees'
  worker is declared but disabled in its host configuration until
  Panterloons' worker has run healthy beside its guests.
- CI needs the operator to add `BUCK_RE_TAILSCALE_AUTHKEY` (ephemeral,
  pre-authorised, tagged `tag:buck-re-ci`, with a tailnet policy allowing it
  to reach only Panterloons' 50072) and `BUCK_RE_UPLOADER_IDENTITY`, set that
  tailnet policy, and set the repository variable `BUCK_RE` to `enabled`.
  Until then CI runs locally.
- Known limits, also listed under Consequences: worker I/O is weighted, not
  bandwidth-capped; Lilly's capacity admission does not count the worker's
  memory cap; the tailnet policy (`tag:buck-re-ci` to Panterloons' 50072
  only) is an operator action.
- Workers hold only the cells of their host's deployed revision, so remote
  execution helps only clients on that cells revision.
- The worker-identity gap is fixed in 927d837e9; enabling `BUCK_RE`
  remains the user's decision, and the Dungarees worker stays disabled until
  Panterloons has run the fix healthy. Action-cache writes are bounded by the
  worker CA, not by worker registration. No CRL is configured: rustls
  verifies a CRL's signature against its issuing CA, and the worker CA's key
  was discarded at issuance, so no CRL (empty or not) can be signed for it.
  Revoking a worker leaf is a CA rotation: a new worker CA, both leaves and
  both worker documents, which is a data change in `fleet/buck-re` and
  `secrets/` with no code change.
- No precommit timing with remote execution has been recorded.

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md),
  [ADR-0271](0271-buck2-host-self-deployment.md),
  [ADR-0248](0248-fleet-build-scheduling.md),
  [ADR-0188](0188-signed-overalls-cachix-substitution.md) and
  [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
