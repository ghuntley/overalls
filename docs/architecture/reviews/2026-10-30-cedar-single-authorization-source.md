# Cedar as Marshall's single authorization source (2026-10-30)

Scope: the authorization boundary of every Marshall Ash resource and every
non-Ash decision path, implementing
[ADR-0268](../decisions/0268-cedar-single-authorization-source.md). The change
moves the eleven `Ash.Policy` resources, the nested authorizer table, the
Elixir check modules, the AshAuthentication/AshScim bypasses and all
`authorize?: false` sites in Marshall code onto Cedar.

## Changes

- **One authorizer and mapping.** `AshAuthorizer` is also the Spark extension
  every resource uses. Its `cedar` block maps each action to `control_plane`,
  `internal`, `service`, `record` or `refused`, and the verifiers reject
  unmapped, duplicate, contradictory and ill-kinded mappings. Paper-trail
  versions inherit their mapping through a mixin.
- **Principals.** `SystemActor` gains the `ash_authentication` and `scim`
  service purposes, each admitted only through its own Cedar action on the
  declared `Internal` entities; SCIM's `enabled` is a principal attribute read
  per decision scope. The authorizer presents an actorless call as
  AshAuthentication only when AshAuthentication set its own private flag; the
  three places Marshall forged that flag are gone.
- **Decisions in SQL.** Record decisions and list reads no longer assemble
  entities in Elixir. Cedar TPE residuals, cached per engine, are bound to the
  loaded principal and translated through one `Record` module per entity type
  (VM, Thread, Team, Artifact, Integration, TerminalSession) into an Ash filter.
  A record decision is `WHERE id = $1 AND <filter>`; a page is one query.
- **Rules moved from Elixir into Cedar.** The owner-account, profile sharing,
  terminal and web capability checks; integration liveness; account
  self-service (`account_self`); and terminal session sharing
  (`TerminalSession`). The artifacts library and pinned-machine lists lost
  their hand-written authorization SQL in favour of the residual filter.
- **Engine.** The Marshall NIF treats a declared principal or resource type
  that an action does not apply to as a deny; only undeclared types, entity
  non-conformance and evaluation errors raise.

## Accidental behaviour fixed

| Before | Now |
| --- | --- |
| `InternalLookup` admitted the compute actor to every action | compute is admitted only to actions mapped `internal` |
| SCIM archive projection trusted `actor.administrator` | internal only (it has no user-facing reader) |
| User `:read`, `get_by_*`, `sign_in_*` reachable only via bypasses | `service :ash_authentication` / `service :scim` rules |
| Compute User gets with `authorize?: false` | `internal_lookup` with the compute principal |
| Terminal session sharing decided in Elixir | Cedar `terminal_session_use` |

## Evidence

Executed on the throwaway cluster (`/tmp/oa-pg.AzB2:55471`), branch based on
`aaadafd55`:

- `test/marshall/authorization` (21 tests) pass: the structural gate, the
  60-case Hegel VM decision table (SQL decision = list-filter membership =
  hand-built Cedar entity = `get_vm` outcome = intended table), system-only
  refusals, production residual translation and the query budgets.
- **Query budgets** (deterministic): a record decision outside a scope is two
  queries (principal + decision); a three-record page inside a scope is two
  queries in total; a filtered list read is the read plus the principal query.
- **Full Marshall suite** (default tags, `--timeout 1800000`): every failure was
  fixed and rerun green except the known Inception failures
  (`InceptionTest` ×2, the `MachinesLiveTest` Inception selection), which are
  out of scope. One `JobHistoryTest` failure was caused by two committed
  fixture jobs leaked into the test database by an earlier killed run; it
  passes once they are removed and passes on trunk.
- **`mix precommit`** on the rebased tree: the toolchain, ADR, contracts,
  logging, compiler, format, Covenant (47/47), terminal, workspace, monospace,
  localization, gettext and `dialyzer --force-check` gates pass. The full test
  step ran past the two-hour limit on a host at load average 130–200. The
  executor-loss, operator-boot, Control room history and personal-session
  tests that failed there (Hegel `TooSlow` and timeouts) fail the same way on
  trunk `aaadafd55` under the same load, so they are not attributed to this change.
  That run did find one regression, which is fixed: a removed Galileo
  integration's replay was refused as `forbidden` because decisions read only
  unarchived rows. Integration decisions now read `:history`, as VM decisions do.
- **Native crate:** `marshall/native/marshall_cedar` carries the ADR-0265 lint
  policy and is gated by the `marshall-cedar-lints` flake check (rustfmt and
  clippy `-D warnings` over the vendored lockfile); `rust-lints --strict` and
  `service-marshall` build.
- **Timing against trunk** (`sharing_matrix_history_test`, same machine):
  "grant churn" 293 s on trunk, 250 s on the branch. Trunk's "every shared
  role" history took 716 s; it was already beyond the suite's default budget
  before this change.

## Gaps

- Galileo's machine-to-integration eligibility still decides for a VM
  principal in Elixir (`Galileo.Ownership.live?`); it needs a VM principal type.
- Generated decision tables exist for VM only; other types rely on their domain
  suites.
- Not executed for this review: the distributed/host/capacity-tagged suites,
  the latency benchmarks for `fresh_login` callbacks and 1k/10k-row lists,
  `EXPLAIN` plans for the main list reads, and the machine tests named in the
  plan (account-lifecycle, control-room-browser, credential-self-service-browser,
  galileo-fleet, audi-fleet, SCIM).

Architecture impact: ADR-0268 is accepted and now `partial`; ADR-0119 (already
superseded) is the only record that carried the replaced Ash-policy clause.
