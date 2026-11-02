# ADR-0280: Remote Underclass and safe agent retries

- ID: ADR-0280
- Date: 2026-11-02
- Status: accepted
- Implementation: partial
- Components: Marshall, Ziggy, Underclass, fleet
- Supersedes: ADR-0100, ADR-0102
- Superseded by: none

## Context

A newly created Dungarees machine admitted its initial joke prompt, but its
local Underclass had zero accounts and returned HTTP 503. Marshall reset the
claimed model-call row to queued; Ziggy's second admission reused the consumed
request ID and failed. The saved request completed through Panterloons's pool.
The operator explicitly authorized forwarding Dungarees inference to Panterloons,
UUIDv7-only Underclass correlation, bounded fresh-attempt retries, and recovery
of the affected thread, then requested implementation of the reviewed plan.

## Decision

Carry forward ADR-0100's PostgreSQL authority, pulled host-bound model work,
durable pre-dispatch admission, fencing, content custody and uncertain-result
no-replay rule. Carry forward ADR-0102's private local account databases,
loopback HTTP listeners, supervised Tailscale Serve publication, distinct proxy
and administrator credentials, and separate read-only local monitor sockets.
This replacement changes the compulsory independent-pool routing requirement:
Dungarees Ziggy uses the explicitly allowed Panterloons tailnet HTTPS origin.
Only Panterloons's proxy key enters Dungarees's dedicated encrypted bundle.
Provider account state and administrative credentials remain on Panterloons.
Dungarees's existing local pool remains independently available to operators.

Every new inference request uses UUIDv7. The model-call ID is the admission ID
and outbound `x-request-id`; Underclass preserves it across internal attempts
and responses. Invalid, duplicate or UUIDv4 correlation headers are replaced
before authentication and logging. Existing account identities and receipts
remain opaque stored values. Credentials and PKCE entropy use OS randomness,
not time-based identifiers. Catalogued diagnostics record identifiers, bounded
status/duration and closed failure categories, never payloads or credentials.

Underclass may certify a held terminal overload with
`x-underclass-retry-safe: pre-output-overload` only when every attempted response
proves an explicit overload before output. Generic failover permanently clears
eligibility. The final response selector owns the header; inbound/provider
values cannot confer eligibility. Ziggy independently requires one exact header,
the exact overload terminal, completed transport and monotone no-output proof.
Unknown/malformed events, overflow, cancellation, contradictions and transport
loss prohibit this certificate's use. The control result uses the closed error
`retryable_overload`; accounting documents and protocol versions are unchanged.

Marshall retains every failed attempt and allocates a new UUIDv7 model call for
an eligible retry. A consecutive rejection streak permits three attempts total,
with one- and two-second delays calculated from persisted completion times.
Successful model/maintenance work ends the streak; existing turn limits remain.
Ordinary failures, quota exhaustion, empty pools and uncertain results do not
retry. Completion delivery may repeat the same receipt, never provider work.

## Alternatives

Onboarding Dungarees's empty pool or relocating the VM was explicitly declined.
Copying the account database would duplicate provider credential custody.
Requeuing the same call violates durable admission identity. Retrying generic
503s is unsafe because pool exhaustion can follow an ambiguous upstream attempt.
Allowing arbitrary configured origins expands the credential destination beyond
the reviewed fleet requirement.

## Consequences

Panterloons pool availability now affects Dungarees inference. Host authority,
VM placement, usage attribution and execution fencing stay on their existing
paths. Proxy-key rotation must update the Panterloons source and Dungarees's
proxy-only encrypted copy together. Local monitor readiness still describes
the local pool, not Ziggy's remote provider route. UUIDv4 correlation clients
receive newly assigned v7 IDs rather than cross-proxy preservation.

## Invariants and verification

- Preserve one UUIDv7 through admission, provider proxy logs and final response.
- Keep proxy/admin authentication separate and verify remote TLS normally.
- Never replace a terminal failed attempt with queued work or reuse admission.
- Preserve uncertainty, output evidence and the bounded retry streak on restart.
- Verify mixed failover chains cannot retain a stale retry certificate.
- Verify duplicate completion delivery cannot cause another provider request.

## Implementation evidence

The [host configuration](../../../fleet/hosts/dungarees/configuration.nix) selects
the remote endpoint and proxy-only runtime secret. The
[profile](../../../nix/platform/hosts/profile.nix) permits this reviewed override
while retaining local pool custody. The
[Ziggy transport](../../../ziggy/lib/ziggy/upstream.ex) and
[agent collector](../../../ziggy/lib/ziggy/agent_stream.ex) implement correlation
and independent retry proof. The
[model coordinator](../../../marshall/lib/marshall/agents/model_calls.ex) and
[loop](../../../marshall/lib/marshall/agents/loop.ex) retain durable attempts.
The [machine fixture](../../../nix/verification/tests/machines/ziggy-underclass/default.nix)
uses real packages over local test TLS on two nodes. The
[implementation review](../reviews/2026-11-02-agent-startup-inference.md) records
the separate production Tailscale TLS/authentication probe and completed repair
on the original VM, with one UUIDv7 across all three services.
Historical ADR-0100 and ADR-0102 verification gaps are not implicitly closed.

## Open questions

None for the accepted behavior. The scoped production repair and live-provider
acceptance are recorded above; inherited verification gaps keep the broader
implementation partial.

## Related decisions

[ADR-0042](0042-host-observability.md),
[ADR-0174](0174-user-threads.md),
[ADR-0178](0178-durable-agent-context-and-planning.md),
[ADR-0246](0246-panterloons-control-plane-deployment.md).
