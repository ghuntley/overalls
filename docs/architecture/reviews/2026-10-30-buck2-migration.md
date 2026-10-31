# Buck2 migration: architecture review (2026-10-30)

Scope: the move to Buck2 as the only build system, with Nix supplying
toolchains and pins and assembling NixOS
([ADR-0269](../decisions/0269-buck2-build-system-with-nix-toolchains.md) to
[ADR-0273](../decisions/0273-single-rust-workspace-and-toolchain.md)). It also
covers the pin consolidation that preceded it
([ADR-0267](../decisions/0267-single-dependency-pin-registry.md)) and the M1
foundation change.

## Findings that shaped the design

The design follows nine subsystem deep dives and an adversarial review of the
draft plan:

- **No change-to-test mapping.** About 200 machine checks, including 66 fleet
  variants, run only as a daily batch. Some use import-from-derivation.
- **Duplicated definitions.** The ten application names appear more than
  twenty times, there are six Rust toolchains and about twenty copied source
  filters, and `lilly-host-tools` has four definitions. The service, host and
  port rosters repeat five to ten times.
- **Pins outside the registries.** There were 62 inline hashes and a stale
  `lyraVendor` key. ADR-0267 resolved both.
- **Host builds.** Hosts self-build `nixosConfigurations` from a fresh
  checkout per revision. Removing the flake outputs therefore needs an
  activation gate and an updater change before anything else
  ([ADR-0271](../decisions/0271-buck2-host-self-deployment.md)).
- **Blockers from the adversarial review**, which the plan now addresses:
  - Store-path imports lose runtime references. Assembly wraps them using
    `RuntimeRefs`.
  - A symlinked source tree defeats soundness. Assembly copies a tree of
    declared sources only.
  - `fetchTree` drops lock `follows`. Assembly uses `getFlake`.
  - The cache must exist before the Rust and Elixir moves.
- **Committed build output.** Commit `9a0158861` committed 2868 compiled files
  under `lilly/_build_antithesis`, including dangling symlinks into `deps/`.
  Nothing read them, and their globs broke Buck2 ownership. The M1 change
  removes them and ignores `/_build*/` in `lilly/.gitignore`.

## M1 spike results

| Question | Result |
|---|---|
| Does Buck2 accept a cell root symlinked into `/nix/store` (the prelude)? | Yes. The prelude loads; globs and `uquery owner()` work through it. |
| Do Nix store paths enter action keys? | Yes, when read at load time. `read_root_config` is unavailable during analysis, so `nix_tool` is a macro that reads it and passes an attribute. `-c nix.elixir=…` changes the recursive target hash of `//buck/probes:elixir_version`. |
| Do content target hashes detect edits? | Yes. `--target-hash-file-mode=paths_and_contents --target-hash-modified-paths` changes the hash of the owning filegroup (a scratch target, not kept). |
| Does `getFlake` with `restrict-eval` keep `follows` and refuse undeclared reads? | Yes. `nixos-images.inputs.nixos-stable` equals `nixpkgs`, and `readFile /etc/hostname` fails even inside `tryEval`. |
| Is buck2-change-detector usable? | It is not packaged in nixpkgs. Selection uses Buck2's own target hashes ([ADR-0270](../decisions/0270-graph-driven-machine-test-selection.md)). |
| Do default globs include dotfiles? | No. `nix_owned` adds `**/.*` patterns. Ownership then covers all 7247 tracked files outside `docs/`. |
| Are `.buckconfig` ignores matched anywhere in the tree? | No, they are root-relative. Nested build directories need `**/` patterns. |

## M3 assembly results

- **Shared source of truth.** `lib.assemble` now holds the package set, the
  module set, the host systems, kexec and the machine-test catalog, and the
  flake outputs are views of it. With the same revision, all six host
  systems have the same drvPaths as on trunk.
- **Expected differences.** `image-susan` embeds the flake revision, and Mila
  native Linux takes the whole repository as its source. The pins check and
  the host-enrollment fixture also differ; both embed the flake source.
- **Store context.** `builtins.storePath` works under `restrict-eval`.
  Runtime references passed as JSON strings carry no store context, so
  `importArtifact` restores it with `storePath`. Without that, Nix records
  no references and the closure silently loses runtime dependencies. The
  first probe showed exactly this.
- **Reading the tree.** `restrict-eval` refuses reads of the temporary tree,
  so assembly reads its artifact manifest through the copied flake's
  `outPath`.

- **In-module builds.** Modules no longer build first-party packages. The
  otel-fleet modules, the request-source fixture and the fleet,
  otel-fleet and otel-request-recorder tests take `otelReceiver`. The
  logging and fleet-exporter modules take `observabilityRuntimes`. The
  trace-spool module, its test and the antithesis harness take `traceSpool`.
  - The `-base` host systems are drvPath-identical at a fixed revision.
  - The enrolled hosts differ, as intended. Their own nixos-26.05 builds of
    the receiver, trace spool and observability runtimes (about 900 crate
    derivations) are gone. Only the package set's builds, made with
    buildNixpkgs' Rust, remain, plus the units and `etc` that name them.
    Before this, dungarees and panterloons carried both builds of the
    receiver.
  - Of the 21 antithesis contexts, only `recorder-host-vmm` changes: its VM
    built the spool and recorder with its own nixpkgs.
  - Fluent Bit stays on the system's nixpkgs. buildNixpkgs has 5.1.0, and the
    logging route limits were reviewed against 5.0.x.

## M2 host self-deployment

- **Scope.** M2 changes the updater's build path, the fleet host targets and
  the in-VM updater fixtures.
  - Decisions: [ADR-0271](../decisions/0271-buck2-host-self-deployment.md),
    with [ADR-0259](../decisions/0259-deployment-revision-telemetry.md) and
    [ADR-0144](../decisions/0144-nix-builds-exclude-guest-datasets.md).
  - Boundaries that stay intact: activation, secret custody, migrations and
    health checks.
- **Design.** Each host builds `//fleet/hosts/<host>:deployment` through the
  candidate checkout's own `tools/buck2`.
  - It uses one fixed checkout and one isolation directory, and activates
    exactly the reported bundle.
  - A missing or unstartable build tool fails closed. There is no fallback
    to a flake build.
  - The Nix daemon contract still holds, because the updater restarts buckd
    before each build, so its actions inherit `NIX_REMOTE=daemon`.
- **Accepted deviations.**
  - The target is the `overallsDeployment` bundle rather than `toplevel`. The
    updater reads the descriptor beside the system, and some fixtures pair a
    system with an edited descriptor.
  - In-VM fixtures name candidates with `builtins.storePath`, because
    restrict-eval refuses `path:` inputs.
- **Finding.** `nix_assemble.sh` dropped executable bits when it copied the
  tree. Assembled systems then forked from the flake build (Susan's
  dependency source hash). This is now fixed. For the same tree and revision,
  `:deployment` equals `lib.assemble`'s `overallsDeployment`.
- **Finding.** The root package glob owned `.buck-cells.gcroot`, which is
  tools/buck2's link to the cells store path. `nix_assemble`'s `cp -RL` then
  copied the whole Buck2 closure into every assembled tree, and the updater
  test VM ran out of disk after a few builds. M3's 7f4a33af7 makes `.buckconfig`
  ignore the wrapper's state files and `.buckconfig.local`.
- **Finding.** buckd's `notify` watcher followed buck-out result links into
  the system closure, which took about 100 s per daemon start on a 9p store.
  The updater writes a `.buckconfig.local` that selects `fs_hash_crawler`, and
  it sets `OVERALLS_GCROOT_DIR` to its own root-owned state.
- **Gaps.**
  - Per-host parameters still use fleet-wide `lib.assemble` defaults.
  - The operator CLI still builds `nixosConfigurations`.
  - There is no NativeLink cache yet.
  - The root `OWNED_PACKAGES` lists host packages by hand, which repeats the
    inventory.
  - The activation gate remains open.
- **Machine tests.**
  - Pass: auto-update, credential-rotation, host-conversion and
    audi-relocation-fleet, rebased on 7f4a33af7. auto-update was rerun on the
    pushed base.
  - Pass: host-enrollment, through both the nix check and `tools/buck2 test`.
    auto-update, credential-rotation, host-enrollment and
    customer-isolation-fleet were rerun through `tools/buck2 test` rebased
    on e5fe2ffde. The enrolled host's published updates build
    through `//fleet/hosts/fixture-enrollment:deployment`.
  - Pass: the auto-update-custody, auto-update-compatibility and
    host-planning evaluation checks.
  - customer-isolation-fleet failed once and then passed three times, the
    last time rebased on e5fe2ffde. The trunk baseline on the same base passed.
    - The failure: after "Lilly daemon death preserves every independently
      supervised VMM" passed, l2's restarted Lilly logged
      `lilly.control_request_refused` and `control_exchange_failed`
      (`http_error`). `fleet-op` start in "Customer egress denial survives
      guest stop/start" then got `vm.lifecycle_refused` `host_unavailable`
      until its 180 s retry expired.
    - This is recorded as intermittent. M2 changes nothing in Lilly,
      Marshall, the control protocol or the units it restarts. Every updater
      attempt and Buck2 daemon had finished before that subtest ran.
- **Finding.** New Buck2 packages remove their files from the parent's
  `srcs`. `//nix/platform` and `//fleet/hosts/<host>` had to be added to
  `NIX_INPUTS`, or every machine-test assembly would miss
  `nix/platform/hosts/profile.nix`. `owned_set` also placed toolchains-cell
  files at the tree root until it learned the cell prefix.
- **Finding.** `builtins.storePath` names a store path but does not admit
  reads under restrict-eval. Offline fixtures therefore expose the sources
  they read through lookup-path entries.
- **Evaluation sweep.** `nix_assemble` gained a `[drv]` sub-target. It copies
  the same declared tree, evaluates under the same restrict-eval options and
  writes only the derivation path. It builds nothing beyond
  import-from-derivation and roots nothing (contract
  `nix-assemble-drv-evaluation`).
  - Every assembly in
    `attrfilter(labels, machine_test_assembly, //...)` (205 targets) was
    evaluated in one `tools/buck2 build -j 24 --keep-going` run. It took 844 s
    of wall time while other builds shared the machine, and Inception's
    checkout was the longest single evaluation. This is cheap enough for a CI
    job.
  - After rebasing onto e5fe2ffde, a second run took 621 s. It covered all
    205 assemblies, the nine `//fleet/hosts/<host>` targets and
    `//nix/platform:kexec`, and it builds the Rust leaves those targets
    import. Every target evaluated.
  - Six assemblies failed on trunk, all from cross-suite files that support
    modules read: `support/zfs-node.nix` reads
    `machines/zfs-lifecycle/probe.exs`, and `support/native-role-node.nix`
    reads `machines/service-roles/seal.py`. The affected assemblies were
    native-zfs, source-export, export-endpoint, both backup-cleanup variants
    and application-metrics. Trunk d9e423ee4 declares both suites in
    `NIX_INPUTS`, after which all six evaluate. Trunk 22d1f7ab4 separately
    restored host-enrollment's `observabilityRuntimes` stand-in, which
    c170ebcb2 had broken.
- **Finding.** The updater fixture first copied `toolchains/BUCK` and
  `nix.bzl` by name. After M5 made `toolchains/BUCK` load `rust.bzl`, every
  in-VM Buck2 build failed during loading. The fixture now copies the whole
  toolchains cell and links an empty `rust//` cell, because no fixture target
  loads Rust.

## Risks

- **Hosts get heavier.** They need buck2, the cells closure and the cache. The
  local fallback is required.
- **Broad selection until M11.** Until each module has its own target, a
  module change selects about 60 suites.
- **Poisoned cache entries.** A compromised CI uploader could poison the
  action cache that hosts read
  ([ADR-0272](../decisions/0272-nativelink-remote-cache-and-execution.md)).
  The mitigations are: hosts are read-only, uploads come only from this
  repository's jobs, and Nix assembly and machine tests always run locally.
- **buck2 snapshot cadence.** Every bump changes every toolchain hash, which
  means a full CI run.

## Verification performed

- Built `buckCells`. Ran `tools/buck2 build //buck/probes:elixir_version`, which
  printed Elixir 1.20.4.
- Built `//:package-tool-lyra` through the bootstrap rule.
- `tools/buck2 bxl //buck/bxl/ownership.bxl:main -- --files $(git ls-files)`
  passed over 7247 files. It had failed with 83 dotfiles before `nix_owned`
  matched them.
- `elixir scripts/check_adrs.exs`.

No NixOS machine test covers M1, because it changes no deployed module. Host
and selection coverage is planned for M2 and M4a.

## M7: Go, JavaScript, Python and script checks

This milestone adds Buck2 rules within ADR-0269. It makes no new decision.

**Pinned inputs.** Third-party inputs stay in Nix: the gh and git-lfs sources
and vendored modules, the marvin `importNpmLock` tree, and one Python closure.
`buckCells` exposes their store paths through `[nix]`, so each path is part
of the action key.

**Parity.** On 2026-10-30:

- The Buck2 gh and git-lfs builds for four platforms, and the release
  manifest, were byte-identical to `.#tool-github-managed`. Matching needed
  stdenv's `strip -S -p`, and building outside the checkout so Go does not
  stamp VCS data.
- `//marvin:marvin` was byte-identical to the Nix marvin package.
- `//:py-static` reported the same findings as the prek Python hooks.
- `//mila:journey-fixture` runs the same store path as
  `.#mila-journey-fixture`.

**Findings:**

- The flake leaves cannot be deleted yet. Guest images and the Marshall and
  Ziggy modules read `githubTools` and `marvin` from the Nix package set. M3
  moves them to Buck2 artifacts.
- `nix-compact-*` and `fleet-builds-configuration` evaluate NixOS, so they
  need `nix_assemble`. They are not pure scripts.
- Buck2 globs include untracked files, but prek and Nix see only tracked ones.
  This is stricter, but a dirty tree can fail `py-static` where prek passes.
- A local action's cwd is the project root, so the checks read sources in
  place. Remote execution sees only declared inputs, so every check declares
  all of its files.

**Verification:**

- `tools/buck2 build` and `test` of every new target.
- Planted-failure runs for ruff, ty, the conflict-marker check and the
  package-input-lock check.
- The `overalls-install-ps1` Nix check with the shared script.
- The ownership BXL, `check_pins`, `check_adrs` and the contract format and
  coverage checks.

No NixOS machine test covers this change, because no deployed module changes.

## M4a: machine tests as targets, selection and CI

Scope: `nixos_machine_test` ([buck/nixos.bzl](../../../buck/nixos.bzl)), the
generated suite `BUCK` files (each test built through `nix_assemble`), `tools/affected`, `ci.yml`, the adapted daily
run and the M1 follow-ups. Architecture impact: implements
[ADR-0270](../decisions/0270-graph-driven-machine-test-selection.md)
(implementation stays partial) and adds evidence to
[ADR-0269](../decisions/0269-buck2-build-system-with-nix-toolchains.md). No
deployed module changes.

Findings:

- **Hash flags.** `--target-hash-modified-paths` only applies in `paths_only`
  mode, and hashes are not recursive by default. Without
  `--target-hash-recursive=true` a toolchain path change left
  `//buck/probes:elixir_version`'s hash unchanged. The selector hashes full
  contents recursively; a cold daemon takes about a second.
- **Rule files are invisible to target hashes,** so a `buck/*.bzl` change
  selects everything.
- **Fleet scenarios cannot be read from the Nix source alone.** The variant
  conditionals in `fleet/default.nix` choose scenario files. Evaluating each
  variant's `config.testScript` (about 15 s each, no build) and matching the
  scenarios' distinctive lines gives the per-variant `srcs`; each test run
  re-checks it.
- **`catalog.nix`, `ci.nix` and `select-checks.sh` cannot go yet.** The flake's
  checks come from the catalog, and `publish-cache.yml` (owned by another
  stream) selects its builds with `select-checks.sh build`.
- **Docs.** Repository-wide targets read `docs/`: the whole-tree flake
  checks and assembly probes, and the per-file conflict-marker and Python
  checks. A docs-only change selects those and no machine test.

Verification:

- `tools/buck2 test` of `//nix/verification/tests/machines/sysctl:sysctl` and
  `//nix/verification/tests/machines/nix-ld:nix-ld` booted their VMs and passed.
  A deliberately wrong `nested_kvm` made the test command fail.
- `//buck:toolchain_hash`, `//buck:bootstrap_attrs_fresh`,
  `//buck:machine_tests_fresh` and `//buck:affected_fixtures` pass.
- Ownership over every tracked file, `elixir scripts/check_adrs.exs`, contract
  format and coverage, and `prek run --all-files`.

- **Assembly backing.** Each machine test builds `lib.assemble {}.checks.<name>`
  through `nix_assemble` (M3) over a copy of its declared inputs only, so a
  test that reads an undeclared file fails to evaluate. `sysctl` built that way
  produced the same store path as the flake check.

Remaining risks: until M11 a change anywhere under `nix/` selects every machine
test, and most suites have not yet run through their declared-only tree, so an
undeclared read surfaces as a first-run failure.

## M4b: NativeLink cache

Scope: the CAS and action cache on Panterloons, client configuration and
credentials ([ADR-0272](../decisions/0272-nativelink-remote-cache-and-execution.md)).
Remote-execution workers are M10.

- **No per-identity authorisation.** NativeLink checks a client certificate
  against a CA but cannot authorise by subject. The write split is therefore
  structural: two listeners in one process, each trusting one CA. The read
  listener's action cache is `read_only`. Its CAS is a `fast_slow` store with
  a `noop` fast tier and a `read_only` reference to the shared CAS, so reads
  reach the shared blobs and host uploads are drained. A host blob upload
  therefore returns success but persists nothing. The test asserts this; it
  is weaker than a refusal, but content-addressed blobs cannot poison
  anything, and action-cache writes are refused.
- **Public reachability.** The fleet firewall admits reviewed public fleet
  sources to every port, and Linux accepts a packet for any local address on
  any interface. A firewall-only design would therefore leave the cache
  reachable from fleet peers' public addresses. The module binds the tailnet
  address with `freebind` and restricts the unit to loopback and
  `tailscale0`. The machine test routes the tailnet address through the
  public interface and shows that sshd answers there but the cache does not.
- **Credentials.** There are two CAs, as in ADR-0248, and both private keys
  were discarded after issuance. The CI uploader identity is held in a
  recovery-only document until the CI workflow (M4a) loads it.
- **Licence.** NativeLink v0.8 and later are FSL-1.1-ALv2. The fleet's
  internal use is a permitted purpose. v0.7.10, the last Apache-2.0 release,
  lacks the listener `freebind` option that the tailnet-only binding needs.
- **Host fallback.** Root's `~/.buckconfig.d` file exists only while the
  decrypted identity does, so a missing credential means local execution.
  Buck2 ignores symlinks and includes in that directory, which the first
  machine-test run exposed; the unit installs a regular copy. Only root reads
  it, so other users' builds on a host are unaffected. A cache that cannot be
  reached is not fatal either: buck2 reports the RE error and builds locally.

Residual risks: a compromised CI runner can still poison the action cache
(see Risks). The cache has no deployment receipt on Panterloons yet.

Verification performed for M4b:
- The `buck-remote-cache` machine test passed, through `nix build` and
  through `tools/buck2 test`. Its suite declares `//buck:srcs` as an extra
  input, because it tests the real `buck/platforms.bzl`.
- The Panterloons and Dungarees toplevels built, and so did the
  `fleet-roster` and `fleet-builds-configuration` checks.
- Before writing the module, a local NativeLink run checked the same
  configuration with grpcurl and buck2.
- `check_pins`, `check_adrs`, the contract format and coverage checks,
  `prek run --all-files`, `//buck/...` tests and the ownership BXL.
- `nix run .#secrets -- check` reports drift only for `fleet-tailscale`,
  which trunk already had before this change.

## M10: remote-execution workers and host cache reads

Scope: the NativeLink scheduler on Panterloons, workers on Panterloons and
Dungarees, client and CI configuration, and the host updater reading the cache
([ADR-0272](../decisions/0272-nativelink-remote-cache-and-execution.md),
[ADR-0271](../decisions/0271-buck2-host-self-deployment.md) decision 3).

- **Updater cache reads.** The M2 updater runs Buck2 with a private `HOME`,
  so the M4b root `~/.buckconfig.d` file never reached it. Rather than a second
  copy of that file, the updater receives the cache settings as typed
  configuration and writes the section into the checkout's
  `.buckconfig.local` per build. It probes the listener first (5 s): Buck2
  already degrades a failed action-cache query to a miss, but a blackholed
  tailnet would otherwise cost a connect timeout. The same file always
  refuses uploads and remote execution, whatever the candidate's
  `.buckconfig` says, and the read listener has neither write access nor an
  execution service.
- **Write split with execution.** NativeLink still cannot authorise per
  certificate, so execution adds listeners, not identities on existing ones:
  CI executes on its upload listener; developers get an execute listener whose
  action cache is read-only (results come only from workers); workers get
  their own listener for the worker API and result uploads. Each trusts one
  new or existing CA. Two new CAs were issued and their keys discarded; the
  worker identities are new per-host documents because the M4b documents
  cannot be re-encrypted without a recovery identity.
- **Fallback.** The OSS Buck2 RE client gets no queue estimate from
  NativeLink, so `remote_execution_queue_time_threshold_s` would never fire.
  Instead the scheduler fails an unmatched action (`unsatisfiable_action_timeout_s`
  and `no_worker_action_timeout_s`, 15 s), and the platform is limited hybrid
  with fallbacks, so Buck2 reruns it locally. Full hybrid (racing) would also
  fall back but doubles every action's work. An unreachable scheduler is an
  infrastructure error and falls back at once.
- **Cells id instead of the wrapper key.** The plan put the wrapper's key on
  actions. That key hashes the wrapper's input files in a locale-dependent
  order, and a worker cannot recompute it without the source. `cells_id` is a
  hash of every toolchain path, the rust cell and buck2, written into the
  cells' own `toolchains.buckconfig`, so clients and workers read the same
  value. It is also on cache-only actions, so hosts and executing clients
  share digests. Adding it changed every action digest once.
- **Which cells a worker holds.** Workers advertise one id (NativeLink keeps
  one value per property): their host updater's deployed cells, realised from
  Cachix by the updater's own `tools/buck2`. Clients on another cells
  revision fall back after the timeout. Holding several revisions would need a
  cells fetch keyed by revision; it was left out.
- **Worker isolation.** The worker's start script unmounts every Lilly pool
  inside its private mount namespace before dropping to an unprivileged user,
  as nix-daemon does (ADR-0144); `InaccessiblePaths` alone would leave copies
  of guest dataset mounts pinned underneath. It makes its namespace
  `rprivate` first: the machine test showed a dataset mounted after start
  still propagated in through the slave mount systemd sets up. The unit
  reaches only loopback and the scheduler, has no devices, and cannot see the
  secrets runtime, the SSH host identity, the updater's state or any Lilly
  control, socket or Firecracker directory.
- **Capacity.** Lilly reports capacity to Marshall every few seconds and
  guests must not be starved, so the worker cgroup has hard caps besides low
  weights: `CPUQuota` 100% per in-flight task (48 of 96 threads in the
  fleet), `MemoryHigh` 20% and `MemoryMax` 25% of RAM, no swap, `TasksMax`
  8192, and `OOMScoreAdjust` 1000 so it dies first. I/O has only weight
  (`IOWeight` 20); a bandwidth cap needs per-device numbers.
- **Who can submit actions.** Execution needs a client certificate from the
  uploader CA (50072: CI and the recovery uploader) or the executor CA
  (50073: recovery-only). The worker CA (50074) admits only workers. Hosts
  (50071) cannot execute. All listeners bind only the tailnet address. CI
  uses its identity only when the repository variable `BUCK_RE` is
  `enabled`, both secrets exist and the run is a trunk push or dispatch in
  this repository; ci.yml has no pull-request trigger, and the step
  continues on error so the `ci` gate never waits on NativeLink.

Residual risks:
- Closed by M10b: actions ran as the worker user and could read the worker
  identity, and so write the action cache through the worker listener. They
  now run through a sandbox as `nativelink-action` in their own namespaces,
  so the identity reaches only the worker process. The worker keeps
  `CAP_SETUID`, `CAP_SETGID` and `CAP_SYS_ADMIN` in its bounding set for the
  sandbox's file capabilities and runs without `no_new_privs`; a compromised
  NativeLink worker process could still write the cache. Executing remotely
  stays as trusted as uploading.
- A compromised CI runner or executor could poison the action cache (as in
  M4b); hosts trust it for updates.
- Remote actions share a host with Lilly guests. The caps above bound the
  impact, but Lilly's admission was not changed to account for the
  worker's memory cap, and I/O is weighted, not capped.
- The tailnet policy for `tag:buck-re-ci` is the operator's; until it is
  set, mTLS alone separates CI from other listeners.

Verification performed for M10 (2026-10-30, through `tools/buck2 test` and the
repository gates):
- `buck-remote-execution` passed all 12 subtests, including the sandbox and
  cgroup-cap subtest, guest-dataset and Lilly-state hiding, the unmatched-cells
  fallback (14.9 s) and the stopped-scheduler fallback (71.0 s).
- `buck-remote-cache` (with the updater cached, unreachable,
  identity-missing and identity-rejected paths, the last proving the cache
  reads fail open), `auto-update`, `credential-rotation` and
  `host-enrollment` passed. The updater also retries once without the cache
  when an enabled build fails (unit-tested).
- The rollout is single-host: Dungarees' worker stays disabled in a held
  follow-up until Panterloons' worker has run healthy.
- `check-auto-update-compatibility` and `check-auto-update-custody` passed;
  Panterloons and Dungarees `:deployment[drv]` evaluate.
- `tools/precommit --all`, `prek run --all-files`, the ADR check, contract
  format and coverage, and `buck/machine_tests.py check` passed.

Not verified: a deployment on Panterloons or Dungarees, CI with the secrets
set, the tailnet policy, and precommit timings with remote execution.

### M10b: worker identity reaches only the worker

The M10 residual risk was a security gap: an executed action could read the
worker's identity and use it to write the cache hosts read. NativeLink's own
action namespaces map the action to the worker's uid, so they hide neither
the identity file nor the worker's store, and its `entrypoint` runs without
privileges. M10b therefore adds an entrypoint with three file capabilities
that builds the namespaces itself and drops to a separate action user (see
ADR-0272 evidence). Alternatives considered: a TLS-terminating proxy holding
the identity (actions could still use the proxy over loopback), and the
worker keeping `CAP_SETUID` itself (a NativeLink compromise could then
become any user). NativeLink cannot tie action-cache writes to registered
workers, so the bound is the worker CA, whose only leaves are the two
worker identities.

Verification: `buck-remote-execution` passed all 14 subtests on 2026-10-30,
including "remote actions cannot reach the worker identity" and "a forged
worker cannot register or record results".

### M10c: the sandbox's privileges (accepted risk)

**What the worker holds.** `nativelink-worker` runs with an empty
effective, permitted, inheritable and ambient set and a bounding set of
exactly `CAP_SETUID`, `CAP_SETGID`, `CAP_SETPCAP` and `CAP_SYS_ADMIN`, without
`no_new_privs`. The only file it can gain them from is the sandbox,
`/run/nativelink-worker-exec/action-sandbox`: a copy the start script puts on
a tmpfs that exists only in the unit's mount namespace, owned
`root:nativelink-worker`, mode 0750, with
`cap_setuid,cap_setgid,cap_setpcap,cap_sys_admin+ep`. `/run/wrappers` is
hidden in that namespace, so no setuid binary is reachable, and the Nix
store carries no file capabilities. The sandbox accepts only the worker uid
as caller and only switches to `nativelink-action`; before it runs the
action it empties every capability set, including the bounding set (hence
`CAP_SETPCAP`), sets `no_new_privs` and closes descriptors.

**Why.** NativeLink runs an action by executing its `entrypoint` as a child
of the worker, reads its stdout and stderr through pipes, kills it by
process group and samples its resources by process group. A different user
and fresh namespaces therefore have to be set up by something the worker
itself executes, which needs these capabilities at exec time; `no_new_privs`
would discard them.

**The risk accepted.** A compromised NativeLink worker process (not an
action) could run the sandbox with arguments of its choosing. That gives it
what the sandbox does: a command as `nativelink-action` in fresh namespaces,
less than the worker itself already has, since the worker holds the identity
and can write the cache. It cannot use the bounding set any other way
without a file that grants capabilities, and the only one is the sandbox. A
memory-safety bug in the sandbox, which runs with `CAP_SYS_ADMIN` until it
drops, would be the residual path; it is about 300 lines of C with `-Wall -Wextra
-Werror`, parses no input beyond its argument vector and working directory,
and checks the working directory against the work root.

**Alternative: a root-owned launcher.** A separate root service (socket
activated, or `systemd-run` from the worker) would start each action, and the
worker would keep an empty bounding set and `no_new_privs`. It was not
chosen, because it is neither cheaper nor clearly safer:
- NativeLink's entrypoint would become a client that passes stdin, stdout
  and stderr over the socket (`SCM_RIGHTS`), relays signals and the exit
  status, and stands in for the real process group. NativeLink's kill and
  resource sampling act on the client's process group, so the launched
  action would escape both unless the launcher mirrored them.
- The launcher runs as root with every capability it needs permanently and
  parses requests from the worker over a socket: a larger, always-running
  privileged surface than a sandbox that execs once per action and drops.
- `systemd-run` would need the worker to reach the system manager over
  D-Bus with polkit rights to start transient units, which is broader than
  starting one fixed program.
If NativeLink later supports running actions as another user itself, the
file capabilities can go.

Verification (M10c): the identity subtest now also asserts, from inside the
action, that `CapInh`, `CapPrm`, `CapEff`, `CapBnd` and `CapAmb` are all zero
and `NoNewPrivs` is 1, and that neither the sandbox's path nor
`/proc/1/exe` can be opened or executed.

## M8: precommit on Buck2 BXL

This milestone implements the precommit part of ADR-0269 and shares
ADR-0270's ownership graph. It makes no new decision.

**Design.** `tools/precommit` computes the changed and deleted files (staged,
`--base REV` or `--all`) and runs `buck/bxl/precommit.bxl`. The BXL treats the
`precommit` label as an aspect: every labelled target is a candidate, a
`PrecommitInfo` provider says which paths each reads and which sub-targets
check a single file, and one `ctx.build` builds the selection. A build-graph or
toolchain change selects every check, and unchanged ones are cache hits.
`--fix` copies the `[fix/<path>]` outputs over the sources; it is the only mode
that writes files.

**Check to target mapping.** Every check the prek hooks ran before M8 now runs
through Buck2 when its inputs change:

| Check before M8 | Where it ran | Buck2 target precommit builds |
| --- | --- | --- |
| conflict markers | prek, pre-commit and pre-merge-commit, all files | `//:conflict-markers[<path>]` per changed file |
| ruff format, ruff check | prek, changed `.py` | `//:py-static[ruff/<path>]` |
| ty | prek, any `.py` change | `//:py-static[ty]` |
| pins | prek, `.nix` or registry change | `//:pins` |
| rust-lints | prek, Rust or lint-policy change | `//:rust-lints` |
| logging (10 hooks) | prek, application `lib`/`config`/`mix.exs` | `//:logging-<app>` |
| ADR check | CI gates, `mix architecture.check` ×11 | `//:adrs` (docs/architecture, any deletion) |
| contract format and coverage | CI gates, `mix contracts.check` ×11 | `//:contracts[contracts/<path>]`; whole for `CONTRACTS` or checker changes |
| contract checker tests | CI gates, `mix contracts.check` ×11 | `//:contracts-tests` |
| toolchain versions | `mix toolchain.check` ×11 | `//:toolchain-versions` (cells Elixir/OTP vs `.tool-versions`) |
| package-input-lock | flake check | `//:package-input-lock` |
| overalls-install.ps1 | flake check | `//nix:overalls-install-ps1` |

Not mapped yet, so it stays where it is: each project's `mix precommit`
(compile, format, tests, Covenant, Dialyzer, gettext and Marshall's extra
gates) and CI's precommit matrix, until M6 provides Mix sub-targets; rustfmt
and clippy with M5. `mix precommit` is unchanged, so its repository-wide steps
still run 11 times in CI.

**Entry points.** devenv gains a `precommit` command. The 16 prek hooks become
one `precommit` hook at pre-commit and pre-merge-commit. It receives the
staged files, so `prek run --all-files` still runs every check. When
`tools/buck2 server` fails, the hook runs the pre-M8 hook scripts directly
with the pinned tools devenv passes. It fails on their findings, and it names
the checks it skipped. `ci.yml` gains a `precommit` job that runs
`tools/precommit` over the range `tools/affected` selected, and the `ci` job
requires it. The `publish-cache.yml` gates job still runs
`prek run --all-files`, which now goes through Buck2, plus its own ADR and
contract steps; removing that duplication is left to that workflow's owner.

**Timings** (2026-10-30, one workstation, local cache only; NativeLink is
M4b/M10):

| Run | Before (prek) | Buck2 precommit |
| --- | --- | --- |
| no-op (nothing staged) | — | 53 ms |
| one `.py` file, warm | 5.2–5.3 s | 1.2–1.3 s (ruff, ty, markers, contracts) |
| one Markdown file, warm | 4.5 s | 0.6–0.7 s |
| one Marshall `.ex`, warm | 5.5 s | 1.8 s (adds `//:logging-marshall`) |
| same file again (cache hit) | 5.2 s | 23–45 ms |
| cold daemon and cache, no files | — | 1.6 s |
| cold daemon and cache, one `.py` | — | 2.7 s |
| every check (`--all` / `prek run --all-files`), cold | 15 s (prek hooks only) | 20 s (also ADRs, contracts and logging) |
| every check, warm | 15 s | 0.03–0.3 s |
| repository-wide steps of one `mix precommit` | ~21.8 s (ADRs 1.0, contracts 12.8, checker tests 6.1, logging 1.4, toolchain 0.4) ×11 projects | once, only when inputs change |

The contract check was the largest cost: 12.8 s for the whole repository
against 0.6–0.8 s for one file. `check_contracts.mjs files <path>` checks a
file with its ancestor `CONTRACTS`, which is all that cc-check's uniqueness
rules read for a source file, so per-file results agree with the whole run.

**Findings:**

- Bootstrap flake checks and machine tests carry the `check` label. Precommit
  therefore selects on its own `precommit` label.
- A Buck2 daemon started from a Git hook inherits `GIT_INDEX_FILE`. The wrapper
  and `repo_check` unset `GIT_*` before git runs inside an action.
- BXL `cli_args.bool` needs a value, so the BXL takes `--mode` and `--scope`
  enums and the wrapper keeps the flag interface.
- Failure output repeats each failed action's command line and log. It is
  verbose, but it names the failing check and file.

**Verification:**

- `--mode plan` and real runs for (a) no changes, (b) a Python edit, (c) a
  `docs/architecture` edit, (d) a planted conflict marker and (e) a lock
  change. Each selected exactly the expected checks. A planted unknown ADR
  reference, ruff violation, conflict marker and `nix-compact` lock mismatch
  each failed only their own check.
- Through the installed hook, `git commit` refused a conflict marker, an
  unformatted `.py`, a ty `invalid-return-type` and a direct `Logger.info` in
  Marshall, both through Buck2 and with `OVERALLS_PRECOMMIT_DIRECT=1`.
  `prek run --hook-stage pre-merge-commit` refused a marker in both modes.
- `tools/precommit --fix` on a file with an unused import and unformatted
  code removed the import, formatted it and then passed. A first version
  printed the fix output with `format()`, which renders an ensured artifact as
  its description rather than its path, and truncated the file. The wrapper
  now refuses a missing fix output.
- `tools/precommit --base origin/trunk`, `--all` and `prek run --all-files`
  passed; the ownership BXL, `elixir
  scripts/check_adrs.exs`, `//:contracts` (format and coverage) and
  `//:contracts-tests` passed.

No NixOS machine test covers this change, because no deployed module changes.

## M5: Rust on Buck2

This milestone implements ADR-0273 decisions 2 and 3 for the first leaves and
the Rust part of ADR-0269. It makes no new decision.

**One toolchain.** `nix/rust-toolchain.nix` builds the 1.97.1 rust-overlay
toolchain from the flake's `rust-overlay` input and is the only Rust release
definition. devenv, Lyra's and terminald's cross and native builds and Buck2
use it. Two findings shaped it:
- With `rust-src` installed, rustc maps std's `/rustc/<hash>` panic paths to
  the toolchain's store path, and every `allowedReferences = [ ]` cross
  build failed. The toolchain omits `rust-src`, and editors read
  `RUST_SRC_PATH`.
- rust-overlay's illumos standard library links the guest's libc family;
  `autoPatchelf` fails on it, so it is added with those libraries ignored.

Every first-party Nix Rust leaf then moved to it (rustc 1.99 to 1.97.1):
`cargo-workspace.nix` exports `rustPlatform`, `rustTools` and
`buildStaticMusl`. `pkgsStatic.makeRustPlatform` over the overlay toolchain
built build scripts that crashed with SIGSEGV, so `buildStaticMusl` links
terminald and the editor broker as static-pie with rustc's self-contained
musl CRT and `rust-lld`, still with the `release` profile they really used
(873 KB and 1.31 MB, from 955 KB and 1.39 MB), and the broker's tests run in
its check phase. The leaves now declare their profile with `buildType`; the
exported `buildRustPackage` refuses the ignored `cargoBuildType` (the T2
profile regression below).
The host derivations changed on purpose (dungarees `pf1nr19` to `5zjw023`,
panterloons `wxq0yzm` to `1g8i65r`, salopettes `w6xh09q` to `s1619s5`); each
diff is the Rust leaves, their dependents (Lilly's release, host tools, guest
images carrying terminald or the receiver, their units) and the toolchain's
own derivations. The five parity tests pass against the 1.97.1 Nix builds.
NativeLink, underclass, Marshall's Cedar NIF and lints and libhegel stay on
nixpkgs Rust until M6.

**Third-party crates.** reindeer cannot vendor from a lock it does not
resolve, and committing its output would add a second pin. `nix/buck/rust.nix`
therefore generates the `rust//` cell in Nix: a pseudo-package lists every
member's direct dependencies at the exact root-lock versions (a versioned
alias where two versions are used), Cargo prunes a copy of the root lock, a
subset check refuses any version the root lock did not resolve, and `reindeer
buckify` runs over the `importCargoLock` sources. `cargo metadata` runs over
the manifests plus empty stubs of every target-discovery file, so the cell
depends on Rust file names but not their contents. Build scripts run by
default; libc needs one committed fixup (a macro-declared module). Cfg
conditions of first-party dependencies are evaluated against the same six
reindeer platforms.

**Rules.** `toolchains//:rust` takes rustc, rustdoc and clippy-driver from the
store path, with the root `clippy.toml`. `toolchains//:cxx` links with the Nix
cc wrapper under `env -i`: a Buck2 daemon started in a dev shell otherwise
linked that shell's `NIX_LDFLAGS` rpath into binaries. `overalls_rust_crate`
turns a member's row of `rust//:workspace.bzl` into prelude library, binary
and test targets with the workspace lints, the Cargo profile the Nix build
selects, native library directories and test environments, plus the
`<pkg>-clippy` and `<pkg>-rustfmt` precommit checks. A planted `unwrap()` and
a planted format error each failed their check.

**Leaf swaps.** A swapped leaf is a bundle in the consumer's layout, imported
with `nix_store_import` and its rpath store paths as runtime references, and
read by Nix through `swapLeaf`, which keeps the Nix build's `meta` (the
trace-spool module's `lib.getExe` needs `mainProgram`) and exposes it as
`passthru.nixBuild`. The request-recorder fixtures patch and rebuild the
receiver's source, so they derive from `nixBuild`: an `overrideAttrs` on the
import only changes its copy step, which the first swapped run showed as a
missing `request_fixture`. `ASSEMBLY_ARTIFACTS`
(`buck/artifacts.bzl`, merging `RUST_ARTIFACTS` and M6's `MIX_ARTIFACTS`)
feeds every machine test, and `nix/domains/artifacts/default.nix` refuses an
artifact name it does not consume. Host `:deployment` targets read the same
dict since M2 (7ccb4f72a), so hosts run these Buck2 builds; the flake keeps
the Nix builds as a fallback until M11 deletes them.
`rust_leaf_parity_test` (label `heavy`) builds the Nix side and fails when the
two builds name different executables, when an executable's interpreter or
RUNPATH differs, when it needs a library the Nix
build does not, or when any store path in its rpath or bytes is outside the
closure of the import's declared references. Fewer NEEDED entries are allowed:
Cargo's links also list `ld-linux-x86-64.so.2` (PT_INTERP loads it either way),
and the Nix receiver and spool carried an unused `libm.so.6` under rustc 1.99.
It also fails on a `.debug_*` section the Nix build strips: the first
Buck2 receiver binaries were five times larger because the prelude does not
apply Cargo's implicit `strip = "debuginfo"` for `release`, which
`buck/rust.bzl` now passes. Byte identity is not expected: the drivers
differ.

| Leaf | Buck2 import | Parity and tests |
| --- | --- | --- |
| Lilly host helpers (13 executables) | `//lilly:host-helpers-import` | `//lilly:host-helpers-parity` passes; the helpers' unit and integration test targets pass |
| Enrico git owner | `//enrico:git-owner-import` | `//enrico:git-owner-parity` passes; unit and history tests pass serially |
| Guest telemetry receiver (6) | `//nix:otel-guest-receiver-import` | `//nix:otel-guest-receiver-parity` passes |
| observability-runtimes (2) | `//nix:observability-runtimes-import` | `//nix:observability-runtimes-parity` passes |
| Trace spool | `//elixir:trace-spool-import` | `//elixir:trace-spool-parity` passes |
| terminald (static musl) | `//nix:terminald-import` | `//nix:terminald-parity` passes; 61 binary tests pass |
| Editor broker (static musl) | `//nix:vscode-web-broker-import` | `//nix:vscode-web-broker-parity` passes; binary tests pass |

Parity coverage is enforced rather than conventional:
`//buck/bxl/rust_parity_coverage.bxl:main`, which `tools/precommit` runs on
every invocation, queries every `rust_leaf_parity_test` and fails when a
`RUST_ARTIFACTS` import is not the `buck` attribute of one. It passes for the
seven entries above; adding an entry without a test fails with the entry
named.

**Static musl leaves.** `rust_musl_binary` applies a transition that adds
`toolchains//:musl`; the Rust toolchain's target triple and flags and the C
toolchain's linker select on it, so the binary and its third-party crates
build for x86_64-unknown-linux-musl and link with rust-lld (the first build
was 593,960 bytes, the size of the Nix build). Proc macros and build scripts
are exec-configured and stay on gnu. The imports declare no runtime
references; parity checks that they have no interpreter, NEEDED entry or
RUNPATH, as the Nix builds do. Two findings came from running terminald's
tests: the rule had no target for a binary's own `#[cfg(test)]` modules, so
bin-only crates ran none of them (24 `<bin>-bin-unittest` targets now exist),
and its PTY tests start a login shell, which outside the build sandbox read
the host's `/etc/profile` and grew one session's ring past its budget. The
tests now use `[nix] test_login_shell`, bash with `--noprofile --norc`.

Machine tests through Buck2 with all five swaps, each assembly using the
imports (different store paths from the Nix leaves): vm-watch, image-copy,
enrico-service, otel-fleet, source-export, export-endpoint, trace-spool-native
(with independent trace custody) and both otel-request-recorder variants
pass. fleet fails only "capacity races spend pending startup headroom only
once", which current trunk also fails without
any swap. The unswapped flake derivation fails it identically: the race host
has 16.895 GB free after its first placement (16.713 GB on the older trunk
where it passed), so the "fewer than three disk slots" term is false. The
race's slot margin is under 180 MB; overalls-1f is deriving it from the
actual pool.
The first swapped run found two consumer mismatches, fixed above: the spool's
`lib.getExe` lost `mainProgram`, and the recorder fixtures overrode the
import. It also found that `support/zfs-node.nix` reads
`zfs-lifecycle/probe.exs` without declaring it, so every ZFS-node assembly
failed to evaluate; d9e423ee4 declared it in `NIX_INPUTS`.

**Profile regression (T2), found through the helper swap.** Full machine run
41094831662 failed real guest launches in account-lifecycle,
audi-relocation-fleet, coding-clis-nixos-fleet and artifact-agent-publish
with the Buck2 helpers, and fbb29d9fe held the swap back. The A/B showed the
same files, modes, interpreter, NEEDED and RUNPATH, the same rustix and libc
features and build-script cfgs, and no compile-time environment in the
helpers. The difference was the profile. Buck2 honoured the declared
`hardened` (abort, fat LTO, symbols stripped, about 30% smaller), but the Nix
builds are `release`: `buildRustPackage` overwrites `cargoBuildType` from its
`buildType` argument, so since T2 (a89cde0de) the helpers and terminald's and
the broker's Linux builds unwind and keep their symbols, where each crate's
own `[profile.release]` had made them abort before. The deployed builds are
the unwind ones, so the Buck2 helpers now build `release`, and the parity
test compares the panic strategy (the panic_unwind runtime's message, which
survives stripping). Abort was the deployed strategy until today and the
helper sources have not changed since, so abort alone does not explain the
failures, and overalls-1f's A/B cleared the helpers: account-lifecycle passed
locally on the exact CI derivation with the Buck2 helpers and with the Nix
helpers at fbb29d9fe, artifact-agent-publish passed twice (once at load
60-70), and audi-relocation-fleet passed from the identical CI derivations,
with no "panicked at", SIGABRT or core dump in any run. The same suites had
failed before Buck2 (runs 40518919452 and 40703103535). The cause was runner
oversubscription (8-vCPU nested runners carrying about 30 vCPUs of VMs) and
a Lilly prewarm that never retries after `busy`, which overalls-1f is fixing.
The swap is restored with the `release` helpers. Restoring `hardened` is a
follow-up recorded in ADR-0273.

Open item (owner: overalls-1f): hostd's request decoder (`lilly/native/hostd/src/protocol.rs`)
reads frames by offset (`bytes[9..]`, `rest[..state_length]`,
`body[4..8]`). Each slice follows a length check today, but nothing proves
the decoder total over truncated or oversized frames; a missed bound would
panic the connection thread, and under `hardened` (abort) all of hostd. The
decoder must use checked `get(..)` with a decode error and gain a property
test over truncated and oversized frames before `hardened` returns.

Closed (hostd decoder prerequisite). An audit of every index, slice,
conversion and wire length field on the decode path (`decode`, `sized`,
`netns_target`, `run_body`, `valid_directory`, `Stream::decode`,
`decode_reply`, `receive` and the argument grammars that read decoded
fields) found no reachable panic: each offset slice was dominated by a
length check, and the new property tests also pass against the previous
decoder. The decoder is now total by construction: a bounds-checked cursor
(`split_at_checked`, `try_into`) returns a closed `DecodeError` (`Size`,
`Operation`, `Layout`, `Value`), the wire format is unchanged, and a
malformed datagram still closes its session with no reply. The one
peer-reachable abort found was elsewhere: `std::thread::spawn` panics when no
thread can be created, so a connection or request flood that exhausted
threads would abort a `hardened` hostd. Connection, request, durable-job and
namespace-dial threads now use `thread::Builder::spawn`; a failed request is
refused `Unavailable` and a failed connection is closed. Evidence: Hegel
properties in `lilly/native/hostd/src/decode_tests.rs` (arbitrary bytes,
truncated and byte-corrupted frames of every operation, corrupted length
fields of `LaunchVm`, `BridgeNetnsTcp` and `BridgeIngress`, each asserting no
panic, a typed error and exact re-encoding of anything accepted, plus
in-process sessions whose threads must not panic) and
`lilly/native/hostd/tests/malformed_frames.rs`, which drives the real binary
and requires it to stay running and serve a new session after each
malformed datagram. Both pass under `cargo test --profile release` and
`--profile hardened`, and through Buck2 (`//lilly:lilly-hostd-unittest`,
`//lilly:lilly-hostd-test-malformed_frames`). A mutant with one unchecked
namespace slice fails both suites; under `hardened` the daemon exits with
SIGABRT (wait status 134), under `release` only its session thread dies,
which shows that the binary test checks the abort case. Remaining for
`hardened`: the other twelve helpers, and the start-up-only spawns in
`exec.rs` (reaper and bridge-exit reporter), were not audited here.

**Mila C header.** The three copies of the C ABI had drifted: the Rust
crate's header declared 32 of the 52 `mila_*` exports, Apple's 37 and the
Windows scaffold's 26, and the Windows copy spelled the watch enumerators
differently. cbindgen 0.29 cannot reproduce the enumerator names Swift
imports, so the crate's header stays hand-written and becomes the only copy:
it now declares all 52 exports, Apple's `include/mila_ffi.h` is a symlink to
it, and the Windows header is deleted (.NET declares its imports in C# and
never read it). `tests/header.rs` fails when an export is missing, extra or
has a different arity, or when a C enumerator differs from its Rust
discriminant; the Nix Mila check also compiles the header with
`-Wall -Wextra -pedantic -Werror` as C and C++. Apple CI is the only
consumer that can confirm the symlink.

**Vendor leak (T2).** A panic location naming a vendored crate keeps the
whole `importCargoLock` link farm in a closure. Lyra's main zigbuild phase had
no remap, so `tool-lyra` carried 518 store paths, every crate included; it now
remaps `${vendor}` like the cross builds, and its closure is the single output
path. The Buck2 leaves name crates by their relative cell path
(`.buck-cells/rust/vendor/...`), never a store path, and each parity test's
embedded-path scan refuses an import that would carry one. The prelude's own
`--remap-path-prefix` wins over a toolchain flag, so no extra remap is set.

**Lyra's cargo (2026-10-31).** Lyra's four Nix derivations ran nixpkgs cargo
1.99.0 against the toolchain's rustc 1.97.1, which breaches ADR-0273 (see its
dated correction). They now take cargo, clippy and rustfmt from the toolchain.
Rebuilt outputs are byte-identical to the previous ones, except the two macOS
clients' `LC_UUID`.

**Findings (open):**

- *macOS clients are not reproducible.* `nix build --rebuild` of the same
  Lyra derivation changes 16 bytes of `LC_UUID` in `darwin-amd64` and
  `darwin-arm64` (plus the ad-hoc signature hashes over it on arm64); the
  zig Mach-O link takes something per-run into the UUID. The Linux, Windows,
  FreeBSD and illumos outputs rebuild identically.
- *Vendored OpenSSL embeds build paths.* Every Lyra binary that links
  `openssl-sys` with `vendored` carries three absolute paths from the build
  sandbox: `ENGINESDIR` and `MODULESDIR` under Cargo's `OUT_DIR`
  (`/build/target/<triple>/hardened/build/openssl-sys-<hash>/out/openssl-build/install/lib/{engines-3,ossl-modules}`)
  and the `compiler:` string naming cargo-zigbuild's `zigcc` wrapper under
  `/build/cargo-zigbuild-cache`. openssl-src passes `--prefix=$OUT_DIR/...`
  and OpenSSL compiles the directories in as defines, so
  `-ffile-prefix-map` cannot reach them (and would itself appear in the
  `compiler:` string). They are not store paths, so closures are unaffected,
  but the outputs depend on the builder's directory layout, and the two
  directories are the shipped client's default provider and engine search
  paths: a writable `/build` on a user's machine is a place a provider could be
  loaded from if a configuration asked for one. Fixing it needs a patched
  openssl-src (an install prefix independent of `OUT_DIR`); until then a
  Buck2 build of Lyra matches Nix only when it runs under the same `/build`
  layout.

## M9: Mila platforms

This milestone implements the Mila part of ADR-0269. It makes no new
decision; the shipped Windows DLL stays MSVC, and the record superseding
ADR-0227 is still to be written.

**Non-hermetic targets.** Xcode, the Android SDK with Gradle, and the .NET
SDK are not in Nix, so `mila_platform` (`buck/mila.bzl`) runs them through a
typed driver (`buck/mila_platform.py`) from the Buck2 daemon's environment.
Buck2 local actions inherit the daemon's environment, not the client's: a
probe action did not see a variable set only on a later `buck2 build`.
The driver therefore checks its `require` programs and names `tools/buck2
kill` when one is missing. Each target carries the label `non_hermetic`, is
`local_only` with `allow_cache_upload = False`, so no SDK-dependent output
reaches the NativeLink cache or remote execution, and is compatible only
with `toolchains//:non_hermetic_enabled` (`-c overalls.non_hermetic=true`)
and its host OS. `buck2 build //...` skips the 14 Mila platform targets, and
`affected.bxl` drops them from selection. Their source globs are declared
inputs, and the in-tree build outputs are in `project.ignore`.

| Platform | Targets | Pinning |
| --- | --- | --- |
| Apple | `apple-ffi`, `apple-ffi-clippy`, `apple-swift-test`, `macos-dev`, `ios-dev`, `macos-release`, `ios-release` | Swift packages have no dependencies; Rust from the root `Cargo.lock` |
| Android | `android-debug`, `android-release`, `android-ffi-clippy` | `gradle/verification-metadata.xml` (SHA-256, 532 components) |
| Windows | `windows-ffi-msvc`, `windows-ffi-msvc-clippy`, `windows-dotnet`, `windows-smoke` | `packages.lock.json`, `RestoreLockedMode` |
| Linux (hermetic) | `windows-ffi-gnu`, `windows-ffi-gnu-clippy` | vendored `rust//` crates |

The Gradle and NuGet locks are no Nix inputs and do not fit the
`dependencyPins` model, so `scripts/pins.ex` gains `platform_locks`: a
`.csproj` without `RestorePackagesWithLockFile`, `RestoreLockedMode` and a
committed lock, or a Gradle build without verification metadata, is a
violation. Robolectric downloads its `android-all` jar at test time, outside
Gradle's resolution, so that jar is unverified.

**Windows FFI.** `cargo zigbuild` cross-builds `mila-ffi` for
`x86_64-pc-windows-gnu` offline from the vendored crates. The DLL imports only
system and UCRT libraries and contains no store or home path. Three findings
shaped the rule: build scripts need a host `cc`; cargo-zigbuild's wrapper
paths must be absolute because rustc runs in each crate's directory; and
`RUSTFLAGS` replaces the `dlltool` flag cargo-zigbuild adds, so the path
remaps go in the Cargo home's target `rustflags`. The gnu DLL is not
bit-reproducible and the .NET interop has only been verified against MSVC,
so it stays a compile and Clippy check. Switching the shipped DLL to gnu
would need its own decision.

**Darwin cells.** `buckCells.aarch64-darwin` evaluates once devenv's patched
nixpkgs source (an import-from-derivation) is substituted from
devenv.cachix.org; only three small derivations are built. Hermetic toolchains
there are a stub that fails when run, so a Darwin runner builds only
`non_hermetic` targets. `tools/buck2` falls back to `shasum` on macOS.

**Without Nix.** `tools/buck2 --no-nix` (Git Bash on Windows, or Linux)
downloads the buck2 release and prelude archive named in
`tools/buck2-no-nix.json` and refuses either unless its SHA-256 matches the
pin registry. It writes a real `.buck-cells` directory with an empty `rust`
cell and `[overalls] no_nix = true, non_hermetic = true`; `toolchains//`
accepts any path then, and a hermetic target fails at analysis.
`nix/buck/no-nix.nix` builds the same downloads as `//tools:buck2-no-nix-*`
kits, and fails when the release or prelude no longer matches the pinned
nixpkgs buck2, so a buck2 bump must update the file and pins together. The
cells name only the kits' derivations, so materialising the cells does not
fetch them. `.gitattributes` keeps `tools/buck2` LF on Windows checkouts.

**CI.** `mila-builds.yml` keeps its job names and artifact paths:
- source-bundle builds the bundles through bootstrap targets;
- apple-native installs Nix with the overalls and devenv caches, materialises
  the cells, and builds `apple-ffi`, `apple-ffi-clippy`, `apple-swift-test`
  and the dev apps;
- android-native builds `android-ffi-clippy` and `android-debug`;
- windows-native downloads buck2 directly (no dependency on source-bundle)
  and builds the four Windows targets.
The tailnet and journey steps are unchanged (ADR-0264), and the workflow now
also runs when the wrapper, cells, toolchains or the rule files `mila/BUCK`
loads change.

The first dispatched run (41111464288) found two faults that local Linux
runs could not:
- Git Bash rewrites POSIX-looking arguments when it starts a Windows
  program, so `//mila:windows-ffi-msvc` reached buck2.exe as `/mila:…`.
  `tools/buck2 --no-nix` now disables that conversion.
- A case-insensitive checkout (macOS, Windows) cannot hold both the root
  `BUCK` file and the `buck/` directory, so the root package was missing and
  `//mila:apple-ffi -> //:workspace_files` failed to analyse. The Mila
  sources named the root files on Linux only (8da625617) until 055218ae8
  renamed the root build file to `BUCK.v2`; 8b444aa8a restored the
  dependency on every platform, and its run 41124115576 built every Apple
  and Windows target with it.

Run 41114668466 (8da625617) is the M9 gate, repeated by 41122878867 after
the rename: linux-native, android-native and
source-bundle pass; apple-native and windows-native pass every build step
and fail only where the tailnet fixture is unreachable, as on earlier trunk
runs (journey-fixture-tailnet: the fixture node is not tagged
`tag:mila-ci`). The "Native platform gate" fails on open parity-matrix rows,
also as before. Timings on a cache hit:

| Job | Buck2 setup | Build steps | Tailnet join after job start |
| --- | --- | --- | --- |
| windows-native | cells 12 s | FFI 2m30, Clippy 55 s, .NET 1m32, smoke 9 s | 5m44 (4m54 to 7m25 before) |
| apple-native | Nix 49 s, Cachix 7 s, cells 1m38 | FFI 1m24, Clippy 38 s, Swift 53 s, dev apps 1m54 and 1m47 | 9m34 (about 7m before) |

**Release (held).** A reviewed change to `mila-release.yml`, not yet pushed
and waiting on the user's decision and a test tag, builds the bundles and
Linux tarball through bootstrap targets, the Android APK through
`tools/buck2 --no-nix` and `//mila:android-release`, and the Apple FFI and
signed apps through `//mila:apple-ffi` and `//mila:<platform>-release`.
Signing secrets stay in the import step, which runs no Buck2 command; the
release step restarts the daemon with only variables and the paths and
profile name the import step writes to `$GITHUB_ENV`. A local probe started a
daemon with canary `CERTIFICATE`, `CERTIFICATE_PASSWORD`, `NOTARY_KEY` and
`MILA_KEYCHAIN` values and built a non_hermetic target: none appeared in
`buck2 log what-ran`, `buck2 log show`, the decoded event log or buck-out.
The release job repeats that check on every Apple release, also when the
build fails: it masks the canaries and fails when the keychain password,
certificate password or notary key and issuer IDs reach the daemon's
environment, an event log, buck-out, `~/.buck` or a buck2 temporary
directory, when the identity is in an action's command or environment, or
when any of those places holds a copy of the iOS export options. No uploaded
artifact contains buck-out or a Buck2 log. The legacy Flutter Windows
release job is unchanged.
