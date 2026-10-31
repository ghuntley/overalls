# ADR-0033: NixOS machine verification

- ID: ADR-0033
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: NixOS tests, Marshall, Lilly, Firecracker, ZFS, deployment acceptance
- Supersedes: none
- Superseded by: ADR-0043

## Context

[ADR-0043](0043-declarative-host-provisioning.md) replaces generic host deployment
and inventory boundaries while carrying forward the other decisions below.
This record preserves the historical rationale and evidence.

The user explicitly requires NixOS machine tests using the NixOS VM Testing
Framework. Existing Elixir/property tests, direct KVM scripts and three-process
deployment harnesses provide useful evidence with stated limits. They do not
boot the proposed NixOS service modules or validate host installation. The
reference host's existing disko mirrored-boot test must be retained in the new
repository-owned suite.

## Decision

Implement repository tests under `nix/verification/tests/` with `pkgs.testers.runNixOSTest` and
named QEMU machine nodes. Import the actual service modules and source-built
packages; do not substitute fake Marshall/Lilly daemons or fake Firecracker for
execution acceptance. Export individual `checks.x86_64-linux` derivations through
the flake, runnable independently and as the complete required suite. Keep the
framework's Python lint/type checks enabled and use bounded readiness waits.

Reduce resource budgets and disk sizes for functional tests without disabling
credential checks, TLS verification, confinement, accounting or other production
invariants. Supply local PostgreSQL, DNS, ACME, Route 53 API and egress fixtures.
After dependencies are fetched, machine tests must not depend on live AWS,
Let's Encrypt, public Internet services or production credentials. Fixtures
establish integration behavior, not AWS-provider availability or acceptance.

### Required suites

| Suite | Required scenarios |
| --- | --- |
| Configuration and roles | Neither service, Marshall only, Lilly only and both; reject invalid options, overlapping ports and insufficient budgets; boot roles and inspect service ordering, privileges, credentials, cgroups, firewall and readiness. |
| Marshall coordination | At least three distinct Marshall machines, with HAProxy and a separate PostgreSQL fixture; authenticated shared state, concurrent capacity admission, node death/reboot, network interruption, database outage/recovery and stale-capacity rejection. |
| Secret custody | Actual SecretSpec/SOPS with synthetic runtime host/operator keys; wrong-recipient and missing-value failures, private runtime delivery, recovery, rotation, persistent host identity and no fixture plaintext in images or diagnostics. |
| TLS and certificates | Public termination, verified backend TLS/name rejection, readiness, WebSockets, local ACME HTTP/DNS issuance, three-frontend challenge routing, renewal/reload and failed-renewal handling using test-only provider endpoints. |
| Sparse ZFS | Real virtual disks and ZFS datasets; LZ4 inheritance, absent reservations, sparse allocation, quota/headroom, compressible/incompressible writes, logical-cap races, asynchronous accounting/reclamation and pressure. |
| Storage recovery | Interrupted materialization/deletion, ownership/property conflicts, missing-ready-disk rejection, stopped-VM retention and reboot reconciliation; compare acknowledged flushed guest data after abrupt simulated host loss. |
| Firecracker lifecycle and terminal | Two distinct Lilly machines running real nested guests; provision/start/stop, CPU/memory/disk reports, actual terminal read/write, sharing/revocation, daemon death/restart and independent VMM survival. |
| Network isolation | Customer, Standard and OSS profiles; controlled outbound reachability and denied same-host/cross-host guest communication; source spoofing, IPv6 and protected-infrastructure denial. |
| Installation and boot | Boot installer and installed QEMU images through UEFI, confirm mirrored root and both EFI loaders, then boot separately from each surviving disk and verify degraded-pool recovery and SSH. |

The profile allocation ranges remain `10.10.0.0/16`, `10.20.0.0/16` and
`10.30.0.0/16`; a profile does not permit lateral communication. Tests must
exercise actual routed isolation, not only compare generated firewall text.
Installation tests must use firmware and installed bootloaders: the framework's
ordinary direct-kernel boot cannot establish EFI or mirrored-boot correctness.

### Runner and evidence requirements

Linux QEMU tests require KVM and the standard NixOS-test builder capability.
Nested Firecracker tests additionally declare a `nested-kvm` required builder
feature. Configure host nested virtualization and expose the necessary CPU
features to Lilly test machines; verify usable `/dev/kvm` inside them before
starting a guest. Advertising a builder feature is not evidence it works.

An incapable builder leaves those required checks unmet. Do not silently skip
them, replace execution with mocks or report the deployment milestone complete.
Document builder requirements and resource/time limits, retain useful bounded
failure logs, and provide the framework's interactive driver for diagnosis.
Functional machine checks are required for deployment completion alongside the
existing project gates, not a replacement for property tests or Dialyzer.

Two Lilly QEMU nodes prove behavior across simulated machines sharing one physical
failure domain. Three Marshall nodes do not prove 100-instance throughput. Keep
independent physical-host resilience, live provider validation, representative
fleet/terminal load, and physical performance measurements as separate evidence.
Use the benchmark proposal in [ADR-0034](0034-mixed-workload-storage-tuning.md)
without presenting virtual test timings as optimal production tuning.

## Alternatives

Module evaluation catches configuration errors but cannot prove service startup
or runtime isolation. Existing ad hoc host scripts do not reproduce whole-machine
boot/dependency behavior. Containers do not exercise the selected QEMU/UEFI/ZFS
and nested-KVM boundaries. Live cloud dependencies would make routine tests
credential-dependent and less reproducible.

## Consequences

Tests need a capable dedicated builder and more resources than unit tests.
Synthetic external-service fixtures need maintenance as pinned clients change.
Bootloader and nested-KVM tests require different setup from ordinary service
nodes. Deterministic checks must preserve failure artifacts without logging
secrets or user terminal content.

## Invariants and verification

- Every required suite is exported and runs the matching module/package revision.
- A deliberate bad TLS certificate, stale report, over-budget request, missing
  nested KVM device or isolation regression causes a failure, not a skip.
- Reboot tests retain disks; abrupt-loss tests distinguish guest fsync from
  unflushed writes and must invalidate the relevant host caches in the simulation.
- Failures and completed runs are recorded separately from tests merely defined.
- Required compiler, property, contract and Dialyzer gates remain in place.

## Implementation evidence

The shared [fleet host profile](../../../nix/platform/hosts/profile.nix) loads both
supported KVM vendor modules, enables their nested-virtualization options and
advertises the `nested-kvm` Nix system feature. The
[storage](../../../nix/verification/tests/evaluation/storage-configuration.nix) and
[enrollment](../../../nix/verification/tests/evaluation/enrollment-configuration.nix)
evaluation checks cover base and enrolled hosts, while the
[remote-builder check](../../../nix/verification/tests/evaluation/remote-builders.nix)
covers both Overalls and Dungarees declarations. This makes native nested suites
schedulable throughout the managed fleets. It does not replace each suite's
runtime `/dev/kvm` verification or prove that an arbitrary non-fleet builder
supports nesting. The
[Inception completion audit](../reviews/2026-09-22-inception-completion-audit.md)
records the change and its evaluation evidence.

[ADR-0041](0041-declarative-fleet-users.md) adds the named fleet
[SSH suite](../../../nix/verification/tests/machines/access/default.nix),
[access evaluation](../../../nix/verification/tests/evaluation/access.nix) and
[actual SOPS reconciliation tests](../../../nix/verification/tests/evaluation/secrets_test.py).
The [fleet-user review](../reviews/2026-09-17-fleet-users.md) records verification
and the separate boundaries of public-key fixture injection, registry evaluation
and actual operator deployment.

[ADR-0040](0040-host-local-smtp-relay.md) adds a separate SMTP bundle consumer
and [relay machine suite](../../../nix/verification/tests/machines/smtp-relay/default.nix).
Its [review](../reviews/2026-09-17-smtp-relay.md) tracks verification; existing
secret custody and machine acceptance boundaries remain unchanged.

[ADR-0039](0039-opt-in-host-tcp-profile.md) adds the standalone
[sysctl machine suite](../../../nix/verification/tests/machines/sysctl/default.nix) for BBR/fq,
inherited policy, connected TCP sockets and reboot persistence. Its execution
evidence is tracked in the [host TCP review](../reviews/2026-09-17-host-tcp-profile.md).

[ADR-0038](0038-http01-validation-and-peer-routing.md) adds an
[HTTP-01 suite](../../../nix/verification/tests/machines/acme-http01/default.nix) with three
actual frontends and a separate local CA/DNS validator. Local configuration and
[lookup tests](../../../nix/verification/tests/evaluation/acme-lookup.py), the HTTP machine suite,
Route 53 regression and service-role regression pass. Execution results and
limits are recorded in the [review](../reviews/2026-09-17-http01-validation.md).
The existing Route 53 suite remains required.

The [test catalog](../../../nix/verification/tests/README.md) maps the fifteen stable flake
checks to evaluation, release and per-machine-suite directories. Fleet scenarios
are composed in explicit order before framework lint/type checking; shared
support retains the suites' authentication, TLS and resource boundaries. The
[refactor review](../reviews/2026-09-16-nix-layout-and-test-refactor.md) records
inventory comparisons and execution results without replacing earlier evidence.

The [flake](../../../flake.nix) exports
[configuration checks](../../../nix/verification/tests/evaluation/module-configuration.nix) and the
[NixOS role suite](../../../nix/verification/tests/machines/service-roles/default.nix), using actual source-built
releases and runtime-generated synthetic credentials. The role suite covers
neither service, Marshall only, Lilly only and both. It requires hardware
acceleration and the `nested-kvm` feature because Lilly validates inner KVM at
startup. Framework type and lint checks stay enabled. The suite passed with
hardware acceleration enforced, including actual inner-KVM startup checks;
it does not provision guests or establish shared database coordination across
three Marshall machines. The [implementation review](../reviews/2026-09-16-nixos-releases-and-roles.md)
records failures and fixes separately from the successful run.

The expanded combined role runs three colocated Marshall instances with Lilly
and HAProxy. Its 104.32-second run passed distinct database identities, effective
CPU/memory limits, unchanged Marshall PIDs across Lilly restart, and unchanged
Lilly PID across control-plane stops. The proxy stays ready with one backend,
returns unavailable with none and recovers when they restart. The suite also
exercises the HAProxy TLS bridge, wrong-name rejection and sanitized request
logs. The [completion audit](../reviews/2026-09-16-plan-completion-audit.md)
records the exact derivation and remaining physical-host acceptance. The
[secret custody suite](../../../nix/verification/tests/machines/secret-custody/default.nix) adds two machines with
actual SecretSpec/SOPS resolution, distinct SSH identities and synthetic operator
recovery. The current suite passed wrong-host and missing-value startup rejection,
real Marshall credential delivery, group isolation, environment properties,
interrupted publication, application credential rotation and journal checks.
Switching to a second NixOS generation preserved the SSH identity and subsequent
decryption. The expanded suite also passed staged host-recipient rotation,
old-recipient rejection and operator recovery onto a separately keyed replacement
through the actual preparation module. The
[rotation review](../reviews/2026-09-16-secret-host-rotation.md) records the
135.90-second full run and distinguishes ciphertext custody from coordinated
application-credential rotation. Reusable-image/reboot behavior has separate
passing evidence below.

The separate [credential-rotation suite](../../../nix/verification/tests/machines/credential-rotation/default.nix)
passed in 249.75 seconds with three actual Marshall machines and shared PostgreSQL.
It verifies staged/promoted Cloak keyrings through live HTTPS credential checks,
coordinated database/signing/cookie cutover, old password/token/cookie rejection,
fresh logins, retained ciphertext and fail-closed removal of a still-needed key.
The [rotation review](../reviews/2026-09-16-fleet-credential-rotation.md) records
its planned interruption and distinguishes HTTP authentication from browser
sign-in/terminal continuity.

The [ACME suite](../../../nix/verification/tests/machines/acme-route53/default.nix) adds actual Lego and Pebble, DNS
challenge records and a Route 53 API fixture verifying signed requests. It uses
real Marshall/HAProxy and generated encrypted AWS credentials. Scenarios cover
issuance, renewal, provider failure, WebSocket transport survival, reload retry,
invalid replacement material and cached-certificate startup. The complete current
suite passed, as did the shared role and secret-custody regression suites. The
[ACME review](../reviews/2026-09-16-acme-publication.md) distinguishes completed
runs from test failures and records shared role/custody regression results.
This is not real AWS/CA or physical crash acceptance.

The [native ZFS suite](../../../nix/verification/tests/machines/native-zfs/default.nix) runs Lilly's source-built reader
in a KVM-accelerated NixOS machine with OpenZFS 2.4.4 and two virtual mirror
members. It exercises mount/GUID identity, sparse files, LZ4, separate logical
and physical usage, quota pressure, unsafe properties, unexpected snapshot/
bookmark/clone/descendant rejection, degraded backing, large property responses,
observed reclamation and replaced-dataset fencing. The
[observation review](../reviews/2026-09-16-native-zfs-observations.md) records
executed runs. Dataset creation/deletion in that reader fixture uses ZFS utilities.
The separate [owned lifecycle driver](../../../nix/verification/tests/machines/zfs-lifecycle/driver.py) calls
actual Lilly disk APIs with verified guest artifacts, including interruption
after real create/copy/destroy mutations and ownership/GUID/mount conflicts.
The [guest suite](../../../nix/verification/tests/machines/zfs-guest/default.nix) adds actual nested Firecracker,
physical confinement checks, console persistence, stopped disk retention,
cleanup and simulated host loss. The
[lifecycle review](../reviews/2026-09-16-owned-zfs-lifecycle.md) records which
checks have completed. Neither suite establishes independent physical power
loss, fleet coordination or production acceptance.

The [native I/O suite](../../../nix/verification/tests/machines/zfs-io/default.nix) runs the source-built
collector on two real ZFS pools. It generates read/write traffic outside Lilly's
dataset, checks pool-scoped rates separately from dataset quota/availability,
and injects malformed output, timeout and a real export/import between identity
checks. These cases must preserve valid capacity while withholding uncertain
rates, then recover on a clean sample. The
[I/O review](../reviews/2026-09-16-native-zfs-io.md) records executed checks.
Virtual-disk traffic is functional evidence, not physical IOPS calibration.
The [2026-10-13 prerequisite review](../reviews/2026-10-13-antithesis-prerequisites.md)
records a fresh source-built `zfs-io` machine pass after a fixture-only protocol
round-trip repair. It keeps independent pool I/O observations outside the
capacity report and records the earlier failed attempt separately. Galileo and
Enrico release payload checks also pass; two expanded service-role attempts
failed, first at a shell cookie pipeline and then during Lilly startup after
Marshall cookie checks. The underlying Lilly failure remains under investigation.
These results do not establish a
current hosted Antithesis harness, physical storage performance or deployed
service health.
The [new harness foundation](../reviews/2026-10-13-antithesis-harness-foundation.md)
adds optional source-built release/container contexts, a control-only Compose
graph and separate TCG guest/storage-router definitions. Four selected context
exports passed at their captured derivations. The separate
[local guest boot record](../../../antithesis/verification/guest-boot.md) captures
three ready QEMU TCG boots of a q35-adapted production NixOS guest, including a
restart on one retained qcow2 overlay and matching offline machine-id bytes.
This software-emulated result and static roster/component checks do not replace
this ADR's KVM NixOS machine evidence. No composed Lilly guest-executor run, native
Firecracker/KVM/ZFS effect, complete local control-core startup or hosted
baseline is recorded; the inherited verification requirement and partial
implementation status remain unchanged.
The [storage-router TCG record](../../../antithesis/verification/storage-boot.md)
also passed a direct local Linux/ZFS/Brady smoke with retained GUIDs and marker
after QMP reset. It establishes guest/process-crash recovery in that software
emulator, not physical power-loss durability, native Firecracker/KVM behavior or
hosted container execution.
The separate [integrated-host boot record](../../../antithesis/verification/integrated-host-boot.json)
captures an actual TCG NixOS Lilly-host boot and real ZFS/cgroup measurement at
its third exact image; two prior attempts published unavailable health. It has
no authenticated Control or admitted nested guest and cannot replace native
KVM/Firecracker acceptance.
The fourth private-service image in the same record also built and booted,
with real ZFS/cgroup sampling and runtime PKI preparation. Both passing host
samples remain disconnected and execution-unready; no nested guest or
authenticated Control result was recorded.

The [firmware installation suite](../../../nix/verification/tests/machines/mirrored-installation/default.nix) uses
actual installer/target module variants with test-console instrumentation. It
attaches no direct kernel or shared host store, boots OVMF, installs to two blank
QCOW2 disks, verifies mirrored EFI artifacts and boots both the complete mirror
and independent surviving-disk branches. Each branch must retain data and SSH
identity, allow key authentication and report degraded ZFS. The complete suite
passed, including unconditional installed-store verification and effective SSH
authentication policy on the installer, healthy mirror and both survivors. The
[installation review](../reviews/2026-09-16-mirrored-installation.md) distinguishes
executed results from definitions and image builds. The existing reference host's
external boot test has not been located or ported.

The separate exported-image suite (`nix/verification/tests/machines/bootstrap-images/default.nix` at overalls revision `16e8dbe4`, repository deleted)
boots the unmodified public QCOW2 artifacts through OVMF using disposable
overlays. It injects neither credentials nor a test-console service, and reads
the SSH public identity externally. Fresh copies must generate different keys;
reboot and both surviving-disk branches must preserve the first copy's key.
This exercises disko's image builder independently of the installer. It does
not authenticate as the operator or inspect storage inside the guest; the
installation suite covers those behaviors with isolated test credentials.
The complete exported-image check passed after the image builder gained a clean
root-pool export before shutdown. Execution results and the corrected import
failure are recorded in the installation review.

The [fleet suite](../../../nix/verification/tests/machines/fleet/default.nix) boots the minimum distinct
Marshall/Lilly topology with separate PostgreSQL and proxy machines, native ZFS
disks and authenticated provisioner reports. The complete current-source immutable
run passed in **1108.23 seconds**: real browser/terminal/sharing/revocation,
six-guest admission, packet isolation, machine/database outage recovery, daemon
survival, retained stop/start storage, independent deletion and stale-capacity
rejection/recovery. Its deterministic machine-loss case also verified termination
of an abandoned transaction and all recorded lost-node connections within the
20/35-second deadlines. The [review](../reviews/2026-09-16-nixos-fleet.md) records
fixture-selected resource UUIDs, source/package boundaries and prior failures.

The native lifecycle suite passed guarded recovery after actual unmount
interruption, including refusal of an unmounted replacement with copied ownership
tags. The focused two-guest launcher regression also passed, including continued
survivor disk access and distinct-value simulated host-loss recovery. The exact
existing reference-host configuration and external mirrored-boot test remain
unavailable. External provider/physical-host acceptance retains its stated gaps.
All fifteen exported check derivations have successful outputs for the final
source/package revisions. The existing
[NixOS deployment checks](../../../nix/verification/tests/README.md),
[execution smoke](../../../marshall/scripts/smoke_execution.exs),
[jailed KVM smoke](../../../lilly/scripts/smoke_jailed.exs) and
[terminal failover harness](../../../nix/verification/tests/README.md) provide
historical evidence with their own boundaries. The
[guest configuration](../../../nix/domains/artifacts/guest/configuration.nix) alone is not a host
integration test. No physical storage benchmarks have run.

The [standalone browser gate review](../reviews/2026-09-25-browser-type-gates.md)
records an explicit gap in composed-driver typing: separately invoked Playwright
helpers are outside that script and repository type-check discovery. Teams,
Control room, handbook and default OSS now execute artifacts that pass pinned
`ty` against their actual Python/Playwright environment before use. The existing
MFA, resize and account-lifecycle artifacts retain their gates. This adds build
evidence; it does not rerun prior native journeys or close the legacy composed
fleet driver's explicit type-check exclusion.

The [legacy browser typing sweep](../reviews/2026-09-26-browser-typing-sweep.md)
then closed that exclusion: every fleet variant's composed driver passes the
framework's type and lint checks, and the remaining fleet Audi/Porsche and
Inception browser helpers execute pinned checked artifacts. The sweep also
restored the fleet's evaluable executor-loss check after an integration merge
dropped its formal parameter. This remains build evidence; recorded native
journeys keep their revisions and scopes.

*Fixture image medium (2026-10-31).* The fleet fixture's Lilly hosts used to read
guest image artifacts from the runner's store over the framework's 9p share. On
Namespace xl runners that delivered 2–3.5 MB/s, and in machine-test run
41164441328 audi-fleet's template prewarm ended unconfirmed after 918.9 s, past
the fixture's 900 s image I/O deadline. The
[image store module](../../../nix/verification/tests/machines/fleet/image-store.nix)
now builds, at VM start, a read-only erofs virtio-blk drive from each configured
image's resolved store artifacts up to 8 GiB. Before Lilly starts, it bind-mounts
each artifact over its own `/nix/store` path (contract
`fleet-image-store-medium-only`). Lilly's configured paths, immutable-store
verification, durable template copy and deadline are unchanged. Template copy
times on this medium are fixture timings. They are not production clone
evidence, and larger images (Windows) still use 9p.

## Open questions

The current runner proved nested KVM and the required functional suites. Maintain
a builder with sufficient resources and the documented capabilities for regression runs.
Record the independent physical-host and production-provider acceptance results
before making those stronger claims.

## Related decisions

[ADR-0003](0003-control-plane-coordination.md),
[ADR-0007](0007-profile-networking.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0029](0029-database-durability-and-recovery.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0032](0032-ssh-derived-age-identities.md),
[architecture review](../reviews/2026-09-16-nixos-and-sparse-zfs.md).

Interface reference: [NixOS VM Testing Framework](https://nixos.org/manual/nixos/stable/#sec-nixos-tests).
