# ADR-0268: Cedar is Marshall's single authorization source

- ID: ADR-0268
- Date: 2026-10-30
- Status: accepted
- Implementation: partial
- Components: Marshall authorization, Accounts, SCIM, Compute, Threads, Artifacts, Access, Teams, Ingress, SSH
- Supersedes: none
- Superseded by: none

## Context

Marshall made authorization decisions in two places:
- **Cedar.** Policy in `marshall/priv/cedar`, evaluated through ex_cedar. It was reached through `Marshall.Authorization.AshAuthorizer` on most Ash resources, and through direct `Cedar.allowed?` calls from coordinators, SSH and batched page snapshots.
- **Ash.Policy.** Eleven account and SCIM resources used `Ash.Policy.Authorizer`, with Elixir check modules and the AshAuthentication and AshScim interaction bypasses. This followed the ADR-0119 requirement that "account reads and mutations use separate Ash policy checks", which ADR-0123 and ADR-0160 carried forward.

Observed facts (2026-10-30):
- **Two sources of truth.** Which actions a principal may call was split across a nested resource/action table in `AshAuthorizer`, Ash policy blocks, three Elixir check modules, two library bypasses, and `authorize?: false` call sites.
- **Accidental behaviour that no decision records:**
  - `InternalLookup` admitted the compute system actor to every action on its resources.
  - The SCIM archive projection trusted the caller's struct for administrator status.
  - User reads such as `:read`, `get_by_*` and `sign_in_*` were reachable only through the "always" bypasses.
  - Two compute User reads ran with `authorize?: false`.
- **Performance.** Ash.Policy simplifies every policy on the resource with the Crux SAT library on each authorized call. A Cedar decision for a User principal first reloaded the principal through two Ash.Policy-authorized reads (User and Token), so each decision cost about three database round trips and two Crux solves. LiveView hooks repeat this on every callback. A stack-sampling profile put about a quarter of `mfa_login_history`'s samples in Crux, and several property tests exceeded their budgets.
- **Engine capability.** cedar-policy 4.11 provides type-aware partial evaluation (TPE). A spike evaluated `read` on `VM` with principal and resource unknown and got residual policies in Cedar JSON form. A typed decision costs about 60 µs.

The user asked for the best design with a single source of truth and no limit on refactoring. They required no backwards compatibility and made performance a first-class requirement (plan approved 2026-10-30).

## Decision

**Single source.** Cedar policy and schema (`marshall/priv/cedar`) are the only place Marshall's access rules live. No Elixir check module, Ash policy, library bypass or `authorize?: false` makes or skips an authorization decision. The narrow exceptions are the named library internals under "Library and system principals" below.

**Declarative mapping.** `Marshall.Authorization.AshAuthorizer` is both Marshall's only Ash authorizer and a Spark extension. Every resource declares, next to its actions, a `cedar` block that maps every action to exactly one kind of check:
- `control_plane "<cedar action>", [actions]`: admission on `ControlPlane::"marshall"`, for public entry actions whose coordinators then make record decisions;
- `internal [actions]`: `coordinate` on `Internal::"<Resource>:<action>"`, which only `System::"compute"` holds;
- `service :ash_authentication | :scim, [actions]`: the library service principal's own Cedar action on the same `Internal` entity;
- `record "<cedar action>", "<EntityType>", [actions]`: an update or destroy decided on the loaded record's primary key;
- `refused [actions]`: never admitted, such as paper-trail version updates.

Compile-time verifiers reject:
- an unmapped action (deny by default) and a mapping that names a missing action;
- duplicate rules;
- record rules on anything but update or destroy;
- an action both refused and admitted;
- a control-plane Cedar action that doesn't apply to `ControlPlane`.

Generated paper-trail version resources get their mapping through the `Marshall.Authorization.VersionMapping` mixin. The mapping only says what is being asked; Cedar decides who may.

**Entity attributes in SQL.** A Cedar entity type backed by a table has one `Marshall.Authorization.Record` module (for example `Marshall.Compute.VirtualMachine.Cedar`). It defines each schema attribute once, as an Ash expression over the row, and nothing else. No Elixir code assembles a record entity.

**Record decisions and read filters from residuals.**
- `Marshall.Authorization.Filter` asks Cedar TPE once per (principal type, action, entity type), with principal and resource unknown. It keeps the residual policies as a template in `:persistent_term`, keyed by the engine.
- A decision binds the loaded principal's attributes and constant-folds. It translates the remaining resource-attribute uses through the record module, and computes the permits AND NOT the forbids as an Ash filter.
- `Marshall.Authorization.allowed?/4` is `WHERE id = $1 AND <filter>`. `prefetch/4` decides a page in one query and primes the decision scope. `filter/4` restricts a list read to exactly the permitted rows.
- A residual shape, attribute or principal attribute the translator doesn't recognise fails closed: that decision is `false`, and the catalogued `cedar.filter_unsupported` error event is emitted. A test translates every production record action for a user principal, so an untranslatable policy fails CI rather than denying owners in production.

**Typed API.** Code that is not an Ash action entry uses `Marshall.Authorization` (`control_plane?/2`, `allowed?/4`, `prefetch/4`, `filter/4`) or the domain facades built on it. This covers coordinators, SSH, guest web, terminals, snapshots and LiveViews. The Cedar engine is Marshall's own Rustler NIF (`marshall/native/marshall_cedar`), which replaces ex_cedar.
- Policy and schema must pass strict validation with no errors or warnings before Marshall starts.
- A request whose declared principal or resource type the action doesn't apply to is a plain deny. Undeclared types, entity non-conformance and evaluation errors raise and deny with `cedar.evaluation_error`.

**Library and system principals.** Every caller is a typed principal:
- **User:** attributes `administrator` and `elevated`, loaded once per authorization scope.
- **`System::"compute"`:** internal coordination, admitted only to actions the mapping declares internal.
- **`Service::"ash_authentication"`:** admitted only to the authentication actions the mapping names: the User sign-in and lookup actions AshAuthentication invokes, and the Token actions.
- **`Service::"scim"`:** the SCIM service owner while SCIM is enabled, admitted only to the mapped SCIM actions.

The bypasses are removed, and Marshall's own code never sets library context flags. Library internals that skip authorization are named in this record's evidence. Only AshPaperTrail's version writes remain; Marshall doesn't use AshAuthentication's WebAuthn strategy, because passkeys are Marshall's own internal resources.

**Intended rules for formerly accidental behaviour:**
- The system principal performs only actions declared internal.
- The SCIM archive projection is internal (system-only): it has no user-facing reads.
- Plain User `:read` is internal. The library actions belong to their service principals.
- Compute reads of User go through the system principal's internal lookup.

**Performance contract:**
- **One principal load per decision scope:** `Marshall.Authorization.Principal` is one internal SQL query, not an authorized Ash read. It returns the user, deleted and active state, administrator, presented-login presence and elevation. Inside a `DecisionSnapshot` scope it loads once; outside one, every decision reads fresh. Authority is never cached across scopes.
- **Admission depends only on principal attributes:** it costs one in-memory NIF call, about 60 µs.
- **Record decisions are one query each:** a prefetched page is one query, and later per-record decisions in that scope cost nothing. List reads are a single filtered SQL query, with grant and team relations joined through `EXISTS`.
- **No partial evaluation at request time:** residual templates are computed once per engine.

This replaces the carried-forward ADR-0119 clause "Account reads and mutations use separate Ash policy checks". ADR-0160's administrator step-up, receipts and elevation semantics are unchanged. They now feed Cedar's `elevated` attribute only through the principal loader. Authorization source: the user's approved plan of 2026-10-30.

## Alternatives

- **Keep Ash.Policy on the accounts resources and shrink User's policy set.** Rejected: it keeps two sources of truth and leaves Crux on the hot path.
- **Ash.Policy everywhere.** Rejected:
  - it spreads policy across arbitrary Elixir and loses Cedar's schema validation and analyzability;
  - every call would pay Crux, which is slower;
  - it cannot cover the SSH, coordinator and snapshot paths.
- **Ash.Policy as the mechanism with one Cedar check per resource.** Rejected: the library bypasses and filter policies remain a second decision source, and Crux stays in the path.
- **Vendor and patch ex_cedar.** Rejected in favour of a small Marshall-owned NIF: it exposes exactly compile, typed authorize, batch authorize and residuals; takes typed terms instead of JSON; and doesn't carry a fork.

## Consequences

- **Benefits:**
  - one auditable, schema-validated policy source;
  - list reads authorize in SQL;
  - no authorization round trips beyond one principal load per scope;
  - no SAT solving per call;
  - a structural gate keeps the design from drifting.
- **Costs:**
  - every resource carries a mapping block;
  - the residual translator and TPE are new trusted code, and TPE is experimental in cedar-policy 4.11;
  - the NIF is Marshall-maintained.
- **Compatibility:** none. This is a direct cutover. Behaviour that was accidental before changes to the intended rules above, and the decision-table tests encode those rules.
- **Operational risk:** an untranslatable or invalid policy stops Marshall at boot rather than failing open.

## Invariants and verification

- **Deny by default:** an unmapped action fails compilation. An unknown principal, a missing record, an untranslatable residual or an evaluation error denies.
- **Schema conformance:** policy and schema pass strict validation at boot. Control-plane mappings must name actions that apply to `ControlPlane`.
- **Residual soundness:** for each generated principal relation, machine profile and owner state, the SQL record decision, list-filter membership, a Cedar decision over a hand-built entity and the real `get_vm` outcome all equal a decision table written from this record (VM first).
- **Principal scoping:**
  - service principals reach only their mapped actions;
  - system-only resources refuse users, elevated administrators, nil and both services;
  - Token admits only AshAuthentication.
  - An actorless call is presented as AshAuthentication only when AshAuthentication itself set its private flag. Marshall code never sets library flags.
- **Performance:** query-count tests pin a record decision at one principal query plus one decision query, a prefetched page at one decision query in a scope, and a filtered read at the read plus the principal query.
- **Structural gate:** a test fails if any Marshall resource has an authorizer other than `AshAuthorizer` or an action without a rule. It also fails if Marshall's `lib` mentions `Ash.Policy`, `authorize_if` or `authorize?: false`, or sets a library context flag.
- **Disproof cases:**
  - a residual translation that admits a record Cedar denies, or denies one it admits;
  - a service principal reaching an unmapped action;
  - a stale principal surviving into a later scope.

## Implementation evidence

- **Mapping and authorizer:** [`ash_authorizer.ex`](../../../marshall/lib/marshall/authorization/ash_authorizer.ex) and `resource/{rule,info,persist,verifier}.ex`, plus `version_mapping.ex`. Every resource carries a `cedar` block; `Accounts.Checks.*`, every `policies` block and the nested resource table are deleted.
- **Record modules:** `compute/virtual_machine/cedar.ex`, `threads/thread/cedar.ex`, `teams/team/cedar.ex`, `artifacts/artifact/cedar.ex`, `galileo/integration/cedar.ex` and `terminal/session/cedar.ex`.
- **Translator and typed API:** [`filter.ex`](../../../marshall/lib/marshall/authorization/filter.ex), [`authorization.ex`](../../../marshall/lib/marshall/authorization.ex), `authorization/principal.ex` and `authorization/cedar.ex`.
- **Principals:** `SystemActor.service/1`. The SCIM entry (`scim/auth.ex`) and the magic-link request use service principals, and all 36 former `authorize?: false` sites use the compute principal.
- **Policy:** `priv/cedar/schema.cedarschema` and `compute.cedar` add:
  - the `Service` principals, `account_self` and `TerminalSession`;
  - owner-active, sharing, terminal and web capability attributes, which replace Elixir-side profile and owner checks.
- **Tests** under `marshall/test/marshall/authorization/`:
  - [`structure_test.exs`](../../../marshall/test/marshall/authorization/structure_test.exs) (structural gate);
  - [`vm_decision_table_test.exs`](../../../marshall/test/marshall/authorization/vm_decision_table_test.exs) (Hegel decision table);
  - `system_only_refusal_test.exs`;
  - `filter_translation_test.exs`;
  - `query_count_test.exs`.
- **Review:** [2026-10-30 review](../reviews/2026-10-30-cedar-single-authorization-source.md) records the executed evidence and the gaps.
- **Exceptions that remain library-internal:**
  - AshPaperTrail writes versions without authorization, because the domains don't set `authorize :always`; Marshall maps version reads and creates as internal and refuses updates.
  - AshAuthentication's own token and sign-in calls are decided as `Service::"ash_authentication"`.

## Open questions

- **Galileo machine eligibility:** Galileo's machine-to-integration eligibility (`galileo/authorizations.ex`, `reflection/snapshots.ex`) decides for a VM principal in Elixir through `Galileo.Ownership.live?`. It needs a VM principal type in Cedar, and it is the remaining Elixir-side rule.
- **Decision tables beyond VM:** Thread, Artifact, Team and Integration are covered by their existing domain suites, not by generated tables.
- **Normal-scheduler NIF variant:** whether one is worth adding for single decisions, decided from measured latency.

## Related decisions

- [ADR-0160](0160-privileged-administrator-step-up.md): administrator step-up and elevation, unchanged.
- [ADR-0199](0199-memory-suspension-and-demand-wake.md): current compute entry points.
- [ADR-0119](0119-authenticated-control-room-reads.md): control-room read access; its separate-Ash-policy clause is replaced here.
- [ADR-0256](0256-batched-page-authorization-snapshots.md): batched page authorization, kept where faster.
- [ADR-0253](0253-artifacts-domain.md): artifact Cedar roles.
