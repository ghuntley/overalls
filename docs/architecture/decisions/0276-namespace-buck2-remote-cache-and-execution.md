# ADR-0276: Namespace remote cache and execution for Buck2

- ID: ADR-0276
- Date: 2026-10-31
- Status: accepted
- Implementation: partial
- Components: build, fleet infrastructure, CI, secrets
- Supersedes: ADR-0272
- Superseded by: none

## Context

Buck2 has no persistent local action cache. Every daemon restart, fresh
clone and CI runner rebuilt from cold, and a precommit that reached an Elixir
test suite took 5.5 hours. The NativeLink cache of
[ADR-0272](0272-nativelink-remote-cache-and-execution.md) never warmed
anything in practice:
- CI's uploader needed a tailnet join and secrets that were never provisioned;
- developers had no writable listener;
- hosts read a cache that only CI could fill.

CI already runs on Namespace runners (`namespace-profile-cached-amd64*`).
Namespace also offers an REv2 cache and remote execution, which the user
chose on 2026-10-31. Observed facts:
- Buck2 accepts Namespace's endpoints as bare `host:port` with `tls = true`
  and rejects a `grpcs://` scheme.
- Namespace authenticates with an `x-nsc-ingress-auth: Bearer` header, and
  Buck2 expands an environment variable in `http_headers`.
- A tenant-scoped, revocable token (`nsc bazel create-token --scope tenant`)
  lasts up to one year.

## Decision

1. **Backend.** Namespace is the Buck2 remote cache and remote-execution
   backend for developers, fleet hosts and CI. It replaces NativeLink
   (ADR-0272). The fleet stops running the NativeLink server, scheduler,
   workers and host clients. Their module, registry, credentials and machine
   tests stay in the repository, dormant, for reactivation.

   Revised on 2026-11-01: the user approved retiring the dormant NativeLink
   leftovers, so they no longer stay for reactivation. The module, the
   worker sandbox, the package and its pins, the registry and its
   certificates, the host credentials and SOPS documents, the tailnet ports,
   the updater's NativeLink `remoteCache` client, the CI step and the
   `buck-remote-cache` and `buck-remote-execution` machine tests are removed.
   Reactivating NativeLink would need a new decision. ADR-0272 records the
   retiring commit.
2. **One tenant token, many writers.** A single tenant-scoped, revocable token
   authorises everyone. Every holder can read and write the cache, and the
   holders are:
   - developers on fleet hosts (`wheel`, who already hold sudo);
   - each host's updater (root);
   - CI on trunk pushes, dispatches and same-repository pull requests.

   ADR-0272 had kept hosts read-only and made CI the only writer. That gave a
   separate trust boundary only because the identities differed. Under one
   token, a read-only updater would add no boundary, so the updater uploads
   too, and hosts warm each other's deployment builds. This also amends
   [ADR-0271](0271-buck2-host-self-deployment.md) decision 3.
3. **Delivery.** The token is the SOPS document `fleet-namespace`. It is
   decrypted at boot on every host that names the credential, to
   `/run/overalls-secrets/fleet-namespace/token` (root and `wheel`). It is also
   the `NAMESPACE_RBE_TOKEN` repository secret. Developers off the fleet may
   use `~/.config/overalls/namespace-rbe-token.json`. The token never enters
   the Nix store, the repository, argv or a log.
4. **Client.** `tools/buck2` enables Namespace only while a token is
   available, through an untracked include of the tracked
   `tools/namespace.buckconfig`. That file names the token as
   `$NAMESPACE_RBE_TOKEN`, so the token itself is never written into it.
   Without a token, or with `OVERALLS_BUCK2_REMOTE=off`, builds stay local.
   `--no-nix` platform builds always stay local.

   Corrected on 2026-11-01:
   - **Uploads.** Buck2 reads `buck2.default_allow_cache_upload` only from
     the root `.buckconfig`, `.buckconfig.local` and user configuration, not
     from the include. Until this correction every action reported
     `ACTION_UPLOAD_NOT_ALLOWED`. Uploads had worked only on Panterloons,
     through a temporary `~/.buckconfig.d` file, until that file was deleted;
     CI and hosts never uploaded. The key now sits in the root `.buckconfig`.
     Without a token there is no remote cache, so nothing uploads.
   - **Endpoints.** Namespace's cache and scheduler addresses name the
     cluster's instances, and Namespace recreated the cluster on 2026-11-01
     (new instance IDs, so the committed addresses answered 404). Where `nsc`
     is logged in, `tools/buck2` now re-reads the addresses at most hourly with
     `nsc bazel setup -o json`, which also recreates a missing cluster.
     Elsewhere (hosts) the addresses committed in
     `tools/namespace.buckconfig` apply.
   - **Dead endpoints fail open.** Against a dead address Buck2 does not fall
     back: it retries every action's capability query, and builds and host
     self-updates stalled (Dungarees, 2026-11-01). `tools/buck2` now probes
     the cache address without credentials, bounded at five seconds and
     remembered for ten minutes. A 404 or no answer turns the cache off for
     that build, which then runs locally (decision 7).
5. **What stays local.** As in ADR-0272:
   - `local_only` actions never upload;
   - Nix imports, NixOS assembly, machine tests, test commands and the
     non-hermetic Mila platform builds run locally;
   - non-hermetic CI jobs receive no token;
   - host deployment builds keep `remote_execution = false`.

   Exception, recorded on 2026-11-01: `mix_release` stays `local_only` but
   sets `allow_cache_upload = True`, so one runner's release build serves
   every later assembly. This was checked before enabling it. All 39 release
   imports (10 applications as plain, `encrypted_crash_dumps` and Antithesis
   harness builds, Lilly's guest and integrated-host builds, and the seven
   fleet fixtures) were built on dungarees and scanned:
   - none carries an Erlang cookie;
   - the token-pattern hits are all false positives (Marshall's redaction
     regexes, and PEM header strings inside `ssh_file`, `pubkey_pem` and the
     JOSE beams);
   - the action's inputs are its declared sources, the pinned Hex
     dependencies and pinned Nix toolchains. It reads no host credential
     or configuration file. This was established by inspection, not by a
     sandbox.
   Lilly's releases contain one symlink (the host-tools link). The action
   cache refuses outputs with symlinks, so those releases still rebuild per
   runner. The `mix-release-cache-upload` contract in `buck/CONTRACTS`
   requires turning the upload off if a release ever gains a secret.
6. **Remote execution is the default where it is supported.** Remote
   execution runs on Namespace Linux workers whose image carries the
   `buckCells` closure. The image is digest-pinned in `nscr.io`, recorded per
   `cells_id` in the committed `tools/namespace-re-image.lock`, and its
   digest is a `container-image` platform property beside `overalls-cells` on
   every action whenever the lock matches, so all clients share action keys.
   `.github/workflows/namespace-re-image.yml` republishes the image and
   commits the lock after every trunk change to the cells' inputs, so remote
   execution does not silently lapse when the cells move.

   Wherever a token and a matching image exist (developer machines and CI
   jobs), `tools/buck2` executes every remotable action remotely.
   `OVERALLS_BUCK2_REMOTE_EXECUTION=off` keeps a build cache-only. Host
   deployments stay cache-only through the updater's `.buckconfig.local`
   (decision 5), and `local_only` actions stay local.

   History of this decision:
   - 2026-10-31, revised the same day: a developer opt-in, with CI and hosts
     cache-only. The workspace's 64-vCPU Linux cap is shared by CI runners
     and the Namespace cache, and Namespace documents no maximum worker
     count, idle timeout or scale-to-zero for remote-execution workers. One
     opt-in build started a 16x32 worker, which kept running until it was
     destroyed by hand. That queued CI runners behind it, so the user chose
     to stay inside the cap.
   - 2026-11-01, on the coordinating session's instruction: `ci.yml`'s build
     job also executed remotely.
   - 2026-11-01, the user's decision, relayed by the coordinating session:
     remote execution by default wherever it is supported, on developer
     machines and in CI, with an `off` escape hatch.

   **Trade-off accepted with the default.** Namespace still cannot bound the
   worker pool. A build may start two or more 16x32 workers (32 vCPU or more)
   that keep running after it ends, and they count against the same 64-vCPU
   cap as CI runners, so concurrent CI runs can queue behind idle workers.
   Mitigations: `nsc list` shows workers (`bazel.purpose=worker`) and
   `nsc destroy <id> --force` frees an idle one; any build can opt out with
   `OVERALLS_BUCK2_REMOTE_EXECUTION=off`; and a remote action that fails, or
   a scheduler that cannot place one, falls back to local execution. A
   separate Namespace workspace for workers, which would give them their own
   cap, is the open alternative (see Open questions).
7. **Fail open.** A Namespace outage, or a revoked or expired token, never
   blocks an update. The host updater retries a failed build once with
   `OVERALLS_BUCK2_REMOTE=off`.

Authorization: the user's 2026-10-31 instruction, relayed by the
coordinating session, to make Namespace the remote cache and RBE backend. The
coordinator approved the updater uploading on the same day.

## Alternatives

- **Keep NativeLink and add a developer-writable store.** This needs a new
  listener, CA and storage on Panterloons, and it still leaves CI dependent
  on a tailnet join and an uploader secret that were never provisioned.
- **A separate read-only token for hosts.** Namespace tokens are tenant-scoped
  rather than per-cache, so the read and write split of ADR-0272 cannot be
  expressed. A second tenant would split the cache and lose the
  cross-writer hits that motivate the change.
- **A Buck2 local disk cache.** Buck2 has none upstream. A local REv2 proxy per
  host would warm only that host.

## Consequences

- Fresh clones, daemon restarts, hosts and CI share one warm cache.
- Build inputs and outputs leave the fleet for Namespace, a vendor, which
  ADR-0272 had rejected. The user accepted this for speed.
- **Cache poisoning.** Anyone holding the token can write action results that
  hosts then deploy. The holders are fleet administrators with sudo, host
  updaters (root) and this repository's CI. Same-repository pull requests
  receive the secret; forks do not. This is a wider trust set than ADR-0272's
  CI-only uploader. A leaked token is revoked with `nsc token revoke`, after
  which hosts and CI build locally.
- The NativeLink services stop on the next host update. Their state under
  `/var/lib/nativelink*` stays until an operator removes it.

## Invariants and verification

- **Without a token, builds are local.** `tools/buck2` removes the include
  without a token, in `--no-nix` mode and under `OVERALLS_BUCK2_REMOTE=off`.
  Contract `buck2-namespace-optional` (tools/CONTRACTS).
- **The token is never written.**
  - It appears in no file in the checkout, in Buck2 logs or in the daemon
    state.
  - Contract `namespace-token-never-written`.
  - `tools/namespace-token-scan` runs after every CI Buck2 job that holds
    the token.
- **Token delivery reaches only root and `wheel`.** Contract
  `namespace-buck2-token-delivery`, and the `enrollment-configuration`
  evaluation test (`namespace-buck2-token-evaluation`).
- **Remote execution stays opt-in, and remote failures fall back to local.**
  - Contracts `namespace-re-worker-image`, `buck2-remote-cache-optional` and
    `buck2-remote-execution-optional`.
  - `local_only` actions never run remotely; the measured builds confirm it.
- **The updater never executes remotely, and a cache failure never fails an
  update.**
  - Contracts `updater-remote-cache-read-only` (revised) and
    `updater-remote-cache-fail-open`.
  - Unit tests `NamespaceCache` and `RemoteCacheConfiguration` in the
    auto-update compatibility check.
- **CI holds the token only in the job environment of its Buck2 jobs.**
  Contract `ci-namespace-cache` (.github/CONTRACTS).
- **Failure case.** A poisoned entry uploaded with a leaked token would be
  deployed. Detection depends on revocation and on
  `nsc token list` audits. Nothing here verifies cache contents against a
  local rebuild.

## Implementation evidence

Implementation is partial. The cache is implemented. Remote execution
(decision 6) is implemented and measured for Rust, as a developer opt-in; the
Elixir rules (M6) are not on trunk yet.

- **Client.** [tools/buck2](../../../tools/buck2),
  [tools/namespace.buckconfig](../../../tools/namespace.buckconfig) and the
  optional include in [.buckconfig](../../../.buckconfig).
  - Measured on Panterloons on 2026-10-31: a fresh clone with an empty
    `HOME`, after `buck2 kill` and `rm -rf buck-out`, built
    `root//nix:terminald` in 7.8 s with `Cache hits: 98%` and
    `Commands: 58 (cached: 57, remote: 0, local: 1)`.
  - With `OVERALLS_BUCK2_REMOTE=off`, or without a token, the include is
    absent and `audit config` shows no `[buck2_re_client]`.
- **Token scan.** [tools/namespace-token-scan](../../../tools/namespace-token-scan)
  found no `nsrt_` prefix in the include, the event logs, the command reports,
  the `-v 4` build output, `--version` or the daemon directory after a cached
  build.
- **Hosts.**
  - The NativeLink leftovers are removed from the repository (decision 1,
    revised 2026-11-01). The updater keeps only the Namespace path:
    `BUCK2_NAMESPACE_CONFIG` normally and `BUCK2_LOCAL_CONFIG`, which refuses
    uploads, for the fallback build.
  - [profile.nix](../../../nix/platform/hosts/profile.nix) declares the
    `fleet-namespace` bundle (group `wheel`, started at boot) for every host
    whose `host.json` names the credential (all three).
  - The NativeLink `forHost` lines are removed from the Panterloons and
    Dungarees configurations.
  - [runtime.py](../../../nix/domains/system/auto-update/runtime.py) logs
    `update.namespace_cache`, uploads under Namespace and retries with
    `OVERALLS_BUCK2_REMOTE=off`.
- **CI.** [ci.yml](../../../.github/workflows/ci.yml),
  [nixos-machine-tests.yml](../../../.github/workflows/nixos-machine-tests.yml)
  and the source-bundle, windows-ffi and journey-fixture jobs of
  [mila-builds.yml](../../../.github/workflows/mila-builds.yml) set
  `NAMESPACE_RBE_TOKEN` from the secret. GitHub-hosted runners have no `nsc`
  to resolve the live endpoints, so the KVM journey jobs there hold no token:
  they substitute the journey-fixture job's store path from Cachix and build
  locally only when it is missing (run 41335763927 had 0% cache hits). The
  NativeLink `buck-re` action and its script are removed, and so, on
  2026-11-01, is ci.yml's dangling step that still named the action and the
  `BUCK_RE_*` secrets.

- **Remote execution, opt-in.**
  - [tools/namespace-re-image](../../../tools/namespace-re-image) builds the
    image from the `buckCells` closure.
    - It leaves out the cells' 2,334 `.drv` files. These are read only by
      `local_only` Nix imports, and they are also why `dockerTools` failed:
      `exportReferencesGraph` pulled in their invalid bootstrap outputs.
    - It adds `/bin/sh` and `/usr/bin/env`.
    - It writes 40 deterministic layers of about 200 MiB, pushes them with
      the flake-pinned crane, runs `nsc base-image optimize` and writes the
      lock.
  - [buck/platforms.bzl](../../../buck/platforms.bzl) adds
    `container-image` and `allow_hybrid_fallbacks_on_failure`.
  - Namespace accepted the extra `overalls-cells` property.
  - After an opt-in build, `tools/buck2` names every running
    `bazel.purpose=worker` instance with its `nsc destroy` command. It
    destroys nothing itself, because another build may be using a worker.
- **Measured on Panterloons, 2026-10-31.**

  | Build | Wall time | Commands |
  | --- | --- | --- |
  | `root//nix:terminald`, cold local, no cache (coordinator's measurement) | 24 s | — |
  | `root//nix:terminald`, warm cache, fresh `buck-out` | 9 s | — |
  | `root//nix:terminald`, cold remote | 242 s | 58: cached 0, remote 49, local 9 |
  | `root//nix:terminald`, cache-only rebuild after the remote run | 9.7 s | 58: cached 49, remote 0, local 9 |
  | `salopettes:deployment[drv]` | 381 s | 457: cached 50, remote 342, local 65 |

  - About 3 minutes of the cold remote run was the first image pull, waiting
    in `re_queued`.
  - The cache-only rebuild shows that remote results serve cache-only
    clients.
  - In the `salopettes` build, every `nix_store_import` (11),
    `nix_assemble_drv` and `lyra_cross` action ran locally.
  - On a 96-thread development host, remote execution is slower than a
    local build plus the cache. That is the second reason cache-only is the
    default.
- **Worker image with `PATH` tools, 2026-11-01.** The lock now names
  `sha256:20bc6fa1…`, which adds the `/bin` links for coreutils, findutils,
  grep and sed. `nsc base-image optimize` took under five minutes. On
  Panterloons, `root//nix:terminald` with remote execution ran
  `Commands: 58 (cached: 0, remote: 50, local: 8)`: the `mkdir` genrule
  that fell back to local before now runs remotely. The build started two
  16x32 workers, destroyed by hand afterwards.
- **Fallback without masking.**
  - A genrule that calls `mkdir` from `PATH` failed on the worker and
    succeeded locally.
  - A planted `E0308` in terminald's `main.rs` ran remotely, then locally,
    and the build failed.

- **Remote execution by default and working uploads, 2026-11-01**, on
  Panterloons, in two fresh clones of the same revision (`root//enrico:git-owner`
  with a source edit no client had built, so no cache entry existed):

  | Build | Wall time | Commands |
  | --- | --- | --- |
  | Clone A before the upload fix, cache-only | 42 s | 18: cached 0, remote 0, local 18 (`ACTION_UPLOAD_NOT_ALLOWED`) |
  | Clone B before the fix, same revision | 32 s | 18: cached 0, remote 0, local 18 |
  | Clone B after the fix, remote execution by default | 5 min 56 s | 18: cached 0, remote 15, local 3 |
  | Clone A after the fix, after `rm -rf buck-out` | 11.7 s | 18: cached 18, remote 0, local 0 |

  - The remote build waited about five minutes in the queue. The scheduler's
    log showed `ResourceExhausted ... used all of 64 vCPU` for every attempt
    to start a 16x32 worker while CI runners held the cap, until capacity
    freed. Buck2's `remote_execution_queue_time_threshold_s` did not cut the
    wait short against Namespace, so it is not configured.
  - The lock now names `sha256:432163cc…`, rebuilt for the current cells with
    the `/bin` tool links and optimised with a temporary 8x16 instance, which
    Namespace removed afterwards.

- **CI, two dispatches of `ci.yml` on the same commit (f712c0e06, base
  50c80b6c9, so every target was selected), 2026-11-01.** Both build jobs
  failed at the end on a stale target name from the affected selection
  (`marshall_cedar-lib`), not on the cache.

  | Run (build job) | Wall time | Build summary |
  | --- | --- | --- |
  | 41274553637 (124757700141), first | 10 min 38 s | `Cache hits: 60%`, `Commands: 849 (cached: 507, remote: 13, local: 329)`, `Fallback: 266/342` |
  | 41274559163 (124813118199), second | 1 min 43 s | `Cache hits: 96%`, `Commands: 849 (cached: 818, remote: 0, local: 31)` |

  - The first run executed actions remotely in CI. 266 of its 342 remote
    attempts fell back to local while the shared cap had no room for
    workers.
  - The second run read back what the first uploaded, so CI writes the
    cache and later runs hit it.

Remaining gaps:
- No recorded deployment receipt for the token bundle on the hosts yet.
- No Elixir compile has been measured remotely: Mix actions are `local_only`
  (see Open questions).
- Namespace offers no bound or idle timeout for workers, and actions wait in
  its queue, without falling back, while the 64-vCPU cap is full.
- Hosts have no `nsc` login, so they rely on the committed endpoints and
  lose the cache, not the build, when Namespace recreates the cluster.
- No machine test exercises the Namespace path (see Open questions).

## Open questions

- **Bounding workers.** Whether a second Namespace workspace, holding only
  the remote-execution workers, would give them a cap of their own so they
  cannot queue CI runners. It would need its own token and cache, which
  splits cache hits unless the executing workspace also serves the cache.
- **Machine tests and the cache.** Machine tests currently build without
  the cache. The token must never enter a test VM. A proposal: the NixOS
  test driver, which runs on the CI runner or developer host outside the
  VMs, resolves the Buck2 outputs a test needs through `tools/buck2` with the
  cache before it starts the VMs, and passes them in as store paths. The VMs
  then need no network and no token, and the cache is used only by the
  driver's host process, as in any other build. Whether the NixOS test
  framework can take prebuilt Buck2 outputs this way is unverified.
- **Mix actions remotely.** Mix compile and test actions are `local_only`
  because their bubblewrap sandbox needs unprivileged user namespaces and a
  Nix-store build-state script outside the cells closure. Whether the
  Namespace worker allows unprivileged user namespaces, and whether the
  state script can join the image, is unmeasured.

## Related decisions

- [ADR-0272](0272-nativelink-remote-cache-and-execution.md) (superseded by
  this record).
- [ADR-0271](0271-buck2-host-self-deployment.md): decision 3 is amended by
  this record.
- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md).
