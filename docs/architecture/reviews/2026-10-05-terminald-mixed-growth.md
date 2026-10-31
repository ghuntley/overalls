# Terminald mixed pressure, growth and admission

## Scope and architecture impact

Integrated baseline `e3598d11be20498968fc21da993a5459f4b96890`, ADR-0082.
This batch adds a test-only property using the pinned native output helper
published by the standalone growth batch. Production capacity configuration,
protocol and authority are unchanged. The accepted decision remains partial;
this is Linux PTY/socket contention, not authenticated guest or hosted evidence.

## Independent history and oracle

The fixture configures an 8 MiB total budget, 1 MiB initial reservations and
4 MiB maximum rings, retaining the production pump, create and growth paths.
A filler session first grows to 4 MiB. A distinct viewer with a reduced socket
send buffer withholds reads until its actual queue exceeds the generated
32767/32768/32769-byte watermark. It remains stalled at each subsequent checkpoint.

A barrier starts two to four create contenders and a healthy output worker.
The worker emits two complete 4 MiB-plus-boundary phases, checked by exact
streamed NUL counts and an echo-independent completion marker. Scheduling may
leave the healthy ring at 1 or 2 MiB: successful creates must consume exactly
the remaining whole reservations. The 4 MiB growth step must be refused because
it cannot fit alongside the filler and stalled neighbor. All workers join
before assertions; refused creates must return the capacity error.

An independent map of IDs and expected limits checks every survivor, the exact
reservation sum, actual backing bound and viewer permits. Retiring the filler
returns exactly 4 MiB. The healthy session must then grow to 4 MiB while the
neighbor remains stalled; exact replacement creates fill the remaining quota.
Fresh healthy output must still complete at full quota. Final owned retirement
returns registry, quota and viewer counters to zero with peers still open.
Snapshots release locks before asserting, and cleanup retires owned sessions on
early failure. No payloads or tokens enter diagnostics.

## Verification

The initial native check passed all 51 tests in 6.06 seconds and Clippy with
warnings as errors. Nix completed in 35 seconds, archive
`1791193476680-62307-0.jsonl`; log
`/tmp/overalls-terminald-mixed-growth-native.log`.
Formatting, the growth callee contract and a clearer refusal diagnostic followed.
The final native gate passed all 51 tests in 5.47 seconds and Clippy; Nix completed in 79 seconds,
archive `1791193646259-98527-0.jsonl`; log
`/tmp/overalls-terminald-mixed-growth-final-native.log`.
Contract format and discovery passed. Self-review traced production creation,
grow-before-append, reservation refusal, viewer pressure and owned retirement;
the oracle permits either legal race winner and uses independent capacity
arithmetic to require exact total admission. No semantic blocker was found.

The isolated control replaces only growth's aggregate maximum with `usize::MAX`,
preserving its exact increment and the create guard. Mutation-only patch SHA256
`e0cfc35ac76b7722be7eba07b57609d688df97b75252063ce1b2855116a21a65`.
Only the mixed property was selected. The smaller-fixture control failed the
intended refusal assertion: healthy retention reached4194304 bytes although that
growth step could not fit. Counterexample contenders2, boundary32767,
watermark32767; one failure,50filtered,162.22seconds. Nix207seconds, exit1,
archive `1791193758229-106975-0.jsonl`; log
`/tmp/overalls-terminald-mixed-growth-mutant.log`. No inconsistent-outcome
diagnostic was reported. At that stage the expanded-source rerun and integrated
gates remained pending. The production worktree retains the ordinary bound.

## Remaining gaps

The original configuration makes the boundary reachable with a small live set;
the later default extension adds the configured 64 MiB/watermark witness below.
Pressure is checked at explicit checkpoints, not continuously instrumented.
Authenticated vsock, Firecracker/browser composition, RSS/allocator peaks,
host recovery, many-viewer sustained throughput and hosted faults remain open.

## Default capacity extension

Every draw now also includes the configured 64 MiB total, 8 MiB maximum and
1 MiB viewer watermark. Seven filler sessions grow to 8 MiB. Finite pressure
at the default watermark grows the stalled session to 2 MiB before it blocks;
the independent map requires that exact reservation. Six create contenders
race healthy output. Legal healthy limits are 1/2/4 MiB, and create successes
must fill exactly the remaining capacity. An 8 MiB healthy growth step cannot
fit before retirement. Retiring one filler permits full healthy growth and
exact replacement admission. The default extension's native gate passed all51
tests in10.24seconds and Clippy, Nix56seconds, archive `1791193885814-120500-0.jsonl`; log
`/tmp/overalls-terminald-mixed-growth-default-native.log`. The earlier 8 MiB
evidence retains its narrower scope.

The expanded-source control failed the same intended refusal with limit4194304,
contenders2/boundary32767/watermark32767: one failure,50filtered,169.07seconds.
Nix204seconds, exit1, archive `1791194029064-181559-0.jsonl`; log
`/tmp/overalls-terminald-mixed-growth-default-mutant.log`. The failure occurs in
the smaller family before its subsequent default witness; it establishes oracle
sensitivity for that history, not a separate default-family counterexample.
The mutation and test filter remained isolated from production worktrees.
After retaining the patch and execution archives, the disposable mutant worktree
was removed. A fresh review attempt was rejected by the agent thread limit;
self-review additionally checked the default2MiB stalled reservation, legal
1/2/4MiB healthy outcomes, exact success arithmetic and all joined workers.
No source/contract blocker was found. Integrated Marshall execution remains
completed after integration with the published standalone growth suite; exact results follow.

## Integrated final verification

The combined native gate passed52tests in22.00seconds and Clippy with
warnings as errors. Nix completed63seconds, exit0; archive
`1791196431220-1589999-0.jsonl`, log
`/tmp/overalls-terminald-mixed-growth-merged-native.log`. This includes both
standalone actual-growth and mixed-pressure properties against the merged source.

Marshall full precommit passed1451checks (237properties,1214tests), two
exclusions, seed673050,1780.4seconds. Browser-state gates passed. Forced
Dialyzer passed with zero errors, skips or unnecessary skips in63.38seconds;
its PLT rebuild took4m22.37s. The complete command exited0; log
`/tmp/overalls-terminald-mixed-growth-marshall-precommit.log`.
Repository hooks and evaluated HLDD passed before final evidence reconciliation;
archive `1791196519621-1629361-0.jsonl`,35seconds. Final receipt/hooks and evaluated HLDD
verification passed, exit0, Nix34seconds, archive
`1791199276099-3111714-0.jsonl`; log
`/tmp/overalls-terminald-mixed-growth-publication-hooks.log`. Final source review found no architecture or
contract mismatch: only a test module was added, all race workers join before
assertions, snapshots release locks before asserting, and exact independent
capacity arithmetic permits each legal scheduling result. Authenticated guest,
RSS, sustained many-viewer throughput and hosted acceptance remain open.

## Correction (2026-10-30): oracle scheduling assumptions

Buck2 CI run 41143401371 at `b34d4c37a` failed the default family:
`ring_total` was 60817408 against an expected 61865984. Production accounting
was correct. The reservation equalled the sum of actual ring capacities, but
the oracle above wrongly required the stalled session to reach 2 MiB. Growth
reserves only when a read finds the ring already full. At a 1 MiB watermark,
the read that first fills the ring can also lift the queue over the watermark,
and the pump then pauses before another read. A local probe at the default
1 MiB unit and watermark left 2 of 20 stalled sessions at 1 MiB, and 3 of 40 at
a 64 KiB unit. Every probe matched `ring_total` to the actual capacity. Under
the pump's session lock, the oracle now accepts a stalled limit of one or two
units when the watermark is at least one unit, and exactly one unit below it.
Exact reservation, capacity and backing assertions are unchanged.

A full-suite rerun exposed a second oracle race in the smaller family:
5242880 reserved against 4194304 expected after the filler retirement. The
growth helper returned at the completion marker, before the shell's next
prompt. When that prompt reached a full healthy ring after the retirement had
freed quota, the ring grew outside the checkpoint. Each growth round now sets
an octal-escaped prompt marker and waits until it is read. Probes saw no bytes
after that prompt in 48 rounds. All 61 terminald tests passed with
`--test-threads=1`, and the mixed property passed six further runs. These
are local Linux PTY results; the remaining gaps above still apply.
