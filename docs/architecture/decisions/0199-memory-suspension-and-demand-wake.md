# ADR-0199: Memory-preserving suspension, relocation and demand wake

- ID: ADR-0199
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Marshall Compute, Agents, Threads, Access, Ingress, Editor, SSH, Lilly, Audi, shared protocol, native guests, NixOS
- Supersedes: ADR-0037, ADR-0047, ADR-0085, ADR-0155, ADR-0159, ADR-0193
- Superseded by: none

## Context

The owner authorized memory-preserving Firecracker suspension, same-boot
relocation, explicit state machines, Hegel properties and real NixOS machine
verification. A newly provisioned thread/Orb machine must suspend after four
hours since its last tool call. This replaces the earlier two-hour and
human-prompt formulations in the task. Prompts and permitted network use wake
the machine. The owner additionally selected an immediate wake on owner pin,
four hours of wake grace after network access, and durable waiting when the
compatible fleet has no room.

Firecracker's Paused API alone retains host RAM. Its full snapshot API captures
memory/device state; a fresh unconfigured VMM loads that state. Snapshot load
changes physical placement without rewriting the guest's immutable boot identity.
Vsock resets connected sockets, so guest drivers must preserve listeners across
a validated transport reset while continuing to fail closed on invalid events.

## Decision

This decision replaces only the inherited memory-migration prohibition,
stopped-source/reboot requirement and cross-host application-relay prohibition.
It extends the owner pin's consequences with automatic-suspension prevention
and wake. All unrelated isolation, execution fencing, capacity, cleanup,
authorization and convergence requirements of the superseded records continue.
Full transfer while paused is sufficient; pre-copy is not introduced.

Compute owns durable suspension policy and a coalesced WakeRequest. New
thread-created machines opt in; existing machines do not change automatically.
Database time and a serialized revision record tool admission/completion.
Provisioning and successful wake initialize a four-hour idle window. A running
machine's human prompt or background health traffic does not refresh the tool
clock. Active admitted tools/turns defer capture. Only the owner's pin prevents
automatic suspension; a personal pin never creates access authority.

Keep intent, physical observation, workflow phase and cleanup authority distinct.
Pause reserves storage before freezing, drains/synchronizes backing I/O, captures
one coherent disk/RAM state, durably publishes ownership, then proves VMM/cgroup
emptiness before releasing compute. Resume loads into a fresh API-only VMM,
validates continuation and destination networking, then resumes and verifies
same-boot readiness. Never substitute a cold boot for memory restoration.

Use two private checkpoint leaf datasets beside the ordinary VM disk dataset.
Prebind both slots before every VMM launch because a running VMM's mount
namespace cannot see subsequent host mounts. Capture into the other slot while
the mapped slot stays sealed read-only. Memory/state/manifests do not enter
ordinary disk clone/backup streams. Consumption and ownership journals live
outside transferred storage. Reserve capture headroom for both slots when
needed, and retire mapped storage only after confirmed absence and reclamation.
Checkpoint physical credit is separately verified and capped; unknown artifacts
consume free space without granting credit.

Continuation binds immutable guest boot identity to current placement, epoch,
generation and validated disk/checkpoint provenance. Compare conservative CPU,
microcode, kernel/KVM, exact patched VMM and device identities before source
interruption. A restore claim must become durable before possible execution;
after ambiguous execution never replay an older checkpoint against modified
disks. On recovery, continue only an independently verified current running VMM or
resume the same proven paused VMM under its durable restore claim, exact launch
identity and unchanged PID/start time. Never reload RAM into an ambiguous process.

Wake reserves fresh local capacity first. Otherwise relocate the paused disk
and checkpoint together to a compatible destination, atomically hand off current
authority, restore, verify readiness, and reclaim the old copy. No compatible
capacity leaves wake durably pending without destroying its checkpoint or
exhausting retries. Stop/delete supersede wake under lifecycle locks. Before
handoff, cancellation resumes an originally running source; an originally
paused source remains paused. After handoff, the old source cannot execute.

Discovery retains suspended routes and SSH key information but grants no guest
execution. Current user/endpoint authorization precedes wake. Authorized new
SSH, HTTP and editor connections wait with bounded buffering and renewed
authority through capacity waits and relocation; DNS/health/renewal probes do
not wake. Existing connections may reconnect after relocation.

Use at most one Audi-to-Audi relay hop over explicitly keyed fleet WireGuard
peers. Bind a short-lived single-use capability to both gateway identities,
service generations, exact current execution, permitted service and original
authorized identity. The destination consumes it through Marshall before
opening its ordinary local Lilly connector. No caller-selected host/port,
relay chains, guest-subnet routing or request replay after forwarding bytes.
Browser authorization survives relocation while preserving issuer revocation,
current login/policy and endpoint/account scope.

## Alternatives

- Paused vCPUs alone retain RAM and cannot free compute for other workloads.
- Stop/start relocation discards memory and contradicts the requested behavior.
- Live pre-copy adds complexity without being required for accepted downtime.
- RAM in the VM disk dataset leaks through ordinary clones and backup streams.
- A single mutable checkpoint dataset weakens mapped-memory immutability.
- Immediate capacity errors or gateway redirects lose the original waiting
  connection and fail the accepted seamless-wake requirement.

## Consequences

Suspended machines retain disk/checkpoint capacity. Repeated capture may need two
full RAM images. Cross-host wake adds an authenticated transport boundary and
requires compatible enrolled hosts. Guest/image qualification is exact; retained
incompatible images must refuse memory operations rather than reboot or upgrade.
Ordered converged rollout remains required by ADR-0159; no retired-version shim
or permanent legacy decoder is introduced. Inception remains out of scope.

## Invariants and verification

Hegel must explore lifecycle/idle/pin races, wake coalescing, reservations,
stale commands, single-use restore, cancellation, handoff and relay authorization.
Real NixOS/KVM tests must prove RAM-only nonce, PID and boot UUID continuity;
empty cgroup/released RAM; repeated captures and restarts; corrupt/missing and
incompatible refusal; local-full relocation with the original connection
waiting; and full-fleet waiting followed by capacity recovery. Neither BEAM
contracts nor a disk marker establishes memory or physical isolation evidence.

## Implementation evidence

The implementation includes the [Compute idle policy](../../../marshall/lib/marshall/compute/idle.ex),
[durable wake coordinator](../../../marshall/lib/marshall/compute/wake.ex),
[Lilly checkpoint custody](../../../lilly/lib/lilly/vm/checkpoint.ex),
[authenticated ingress relay](../../../marshall/lib/marshall/ingress/relays.ex)
and [NixOS fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/suspension.py).
Machine and consumer verification are in progress. The
[implementation review](../reviews/2026-10-18-memory-suspension.md) records exact
source/test evidence and remaining acceptance gaps. This accepted decision is
not a claim of completed implementation or deployment.

Lilly's [trusted driver configuration](../../../lilly/lib/lilly/vm/config.ex)
defaults exact checkpoint image qualification to an empty list. The
[admission predicate](../../../protocol/lib/overalls_protocol/native_admission.ex)
requires that exact content-addressed identity for both pause and resume;
Linux kernel shape alone does not qualify an image. The native fixture's explicit
candidate ID is separate from recorded production artifact qualification.
The authenticated host inventory carries that qualification independently of
physical checkpoint compatibility. Marshall checks it for pause, restored
capacity, memory relocation selection and the final destination handoff fence.

[ADR-0266](0266-anonymous-restored-guest-memory.md) records that restored RAM is
an anonymous copy of the checkpoint memory file, not a file mapping, so a restored
guest is charged once within its accounted memory and can be checkpointed again.
The mapped-slot custody rules above are unchanged.

## Open questions

None. Exact-image and physical-fleet qualification remain verification work.

## Related decisions

- [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
- [ADR-0033](0033-nixos-machine-verification.md)
- [ADR-0037](0037-workload-placement-and-relocation.md)
- [ADR-0047](0047-audi-ingress-and-authoritative-dns.md)
- [ADR-0085](0085-inception-public-ingress.md)
- [ADR-0155](0155-stopped-only-relocation.md)
- [ADR-0159](0159-remove-legacy-compatibility.md)
- [ADR-0182](0182-unprivileged-lilly-beam.md)
- [ADR-0183](0183-guest-dataset-streams-in-hostd.md)
- [ADR-0193](0193-per-user-machine-pins.md)
- [ADR-0266](0266-anonymous-restored-guest-memory.md)
