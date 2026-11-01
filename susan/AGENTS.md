# Susan guidance

Follow [root guidance](../AGENTS.md) and [ADR-0224](../docs/architecture/decisions/0224-susan-push-relay.md).
Susan is the independently deployed, content-free push relay for Mila. It has
its own Ash domains (`Susan.Relay`, `Susan.Audit`), its own PostgreSQL database
and no dependency on Marshall, Lilly or Porsche.

- Keep the poke pipeline in the pure `Susan.Poke.Machine`; `Susan.Poke` only
  interprets its commands. Change states and responses there first, with the
  property tests in `test/susan/machine_property_test.exs`.
- Never store or log provider tokens, push-key envelopes, ciphertext, install
  keys or source addresses. Events go through `Susan.Events` with enum/integer
  metadata only; audit rows use the closed action and reason enums.
- 400 and 404 bodies are identical, and unauthenticated pokes cause no database
  write. Keep both properties when adding refusals.
- Provider HTTP is injectable (`config :susan, provider_http:`); tests use
  `Susan.FakeProvider`. Never add configurable egress origins.
- The audit table is append-only in the database (trigger and REVOKE). When
  adding an audit action, update `Susan.Audit.AuditEntry` and the Events
  catalog `susan.audit_appended` enum in the same change.
- Run `tools/precommit` (`//susan:check` and `//susan:test`). The NixOS checks `susan-release`, `susan-service`,
  `susan-secrets` and `susan-image` exercise the release, secret custody and
  OCI image; Covenant evidence covers only BEAM-observable behaviour.
