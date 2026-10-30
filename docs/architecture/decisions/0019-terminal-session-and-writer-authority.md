# ADR-0019: Terminal session and writer authority

- ID: ADR-0019
- Date: 2026-09-15
- Status: superseded
- Implementation: implemented
- Components: Marshall Terminal, Accounts, Access, Compute, Lilly console relay
- Supersedes: none
- Superseded by: ADR-0083

## Context

ADR-0008 requires several console readers and one writer across Marshall nodes,
with revocation affecting existing connections. Persisted sharing now exists, but
neither a cached browser actor nor a database lease alone can protect a physical
console from delayed input. The authorized implementation needs a durable source
of session authority and an explicit host acknowledgment before writer handoff.

## Decision

Add an Ash Terminal domain. Sessions belong to a registered user and one VM
generation. Opening verifies a signed AshAuthentication user token, rejects actor
tokens, checks its subject against the caller, and requires a current stored user
token. Retain only the encrypted token identifier, never the bearer token. Every
subsequent read/refresh, writer claim and input authorization checks token presence,
expiry and current persisted Cedar permissions. Revoked login tokens cannot keep
authorizing an old in-memory actor. A session ID is an immutable opening identity: retries must
match its VM/user/generation/token, and closed IDs cannot be reopened.

Use PostgreSQL time for a 30-second session lifetime, capped by account-token
expiry. Clients must refresh before expiry. Cap unarchived sessions at 64 per VM
and 8 per user/VM. Prune expired sessions during opening and host polling; an
AshOban trigger performs idle cleanup. Expiration workers acquire the VM lock and
recheck expiry so a delayed job cannot close a session already renewed. Sessions
are archived; AshPaperTrail records opening and closure metadata. Routine session
and lease renewals do not generate audit versions. Encrypted identifiers are
excluded from audit history.

One unique Writer resource per VM retains a monotonically increasing fence epoch.
Claims serialize on the VM row. The first eligible claimant gets a **pending**
10-second lease, capped by session expiry; other sessions receive `writer_busy`.
There is no forced takeover or fairness queue initially. Repeating a pending claim
does not extend it. Only an authenticated current execution-host session may
acknowledge the exact VM generation and fence epoch to make the claim **active**.
An active writer can renew while refreshing its valid browser session. Expired
leases require a new epoch and host acknowledgment.

A pending claim cannot authorize input. Release, closure, read-access revocation,
write-access downgrade, stale host connection and expiry invalidate writer
authority. A new claimant always needs a newer host fence. Grant changes close or
invalidate sessions in the same VM-locked transaction. Lifecycle generation
changes and non-running physical outcomes close all sessions. New sessions require
a running observation and completed start/provision operation for the current
generation, preventing an old running observation from admitting a new console.

The lock order stays host then VM for authenticated host calls; user session and
grant mutations acquire VM and never lock the host afterward. Each operation
rechecks session state after acquiring VM. Internal resource actions are available
only to the trusted coordinator actor; explicitly mapped public generic actions
still apply fresh record-level authorization.

**Physical enforcement is a required next boundary.** Lilly must install the
generation/epoch fence and discard older pending input before acknowledging it.
It must serialize input through one console owner, reject delayed or duplicate
frames, enforce a local monotonic deadline on any remote authority, and bound
input/output queues. New input cannot use a returned authority snapshot as a
browser-provided bearer capability. The relay must obtain authority itself for
every input and recheck reader authority before delivering output. No network
terminal endpoint is enabled by this foundation alone.

## Alternatives

A node-local writer registry allows multiple writers on different Marshall nodes.
A database lease that becomes active immediately can overlap delayed input from
the previous holder. Trusting socket authentication for its entire lifetime keeps
revoked tokens effective. Recording only the user ID loses the connection to the
specific login that authorized the session. Deleting session history permits
opening-ID reuse and loses closure evidence.

## Consequences

Loss of database access fails closed. Session refresh and per-input checks add
database work; fleet and terminal-load validation remains necessary. Session and
writer history consume storage and need a future audit-retention policy. A lost
writer waits for expiry or explicitly releases; no operator may infer physical
fencing from a timeout alone. Database timestamps do not replace Lilly's monotonic
deadline. A physical revocation-latency guarantee requires the completed relay and
fault tests, not just the configured session/lease intervals.

Deploy the additive terminal tables and the fence-constraint migration before
new Marshall code. The constraint rejects null host epochs in non-idle claims,
including SQL's otherwise-permissive unknown result for a null comparison.

## Invariants and verification

- No pending, expired, revoked or foreign session can authorize input.
- Concurrent claims through three nodes produce one writer.
- Old host credentials, sessions, generations and epochs cannot activate a claim.
- Role downgrade, lifecycle changes and account-token revocation reach existing
  sessions; token/role checks occur independently of the UI.
- Delayed expiration jobs cannot close renewed sessions.
- Identifier encryption and audit exclusions hold for persisted records.
- Physical handoff, ordered bounded relay, local deadline and restart behavior
  require protocol properties and real console fault tests before remote access.

## Implementation evidence

[Terminal domain](../../../marshall/lib/marshall/terminal.ex),
[sessions](../../../marshall/lib/marshall/terminal/session.ex),
the writer resource,
[authority coordinator](../../../marshall/lib/marshall/terminal/authority.ex) and
identity checks implemented the
control-plane state and checks. The
[initial migration](../../../marshall/priv/repo/migrations/20260915204124_add_terminal_authority.exs)
adds the tables and the
[constraint migration](../../../marshall/priv/repo/migrations/20260915204802_enforce_terminal_fence_invariants.exs)
enforces complete writer state, including non-null host epochs. The
the expiration change
supports the AshOban session-cleanup trigger.
[Sharing](../../../marshall/lib/marshall/access/sharing.ex),
[lifecycle](../../../marshall/lib/marshall/compute/lifecycle.ex) and
[outcomes](../../../marshall/lib/marshall/compute/outcomes.ex) invalidate sessions
under their existing VM lock.
Authority tests and
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
exercise the control-plane rules. See the
[review](../reviews/2026-09-15-terminal-authority.md) for verification and limits.
[ADR-0020](0020-local-console-fences-and-bounded-streams.md) implements Lilly's local
gate. [ADR-0021](0021-console-relay-connections-and-mailboxes.md) implements the
wire codec, HTTPS client/server, encrypted mailboxes and VM-actor integration.
[ADR-0022](0022-browser-terminal-and-live-login-checks.md) now adds the browser UI,
fixed geometry, bounded input and reconnect behavior.
The [three-node production browser harness](../../../nix/verification/tests/README.md)
now verifies real guest writer handoff, grant/login revocation and explicit writer
reacquisition after lost replies and Marshall process death. See the
[review](../reviews/2026-09-16-terminal-failover.md) for evidence and limits.

Lock-order correction (2026-10-30): two callers violated this ordering and
deadlocked in fleet machine runs. `ModelCalls.queue/3` locked the VM and then
the host, through its ModelCall host foreign key; it now takes the host
key-share lock first
([`model_calls.ex`](../../../marshall/lib/marshall/agents/model_calls.ex),
`model-call-queue-host-before-vm`). Galileo configuration referenced its User
before its peer VM, while guest roster pulls lock the VM and then its writers'
User rows. Configuration and attachment now take FOR KEY SHARE on the VM first
([`configurations.ex`](../../../marshall/lib/marshall/galileo/configurations.ex),
`galileo-vm-before-user-rows`). Committed two-connection regressions block each
action behind the competing lock and probe the next lock with NOWAIT
([`model_call_lock_order_test.exs`](../../../marshall/test/marshall/agents/model_call_lock_order_test.exs),
[`configuration_lock_order_test.exs`](../../../marshall/test/marshall/galileo/configuration_lock_order_test.exs)).
Without the fix, queue and peer configuration fail that probe with
`lock_not_available`. The attachment case passed even before the change, so it
guards the order rather than reproducing a failure.

## Open questions

Extend the verified three-node, single-host browser path under ADR-0022 with
reordered/delayed transport messages and Lilly restart during input.
Measure database load before claiming support
for the intended fleet and terminal session counts. Define historical audit retention.

## Related decisions

[ADR-0003](0003-control-plane-coordination.md),
[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0016](0016-executable-generations-and-lifecycle.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md).
