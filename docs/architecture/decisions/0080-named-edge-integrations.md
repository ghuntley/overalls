# ADR-0080: Named edge integrations and renewable admission leases (Galileo)

- ID: ADR-0080
- Date: 2026-09-19
- Status: accepted
- Implementation: partial
- Components: Galileo, Marshall, Audi, Porsche, protocol, NixOS
- Supersedes: none
- Superseded by: none

## Context

The user authorized a new application modeled on sample-host's HTTP proxy
integration: VM workloads call named upstream services at
`https://<name>.integration.internal` while user-provided credentials
(bearer tokens, basic auth, static headers) are injected at the network
edge and never become readable inside the VM. Configuration is surfaced
through Porsche commands and the Marshall web console. Backwards
compatibility was explicitly not required; the simplest correct design was
requested. No per-request monetary accounting is included; observability is
bounded numeric metrics only.

## Decision

Every enabled Lilly host runs an independent Galileo release, default-enabled
with Lilly, fronted by Audi's private frontend. Audi answers the closed
`.internal` namespace for the fixed integration zone suffix and routes
single-label `<name>.integration.internal` requests over a private Unix
socket with the same pre-NAT Lilly binding used by Ziggy. Galileo resolves
each request by asking Marshall to authorize the binding and integration
name; Marshall returns a fixed HTTPS target, an optional segment-aligned
strip prefix, at most sixteen validated injected headers and, for peers, a
bounded endpoint plus purpose-built token. Galileo applies the strip prefix,
injects headers (platform-computed credentials override guest-supplied
copies), and performs a single-attempt TLS-verified upstream request with
streaming and backpressure. No retry, no content capture, no persistence of
user secrets on any Lilly host.

Each admitted request carries a short relative lease. While the one upstream
attempt remains open, Galileo renews that lease through a separate Marshall
operation which repeats the source execution, ownership and attachment fences
but returns only a new bounded TTL. Renewal never repeats injected credentials,
changes the selected target or mints another peer token. Galileo converts each
TTL to a monotonic local deadline and closes the upstream attempt on expiry or
the first failed renewal. Socket disconnection alone is not proof of execution
death.

Integration names are globally unique lowercase labels. Integrations are
owned by a user or a team and are reachable by attached VMs and, for team
ownership, by VMs owned by team members. User-provided secret values are
stored only in Marshall PostgreSQL, Cloak-encrypted through the existing
vault, write-only through every surface, and rendered as `****`. Galileo's
own control-plane credential is a digest-only token delivered through the
existing SecretSpec/SOPS/systemd credential pipeline. Customer-profile VMs
remain excluded from private services under ADR-0064.

## Alternatives

Transparent interception (Brady-style tproxy) was rejected: named
integrations are deliberately addressed by hostname, need no MITM CA, and
attribute identity through the existing binding path. A central fleet proxy
was rejected in favor of per-host Galileo releases for the same isolation
reasons as Ziggy (ADR-0063). Storing user secrets on Lilly hosts was
rejected: custody stays in the control plane and secrets cross the wire only
inside short-lived authorization responses.

## Consequences

Guest images need no change for the new zone: split DNS already routes
`.internal` and TLS is served by the fleet wildcard certificate
(ADR-0078). Galileo health does not gate guest execution; an unhealthy
Galileo only fails integration requests. Header injection is bounded and
validated at three layers (protocol, Marshall persistence, Galileo edge) so
no value can smuggle transport metadata. Deleting Galileo state loses
nothing: every authorization is derived per request.

## Invariants and verification

Protocol property tests cover name, target, strip-prefix, header and
authorization-response validation including CRLF smuggling and transport
impersonation rejection, TTL bounds and closed renewal responses. Marshall tests cover authorization fences (dead
owner, wrong epoch, unattached VM, customer profile), Cloak-at-rest and
write-only secret surfaces, plus renewal without credential or peer-token
reissuance. Galileo tests cover strip-prefix alignment, header
override semantics, bounded multi-chunk uploads, single-attempt failure and TLS
rejection before body consumption, monotonic cancellation of a stalled
upstream after renewal refusal, and generated bodiless guest requests reaching
a raw TLS origin with no chunked framing or body bytes. Audi tests cover bounded upload and download
forwarding without retaining complete bodies. The `galileo-service` NixOS test exercises the real
packaged Galileo release, SOPS credential loading, verified synthetic
control/origin TLS, header injection, strip-prefix handling and malformed-binding
denial. It also verifies exact byte count and digest for an upload larger than
three Galileo source chunks. The separate private-services test covers Audi
wildcard DNS/TLS. The physical fleet test now proves real attachment denial,
guest upload/load and execution-stop cancellation of a stalled request followed
by fresh authorization after restart. The complete nested-KVM fleet sequence now
passes cross-host peer transport, source relocation and control-plane outage
recovery. The isolated public Audi CA was missing from Galileo's fixture trust;
correcting that trust resolved the earlier peer transport failure.

## Implementation evidence

The [protocol contracts](../../../protocol/lib/overalls_protocol/integration.ex)
and [PrivateServices zone constants](../../../protocol/lib/overalls_protocol/private_services.ex)
define the closed wire surface. The [Galileo release](../../../galileo/lib/galileo/application.ex)
serves only a private Unix socket; its [upstream client](../../../galileo/lib/galileo/upstream.ex)
renews authority against monotonic deadlines and closes the same attempt on
refusal or expiry. The [control client](../../../galileo/lib/galileo/control.ex)
now retains HTTP 426 as a distinct version refusal even when the response body
is oversized; generated [local TLS tests](../../../galileo/test/control_version_test.exs)
cover all three control routes. Since ADR-0142 Galileo carries no body version; the
[control API](../../../marshall/lib/marshall_web/control_api.ex) returns 426 for
a wrong protocol version at upgrade, with [upgrade checks](../../../marshall/test/marshall_web/control_api_test.exs).
This does not establish hosted mixed-version
recovery. The [Marshall domain](../../../marshall/lib/marshall/galileo.ex)
persists integrations, headers, attachments and host credentials, and the
[control service](../../../marshall/lib/marshall/control/services/galileo.ex) performs
authorization and renewal. The [Audi private DNS](../../../audi/lib/audi/private/dns.ex)
and [frontend](../../../audi/lib/audi/private/front.ex) answer and route the
integration zone. The [NixOS module](../../../nix/domains/system/galileo.nix) and
[machines test](../../../nix/verification/tests/machines/galileo-service/default.nix)
cover deployment and packaged-service fixture verification. Remaining gaps are
recorded in the [ledger](../../services/galileo.md). The
[fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/galileo.py) supplies
real Marshall/Lilly/Firecracker evidence within one physical failure domain.
The packaged service test additionally passes stalled-source/destination bounds
and concurrent load. The September 20 review retains its historical combined Marshall failures;
subsequent [team-resource](../reviews/2026-09-25-team-resource-verification.md)
and [credential](../reviews/2026-09-25-credential-lifecycle-verification.md)
campaign gates record passing Marshall suites at their captured revisions.
They do not rerun unchanged consumer/native cases at this revision.

The [renewal verification review](../reviews/2026-09-25-integration-renewal-verification.md)
records generated membership/attachment/configuration histories with exact
TTL-only renewal and unchanged credential/token rows. A new
[native journey](../../../nix/verification/tests/machines/integration-renewals/driver.py)
requires successful HTTPS renewal before ordinary membership/attachment
withdrawal, actual origin socket closure without retry and fresh restoration.
The captured native execution passed all eight stages in 413.94 seconds.
Configuration/name identity investigation has not established a need to change
the current renewal wire contract.

[ADR-0134](0134-personal-integration-owner-eligibility.md) clarifies explicit
personal attachments without compatibility or backfill. The
[attachment/fault review](../reviews/2026-10-03-galileo-attachments-and-faults.md)
records generated personal-owner, supported retirement/removal histories and
packaged HTTP/1 blocked-upload cancellation. Bandit reads remain in their
stream owner; cancellation closes its frontend through ThousandIsland's API.
The native fault workload independently counts accepted TLS and HTTP dispatch,
requires a successful silent renewal, then verifies origin EOF/reset and bounded
frontend return after refusal, invalid TTL or expiry. This evidence does not
establish the new policy's production rollout or arbitrary streaming resilience.

The [production review](../reviews/2026-10-02-galileo-production.md) also records
a reproduced archived-team authority defect. Shared
[owner liveness](../../../marshall/lib/marshall/galileo/ownership.ex) and atomic
[peer consumption](../../../marshall/lib/marshall/galileo/peer_tokens.ex) refuse
archived team owners despite retained membership/attachment rows. The generated
[archival history](../../../marshall/test/marshall/galileo/renewal_history_test.exs)
records passing application refusal and unchanged-state evidence; native archival
cancellation and production verification remain separate.

*Transport (2026-10-05).* Galileo now reaches Marshall over the control
WebSocket ([ADR-0142](0142-overallsprotocol-control-websocket.md)). Identity,
authorize and renew are `galileo.*` requests on one long-lived connection
instead of `POST /api/galileo/v1/*`, which is deleted. They are still single-attempt, an
unauthorized answer is still a refusal, and a version refusal (426 at upgrade)
still keeps its distinct permanent class. Renewal outcomes are observed
through the catalogued `galileo.lease_renewal` event.

The [private DNS implementation](../../../audi/lib/audi/private/dns.ex) returns
authoritative NOERROR/NODATA with the integration SOA for AAAA queries of valid
single-label integration names. It retains their fixed IPv4 A answer and
malformed/deep/internal NXDOMAIN or external REFUSED behavior. This repairs the
existing closed DNS contract: an IPv6 query must not negatively cache the whole
valid name. It adds no service destination or authentication authority. The
[GitHub review](../reviews/2026-10-18-github-com-integration.md) records the scoped
UDP/TCP and generated-label evidence separately from the fleet journey.

## Open questions

The [production review](../reviews/2026-10-02-galileo-production.md) records
Porsche listing/peer-flag repairs, closed validation refusals and browser password
input replacement. Generated properties and full gates distinguish server HTML
from actual Chromium input values. Two-host live credential, Customer, peer,
membership and relocation journeys are recorded. The repaired browser and CLI
paths passed on two-host rollout `33b76a25`; campaign integrations, team and VMs
were removed. Only the empty account's passkey-authorized retirement remains
open. It explicitly records the
personal-owner eligibility discrepancy against the existing source contract.
[ADR-0134](0134-personal-integration-owner-eligibility.md) proposes an explicit
clarification while preserving existing access pending that decision.

Extend independent physical-host acceptance and complete operator deployment.

## Related decisions

- [ADR-0063](0063-private-services-and-ziggy.md): private guest services pattern.
- [ADR-0064](0064-customer-workspace-isolation.md): customer exclusion.
- [ADR-0077](0077-teams-and-shared-resources.md): ownership and sharing.
- [ADR-0078](0078-fleet-wildcard-certificate.md): TLS for the zone.
- [ADR-0079](0079-peer-vm-vm-attestation.md): peer integrations.
