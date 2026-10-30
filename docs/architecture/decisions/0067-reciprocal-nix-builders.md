# ADR-0067: Reciprocal Nix builders and authenticated SSH caches

- ID: ADR-0067
- Date: 2026-09-18
- Status: superseded
- Implementation: implemented
- Components: NixOS, fleet access, secret delivery, automatic updates
- Supersedes: ADR-0044
- Superseded by: ADR-0086

## Context

The approved implementation plan requests reciprocal local/remote builds and
caches on Dungarees and Overalls. Both have 32 logical CPUs, measured through
inventory-pinned administrative SSH; guest budgets do not establish CPU counts.
Overalls serves administrative SSH on 2222 and Porsche on 22. The local bare
`overalls` known-host entry differs from inventory; authenticated port-2222
access confirms the inventory key. Dungarees administrative SSH/sudo also works.

## Decision

Carry forward every ADR-0044 policy, including its inherited secret custody,
recovery recipients, persistent host identities and authoritative human access.
Add one opt-in machine account exception to the SSH allowlist: `nix-ssh`, with
only peer client keys, forced `nix-daemon --stdio`, no shell commands, PTYs,
forwarding or user RC execution. Nix trusts this account to build arbitrary
input-addressed derivations. This is a privileged build trust relationship;
SSH command restrictions do not turn trusted Nix access into an untrusted sandbox.
A compromised participant can supply malicious store outputs to its peer.

A shared registry declares endpoints, systems, measured logical CPU counts,
features, client public keys, inventory-derived host pins and encrypted documents.
Each host excludes itself. Use `ssh-ng`, CPU-sized remote derivation slots,
local `max-jobs = auto`, `cores = 0`, and at least CPU-sized build-user pools.
Concurrent builds may each use all cores; resource contention is intentional.

Append SSH peer substituters and scope `trusted=true` to those pinned endpoints.
Keep existing caches, trusted signing keys and global signature verification.
No separate cache-signing secret is needed. Strict host checking, dedicated
aliases, no SSH agent and bounded connection attempts bind endpoint identity.
Remote build requests use Nix's direct derivation protocol, which does not invoke
the receiver's build hook. Remote input substitution is disabled to avoid cycles.

Generate distinct client keys in private temporary storage. Inventory documents
select exactly the owning host and all configured recovery users. SecretSpec
project `overalls-remote-builders`, profile `production`, supplies `SSH_PRIVATE_KEY`
as a root-only runtime bundle. Nix wants preparation but does not require it;
missing keys or peers must preserve local builds. PartOf identifies Nix as an
updater consumer. Preparation/rotation participates in existing candidate staging,
publication and health checks. Existing Nix connections may outlive daemon
restarts; retiring keys rejects new authentication, not already-open sessions.

## Alternatives

Root SSH broadens command authority. Disabling signatures globally trusts every
cache. Separate HTTP caches require extra services and signing-key custody.
A shared client key prevents independent rotation. Remote-only scheduling loses
local progress during outages. Guest CPU budgets can diverge from physical CPUs.

## Consequences

Both hosts become mutually trusted build producers without changing application
placement, VM capacity reservations or storage identities. Builds compete with
services and guests for CPU and memory. Peer outage can delay a cache query until
its bounded SSH timeout, after which local builds remain available. In-flight
build failures are surfaced; this does not promise transparent retry of every
failed remote derivation. Runtime key rotation uses public-key overlap followed
by old-key retirement after both peers accept the new configuration.

## Invariants and verification

Evaluate self exclusion, reciprocal scheduling, additive caches, signature policy,
CPU settings, restricted access, private delivery and rejected invalid inputs.
Exercise both initiators with overlapping local/remote execution, reciprocal
substitution without rebuilding, no recursive forwarding, wrong pins, prohibited
commands/forwarding, secret custody, key rotation and peer/preparation failures.
Run access, secret reconciliation, updater and governance regressions. Physical
rollout additionally verifies authenticated identity, effective CPU settings,
remote store connectivity, reciprocal substitution and updater health.

## Implementation evidence

- [Module](../../../nix/domains/system/remote-builders.nix) implements opt-in scheduling,
  SSH restrictions, scoped cache trust and runtime secret dependencies.
- [Access policy](../../../nix/domains/system/access.nix) admits the account only when
  the remote-builder module is enabled.
- [Fleet registry](../../../fleet/remote-builders.nix) derives pins and document
  paths from authoritative inventory, and tailnet addresses, the administrative
  SSH port and measured CPU counts from the [fleet host roster](../../../nix/policy/fleet/hosts.nix) and
  [port roster](../../../nix/policy/fleet/ports.nix).
- [Evaluation check](../../../nix/verification/tests/evaluation/remote-builders.nix) and
  [two-machine check](../../../nix/verification/tests/machines/remote-builders/default.nix)
  cover configuration and actual Nix/SSH behavior separately.
- [Operator guide](../../operations/remote-builders.md) documents recovery and rotation.

Execution and rollout evidence is tracked in the
[review](../reviews/2026-09-18-remote-builders.md). Configuration, two-machine failure/rotation checks, governance gates and bounded
physical reciprocal build/substitution acceptance passed. Production maximum-load
availability is not claimed.

Superseded by [ADR-0086](0086-reciprocal-nix-caches.md): under concurrent fleet
updates the remote build delegation this decision accepted forwards builds
between the peers' daemons without executing them. Its cache provisions carry
forward unchanged.

## Open questions

None for the accepted design. Verification and deployment are tracked separately.

## Related decisions

[ADR-0044](0044-recovery-only-secret-documents.md),
[ADR-0041](0041-declarative-fleet-users.md),
[ADR-0036](0036-automatic-host-updates.md),
[ADR-0043](0043-declarative-host-provisioning.md).
