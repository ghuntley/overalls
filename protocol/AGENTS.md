# Protocol guidance

Follow [root guidance](../AGENTS.md). This dependency contains versioned wire
validation and types shared by Marshall and Lilly, and the pure state-machine,
cadence and single-writer in-memory view primitives every component shares
(ADR-0140). ADR-0142 additionally places the outbound control WebSocket client
in the named `Control.Client` and `WebSocket.Connection` modules. Keep codecs
and state/value primitives pure; those transport modules may own sockets and use
application-supplied credential callbacks and TLS trust. Keep the entire library
free of Ash, database access, host mutations and durable credential storage.
Never create atoms from peer input. Bound every
collection and integer before passing data to either application.

Build `//protocol:check //protocol:test` and both applications' `:check` and
`:test` (`tools/precommit` selects them) when this contract changes.
Codecs accept exactly the current shape. Change a shared message by ordered,
converged pushes (consumer tolerant, producer changes, decoder strict; ADR-0159),
never by keeping a compatibility reader, and cover each step with protocol tests.
