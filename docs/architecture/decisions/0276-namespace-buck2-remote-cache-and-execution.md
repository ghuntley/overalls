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
5. **What stays local.** As in ADR-0272:
   - `local_only` actions never upload;
   - Nix imports, NixOS assembly, machine tests, test commands and the
     non-hermetic Mila platform builds run locally;
   - non-hermetic CI jobs receive no token;
   - host deployment builds keep `remote_execution = false`.
6. **Remote execution is a developer opt-in.** Remote execution runs on
   Namespace Linux workers whose image carries the `buckCells` closure. The
   image is digest-pinned in `nscr.io`, recorded per `cells_id` in the
   committed `tools/namespace-re-image.lock`, and its digest is a
   `container-image` platform property beside `overalls-cells` on every
   action whenever the lock matches, so all clients share action keys.
   Remote execution itself runs only under
   `OVERALLS_BUCK2_REMOTE_EXECUTION=on`. CI and hosts are cache-only.

   Revised on 2026-10-31, the same day the decision was taken. The
   workspace's 64-vCPU Linux cap is shared by CI runners and the Namespace
   cache, and Namespace documents no maximum worker count, idle timeout or
   scale-to-zero for remote-execution workers. One opt-in build started a
   16x32 worker, which kept running until it was destroyed by hand. That
   queued CI runners behind it, so the user chose to stay inside the cap.
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
  and the source-bundle job of
  [mila-builds.yml](../../../.github/workflows/mila-builds.yml) set
  `NAMESPACE_RBE_TOKEN` from the secret. The NativeLink `buck-re` action and
  its script are removed.

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
- **Fallback without masking.**
  - A genrule that calls `mkdir` from `PATH` failed on the worker and
    succeeded locally.
  - A planted `E0308` in terminald's `main.rs` ran remotely, then locally,
    and the build failed.

Remaining gaps:
- No recorded deployment receipt for the token bundle on the hosts yet.
- No recorded CI run showing cache hits on a rerun yet.
- No Elixir compile has been measured remotely; the Mix rules arrive with
  M6.
- The recorded image predates the `/bin` tool links in
  `tools/namespace-re-image`, so genrules that use `PATH` tools fall back to
  local until the image is rebuilt. A rebuild costs a temporary 8x16
  maintenance instance for `nsc base-image optimize`.
- The cells change often, and a stale lock means no remote execution until
  someone republishes the image.
- No machine test exercises the Namespace path. It needs network access to a
  vendor service, which machine tests do not have.

## Open questions

None.

## Related decisions

- [ADR-0272](0272-nativelink-remote-cache-and-execution.md) (superseded by
  this record).
- [ADR-0271](0271-buck2-host-self-deployment.md): decision 3 is amended by
  this record.
- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md).
