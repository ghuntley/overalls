# User threads architecture review

## Decision and impact

This change has material architecture impact: it adds a persisted Ash domain,
cross-domain Compute/Agents coordination, a new lifecycle owner, user-facing
routes and a new authorization boundary. ADR-0174 records the accepted
ownership and recovery model. Existing machine-scoped agent threads remain the
execution primitive inside the new boundary.

## Evidence reviewed

- `Marshall.Threads.Thread` persists objective, mode, machine specification,
  create idempotency key, machine admission key, lifecycle state and bound
  machine/agent identities. PaperTrail retains changes to the binding.
  The initial additive migration left the machine key nullable. Following
  confirmed expansion convergence, the dependent migration backfilled late null
  rows and enforced `NOT NULL`; the resource requires an explicit machine key and
  removes the row-key fallback. Both hosts now run this contraction, and read-only
  SQL confirmed the deployed constraint and zero null rows.
- `Marshall.Threads.ProvisionWorker` claims the thread under a row lock, uses
  Compute admission and idempotency, records the admitted machine identity,
  waits for an observed running VM, binds the
  automatically registered agent root/thread, and submits the initial objective
  with a stable thread-scoped request key before readiness. Binding or objective
  failure requests VM cleanup through the existing Compute lifecycle.
  Machine keys fence writes from retired provisioning attempts, and replacement
  admission waits for physical cleanup of the previous machine.
- `Marshall.Threads.ArchiveWorker` leaves the thread deleting until retained
  Compute history reports VM archival.
- `Marshall.Threads.Coordinator` filters reads by creator/team membership and
  delegates prompts and deletion to current machine authorization/lifecycle.
  Creation uses an advisory lock and compares the creator, objective, mode,
  team and canonical machine specification before accepting an idempotent replay.
  Archive and delete share the deletion lifecycle. Reopen requires an archived
  thread, clears the retired binding, preserves its original create key, assigns
  a fresh machine key and queues admission. Thread state and its durable job are
  inserted in the same transaction; Compute provisioning runs after commit.
- `Marshall.Threads.events/3` rechecks user-thread visibility and validates the
  current agent root/thread binding before returning retained transcript events.
  The helper allows authorized archived reads without granting prompt or terminal
  access to a deleted VM.
- `/threads` routes expose pending, failed, ready, deleting and archived states,
  polling, activity filtering and lifecycle controls. Semantic markup and
  LiveView streams use ADR-0161's monospace presentation. List, detail and
  transcript reads distinguish unavailable data from an empty result, and
  missing or unavailable detail refuses mutation events. Diagnostic events
  contain closed outcomes and identifiers rather than objective or terminal
  payloads. Creation puts objective and mode first, with machine settings in a
  closed details disclosure so the primary flow describes the work to perform.

## Expansion convergence and required-key contraction

On 2026-10-15, both hosts reported healthy at exact revision
`d5e03c080204a33a11b8c136e983593630e4fccf`: Dungarees at 22:10:36 UTC and Overalls
at 22:15:44 UTC. The deployed nullable `machine_key` schema and backfill were
confirmed, and TLS readiness was healthy. This establishes ADR-0159's convergence
prerequisite for the dependent contraction. It does not establish native teardown
or the complete lifecycle across reopened generations.

One recovery of the reported failed production thread was verified against that
deployed expansion revision. Exactly one authorized public retry was issued;
subsequent read-only SQL inspection showed thread
`01a13ffe-bcd2-7fa3-9545-ea5551f9c01f` ready and its VM
`beedd015-9ac4-4b72-8b15-89a7b213d2cb` both desired and observed running. Exactly
one VM existed for its machine admission key, exactly one initial objective turn
completed without a failure, and the provisioning and title jobs completed.
No objective, prompt or transcript contents were included in the evidence. This
is one deployed retry-to-ready and initial-turn completion, not native archive,
reopen, worker-loss or provider-failure acceptance.

The follow-up
[`20261015230000_require_thread_machine_keys.exs`](../../../marshall/priv/repo/migrations/20261015230000_require_thread_machine_keys.exs)
backfills null keys before enforcing `NOT NULL`; the Ash resource requires the
attribute and coordinator/workers read it directly. The expansion already wrote
keys on create, replacement retry and reopen, so it remained compatible while the
new constraint migration ran. The row-key fallback is removed. Provisioning and
archive jobs must also carry the
matching machine key; malformed unkeyed jobs are cancelled, and authorized public
retry creates a current keyed job.

The production contraction preflight used read-only SQL and found no threads
with null machine keys, no active provision/archive jobs without a key, and no
active provision/archive jobs in total. Historical unkeyed provision jobs were
five completed and eight discarded jobs, which do not run automatically. These
observations support removing the unkeyed execution path; they are point-in-time
observations rather than a general queue-drain guarantee.

The contraction was deployed as
`32624e1bf80df120beb69b923eee4362427aee23`. Dungarees reported healthy at
22:29:29 UTC and Overalls at 22:33:39 UTC on 2026-10-15. Read-only observations
between 22:35:55 and 22:36:04 UTC confirmed both hosts healthy on that exact
revision and TLS readiness healthy. At 22:35:55 UTC, SQL reported
`machine_key` nullable `NO` and zero rows with null keys. This completes the
dependent rollout obligation under ADR-0159.

The same read-only inspection confirmed the reported thread remained ready with
the same VM desired and observed running, one VM for its admission key, and one
initial objective turn. The original turn
`01a141a3-8bda-7dac-92c5-9fd2c12d25e7` remained completed. No new retry or prompt
was issued during this verification. This establishes continuity through the
constraint deployment, while native archive/reopen and fault recovery retain
their separate gaps.

The subsequent fixture and handbook release
`3c36a622774baf696b1503d71bbd8d91848d13a2` converged healthy on both hosts by
22:52:02 UTC, with zero updater failures. TLS readiness and read-only SQL again
confirmed the required key, zero null rows, the same ready thread and running VM,
and the same completed initial turn, with one VM and one turn for this generation.
The production thread implementation is unchanged from `32624e1bf`.

Five focused cases in
[`threads_machine_key_test.exs`](../../../marshall/test/marshall/threads_machine_key_test.exs)
are present: resource creation rejects an omitted machine key, and PostgreSQL
rejects setting it to null; provisioning and archive workers refuse missing or
malformed keys before changing state; and an archive job from an older generation
leaves the current generation unchanged. All five passed in the final focused run
below. The local schema tests and the later deployed SQL observation are distinct
evidence for constraint enforcement and fleet activation.

The follow-up browser observer passed 20 synthetic workspace combinations: five
pages in two themes at two viewport sizes, plus four expanded machine-settings
views. The 24 screenshots verified that machine settings are closed by default,
mode remains visible, profile stays hidden until expansion, and the seeded image
is selected. The inspected
[`ThreadsLive` source](../../../marshall/lib/marshall_web/live/threads_live.ex)
SHA-256 was
`82b42dd43f1b34140ca84b7c12849e618052500d66b7ee3665b73f432fabed48`.
Its standalone artifacts were written outside the repository and are not durable
tracked evidence. This observation checks presentation with synthetic lifecycle
data; it does not exercise production VM provisioning or establish cross-device
runtime acceptance.

## Remaining findings

- **Medium — previous transcript generations:** `reopen` clears the current agent
  binding, while `Marshall.Threads.events/3` resolves only that current binding.
  PaperTrail and Agents retain the old identities and events, but the current
  workspace cannot browse those transcripts after reopen. ADR-0174 requires
  retained history; add an authorized generation selector and retrieval path
  before claiming complete transcript continuity across reopened machines.
- **Verification gap — lifecycle recovery:** the row-lock, readiness and archive
  paths require native teardown and worker-loss histories. Unit tests cannot
  establish physical deletion, isolation, cross-node replay or production model
  availability under ADR-0174.

## Verification and gaps

Focused mode, machine-spec, title, idempotency, authorization, worker-replay,
reopen and LiveView tests are present, along with owner/team/stranger archived
transcript tests. Five database-backed lifecycle cases are present in
[`threads_lifecycle_test.exs`](../../../marshall/test/marshall/threads_lifecycle_test.exs):
create replay across archive/reopen, retention of a pending VM binding until
deletion, refusal to equate delete intent with completion, one initial objective
per reopened machine with stale-job fencing, and cleanup before retry rotates
the machine key. These tests inject execution outcomes; they do not run a native
VM or establish physical deletion.

On 2026-10-15, the working integration snapshot before its final commit passed
31 focused tests with zero failures in 5.2 seconds, seed `962357`. The run covered
[`threads_test.exs`](../../../marshall/test/marshall/threads_test.exs),
[`threads_lifecycle_test.exs`](../../../marshall/test/marshall/threads_lifecycle_test.exs),
[`threads_transcript_test.exs`](../../../marshall/test/marshall/threads_transcript_test.exs),
[`threads_live_test.exs`](../../../marshall/test/marshall_web/threads_live_test.exs)
and [`agent_threads_live_test.exs`](../../../marshall/test/marshall_web/agent_threads_live_test.exs).
`mix monospace.check` and `mix workspace.check` also passed, including eight
JavaScript tests. The final warnings-as-errors compilation passed and formatting
completed. These historical results cover the initial working source snapshot;
the following required-key run provides the committed anchor for its five files.

The required-key working snapshot based on expansion revision
`d5e03c080204a33a11b8c136e983593630e4fccf` subsequently passed 32 focused tests
with zero failures in 3.0 seconds, seed `659069`, maximum four cases. It covered
the same thread, lifecycle, transcript and workspace test files above, plus
[`threads_machine_key_test.exs`](../../../marshall/test/marshall/threads_machine_key_test.exs);
the separate machine-scoped `agent_threads_live_test.exs` was not included in
this follow-up run. Distributed, host and capacity tags were excluded. The new
required-key test file SHA-256 was
`c10d21b03e6447d4ec1d26a05e0a2d454458ee77f6809831a4e54072cc1dbe33`, and the
dependent migration SHA-256 was
`450b7dc67e5dafb84e163cbdd728facf4434bd17bc5949f4152d8348402b56ab`.
Development warnings-as-errors compilation also passed. This run establishes
local resource/database enforcement, strict job-key refusal and bounded
lifecycle/UI behavior. Its unchanged thread implementation and test sources were
committed in `32624e1bf80df120beb69b923eee4362427aee23`; the recorded test,
migration and UI digests above match that revision. All 32 focused tests passed
for the source committed in `32624e1bf80df120beb69b923eee4362427aee23`.

At that revision, the Nix `hldd` check and all-files prek checks passed, as did
`mix monospace.check`, workspace TypeScript validation with eight JavaScript
tests, and 32 terminal JavaScript tests. These structural and bounded tests do
not establish native thread recovery. Forced Dialyzer subsequently passed with
zero errors, skipped warnings or unnecessary skips, taking 1 minute 24.46 seconds
after its local PLT rebuild.

The final full `mix precommit` run included distributed tests and retained the
host/capacity exclusions. With seed `363476` and maximum four cases, its test
phase completed in 1552.9 seconds: 1525/1528 passed, comprising all 240 properties
and 1285/1288 tests, with four excluded. Two clone-ordering peer startups failed
during scratch PostgreSQL connection exhaustion before any clone operation ran.
The third failure was the old editor-connection fixture, already loaded before
its correction in `f436e438aed5acd1e70813a6467482450695f274`. The older expansion
run was interrupted to release its scratch database connections; it produced no
final result. The fixture-only correction changes no production behavior or
thread test source.

The full alias continued through passing terminal, workspace and presentation
checks and forced Dialyzer, which reported zero errors, skipped warnings or
unnecessary skips in 1 minute 20.6 seconds. Its final exit status was 2 because
of the three recorded test failures; this was not an entirely green single run.

After removing the competing run, an isolated serial rerun of
[`clone_ordering_test.exs`](../../../marshall/test/marshall/compute/clone_ordering_test.exs)
and the corrected
[`editor_workspace_test.exs`](../../../marshall/test/marshall_web/editor_workspace_test.exs)
passed all 17 tests, including every failed case, in 12.8 seconds with seed
`264941` and maximum one case. Distributed tests remained included and the
`threads_verify` database partition isolated this rerun. There was no connection
exhaustion. No unrelated clone implementation change was made. The final ADR,
HLDD receipt/options/coverage/views, Nix `hldd` and all-files prek checks also
passed for the deployment-evidence update.

Native machine
isolation and teardown, generated worker-loss/idempotency histories, cross-node
reconciliation, browser acceptance across devices, and broader title/model
provider acceptance remain unverified. The production retry and completed initial
turn above establish only their stated case. At that verification boundary,
ADR-0174 remained accepted and partial. ADR-0175 subsequently replaces only its
authority clauses, as recorded in the
[sharing review](2026-10-16-thread-sharing.md).

## Conversation presentation follow-up

This assessment covers the presentation portion. The subsequent sharing extension
has material authority and persistence impact under
[ADR-0175](../decisions/0175-thread-sharing-and-bound-machine-authority.md),
reviewed separately in the [sharing review](2026-10-16-thread-sharing.md).

The follow-up presentation change stays within ADR-0161 and ADR-0174. It changes
the Threads template, bounded list filtering, presentation helpers and page
stylesheet without changing domain boundaries, persistence, routes,
authentication, authorization, machine admission or lifecycle coordination.
No architectural decision changes for this portion. The
objective composer and conversation receive the main visual emphasis; machine
settings and lifecycle actions use disclosures, and status events use readable
labels. The ready-thread reply composer precedes the transcript, whose authorized
events are displayed newest first. The thread index, recent-thread rail and
activity rows retain the existing bounded streams and domain authority. Index search matches titles and
objectives without case sensitivity; all/active/archived filtering operates only
on the current authorized keyset page. The index and activity rail expose First
page/Next page controls for 50-item pages; each cursor is issued by the
authorized domain query and cannot expand read authority.

A ready thread's Open VS Code action uses a fresh authorized Compute projection
and the shared editor eligibility helper. Opening the existing machine editor
route still checks current Editor authority; the visible control grants none.

Managers can invoke the existing Archive/Delete lifecycle actions while a
thread is pending or provisioning, so a stuck admission can be cancelled from
its detail view. The domain still rechecks current manage authority and leaves
the thread in archived or deleting state according to whether a machine was
admitted.

The machine navigation drops its Agents tab. Direct machine-agent routes and
their existing backend authority remain available; global Threads becomes the
primary visible entry point for agent tasks.

The terminal remains available as a link to the bound machine's terminal page
and now also has an opt-in, lazy embedded terminal disclosure. The activity
route keeps the recent-thread rail visible and supports bounded status, time,
owner, team and text filters over the current authorized keyset page. A
persistent global rail and project-specific filtering remain separate work.
Previous-generation transcript browsing is addressed by
the retained-generation selector below; native lifecycle/recovery acceptance
retains its separate gap.

The earlier focused thread suite passed 111 cases on 2026-10-16, including the initial
presentation and sharing LiveView assertions. The current follow-up suite passes 117 cases,
including keyset pagination, initial skill selection, pending lifecycle actions and the
activity-clock projection. Its exact command and bounded scope are recorded in the
[sharing review](2026-10-16-thread-sharing.md).
The maintained browser probe passed all 32 thread route/theme/viewport
combinations, four expanded settings views, four expanded sharing views and
36 collaborator role/state/theme/viewport combinations. Newest-first reading,
top composer, terminal/editor role gating, filters, live viewer revoke/restore,
unrelated-account refusal and presentation checks passed on synthetic fixtures.
The sharing review records exact source hashes and the native acceptance limits.
Earlier browser and test results above retain their original revision and scope.

## Retained generation transcript retrieval

The previous-generation browsing finding is addressed in the source tree. The
`thread_generations` migration backfills one durable row per existing thread;
provision, retry, archive and reopen keep that row synchronized and allocate a
new ordinal for each replacement machine. `Marshall.Threads.generations/2`
rechecks current thread authority, while `Marshall.Threads.events/4` resolves
the selected generation and validates the paired agent root, machine identity
and creator before reading retained events. `/threads/:id?generation=N` exposes
the same read-only selection in the workspace; prompt, terminal and editor
controls remain tied to the current generation. The transcript test covers
reopen continuity and unknown-generation refusal. Native archive/reopen,
cross-node recovery and physical isolation remain separate acceptance gaps.
