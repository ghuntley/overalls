# ADR-0087: Native compact Nix build output and indexed local evidence

- ID: ADR-0087
- Date: 2026-09-21
- Status: superseded
- Implementation: implemented
- Components: Nix CLI, NixOS, development shell
- Supersedes: none
- Superseded by: ADR-0159, ADR-0281

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for the preserved legacy `overalls.nixCompact.enable` option and adapters. ADR-0159 carries every other requirement of this record forward unchanged.
> [ADR-0281](0281-nix-compact-own-package-input.md) supersedes only its use of overalls' development/stable package sets: overalls now uses the package nix-compact builds from its own pinned input.

## Context

Build output consumed by coding agents spends input tokens on routine progress
and repeated diagnostics. Sleeping between writes only delays the same volume.
The user authorized a source-patched Nix, shared by NixOS and devenv, with saved
logs, bounded diagnostic context, stable line references and targeted retrieval.
Both currently pinned package inputs select Nix 2.34.8 and the same source.
Application error messages, including expected-error tests, are not build results.

## Decision

The user subsequently authorized extraction into the public
[ghuntley/nix-compact](https://github.com/ghuntley/nix-compact) repository. The
native implementation and Hegel tests now have that single source of truth.
Overalls consumes a pinned flake and retains thin package/check and NixOS option
adapters. Its supplied development/stable package sets and default-on legacy
option are preserved; the standalone NixOS module itself is explicitly opt-in.
This changes source ownership and dependency wiring, not the accepted logging,
privacy, output-budget or build-result decisions below.

Compile capture, classification, compact presentation and a bounded build-log
reader into the Nix CLI. Enable compact presentation for ordinary `nix build`;
honor explicit log formats and full-output selection. Capture received diagnostic
and builder output before presentation filtering, requesting builder logs over
existing local/daemon/remote paths without changing their wire protocol.

Write a private versioned JSONL session archive below
`${XDG_STATE_HOME:-$HOME/.local/state}/nix/build-logs`. Archive records preserve
physical payload lines, available activity identity, stable global line numbers
and receipt time. Non-UTF-8 bytes have an explicit reversible encoding. Multiline
messages have a common event identifier. A completion footer records the actual
process result; its absence means incomplete. A rebuildable sparse index may
accelerate retrieval but never becomes the only route to evidence.

The console advertises suppression and the absolute log path, explains `L#` log
lines and `D#` diagnostic references once, and emits at most one 160-byte progress
line every 15 seconds. Diagnostic details have a non-refilling 12 KiB invocation
budget and 4 KiB excerpt budget. Context is up to 20 preceding and 20 following
lines from the same build, bounded by time and diagnostic boundaries. Prioritize
the primary message and source explanation, merge overlapping context and count
exact repetitions. Reserve 2 KiB separately for actual completion/failure.
Low-confidence word matches and their context may use at most 4 KiB of the
diagnostic budget, preserving capacity for higher-confidence diagnostics.

Classification uses native Nix severity, Elixir LoggerJSON `severity`, Rust
tracing `level`, Cargo compiler-message `message.level`, recognizable text formats
and finally lower-confidence error-like phrases. Recognized severity wins over
payload words. Classification controls presentation only. A successful Nix result
remains successful regardless of application error events.

The reader returns at most 100 lines and 8 KiB by default, supports diagnostic,
line-range and build selection, and emits a bounded continuation command on
truncation. Filters preserve global line numbers. Original-payload output is
available explicitly. Captured logs are local build evidence, not fleet log
sources; do not add arguments/environment metadata or weaken producer redaction.
Completed-session retention is configurable by age and aggregate size; active
sessions are not truncated or pruned. Capture errors announce visible-output
fallback rather than claiming successful retention.

## Alternatives

Shell aliases do not reliably cover agents and cannot access activity identity.
A wrapper was explicitly rejected in favor of native Nix. Quiet-only output
loses discovery and context. Unlimited immediate errors still exhaust tokens.
Regex-only detection misclassifies structured payloads and misses severity
schemas. Retaining only failure tails loses evaluation and cross-build context.
Automatically forwarding build logs broadens their custody without authorization.

## Consequences

Nix CLI source patches and two pinned-package builds require ongoing maintenance.
Archives cost disk space and I/O. Lossless capture cannot promise zero backpressure
on a slow disk. Some diagnostic candidates are intentionally omitted from the
console during floods; their archive references and counts remain available.
The archive records received output, not disabled source verbosity or historical
logs of substituted builds. Physical-line context may still mix processes inside
one derivation. Log parsing must bound memory, depth and rendering expansion.

## Invariants and verification

- Error-like strings never alter status, scheduling or subsequent builds.
- Noisy success and unique-error floods meet byte/line budgets; every received
  record remains recoverable, including malformed and non-UTF-8 input.
- Concurrent builds retain correct activity context and stable references.
- Structured Elixir/Rust severity, multiline diagnostics and precedence work.
- Pinned Hegel property tests generate arbitrary payload bytes, severity/payload
  combinations, interleaved activities and diagnostic floods. Shrunk failures
  report reproduction blobs. The C ABI exercises the actual C++ implementation;
  independent archive decoding and budget accounting act as the oracles.
- Quiet builds heartbeat; interruption leaves honest completion state.
- Reader pagination handles filters and oversized records without skipping data.
- Archive failures visibly fall back; retention preserves active sessions.
- Explicit machine formats, JSON stdout, output paths and full streaming work.
- Verify local, daemon and remote paths and both pinned Nix variants; NixOS and
  devenv must resolve the custom executable. Measure console bytes against stock
  Nix on equivalent builds, separately from archive completeness.

## Implementation evidence

- The [native package override](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/default.nix)
  compiles the [logger and command adapter](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/native.hh)
  into Nix's CLI component, preserving daemon libraries and wire protocols.
- The [archive](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/archive.hh),
  [classifier](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/classify.hh),
  [presenter](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/session.hh) and
  [reader](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/reader.hh) implement local capture,
  stable references, budgeted presentation and bounded retrieval.
- The [Hegel properties](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/property-test.cc) pass
  1,000 generated core cases and 50 real-build cases in each pinned-input
  native check (`nix/domains/artifacts/nix-compact/native-check.nix` at overalls revision `9fe1e493`, repository deleted). Runtime checks
  cover JSON/path stdout, TTY/raw formats, startup and mid-write capture fallback,
  evaluation diagnostics, quiet-build heartbeat, SIGINT, a Unix-socket daemon and
  both remote builder protocols through Nix's localhost transport fixture. These
  are protocol-path tests, not physical-host deployment. The reader also rejects
  oversized completion-status integers instead of narrowing them to success.
- One 10,000-line fixture retained every builder line while reducing stderr from
  359,114 to 609 bytes (over 99.8%). This measures console bytes, not tokenizer
  counts, and is not a workload-wide performance guarantee.
- The [NixOS module](../../../nix/domains/system/nix-compact.nix),
  [development shell](../../../devenv.nix) and [flake](../../../flake.nix)
  select/export the package. The [configuration check](../../../nix/domains/artifacts/nix-compact/configuration-check.nix)
  verifies default selection, opt-out, explicit overrides and unchanged daemon
  libraries. Both complete packages build with upstream gates retained; the
  development-input functional suite reports 201 passes, zero failures and eight
  upstream skips. Actual development-shell resolution and all enrolled/base host
  configuration selections were checked. Header-only cache invalidation was
  verified by changing a comment, evaluating, restoring it and comparing results.
- The [guide](../../development/nix-build-logs.md) documents invocation/reader budgets, local
  evidence, opt-outs and retention. The [completion review](../reviews/2026-09-21-compact-nix-build-logs.md)
  maps requirements to tests and records operational boundaries. The
  [upstream contracts](https://github.com/ghuntley/nix-compact/blob/9e43798f4ebf1b969432b6e1eb9f8a0bdf69fede/package/CONTRACTS) define the corresponding
  implementation obligations; structural validation alone is not runtime proof.
- The consumer adapters (`nix/domains/artifacts/nix-compact/default.nix` at overalls revision `9fe1e493`, repository deleted) and
  [lock resolver](../../../nix/domains/artifacts/nix-compact/source.nix) delegate to the
  root flake's immutable source revision. The
  [extraction review](../reviews/2026-09-21-standalone-nix-compact.md) records
  standalone publication, cold-store evaluation and consumer migration evidence.

## Open questions

None. Existing fleet hosts receive the configured package on their normal
rebuild/activation; this change does not claim a live fleet rollout. Capture
preserves received log events, not source-disabled or pre-command startup output.

## Related decisions

- [ADR-0042](0042-host-observability.md): source-side diagnostic protection and
  explicit custody of restricted evidence remain unchanged.
- [ADR-0086](0086-reciprocal-nix-caches.md): build placement and cache policy remain
  unchanged; remote capture tests do not re-enable fleet build delegation.
