# ADR-0192: Editor and nested HTTPS use staged detached ingress bridges

- ID: ADR-0192
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: Lilly, lilly-hostd, Marshall Ingress and Editor authority, Audi, NixOS editor fleet test
- Supersedes: none
- Superseded by: none

## Context

[ADR-0187](0187-detached-ingress-bridges.md) moved guest SSH and plain web
ingress (`ssh`, `web`, `porsche_ssh`, `audi_ssh`) onto detached
`lilly-ingress-bridge` processes in `lilly_ingress.slice`, so those sessions
survive restarts of `lilly-hostd` and Lilly. Its decision 1 left the browser
editor (`editor`, port 4444) and nested HTTPS (`control_https`, `audi_https`)
on [ADR-0184](0184-lilly-owns-every-socket.md)'s op 13 bridge and the BEAM
relay (`Lilly.Ingress.Server.pump/3`), because they "need a preface or a
ready frame from the guest". A hostd or Lilly restart therefore still ended
every live editor WebSocket and nested HTTPS connection.

The user asked why those two still need op 13 and the BEAM, and to move them
if that is safe. Reading the code (`Lilly.Network.Ingress.connect/3`,
`Lilly.Ingress.Server.serve_bound/3`, `Audi.Connector`, the guest
`vscode-web-broker`) gives the exact reasons, and none of them is a role the
BEAM must play for the life of the connection:

- **No TLS termination in Lilly.** Nested HTTPS is TLS end to end between
  the client and the nested Inception guest. Audi and Lilly see ciphertext.
- **No HTTP inspection or multiplexing in Lilly.** Audi terminates the
  editor's HTTPS, enforces editor grants per request and on WebSocket
  renewal, and opens one connector connection per proxied request or
  WebSocket. Lilly relays opaque bytes, one connection per stream.
- **Per-request authorization is Audi's and Marshall's.** Lilly's part is
  the execution guardian (`ingress-current-observed-execution`), checked for
  the whole connection; ADR-0187's keepers already hold it for detached
  bridges. Editor sign-out closes the WebSocket at Audi, which ends any
  bridge because the bridge ends when its client closes.
- **What does need Lilly happens once, before the first opaque byte.**
  Nested HTTPS gets one 28-byte PROXY v2 header naming the Audi-attested
  client and the derived guest destination (`connector-owned-proxy-preface`).
  The editor gets the 4-byte-length-framed closed `EditorConnect` binding,
  then Lilly waits up to 20 s (the editor's cold start) for the guest broker's
  length-framed ready document before telling Audi it is ready. The broker
  writes exactly `{"version":1,"ready":true}`; after it, the stream is opaque.
  The editor also binds the guest gateway as its source address.

So the BEAM's only essential contribution is to derive two byte strings
from the validated binding and to decide that the guest answered correctly.
Both are setup, not relay.

## Decision

Accepted on 2026-10-17 under the user's instruction to extend ADR-0187's
mechanism to the editor and nested HTTPS if that is safe, keeping Lilly's
execution fence. This amends ADR-0187 decision 1; its other decisions stand
and now apply to every ingress service.

1. **Every ingress service is detachable.** `Lilly.Network.Ingress.detachable?/1`
   accepts `ssh`, `web`, `editor`, `porsche_ssh`, `audi_ssh`,
   `control_https` and `audi_https`. They all take ADR-0187's path:
   reservation, a record written before the bridge exists, op 14, a keeper
   holding the guardian, re-adoption with the 30 s grace, and ending through
   hostd. The record of a nested HTTPS bridge includes the client endpoint,
   because its binding includes it.
2. **op 14 carries a stage.** `BridgeIngress` gains three fields between
   the greeting and the target: a `preface` of at most 4096 bytes, an
   `expect` frame of at most 256 bytes and a `ready_ms` wait, which is 0
   when `expect` is empty and 1..30000 ms otherwise. Lilly derives them in
   `Lilly.Network.Ingress.stage/3` from the validated binding and the derived
   target, exactly as `connect/3` does: nothing for SSH and web; the PROXY v2
   header for nested HTTPS; the framed `EditorConnect` binding, the exact
   framed ready document and 20 s for the editor. The editor's dial binds the
   guest gateway source address, as `connect/3` does.
3. **hostd executes the stage mechanically.** After the namespace dial and
   before spawning the bridge, hostd writes the whole preface to the guest
   and, when `expect` is set, reads exactly `expect.len()` bytes and requires
   byte equality (`ingress-guest-stage`). It reads no byte past the frame, so
   every later guest byte reaches Audi through the bridge. Any short write,
   closed guest, timeout or difference is `Unavailable`, the guest
   connection is dropped and no bridge starts. The rest of op 14 (READY,
   greeting to Audi, GO) is unchanged, so guest bytes still never precede
   Lilly's greeting.
4. **Security decisions stay in Lilly.** Lilly alone decides what the guest
   is told (the preface) and what counts as ready (the exact frame). hostd
   interprets neither: it writes one opaque string and compares another.
   Accepting only the exact document is narrower than the BEAM's JSON check
   (`IngressConnect.ready?/1`), and the broker writes exactly that document.
   The privileged process reads at most 256 guest bytes into a fixed buffer
   and compares them; it parses nothing.
5. **op 13 and the relay remain as the fallback** for a backend whose
   executor cannot bridge detached or a connector without a detached host
   (`lilly-connector-backend-fence`). No production service needs them.

### Correction: renewal across a Lilly restart (2026-10-17)

The first run of the editor restart subtest failed with "no editor bridge
survived the restarts". The bridges did survive; Marshall ended the streams.
After the Lilly restart, Audi's next editor renewal got a conclusive
`unauthorized` (`audi.control_exchange_failed`, then `audi.editor_revoked`), so
Audi's guard killed the stream owner and the bridge ended with its client.
New admissions in the same log succeeded.

Two causes in Marshall:

- **The editor lease pinned the provisioner control session.**
  `Marshall.Editor.Authority` required `lease.connection_session_id ==
  host.connection_session_id` at renewal, from
  [ADR-0153](0153-official-source-browser-editor.md)'s lease binding
  ("host connection session"). Every Lilly reconnect opens a new session, so
  no editor lease could outlive a Lilly restart, whatever the bridge did.
- **A reconnecting host was a conclusive refusal.**
  `Marshall.Ingress.Execution.current!/3` denied with `unauthorized` while the
  host had no session (`HostReports.disconnect/2`) or a new session without
  its first report (`ProvisionerControl` opens it with `reported_at: nil`).
  Web renewal does not pin the session (its binding's `session_id` is the
  stream id), but it hit this window.

Decision 6, under the coordinator's instruction to make renewal succeed
whenever the execution binding is still authorised and current:

6. **Renewal binds the execution, not the provisioner's control session.**
   Editor and web renewal recheck the gateway service and generation, host,
   VM placement, execution epoch and generation, desired and observed
   running state, relocation readiness, the completed start, and every
   identity and policy check, as before; the editor lease no longer compares
   the control session. Admission still requires a live session. When the
   only failure is that the provisioner is reconnecting (no session, or a
   session that has not reported yet), renewal is refused with
   `temporarily_unavailable` **after** every conclusive check
   (`ingress-renewal-host-reconnecting`, `Execution.renewable!/2`), the lease
   is left unchanged, Marshall's Audi channel answers `unavailable`, and Audi
   classifies that as inconclusive and retries until the lease deadline
   (`Audi.Authority.Renewal.inconclusive?/1`). Sign-out, revoked grants,
   stop, deletion, a newer generation or placement and a stale report on a
   live session stay conclusive, including while Lilly reconnects.

Guest SSH renewal (`Marshall.Ingress.Sessions`) had the same reconnecting
refusal and now follows this decision too, recorded as a correction in
[ADR-0187](0187-detached-ingress-bridges.md).

This narrows [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md)'s
rule that "a reset or replaced connection session still ends authority at
once" for the renewal of an already admitted editor, web or guest SSH stream
only: the
stream keeps its remaining lease (at most 30 s) through the reconnect, and
cannot be extended until the new session reports. Admission, terminal and
nested stream authority are unchanged. During that window a stream whose
execution Marshall can no longer observe lasts at most its lease, the same
bound ADR-0187 accepts for a live bridge while Lilly is down.

## Alternatives

- **Keep the BEAM for setup, then hand off the guest connection.** The BEAM
  would hold the guest socket during setup and pass it to hostd afterwards.
  Rejected: hostd sends the BEAM no descriptor (ADR-0184 decision 1), so the
  guest connection never reaches the BEAM; it would need a new descriptor
  path in the other direction, against the custody rule.
- **Let the bridge process run the stage.** The unprivileged bridge would
  receive the preface and frame over its control socket and exchange them
  with the guest. This keeps guest bytes out of root entirely, but needs a
  second handshake protocol in the bridge, and the preface (which names a
  user and account) would cross another process. The root stage reads at
  most 256 bytes and compares them, which is a smaller surface than the
  existing namespace dial. Recorded as a possible hardening.
- **Have hostd parse the ready frame.** Rejected: that moves the readiness
  decision into hostd. An exact byte comparison against Lilly's frame keeps
  the decision in Lilly.
- **Re-admit the editor stream after a Lilly restart instead of renewing.**
  Audi would open a new lease under the new session. Rejected: admission
  issues a new binding, and Audi deliberately refuses a renewal whose binding
  changed, so the live WebSocket would still end.
- **Treat every renewal refusal as inconclusive during a grace period.**
  Rejected: it would delay sign-out and VM stop by the grace period. Only the
  reconnecting state is inconclusive, and only after the conclusive checks.
- **Keep editor and nested HTTPS on op 13 and accept the loss.** Editor
  clients reconnect, but a reconnect is visible to the user (VS Code shows
  "reconnecting" and may reload extensions), and the review found no reason
  the BEAM must stay in the path.

## Consequences

- A live browser editor WebSocket or nested HTTPS connection survives a
  restart of `lilly-hostd`, of Lilly or of both, with the same bounded fence
  gap as ADR-0187: a revoked execution's live connection can last Lilly's
  downtime plus 30 s.
- A detached editor connection's setup takes the dial, up to 20 s of guest
  cold start and the scope start inside one hostd request thread. The BEAM's
  setup budget for a detached editor is 32 s and its hostd call bound is
  dial + ready + 10 s; Audi still gives up after 22 s, as before.
- A nested HTTPS bridge's record stores the client's IPv4 endpoint in
  Lilly's private 0700 directory until the bridge ends. It holds no
  credential.
- The op 14 wire layout changes without a protocol version change. Lilly
  and hostd come from one closure and restart together (`BindsTo=`), so a
  mixed pair is not a supported state. An old Lilly against a new hostd
  fails decoding (the first bytes of its mark exceed the preface bound) and
  the hostd session ends; the reverse pairing is not checked. Live bridges
  are unaffected because the bridge binary's interface is unchanged.

## Invariants and verification

- hostd decodes op 14 exactly when every length fits its bound and the
  ready wait matches the expected frame (`hostd-ingress-decoding`, Hegel).
- hostd writes the preface whole, accepts only the exact frame, reads no
  byte past it, and refuses a different frame, a closed guest or a silent
  one (`ingress-guest-stage`, `hostd-ingress-guest-stage`).
- Lilly derives the stage only from the validated binding and target:
  nothing for SSH, exactly one PROXY v2 header for nested HTTPS, the editor
  binding and exact ready frame for the editor (`ingress-detached-stage`,
  `ingress-detached-stage-fixture`).
- Editor and nested HTTPS connections are reserved, recorded, bridged and
  kept like SSH (`ingress-detached-handoff`,
  `ingress-editor-https-detached-fixture`).
- The machine test must show live editor WebSockets kept, with frames still
  arriving, across a hostd restart and a Lilly restart, held by bridges in
  `lilly_ingress.slice` connected to the guest's port 4444
  (`journey-editor-restart-keeps-bridges`,
  `editor-websocket-survives-restarts`).
- Editor and web renewal while Lilly reconnects are `unavailable`, then
  succeed with the unchanged binding once the new session reports; admission
  in that window is refused; sign-out, stop, a newer generation and a stale
  report stay conclusive (`ingress-renewal-host-reconnecting`,
  `editor-renewal-across-lilly-restart`,
  `editor-renewal-revocation-stays-conclusive`,
  `web-renewal-across-lilly-restart`).
- Audi keeps a stream through `unavailable` renewals and carries it past its
  original deadline once a grant returns; `unauthorized`, `forbidden` and
  `authentication_required` end it at that renewal
  (`audi-renewal-across-lilly-restart`, `audi-renewal-revocation-conclusive`).

## Implementation evidence

- hostd: [`ingress.rs`](../../../lilly/native/hostd/src/ingress.rs)
  (`Stage`, `stage`, bounds),
  [`protocol.rs`](../../../lilly/native/hostd/src/protocol.rs) (op 14
  layout), [`session.rs`](../../../lilly/native/hostd/src/session.rs)
  (`bridge_ingress` stages before `start`). Tests in
  [`ingress_tests.rs`](../../../lilly/native/hostd/src/ingress_tests.rs):
  the extended Hegel decoding model and the stage test against socket pairs.
- Lilly: [`Lilly.Network.Ingress`](../../../lilly/lib/lilly/network/ingress.ex)
  (`detachable?/1`, `stage/3`, `bridge/6`),
  [`Lilly.Host.Hostd`](../../../lilly/lib/lilly/host/hostd.ex)
  (`bridge_ingress/5`),
  [`Lilly.Ingress.Server`](../../../lilly/lib/lilly/ingress/server.ex)
  (detached editor budget). Tests in
  [`ingress_bridges_test.exs`](../../../lilly/test/ingress_bridges_test.exs).
- Marshall: [`Execution`](../../../marshall/lib/marshall/ingress/execution.ex)
  (`current!/4` with `:renew`, `renewable!/2`),
  [`Editor.Authority`](../../../marshall/lib/marshall/editor/authority.ex)
  (`:renew_editor` without the session pin),
  [`WebStreams`](../../../marshall/lib/marshall/ingress/web_streams.ex)
  (`:renew_web`). Tests in
  [`editor_test.exs`](../../../marshall/test/marshall/editor_test.exs) and
  [`access_test.exs`](../../../marshall/test/marshall/ingress/access_test.exs).
- Audi: tests with a scripted control channel in
  [`http_authority_test.exs`](../../../audi/test/http_authority_test.exs);
  Audi's code is unchanged.
- Diagnostics: hostd's reaper reports every detached bridge it reaps as one
  fixed-grammar stderr line, `ingress.bridge_exited` with a closed `outcome`
  (`ok`, `exit_io`, `setup_failed`, `exit_other`, `signal`) and `signal`
  class (`none`, `pipe`, `kill`, `other`), with no pid, key, path or bytes
  (`hostd-detached-bridge-exit-report` in
  [`exec.rs`](../../../lilly/native/hostd/src/exec.rs), classification test
  in [`ingress_tests.rs`](../../../lilly/native/hostd/src/ingress_tests.rs)).
  A bridge that outlives hostd is reaped elsewhere and is not reported. The
  report stays in hostd's journal; Lilly does not see it, because hostd has
  no asynchronous notification to Lilly. The bridge ignores SIGPIPE through the
  Rust runtime, so splicing into a closed peer exits `exit_io`
  ([`bridge.rs`](../../../lilly/native/ingress-bridge/tests/bridge.rs),
  `guest_loss_while_relaying_exits_with_io_failure_not_sigpipe`).
- Machine test: the editor fleet subtest "live editor WebSockets survive
  lilly-hostd and Lilly restarts in detached bridges"
  ([`fleet.py`](../../../nix/verification/tests/machines/vscode-web/fleet.py),
  browser helper [`restart.py`](../../../nix/verification/tests/machines/vscode-web/restart.py))
  exists. Its first run failed on the renewal causes above; the corrected
  subtest has not run yet.

Remaining: the corrected machine subtest has not run; nested HTTPS renewal
still pins the host session through its publication
(`inception-current-stream-authority`, five-second leases), so a nested
HTTPS stream outlives a hostd restart but not a Lilly restart until the
publication is re-offered and the stream re-admitted (this includes nested
`porsche_ssh` and `audi_ssh`); nested HTTPS has no machine
evidence because the Inception fleet is out of scope; the editor's cold
start on a loaded host can approach Audi's 22 s bound now that a scope start
follows the ready frame.

## Open questions

- Whether the stage should move into the unprivileged bridge process (see
  Alternatives). It would remove the last guest bytes hostd reads.

## Related decisions

- [ADR-0187](0187-detached-ingress-bridges.md): decision 1 is amended here;
  the rest applies to every ingress service.
- [ADR-0184](0184-lilly-owns-every-socket.md): custody and op 13 remain; op
  13 is now only a fallback.
- [ADR-0182](0182-unprivileged-lilly-beam.md): the unprivileged BEAM and hostd
  as the only root component.
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md): decision 6
  narrows its replaced-session rule for editor and web stream renewal.
- [ADR-0153](0153-official-source-browser-editor.md) (superseded): the origin
  of the editor lease's host-session binding, removed from renewal here.
- Review: [2026-10-17 staged detached ingress](../reviews/2026-10-17-staged-detached-ingress.md).
