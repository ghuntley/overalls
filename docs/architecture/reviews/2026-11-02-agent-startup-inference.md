# Startup inference recovery, 2026-11-02

## Scope and findings

Machine `4495b893-267f-4d89-a277-8d9afa852fe0` admitted its initial prompt into
thread `01a19af3-e5ff-7cc1-aaad-a06b98f97a67`. Model call
`01a19af4-2bf7-746b-ac25-51a8b9a8c39a` reached Dungarees's empty Underclass pool
at 06:30:55 UTC and received 503 before provider selection. Resetting that call
to queued then reused an already-admitted request ID. Its second admission
failed and the result eventually became uncertain. This violated ADR-0100's
single-attempt durable-call requirement. Existing timestamp correlation was
insufficient because Ziggy omitted the shared request header.

The saved request completed through Panterloons's nine-account pool during an
authorized diagnostic probe. One pre-output overload preceded a successful
internal failover. This established destination feasibility, not deployment or
recovery of the user's thread.

## Architecture impact

[ADR-0280](../decisions/0280-remote-underclass-and-safe-agent-retries.md) supersedes
ADR-0100 and ADR-0102 while preserving their authority, monitor and secret-custody
rationale. ADR-0042 diagnostics, ADR-0174 thread admission, ADR-0178 context and
ADR-0246 fleet ownership remain unchanged. Underclass separately replaces its
UUIDv4 correlation ADR. No database or accounting protocol migration is needed.

The retry certificate is intentionally conservative: generic failover permanently
disqualifies a request, including harmless cases where pre-dispatch failure could
not be proved. Transport or collector uncertainty also prevents automatic retry.
The same completed receipt may be delivered again without repeating inference.

## Verification and deployment evidence

Underclass commit
[`0e85963ef7c950c637ae3a7f9e11c6873798cf15`](https://github.com/ghuntley/underclass/commit/0e85963ef7c950c637ae3a7f9e11c6873798cf15)
was pushed and is the exact Overalls source pin. Its 182 tests, release build,
format/check gates and UUID feature audit passed. The source and Cargo hashes
were refreshed and verified through the pin tooling. No UUIDv4 generation
remains in Underclass or the Overalls instrumentation applied to it.

Recorded passing checks:

- Marshall's final retry shard: 183 tests, two excluded, seed `4024449041`.
  The 100 generated SQL histories exercise real inference admission and
  completion, fresh identities, persisted delays and budgets, duplicate
  receipts, successful-step reset, fencing and uncertainty. They do not prove
  native isolation or tailnet operation.
- Marshall's full check gate, including forced Dialyzer (zero errors),
  formatting, logging, presentation, gettext and localization checks. The
  corrected UI shards passed 169, 125 and 160 tests, with all four stale cases
  verified. Their final formatting and per-file contract checks passed.
- All sixteen Marshall application shards passed across the original run and
  those corrected reruns: 2,281 tests/properties, five excluded; the repository
  shard passed 52. The known-failure shard retained three documented Inception
  failures (ten of thirteen passed, 36 excluded), without investigation or
  unrelated changes. This combined evidence does not certify the original
  aggregate or Covenant union, because the original run contained the stale UI
  failures; the final precommit run supplies that separate aggregate evidence.
- Ziggy's full check/test gate: 149 passing tests across four shards, all ten
  Covenant obligations, and zero Dialyzer errors. The compiler, formatter,
  logging and unused-dependency checks passed. The longest shard's seed was
  `1530296402`; its complete startup-validation matrix ran within the existing
  timeout, with no coverage or timeout change.
- Buck2 contracts, contract regressions, Python static checks, Ziggy logging
  and shared diagnostics checks; direct ADR/pin checks; generated graph docs.
- Ziggy, Underclass and enrollment configuration evaluations, and both host
  deployment targets. The preliminary bundles have no final Git revision and
  are not the deployment candidates.
- The real Underclass SLO and service machine tests, using the pinned package;
  the service test includes generated restart/reboot/authentication histories.
- The full agent-fleet machine test: a provisioning objective reaches one
  completed model call and turn, a Marshall restart does not duplicate initial
  admission, and an operator prompt reads a file in the real guest. The
  three-test Buck2 batch passed with no failures or skips (build
  `dfc152a9-555b-4f2e-9651-382709c43ee0`).
- The two-node Ziggy/Underclass machine test: verified remote HTTPS, a completed
  assistant result with one UUIDv7 through both services, separate proxy/admin
  authentication, and fresh-request recovery after ingress loss without replay
  (build `37fc0f77-5b51-4f7f-97a7-72e541ef558b`, one pass, no skips). Its composed
  Python driver passed type checking and lint.
- Secret inventory validation: all 52 encrypted documents, including the
  proxy-only Dungarees bundle.

The final changed-file precommit graph passed all 92 checks at 09:42:45 UTC
(build `38689fe9-a816-4a77-ab89-5cb598fa43f8`), including every Marshall shard
and its Covenant aggregate. The direct ADR checker passed all 264 decisions.
All four selected machine targets passed. The two-node fixture uses local TLS;
Tailscale Serve, ACL/certificate behavior and the live recovered thread require
independent operational verification. No production fix is deployed yet.

The broader Marshall gates also exposed stale test/catalog evidence from
`7d4728eb055bd192891d6d2a8fd41729cea7f2b1`, which hid unsupported browser-editor
actions without updating the corresponding expectations or catalogs. The
obsolete message and source references were removed from the template/locales;
four cases in three UI test files now require the unsupported action and notice
to be absent, while preserving the direct-launch authorization denial. No production editor
behavior or live translation changed.

An authorized read-only operator probe confirmed the original transcript still
contains only prompt, turn-start and turn-failed events. The machine remains
running on Dungarees with execution epoch 1 and its original placement. The
repair will submit through the normal thread action with a fresh stable key;
the uncertain original model call and failed turn remain retained.
