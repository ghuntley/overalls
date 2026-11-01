# Property-based machine testing with Hegel

Overalls NixOS machine checks support property-based testing driven by
[Hegel](https://hegel.dev/)'s native engine. Instead of enumerating every
interleaving by hand, you declare **rules** (operations the engine may run,
in any order, any number of times) and **invariants** (properties the engine
checks after every group of steps), plus **value-level properties** over
drawn inputs. On a failure the engine shrinks the op sequence to a minimal
counterexample and emits a replay blob.

The framework lives in [`nix/verification/hegel/`](../../nix/verification/hegel/README.md). It wraps the
upstream `pkgs.testers.runNixOSTest`; nixpkgs is not modified.

## When to use which form

| Form | Use for |
|---|---|
| plain `testScript` (imperative) | one-off bring-up, exact permission bits, fixed assertions |
| `@given(...)` | "for drawn inputs, the service must/ must not …" |
| `MachineStateMachine` | interleavings: restarts, reboots, crashes, rotations, adversarial operations |

## Enabling it

Machine tests opt in through `hegel.runTest`, same shape as
`pkgs.testers.runNixOSTest` plus a `properties` block:

```nix
{ pkgs, module, hegel, ... }:
hegel.runTest {
  name = "overalls-myservice";
  properties = {
    enable = true;
    profile = "ci";        # deterministic in CI
    testCases = 10;        # engine cases per property
    statefulStepCount = 30; # steps per state-machine case
    redact = false;        # true: never print drawn values or blobs
  };
  nodes.machine = { ... };
  testScript = '' ... '';
}
```

then register the check with the extended argument set in
`nix/verification/tests/catalog.nix`:

```nix
myservice = import ./machines/myservice (service // { inherit hegel; });
```

## Value-level properties

`@given(name = generators.X(...))` registers a property; each declared
keyword argument is drawn fresh per test case:

```python
from hegel import TestCase, given, integers, sampled_from, text


@given(size=integers(0, 4096), tenant=sampled_from(["alpha", "beta"]))
def accepts_any_payload(tc: TestCase, size: int, tenant: str) -> None:
    machine.succeed(f"dd if=/dev/zero bs={size} count=1 | myservice ingest --tenant {tenant}")
```

Run the property body just as you would write imperative code — `machine`
and friends are the same driver objects. Fail with `assert` (any exception
fails the case); discard invalid examples with `tc.assume(condition)`.

Available generators: `integers`, `floats`, `booleans`, `binary`, `text`
(including `alphabet=`, `codec=`, Unicode `categories` filtering),
`from_regex`, `emails`, `urls`, `domains`, `lists`, `sampled_from`,
`one_of`, `optional`, `fixed_dictionaries`, `tuples`, `just`, `dates`,
`times`, `datetimes`, `uuids`, `ip_addresses`. Combinators: `.map(f)`,
`.filter(pred)`.

## Stateful properties: rules, invariants, pools

Subclass `MachineStateMachine`, declare `@rule`s and `@invariant`s, register
with `MyMachine.run()`. The engine schedules the rules; you write the
actions and the properties:

```python
from hegel import MachineStateMachine, Pool, invariant, rule


class Custody(MachineStateMachine):
    def setup(self) -> None:
        self.keys: Pool = Pool()  # engine-managed "previously produced values"
        self.model: dict[str, str] = {}

    @rule(weight=4, name=text(min_size=1, max_size=24, alphabet="a-z"))
    def write(self, name: str) -> None:
        machine.succeed(f"kv put {name} value-{name}")
        self.keys.add(name)
        self.model[name] = f"value-{name}"

    @rule(weight=2)
    def read_back(self) -> None:
        key = self.keys.draw()  # raises assumption if empty -> rule skipped
        out = machine.succeed(f"kv get {key}").strip()
        assert out == self.model[key]

    @rule(weight=1)
    def reboot(self) -> None:
        machine.reboot()
        machine.wait_for_shutdown()
        machine.start()
        machine.wait_for_unit("kv-store.service")

    @invariant(always=True)  # checked after every rule group ...
    def unit_active(self) -> None:
        machine.require_unit_state("kv-store.service")

    @invariant  # ... and sampled at join points
    def model_matches_store(self) -> None:
        for key, value in self.model.items():
            assert machine.succeed(f"kv get {key}").strip() == value


Custody.run(steps=50)
```

Semantics, exactly:

- each **test case** = fresh machine instance state (`setup()`), one
  engine-chosen op sequence, then `teardown()`;
- the engine decides *which rule next* and *when to check non-`always`
  invariants* (probability `1/step_count` per join point); `always=True`
  invariants run at **every** join point; every invariant runs at the
  initial and final state;
- a rule that raises `hegel.assume(...)`/`AssumptionRejected` (e.g. because
  a `Pool` is empty) is **rejected**, not failed — the engine picks another;
- failures shrink: the engine replays prefixes/subsequences toward the
  minimal failing interleaving.

`Pool` is for "use a value from an earlier step" (`add`, `draw(consume=…)`) —
rules that need prior artifacts (keys written, datasets created, claims
opened) shrink cleanly through them.

## Fault injection as rules

The hand-written crash ladders (`systemd-run --setenv=…`, wait for the
commit marker, `SIGKILL`, assert the durable claim) become ordinary rules:

```python
@rule(weight=1, point=sampled_from(["stage", "fsync", "rename"]))
def kill_mid_publish(self, point: str) -> None:
    machine.succeed(
        f"systemd-run --unit=overalls-fault --setenv=PUBLISH_PAUSE={point} "
        "systemctl restart overalls-secrets-marshall.service",
        check_exit=False,
    )
    machine.wait_for_file("/run/publish-committed", timeout=30)
    machine.succeed("systemctl kill --kill-whom=main -s KILL overalls-fault.service")
```

Keep rules concise and **idempotent-friendly**: the engine will retry them
in combinations you didn't anticipate. Anything that must hold regardless
goes in an invariant, not a rule tail.

Two hard-won constraints, both discovered by the engine in the overalls
suite itself:

- **Tame systemd ratelimits in the node config.** A weight-2 restart rule
  chained several times in one case trips `StartLimitBurst` (default
  5/10s) and your rules then wedge in `wait_for_unit`. Opt out in the
  node: `systemd.services.<svc>.serviceConfig.StartLimitBurst =
  pkgs.lib.mkForce 0;` plus
  `.unitConfig.StartLimitIntervalSec = pkgs.lib.mkForce 0;` (the module may
  already set these; the first migration hit exactly this).
- **Reset guest state per case.** The engine replays the *same draws* when
  shrinking; your VM is not snapshot-restored between replays. If replay N+1
  observes replay N's leftovers and diverges, the engine (correctly) refuses
  the run with "flaky test detected". `teardown()` (and `setup()`, for
  defensive idempotence) must drive the guest back to the baseline the first
  replay saw: retire claims, destroy created datasets, clear markers. If a
  subsystem truly cannot be made replay-deterministic, scope it out of the
  state machine and keep it as an imperative subtest, or drop to
  `properties.phases = [ "generate" ];` to disable replay/shrink for the
  whole check (you keep exploration, you lose shrinking).

## Determinism, seeds, and CI

- `profile = "ci"` (default): derandomized seed from the test identity, no
  database, `too_slow` health check suppressed — byte-identical runs in CI.
- Local fuzzing: build and run the interactive driver
  (`nix build --impure -L --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).checks.myservice.driverInteractive'`, then
  `./result/bin/nixos-test-driver`), and in the REPL call
  `_run_registered(profile="development")` for fresh entropy each run;
  `HEGEL_TEST_CASES`/`HEGEL_SEED` and friends override per process.
- A failing CI run prints `HEGEL_REPLAY_BLOB="…"`; re-run only that
  counterexample:

  ```sh
  nix build --impure -L --expr '((builtins.getFlake (toString ./.)).lib.assemble { }).checks.myservice.driver'
  HEGEL_REPLAY_BLOB="…" result/bin/nixos-test-driver
  ```

## Redaction and secrets

With `redact = true` the harness never prints drawn values, exception values,
or reproduce blobs — only failure **origins** (rule/invariant/function and
location). Use it for any test whose draws may carry secret material
(example: `secret-custody`). Guest-side hygiene is unchanged: don't echo
secrets into the serial log, keep `assert` messages value-free.

## Debugging tips

- `verbosity = "debug"` (or `--hegel-profile=development`) for per-case traces.
- The driver log already records every `machine.succeed/fail` — engine traces
  interleave with machine logs, so a shrunken counterexample is readable as a
  plain script of commands.
- Rules showing up as never-run is usually a rejection loop (empty pool) —
  check the `assume` paths, not the engine.

## Design notes

- The engine is `libhegel_c` (Rust, C ABI), pinned in `nix/verification/hegel/libhegel.nix`;
  the Python frontend is `nix/verification/hegel/python/hegel` (ctypes, stdlib only,
  zero interpreter dependencies in the driver's closure beyond the engine).
- State machines are **sequential** today (`min_concurrency = max_concurrency
  = 1`); the ABI supports concurrency groups and that is a planned extension.
- nixpkgs pin compatibility is proven at test-eval time: the composed driver
  runs `ty` and `ruff` over the script including the Hegel epilogue.

## Elixir and BEAM properties

Elixir properties use the same native Hegel engine but run inside the Mix test VM.
The current frontend ref of every Mix project is `44b4c8e`, resolved as
`44b4c8e109313f14733b06f2025e64f3c65a0bc9`. It is `b0dec2a` plus one fix: a
property without a `seed` option keeps the profile seed, so `HEGEL_SEED`
applies (before, the NIF cleared it). The recorded
299-test protocol gate used the earlier `2c9f7a4` frontend; the review preserves
the passing `6a62795` result separately. Those historical results do not verify
the current pin or changed consumer tests.
Use them for pure functions, protocol codecs, Ash changesets, lifecycle models,
authorization decisions, bounded retry/reconciliation models, and BEAM-visible
process or socket behavior. Keep NixOS, native Rust/KVM, physical isolation,
filesystem durability, and multi-host recovery claims in their dedicated suites.

Seeds in the Mix test VM come from the engine environment, which it reads once
per VM. Use `HEGEL_SEED=<n>` to replay or explore a fixed draw sequence, and
`HEGEL_DERANDOMIZE=true` (or the `ci` profile, which `CI=true` selects) for
derandomized draws. An explicit `seed:` option on a property overrides both.
`hegel_ex` sets no database key, so derandomized draws come from the engine's
constant `unnamed-test` key: every property without a seed starts from the same
seed, not one derived from its identity. A per-property key would also turn on
the engine's `.hegel/examples` replay database wherever `HEGEL_DATABASE` is not
`disabled`. That changes which examples run, so it is an open follow-up rather
than part of this pin.

Under Buck2, `mix_test` sets the seeds from the action's inputs, so a cached
verdict is the one a fresh run would reach
([ADR-0269](../architecture/decisions/0269-buck2-build-system-with-nix-toolchains.md),
contract `mix-test-seeds-explicit` in [buck/CONTRACTS](../../buck/CONTRACTS)):

| Run | `[mix] test_salt` | Hegel | ExUnit |
|---|---|---|---|
| Gate (`tools/precommit`, ci.yml, `tools/buck2 build`) | empty | `CI=true` (`ci` profile), `HEGEL_SEED=<n>`, `HEGEL_DATABASE=disabled` | `--seed <n>` |
| Nightly ([mix-nightly-seeds.yml](../../.github/workflows/mix-nightly-seeds.yml)) | `nightly-<UTC date>` | `CI=true`, `HEGEL_SEED=<n>`, `HEGEL_DATABASE=disabled` | `--seed <n>` |

`<n>` is the 32-bit FNV-1a hash of `<salt>:<inputs>`, where `<inputs>` is the
SHA-256 digest of the shard's source tree and test arguments. A cache hit
therefore replays exactly, and every changed shard draws anew. The `ci` profile suppresses the
wall-clock TooSlow health check, so a verdict does not depend on machine load;
plain `mix test` outside CI still runs it. Each shard log starts with its
salt and seeds. A failing shard prints a reproduction command:
`tools/buck2 build <target> -c mix.test_salt=<salt>`, or the `mix test` line
with the same environment.

The `b0dec2a` installer publishes the NIF through a sibling temporary file and
atomic rename. The previous in-place copy truncated a loaded library inode,
which could crash a concurrent test VM even when copying identical bytes.
Installer regressions verify inode preservation, complete concurrent publication,
permissions and failed-copy cleanup. This packaging repair changes no native
engine or runtime frontend sources relative to `1cfe362`.

Use one `property` runner with labelled draws, or a standalone `Hegel.check`
runner inside an ordinary test. Execution options belong on that runner.
The frontend rejects unknown options, nested `check all` execution
options, and unsupported compatibility clauses. Earlier frontends silently
discarded these inputs. Native engine errors retain the original discovered
BEAM failures and stacks; flaky errors do not erase their underlying assertions.
Standalone `check all` propagates supported options,
but the engine uses `test_cases`, not `max_runs`; `max_shrinking_steps` is also
unsupported. Express filter conditions explicitly with `Hegel.assume` and
destructure a generated value after drawing it. The earlier `f1ad336` map-context/options branch recursively
expanded and failed a 512 MiB/10-second compilation probe while a plain-property
control passed. The historical `08cd428` source passed an equally bounded
compilation/runtime probe for map context with options, named ExUnit context
with options and map context without options. A named context receives the
complete ExUnit context, including metadata; use a submap pattern for setup
values. Retained tagged ordinary declarations keep their existing generated
checks and fixture boundaries; this scoped probe is not a complete consumer gate.
Keep the default 100-case exploration budget and existing larger budgets for
generated success properties. A one-case deliberate failure/replay control is
different from a reduced success property. An exhaustive finite input matrix
can be an ordinary test; avoid repeatedly drawing an element already included
in that complete matrix. Do not truncate mutation lists to make tests finish.
ExUnit setup and teardown happen once per test, not once per generated case.
Use per-case setup/teardown or `Hegel.on_cleanup` for fixture ownership.
The shared test helper `Overalls.HegelFixtures` stops only the supervised PID
owned by its case and refuses to stop a replacement using the same child ID.
The pinned `string` kind accepts an explicit character list; pass
`Enum.to_list(?a..?z)` for lowercase ASCII. A Range is not that alphabet and
falls back to printable ASCII. `member_of` also requires a list; use
`integer(0..2)` for that integer domain. Slow real-I/O histories may select the
CI profile at their actual runner boundary without reducing cases or deadlines.
Review effective settings from the linked NIF. Since `8fe9786`, unspecified
randomness and database settings inherit the selected profile; older frontend
setter behavior does not establish the current settings. Keep full case budgets
when using the CI profile for demonstrated slow external I/O, and document the
reason. Size a finite aggregate ExUnit timeout from measured workload duration;
preserve per-operation deadlines. The profile name alone does not establish
execution scope or a passing result.
At the historical `08cd428` pin, the shared-lock distributed property retained two generated
cases and all three rotations per case under its scoped CI profile. Its selected
run passed in 26.9 seconds at ExUnit seed 770435. The prior full `f1ad336` scan
failed only its TooSlow heuristic after two valid inputs in 34.511763231 seconds;
the profile repair changes no clocks, peer count, lock barrier or oracle.
Draw labelled values
once at the property boundary instead. Protocol's
[`TestProperties.draw/2`](../../protocol/test/support/test_properties.ex) obtains
the native test case, records only the literal label and a redaction marker, and
uses `:hegel.draw_silent/2`. Shrinking and the original exception remain native;
[`hegel_support_test.exs`](../../protocol/test/hegel_support_test.exs) verifies
failure replay without printing the synthetic payload. A fixed seed reproduces
the same setup, draws and cleanup sequence without exposing a replay blob.

Generators must be bounded and typed. The pinned native integer primitive accepts
signed 64-bit bounds; protocol's
[`TestGenerators`](../../protocol/test/support/test_generators.ex) composes 32-bit
halves to retain unsigned GUIDs and upper-half refusal cases. Its strings preserve
explicit alphabets and character counts, including Unicode controls for sanitizer
tests. Its peer terms retain bounded scalar, nil, list, map and tuple shapes without
arbitrary atoms or BEAM resources. Use native `list(generator, min: ..., max: ...)`
and `tuple([...])` forms rather than assuming StreamData options are implemented.

Every generated case owns its mutable fixtures. Start SQL sandboxes, processes,
sockets, temporary directories, registries, and node connections in per-case setup;
release them in teardown even when the body raises or a command is rejected. Cleanup
failures remain visible. Do not let process-dictionary convenience hide ownership or
make a replay depend on another case's state.

Stateful properties separate command generation, model transition, system action,
postconditions, and invariants. Concurrent properties use controlled schedules and
check the resulting history against a reference model or linearizability oracle.
Rejected commands are discarded as assumptions; assertion failures and cleanup
failures fail the case. Redact drawn values, exception terms, payloads, terminal bytes,
credentials, and replay blobs by default; report only safe labels, locations, seeds,
and bounded structural metadata unless a test explicitly opts in.

Run a focused property or replay before the application's `mix precommit`. Protocol
changes require both Marshall and Lilly consumer gates. Preserve contract, ADR,
logging, and machine-test evidence boundaries when reporting results.

Protocol's `workspace_source_test.exs` and `view_test.exs` still use StreamData.
The application migration remains partial until these properties and the wider
native-engine obligations have passing execution records.
