# ADR-0142: OverallsProtocol control WebSocket

- ID: ADR-0142
- Date: 2026-10-05
- Status: accepted
- Implementation: partial
- Components: Protocol, Marshall, Galileo, Audi, Lilly, Ziggy, Porsche
- Supersedes: none
- Superseded by: none

## Context

Every service talks to Marshall through one-off HTTPS POSTs that it polls:

- Lilly's exchange runs every second, alongside 13 relocation loops.
- Audi reads its catalog, certificate and DNS every second, and renews each
  stream lease at least once a second.
- Ziggy polls `agent_next` every second.
- Porsche polls approvals and command status every second.
- Galileo authorizes and renews per request.

Each client carries its own HTTP client, version handling and body limits.
Marshall cannot push anything, so revocation ([ADR-0141](0141-control-plane-hints-and-resync.md))
and new work wait for the next poll. The only WebSockets (the Lilly terminal
stream and the Marshall peer hop) use two hand-rolled clients with blocking
poll loops.

The transport rules this decision replaces come from ADR-0012 and were carried
forward through ADR-0035, 0037, 0050, 0051, 0053 and finally
[ADR-0126](0126-bounded-database-client-recovery.md):
"outbound HTTPS POST exchanges … every second with one request in flight",
2/3/5-second client timeouts, and no implicit retries.

## Decision

Authorized by the user on 2026-10-05: "redesign all of the connections needed
for everything that needs to connect to Marshall to use WebSockets and move it
into a proper protocol", with re-architecture allowed and no compatibility
shims.

- **One protocol in `protocol/`.**
  - `OverallsProtocol.WebSocket.Frame` and `Handshake` are pure, bounded RFC 6455
    code. Fragmentation, compression and reserved bits are refused, and each
    role checks masking.
  - `WebSocket.Connection` is a verified-TLS IPv4 client socket in
    `active: :once` mode, so nothing polls.
  - `Control.Envelope` defines the JSON message kinds: `hello`, `welcome`,
    `req`, `res`, `hint`, `resync`, `ping` and `pong`. Ops, hint kinds and
    errors are closed names, and decoding never creates atoms.
  - `Control.Close` defines the closed close codes (4000–4008) and the one
    reaction each requires.
  - `Control.Client` is the shared client. It runs hello and welcome,
    correlates requests, sends heartbeats both ways and reconnects with
    full-jitter backoff capped at four seconds (Lilly's report retry bound
    from ADR-0140, so a restarted Marshall is reached within the host report
    windows). It reports connected, hint, resync and disconnected
    events to its owner.
    It opens each connection outside its own process, so requests, status and
    readiness answer at once (`:disconnected`) while a connect hangs.
  - **Shared-library boundary:** codecs, state machines, Cadence and View
    retain their pure boundaries. Socket I/O is confined to
    `WebSocket.Connection` and `Control.Client`; application-owned callbacks
    supply credentials and TLS trust. Protocol owns no Ash resources, database,
    host mutation or durable credential store. This transport addition replaces
    the earlier blanket no-I/O library guidance; it does not relax codec purity.
- **One endpoint.** `GET /api/control/v1` lives on the fleet listener
  (`MarshallWeb.ControlAPI`) and carries `overalls-control: 1`,
  `overalls-service` and a bearer credential.
  - A wrong version gets HTTP 426 and a failed credential 401, both before any
    process exists.
  - `Marshall.Control.Socket` binds the hello through a `Control.Service`
    module, runs each request in a supervised task, pushes the bound
    identity's hints and enforces heartbeats.
  - **Per-service limits.** A service may declare its largest
    server-to-client frame, its largest client-to-server frame (enforced at
    upgrade) and its most concurrent requests. The welcome advertises the
    outbound frame and `in_flight`; the client adopts `in_flight` (1–256;
    otherwise 8). The defaults are 1 MiB, 1 MiB and 8.
  - **Test-only fault gate.** When a release is configured with
    `MARSHALL_CONTROL_FAULT_GATE_FILE` (only native tests do), listed ops are
    answered `temporarily_unavailable` before dispatch. This replaces proxy
    path rules, which cannot see ops inside the socket. Production configures
    no file.
- **Semantics kept.** Requests call the unchanged domain functions, so the
  host-locked transactions, durable intent before acknowledgement,
  idempotency and fencing are those of the domain.
  - A request whose connection drops resolves as `:unproven` and is never
    replayed (no hidden redelivery).
  - A connect always triggers a full read of durable state, and pushes are
    hints only.
- **Migration.** Clients move one at a time; each client's old HTTP routes are
  deleted after it moves.
  - Galileo moves first, because it has only three request/response ops.
  - Then Audi, Lilly control, the Lilly terminal stream together with the
    Marshall peer hop, then Ziggy and Porsche.
  - **Rolling-deploy order.** Hosts auto-update independently, so a client
    may run new code before overalls' Marshall does. Each phase therefore
    ships Marshall's service first and the client in a later push.
  - **Audi (gateway and DNS roles)** sends every route except
    `host-certificate` as op `audi.<route>`, with underscores for hyphens.
    - Requests and responses are the same versioned documents as the HTTPS
      routes; `Marshall.Ingress.ControlRequests` serves both transports, so
      domain calls, re-authentication under lock and denial classes are
      shared.
    - The hello binds the credential's role and host; any other bind is
      refused.
    - Limits are an 8 MiB + 1 KiB frame (the DNS snapshot bound) and 64
      requests in flight (one renewal per stream).
    - Marshall's side shipped one push before Audi's client.
  - **Lilly control** sends the 18 `/api/provisioners/v3` routes as
    `lilly.<route>` through `Marshall.Compute.ProvisionerRequests`, which the
    HTTPS routes share.
    - The upgrade credential is the host's; the hello binds its `host_id`.
    - Every exchange still re-authenticates under the host lock and fences
      the session and epoch carried in its document.
    - Errors keep their closed names; any other failure is the fixed
      `temporarily_unavailable`.
    - Limits are 1 MiB + 4 KiB frames each way and 64 requests in flight (the
      execution exchange, audit, clone, relocation, inception and owner
      loops).
    - A dropped socket resolves an in-flight exchange as unproven, which
      Lilly classifies as a transport error with its existing bounded backoff.
    - Marshall's side shipped one push before Lilly's client. The terminal
      stream stays on its own WebSocket until P4b.
  - **Ziggy and Porsche, server side:** Marshall serves Ziggy's 16
    `/api/ziggy/v1` routes as `ziggy.<route>` through
    `Marshall.Inference.ControlRequests`, and Porsche's gateway routes
    (`ready`, `sessions`, `session`, `close`, `commands`) as `porsche.<route>`
    through `Marshall.SSH.ControlRequests`; the HTTPS routes share both.
    - A Ziggy hello binds the host credential's `host_id`. Its socket accepts
      1,100,000 + 4 KiB inbound frames (`agent_result`) and 256 requests in
      flight; errors keep the HTTPS classes.
    - A Porsche hello is empty; the gateway is the credential's. Errors carry
      the same closed names as the HTTPS bodies, each in one status class,
      and the socket allows 256 requests in flight.
    - Marshall's side shipped one push before their clients.
- **What stays HTTP:**
  - the fleet monitor (Python stdlib; an acknowledged 5 s spool);
  - the agent CLI;
  - the lyra daily host-certificate request;
  - public known-hosts and `/bin` downloads;
  - Marshall→Enrico;
  - SSH transfer.
- **Scope of supersession.** This supersedes only the transport clauses of the
  ADR-0012…0126 chain (HTTPS POST per exchange, the one-second exchange
  cadence and per-request timeouts as the transport). It also supersedes the
  transport parts of ADR-0080 (Galileo), ADR-0100 (Ziggy polling), ADR-0046
  (Porsche) and ADR-0105 (Audi), each as that client moves. Their semantic
  rules stand. ADR-0085 (separate IPv4 fleet listener, Erlang distribution
  off) and ADR-0090 still hold.

## Alternatives

- **HTTP long-poll for pushes.** Smaller, but it keeps one client per
  service. The user chose WebSockets for everything.
- **`mint_web_socket` or Phoenix channels.** These would add a runtime
  dependency, or Phoenix's protocol, to every client. A bounded RFC 6455 codec
  already existed twice in the repository and is now shared once.
- **Erlang distribution for cross-node pushes.** Excluded by ADR-0085. Hints
  cross nodes through PostgreSQL (ADR-0141).

## Consequences

- Revocation, commands and catalog changes can be pushed. Polling cadences
  become backstops as each client moves.
- One long-lived socket per service instance replaces per-request TLS
  handshakes.
- A Marshall node loss drops its sockets. Clients reconnect to another node
  through HAProxy and resynchronize. During a rolling deploy, a client on a
  retired version gets 426 or close code 4001 and waits for auto-update.
- HAProxy request logs no longer show individual control requests.
  Observation moves to catalogued events, for example
  `galileo.lease_renewal`.

## Invariants and verification

- **Frame and handshake codecs:** they round-trip, never raise on arbitrary
  input, and refuse wrong masking, fragmentation, oversized and non-minimal
  frames (`protocol/test/web_socket_test.exs`).
- **Envelope and close codes:** the envelope round-trips, refuses other
  versions and extra fields, and maps every close reason to one code and
  reaction (`protocol/test/control/envelope_test.exs`).
- **Client behaviour** (`protocol/test/control/client_test.exs`, against a
  loopback server):
  - hello binding and request correlation work;
  - hints and resyncs reach the owner;
  - a drop makes in-flight requests `:unproven` with no replay;
  - close codes reach the owner by reason.
  - generated reconnect histories exposed retired heartbeat schedules servicing
    a replacement connection. The timer-reference repair passed its focused
    property in47.8seconds. A separate queued-reference extension passed47.9seconds
    and caught a ref-matching mutant in6.2seconds. The integrated extension passed
    in45.9seconds after the249-check Protocol production gate. Lilly503,
    Marshall1466 and Galileo31-check consumer gates passed with zero-error
    forced Dialyzer; incoming-main and native fleet integration remain open.
  - the terminal version-refusal property observes generated pending batches
    settling as unproven and checks no replacement upgrade beyond sixty seconds.
    The original client failed after60.3seconds; the refined repaired six-check
    file passed318.9seconds, and the targeted retry mutant was detected through
    peer-observed queued reconnects. These bounded loopback results do not prove
    arbitrary future silence or native rollout. See the
    [control review](../reviews/2026-10-05-control-first-envelope.md).
- **Upgrade refusals:** 426 and 401 before any socket, and HTTPS only
  (`marshall/test/marshall_web/control_api_test.exs`).
- **Socket behaviour** (same file):
  - hello first, for the upgraded service and current version;
  - requests reach the domain;
  - unknown ops get error responses;
  - hints only reach bound sockets.
- **Galileo client:** a 426 keeps its permanent class on every route, domain
  refusals map as before, and guest-facing refusals are unchanged
  (`galileo/test/control_version_test.exs`, `galileo/test/http_test.exs`).
- **Advertised limits:** a welcome's `in_flight` bounds concurrent requests,
  and invalid values fall back to 8 (`protocol/test/control/client_test.exs`).
- **Audi transport equivalence:** for the same credential, route and body, the
  socket answers with the HTTPS route's class and document
  (`marshall/test/marshall/control/audi_service_test.exs`). The bind holds
  role and host there too.
- **Ziggy and Porsche:** their binds, limits and error classes
  (`marshall/test/marshall/control/ziggy_porsche_service_test.exs`). The revised
  Porsche property checks stable creation fields, independently issued session
  identities, exact status documents for each session through both adapters and
  exact refusal names. Focused execution passed3checks (1property,2tests),seed0,
  0.7seconds; mutation/full integrated gates remain pending. Direct adapter invocation does
  not verify a WebSocket upgrade, TLS or post-bind credential rotation.
- **Lilly session ratchet over both transports:** generated interleavings of
  HTTPS and socket opens and exchanges follow one ratchet; the bind,
  limits, error names and fault gate are covered too
  (`marshall/test/marshall/control/lilly_service_test.exs`).
- **Peer-hop liveness:** both sides end after fifteen seconds of silence, and
  any frame renews the socket's deadline
  (`marshall/test/marshall/terminal/peer_liveness_test.exs`). Lilly's stream
  suites drive the active transport (`lilly/test/terminal/`).
- **Responsive connect:** against a server that never completes the
  handshake, requests, status and readiness answer immediately
  (`protocol/test/control/client_test.exs`).
- **Ziggy and Porsche clients:** Ziggy's classes are a property over socket
  answers (`ziggy/test/control_response_test.exs`); version refusal at
  upgrade stays terminal (`ziggy/test/version_refusal_test.exs`). Porsche's
  closed names, lost replies and bounds run against a TLS socket stub
  (`porsche/test/client_test.exs`), and Marshall's SSH transport suite drives
  the real Listener over the control endpoint, including an exactly-once
  retry after a dropped committed reply.
- **Lilly client:** the real client drives Marshall's control endpoint in the
  provisioner transport, enrollment, lifecycle-audit and Inception suites,
  with socket-level probes for lost audit acknowledgements and relocation
  worker completion. Lilly's own suites use a loopback control stub
  (`lilly/test/support/control_stub.ex`).
- **Audi client:** the existing Audi suites now run against a WebSocket
  Marshall stub with an unchanged request contract (`audi/test/support/dns_control.ex`).
  The real Audi client also reaches Marshall's control endpoint
  (`marshall/test/marshall/ingress/{publications,access}_test.exs`,
  `marshall/test/marshall_web/ingress_transport_test.exs`).

## Implementation evidence

- Protocol:
  [frame.ex](../../../protocol/lib/overalls_protocol/web_socket/frame.ex),
  [handshake.ex](../../../protocol/lib/overalls_protocol/web_socket/handshake.ex),
  [connection.ex](../../../protocol/lib/overalls_protocol/web_socket/connection.ex),
  [envelope.ex](../../../protocol/lib/overalls_protocol/control/envelope.ex),
  [close.ex](../../../protocol/lib/overalls_protocol/control/close.ex),
  [client.ex](../../../protocol/lib/overalls_protocol/control/client.ex).
- Marshall:
  [control_api.ex](../../../marshall/lib/marshall_web/control_api.ex),
  [socket.ex](../../../marshall/lib/marshall/control/socket.ex),
  [service.ex](../../../marshall/lib/marshall/control/service.ex),
  [services/galileo.ex](../../../marshall/lib/marshall/control/services/galileo.ex).
- Galileo:
  [control.ex](../../../galileo/lib/galileo/control.ex).
- Audi:
  [services/audi.ex](../../../marshall/lib/marshall/control/services/audi.ex),
  [control_requests.ex](../../../marshall/lib/marshall/ingress/control_requests.ex),
  [client.ex](../../../audi/lib/audi/control/client.ex),
  [link.ex](../../../audi/lib/audi/control/link.ex).
- Ziggy and Porsche:
  [ziggy control.ex](../../../ziggy/lib/ziggy/control.ex),
  [ziggy link.ex](../../../ziggy/lib/ziggy/control/link.ex),
  [porsche client.ex](../../../porsche/lib/porsche/client.ex),
  [porsche link.ex](../../../porsche/lib/porsche/control/link.ex),
  [services/ziggy.ex](../../../marshall/lib/marshall/control/services/ziggy.ex),
  [services/porsche.ex](../../../marshall/lib/marshall/control/services/porsche.ex),
  [inference/control_requests.ex](../../../marshall/lib/marshall/inference/control_requests.ex),
  [ssh/control_requests.ex](../../../marshall/lib/marshall/ssh/control_requests.ex).
- Lilly:
  [client.ex](../../../lilly/lib/lilly/control/client.ex),
  [link.ex](../../../lilly/lib/lilly/control/link.ex),
  [services/lilly.ex](../../../marshall/lib/marshall/control/services/lilly.ex),
  [provisioner_requests.ex](../../../marshall/lib/marshall/compute/provisioner_requests.ex),
  [fault_gate.ex](../../../marshall/lib/marshall/control/fault_gate.ex).

Every client has moved. The Lilly terminal stream and the Marshall peer hop
(P4b) keep ADR-0083's binary codec, hello and credits, but run over the shared
active-once `Connection`: nothing polls, Lilly opens its stream off-process,
and the peer hop pings every 5 s, with either side ending after 15 s of
silence. Hint producers, first slice: every operation, relocation probe,
relocation key, destination receive and source permit dispatch now emits a
`host_commands` hint for its host (replacing a node-local PubSub broadcast
nothing consumed since Lilly left HTTPS). Lilly's bind subscribes to it and
its runtime exchanges at once on the hint, coalesced with the in-flight
exchange; the one-second cadence stays as the backstop. Second slice: VM
run-state, placement and archive actions and endpoint record/policy changes
emit a host-keyed `gateway_catalog` hint; the host's Audi gateway subscribes
and its fleet worker refreshes the catalog at once through a local hint
registry. Lease groundwork (push A of two): Audi gateways subscribe to every
`user` and `vm` hint (a kind-wide subscription), and each web, nested and SSH
stream's renewal worker renews at once on a hint for its VM or user, so a
revocation ends the stream without waiting for the periodic renewal. Audi
and the protocol accept stream TTLs up to 30 s and an optional
`user_id` on nested and SSH grants; long leases renew at half their remaining
time. The browser viewer's periodic authority backstop is now five seconds,
since user and VM hints trigger an immediate recheck. Push B: Marshall issues 30-second web-stream and SSH-session leases, and SSH
grants carry the key owner's `user_id`, so key removal or any user hint ends
open sessions at once; gateways renew at half the remaining lease (about every
15 s) instead of every second. Nested streams stay bound to their
environment publication's five-second expiry. Catalog and DNS snapshot TTLs
stay at five seconds (see the correction below). Push B's
audi-fleet run exposed that resource-level `Hints.Change` declarations ran
only on create and update (Ash's default), so hints for destroy actions
(SSH key revoke, archival destroys) were never emitted; every declaration now
runs on create, update and destroy, with a focused test for key removal. Third slice: queuing a model call emits a host-keyed `ziggy_work`
hint; Ziggy's agent worker claims once at once without adding a timer, so the
poll cadence and version fence are unchanged.

The [catalog decoder](../../../protocol/lib/overalls_protocol/ingress_catalog.ex)
now rejects TTLs above 5,000 milliseconds, matching the existing publication
bound; [boundary cases](../../../protocol/test/ingress_catalog_test.exs) cover
5,000, 5,001 and 30,000 milliseconds. The
[prerequisite review](../reviews/2026-10-13-antithesis-prerequisites.md) records
this as a contract-preserving decoder correction. A later ordinary Protocol
precommit passed 262 checks and forced Dialyzer; ordinary Lilly passed 559
checks and forced Dialyzer on its final runtime source. A final Marshall
consumer or hosted execution result is not claimed here.

Remaining:
- **For Audi (status 2026-10-07):**
  - done: `gateway_catalog` hints (catalog refreshes at once), stream
    leases renewed on `user`/`vm` hints, `user_id` on SSH grants, 30-second
    web and SSH leases;
  - done (fourth slice): `dns_snapshot` hints. Route record and replace,
    the same VM transitions that hint the catalog, and endpoint record and
    policy changes emit `dns_snapshot` inside their transaction (a route's
    lease refresh does not); DNS-role sockets subscribe kind-wide and the
    replica refreshes at once, coalescing queued hints into one read.
    A recorded ACME proof also hints `dns_snapshot`, and activating a fleet
    certificate generation emits `fleet_certificate`, which every gateway
    hears and fetches at once instead of at its 30-second delivery check.
  - done (fifth slice): host session and authority transitions (connect,
    disconnect, maintenance, configure) also hint that host's
    `gateway_catalog` and the zone's `dns_snapshot`, so a disconnected host's
    routes leave its gateway catalog and DNS at once.
  - correction (2026-10-09): earlier notes said the five-second catalog and
    DNS TTLs encode host liveness. They do not: host authority is
    `host_authority_ms` (60 s, ADR-0140) and is re-evaluated by every read,
    and authority lost only by report age is caught by the one-second
    backstop read. The five-second TTL bounds how long an Audi that cannot
    reach Marshall keeps serving its last snapshot. Lengthening it would buy
    no latency (hints already refresh at once) and would only extend stale
    routes under a partition, so it stays at five seconds with the one-second
    backstop. Nested streams keep their environment publication's
    five-second bound.
  - not needed: `ssh_approval` hints; Porsche does not poll approvals (the
    user retries after approving).
- **P6 (route deletion):** the HTTPS control routes are gone; every
  service reaches Marshall only over the control socket.
  - `/api/galileo/v1` and `/api/ziggy/v1` are deleted (`GalileoAPI`,
    `InferenceAPI`). The host-replacement scenario probes live and retired
    Ziggy credentials over the socket; a retired one is refused with 401 at
    upgrade.
  - Audi keeps only `identity` and `dns-snapshot` (Inception publication),
    `host-key` and `host-certificate` (lyra) and public known-hosts over
    HTTPS.
  - Porsche keeps only `ready` (Inception publication) and
    `host-certificate` (lyra).
  - `/api/provisioners/v1`–`v3` answered 426 `unsupported_version` until
    ADR-0159 removed that catch-all; they now get the fleet listener's 404, and
    only the v4 terminal stream upgrade remains. The
    credential-rotation fixture opens its sessions over the socket.
  - A refused credential kept its refusal class only over HTTPS: on the
    socket, every client reported a 401 upgrade as a transport error. The
    shared client now answers requests with `:refused` or
    `:unsupported_version` while its last close was one, and each service
    maps `:refused` to its unauthorized class. Found by host-replacement's
    retired-credential probe, which also now starts a real `Lilly.Control.Link`.
  - A credential check that cannot complete (Lilly's undecryptable stored
    secret) now answers the upgrade with 503 rather than 401, so the client
    backs off instead of treating its credential as refused.
  - Tests reach the moved requests through `Marshall.AudiSocket`,
    `Marshall.PorscheSocket` and `Marshall.LillySocket`.
  - Lengthening Audi leases and the viewer poll waits for the hint
    producers above.
- Native evidence: `galileo-service`, `galileo-fleet`, `integration-renewals`
  and `audi-fleet` pass. `audi-dns`, `audi-service` and `sharing-surfaces`
  fail identically on `main` (pre-existing). For Lilly control, `fleet` passed
  every subtest through Lilly release upgrades with authenticated control,
  including two that fail on `main`; one earlier run's capacity race failed
  when a host's ZFS collection reported its pool unavailable under load.
  `relocation-fleet` fails at the same subtest as `main`.

## Production fleet path

The [opening socket custody review](../reviews/2026-10-06-opening-socket-custody.md)
reproduces worker death after controlling-process transfer but before completion
reporting. Provisional owner registration now precedes transfer, allowing worker
death and failed completion to retire the socket. Generated local properties and
separate cleanup mutants verify this seam. Current full gates and native/hosted
acceptance remain pending; accepted boundaries and rationale are unchanged.

The shared client's asynchronous opening attempt now owns a linked/monitored
worker. A matching worker death retires its attempt through existing bounded
lost recovery; termination retires the opening worker/socket. A generated real
loopback property reproduced the previously stuck reference, and the
[control review](../reviews/2026-10-05-control-first-envelope.md) records the
repair, exact successor hello/welcome, orderly/abrupt owner cleanup and caught
retained-attempt mutant. Full current Protocol/consumer gates and native/hosted
acceptance remain separate. This preserves accepted transport/domain boundaries,
terminal close reactions, rationale and implementation status.

The [consumer classification review](../reviews/2026-10-05-control-first-envelope.md)
records a migration correction: pending Ziggy/Porsche/Galileo calls resolved as unproven
must retain the shared client's stopped unsupported-version reason after
close4001. Galileo's generated property also permutes all three routes with
healthy response and transient4008 controls. Generated verified-TLS scripted-peer properties pass, separate guard
reversions fail at the predicted assertion, and restored properties pass.
This adds local adapter evidence without changing the decision or implementation
status. Full consumer gates, native deployment and hosted mixed-version acceptance
remain separately scoped.

The ADR-0095 relay
([overalls configuration](../../../fleet/roles/control-plane/configuration.nix)) is
`systemd-socket-proxyd` forwarding bytes from `OVERALLS_PRIMARY_IPV4:5443` to
Marshall's loopback TLS listener. It has no idle timeout and does not
interpret HTTP, so upgraded sockets stay open and TLS is end to end.

- Its default cap of 256 concurrent connections now covers the control
  sockets as well as the terminal streams.
- It `requires` the Marshall unit, so a Marshall restart drops every socket.
  Clients reconnect and resynchronize, as for a node loss.

## Amendment 2026-10-30: bounded Lilly request execution

[ADR-0275](0275-bounded-control-request-execution.md) replaces this record's
"runs each request in a supervised task" concurrency for Lilly sockets. At
most `running` accepted requests (default 2) execute at once. The rest wait in
FIFO order in the socket, and one that waited past the queue deadline is
answered `temporarily_unavailable` without running. The advertised
`in_flight` of 64, the frames and the reply names are unchanged. Other
services keep `running = in_flight`. The trigger was pool exhaustion from
hint-triggered bursts of 14 host-locked exchanges in machine-test run
41126173301.

## Open questions

- Whether the relay's 256-connection cap needs raising once Lilly, Audi,
  Ziggy and Porsche all hold sockets alongside many terminal streams.

## Related decisions

- [ADR-0275](0275-bounded-control-request-execution.md): bounded execution of
  accepted Lilly requests (amends this record's per-request task concurrency)
- [ADR-0141](0141-control-plane-hints-and-resync.md)
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md)
- [ADR-0126](0126-bounded-database-client-recovery.md)
- [ADR-0085](0085-inception-public-ingress.md)
