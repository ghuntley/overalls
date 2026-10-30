# ADR-0141: Control-plane hints and resync

- ID: ADR-0141
- Date: 2026-10-05
- Status: accepted
- Implementation: partial
- Components: Marshall
- Supersedes: none
- Superseded by: none

## Context

[ADR-0140](0140-event-driven-liveness-and-single-writer-views.md) requires
revocation to take effect at once, with time windows only as backstops. It left
two items open: Marshall-pushed stream revocation, and terminal viewer
authority still being a one-second poll. Marshall has no way to tell anything
that state has changed. Every consumer polls.

Observed facts:
- Marshall nodes share only PostgreSQL. Erlang distribution is off
  ([ADR-0085](0085-inception-public-ingress.md)), so
  `Phoenix.PubSub` reaches only the local node.
- Oban's PostgreSQL notifier is already running on every node. Its
  `pg_notify` runs on the caller's connection, so inside a transaction a
  notification is delivered only if the transaction commits. Notifications
  sent while a node's listener is disconnected are lost, and Oban gives
  listeners no reconnect signal; it reports only a status switch.
- Many mutations end authority: grant and team changes, token and session
  revocation, passkey, MFA and administrator changes, terminal session sharing
  and kill, VM transitions, endpoint policy and environment publication, host
  and gateway credential changes. Before this decision, none of them told
  anyone.

## Decision

Authorized by the user's approval on 2026-10-05 of the control WebSocket plan,
which makes this its phase P0.

- **Hints, not authority.** `Marshall.Control.Hints` publishes `{kind, id}`
  over one Oban notifier channel. `kind` is from a closed set and `id` must be
  a canonical UUID. Every subscriber reacts by re-reading durable state
  through its existing full check, so PostgreSQL stays the only source of
  truth ([ADR-0003](0003-control-plane-coordination.md)).
- **In the transaction.** A hint is emitted on the mutating transaction's
  connection, so an uncommitted change never notifies. Like any statement of
  that transaction, a failed `pg_notify` aborts it. Outside a transaction a
  failure is dropped.
- **Structural producers.** The Ash change `Marshall.Control.Hints.Change`
  emits the hint in `after_action`, inside the action's transaction. It is
  attached in each resource's `changes` block to the authority-reducing
  actions. Raw-SQL token revocation paths call the hint explicitly. A catalog
  test fails if a catalogued action lacks its hint.
- **Delivery and resync.** `Hints.Relay` on each node rebroadcasts hints
  locally on `control:<kind>:<id>`. When Oban's notifier leaves `:isolated`,
  the relay tells every local subscriber to resync, because hints sent during
  the outage are lost.
- **Backstops stay.** Lost hints are caught by each subscriber's existing poll
  or lease. Lengthening those backstops is a later step that needs native
  evidence.
- **First consumer: terminal viewers.** A viewer subscribes to its actor's user
  hints and its machine's hints, plus resync, and rechecks immediately on any
  of them. The one-second poll remains as the backstop.

## Alternatives

- **Scattered explicit calls at each mutation site.** This was the first
  draft. An inventory found more than a dozen uncovered authority-reducing
  paths, so a structural hook with a coverage gate replaces it.
- **Ash notifiers.** These run after commit, outside the transaction, so they
  would lose the commit-gated delivery and would need a separate outbox.
- **Erlang clustering or a directory table for hints.** Distribution is
  excluded by ADR-0085. A directory adds writes and expiry handling for
  broadcast traffic that is tiny.

## Consequences

- Revocation reaches local and remote subscribers within notifier latency
  instead of the poll interval.
- Every hinted action adds one notification to its transaction. High-rate
  actions (host reports, VM observations) are deliberately not hinted.
- A hint-delivery failure inside a transaction now aborts that transaction.
  This is the same failure class as any other statement that hits a lost
  connection.

## Invariants and verification

- Only closed kinds and canonical UUIDs are delivered: a property test in
  `marshall/test/marshall/control/hints_test.exs`.
- Every catalogued action carries its hint: the catalog test in the same file.
- A committed hint crosses nodes and a rolled-back one does not: two
  independent BEAMs sharing PostgreSQL in
  `marshall/test/marshall/control/hints_distributed_test.exs`.
- Notifier recovery forces a resync: the relay test in `hints_test.exs`.
- A committed grant revocation emits a hint, and the hint alone closes an
  attached viewer: `marshall/test/marshall/terminal/authority_test.exs`.

## Implementation evidence

- [hints.ex](../../../marshall/lib/marshall/control/hints.ex),
  [relay.ex](../../../marshall/lib/marshall/control/hints/relay.ex),
  [change.ex](../../../marshall/lib/marshall/control/hints/change.ex).
- Resource `changes` blocks, for example
  [grant.ex](../../../marshall/lib/marshall/access/grant.ex) and
  [virtual_machine.ex](../../../marshall/lib/marshall/compute/virtual_machine.ex).
- Viewer subscription in
  [viewer.ex](../../../marshall/lib/marshall/terminal/viewer.ex).
- Node-local PubSub also bounds the browser LiveView transport. A long-poll
  session lives in one node's PubSub, and the proxy balances each request
  round-robin, so the session cannot be resumed by its next request. Phoenix
  also memorizes a fallback per tab, so one ping slower than the 2.5-second
  fallback threshold left loaded browsers on a transport that never joined.
  The [endpoint](../../../marshall/lib/marshall_web/endpoint.ex) now offers
  only the WebSocket transport and
  [app.js](../../../marshall/assets/js/app.js) no longer falls back; the
  [endpoint test](../../../marshall/test/marshall_web/public_endpoint_test.exs)
  checks that long-poll is absent. This is a correction to match the
  accepted topology, not a new decision.

Remaining gaps:
- No pushed consumer outside Marshall yet; the control WebSocket phases add
  Audi, Lilly, Ziggy, Galileo and Porsche.
- Viewers do not yet subscribe to host hints.
- Hinted host-credential changes beyond the Host resource actions (credential
  rotation and revocation in `Compute.Credentials`) are not covered.
- No native measurement of push latency has been recorded yet.

## Open questions

- Backstop lengths once push is proven (control WebSocket plan, phase P6).

## Related decisions

- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md)
- [ADR-0003](0003-control-plane-coordination.md)
- [ADR-0085](0085-inception-public-ingress.md)
