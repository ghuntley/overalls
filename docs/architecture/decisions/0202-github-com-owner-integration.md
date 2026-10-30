# ADR-0202: Owner-bound GitHub.com integration

- ID: ADR-0202
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Marshall, Galileo, Audi, protocol, Lyra, guest images, NixOS
- Supersedes: none
- Superseded by: none

## Context

Users need ordinary GitHub CLI, Git and Git LFS workflows without copying GitHub
credentials into their machines. Existing Galileo integrations inject
Marshall-custodied credentials into one authorized upstream attempt, but their
globally unique names and user-entered headers do not model a separate GitHub
account for every Marshall user or rotating OAuth credentials.

The user approved `github-com` at `https://com-github.integration.internal`,
automatic availability on eligible owner machines, persistent per-machine detach
and the VM owner's GitHub identity for shared writers. The October 18
implementation request authorizes this decision. Organization administration and
additional providers are outside the selected daily development permissions.

## Decision

### Personal connection and permissions

Marshall owns one current GitHub.com connection per User. A stable numeric GitHub
account ID, rather than a mutable login, identifies the external account; one
numeric account may have only one active Marshall connection. Connecting another
Marshall account to an already connected GitHub account refuses rather than
transferring authority. Users manage only their own connection through the
signed-in Integrations page.

Use a GitHub OAuth App with `offline_access`. Request exactly `repo`, `workflow`,
`read:org`, `project`, `gist`, `notifications`, `read:user`, `user:email`,
`read:packages`, `write:packages` and `offline_access`. These support repository
read/write, workflow changes, ordinary organization reads, projects, gists,
notifications and packages within the consenting user's GitHub rights. They do
not override organization approval, SAML SSO, repository permissions or GitHub
policy. Do not request organization administration or repository deletion.

GitHub's [2026-08-14 OAuth App announcement](https://github.blog/changelog/2026-08-14-multiple-redirect-uris-and-token-refresh-for-oauth-apps/)
and [authorization documentation](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps),
reviewed on 2026-10-19, document this credential model for GitHub.com. Requesting
`offline_access` obtains an eight-hour access token and a refresh token valid for
six months without use, even when the app has not globally enabled expiring
tokens. It is not a normal granted scope and need not appear in the returned
scope list. This is documented provider support, not evidence of consent or a
successful exchange by the registered Overalls app. GitHub Enterprise Server and
non-expiring-token fallback are outside this decision.

`POST /auth/github-com/start` begins authorization under the current completed
Marshall login and CSRF protection. `GET /auth/github-com/callback` accepts only
the current one-use, expiring attempt bound to that account and browser login.
Provider errors, replay, expired state, changed login and retired accounts
establish no connection. OAuth code/state values, token-bearing URLs and provider
bodies stay out of diagnostics and browser storage. Return only to the fixed
same-origin Integrations page.

The browser policy in ADR-0194 permits the fixed `https://github.com` origin
in `form-action`, including the start POST's authorization redirect. Its
same-origin script, connection and frame restrictions remain unchanged;
arbitrary HTTPS origins and wildcard subdomains remain refused.

Access and refresh tokens are sensitive Cloak-encrypted attributes in Marshall
PostgreSQL. Decrypt only for the provider exchange or authorized edge attempt.
Neither plaintext nor ciphertext enters PaperTrail, administrative job
projections, events or user responses. OAuth App credentials use the existing
host secret pipeline, outside images and the Nix store. Ordinary browser
sign-out preserves this separate GitHub connection; explicit disconnect and
account retirement withdraw it.

### Machine authority and forwarding

`com-github.integration.internal` is a built-in Galileo route, not a globally
registered generic integration name. Audi's private DNS, TLS frontend and
Lilly-derived pre-NAT execution binding remain the ingress boundary. The hostname
already matches `*.integration.internal`; ADR-0111's exact SAN set, offline issuer
custody and root distribution remain unchanged.

Each eligible non-Customer VM automatically resolves its owner's current GitHub
connection unless that owner has persistently detached it. Detach survives
reconnect, restart and relocation until explicit reattachment. New machines use
the current owner connection; copied disks carry no credentials. Generic personal
integrations retain ADR-0134's explicit attachment rule; team-owned integrations
retain their existing membership policy.

The trusted binding identifies a VM, not the human running a process. Every
permitted process on a shared VM therefore uses the VM owner's GitHub identity.
Guest usernames, environment, paths and headers cannot select another connection.
Authorized writers retain passwordless sudo under ADR-0158; no confidentiality
between those writers is introduced. Sharing an eligible machine intentionally
delegates the owner's GitHub operations without revealing their token.

Galileo accepts only reviewed REST, GraphQL, Git smart-HTTP and Git LFS routes.
Fixed server-owned destinations and validated rewrites select GitHub.com, never
an arbitrary guest-selected upstream. Platform credentials replace guest
Authorization. Uploads, responses and LFS content remain bounded streams;
redirects and response rewrites must not expose credentials or select an
unreviewed credential recipient. Git SSH, arbitrary CONNECT and self-hosted
origins acquire no GitHub authority.

Mutations never follow redirects or automatically retry. GET/HEAD may follow at
most three reviewed redirect hops under the same current lease and credential
generation. Signed storage hops receive no OAuth bearer. Credential-bearing LFS
action URLs and headers remain in Galileo memory behind opaque, method-bound,
execution/generation-bound selectors with at most sixty seconds lifetime and
earlier provider expiry. Mutation selectors have one winner; signed URLs and
action credentials never enter guest responses. JSON rewriting is limited to
eight MiB and thirty-two nested levels; binary content stays streamed.

Every attempt checks current host, placement, execution, owner and machine
eligibility. An absent, disconnected, detached, reconnect-required or
configuration-disabled connection allows reviewed routes to forward anonymously
without injecting a token. GitHub decides
which operations require authentication; this fallback imposes no global
GET/HEAD restriction. A connection actively draining or refreshing refuses new
admissions rather than changing identity mid-attempt.

An authenticated attempt additionally pins the connection generation and a short
renewable lease. Renewal returns bounded authority only, never replacement
credentials. Disconnect, detach, retirement or generation replacement withdraws
credential-bearing authority. Failed or expired renewal closes the existing
attempt without replaying it. A fresh anonymous request cannot revive the closed
authenticated attempt.

### Token lifecycle and recovery

Use explicit Ash state machines for connection and operation progress.
PostgreSQL owns attempt IDs, credential generations, deadlines and terminal
outcomes; Oban and AshOban deliver and reconcile work. Jobs carry IDs only.
Selecting an attempt and settling its result lock and re-read the connection;
provider waits happen outside database transactions. Duplicate workers and stale
results cannot publish another token generation or revive a disconnected user.

Begin refresh ten minutes before access-token expiry. Stop new old-generation
admissions, allow existing attempts to drain for at most five minutes, then
withdraw remaining leases before exchanging refresh credentials. Commit the
complete replacement access/refresh pair and expiry metadata atomically. Lease
expiry, token expiry and the drain deadline remain separate facts; none proves
an upstream request completed successfully.

The provider's documented refresh exchange invalidates both the consumed refresh
token and the previous access token. It returns a new pair with the previous
permission scopes; refresh cannot request additional scopes. An expired or
invalid refresh token returns `bad_refresh_token` and requires new browser
authorization. These semantics motivate draining and the recovery fence below.

A provider may rotate a token before Marshall commits its reply. An unanswered
exchange, lost worker or uncertain post-exchange commit must enter explicit
reconnect-required recovery instead of blindly replaying the old refresh token.
Definite pre-dispatch failures may retry under the same current-attempt rules;
invalid or revoked provider authority requires reconnection. Reconnection creates
a new fenced generation, so late callbacks, refresh replies and jobs cannot
restore older authority.

Known late or rejected pairs are retained encrypted in the failed attempt for
ID-only access-token cleanup and then cleared; minute reconciliation retries
that cleanup. Unknown provider replies remain an explicit recovery gap. Removing
OAuth configuration withdraws private admission/renewal but retains the encrypted
grant pending operator reconfiguration or revocation; it cannot prove remote
revocation. Restore startup refuses a pending epoch-publication sentinel before
starting the application, as well as invalid or unreadable final markers.

Managed `gh`, Git HTTPS and Git LFS configuration targets the private endpoint
without a real GitHub token in guest files, environment or arguments. Intended
support includes NixOS, Ubuntu, Arch, AlmaLinux, Windows, FreeBSD and OmniOS, plus
retained machines through a reviewed guest update path. Image recipes and
installed binaries do not establish seven-family runtime acceptance or upgrade
of existing writable disks. Exact admitted native images retain their immutable
qualification; changed candidates require independent promotion evidence.

## Alternatives

- Static bearer integrations lack per-user account identity, OAuth consent and
  refresh recovery; a globally unique name cannot represent this endpoint.
- GitHub App installation tokens do not express the selected broad personal
  identity and daily workflow permission model.
- Guest `gh` login or credential helpers would violate credential custody.
- Guest-selected user IDs cannot authenticate a human on a shared sudo-capable
  VM. Per-process personal authority needs a separate authenticated model.
- A new `*.internal` alias/certificate widens TLS without a required capability.
- Blind retries after ambiguous rotating refresh can lose the only valid pair;
  explicit reconnect preserves an honest recovery boundary.

## Consequences

Every permitted process on an eligible machine can exercise its owner's GitHub
authority, including shared writers. A user can detach one machine without
disconnecting their account. The scopes remain broad, while provider-side policy
can still refuse operations. Anonymous public forwarding remains available when
the connection is absent, detached or requires reconnection; it supplies no
private-resource authority. Marshall/database loss denies new admission and
eventually expires existing leases; it does not replay guest mutations or prove
their upstream outcome.

New resources, encrypted fields, audit retention and background work need
migrations and matching backup custody. Historical ciphertext may hold an already
consumed refresh token; decryption is not proof of usable provider authority.
Database restore quiesces serving and applies a durable external restore epoch
before any replica resumes. A singleton database acknowledgement makes a marker
idempotent across repeated starts. A new marker atomically advances every
connection generation, erases restored credentials and staged pairs, invalidates
browser attempts and request pins, and requires browser reconnection. The
supported restore wrapper durably publishes the marker before changing the
database; failed publication or invalidation withholds recovery startup. Raw
database replacement cannot be detected from restored database contents alone.
Operators must stop every replica and distribute one common fresh epoch before
any resumes; a local wrapper cannot prove remote fencing. Source and unit
fixtures do not establish an
executed backup/restore deployment journey.
Consumers must understand the route/fences before managed guests select it.
Retained-machine updates and seven-family acceptance remain delivery obligations.

## Invariants and verification

- Typed Hegel histories independently model callback replay, reconnect,
  disconnect, detach, reattach, expiry, refresh, ambiguous exchange and retirement.
  Compare durable rows and audit receipts after allowed/refused operations without
  printing generated credential values.
- Multi-Marshall schedules prove one refresh winner, unique active numeric
  ownership, atomic pair replacement and stale-settlement refusal.
- Protocol properties reject forged identity, unknown routes/fields, target
  escapes, credential-smuggling headers and invalid generation/deadline values.
- Controlled TLS origins independently count effects and observe cancellation,
  proving credential replacement, no mutation replay and no target leakage.
- Packaged machine journeys exercise browser OAuth and actual `gh`, Git and LFS
  through Marshall/Audi/Lilly/Galileo, two owners, shared writers, detach, refresh,
  revocation and relocation. Each OS and retained-machine update needs recorded
  evidence. Fixtures cannot establish live OAuth App support, organization
  approval or production rollout.
- Colocated contracts, Covenant obligations and payload-free Events accompany
  implementation; they complement native transport/isolation/recovery evidence.

## Implementation evidence

The [GitHub Ash domain](../../../marshall/lib/marshall/github.ex) owns browser
attempts, encrypted connection generations, exclusions and request leases. Its
[connection resource](../../../marshall/lib/marshall/github/connection.ex) and
[worker](../../../marshall/lib/marshall/github/worker.ex) implement explicit
progress and ID-only refresh/revocation delivery. The
[restore acknowledgement](../../../marshall/lib/marshall/github/restore_epoch.ex)
fences restored database authority using an external marker; the
[persistence helper](../../../marshall/lib/marshall/github/persistence.ex) retries
only settlement of the same received pair, never the provider exchange. The
[configuration validator](../../../marshall/lib/marshall/operations/git_hub_config.ex)
requires complete settings and a fixed HTTPS callback path; it does not require
the registered callback host to equal the configured Marshall origin.

The [provider transport](../../../marshall/lib/marshall/github/provider.ex)
requests `offline_access`, uses the documented fixed token endpoint and sends
`grant_type=refresh_token` without a new scope request. Token replies must declare
`token_type=bearer`. Its [grant parser](../../../marshall/lib/marshall/github/grant.ex)
requires both tokens
and bounded positive expiry fields; the documented 28,800/15,897,600-second
response fits that contract. Missing refresh credentials are refused rather than
silently becoming a non-expiring connection. Source conformance and controlled
fixtures do not establish the registered app's actual consent, rotating exchange
or organization approval.

The [wire route contract](../../../protocol/lib/overalls_protocol/github.ex),
[Marshall admission](../../../marshall/lib/marshall/galileo/github.ex),
[response rewrite](../../../galileo/lib/galileo/github/response.ex) and
[transfer selectors](../../../galileo/lib/galileo/github/capabilities.ex) implement
the provider-specific path over the retained
[private binding](../../../protocol/lib/overalls_protocol/private_services.ex)
and [single-attempt upstream](../../../galileo/lib/galileo/upstream.ex).
[Managed guest transport](../../../nix/domains/artifacts/guest/github/) and the
[tool manifest](../../../protocol/lib/overalls_protocol/github_tools.ex) add
source delivery contracts. These sources establish implementation presence,
not live provider, native guest or production acceptance. Exact inspected tests,
executed results and remaining gaps are tracked in the
[review](../reviews/2026-10-18-github-com-integration.md) and
[service guide](../../services/github-com.md).

The controlled packaged edge check passed on 2026-10-19 at revision
`97809b51f5187f38d46c0d261c923771a880cddc`. Its managed-client and TLS transfer
results use substituted Marshall/Lilly authority; they do not establish browser
OAuth or fleet acceptance. The review records the exact execution scope, and the
HLDD owner-integration scenario records the remaining security acceptance gaps.
Implementation remains partial.

The common-fleet diagnostic also exposed valid integration AAAA queries returning
NXDOMAIN before any API request. The
[private DNS repair](../../../audi/lib/audi/private/dns.ex) restores authoritative
NOERROR/NODATA with the integration SOA, retaining the fixed A answer and all
name refusals under ADR-0080. It adds no authentication or target authority.
Focused DNS execution and the composed fleet result retain separate scope in
the review; a DNS repair alone does not establish the owner integration journey.

The NixOS fleet journey (2026-10-30) exposed three defects in the managed
client path; each is corrected rather than relaxed. Adding the unpatched
Nixpkgs `gh` to the [guest toolset](../../../nix/domains/artifacts/guest/configuration.nix)
shadowed the managed client in the system profile, so the guest asked for
`gh auth login`; the toolset again carries only the managed client, and the
[guest-toolset evaluation](../../../nix/verification/tests/evaluation/guest-toolset.nix)
refuses any unmanaged `gh`. The guest agent state root was owner-only, so the
public `/usr/local/bin` launcher exited 127 for every ordinary account; the
[NixOS](../../../nix/domains/artifacts/guest/default.nix) and
[foreign Linux](../../../nix/domains/artifacts/guest/ubuntu/agent-executor.service)
executor units now make it traverse-only (0711) while logs and update state
keep their own owner-only directories. The
[integrations page](../../../marshall/lib/marshall_web/live/integrations_live.ex)
closed the excluded-machines panel on every Detach/Attach re-render; it now
keeps the owner's open state. Foreign-image, FreeBSD and illumos launcher
access for non-root accounts remains unexecuted.

Retained native [tool setup](../../../lyra/src/agent/maintenance.rs) also migrates
historical broad workspace Git trust only after validating a completed immutable
source, preserving unrelated settings and configuration rollback. With no source
it preserves existing policy; native upgrade/reboot results remain separate from
the Linux-host maintenance tests. This implements the exact shared-checkout
boundary rather than granting trust to every workspace path.

Native candidate constructors support explicit allocation Git identity version1
only with source-v2 and a native payload. The qualification harness checks
effective personal-user Git configuration and actual commit attribution across
boot epochs. The [review](../reviews/2026-10-18-github-com-integration.md) records
FreeBSD image `0150b6d1` passing all five exact-artifact scenarios with 26 service
checks, then repeating all five against current VMM `f0d9275b`. Structural
verification, signed publication, independent empty-store substitution and
fresh-byte verification passed before its additive source admission and default
selection. Older approved disks retain their exact identities and remain
incompatible with the allocation Git identity gate. OmniOS selection remains
unchanged; the review preserves its separately scoped candidate results and
failures. Publication and source selection do not establish live deployment,
retained-tool acceptance or a Marshall-owned native fleet journey.

The same review identified a retained-restart prerequisite: Lilly repeats exact
admission on retained portable bundles, so selection must not revoke immutable
history. The [registry](../../../protocol/lib/overalls_protocol/native_admission.ex)
now keeps explicit reviewed history independently from selected manifests, and
[retained staging](../../../fleet/staged-guest-images.nix) preserves exact old
promotion packages for original provisioning. Nine focused Protocol checks
passed with the additive FreeBSD identity, old/new portable bundles and refusal
of capability relabelling; selected package/promotion/native-OS Nix targets also
passed. Existing no-snapshot machines retain their capability absence.
This implements the existing immutable-qualification and retained identity
requirements, not an older-format compatibility reader. Native checkpoint
qualification remains unperformed. The historical OmniOS matrix passed growth
but failed the other four targets against VMM `9815649a`; those results and its
earlier direct services retain that exact scope. Current-runtime qualification
cannot be inferred from unchanged disk bytes or version strings.
The unchanged OmniOS candidate later passed current-VMM services, growth,
crash recovery and daemon recovery; isolation failed during boot 0's bounded SSH
shutdown request before the VMM wait. Cleanup completed, but no complete
isolation receipt or new OmniOS publication/admission/selection exists. The
review preserves this result separately from the historical matrix.

## Open questions

No product-policy choice remains for this version. OAuth App provisioning,
registered-app `offline_access` consent and rotation, provider/organization
approval, seven-family runtime and retained-machine upgrade acceptance still
require evidence. The dated primary sources establish documented OAuth App
refresh support, not these operational results.

## Related decisions

- [ADR-0080](0080-named-edge-integrations.md): single-attempt credential injection.
- [ADR-0134](0134-personal-integration-owner-eligibility.md): generic attachments.
- [ADR-0111](0111-private-service-tls-names.md): existing exact TLS names.
- [ADR-0158](0158-durable-guest-identities.md): guest identities/shared sudo.
- [ADR-0157](0157-multi-provider-authenticated-repository-launch.md): inert public source identity remains separate from credentials.
- [ADR-0142](0142-overallsprotocol-control-websocket.md): control transport.
- [ADR-0186](0186-covenant-contract-verification.md): bounded BEAM contracts.
- [ADR-0191](0191-elixir-hegel-property-verification.md): typed property histories.
- [ADR-0194](0194-marshall-http-security-headers.md): fixed-origin OAuth form navigation.
