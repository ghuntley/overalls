# ADR-0113: Boot-bound guest platform trust delivery

- ID: ADR-0113
- Date: 2026-09-24
- Status: accepted
- Implementation: partial
- Components: Lilly, NixOS guest, Ubuntu guest, native guests, Brady, shared protocol
- Supersedes: ADR-0109
- Superseded by: none

## Context

The root and intermediate custody in ADR-0109 remain appropriate, but placing
the public platform root in each immutable image prevents a host from replacing
the trust set when a VM is created or relocated. The user authorized automatic
host-to-guest trust delivery on every new boot, with no separate rotation or
quarantine workflow. Existing VMs may be deleted during development.

## Decision

Each Lilly host retains its own explicit list of public platform roots. On
creation, restart or destination adoption, Lilly sends that host's current set
through the locally owned Firecracker vsock before guest networking and SSH
start. The guest accepts only host CID 2 and an exact placement, execution epoch
and boot challenge. It replaces the previous platform set, even when the
destination host carries an older set. Ordinary distribution roots remain.

Lilly records `pending → delivering → installed` in a host-local Ash lifecycle
journal, with `failed → delivering` for at most three attempts on one boot. A
validated guest receipt and durable installed transition precede Marshall's
running observation. Reconciliation of an already running boot may reuse that
boot's durable receipt. A new boot cannot reuse it. A terminal trust failure
fences and stops the VM. Guest networking, private DNS, SSH roster sync, sshd
and the agent executor depend on installation; SSH host keys do not require a
restart because the receipt precedes sshd startup.

The Brady hierarchy and secret custody in ADR-0109 continue: a recovery-only
fleet root key, ten-year host signer certificates, and public root distribution
to fleet hosts. The root certificate's twenty-year lifetime is retained. A
running guest keeps its installed bundle until its next boot; this decision
does not initiate live updates or restart VMs for a CA change.

## Alternatives

Rebuilding every image for each CA change leaves retained disks and relocation
dependent on image timing. A guest REST endpoint requires networking before
trust is installed. A separate quarantine and rotation workflow adds a second
authority path when boot-time replacement suffices for the development fleet.

## Consequences

Host availability and the vsock exchange now gate first guest networking and
the running observation. Host-local public root configuration must be kept
current on every Lilly node. Trust receipts and transitions are durable and
auditable; guest diagnostics expose only fixed events, never certificate bytes.
Existing running VMs keep their old bundle until reboot or replacement.

## Invariants and verification

The [continuing boot review](../reviews/2026-10-03-telemetry-retention-and-diagnostics.md)
records a correction for adoption of an already-running VM at a newer logical
generation. The [boot adoption implementation](../../../lilly/lib/lilly/vm/boot.ex)
and [Driver callers](../../../lilly/lib/lilly/vm/driver.ex) require native ownership;
[generated journal properties](../../../lilly/test/vm/boot_generation_adoption_property_test.exs)
verify only isolated durable metadata histories. Proven confinement permits
same-placement, same-epoch boot journal
generation advancement while preserving its challenge. Trust receipt reuse
remains limited to that unchanged physical boot; current-generation readiness
still requires current intent and a bounded fresh exchange. Metadata properties
and native continued-process readiness passed, along with the full Lilly gate.
The complete native clone matrix passed in 1539.61 seconds. Native foreign/corrupt
boot refusal remains open.

- Only the current confined VM boot and host CID 2 can deliver a bounded public
  certificate set; stale receipts and mismatched digests cannot report running.
- The guest uses the destination host's exact current platform roots plus
  ordinary OS roots, and networking starts only after installation.
- A malformed or unavailable exchange fails closed after bounded retries;
  a successful receipt is durable before running is reported.
- NixOS and Ubuntu machine tests must prove both installation and service
  ordering, including destination adoption with a different CA set.

## Implementation evidence

The [2026-10-02 production review](../reviews/2026-10-02-https-egress-production.md)
records ordinary system-trust HTTPS through Brady on fresh NixOS and Ubuntu
guests and after their stop/start on Overalls. Curl verified the host signer
chain without CA overrides. This one-host evidence leaves terminal retry
exhaustion, trust replacement and independent-host claims under their separately
recorded native scopes; implementation remains partial.

The [Rust vsock receiver](../../../lyra/src/bin/overalls-trustd.rs),
[Lilly sender](../../../lilly/lib/lilly/vm/guest_trust.ex),
[Ash trust lifecycle](../../../lilly/lib/lilly/lifecycle/guest_trust.ex),
[NixOS guest wiring](../../../nix/domains/artifacts/guest/private-services.nix),
[Ubuntu guest wiring](../../../nix/domains/artifacts/guest/ubuntu/default.nix),
and [property tests](../../../lilly/test/lifecycle/guest_trust_test.exs)
implement the initial path. The native Audi NixOS and Ubuntu relocation fleet
machine tests pass boot-time installation, unprivileged bundle reads and SSH
ordering. Both move a retained disk to a host with an extra public root and
back, proving addition and removal in the effective guest bundle. Native
terminal trust failure acceptance remains unverified, so implementation is
partial. The [fixture verification review](../reviews/2026-09-25-fleet-guest-trust-verification.md)
records correction of shared fleet image/prerequisite compatibility and a passing
bounded native NixOS/Ubuntu receipt, completed wrong-boot refusal and retained-data
restart journey on `0cfa6302`, including ADR-0124 certificate-gated readiness.
The [evidence review](../reviews/2026-09-26-guest-trust-evidence.md) records the
lifecycle/digest property executions on current source (two seeds) and a bounded
native receiver-side trust-failure exhaustion to completed refusals on `40c1e73b`,
with an accept-expired mutant caught and restored. The seven legacy feature
matrices were evaluated but not rerun; historical feature results retain their
original scope. Terminal trust-retry exhaustion remains unverified, so this
decision's implementation stays partial.

The [2026-10-29 pin-bump review](../reviews/2026-10-29-emudhra-distrust-backout.md)
records two consecutive passing [fleet-guest-trust](../../../nix/verification/tests/machines/fleet-guest-trust/driver.py)
runs on 2026-10-30. They followed fixture-only corrections: the
[probe](../../../nix/verification/tests/machines/fleet-guest-trust/guest.exs)
now binds the readiness-recorded guest boot UUID to the receipt, and the NixOS
root is derived from the image manifest. The decision and its implementation
status are unchanged.

[ADR-0154](0154-guest-boot-profile.md) adds a delivery-time optimization
without changing this decision. Every boot still delivers and verifies the
host's current set before networking. An Ubuntu image now ships its
private-service roots pre-installed in the receiver's managed layout with the
installed digest marker. The receiver skips `update-ca-certificates` only when
the marker equals the delivered digest, the managed files are byte-equal and in
order, the bundle carries every root and every per-root link resolves. Any other
state withdraws the marker, replaces the set and rebuilds the store with
`update-ca-certificates --fresh`. The
[native boot-profile journey](../../../nix/verification/tests/machines/zfs-guest/boot-profile.py)
covers the identical, added and retired sets on both distributions, checking
bundle membership and Ubuntu CApath verification. The bounded journey does not
replace the fleet relocation acceptance above.

The native FreeBSD/OmniOS implementation under
[ADR-0190](0190-native-kernel-provenance-and-admission.md) uses a separate
recipe-pinned regular vendor snapshot at `/etc/overalls/system-ca.pem`, while
publishing the effective bundle at each OS's standard trust path. A real
FreeBSD second boot exposed the earlier adapter reading its previously managed
destination as the vendor base, which accumulated platform roots and prevented
idempotent replacement. The corrected
[native installer](../../../lyra/src/native_guest.rs) validates current boot
authority before writes, composes only the immutable vendor base plus current
roots, refuses missing bases or conflicting staged bytes, and durably publishes
the managed link. Real-filesystem regressions cover new-boot reinstallation,
root addition/removal/rollback and stale-boot refusal. Full final native
two-boot service acceptance remains pending; this correction preserves the
accepted replacement semantics and does not widen native admission.

## Open questions

None for the authorized boot-time scope.

## Related decisions

[ADR-0069](0069-brady-egress-cache.md) owns Brady interception;
[ADR-0154](0154-guest-boot-profile.md) records the measured boot and
Ubuntu verified-current trust reductions; [ADR-0074](0074-durable-lifecycle-state-machines.md) owns durable lifecycle
audits; [ADR-0110](0110-cedar-guest-ssh-accounts.md) owns SSH roster authority.
