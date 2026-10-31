# Clone cancellation and current authority verification

Date: 2026-09-25. Campaign improvement 020; base `7f7ee2cb` in the isolated
`verify/020-clone-cancellation` worktree; integrated published `3f679eff` before
the corrected final gates. No production deployment is authorized
or performed. All credentials, databases, machines and barriers are disposable.

## Scope and existing evidence

ADR-0055 remains accepted and implemented for its documented scope. This change
adds verification within its existing contracts and ADR-0066's retirement fence;
it changes no production coordinator, protocol, persistence, authority or lock
order. A reproduced retained-disk retry classification defect is repaired in
Lilly under the existing ADR-0035/0092 storage and restart requirements.
ADR-0072 remains accepted and partial: Inception's recorded native
multi-disk obligations are not closed by this single-disk journey. ADR-0125's
fresh guest identity requirements and evidence remain intact.

Existing evidence already covers deterministic queue/cancel/revocation behavior,
replayed physical receipts, restoration before copying, immutable capture,
originally stopped sources and capacity rollback. The repeated-key property and
three-node distinct/exact admission tests remain valid. Existing native ZFS and
Porsche/browser suites cover local effects, cross-host copies, independent disks
and boot after source deletion. None of those assertions is relabeled untested.

The additional scope is current authority across generated cancellation/retry
histories, observed concurrent publication/cancellation order, admission versus
manager withdrawal, and the three-party admission/retirement lock-order lead.
The native boundary is public browser cancellation and manager withdrawal during
real captured work, with physical cleanup, source data and resource-release
observations. Successful automatic dispatch remains a control.

## Plan and independent oracles

[Generated histories](../../../marshall/test/marshall/compute/clone_history_test.exs)
call real Ash actions and the coordinator. A queue model independently retains
accepted request/destination identities, FIFO order, authority and retry
eligibility. Every command compares the complete sorted request inventory for
its unique history prefix, including source/requester identities and duplicate
keys across actors; unexpected durable rows cannot hide outside modeled IDs.
Refused/replayed operations must leave physical commands and host holds unchanged. Cancelled keys cannot resurrect after name release.

A separate generated cancellation history samples preparing, stopping, capture,
copying and publishing boundaries, repeats observations and interleaves cleanup
receipts. Its oracle is the outstanding set of five obligations: restored source,
source revocation, destination revocation, destination discard and snapshot prune.
Holds and active identity remain until all five are established. Restoration is
derived from the known initially running source or the supplied completed start
receipt, then checked against observed source power, completed operations and the
coordinator flag; that flag never decides the model obligation. Revoked manager
mutations are refused while admitted recovery continues. Synthetic physical/effect
receipts establish coordinator behavior only; they do not establish native safety.

[Ordering tests](../../../marshall/test/marshall/compute/clone_ordering_test.exs)
boot three independent Marshall BEAMs, Repo pools and authorization runtimes.
The parent runner does not count as a replica. They observe actual production
lock/allocation query completion through bounded telemetry barriers, then inspect
PostgreSQL waiters and committed state on another peer. Both publication/cancel
orders and both admission/withdrawal orders are covered. Barriers add no account
or source fence for the implementation. Every remote mutation carries a peer-side
completion envelope; registered calls are drained even after local task exit, and
uncertain transport outcomes stop the peer before row cleanup. Two failure probes
exercise assertion failure with competing mutations and a local RPC timeout while
the remote source-lock transaction is still alive. The original assertion survives
release/drain/cleanup, and fixture rows are checked after both probes.
Snapshots compare durable attributes, excluding process-local Ash metadata.

The [native driver](../../../nix/verification/tests/machines/clone-cancellation/driver.py) uses
the fleet's three Marshall replicas, two Lilly/ZFS/KVM machines, database, HTTPS
proxy and client. A separately typed
[browser helper](../../../nix/verification/tests/machines/clone-cancellation/browser.py) creates
and shares a real source, queues two manager requests, cancels captured work, and
revokes manager access through ordinary UI controls. A retained manager tab must
lose both submission and request controls.

Only automatic clone-job dispatch is delayed by a disposable PostgreSQL trigger.
The unchanged coordinator is stepped against actual authenticated Lilly receipts;
ordinary lifecycle jobs continue. The fixture observes an immutable snapshot and
source restoration, then stops dispatch at a cancellable copy/publication phase.
After browser cancellation and withdrawal, explicit stepping resumes admitted
recovery. It does not fabricate phases, capacity or physical receipts. Subsequent owner
stop intent must survive cancellation cleanup. The source is explicitly restarted
and its data checked. Native destination/snapshot absence and exact released
holds are checked before the revoked queued request is advanced and refused.
The trigger is removed before the successful owner clone control, which uses
ordinary automatic dispatch, copied guest data and a distinct dataset GUID. This
control does not separately establish ZFS origin independence; existing independent-
disk and source-deletion evidence retains that scope. This controlled schedule is not arbitrary scheduler
or fault-injection coverage.

## Findings

The proposed source/account lock cycle did **not** reproduce on unchanged
production code. Activation held the actual source advisory lock; a public submit
held the account admission fence and waited on that source; retirement queued an
exclusive account fence. After releasing the activation barrier, all three calls
completed in the required order. The baseline schedule passed in 5.0 seconds,
seed `62920`. This is a bounded observed liveness result, not a general proof
about every PostgreSQL queue schedule. No lock-order repair is justified by it.

The test implementation initially exposed fixture defects: an incorrect inner
PGHOST selection prevented the first local connection; raw cross-BEAM Ash struct
comparison included local metadata; a repeated synthetic completion attempted an
illegal complete-to-complete transition; teardown initially removed clone rows
before their operation references; and a status observer attempted to acquire the
paused source lock. Those fixture issues were corrected before the passing
application results. They are not reported as production defects.

The first native driver build failed its separate browser type gate because a
parsed JSON dictionary was not narrowed through a typed mapping. The corrected
helper validates keys and field types. No VM ran in that failed build.

Parent review identified an unsafe test harness cleanup path: local task death or
an RPC return alone did not prove remote completion. The corrected harness records
peer completion envelopes, caches completed operations, drains every registered
mutation and stops uncertain peers before deletion. Direct post-race mutations use
the same discipline. Structured context/snapshot/phase/effect types replace broad
domain interfaces. The restoration oracle now uses supplied receipt evidence.

The first captured native run reached actual capture/restoration and successful
public browser cancellation, then failed a fixture expectation of a 4 GiB source
temporary hold. The accepted portable-bundle reservation contract requires the
4 GiB guest disk plus the fixed 1 GiB boot bundle: the corrected expectation is
5 GiB on source temporary and destination disk reservations. The failed derivation
`/nix/store/nnnzlqapc0jvyrnxgk4c0k622gjy3wz7-vm-test-run-overalls-clone-cancellation.drv`
and archive `1790368370890-1840200-0.jsonl` remain failed evidence; cleanup took
3.98 seconds and all owned Nix/driver/nine QEMU processes were confirmed absent.
No physical cleanup or successful-control acceptance is inferred from this run.

The second captured native run failed during `capture_step`, before observing a
snapshot receipt or reaching public cancellation. Prepare, probe and connect
effects completed; a native ZFS snapshot success was logged immediately before
the strict no-failure assertion stopped the test. The original assertion did not
retain the returned failure label, so these logs cannot identify the cause or
distinguish an unconfirmed effect from a lifecycle failure. No production repair
or retry tolerance is inferred. Its derivation `2q2yn8vpd767rs14g84dbg7128z8q52h`
and archive `1790370985491-2898585-0.jsonl` remain failed evidence. Cleanup took
4.25 seconds; the Nix, driver, nine QEMU and four vde processes were absent after
the session drained. The next fixture reports only allowlisted phase/failure
labels and retains the strict successful-effect assertion.

The third captured native run passed real capture, source restoration, public
browser cancellation and manager withdrawal, then failed the blanket no-failure
assertion during recovery: `phase=cancelling, failure=copy_unconfirmed`. Both
native revocations had completed. `CloneEffects.accept!/2` retains an unconfirmed
receipt from offered forward work after cancellation; `offered?/2` suppresses
further forward work. `CloneCoordinator.cancel/1` requires both revocations,
discard, prune and restoration, then `finish!/2` clears the diagnostic. Requiring
the deliberately revoked unfinished copy to succeed was fixture overspecification,
not a reproduced production defect. Parent source review agreed with this finding.

The corrected fixture permits exactly `copy_unconfirmed` only while `cancelling`
after an observed public cancellation whose stored request remains unpublished.
Pre-cancel advancement, all other failure labels and final completion remain
strict. It still requires successful cleanup receipts, absent destination and
snapshot, exact released reservations/slots/addresses, intact source data and
preserved later source intent. The failed third run does not establish those
postconditions. Its archive is `1790372021875-3352532-0.jsonl`; total runtime was
313 seconds, cleanup 4.31 seconds. All owned Nix/driver/nine QEMU/four vde
processes were absent after session drain, independently confirmed by the parent.

## Recorded execution

Pinned `devenv shell`, Elixir/OTP, `ERL_FLAGS='+S 4:4'`, and isolated PostgreSQL
partition `verify020` were used. Test runs and forced Dialyzer never share the
same build directory concurrently.

- Two generated properties plus four ordering tests passed: **6 checks**, seed
  `448626`, 12.2 seconds. Each property used 16 bounded generated runs.
- With the added admission-first withdrawal schedule, **5 ordering tests passed**,
  seed `839572`, 6.2 seconds.
- The separate browser artifact and strictly composed native driver built after
  the JSON narrowing correction. This is build/type evidence, not machine
  acceptance. The final native candidate and execution remain pending.

The first full gate (seed `759331`) recorded **1081/1087 passed**, 111 properties,
six failed tests and two exclusions in 471.4 seconds. All six failures were exact
maintenance-queue counts inflated by three orphan account-deletion jobs from early
fixture teardown attempts. The positively identified old jobs (108, 232, 242) were
removed; the old partition then had zero users, hosts, clones or jobs. This run
remains failed despite its subsequent forced Dialyzer reporting zero findings.

The first corrected focused run (seed `549874`) passed both properties and five
ordering schedules; its two cleanup probes removed all rows but failed an exact
comparison with ExUnit's whitespace-formatted assertion message. The matcher was
corrected without changing cleanup behavior.

**Corrected focused checks passed: 9 checks (2 properties, 7 tests)**, seed `63229`,
22.3 seconds on integrated `3f679eff`. The seven tests include five ordering
schedules and both assertion/RPC-timeout failure-cleanup probes. Afterwards the
fresh `verify020final` partition had zero users, hosts, clone requests, jobs,
fixture triggers or advisory locks. The two properties each ran 16 histories.
The captured final full Marshall gate passed **1101 checks (113 properties,
988 tests)**, two exclusions, seed `497702`, in 509.4 seconds. Its captured source
tree was `695967b06adab3be26acdacec729420db3c25567` on `3f679eff`; forced test-
environment Dialyzer reported zero findings in 1m1.75s. Post-suite users, hosts,
clone requests, jobs, fixture triggers and advisory locks were all zero.

After that gate drained, parent review strengthened one remaining oracle: compare
all durable requests with the unique history prefix, including unexpected rows
and wrong source/requester assignments. **Final inventory properties passed:
2 properties**, seed `818700`, 9.6 seconds; forced test-environment Dialyzer again
reported zero findings in 1m0.85s. Both properties retain 16 generated histories.
This is the only source delta after the captured full gate; no production source,
distributed harness or native script changed. The full gate and this focused
follow-up retain their distinct scopes.

All-file logging/HLDD/ruff/format/ty and Nix `hldd`/`python-static` passed for the
captured full candidate. ADR, contract, coverage, views and option-reference gates
also passed. Final bookkeeping checks after the inventory delta are tracked in
the native-ready handoff; normal commit hooks and native acceptance remain pending.

The second native capture **failed** as described above:
`/nix/store/2q2yn8vpd767rs14g84dbg7128z8q52h-vm-test-run-overalls-clone-cancellation.drv`.
Its separately typed browser and strictly composed driver built successfully;
the exact captured driver build took 283 seconds. Driver output:
`/nix/store/84pb7jpir6jxfn2w9rnkafwwh8a3j0wy-nixos-test-driver-overalls-clone-cancellation`.
Script SHA-256: `09fffa8bd6bc31ffc9217b2170a8c176687107c4982de5e3780de4647783a3dc`.
Neither failed capture is upgraded by these builds. The next capture and its
serialized runtime slot remain pending.

After that runtime drained, published improvement013 (`d2a47671`) was integrated.
The only merge conflict was the shared HLDD receipt; both improvements' handbook
and scenario evidence is retained. ADR-0126's bounded database-client recovery
settings and terminal asset changes remain intact. The executed second capture
used `3f679eff` runtime; it did not execute the newly integrated database settings.
The integrated clone histories/orderings and RuntimeConfig checks passed
**21 checks (5 properties, 16 tests)**, seed `802448`, in 16.0 seconds. Both clone
properties retain 16 generated histories. `mix terminal.check` passed all
28 JavaScript tests, including the vendor integrity checks, and
`mix workspace.check` passed TypeScript checking. Forced test-environment
Dialyzer reported zero findings in 58.3 seconds. Log:
`/tmp/verify020-integrated-targeted.log`. The application source is disjoint from
013's changes; no executable merge conflict required another full suite. The
earlier full gates retain their captured source scopes.

The new candidate uses the integrated runtime and the diagnostic-only driver
delta. Its captured source tree is `cbb53bf4a89da6c71c2227e9e6906385f5f7dc26`;
runtime derivation:
`/nix/store/34ndh26jvb9742arbvgmn15an3n11mvq-vm-test-run-overalls-clone-cancellation.drv`.
The evaluated script differs from run2 only in the closed phase/failure
diagnostics and their contract; success conditions remain unchanged. The strict
driver build passed in 280 seconds, with script SHA-256
`0868acbf097e3c59b0823aafadecb1c5e3589dffc010a9105d5b0e50b74d7d46`;
the built script exactly matches the final evaluated script. Integrated ADR,
contract, generated-reference, HLDD receipt, all-file prek and Nix
`hldd`/`python-static` checks passed. The post-check database audit found zero
users, hosts, clone requests, jobs, fixture triggers and advisory locks.
This candidate's native execution failed as described above. Documentation-only
changes before execution retained its captured runtime scope; the subsequent
narrow cancellation-oracle correction requires a new native capture.

After the third runtime drained, upstream terminal startup/reply recovery
`5af65d3f` was integrated. Only the review index and HLDD receipts conflicted;
both reviews and scenario evidence were retained. No clone production source or
composed fleet script changed upstream. The third capture remains attached to
`d2a47671`. The integrated clone, terminal startup, connected workspace, handbook
and RuntimeConfig checks passed **57 checks (10 properties, 47 tests)**, seed
`832235`, in 28.7 seconds. Both clone properties retain 16 generated histories.
All 28 terminal JavaScript/vendor checks and workspace TypeScript passed. Forced
test-environment Dialyzer reported zero findings in 53.8 seconds. The isolated
database again had zero users, hosts, clone requests, jobs, fixture triggers and
advisory locks. Log: `/tmp/verify020-terminal-integrated.log`.

The fourth native candidate captures the corrected oracle on `5af65d3f`, source
tree `b2e339caf661a6414434823fa87e4af6ca237b5f`:
`/nix/store/3ypvrigqh7y7sgaf51bbdyarlg26z79r-vm-test-run-overalls-clone-cancellation.drv`.
Its evaluated script SHA-256 is
`a35ec9a24bfc1c84081a44ace73fbd41c86e242a1b794aa098f453a4583f18bf`.
The script differs from the third capture only in the reviewed cancellation
oracle, its contract and the one recovery call site. This fourth native run
failed in **626 seconds**, with 3.88-second cleanup. Its archive is
`1790372939099-3732651-0.jsonl`. The session drained with exit 1; all owned Nix,
builder, driver, nine QEMU and four vde processes were independently confirmed
absent.

**Native cancellation recovery passed in 47.94 seconds.** It followed successful
boot (56.21 seconds), capacity (112.42 seconds), source creation/data seeding
(49.76 seconds), and capture/restoration/public cancellation/withdrawal
(49.83 seconds). Recovery verified actual discard and snapshot absence, exact
reservation/slot/address release, the source's original identity and data, later
owner stop intent and refusal of the withdrawn requester's queued clone.

The ordinary automatic owner-clone control then failed its unchanged browser
completion deadline. Source restart emitted `vm.launch_preparation_failed` with
`disk_not_ready` at elapsed 333.07 seconds and a failed source outcome followed.
The destination subsequently reached running, but the clone did not complete.
This is a failed overall native gate; passing cancellation recovery does not
establish successful ordinary cloning. The diagnostic does not distinguish
invalid dataset/bundle evidence from a lost retryable storage result.

After runtime cleanup, published `d8f05479` and then `e3072688` were integrated.
Both safety stashes remain retained. Conflict resolution preserved both reviews,
ADR evidence, campaign rows, native fleet variants and scenario claims. The new
private-web action grants and administrative account fencing retain their own
source and runtime scopes. The fourth clone capture remains scoped to
`5af65d3f`; integrated application checks and a repaired native candidate are
pending.

## Architecture and contract review

### Retained-disk retry classification

Run4's source failure prompted inspection of `Driver.restart/4` through
`Disk.ready/2`, `ZFSDataset.ready/2` and `ZFS.observe/2`. A validated usage-only
observation race can return `storage_busy`; dataset verification preserves it,
but `Disk.ready/2` converted every callback error to `disk_not_ready`. The
executor already retries `storage_busy` before recording a launch attempt, while
`disk_not_ready` produces terminal execution failure. This is a concrete retry
classification defect independent of whether that branch caused run4.

The [regression](../../../lilly/test/vm/disk_test.exs) executes identical compiled
production `Disk`, `Storage`, `Lock` and `WorkloadBundle` bytecode in a disposable
standard-IO BEAM peer. Only the ZFS boundary is replaced by a synthetic result.
On unchanged source, seed `20004` reproduced `storage_busy` becoming
`disk_not_ready`, with one verification under the real pool lock, no bundle
lookup and independently proven lock release. The replacement is confined to
the peer, which is stopped and monitored before fixture teardown.

The repair preserves only `storage_busy` and adds the
`retained-disk-busy-is-retryable` contract. It does not replay the protected
callback, weaken dataset ownership checks, create disk or boot artifacts, or
change executor retry rules. Invalid dataset evidence and genuine absent bundle
metadata remain terminal. Focused disk, ZFS, storage and bundle checks passed
**22 checks (4 properties, 18 tests)**, seed `20005`, in 2.3 seconds. Logs:
`/tmp/verify020-disk-baseline.log`, `/tmp/verify020-disk-fixed.log`.
This unprivileged regression does not fabricate valid root-owned boot artifacts;
successful retained-source boot remains a required native control.

On integrated `e3072688`, **full Lilly precommit passed 408 checks (48 properties,
360 tests)**, seed `524440`, in 12.1 seconds of test execution. Forced Dialyzer
reported zero findings (12.47 seconds after building its PLT). The combined
Marshall clone histories/orderings, Cedar/private-web and administrative account
histories/distributed schedules passed **51 checks (13 properties, 38 tests)**,
seed `20006`, in 79.6 seconds; forced test-environment Dialyzer reported zero
findings in 60.86 seconds. Logs: `/tmp/verify020-lilly-precommit.log` and
`/tmp/verify020-e307-consumers.log`. The isolated database audit found zero users,
hosts, clone requests, jobs and advisory locks, with only standard production
triggers and no surviving clone or account fixture peers.

ADR/contracts/generated coverage/views/options, reviewed HLDD receipts and
all-file logging/HLDD/ruff/format/ty passed. Nix `hldd` and `python-static` passed
in 12 seconds. The fifth capture on `e3072688`, source tree
`046a05ce09c8ced7545b7af93bff33cbab4845ca`, is
`/nix/store/ra9k9sj2pg8l4ablq3r2cl6b2y731pmy-vm-test-run-overalls-clone-cancellation.drv`.
Its strict driver derivation is
`/nix/store/mpds69r6xdk39c45sng2f73qq89y2v3j-nixos-test-driver-overalls-clone-cancellation.drv`.
The evaluated script is byte-identical to run4, retaining SHA-256
`a35ec9a24bfc1c84081a44ace73fbd41c86e242a1b794aa098f453a4583f18bf`.
Later review/receipt/campaign changes preserve this capture's scope. The strict
driver build passed in **247 seconds** and its built `test-script` exactly matches
the evaluated script. The build session drained successfully with its Nix process
absent. This fifth native execution **failed in 290 seconds**, with 4.21-second
cleanup, before public cancellation. Archive:
`1790374451686-223904-0.jsonl`. Boot (56.05 seconds), authenticated capacity
(126.79 seconds), and source creation/data seeding (60.67 seconds) passed.
The capture checkpoint reported `phase=capturing, failure=capture_unconfirmed`.
The automatic clone control and retained-source restart repair were not exercised.
The session drained with exit 1; root independently confirmed all owned and global
driver/QEMU/vde processes absent.

### Capture retry oracle correction

Run5 logged durable snapshot intent at 282.01 seconds, successful native snapshot
creation at 282.558 seconds, and the fixture failure immediately afterward. The
snapshot journal reached `final_ready` at 282.994 seconds during cleanup. The
underlying error behind the earlier unconfirmed report remains unknown; native
progress during cleanup is not a successful capture receipt.

Source review and independent parent review establish that `capture_unconfirmed`
is a nonterminal progress label. `CloneEffects.accept!/2` retains no effect result
or completion time for it, acknowledges the attempt, and keeps the same capture
effect offered. A matching successful receipt atomically clears the label; the
coordinator cannot record a snapshot without that receipt. Thus failing on the
first intermediate label overspecified the accepted retry contract.

The new real authenticated exchange property generates one through four uncertain
capture receipts across eight histories. It verifies identical effect/intent and
destination, unchanged reservations/slots/operations, no fabricated snapshot or
publication, exact bound successful receipt clearing, duplicate success, and a
late uncertain replay that cannot erase the receipt or reintroduce its diagnostic.
**Capture retry histories passed: 3 properties**, seed `20007`, in 9.7 seconds,
including the two existing generated history properties. Log:
`/tmp/verify020-capture-retry.log`. The new property changes no production behavior.

The initial narrow correction allowed only capture uncertainty and required global
cleared failure at capture. Parent review then requested an audit of every immediate
failure assertion before another native run. `CloneEffects.accept!/2` gives every
unconfirmed kind the same pending/acknowledged semantics. The original oracle also
overspecified preparation, copy/adoption after capture, and cancellation cleanup;
one coordinator call may cross multiple durable phases. A valid capture receipt can
coexist with an independently pending copy effect.

The revised checkpoint reads phase, diagnostic and evidence in one PostgreSQL
snapshot. A closed diagnostic kind must match an actually offered, incomplete effect
with the request's host, endpoint and specification. Preparation permits
prepare/probe/connect; capturing permits capture; copying permits copy; publishing
permits adopt. This fixture cancels only after captured/restored evidence, so its
cancellation guard permits retained copy/adopt or pending revoke/discard/prune.
Every allowance requires original source snapshot headroom, destination disk and
compute commitments, and exactly one unreleased transfer slot per distinct endpoint
host. Source compute may release after observed restoration and a later user stop.
Unexpected labels, wrong phases/bindings, lost commitments, and terminal failures
still fail immediately. Existing finite waits are unchanged.

Capture success independently requires the offered/completed source-host receipt
matching the stored descriptor and its native snapshot GUID. Pending copy/adoption
cannot satisfy capture. Final cancellation and automatic completion require nil
failure, with all original native data, restoration, cleanup, release and refusal
assertions retained. No additional production change implements this correction.

A second authenticated exchange property exercises all eight non-capture effect
kinds, including both revoke endpoints, in four generated histories with one through
three uncertain receipts per effect. It checks retained identity/intent, phase,
snapshot, exact reservations/slots/operations, matching success clearing, and late
uncertain/duplicate receipts. Its first local run exposed an invalid synthetic
prerequisite (a completed replayable probe without an offer); the setup now records
the prerequisite offer. **All-effect retry histories passed: 4 properties**, seed
`20009`, in 28.9 seconds, including the existing queue, cancellation and capture
properties. Log: `/tmp/verify020-all-effect-retry-fixed.log`. The native checkpoint
SQL also passed PostgreSQL `EXPLAIN` against the migrated isolated database. This
remains synthetic host evidence, not native success. Forced test-environment
Dialyzer passed with zero findings in 49.43 seconds
(`/tmp/verify020-all-effect-types.log`). All-file logging/HLDD/ruff/format/ty gates
passed; the isolated database audit found zero users, hosts, clone requests, jobs
and advisory locks. Parent review traced the final guard through effect creation,
placement holds, outcomes release and cancellation completion and found no blocker.

The superseded sixth candidate's strict driver build passed in 291 seconds, but its
runtime was never executed. The broader reviewed candidate requires a fresh capture;
complete native acceptance remains pending.

The change preserves ADR-0035, ADR-0055 and ADR-0092 decisions. The fourth native
failure's precise cause remains uncertain because its closed diagnostic did not
identify the failing verification step. A future passing run must retain that
limitation rather than retroactively attributing the failed capture to this fix.

The pre-implementation review found no need to replace accepted decisions.
Production authority remains in Ash/PostgreSQL; physical work stays with Lilly.
The final source review inspected test barriers, remote completion/cleanup, typed
boundaries, complete request inventory, independent restoration evidence and native
claims. Parent review confirmed the concrete cleanup and oracle findings closed. Relevant contracts are repository evidence/scope,
Marshall test isolation/three-independent-node requirements, compute host-before-VM
ordering, clone queue/placement/receipt contracts and the account admission fence.

No new domain, resource, host or service is introduced. The fleet projection and
Ash ownership views retain their existing topology; the new test variant is not
another deployed service. The handbook's workflow, scenario and security sections
are maintained with their exact recorded scope. No other improvement's native
acceptance or ADR-0072 multi-disk gap is inferred from this work.

## Expanded committed-fixture residue audit

A later parent audit identified a cleanup omission in this change's new helper:
ordinary Standard provisioning registers agent roots, root threads, audit events
and both version tables. Agent history intentionally survives VM deletion in
production, so the old fixture's VM/user cleanup did not remove it. The earlier
zero audits covered only their named users, hosts, clones, jobs, triggers and locks;
they did **not** establish zero agent-table residue.

The expanded `verify020final` audit found 105 rows in each of `agent_roots`,
`agent_roots_versions`, `agent_threads`, `agent_threads_versions` and
`agent_audit_events`; the eight other agent tables were empty. These historical
rows remain untouched because a global orphan sweep would lose provenance.
The baseline is retained in `/tmp/verify020-agent-inventory-before.log`.

The helper now selects root bindings through exact fixture placements and VMs,
including each VM's actual owner, before deleting any placement or request.
A managing requester is not assumed to own the source. Cleanup removes only
selected automatic registrations and their threads, audit rows and versions;
unrelated detached history remains. Every committed ordering test compares all
13 agent-table identity inventories before and after its schedule, including the
assertion-failure and uncertain-RPC teardown probes. A separate same-requester
detached-history control proves its root, thread, audit and versions survive.
The first expanded observer used `id` for the cache table, whose primary key is
`key`; it failed during setup before provisioning and was corrected.

This is test-isolation repair within existing contracts, with no production or
native driver change. Its execution evidence postdates the frozen native source
`697fe5405e52151e1f53577d3dc443f18b365ac8`; the captured production/runtime scope is
unchanged. No Inception or multi-disk validation is added.

**Expanded cleanup ordering passed: 8 tests**, seed `20012`, in 10.7 seconds
(`/tmp/verify020-agent-cleanup-final.log`). Exact-ID cleanup callbacks are registered
immediately after each preservation-control resource creation, so later setup
failure also removes only the control's own rows. Forced test-environment Dialyzer
passed with zero findings in 65.53 seconds. All thirteen agent identity
inventories matched their pre-test state after each successful/failing schedule.
The final expanded audit retained the same 105 historical rows in each affected
table, zero in the other eight agent tables, and zero users, hosts, clones, jobs
or advisory locks (`/tmp/verify020-agent-inventory-after.log`). This establishes
no new residue and unrelated preservation, not a globally empty historical DB.

## Sixth native failure and stage diagnostics

The generalized oracle candidate was captured on `e3072688` as source tree
`697fe5405e52151e1f53577d3dc443f18b365ac8`. Its runtime was
`3cj7kmscxwga5i1ly2s49095d0b35mfk-vm-test-run-overalls-clone-cancellation.drv`,
driver `nsr4z360a8xcbw66xmycb2cq2rydaxk3-nixos-test-driver-overalls-clone-cancellation.drv`,
and evaluated script SHA-256
`101ff47276b0d10e1c37477c4cce413f18e3cca02c69049c34a32c6500a53eb4`.
The strict driver passed in 265 seconds and its built script matched byte-for-byte.
Filenames call this run7 because the preceding narrow run6 was never executed;
this was the sixth actual native execution.

Boot passed in 59.13 seconds, authenticated capacity in 116.47 seconds, and real
source creation/data in 60.05 seconds. The exact capture receipt and snapshot
checkpoint succeeded. Source restoration then reached `observed_state=failed`;
Lilly emitted `vm.launch_preparation_failed`, reason `disk_not_ready`, at guest
time 274.455798 seconds. Public cancellation, cleanup assertions and the automatic
control were not reached. Test cleanup took 3.74 seconds. Session `71577` drained
with status 1; the exact shell, Nix, builder, driver, nine QEMU and four VDE PIDs
were absent, with a separate parent global-native scan also empty.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790389395324-2395864-0.jsonl`.

This failure establishes that preserving `storage_busy` alone does not resolve
the native restart failure. The closed outer error did not identify which retained
disk check failed. Source review found a possible whole-pool observation conflict:
ordinary accounting rejects an unmounted read-only `noauto` sibling while receive
staging intentionally uses those properties. Same-host placement was recorded,
but receive start before failed readiness is not established. This is a lead,
not a diagnosed cause. A pure source/snapshot/sibling accounting check confirms
the capacity refusal boundary and does not reproduce `Disk.ready/2` by itself.

The diagnostic candidate adds catalogued `vm.dataset_readiness_failed` with only
placement UUID, a private closed validation-stage type and finite sanitized reason.
It preserves every predicate, guard, call order, short circuit and return result;
ordinary `storage_busy` is silent. Only retained `ready/2` enables the event;
shared prepare/resize checks remain unchanged. No admission, capacity, ownership,
snapshot binding, boot-bundle or public protocol requirement is weakened.
Parent contract/security review found no blocker. **Diagnostic boundary checks
passed: 18 checks (3 properties, 15 tests)**, seed `20013`, in 1.2 seconds;
`logging.check` passed with 82 catalogued events and forced Lilly test-environment
Dialyzer passed with zero findings in 11.39 seconds
(`/tmp/verify020-readiness-diagnostics.log`). Native diagnostic execution remains
pending an exact slot grant. Inception validation is explicitly excluded.

Before the next capture the branch integrated `73a3a96c`, preserving the Underclass
pin, generated configuration and token-recovery gap. Historical captured revisions
above are not relabeled as this integrated source.

## Seventh native failure: pool observation

The readiness-stage candidate was frozen on `73a3a96c` as tree
`98001c6021efce74de7c0514a15a93ea6d2620dd`, runtime
`b9dj4v1qrqyyz77y5fqyhijriwbpx9mq-vm-test-run-overalls-clone-cancellation.drv`
and driver `l87lva4lb8m7a3s70idfkbx4aqkq7pdy-nixos-test-driver-overalls-clone-cancellation.drv`.
Its strict driver passed in 320 seconds. The evaluated and built scripts matched
SHA-256 `8f0c233d2dceff2aff29fc09bfc5b4d099f830373ed5256a6d07b87556c98e7e`.
The captured script contains no Inception scenario. Source, generated-reference,
ADR/contracts, reviewed HLDD receipts and all-file static gates passed; Nix
`hldd` and `python-static` passed in 12 seconds. This capture precedes subsequent
published campaign integrations and the independent, uncommitted restart work.

With an exact coordinator grant, boot passed in 59.84 seconds, authenticated
capacity in 120.56 seconds, and owner source creation/data in 52.13 seconds.
At 03:30:22.160 UTC on 2026-09-26, Lilly reported
`vm.dataset_readiness_failed`, stage `pool_observation`, reason
`incoherent_zfs_observation`, for the source placement. The outer
`disk_not_ready` event followed one millisecond later. The capture/restoration
stage failed before public cancellation; physical cancellation assertions and
the automatic owner-clone control were not reached. This is the seventh actual
native failure; filenames identify it as run8 because narrow run6 never ran.

The event establishes failure in whole-pool observation. `observe_once` still
combines failed identity reads, failed dataset reads, changed non-usage properties
and exhaustion of three rejected accounting samples into that same result.
It does not establish that receive staging existed at the failure or caused it.
The pure source/sibling accounting test remains separately scoped capacity
evidence. No launch, ownership or accounting guard has been weakened.

The Nix wrapper failed in 271 seconds. Cleanup completed in 3.78 seconds;
session `25530` drained with status 1. All
recorded PID/start-time pairs were absent: Nix client and worker, worker SSH,
builder, driver, nine QEMU and four VDE processes. The parent independently
confirmed the exact drain before releasing the slot. A separately owned external
VM remained on the host; these durations are not performance acceptance.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790393156581-149566-0.jsonl`.
Private full log: `/tmp/verify020-native-run8-all.log`; exact process inventory
and final audit: `/tmp/verify020-run8-owned-processes.json` and
`/tmp/verify020-run8-processes-drained.log`.

After that capture, the branch integrated published `8a575060`, retaining agent
CLI, Brady cache and backup-operator evidence and the Underclass gap. At that capture, the separate
original-checkout recovery work remained uncommitted and had not been adopted.
Its recorded passing clone-retry scenario emitted no readiness-stage failure in
the inspected archive and does not diagnose this failure.

The next diagnostic candidate adds readiness-only finite identity-before/after,
dataset-read-before/after, property-stability, accounting-before/after,
cross-attempt property-drift and accounting-exhaustion stages. It shares the same
whole-pool validator, read order, result and three-attempt bound. Only validated
placement identity and fixed stage/reason atoms leave the boundary; invalid
diagnostic identity disables logging without changing validation. Ordinary
admission observations and coherent usage-only busy samples remain quiet. Each
accounting warning identifies a rejected sample, which may precede recovery by a
later bounded sample; it is not itself a terminal-readiness claim. **Deeper observation
checks passed: 19 checks (3 properties, 16 tests)**, seed `20014`, in 1.1 seconds,
including an unprivileged identity-refusal/no-raw-path diagnostic check.
`logging.check` passed with 83 catalogued events and forced test-environment
Dialyzer passed with zero findings in 14.4 seconds
(`/tmp/verify020-deep-observation-checks.log`). This is diagnostic preparation,
not native acceptance or a semantic repair. Further native execution requires
a new exact grant, and all new Inception validation remains excluded.
Parent contract/security review confirmed preserved read/guard/accounting order,
bounded resampling and returned values, with no remaining finding in that scope.


## Published recovery integration and bounded recorder preparation

The branch subsequently integrated published `951630ee6b169a3ce981ef631137e5bc6db6cc9b`.
The published `Disk.ready/2` implementation is retained unchanged, including
`storage_busy` propagation and `vm.disk_readiness_failed`. Its ZFS dataset
readiness stages and boot-bundle ordering replace the overlapping earlier 020
outer wrapper. That historical wrapper's run8 event remains valid evidence for
its captured revision; the duplicate `vm.dataset_readiness_failed` catalog entry
is removed from the integrated candidate. The inner readiness-only
`vm.dataset_observation_failed` path now attaches to upstream `verify_child/4`;
ordinary callers remain quiet, and the same whole-pool validator still controls
all results. No ownership, launch or capacity predicate changes. Upstream restart
review, generated histories, recorded cloning-fleet pass and production acceptance
gaps remain intact and separately scoped.

Before this integration, diagnostic-only source `dc29b2568070f2e6bf0f2b7d6d48183b19377410`
on `8a575060` built the strict driver in 278 seconds. Driver
`axfy47h78yfvkdqhwlbg0qvdh7d483dq-nixos-test-driver-overalls-clone-cancellation.drv`
and runtime `b2yzz45x7ca4pbs2jjzq5p8mbmzqsprr-vm-test-run-overalls-clone-cancellation.drv`
were captured; evaluated and built scripts matched SHA-256
`8f0c233d2dceff2aff29fc09bfc5b4d099f830373ed5256a6d07b87556c98e7e`.
Session `39147` drained with status 0. **That runtime was never executed and is
superseded**, leaving seven actual failed native captures. The build archive is
`/home/ghuntley/.local/state/nix/build-logs/1790394016921-379240-0.jsonl`.

The fixture-only [recorder](../../../nix/verification/tests/support/zfs_observation_recorder.py)
is installed only for `cloneCancellation`, before the host-selected ZFS package
in Lilly's service PATH. It ultimately invokes that same `config.boot.zfs.package`
executable under the existing command/lock process group. Unarmed and nonmatching
commands exec directly. Recording requires the exact argv:
`list -Hp -t all -o <the original 23-property CSV> -r zroot/lilly`.
Ownership/custom properties, receive tokens, mutations and additional arguments
cannot match. A matched command runs once and forwards binary stdout, stderr and
its native exit/signal status; capturing never substitutes an observation.

Each host retains 128 completed samples with 64 KiB per stream, byte counts,
truncation indicators, timestamps and native return code. Files are mode 0600
under a mode 0700 fixture root; the ring and single atomic staging file are bounded
below 23 MiB per host. No raw sample is emitted to logs or persisted in Nix outputs.
The recorder is armed immediately before capture and remains armed through public
cancellation, cleanup and the unchanged automatic owner-clone control. Failure
collection disarms it, synchronizes completed publication and copies the ring to
`clone-zfs-private/<host>` beneath the private builder working directory before
framework teardown. Collection failures cannot replace the original exception.
The next authorized native build must use `--keep-failed`; private extraction of
that directory must precede removing the failed build. Guest rings are removed
in `finally`, with VM teardown handling an unreachable host. Successful runs
retain no ring. Missing or truncated samples must be reported as evidence gaps.

**Recorder executable checks passed: 5 tests**, in 0.689 seconds, with pinned
Python 3.13, Ruff formatting/lint and ty. The disposable fake executable verifies
single execution, unchanged argv, binary stdout/stderr, nonzero and signal status,
exclusion of custom/token/foreign/additional arguments and unarmed calls, output
truncation without native truncation, ring reuse and persistence-failure pass-through.
Log: `/tmp/verify020-recorder-checks.log`. Native instrumented execution remains
pending; observed timing is not performance acceptance. Architecture impact is
bounded diagnostic/verification instrumentation under ADR-0055/0066/0092, with no
new architectural decision or change to accepted validation authority.


After integrating `951630ee`, **Integrated readiness checks passed: 32 checks
(4 properties, 28 tests)**, seed `20015`, in 5.1 seconds. This includes upstream
actor retry histories and the isolated-peer disk, ZFS accounting and diagnostic
checks. Catalog validation passed with 83 events; forced test Dialyzer reported
zero findings in 10.4 seconds. Session `17108` drained with status 0; log:
`/tmp/verify020-integrated-observation-checks.log`. This result does not extend
any recorded native acceptance scope.


The fixture recorder review required cleanup for partial arming, nonblocking
persistence and explicit native-child custody. Arming now falls inside the same
`try/finally` as the journey; both hosts disarm before collection. Persistence uses
nonblocking flock and drops a sample on contention. The Python child retains the
native lock descriptor and existing process group. Linux clears `PDEATHSIG` at
fork, so the typed child pre-exec boundary restores `SIGKILL` on wrapper death and
checks its captured parent PID after installing the fence. Wrapper signals and
broken consumers trigger explicit kill/reap with a one-second wait bound; no
`Popen` context can wait indefinitely. An uninterruptible native task retains its
lock descriptor and remains subject to the native owner's group cleanup.

For replay, the clone-only release build replaces exactly one reviewed
`observe_for_readiness` body using the
[fail-closed instrumenter](../../../nix/verification/tests/support/instrument_clone_observation.py).
A [typed fixture wrapper](../../../nix/verification/tests/machines/clone-cancellation/observation.ex)
receives the exact `SnapshotOwnership.expectations/1` result before the unchanged
observer. Under the same pool lock, it publishes only a validated placement UUID
and at most eight exact dataset/snapshot GUID bindings, bounded to 4096 bytes in
private context. Its filename binds `Port.info(Lock.current(), :os_pid)`; the
recorder matches its own native parent PID and checks unchanged context before
and after the query. Context is removed in `after`, and stale fixture contexts
are removed before replacement. Empty verified expectations are retained as an
explicit empty map; missing, invalid or changing context remains explicit and
cannot be attributed to readiness. No ownership nonce, token or raw custom-property
output is copied. The observer receives identical arguments, runs once and
preserves results and exceptions.

`Disk.ready/2` and preparation hold `Storage.locked` across dataset validation;
`ZFSDataset.verify_child` obtains the real expectations before readiness observation.
Ordinary capacity reporting uses `Pool.snapshot` with zero-wait pool acquisition
and a separate native owner, so it cannot overlap this context. Backup observation
also uses the pool lock. Other recursive transfer readers target a child dataset
and cannot match the fixed parent argv. Direct fixture probes resolve the unwrapped
host ZFS executable. These caller constraints plus the exact owner-bound context
pair each eligible sample with its actual expected GUID map. Accounting replay
must use that map, the captured native bytes and the frozen fixture's pool identity;
rows alone are insufficient. Missing/truncated context or samples retain a gap.

**Final recorder checks passed: 13 Python tests and 3 Elixir context tests**,
with pinned Ruff and ty; Python completed in 1.520 seconds and Elixir in 0.05 seconds
(seed `109521`). Cases cover original-group child reaping, abrupt wrapper death,
inherited-lock exclusion/reacquisition, parent-identity race refusal, nonblocking
persistence, exact/empty/foreign context, changing context, source-seam refusal,
and callback result/exception cleanup. Log:
`/tmp/verify020-recorder-context-checked.log`. The helper's direct Dialyzer CLI
initially lacked Elixir's debug-info backend; analysis was rerun inside the pinned
Mix runtime. Parent review accepted the incremental source, custody and context
boundaries for strict-build preparation. This remains instrumentation-scoped
verification, with native execution pending and no timing acceptance.

Published `2d66e76dd9a4935045f5daeb1b7ae9716ddd8740` was integrated before the next
capture. Maintenance evacuation and generated CLI history evidence remain intact;
the independent fleet variants retain their strict drivers. Seven historical
native failures and the superseded unexecuted run9 build retain their exact revisions.

The final helper and current Lilly BEAMs were force-analyzed together inside the
pinned test Mix runtime using the existing dependency PLT: **Fixture and Lilly
Dialyzer findings: zero**. The helper was recompiled from the final source before
analysis. Session `96705` drained with status 0; log:
`/tmp/verify020-context-types-final.log`. The initial external CLI failure remains
in `/tmp/verify020-context-types.log` and establishes no type-check success.


The first instrumented strict build captured tree
`7d62a46d33e40961e56063ac9f70b8e81db03332` on `2d66e76`, driver
`l7ns4jjw3ys2x4637ynmy300gmddv12g-nixos-test-driver-overalls-clone-cancellation.drv`
and runtime `4b5iz63dxy54i3gdiamcqvnimfw3i9rx-vm-test-run-overalls-clone-cancellation.drv`.
Its evaluated script hash was
`b3d44c59f990e7b902f594442b2467539ec239126f450a7d65172aa66601990c`, with no Inception
scenario. Source/reference/all-file gates and Nix HLDD/Python checks passed, but
**the strict build failed before application compilation in 9 seconds**: Ruff
interpreted the store-prefixed config basename as standalone Ruff TOML and rejected
the repository's `[tool.ruff]` table. The fixture package now copies that same config
to a literal `config/pyproject.toml` before validation. The native runtime was never
executed; seven native failures remain. Session `15352` drained with status 1;
archive `/home/ghuntley/.local/state/nix/build-logs/1790395953655-876433-0.jsonl`.

The corrected-config build captured tree
`09fe41254c43bd9f2cca3436228d2703a2b220d7` on the same base, driver
`2sbffsj487kwnap3873pyxr3prjyxiq4-nixos-test-driver-overalls-clone-cancellation.drv`
and runtime `9r82qkl1kwqmcll7xvlk5n4k1k8r0jqy-vm-test-run-overalls-clone-cancellation.drv`.
The evaluated script retained the same hash and excluded Inception. **This strict
build also failed before application compilation in 9 seconds**: Ruff passed, but
the isolated package type check exposed four dictionary-narrowing errors and two
unresolved sibling imports. The recorder now validates JSON objects through an
explicit `dict[str, object]` boundary, and the package declares its output directory
as the type check's project root. This preserves the accepted context schema and
invalid-context refusal. Session `17585` drained with status 1; archive
`/home/ghuntley/.local/state/nix/build-logs/1790396298930-961848-0.jsonl`.
Nix HLDD passed in 12 seconds and drained with status 0. No native runtime executed;
the seven native failures and pending instrumented acceptance remain unchanged.

## Eighth native failure: queued activation refusal

The corrected instrumented candidate captured tree
`fc22f9cdf3f9f1bbca8eb49fef52fdd1d49d0d1b` on `2d66e76`, driver
`srwdrxmifg3r3mal5i6qkbc6dx4pf8fh-nixos-test-driver-overalls-clone-cancellation.drv`
and runtime `bf57vvksi24v7vpp2ysrb3d5rrzxihg9-vm-test-run-overalls-clone-cancellation.drv`.
Its strict driver build passed in 318 seconds. The installed test script matched
the evaluated SHA256
`b3d44c59f990e7b902f594442b2467539ec239126f450a7d65172aa66601990c`, with no Inception
scenario. Installed recorder/instrumenter bytes matched frozen sources; both
service paths selected the reviewed wrapper and host ZFS 2.4.4 executable. All
context-helper executable instructions matched the independently checked helper
after removing line-location instructions. Release BEAMs omit abstract code, so
the initial abstract-code comparison did not succeed.

**Recorded instrumented run12 failed before physical capture.** Boot passed in
79.57 seconds, authenticated capacity/private-service setup in 168.07 seconds, and
source creation/seeding in 71.52 seconds. The first manual advance failed with
`phase=failed, failure=unknown`; public cancellation was not reached. The wrapper
failed in 336 seconds, framework cleanup took 2.48 seconds, and session `45292`
drained with status 1. Both agents independently confirmed all 18 owned PID/start
identities absent. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790396926105-1117129-0.jsonl`.

Both private recorder directories were retained and extracted after process drain.
Directory/file modes and copy hashes matched. Source host `l1` retained four
samples, the other host two. All six commands returned zero, with empty stderr and
no truncation; all three consecutive query pairs had identical bytes. Every sample
had missing readiness context. No readiness-failure event occurred. These samples
establish bounded native recording and collection, not readiness-map pairing or
accounting replay. The earlier seventh failure remains a separate pool-observation
result; this run does not identify its cause.

At `04:34:17.238Z`, `clone.failed` reported `activation_failed`. The coordinator
folds most stored activation reasons into that event; the fixture's finite label
set omitted activation reasons. Read-only offline extraction from the retained
disposable DB recovered the exact stored refusal: **`source_unavailable`, inactive,
failed**. The original QCOW2 was hashed, converted to a private sparse copy, and
left unchanged. Only that copy received filesystem-journal recovery. Read-only
`debugfs` extracted PostgreSQL data; the exact PostgreSQL 18.6 executable recovered
WAL in bounded single-user mode without a listener. SQL projected only the exact
clone's failure through the source rollback-atom allowlist and bounded predicate
facts. Recovery and predicate projections succeeded, no forensic PostgreSQL remained,
the working cluster shut down, and the original image hash still matched. Original
builder and private evidence remain retained outside the repository and Nix outputs.

The retained host and pool reports were 5,767 ms old at request `finished_at`,
against the unchanged 5,000 ms guard. Their timestamps and host `updated_at`
precede failure. The other durable source predicates held: existing enabled normal
host, protocol/architecture/readiness, matching pool/hold, disk held, zero temporary
hold and no occupied source transfer slot. There were no clone effects, clone
operations or destination VM, and history records only enqueue then fail. The
manual operator command began at `04:34:11.777Z` and starts Marshall before action
dispatch. Existing evidence cannot bound the guard-to-finish delay below 767 ms;
stale retained telemetry is consistent with the refusal, but the exact failing
conjunct at activation remains unproven.

The next fixture revision waits inside the started operator for actual host/pool
receipts newer than a database-clock barrier, at most one second old and not in the
future, plus completed source operations and real source commitments. The wait is
read-only, bounded to 60 seconds with bounded queries, and calls the unchanged
coordinator once. The accepted public request is preserved. The clone-job trigger
precedes browser submissions; the caller checks that exactly two worker jobs are
scheduled beyond the test's one-hour bound, and operator mode disables dispatch.
Timeouts and later refusals remain fatal; activation labels now include the finite
ordinary-profile rollback reasons. There is no production predicate change or
blind retry. Native execution of this revised precondition wait remains pending.
Architecture impact: fixture evidence and observability under ADR-0055 change;
accepted authorization, freshness, capacity, execution and recovery decisions remain
unchanged. ADR-0066/0072/0092 evidence retains its existing scope and gaps.

The exact new `FleetOperator` module and required lifecycle helper compiled under
the pinned runtime without running bootstrap or actions. Current Marshall and both
fixture helper BEAMs were then analyzed together with the dependency PLT:
**current Marshall and fixture operator Dialyzer findings: zero**. Sessions `10715`
and `71382` drained with status 0; logs:
`/tmp/verify020-post-run12-activation-compile.log` and
`/tmp/verify020-post-run12-activation-types.log`. Pinned driver Ruff and formatting
also passed. These are compilation/type checks, not a new full component gate.

The exact new SQL was extracted from the helper and prepared/executed read-only
against the recovered PostgreSQL 18 schema. Preparation succeeded and the failed
request remained refused. The initial forensic harness split multiline SQL into
individual commands and failed; its log is retained separately. Corrected one-line
preparation verifies schema compatibility and that negative case only. Neither
positive wait completion nor native activation is established by this offline check.

Published `fff6587e48b91897484dd9aa6a6ad769d26eb8f4` was integrated before the next
candidate freeze, including terminal attachment histories, configured Hegel
recognition and guest CLI supervisor recovery. Both strict fleet variants retain
their independent options and drivers. Their recorded scopes remain unchanged;
run12 remains the exact `fc22f9cd` tree on `2d66e76` with its original retained
builder and private evidence. The pre-integration working state is retained as
stash `71fbca267c79c938f096c9d60eb14e768b277a0e`.

## Ninth native failure: admission reports rejected

The integrated candidate captured tree
`5dce161c81829c403f249f74064af5136b4af5cc` on
`fff6587e48b91897484dd9aa6a6ad769d26eb8f4`, driver
`aqvz2g869x4czmkjf0w6d47c7vzq1z6b-nixos-test-driver-overalls-clone-cancellation.drv`
and runtime `iq1vhb1gr2qc6n46aqrdrq5il4fmwzfn-vm-test-run-overalls-clone-cancellation.drv`.
ADR/contracts/HLDD/generated options, scenarios and views, all-file prek and Nix
HLDD/Python checks passed. The strict driver build passed in **409 seconds**;
session `3361` drained with status 0. The exact installed script matched evaluated
SHA256 `318745c194a561e5825cc5d436dc9d47f07d5b2037094b410157d3372733825d`, with
one initial activation call, composed typing/Ruff and no Inception scenario.
All three installed operators matched frozen source. Both recorder/instrumenter
sources, wrappers, selected native ZFS and public pool identities matched the
reviewed artifacts. Installed readiness-helper and ZFS BEAMs were byte-identical
to run12's independently checked BEAMs; no new abstract-code comparison is claimed.

**Recorded run13 failed before source creation or clone activation.** Boot passed
in 71.56 seconds; the initial 300-second fresh-host-report wait timed out. The native
wrapper failed in 402 seconds, cleanup took 4.18 seconds, and session `81806` drained
with status 1. Both agents independently verified all 18 owned PID/start identities
absent. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790399385281-1763258-0.jsonl`.
The retained builder remains
`/nix/var/nix/builds/nix-1763285-3581077231/build`. Recording was never armed;
there are no run13 readiness samples or new activation-wait acceptance. Run12's
original builder and private forensic evidence remain unchanged.

Both Lilly instances started and connected. The catalog records 31
`lilly.control_exchange_failed` events with `reason=invalid_report` and
`utility=execution`, accompanied by unavailable/recovered transitions. The first
failure was at `05:13:24.114Z` and the last at `05:16:17.121Z`. This is Marshall's
report refusal during initial admission, separate from run12's queued clone refusal.
No clone or readiness-failure event was observed, and the recovered database has
zero VMs and zero clone requests.

After independently verified drain, bounded offline analysis again hashed the
original disposable database image, converted a private sparse copy, recovered
only that copy's filesystem journal, and extracted PostgreSQL 18 read-only. The
exact PostgreSQL 18.6 executable recovered WAL and queried finite predicates in
single-user mode without listeners, preloads or external recovery commands. The
working copy shut down cleanly and the original image hash still matched.
Private evidence is retained outside the repository and Nix outputs under
`/home/ghuntley/.local/state/overalls-verification/020-run13-forensics`.

Both hosts had accepted protocol-3 x86_64 execution-ready reports containing one
image, correct enrolled pool/dataset GUIDs and logical budget, and empty allocation
maps. The last accepted source timestamps were `05:14:04.338462Z` (l1, sequence 7)
and `05:14:04.718492Z` (l2, sequence 3); their host row update timestamps were
`05:14:07.671217Z` and `05:14:08.917463Z`. Those row timestamps do not identify
the validation instant or transaction commit. Telemetry retained two accepted l1
samples and one l2 sample, with native I/O collection intervals of 1,189–1,230 ms
and 1,325 ms respectively. These are accepted-report facts, not measurements of
the rejected reports.

The validating Marshall/Lilly/protocol source is unchanged between the captured
bases. `HostReports` checks sample age, exact pool entries/identity/accounting,
capacity schema/bounds, protocol, image IDs and architecture. The collector retains
its sample-start timestamp and bounds native I/O waiting; the five-second admission
guard remains unchanged. Rejected report bodies and their validation clock are
not durable: report/history writes roll back and Lilly retains samples only in
runtime state. Available evidence therefore does not establish the exact failed
predicate or overload causality. A finite diagnostic at the actual rejection
boundary is the next proposed investigation; no production guard, polling bound
or resource requirement has been changed, and no further native runtime is granted.
Architecture impact remains verification evidence under ADR-0055; accepted
freshness, storage, capacity, authorization and cleanup decisions are preserved.

## Integrated staging recovery and fixture-only report rejection evidence

Published `186a1ea4` is integrated. The pre-integration work remains in stash
`131340117967ec73633fe8bc6a27119693354f85`; all earlier stashes, nine failed
native captures, retained builders and private offline evidence remain intact.
The merge preserves upstream bundle/disk checks before one restart child check,
then ownership, mounts and recognized receive staging before the single whole-pool
observation. Only restart supplies the placement diagnostic context; preparation
and resize remain unchanged. Upstream's isolated owned-staging pass and production
retry/bidirectional relocation evidence retain their independent scopes. The changed
Lilly call order means run13's installed BEAM identity comparison cannot qualify
a future candidate. Integrated Lilly `mix precommit` passed **413 checks**
(50 properties, 363 examples), with zero forced Dialyzer errors or skips;
`/tmp/verify020-integrated-lilly-precommit.log`, session `70316`, status 0.

The next diagnostic is confined to the clone-cancellation release. The
[instrumenter](../../../nix/verification/tests/support/instrument_clone_reports.py) pins hashes
of both `HostReports` and its actual authenticated `ProvisionerControl` caller.
It wraps the original `valid?/3` boolean operands in their existing `and` chain
and adds diagnostics inside subsequent rejection branches. Predicates retain
order, short-circuit behavior and one evaluation. The original database `now`,
rollback and external `invalid_report` result remain unchanged. The wrapper
`HostReports.ingest/3` is not relied on for authenticated exchange evidence.
Malformed report shape records no age and does not inspect invalid fields.

The [fixture helper](../../../nix/verification/tests/machines/clone-cancellation/report_rejection.ex)
accepts only eleven fixed stages: report shape, future sample, expired sample,
pool schema, pool set, storage identity, capacity schema, capacity bounds,
protocol, image IDs and architecture. Each record has only `stage` and signed
`sample_age_ms`, computed from the exact guarded sample and database time; age is
null for a malformed shape. The authenticated caller already fences protocol 3;
the later protocol stage covers the trusted ingestion guard without weakening
that earlier fence. These are rejected-guard observations, never committed
reports or outcomes. They survive transaction rollback in private fixture files,
with no application event, payload, host identifier, credential, arbitrary state
or raw report export.

Each replica retains only its first rejection per stage and interval, at most
eleven mode-0600 files of 160 bytes each, plus one equally bounded staging file per
stage beneath its mode-0700 runtime directory. This is neither a timeline nor
host attribution. Only this fixture's admission and clone intervals arm the sink.
The driver disarms, waits for staging publication and copies failure evidence to
a private builder directory outside Nix outputs before teardown; `--keep-failed`
remains required. Successful intervals discard their rings. Sink failures preserve
the original validation result. No resource, polling, freshness or capacity guard
is relaxed, and instrumented timing is not performance evidence.

The [dedicated tests](../../../nix/verification/tests/machines/clone-cancellation/report_rejection_test.exs)
passed **7 checks**, seed `239871`, in the isolated `_verify020_reports` database
partition; `/tmp/verify020-report-tests-final.log`, session `71205`, status 0.
Removing only diagnostic calls restores the original complete source AST. Original
and instrumented authenticated exchanges return the same accepted, stale-report,
stale-session and invalid-report results. A refused exchange rolls back a prior
synthetic physical outcome and report mutations while retaining its guard age;
a subsequent valid exchange succeeds. The tests cover predicate short circuit,
malformed shape, ordered guard stages, disabled/broken sinks, first-record retention
and concurrent bounded publication. Exact-source drift and duplicate rejection,
pinned Python format, Ruff and typing also passed. These are fixture semantics and
synthetic coordinator evidence; no native admission or cancellation pass is claimed.
The initial six-check version also passed, seed `378718`.

Future capture still requires frozen source, strict composed driver and release
builds, installed artifact comparison and an exact native execution grant. This
instrumentation cannot retroactively identify run13's rejected predicate or prove
an overload explanation. Architecture impact remains diagnostic verification under
ADR-0055, preserving the capacity/freshness requirements carried through ADR-0013,
ADR-0031 and subsequent storage/capacity decisions. No accepted decision changes.

Update 2026-10-31: commit `048bee858` added the per-pool `observed_at` guard
(`observed_before?/2`) to `valid?/3` between pool schema and pool set, so the
pinned `HostReports` hash no longer matched and scheduled run 41208554953 failed
to build the clone-cancellation Marshall release. The instrumenter now pins the
new source and wraps that operand in place as the `pool_observed_at` stage, with
order, short circuit and single evaluation preserved. The fixture accepts that
stage alongside the others; its dedicated tests add the stage to guard ordering and
bounded publication. No guard, rollback or accepted decision changes.

The exact helper and instrumented `HostReports` compiled against current Marshall;
forced success typing across current application BEAMs plus both fixture BEAMs
reported **zero findings**, `/tmp/verify020-report-types.log`, session `96205`,
status 0. Production HostReports source and compiled application artifacts were
not replaced on disk. Source/contract review traced the one authenticated exchange
caller, the trusted wrapper, all seven instrumenter replacements, helper publication
and both driver intervals. It found no contract conflict in that inspected scope.
The AST comparison also checks unchanged host/pool writes and rollback sites;
private sink evidence remains explicitly outside committed-outcome logging.

### Full component gate and final upstream integration

The frozen `186a1ea4`-based tree
`76d921772ba63411673a35b073f22921611b79a3` passed Marshall `mix precommit`:
**1,182 checks** (136 properties, 1,046 examples), two existing exclusions, seed
`747825`, in 857.9 seconds (31.4 async, 826.4 sync). Pinned runtime, compiler,
ADR/HLDD/contracts/logging, browser/TypeScript and forced Dialyzer passed;
Dialyzer reported zero errors, skips or unnecessary skips in 1 minute 27.5 seconds.
Session `15625` drained with status 0; source still matched that tree.
`/tmp/verify020-integrated-marshall-precommit.log` retains the result.

The read-only post-drain audit of its isolated `_verify020_integrated` partition
retained 1,346 rows across 138 public tables, inventory SHA256
`275876f0be8deecb09fa77edd83b7029693343878487c860688eb5b220f21357`.
Five agent tables contain 64 rows each; the other eight are empty. Other retained
rows are 465 lifecycle events, 215 job events, 207 job snapshots, one bootstrap
row and 138 migration rows. No complete pre-run inventory was captured, so this
whole-suite remainder is retained and unattributed; no reset or deletion was used.
There were zero other database connections, advisory locks or worktree BEAMs,
and only the four expected production triggers. Private payload-free row hashes
remain under `~/.local/state/overalls-verification/020-gate-186/`; the original
historical detached-agent residue and all native builders/evidence remain untouched.

After that drain and audit, published `1db02e1d` integrated campaigns 029 and 034.
The pre-integration working state remains in stash
`3cc1ac5c0e9f5b18dd5cb48a64343b8d07976244` and a separate backup patch. Only the
review-receipt file conflicted. All production Marshall/Lilly/protocol source,
clone driver/operator and diagnostic sources remain byte-identical to the frozen
fullgate tree. The report source hashes and exact instrumented output also match.
Upstream adds committed-test cleanup/inventory helpers and their consumers, an
updater compatibility check and independent documentation/evidence; it changes
neither this guarded runtime path nor the nine failed native scopes. The broad
suite is not repeated for that integration; targeted cleanup inventory preservation
and final static/build qualification are recorded below.

## Final qualification on the `1db02e1d`-integrated tree

All commands ran from this worktree in the pinned `devenv shell` with
`ERL_FLAGS='+S 4:4'`, `PGHOST=/run/user/1000/devenv-0e19ff2/postgres` and
`TMPDIR=/tmp/overalls-verify020fin`. The reconciled final tree is the staged
`1db02e1d` integration plus documentation-only review/ADR/campaign prose; the
previously unstaged edits contained no source or debug changes.

- **Focused Marshall clone and cleanup suites** passed on the final tree:
  `mix test test/marshall/committed_fixture_cleanup_test.exs
  test/marshall/compute/clone_history_test.exs
  test/marshall/compute/clone_ordering_test.exs --include distributed` under
  `MIX_TEST_PARTITION=verify020fin`: **16 checks (5 properties, 11 tests)**,
  seed `370884`, in 40.7 seconds. These are the upstream post-029
  cleanup/inventory preservation property and its three fixed tests, the four
  clone history properties, and the eight explicit distributed ordering/cleanup
  schedules. The earlier post-029 focused cleanup run passed seed `329985`
  (`/tmp/verify020-post029-cleanup-property.log`, 4 checks, 24.4 seconds);
  log: `/tmp/verify020-fin-marshall-focused.log`.
- **Full Lilly gate** reran on the final tree because upstream additions moved
  shared source: `mix precommit` in `lilly/` passed **413 checks** (50
  properties, 363 tests), seed `312581`, in 13.2 seconds of test execution, with
  code contracts (101 CONTRACTS files, 1,809 native notes, 122 parsed sources),
  `logging.check` (83 catalogued events) and the ADR check (124 decisions).
  Forced test-environment Dialyzer reported zero errors, skips and unnecessary
  skips in 12.48 seconds. Log: `/tmp/verify020-fin-lilly-precommit.log`.
- **All-file static hooks** passed: `prek run --all-files` reported logging
  checks for all eight applications, ruff, ruff-format and ty, all green.
- **ADR and generated-reference gates** passed: `elixir scripts/check_adrs.exs`
  (124 decisions; structure and local links), `hldd_options.exs --check`,
  `hldd_coverage.exs --check` and `hldd_views.exs --check` reported the Ash and
  deployment views current.
- **HLDD receipts:** five groups (marshall, lilly, services, deployment,
  governance) were stale after the chapter/scenario and documentation
  integration; each was reviewed against the actual diff and re-recorded with
  its concrete rationale, after which `elixir scripts/check_hldd.exs` passed.
- **Nix evaluation and HLDD gate:** the final tree's clone-cancellation
  composition evaluates to
  `/nix/store/nlbb6zr3smskd87pn0s3c7cs2fpd9w2d-vm-test-run-overalls-clone-cancellation.drv`
  with strict driver
  `/nix/store/78xrsbc7jqhkyh4yp8iij0qawq8fpar2-nixos-test-driver-overalls-clone-cancellation.drv`;
  the longstanding `network-online.target` ordering evaluation warning is
  unchanged. `nix build .#checks.x86_64-linux.hldd` passed.

Not rerun in this final qualification: the broad Marshall suite (the frozen
`76d92177` full gate above retains that scope), any native NixOS machine run,
and the composed instrumented driver build. Native acceptance and the readiness
map pairing remain pending as recorded throughout this review.
