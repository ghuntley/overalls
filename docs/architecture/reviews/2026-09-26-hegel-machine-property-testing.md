# Hegel property-based testing for NixOS machine checks: no HLDD impact

## Scope and architecture impact

The `hegel-nixos-tests` work adds a verification-only framework under
[nix/verification/hegel/](../../../nix/verification/hegel/README.md): a pinned `libhegel` engine build
([libhegel.nix](../../../nix/verification/hegel/libhegel.nix), `libhegel-pin`), its Python
binding ([hegel-python.nix](../../../nix/verification/hegel/hegel-python.nix),
`hegel-binding-matches-engine`) and a `hegel.runTest` composer
([run-test.nix](../../../nix/verification/hegel/run-test.nix),
`hegel-test-properties-execution`) that wraps `pkgs.testers.runNixOSTest`. The
check catalog gains no new entry; four existing suites are migrated to the
wrapper ([nix/verification/tests/scope.nix](../../../nix/verification/tests/scope.nix), then catalog.nix,
`hegel-framework-packages`; each suite receives `hegel` through its explicit
argument set). User documentation is
[docs/development/testing-with-hegel.md](../../development/testing-with-hegel.md).

No architecture impact and no HLDD chapter change: the change touches
verification tooling only. It adds no NixOS module options — `properties` is
consumed by the test composer and is removed before the upstream
`nixosTest` module class sees the test (`scripts/hldd/options.nix` evaluates
`overalls.*`/`services.*` declarations from the production module; its input is
unchanged). It adds no hosts, roles or services, so the public topology
projection (`scripts/hldd/topology.nix` over `nix/platform/hosts/inventory.nix`) is
unchanged. No domain, protocol, persistence, authorization or deployment
boundary moves; the migrated checks keep their existing synthetic credentials and
isolated scopes (`nix-test-real-packages`, `nix-test-isolated-inputs`). A survey
of the handbook chapters found no passage describing machine-test PBT mechanics
that this framework would stale; `19-coverage.md` already names property-based
tests as preferred evidence generically.

New evidence introduced by the change:

- Hegel binding smoke properties in the binding package `checkPhase`: a passing
  value property, a failing value property that must shrink, report
  `HEGEL_REPLAY_BLOB` and replay to the same counterexample, plus passing and
  failing in-memory state machines. These run as part of any Hegel-enabled
  check's dependency graph, not as a separate flake check.
- Migrated `underclass-service` (`underclass-hegel-stateful`): a
  property-driven authorization matrix over drawn endpoints/tokens and an
  engine-sequenced state machine over restart/reboot interleavings with
  loopback-listener, state-persistence and journal-redaction invariants.
- Migrated `secret-custody`: the previous Hypothesis fixture driver is replaced
  by Hegel properties against the same packaged SecretSpec/SOPS custody
  assertions.
- Migrated `zfs-transfer`: adoption crash recovery becomes the property-driven
  `AdoptionCrashRecovery` state machine with engine-chosen fault points;
  [its CONTRACTS](../../../nix/verification/tests/machines/zfs-transfer/CONTRACTS) gains
  `adoption-crash-recovery-property-driven` bounding that evidence, while the
  suite's `native-transfer-evidence-boundary` scope is unchanged.
- Migrated `agent-cli`: packaged-CLI journey assertions are extended with
  engine-sequenced operations.
- Execution ledger (this branch, KVM, `requiredSystemFeatures = kvm`);
  presence here means an actual run:
  - `underclass-service`: PASSED (twice: 646s and 675s wall; the engine drove
    restart/reboot interleavings past systemd's default start-rate limit, which
    the check now disables explicitly).
  - `secret-custody`: PASSED (605s); the run includes the driver-side
    EnvironmentFile roundtrip property with redacted draws and the custody
    state machine.
  - `zfs-transfer`: PASSED (328s). The engine found two genuine
    migration-time defects — replay nondeterminism (teardown now restores the
    full guest baseline including the one-shot transfer-key store) and a
    fixturing gap (cancel-mode retirement has no proven cleanup transition
    from a ready copy; the state machine is now scoped to the proven
    destroy/mount→import-pruned→killed-unmount→import-deleting corridor, and
    reject probes run post-retirement). Shrinking produced the minimal
    failing sequences during diagnosis.
  - `agent-cli`: driver gates pass; the VM run fails at the same
    pre-existing linear-flow assertion as `origin/main` root
    ("machine or agent access unavailable" — reproduced identically on the
    base commit's build product); the migration does not affect that failure
    and the Hegel additions never run because the linear flow fails first.

## Validation and remaining gaps

Reviewed the root, nix and per-suite CONTRACTS scopes and the changes' native
notes. `node scripts/check_contracts.mjs format` passes (102 CONTRACTS files,
1819 native notes, 2147 maintained source files covered) and `coverage` reports
no gaps: the framework's Nix files carry local notes, and the vendored `hegel.h`
and binding Python sources sit under the `nix/CONTRACTS` scope. Contract checks
are structural; they do not establish that properties actually execute.

`elixir scripts/check_hldd.exs` receipts were refreshed post-review with the
rationale sentences recorded in `docs/hldd-maintenance.json` (`marshall` and
`deployment` as `updated`, `lilly`/`services` as `no-impact`, `governance` as
`updated` for the doc/review additions); the hldd Nix check passes.

Gate readiness: the repository Python static gate passes on the final tree
(`ruff format --check`, `ruff check` covering the new `nix/verification/hegel/python/`
binding and the migrated machine fragments; `ty` over its include list).
The binding's unpackaged-side detail: initial sweep's `F821` (undefined
`c_uint8` in `TestCase.note`, a latent runtime failure) was fixed, and the
`ANN`/`SIM` findings were resolved rather than ignored. `ty` does not cover
`nix/verification/hegel` (`[tool.ty.src]` include list); hegel-enabled machine drivers are
typed through the composed NixOS test driver with `hegelPython` in
`extraPythonPackages`.
