# ADR-0237: Windows custodian same-boot recovery by logon-session quiescence

- ID: ADR-0237
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: Windows editor custodian, Windows editor broker, Windows image
- Supersedes: none
- Superseded by: none

## Context

[ADR-0208](0208-windows-editor-job-custodian.md) clause 11 accepts that custodian
death ends owned workers through `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and that a
restarted custodian creates a new validated worker, preserving personal files,
rather than adopting a vanished job name. Missing, foreign or incomplete custody
must still refuse cleanup or replacement.

The source that implemented ADR-0208 could not satisfy both requirements. A
bounded native experiment had shown that a named job disappears from the object
namespace when its final handle closes even while an assigned child is still
alive. Kill-on-close requests termination, but termination is asynchronous and
a restarted custodian holds no handle through which to count descendants. The
source therefore refused every existing receipt in the same physical-boot
namespace, leaving an account's editor unavailable until a new MMDS boot. That
conservative refusal was safe but left clause 11 unimplemented, and it blocked
the `windows-editor-v1` candidate from any acceptance journey that includes a
custodian crash.

Two kernel facts provide a narrower proof than job membership. Each worker
launch performs its own S4U `LsaLogonUser`, which creates a new LSA logon
session whose LUID is unique within the boot. Every process created from that
token, including restricted-token children, inherits that `AuthenticationId`; an
unprivileged personal process cannot mint a token for another session. A
process list that contains no process of that account SID and logon session
therefore contains no surviving process of that worker launch. These are
documented Win32 semantics, not yet native evidence for this image.

The user has authorized completing the Windows browser editor implementation,
including same-boot recovery after a custodian crash. That task authorization
establishes acceptance of this record; production selection remains bound to
ADR-0208 clause 8 and recorded native evidence.

## Decision

1. **Number every custodian lifetime.** After reserving its exclusive
   first-instance local endpoint, and before admitting any request, a custodian
   reads the SYSTEM-only `generation.json` in its physical-boot namespace,
   takes a strictly greater nonzero generation and durably publishes it with
   the existing private write-through rename. Absence starts at one; malformed,
   unreadable or overflowing records refuse startup. Endpoint reservation first
   means a live predecessor prevents its successor from taking a generation.

2. **Scope kernel names and receipts to that generation.** Job names become
   `Global\overalls-editor-<uid>-g<generation>-<key>` and worker pipe names
   `\\.\pipe\overalls-editor-<uid>-g<generation>-<key>`. Version-2 receipts add
   the generation and the worker token's logon-session LUID to the existing
   SID-bound identity, binding and root process identity. A live retained slot
   is reused only when its receipt generation and logon session equal the
   current custodian's held worker. Version-1 receipts never authorize recovery.

3. **Admit a cold receipt only from an earlier lifetime.** When an account
   slot is empty and a receipt exists, recovery may proceed only if the receipt
   generation is strictly less than the current generation, its stable worker
   identity equals the currently admitted account/SID/placement/epoch/release/
   origin identity, and its generation-scoped job name no longer opens
   (`ERROR_FILE_NOT_FOUND`). Current or future generations, identity drift, a
   surviving job and any probe error refuse without adoption or deletion.

4. **Prove logon-session quiescence before replacement.** The custodian takes a
   complete `TH32CS_SNAPPROCESS` snapshot and opens each entry with
   query/synchronize rights. An entry is a straggler only when it was created no
   earlier than the recorded root and its token has the exact recorded account
   SID and logon session. Earlier processes, other accounts, other sessions of
   the same account, non-account principals, exited entries and unopenable
   entries parented by Idle or System are unrelated. Any other unopenable entry
   or unreadable token of a possible descendant is ambiguous and refuses the
   whole pass. Snapshot errors refuse.

5. **Terminate only re-verified stragglers.** Each planned straggler is reopened
   with terminate rights. Termination proceeds only if that handle's PID and
   creation time still equal the plan and its token still has the exact SID and
   logon session; PID reuse leaves the new process to the next complete pass.
   Failure to observe exit within two seconds refuses. At most eight passes run;
   only an observation with zero stragglers authorizes removal of the exact
   account's private receipt and a fresh launch under the current generation.
   Personal profile and workspace files are never touched.

6. **Keep every other ADR-0208 boundary.** The broker remains a stateless
   gateway that never receives job handles. Broker death still preserves the
   custodian's workers. Retained-custodian root loss still requires exact-job
   zero-descendant accounting. The 64 account slots, 128 pipe reservations,
   quarantine, peer and promotion rules are unchanged.

## Alternatives

Continuing to refuse until a new physical boot was rejected because it leaves
ADR-0208 clause 11 unimplemented and turns any custodian fault into an
account-level outage until a guest reboot. Treating a missing job name or dead
root as proof of quiescence was rejected because the native experiment showed
both can be true while a descendant lives. Enumerating processes by account SID
alone was rejected because it would terminate the account's other legitimate
sessions, such as remote terminal or interactive logons. Matching by executable
image was rejected because terminal descendants run arbitrary programs.
Keeping job handles alive in a second keeper process was rejected by ADR-0208
because it reintroduces a split launch transaction. Waiting on
`LsaGetLogonSessionData` for the session itself to disappear was rejected as
the sole proof because services may hold token references after every process
has exited, which would refuse recovery without a surviving process.

## Consequences

A crashed custodian's accounts can obtain a new worker in the same boot once
kill-on-close has completed, or after the custodian terminates any straggler of
the exact prior session. The custodian gains one new destructive authority:
terminating processes it identifies by kernel creation identity plus exact
account and logon session rather than through a held job handle. That authority
is narrower than account-wide termination and is exercised only after the
earlier lifetime's job no longer exists.

Recovery can still refuse: an unobservable possible descendant, a stuck
termination, a surviving prior job or identity drift keeps the receipt and the
account's editor refused until the condition clears or a new physical boot. A
personal process that escapes the logon session through another credentialed
service (for example a scheduled task registered by the user) was never covered
by job kill-on-close either and is not covered here. The changed broker and
installer payload require a newly bound immutable candidate.

## Invariants and verification

- Generations strictly increase within a namespace, never repeat or wrap, and
  scope every job, worker pipe and receipt. Portable property tests cover
  successor monotonicity, distinct generation-scoped names and serde refusal of
  zero.
- A cold receipt from the current or a future generation, with drifted identity
  or a surviving prior job, refuses before any process is observed or
  terminated. A property test enumerates those combinations and checks that the
  job probe is not reached for stale generations or drift.
- Straggler planning never selects another account, another session of the same
  account, a process created before the recorded root, or an unrelated
  principal; ambiguous observations refuse. A generated process-table property
  test exercises respawning and stubborn stragglers, unobservable entries and
  unreadable tokens, and checks that recovery succeeds only with zero remaining
  session processes and terminates only exact-session processes.
- Scan and termination errors propagate as refusal.
- Native evidence must still establish: kill-on-close termination bounds after
  a real custodian crash with root and descendant processes alive; complete
  snapshot classification on the candidate image, including that no ordinary
  process is unobservable; straggler termination under a real S4U session;
  preservation of another session of the same account; and the packaged browser
  journey resuming on a new worker with files preserved.

## Implementation evidence

The [portable model](../../../nix/domains/artifacts/vscode-web-broker/src/windows_model.rs)
defines `CustodianGeneration`, `LogonSession`, process observation and
classification, `prior_receipt_admission`, `straggler_plan` and the bounded
`drain_prior_session` state machine, with property and unit tests for each
invariant above. The [Win32 implementation](../../../nix/domains/artifacts/vscode-web-broker/src/windows/mod.rs)
records the S4U token's logon session before launch, scopes job and pipe names
by generation, and implements the job-name probe, Toolhelp process observation
and re-verifying straggler termination. One added SYSTEM-only native test covers
the job-name probe and snapshot classification of the test process itself; it
has been cross-linked but not executed. The
[custodian entry](../../../nix/domains/artifacts/vscode-web-broker/src/windows_main.rs)
reserves the endpoint before advancing the durable generation, writes version-2
receipts and runs recovery inside the account's single-flight slot.

These artifacts establish compiled source and portable model behavior only.
Host tests, Windows all-target Clippy and the Nix Windows broker build pass; no
native custodian crash, straggler termination or browser recovery has run. The
[review](../reviews/2026-10-18-windows-editor-job-custodian.md) records exact
commands, artifacts and the remaining native acceptance gaps.

## Open questions

Native execution must confirm that a SYSTEM custodian can classify every process
on the candidate image without ambiguous entries; if some service-hardened
process is unobservable, the rule must be narrowed with evidence rather than
relaxed. The eight-pass bound and two-second exit wait must be measured against
a real custodian crash.

## Related decisions

[ADR-0208](0208-windows-editor-job-custodian.md),
[ADR-0200](0200-windows-browser-editor-candidate.md),
[ADR-0171](0171-windows-guest-agents.md),
[ADR-0158](0158-durable-guest-identities.md); review:
[Windows editor job custodian](../reviews/2026-10-18-windows-editor-job-custodian.md).
