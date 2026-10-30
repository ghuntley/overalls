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

## Invariants and verification

- Only CI identities can write to the action cache, and host credentials are
  read-only. Verified by the `buck-remote-cache` machine test.
- The listener is never reachable off the tailnet. Enforced by the module's
  address binding, interface restriction and assertions, and verified by the
  `buck-remote-cache` machine test.
- Outputs of `local_only` actions are never uploaded (`allow_cache_upload =
  False` in the rules).
- **Failure case:** a compromised CI runner could upload poisoned action
  results that hosts then trust. The mitigation is that the CI uploader runs
  only on trunk and pull-request jobs from this repository. The residual risk
  is recorded in the migration review.

## Implementation evidence

M4b (cache only) is implemented; remote-execution workers (M10) are not.

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

Remaining gaps:
- CI does not yet join the tailnet or load the uploader identity. That wiring
  belongs to the M4a CI workflow.
- No native deployment receipt on Panterloons yet.
- Remote-execution workers, the `overalls-cells` platform property and the
  Cachix cells closure are M10.

## Open questions

None.

## Related decisions

- [ADR-0269](0269-buck2-build-system-with-nix-toolchains.md),
  [ADR-0271](0271-buck2-host-self-deployment.md),
  [ADR-0248](0248-fleet-build-scheduling.md),
  [ADR-0188](0188-signed-overalls-cachix-substitution.md) and
  [ADR-0144](0144-nix-builds-exclude-guest-datasets.md).
- Review: [Buck2 migration](../reviews/2026-10-30-buck2-migration.md).
