# ADR-0100: Pulled agent work over Ziggy control

- ID: ADR-0100
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Marshall, Ziggy, Audi, Lyra, guest images
- Supersedes: ADR-0099
- Superseded by: none

## Context

[ADR-0099](0099-marshall-owned-agent-threads.md) accepted Marshall ownership
of threads, turns, context, model scheduling, tool commands, recovery and audit.
It required Marshall to call a new authenticated Ziggy listener on each host.
The fleet already has a dedicated verified HTTPS Ziggy-to-Marshall control
channel and an Audi-to-Ziggy Unix socket. A second host listener would need
another certificate and reachability policy without changing loop ownership.

## Decision

Marshall remains the event loop and PostgreSQL remains authority for thread
order, model work, tool commands and executor fences. Ziggy polls Marshall's
dedicated control API for model calls assigned to its authenticated host. A
model call is durable and claimed once before a provider attempt. Ziggy still
obtains the existing VM-bound inference admission and fsyncs its accounting
slot before contacting host-local Underclass. A claimed call that loses its
result becomes uncertain and is never automatically replayed.
Marshall prepares stateless Responses requests for agent turns and retains
completed model output, including encrypted reasoning, only in authorized
thread state for later tool steps. Ziggy selects the fixed Responses path from
the trusted request shape; the enrolled-host configuration selects the
Underclass origin and its proxy credential.

Guest `overalls` executors poll `llm.internal` through Audi. Audi replaces the
binding header using Lilly's pre-NAT source lookup. Ziggy relays only closed
executor RPCs to Marshall with its dedicated host credential. Marshall checks
that credential, the current host, VM placement, execution epoch, lease and
fence before returning work or accepting a result. The guest has no model
state and no Marshall credential.

Server-owned tools such as web search are claimed and executed by Marshall's
supervised workers. They produce the same durable tool-result events but are
never returned to the guest executor; ADR-0107 defines the search provider
and credential boundary.

Eligible VM roots, child-thread concurrency, prompt authorization and wake,
deleted-VM history, structured diagnostics, content-free audit, property tests
and NixOS machine tests retain ADR-0099's requirements. Owners, managers,
operators and team admins may prompt; a prompt can request only a start.
Viewers, ordinary team members and web-only shares remain read only. Model
and tool content belongs only in authorized thread state, not diagnostic or
accounting records.

Role reconciliation, 2026-09-25: the preceding ordinary-team-member read-only
wording is retained as historical context. It conflicted with
[ADR-0077](0077-teams-and-shared-resources.md)'s accepted member read-and-use
requirement. The earlier [team resource verification](../reviews/2026-09-25-team-resource-verification.md)
resolved that conflict by granting current members write for existing
profile-permitted agent use and narrow prompt wake. Ordinary lifecycle and
resource management remain owner/admin-only; viewer and web-only direct grants
remain read only for agent use. The [CLI verification](../reviews/2026-09-25-agent-cli-verification.md)
documents and tests that inherited resolution without introducing a new
permission change.

## Alternatives

The host listener in ADR-0099 would have made Marshall's call direction
literal, but added a new ingress, certificate lifecycle and firewall path.
Letting Ziggy or the guest own the turn loop would make them authorities for
context and recovery, contrary to the selected server-owned design.

## Consequences

Marshall must bound and fence model jobs independently of the request/response
connection. Ziggy can pull concurrent jobs without becoming the scheduler.
Provider responses lost after a claim cannot be reconstructed from Ziggy's
content-free accounting spool, so Marshall exposes an uncertain terminal
outcome rather than repeating provider effects. Rolling deployments may enable
the Ziggy poller only after Marshall supports the control routes.

## Invariants and verification

- One model call may be claimed once; timeout, relocation and lost result never
  return it to queued.
- Current host credentials and VM execution binding gate model and tool work.
- Audi-derived binding overrides guest identity; a stale executor fence never
  commits a tool result.
- A queued later prompt never enters an earlier active turn's model context.
- Content-free audit and structured logs contain no prompts, model bodies,
  command arguments, tool output or credentials.
- Property tests and NixOS machine tests exercise wake, deletion, reboot,
  reconnect, claim loss, routing and service boundaries.

## Implementation evidence

The [Marshall loop](../../../marshall/lib/marshall/agents/loop.ex),
[model-call coordinator](../../../marshall/lib/marshall/agents/model_calls.ex),
[executor RPC boundary](../../../marshall/lib/marshall/agents/executor_rpc.ex),
[Ziggy pull worker](../../../ziggy/lib/ziggy/agent_worker.ex) and
[guest executor](../../../lyra/src/agent.rs) implement the basic transport and
single-attempt flow. Focused PostgreSQL tests cover model claims, tool-result
continuation, queued-prompt isolation, claimed-call timeout and running child
joins. The Ziggy NixOS machine test covers synthetic model polling through
host-local Underclass. The [agent fleet NixOS test](../reviews/2026-09-23-agent-threads-foundation.md)
boots Marshall, Ziggy, Audi and a nested guest, then proves an operator-shared
prompt wakes the stopped VM and completes two model calls, one guest
`read_file` command and the final answer. ADR-0101 adds a browser-approved CLI
prompt and result flow. Its [verification review](../reviews/2026-09-25-agent-cli-verification.md)
records a passing ordinary-browser/packaged-CLI/real-guest journey with an
isolated provider. An earlier executor interruption remains unexplained, and
pagination, cross-table identity constraints and live-provider acceptance remain,
so implementation stays partial. The native result predates the subsequent
Underclass pin.
The [Responses protocol](../../../marshall/lib/marshall/agents/model_protocol.ex),
[private replay event](../../../marshall/lib/marshall/agents/model_calls.ex), and
[Ziggy route selection](../../../ziggy/lib/ziggy/agent_worker.ex) add GPT-6 Sol
tool calls while retaining legacy claimed-call completion during rollout.

The [executor-loss review](../reviews/2026-09-26-executor-loss-histories.md)
adds composed application histories and a scoped native started-effect interruption
fixture with explicit user retry. Execution status and pre-start native gaps stay
separate; the earlier unexplained interruption and partial status are preserved.

*Transport (2026-10-05).* Ziggy now reaches Marshall over the control
WebSocket ([ADR-0142](0142-overallsprotocol-control-websocket.md)) as `ziggy.*`
requests on one connection bound to its host.

- The `agent_next` poll keeps its one-second cadence until `ziggy_work` hints
  have producers.
- Error classes are unchanged: unauthorized, version refusal and completion
  conflict, with everything else an authority outage.

The native FreeBSD/illumos
[command runner](../../../lyra/src/agent/native_command.rs) now receives the
existing executor lease/stop callback before spawn and while the command is
running. Refusal cancels its separate process group, reaps the direct child and
discards output. A scoped collector enforces the command deadline independently
of a blocking lease RPC. The
[native admission review](../reviews/2026-10-17-native-image-admission.md)
records this correction and its verification boundary: local process regression
tests are separate from current-boot native lease-withdrawal and image replay.
The existing accepted fencing decision and partial implementation status remain
unchanged.

The typed native control fixture now records the complete withdrawal history:
ordinary completion, explicit arming, accepted start, matching heartbeat
refusal with an observed HTTP 403, process-group death before the accepted-start
deadline, and completion under a higher epoch and different executor fence.
It also proves that stale or wrong-fence heartbeats and result attempts cannot
advance the history. The companion service fixture checks an exact managed Git
checkout and refuses an unrelated root-owned repository with Git's
`detected dubious ownership in repository` error. These are fixture and unit
evidence only; current-boot FreeBSD/OmniOS execution and promotion remain
pending. Details and test limits are recorded in the
[native lease-withdrawal review](../reviews/2026-10-17-native-lease-withdrawal.md).

## Open questions

The [reporter receipt history review](../reviews/2026-10-03-ziggy-reporter-histories.md)
adds local verification of immutable accounting retries and durable spool
recovery without repeating provider effects. Fixed batch boundaries and exact
per-ID attempts cover healthy-neighbor drain around one persistent conflict.
Focused execution passed seed203368 in7.6seconds. Full Ziggy precommit passed 64 checks
(15 properties, 49 tests), seed 521050, in 61.7 seconds. Forced Dialyzer passed in 5.33
seconds with zero errors, skips or unnecessary skips; terminal exit0.
HTTP/Marshall commit recovery, timer cadence and native faults remain separate.

None for the transport decision.

## Related decisions

The [control review](../reviews/2026-10-05-control-first-envelope.md) records
pending Ziggy call classification after control close4001: stopped version refusal
must remain unsupported_version, while close4008 remains transient. Generated
scripted-TLS evidence and a caught/restored guard mutant cover that adapter
boundary. They do not establish provider effect fencing or native/hosted retry
acceptance. Accepted rationale and implementation status remain unchanged.

[ADR-0063](0063-private-services-and-ziggy.md) establishes the guest private
service path; [ADR-0081](0081-independent-underclass-pools.md) governs
Underclass custody; [ADR-0042](0042-host-observability.md) governs diagnostics;
[ADR-0096](0096-lyra-developer-ssh.md) governs the CLI distribution;
[ADR-0101](0101-browser-approved-agent-cli.md) governs user CLI approval.
[ADR-0107](0107-marshall-owned-agent-web-search.md) governs server-owned search.
[ADR-0103](0103-profile-scoped-agent-capabilities.md) governs profile-based
agent tool permissions. [ADR-0104](0104-private-guest-cli-updates.md) governs
private executor updates.
[ADR-0108](0108-guest-agent-web-fetch.md) governs guest-executed web fetch.
