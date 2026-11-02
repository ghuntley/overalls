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
was pushed and initially pinned. Its 182 tests, release build,
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
and all 48 Covenant obligations. Audi's separately quarantined
`Audi.Inception.AuthorityTest` also retains its documented Inception failure;
neither application's known failures were changed. The direct ADR checker
passed all 264 decisions.
All four selected machine targets passed. The two-node fixture uses local TLS;
Tailscale Serve, ACL/certificate behavior and the live recovered thread require
independent operational verification, recorded below.

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

## Live-provider acceptance and response-header correction

Commit `91c972b6a3f7b128eaf2d2a6debb92e60555be17` passed the normal commit
hook and both exact-revision host builds, then was pushed to trunk. Panterloons
and Dungarees activated it in that order and reported healthy, with the exact
revision verified through each running system. The updater's enrollment check
requires its timer to be active, so the held timer was restored on each host
immediately before its manual update. No enrollment guard was bypassed.

From Dungarees, an unauthenticated Panterloons model request returned 401 with
successful TLS verification. An authenticated live inference completed with
HTTP 200, assistant output and echoed UUIDv7
`01a19bb1-99a1-7980-912a-b7a7096a8713` in 8.7 seconds.

The first guarded repair submitted turn
`01a19bb1-df03-7d67-ad4e-7d458c6ff6b9`. Its model call
`01a19bb1-eb09-75b4-9f23-d1775b844774` correlated across Marshall admission,
Ziggy and Underclass. Underclass completed HTTP 200, but Ziggy reported
`invalid_response`. A bounded schema-only probe established that the provider
returned SSE with `Content-Type: application/json`. The direct probe had parsed
the body independently of that header; Ziggy correctly selected its JSON parser
from the advertised media type. The failed repair and its receipt remain intact.

Underclass already classifies an explicit streaming request as a stream despite
an incorrect upstream media type. The follow-up correction applies that same
classification to the outgoing response header, including held overload replay.
It preserves the existing SSE contract, retry proofs and non-stream/error paths;
it introduces no new architecture decision. The two-node regression now makes
the provider advertise JSON for its real SSE body so this mismatch cannot hide
behind a well-formed fixture. Follow-up execution and live recovery remain to
record.

Underclass follow-up
[`3295cb52dc0b8ab17442112ee0a645f76f1bea45`](https://github.com/ghuntley/underclass/commit/3295cb52dc0b8ab17442112ee0a645f76f1bea45)
was committed and pushed and is the final Overalls source pin. All 183 upstream
tests, formatting, compilation, the locked release build and contract checks
passed. The HTTP regression verifies missing and incorrect media types for both
successful output and certified overload replay, byte preservation, UUIDv7
correlation, and unchanged JSON/error responses. No dependencies changed.
The pin tool fetched and verified the new source hash and reconfirmed the
unchanged Cargo hash. An IPv6 fetch timeout was resolved only inside the
isolated build network namespace; host networking was not changed.

With this final pin, the two-node mislabeled-SSE regression passed, including
its composed Python type/lint checks and one-attempt startup completion. The
Underclass SLO machine test also passed (batch
`b7b26902-702b-478e-aed2-47b687e1b0c4`). Service lifecycle and agent-fleet
reruns are still in progress at this commit; final acceptance is recorded after
their completion and deployment.
