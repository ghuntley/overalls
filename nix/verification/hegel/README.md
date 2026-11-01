# Hegel property-based testing for NixOS machine tests

This directory implements property-based testing (PBT) for overalls NixOS
machine checks, driven by [Hegel](https://hegel.dev/)'s native engine
(`libhegel`, from the Hypothesis authors). It composes with the upstream
`pkgs.testers.runNixOSTest` without modifying nixpkgs.

```
nix/verification/hegel/
  libhegel.nix      # the Rust engine (hegeltest-c v0.47.4 tag, cdylib) with pinned hashes
  hegel.h           # the C ABI header from that tag, vendored for reference/audits
  hegel-python.nix  # the Python binding package (used by test drivers)
  python/hegel/     # the binding source: ctypes ABI layer, generators, run loop,
                    # MachineStateMachine, runner
  run-test.nix      # hegel.runTest: composes a runNixOSTest module + properties
  README.md         # this file
```

## Why

Straight-line `testScript`s enumerate interleavings by hand. With Hegel the
engine sequences operations and shrinks failures to a minimal counterexample:

- value-level properties (`@given`) test a service against drawn inputs;
- state machines (`MachineStateMachine` + `@rule` + `@invariant`) explore
  restart/reboot/crash interleavings against live VMs with invariants
  checked at engine-chosen join points.

## Writing a test

See [docs/development/testing-with-hegel.md](../../../docs/development/testing-with-hegel.md) for the
full guide with a worked example. Short form:

```nix
{ pkgs, module, hegel, ... }:
hegel.runTest {
  name = "overalls-myservice";
  properties = {
    enable = true;
    profile = "ci";      # deterministic CI: derandomized, no database
    testCases = 10;      # engine runs this many cases per property
    statefulStepCount = 30;
  };
  nodes.machine = { ... };
  testScript = ''
    from hegel import MachineStateMachine, given, invariant, integers, rule

    @given(n=integers(0, 100))
    def accepts_drawn_load(tc: TestCase, n: int) -> None: ...

    class RestartChaos(MachineStateMachine):
        @rule(weight=3) def query(self) -> None: ...
        @rule(weight=1) def reboot(self) -> None: ...
        @invariant(always=True) def still_serves(self) -> None: ...

    RestartChaos.run()
  '';
}
```

Register the check in `nix/verification/tests/catalog.nix` by extending its argument set
with `hegel`, e.g. `(service // { inherit hegel; })`.

## `properties` options

| option | default | meaning |
|---|---|---|
| `enable` | `false` | inject the binding and run registered properties |
| `profile` | `"ci"` | libhegel profile (`development`, `ci`, `workload`, `base`, or `null`) |
| `testCases` | `25` | max valid cases per property |
| `statefulStepCount` | `40` | rules per state-machine case (per-machine `run(steps=)` overrides) |
| `seed` | `null` | fix the engine seed; `null` = profile behavior |
| `derandomize` | `null` | derive the seed from the test identity (CI determinism) |
| `database` | `null` | example database directory; `null` = profile behavior |
| `redact` | `false` | never print drawn values or reproduce blobs (secret-bearing tests) |
| `verbosity` | `"normal"` | `normal`, `verbose`, `debug`, `quiet` |
| `phases` | `null` | engine phase list subset of `explicit generate reuse target shrink`; `null` = all |

## Replaying a failure

On failure the build log shows a reproduce blob. Re-run exactly that
counterexample locally (values and all):

```sh
# The driver is an attribute of the check, built from lib.assemble (see the
# tests README, "Run checks"); <name> is the check name.
nix build --impure -L --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).checks."<name>".driver' && \
  HEGEL_REPLAY_BLOB="AAEAAAAA..." result/bin/nixos-test-driver
```

With `redact = true`, blobs are suppressed deliberately; the failure origin
is still reported, and the journal/invariant context in the log is the record.

A replay blob is an assertion about one registered property. The runner fails
if the blob is malformed, if it overruns the property's generators, or if it
does not reproduce a failure in any registered property. Stale and
cross-property blobs therefore cannot silently turn a check green.

## Imperative failures and concurrent state machines

`runTest` executes registered properties from a `finally`-style wrapper around
the imperative `testScript`. When an imperative assertion fails, Hegel still
runs and reports its properties before the original assertion is re-raised.

State machines accept `min_concurrency` and `max_concurrency` in `run()`. The
engine chooses a worker count in that range; each worker receives a cloned
`TestCase` (`self.worker` exposes its index and handle), and rules in one
concurrency group may run in parallel. Rule bodies that share fixture state
must provide their own synchronization. Concurrent runs are deliberately
reported as nondeterministic by libhegel and do not produce shrink/replay
blobs; keep a sequential projection for shrinkable diagnosis when a property
needs both forms.

## Interactive use

The interactive driver carries the same environment, so properties are
importable in its REPL:

```sh
nix build --impure -L --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).checks."<name>".driverInteractive'
./result/bin/nixos-test-driver
# in the REPL:
from hegel import _run_registered
_run_registered(profile="development")
```

The catalog exports `hegel-framework-packages` as a standalone check. It builds
the pinned native engine and Python binding and runs the binding smoke suite,
including shrinking, replay, replay-mismatch rejection, state machines, and a
concurrent schedule.

## Versioning

`libhegel.nix` pins tag and hashes; the binding refuses to load a mismatched
`libhegel_c` (`hegel_version` check against `passthru.expectedVersion`). Bump
both together and re-run the binding's `checkPhase` (unit properties,
failing-property shrink/replay, an in-memory state machine) via:

```sh
nix-build -E 'with import <nixpkgs-pinned> {}; ...'  # see nix/verification/tests/catalog.nix
```

(the pinned testPkgs expression is in `nix/verification/tests/catalog.nix`; the driver of
any Hegel-enabled check also re-checks everything at eval+build time.)
