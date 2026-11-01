# ADR-0167: Native guest coding CLIs configured for Ziggy

- ID: ADR-0167
- Date: 2026-10-13
- Status: superseded
- Implementation: partial
- Components: NixOS guest image, Ubuntu guest image, Ziggy
- Supersedes: none
- Superseded by: ADR-0168

## Context

Fresh NixOS and Ubuntu workspaces need Codex and Claude Code preinstalled and
configured for the private Ziggy inference endpoint. The user approved both
clients, native configuration instead of custom launchers, and Ziggy support for
Anthropic's Messages beta query. Pi and OpenCode were explicitly removed from
scope. The user also authorized merging and deploying the verified change.

The supplied pinned package input contains Codex 0.149.0 and Claude Code 2.1.238.
Ubuntu's default package boundary is its authenticated archive lock, with
explicit exceptions for pinned offline development and editor closures. Neither
the archive boundary nor these exceptions imply permission for network installers
or ambient channels. Production hosts currently enable only OpenAI in Ziggy;
installing Claude cannot itself enable Anthropic.

## Decision

Install both pinned clients in the default NixOS and Ubuntu images. Permit the
unfree Claude package through a predicate restricted to that package. Ubuntu adds
these two applications to its offline Nix development-tools closure, copies and
registers all runtime references, normalizes the Nix registration database and retains a GC
root. This is an additional explicit exception to ADR-0068, preserving its
Ubuntu archive rationale and all other image requirements.

Configure native clients in their system configuration locations:

- Codex selects a Ziggy provider at `https://llm.internal/openai/v1`, uses HTTP
  Responses without OpenAI login or WebSockets, and retains native session,
  approval, sandbox and model-selection behavior.
- Claude uses `/etc/claude-code/managed-settings.json` with
  `ANTHROPIC_BASE_URL=https://llm.internal/anthropic` and a nonsecret authentication
  sentinel required by its client. Provider credentials never enter the image.
- Both use verified trust from `/etc/ssl/certs/ca-certificates.crt`; terminal and
  SSH sessions receive the required certificate environment. Automatic client
  updates are disabled, so image input review governs the bundled versions.

No custom launcher, model-catalog synchronizer or Marshall agent integration is
introduced. Codex system defaults may be overridden by native user/CLI settings;
Claude's managed environment uses native managed-setting precedence. Model
selection remains native and guest root can modify installed files; configuration
does not create inference authority. These are user-run processes with guest-local
state and existing guest permissions.

Ziggy accepts the literal query `beta=true` only for POST `/v1/messages` and
`/v1/messages/count_tokens`, including their `/anthropic`-prefixed forms. Empty
queries remain valid. Other values, duplicate/additional parameters, encoded
aliases, mismatched prefixes and queries on other routes remain refused. The
validated query reaches the upstream URL unchanged; the query-free native path
continues to identify the accounting operation. Bodies and permitted Anthropic
headers remain native, without API translation or request replay.

Production Anthropic selection remains unchanged. Its disabled routes return
`provider_unavailable` before admission or provider effects. Customer private
inference refusals and existing narrowly scoped bootstrap/SSH exceptions remain
unchanged. New image identities affect future provisioning; retained writable
guest disks are not migrated.

## Alternatives

Custom launchers and runtime catalog synchronization were rejected because
native clients already support provider URLs and personal selections. They would
add unnecessary configuration precedence, startup and persistence behavior.
First-boot installers and unpinned upstream downloads were rejected because they
would bypass reproducible offline image assembly. Enabling Anthropic or
translating Claude into OpenAI requests was not authorized by this change and
would alter provider policy or the native protocol boundary.

## Consequences

Images and retained Nix closures grow; manifest minima and derived guest defaults
must absorb the actual increase. Existing user sessions, homes and platform-agent
authority remain separate. Native client model catalogs may differ from Ziggy's
available providers/models. Claude is installed and correctly routed while
production Anthropic remains unavailable until separately enabled with
Ziggy-owned credentials. Test fixture enablement does not establish production
provider readiness.

## Invariants and verification

- Both image evaluations require both clients and their native configuration.
- Ubuntu must retain every runtime dependency through registration and garbage
  collection, and reproduce image bytes from unchanged inputs.
- Native guest checks execute both clients, rather than infer usability from
  package presence. Fleet checks use actual clients through verified private TLS,
  current Marshall admission and isolated provider fixtures in both guest families.
- Route table/property checks pin the exact beta query allowance, preserve native
  bodies and query-free operation accounting, and reject disabled providers
  before effects.
- Wrong trust/hostname and Customer inference are refused. No client setting or
  sentinel creates VM identity or inference authority.
- New dependencies introduce no Ash domain, host service, listener or provider
  credential custody change.

## Implementation evidence

The [shared native package/configuration](../../../nix/domains/artifacts/guest/coding-clis.nix)
pins the reviewed versions, permits only Claude's unfree package and generates
system settings and public certificate environment. The
[NixOS configuration](../../../nix/domains/artifacts/guest/configuration.nix) and
[Ubuntu builder](../../../nix/domains/artifacts/guest/ubuntu/default.nix) own image tools
and offline closure assembly. The
[toolset evaluation](../../../nix/verification/tests/evaluation/guest-toolset.nix) and
[Ubuntu evaluation](../../../nix/verification/tests/evaluation/ubuntu-guest.nix) guard image
contents; the [native guest probe](../../../nix/verification/tests/machines/zfs-guest/probe.exs)
owns actual installed command checks.

[Ziggy route validation](../../../ziggy/lib/ziggy/route.ex) and
[upstream transport](../../../ziggy/lib/ziggy/upstream.ex) own native provider
dispatch. [Route properties](../../../ziggy/test/route_test.exs) guard the exact
query allowance and unchanged native bodies; the
[disabled-provider checks](../../../ziggy/test/provider_selection_test.exs) guard
refusal before authority/spool effects. The actual-client
[fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/coding-clis.py) and
[native account helper](../../../nix/verification/tests/machines/fleet/coding-clis-guest.exs)
cover real packaged client requests without substitute provider configuration.
Both native CLI/GC subtests and both complete integrated coding-client fleets
have recorded passes, including real terminal/SSH inference after GC, limited
trust refusals and Customer no-effects refusal. Fleets use editor-free guest
fixtures with the shared client packages/settings, distinct from the built
production artifact identities. The current explicit plugin-update assertion
passed both native client/GC subtests. The complete packaged NixOS native suite
and current Marshall/static/Nix handbook gates passed at the reviewed `c5747868`
checkpoint. Ubuntu's broad suite subsequently failed at fresh neighbour startup
with a quarantined template after its client, source and host-loss checks passed;
its historical cause remains unknown. The later complete corrected Ubuntu suite
passed, including the final cleanup guard and a limited post-import cache action
that preserves ADR-0130's strict identities. Its exact-reuse branch passed;
device-only fenced replacement remains unexecuted. (Correction 2026-11-01:
ADR-0182 accepts device-only drift, so that branch now asserts reuse of the
unchanged incarnation, and fenced replacement is driven by an mtime change on a
sealed file; both passed on 2026-11-01, see ADR-0130's correction.) Focused current NixOS also
passed exact reuse and original VM 102 cleanup through the current packaged
prefix; its omitted remainder retains only the earlier full-run scope. The
corrected/refrozen packaged handbook browser check passed at its captured source;
`8930a70f` was published and activated healthy on both hosts, with matching fresh
image offers. The first production NixOS Codex canary timed out before any
inference admission; its guest, reservations and placement dataset were cleaned
up, and Ubuntu creation was not issued. Separate pinned WebPKI and constrained
Codex tests expose the legacy leaf's rejected extra SAN; same-root preparation
under ADR-0111 and independently verified encrypted host replacements are
recorded separately from pending commit/push and live replacement. Successful
production canaries remain pending. The
[review](../reviews/2026-10-13-native-guest-coding-clis.md) records
the final source and execution scope. Native acceptance and deployment results
must be recorded before claiming operational completion; package declarations
alone do not establish it.

## Open questions

Production Anthropic enablement and credentials remain a separate operator
decision. Live provider/model acceptance, sustained capacity and physical-host
failure acceptance are not established by isolated fixture execution.

## Related decisions

[ADR-0068](0068-nix-built-ubuntu-guests.md),
[ADR-0094](0094-default-development-environments.md),
[ADR-0153](0153-official-source-browser-editor.md),
[ADR-0158](0158-durable-guest-identities.md),
[ADR-0063](0063-private-services-and-ziggy.md),
[ADR-0099](0099-marshall-owned-agent-threads.md),
[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md),
[ADR-0113](0113-guest-trust-at-boot.md),
[ADR-0149](0149-independent-observability.md).
