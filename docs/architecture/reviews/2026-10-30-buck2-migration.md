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
