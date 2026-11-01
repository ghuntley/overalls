# Buck2 cutover, M11 (2026-11-01)

Scope: the milestone that makes Buck2 the only build entry point, so the
flake supplies only pins, toolchains and assembly. Checked against
[ADR-0269](../decisions/0269-buck2-build-system-with-nix-toolchains.md),
[ADR-0270](../decisions/0270-graph-driven-machine-test-selection.md),
[ADR-0271](../decisions/0271-buck2-host-self-deployment.md),
[ADR-0273](../decisions/0273-single-rust-workspace-and-toolchain.md) and
[ADR-0276](../decisions/0276-namespace-buck2-remote-cache-and-execution.md).
The removal was preceded by changes to every consumer, the generated test
index, machine-test input narrowing and a fix to the host enrollment path.

## Findings

1. **Checked: flake outputs (ADR-0269).** The flake exports only
   `buckCells`, `lib.assemble`, `lib.dependencyPins` and `nixosModules`
   (contract `flake-exports-pins-and-assembly` in
   [flake.nix](../../../flake.nix)). `packages`, `checks`,
   `legacyPackages`, `apps` and `nixosConfigurations` are gone. Every
   assembled output is reachable as a `nix_assemble` target over
   `lib.assemble`, so `//:package-*`, `//:check-*`, machine tests and
   `//fleet/hosts/<host>:*` are unchanged. `buckCells` for both systems,
   the pin builds and the hermetic Mila journey fixture kept their drvPaths
   across the removal. The two checks that existed only as flake views
   moved: the `overalls-install.ps1` check is a Buck2 `script_check` (`//nix:overalls-install-ps1`) with its
   contract beside the script, and `py-static` stays the Buck2-native
   check in [python.bzl](../../../buck/python.bzl).
2. **Checked: consumers.** Every workflow, script, test and document that
   read a removed output now goes through Buck2:
   - `mila-release.yml` and `package_release.sh`;
   - the antithesis contexts (`//:package-antithesis-*`) and the OSS scanner
     image;
   - the Rust parity tests, which read `lib.assemble {}.packages`;
   - the host CLI, which builds `//fleet/hosts/<host>:system`, `:binding`
     and `:enrollment`;
   - the run targets `//:host`, `//:secrets` and
     `//:update-vscode-extensions`;
   - the documentation.

   `publish-cache.yml`'s `root//:check-*` targets survive because
   `nix_assemble` evaluates `lib.assemble`, not the removed views.
   `nix-upgrades.yml` touches only the lock file. devenv reads no flake
   output. The remaining flake commands are in `marvin/README.md`, which is
   left unchanged because the Marvin package and the journey fixture hash
   that file, and in historical ADR and review text.
3. **Checked: host activation gate (ADR-0271).** Before the removal,
   `status.json` on dungarees, panterloons and salopettes reported
   `builder: "buck2"` (checked over ssh, 2026-11-01 00:17Z), so no host
   still builds a flake attribute. Salopettes' sshd listens on port 22 by
   design: it is the Susan-only relay (contract `salopettes-susan-only`).
4. **Fixed, medium, host enrollment.** After the host CLI moved to Buck2,
   the host-enrollment machine test failed with an opaque
   `Command failed: buck2`.
   - Diagnosis: the CLI now reports a bounded, redacted tail of buck2's
     stderr (contract `host-cli-bounded-diagnostics`). The tail showed that
     the offline fixture's stub `lib.assemble` reads its preloaded sources
     through lookup-path entries, and that those entries never reached the
     build. `host enroll` builds inside a `systemd-run` unit, which has no
     `NIX_PATH` and reads `nix.conf`. In login shells, the NixOS default
     `NIX_PATH=nixpkgs=flake:nixpkgs` overrides `extra-nix-path`, and under
     restrict-eval it fetches the global flake registry.
   - Fix: the fixture sets one list as both `nix.nixPath` and
     `nix.settings.nix-path`.
   - Scope: the fault was in the fixture only. Real enrollment reads no
     lookup path. `//fleet/hosts/dungarees:enrollment[drv]` evaluated to the
     same derivation with `nix-path ""`, `flake-registry ""`, `--offline` and
     an empty `NIX_PATH`.
   - Hardening: 7fab7483f runs `nix_assemble.sh` with
     `--option flake-registry ""`, so an offline interactive root shell no
     longer tries to fetch the global registry. No derivation changed.
5. **Checked: generated test index (ADR-0269, ADR-0270).**
   [docs.bxl](../../../buck/bxl/docs.bxl) generates the tests README "Find a
   test" table from the graph: every machine test, every assembled check and
   the described Buck2-native checks. Curated text lives in
   [find_a_test.bzl](../../../nix/verification/tests/find_a_test.bzl).
   `tools/docs --check` runs in `tools/precommit` and fails on a stale table
   or on a curated key that names no target.
6. **Partial, medium, selection precision (ADR-0270).** 51 machine-test
   suites now declare narrow module inputs. A change to `sysctl.nix` selects
   156 machine tests instead of 206, and `tailscale.nix` selects 155. The
   number of builds stays at 191. The other 155 suites still depend on
   `modules.default`, so most module edits still select them. Narrowing them
   is incremental work in `machine_tests.py`.
7. **Open, medium, signed release path untested (ADR-0269 M9).**
   `mila-release.yml` builds through Buck2. Since 71e727df8 its unsigned
   Android and Apple builds run without a `mila-v*` tag. Neither the signed
   builds nor the Apple signing-leak check has run:
   - the repository has no `mila-release` environment or signing secrets;
   - the publish job creates a public release;
   - the Apple version check rejects prerelease tags.

   No test tag was pushed. The first real release is the first evidence for
   the signed path.
8. **Low, onboarding friction.** Adding a host still needs a manual
   `OWNED_PACKAGES` entry for affected-test ownership.

## Status

- ADR-0269 stays partial. M11's own work is complete, but the gaps listed in
  the ADR remain: the M5 and M6 leaves, the per-host `params` channel and the
  untested release path.
- ADR-0270 stays partial because of finding 6.
- ADR-0271 stays partial for the per-host `params` channel. The activation
  gate and the enrollment path are evidenced by the passing host-enrollment
  machine test and the fleet status above.

## Checks run

- `tools/buck2 test //nix/verification/tests/machines/host-enrollment:host-enrollment`
  passed in full with the fixture fix.
- Narrowed suites' `[drv]` targets evaluate. `sysctl` and `access` pass.
- drvPath comparisons for `buckCells`, `lib.dependencyPins` and the Mila
  journey fixture across the removal.
- `tools/docs --check`, the assembly attribute freshness check,
  `elixir scripts/check_adrs.exs` and `tools/precommit` on the removal
  commit.
- Inception tests were not run; they are known broken and out of scope.

## Follow-up

- Narrow the remaining 155 machine-test suites.
- Exercise `mila-release.yml`'s signed path once signing secrets and a
  draft-release mode exist.
- Port the `marvin/README.md` flake commands when the Marvin fixture hash is
  next allowed to change.
