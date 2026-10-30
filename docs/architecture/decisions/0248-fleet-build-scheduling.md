# ADR-0248: Fleet build scheduling through a tribuchet hub and grpc:// stores

- ID: ADR-0248
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: NixOS, Nix daemon, fleet secret delivery, Panterloons, Dungarees
- Supersedes: ADR-0086
- Superseded by: none

## Context

[ADR-0086](0086-reciprocal-nix-caches.md) made every fleet host build every
derivation locally because reciprocal `ssh-ng` builders forwarded builds between
the peers' daemons and deadlocked concurrent host updates. Panterloons and
Dungarees are now identical 96-CPU hosts (ADR-0246), and one host's update
candidate repeats most of the other's work. The user asked on 2026-10-20 to pin
[tribuchet](https://github.com/Mic92/tribuchet) and
[nix-grpc-store](https://github.com/Mic92/nix-grpc-store), enable them on
Panterloons and Dungarees, and schedule remote builds across the fleet. The user
chose the topology, a private mTLS CA for tribuchet and `grpc://` in place of
the two hosts' ssh-ng peer caches.

Observed constraints: a tribuchet hub serves only the nix-daemon on its own host
through Nix's experimental `external-builders` hook, and a tribuchet worker dials
exactly one hub. nix-grpc-store tunnels the Nix worker protocol over gRPC with
mTLS and CN-to-role access rules; a remote builder client needs the `trusted`
role because it uploads unsigned inputs.

## Decision

Panterloons is the single scheduler. Its nix-daemon hands every `x86_64-linux`
build to a local tribuchet hub, which schedules it onto tribuchet workers on
Panterloons and Dungarees. Panterloons has no `nix.buildMachines`. Dungarees uses
the ordinary build hook with exactly one build machine, Panterloons'
`grpc://` store, so its builds also reach the hub. Nix's direct derivation
protocol does not invoke the receiving daemon's build hook, and tribuchet
workers only import inputs through their nix-daemon and build in their own
sandbox, so no build is forwarded twice and the ADR-0086 cycle cannot form.

Both participants serve their store over `grpc://` and substitute from each
other with `trusted=true` scoped to that pinned endpoint, replacing their ssh-ng
caches for each other. Panterloons grants Dungarees' certificate the `trusted`
role; Dungarees grants Panterloons' certificate `read-only`. Every other CN is
denied. Global signature verification, existing caches and signing keys stay.
Hosts that do not participate keep ADR-0086 unchanged, including ssh-ng caches
to both participants, whose restricted `nix-ssh` service remains.

Hub (7437) and grpc (50051) listeners bind all addresses but are never opened in
the firewall; only the trusted `tailscale0` interface reaches them, and
certificates carry the tailnet IP SANs. Tribuchet and grpc use two separate
private CAs so a grpc certificate can never register as a worker. Public
certificates are committed; private keys are per-host SOPS documents delivered
as a root-only bundle. CA private keys were discarded after issuance: rotation
reissues every certificate. The hub's Nix is the nix-compact package (ADR-0087)
with tribuchet's uid-range and decline-fallback patches appended; a declined
build (no capable worker) builds locally. Its external builder program is a
wrapper that also declines when the hub socket refuses connections, because
tribuchet's shim otherwise fails the build outright.

## Alternatives

nix-grpc-store's own farm (a scheduler role plus an envoy balancer routing each
build to the chosen builder) was rejected: it adds a balancer and its
certificate tier for two hosts, while tribuchet already provides chunked
transfer, deduplication and restart-surviving builds. A hub on every host was
rejected because a worker serves one hub, so each host could only offload to
itself. Tailscale identity for tribuchet was offered and declined in favour of
an mTLS CA independent of tailnet ACLs. Keeping ssh-ng caches between the two
participants was declined in favour of one transport.

## Consequences

Builds on either host spread over 192 CPUs and identical derivations requested
by both hosts build once. Dungarees-originated builds placed on Dungarees' own
worker cross the network twice; chunk caches bound the repeat cost. Panterloons
is a single point of scheduling: while it, its hub or its grpc daemon is down,
Dungarees builds locally and Panterloons builds locally through the decline
fallback. `external-builders` is experimental and the hub host runs a patched
Nix. Tribuchet certificates cannot be revoked. This is a privileged trust pool,
as ADR-0067 already granted `nix-ssh`: a compromised worker or a holder of
Dungarees' grpc key can supply malicious outputs to Panterloons' store.

## Invariants and verification

Exactly one participant runs the hub and it configures no build machines; the
peer has exactly one `grpc://` builder pointing at it; workers on both dial the
same hub; peer caches are grpc and not ssh-ng between participants while
non-participants keep ssh-ng; access rules are exactly trusted/read-only for the
peer CN; signatures stay required; listener ports are never in
`allowedTCPPorts`; invalid registries are rejected. A two-machine test must show
peer builds delegated and spread over both workers, scheduler-local builds
through the hub, reciprocal grpc substitution, refusal of an unmatched CN, of an
unsigned import by the read-only peer and of a worker certificate from another
CA, and local builds with the hub or the scheduler's grpc daemon down.

## Implementation evidence

- [Flake inputs](../../../flake.nix) pin tribuchet `1a1002096f3c` and
  nix-grpc-store `17f4ff97a6fd`, both following the stable NixOS input.
- [Module](../../../nix/domains/system/fleet-builds.nix) and
  [registry](../../../fleet/fleet-builds.nix) (participants, scheduler and hub from the
  [fleet host roster](../../../nix/policy/fleet/hosts.nix)) configure the hub, workers, grpc
  daemons, build machine, caches, credential bundle and assertions;
  [remote-builders](../../../nix/domains/system/remote-builders.nix) gains
  `substitutePeers`.
- [Evaluation check](../../../nix/verification/tests/evaluation/fleet-builds.nix)
  asserts the invariants on the real Panterloons, Dungarees and Overalls
  configurations plus rejected variants.
- [Two-machine check](../../../nix/verification/tests/machines/fleet-builds/default.nix)
  exercises delegation, spreading, substitution, refusals and outages with
  fixture CAs.

Remaining gaps: no native deployment receipt on Panterloons and Dungarees yet;
the machine test uses two VMs on a plain network, not the tailnet.

## Open questions

Whether `external-builders` honours `preferLocalBuild` (ADR-0086's guest image
placement) is unverified; such derivations may run on either worker.
Derivations requiring `nested-kvm` are declined by tribuchet workers and build
locally on Panterloons.

## Related decisions

[ADR-0086](0086-reciprocal-nix-caches.md),
[ADR-0067](0067-reciprocal-nix-builders.md),
[ADR-0087](0087-compact-nix-build-logs.md),
[ADR-0246](0246-panterloons-control-plane-deployment.md),
[ADR-0044](0044-recovery-only-secret-documents.md),
[review](../reviews/2026-10-20-fleet-build-scheduling.md).
