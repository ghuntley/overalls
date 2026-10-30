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
