# ADR-0223: Porsche terminal attach through a Marshall gateway stream

- ID: ADR-0223
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Porsche, Marshall, protocol, Mila
- Supersedes: none
- Superseded by: none

## Context

Mila needs the same persistent terminal sessions the browser uses
([ADR-0083](0083-terminal-host-stream-and-registry.md),
[ADR-0117](0117-personal-terminal-machine-workspace.md)), attached over its one
Porsche connection, with replay from a cursor and a read-only mode.

## Decision

1. Porsche adds `terminal ls|new|kill M [S]` and `terminal attach M S
   [--cursor N] [--read-only]`. Attach is not a mutation: its ticket is never
   pinned in a receipt or printed.
2. Marshall adds `GET /api/terminal-gateway/v1/stream` on the fleet endpoint,
   authenticated by the Porsche gateway bearer plus a terminal ticket, which
   upgrades into `Marshall.Terminal.Viewer` with an `{:ssh, gateway, session}`
   authority rechecked every 5 seconds.
3. Porsche's channel gains an attach mode that requires a prior `pty` request.
   It relays input (gated by the terminal window), acknowledges output only
   after the local SSH send succeeds, maps `window_change` to resize, writes
   one JSON header line on stderr and maps exits to closed codes. Terminal
   bytes are never logged.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Direct SSH to the guest through Audi.** Rejected: it bypasses the shared
  browser session and its writer authority.
- **Relaying over the control websocket.** Rejected: terminal bandwidth would
  share the control link's backpressure.

## Consequences

The gateway stream becomes a new authenticated Marshall surface with its own
threat model (HLDD chapter 20).

## Invariants and verification

- Read-only attachments never send input; key revocation closes an attach
  within 5 seconds; journals contain no terminal bytes (planned fleet machine
  test `porsche-terminal`).
- Output credit is granted only after a successful local send (planned
  Covenant obligation).

## Implementation evidence

Partial (S2, 2026-10-19): `terminal attach`, the gateway stream, the SSH
viewer authority and Porsche's attach mode are implemented; `terminal
ls|new|kill` belong to the separate client-commands workstream, and Mila does
not yet drive attach.

- Command grammar and closed exit, close-code and header tables:
  [ssh_command.ex](../../../protocol/lib/overalls_protocol/ssh_command.ex),
  [terminal_attach.ex](../../../protocol/lib/overalls_protocol/terminal_attach.ex)
  and the shared [fixture](../../../protocol/test/fixtures/terminal_attach.json),
  conformance-tested with Hegel properties in
  [terminal_attach_test.exs](../../../protocol/test/terminal_attach_test.exs).
- Gateway stream:
  [TerminalGatewayAPI](../../../marshall/lib/marshall_web/terminal_gateway_api.ex)
  on the [fleet endpoint](../../../marshall/lib/marshall_web/fleet_endpoint.ex);
  `{:ssh, gateway, session}` authority, SSH-session-bound tickets and the
  5-second recheck in [Viewer](../../../marshall/lib/marshall/terminal/viewer.ex),
  [SSH.Authority](../../../marshall/lib/marshall/ssh/authority.ex) and
  [Tickets](../../../marshall/lib/marshall/terminal/tickets.ex); the ticket is
  issued by [SSH.Commands](../../../marshall/lib/marshall/ssh/commands.ex).
  End-to-end with the real Porsche listener:
  [ssh_terminal_attach_test.exs](../../../marshall/test/marshall_web/ssh_terminal_attach_test.exs).
- Porsche attach mode: [Channel](../../../porsche/lib/porsche/ssh/channel.ex),
  [Attachment](../../../porsche/lib/porsche/terminal/attachment.ex) and
  [Credit](../../../porsche/lib/porsche/terminal/credit.ex), tested in
  [terminal_attachment_test.exs](../../../porsche/test/terminal_attachment_test.exs)
  and the Hegel model in
  [terminal_credit_property_test.exs](../../../porsche/test/terminal_credit_property_test.exs).
  Output credit after a successful local send is Covenant obligation
  `porsche.terminal.I3` in
  [terminal.obligations.md](../../../porsche/contracts/porsche/terminal.obligations.md).
- Native journey: the `porsche-terminal-fleet` machine test
  ([scenario](../../../nix/verification/tests/machines/fleet/scenarios/porsche-terminal.py),
  registered in the [fleet suite's BUCK](../../../nix/verification/tests/machines/fleet/BUCK))
  evaluates but has not yet recorded a passing run. Shared-session,
  read-only, revocation-within-5-seconds and journal-privacy claims are
  established natively only once it passes.

Run counts and gaps: [S2 review](../reviews/2026-10-19-mila-terminal-attach.md).

- **Mila client:** [`terminal_attach.dart`](../../../mila/packages/mila_core/lib/src/terminal_attach.dart)
  decodes the bounded stderr header and maps exit statuses as in
  `terminal_attach.json`; the PTY channel is in
  [`channels.dart`](../../../mila/packages/mila_transport/lib/src/channels.dart).
  Stock OpenSSH merges stderr into the PTY, so the header path is proven only
  in memory. These client tests have not yet run on the integrated tree.

## Open questions

None.

## Related decisions

[ADR-0019](0019-terminal-session-and-writer-authority.md),
[ADR-0083](0083-terminal-host-stream-and-registry.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0222](0222-porsche-client-commands.md).
