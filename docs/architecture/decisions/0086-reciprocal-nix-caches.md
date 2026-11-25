# ADR-0086: Reciprocal Nix caches without peer build delegation

- ID: ADR-0086
- Date: 2026-09-21
- Status: superseded
- Implementation: partial
- Components: NixOS, fleet access, secret delivery, automatic updates
- Supersedes: ADR-0067
- Superseded by: ADR-0248

## Context

[ADR-0248](0248-fleet-build-scheduling.md) replaces cache-only operation for
Panterloons and Dungarees with a single scheduler and `grpc://` stores
(tribuchet removed by [ADR-0282](0282-remove-tribuchet.md)), and carries this record forward unchanged for every other host. This
record retains its rationale and historical implementation evidence.

Fleet automatic updates failed on every candidate after the reciprocal builder
rollout. Both hosts' updaters build against the same Git branch on the same
short timer. Under that concurrent load, each host's Nix daemon filled its
local build slots with the peer's forwarded derivations, so every new build
request was delegated to the peer daemon, which — running the same reciprocal
configuration — delegated it back. Builds bounced between the daemons without
executing, held store and daemon locks while waiting, and each updater's
bounded command timeout then killed a wedged build and orphaned the surviving
daemon sessions. Dungarees ran its own build helper while its updater was
stopped, and the production attempt log shows dispatches alternating between
`overalls-builder-dungarees` and `overalls-builder-overalls` with no executed
build and near-zero network traffic.

ADR-0067 assumed the direct derivation protocol does not invoke the receiver's
build hook. The evidence disproves that assumption for trusted peer
connections: a receiving daemon applies its own builder configuration,
including its entry for the requesting peer. Bounded acceptance probes and the
two-VM suite passed because they never saturated local slots; the review had
already flagged load under 32 simultaneous all-core builds as unmeasured.
The cache half of ADR-0067 worked throughout: substitution delivered the peer's
realized outputs, including the full guest closure.

## Decision

Keep every ADR-0067 property except remote build delegation. Registered peers
remain inventory-pinned `nix-ssh` endpoints used only as trusted `ssh-ng`
substituters with signature verification, strict host pins, restricted SSH
access and the existing secret custody and rotation lifecycle. The module no
longer configures `nix.buildMachines`, `distributedBuilds` or builder slot
tuning: each host builds every derivation locally on its own 32 logical CPUs
and publishes results to the peer through substitution. Heavy host-shared
derivations such as guest images additionally declare `preferLocalBuild` so
their placement never depends on scheduler races. Host update timers gain a
larger random start delay so identical candidates do not race across the fleet.

The registry keeps measured logical CPU counts, systems and supported features
as authoritative inventory data, but they no longer configure remote slots.

## Alternatives

Removing the caches entirely would force every host to build everything and
re-download shared paths. One-directional builders break the deadlock only by
asymmetry, still forward builds into the serving peer's resource budget and
leave the same cycle available after any role change. Upstream Nix offers no
forwarding-depth or per-client builder control that would make reciprocal
delegation safe.

## Consequences

Both hosts spend local CPU on all builds; concurrent build contention with
services and guests is intentional and bounded by existing budgets. Cross-host
progress no longer depends on remote scheduling, so an update candidate builds
even when the peer is down, mid-update or wedged. Daemon wedges from build
forwarding cannot recur; the updater's process-group timeout cleanup remains as
defense against any other hung child. Substitution traffic continues over the
pinned endpoints with unchanged trust and rotation semantics.

## Invariants and verification

Evaluate cache-only configuration: no build machines, no distributed builds,
self exclusion, additive peer substituters, signature policy, restricted
access, private delivery and rejected invalid inputs. Exercise both peers with
purely local build placement, reciprocal substitution without rebuilding,
wrong pins, prohibited commands and forwarding, secret custody, key rotation
and peer/preparation failures. Run access, secret reconciliation, updater and
governance regressions. Fleet rollout additionally verifies updater health on
both hosts and the absence of peer build dispatch under concurrent updates.

## Implementation evidence

- [Module](../../../nix/domains/system/remote-builders.nix) configures cache trust,
  SSH restrictions and runtime secret dependencies without `buildMachines`.
- [Guest images](../../../nix/domains/artifacts/guest/default.nix) declare
  `preferLocalBuild` for the rootfs and manifest derivations.
- [Evaluation check](../../../nix/verification/tests/evaluation/remote-builders.nix) and
  [two-machine check](../../../nix/verification/tests/machines/remote-builders/default.nix)
  assert cache-only configuration and local build placement with working
  reciprocal substitution.
- [Updater runtime](../../../nix/domains/system/auto-update/runtime.py) signals the
  whole child process group on timeout, and the
  [update timer](../../../nix/domains/system/auto-update/default.nix) desynchronizes
  fleet hosts with a random start delay.

Fleet rollout evidence is tracked in the
[review addendum](../reviews/2026-09-18-remote-builders.md).

## Open questions

None for the accepted design.

## Related decisions

[ADR-0248](0248-fleet-build-scheduling.md),
[ADR-0067](0067-reciprocal-nix-builders.md),
[ADR-0044](0044-recovery-only-secret-documents.md),
[ADR-0041](0041-declarative-fleet-users.md),
[ADR-0036](0036-automatic-host-updates.md),
[ADR-0043](0043-declarative-host-provisioning.md).
