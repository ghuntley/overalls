# ADR-0104: Private guest CLI updates

- ID: ADR-0104
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Marshall, Ziggy, Audi, Lyra, NixOS guest, Ubuntu guest
- Supersedes: none
- Superseded by: none

## Context

ADR-0096 installs the Overalls CLI in both guest images, but the guest executor
starts the immutable image copy and bypasses the desktop updater. Updating a
Lilly host does not replace an existing Firecracker disk. The user authorized
private guest artifact delivery, a shared updater, a two-minute check interval,
both guest distributions, property tests, NixOS machine tests and a 100 MiB
artifact limit. Existing VMs will be deleted during development.

## Decision

New NixOS and Ubuntu images include an immutable seed supervisor, private trust,
and one root-owned managed CLI binary. The supervisor seeds the managed copy
without network access, starts the guest executor and checks the private update
manifest at boot and every two minutes with up to thirty seconds of jitter.
Ordinary guest CLI invocations use the same managed copy and do not perform a
network check on every command. `overalls update` triggers an immediate check.

Audi supplies the current pre-NAT VM binding. Ziggy exposes only fixed private
Linux manifest and binary routes, asks Marshall to authorize the current VM
execution and desired SHA-256 digest, and serves its own packaged artifact only
when its bytes and digest match that decision. Customer guests have no eligible
private agent update authority. The public CLI and private guest updater share
bounded fetching, digest validation, locking and staging. Both limit an artifact
to 104,857,600 bytes.

The supervisor requests the executor to stop claiming work and waits for an
active command to finish before atomically switching to a verified staged
binary. A replacement must register with a fresh Marshall fence within ninety
seconds. Otherwise the supervisor restores the previous executable and restarts
it. Marshall retains the executor's reported digest and records content-free
update audit receipts. Registration is an operational readiness signal, not
remote code attestation. This decision does not add semantic rollback for a
binary that registers but later behaves incorrectly.

## Alternatives

Host-only updates cannot modify existing VM disks. Checking on every command
creates unnecessary private requests and still misses an idle executor. A
mutable supervisor could lose its own recovery path during a failed update.

## Consequences

The two guest images and Ziggy package depend on the host's selected Lyra
artifact. Marshall and Ziggy must agree on the digest while a host update is
rolling; a mismatch denies delivery until they converge. Existing VM disks do
not need a migration. The host's automatic updater remains a separate release
mechanism and does not automatically replace running VM disks.

## Invariants and verification

- Only a current Audi-derived VM execution binding may receive a private artifact.
- No binary above 100 MiB or with a mismatched digest may be staged or executed.
- A command in progress finishes before executor replacement; a stale fence cannot commit a result.
- First boot works without artifact service availability, and failed registration restores the prior binary.
- Property tests cover validation and handoff; real Firecracker machine tests cover NixOS and Ubuntu updates and continued tool work.

## Implementation evidence

The [guest updater](../../../lyra/src/update.rs), [private Ziggy route](../../../ziggy/lib/ziggy/http.ex),
[Marshall authorization](../../../marshall/lib/marshall/inference/requests.ex), and
[guest image definitions](../../../nix/domains/artifacts/guest/default.nix) implement the basic path.
Marshall and Ziggy precommit gates, Lyra Rust tests and Clippy, and both
[NixOS and Ubuntu Firecracker fleet checks](../../../nix/verification/tests/machines/fleet/BUCK)
pass. The fleet checks prove periodic replacement of an old image executable,
private delivery, continued tool work and prompt wakeup. Live rollout to newly
created guests remains unobserved.

The [supervisor recovery review](../reviews/2026-09-26-guest-cli-recovery.md)
records a reproduced exec-format failure that bypassed rollback and its narrow
repair. Generated isolated real-supervisor histories cover candidate start/early
exit, active drain and retry; fixed cases include the registration deadline and
startup reconciliation. Their ready receipts are synthetic. The dedicated strict
[guest recovery driver](../../../nix/verification/tests/machines/guest-cli-recovery/driver.py)
passed invalid-format and registration-timeout recovery in a real NixOS guest,
with exact prior inode/digest restoration, fresh Marshall fences and completed
shared-operator tool work. Direct candidate injection bypasses delivery. Ubuntu
failure recovery and real-command drain remain gaps; the prior two-distribution
successful-delivery evidence retains its original scope.

The [update failure matrix review](../reviews/2026-09-26-update-failure-matrix.md)
closes two of those gaps and pins the refusal semantics. The same strict recovery
journey now passes on the Ubuntu image, including invalid-format and
registration-timeout candidates with fresh Marshall fences. A new interrupted-fetch
journey on both distributions drives the real managed worker through the console seam:
a staged digest whose bytes were never durably persisted never activates, and one real
check through the private manifest route reconverges staging with the installed
executable identity and rejection cooldown intact. Lyra's failure marking now has a
generated property proving a failed check (the closed 503 denial class included) only
moves `last_check`, and a fixed post-rollback freeze of the cooldown deadline; the
poisoning mutant is detected. Marshall `authorize_update` refusals (Customer profile,
cross-host, expired or rotated credentials, stale post-relocation bindings and
arbitrary wire shapes) and the wire-level closed-403 mapping through
`MarshallWeb.InferenceAPI` (since ADR-0142, the Ziggy control service's
`unauthorized` error name) are pinned by new tests, and Ziggy serves the packaged
artifact only on Marshall's exact digest and size — authority denial is the guest's
only distinguishable 403, every other denial class is 503. Direct candidate injection
and a published valid release during these journeys are unchanged.

## Open questions

None for this development-only rollout.

## Related decisions

[ADR-0096](0096-lyra-developer-ssh.md) governs the public developer CLI;
[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) governs VM executor
fencing and private transport; [ADR-0038](0038-http01-validation-and-peer-routing.md)
governs host auto updates.
