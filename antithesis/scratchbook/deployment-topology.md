---
sut_path: /home/ghuntley/src/overalls
commit: 09db83a490ac8f3623aef1cb8d628fed79c297cc
updated: 2026-11-02
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---

# Minimal deployment topology for the fresh Antithesis portfolio

## Scope and decision

This is a design handoff, not a built image, a passing hosted run, or permission
to substitute mocked effects for physical evidence. Source research is limited
to this repository at the commit above. Official Antithesis documentation is
used only for platform and SDK mechanics. The removed harness is not an input.
The completed [SUT analysis](sut-analysis.md), [image](image-build-feasibility.md),
[BEAM](beam-sdk-feasibility.md), [Hegel](hegel-sdk-feasibility.md),
[guest](emulated-guest-feasibility.md), [storage](emulated-storage-feasibility.md)
and [native](native-campaign-inventory.md) inventories supply the component
evidence and current feasibility limits.

Use **focused Compose configurations and test templates**. The smallest common
hosted service spine is one real PostgreSQL primary, two separately faultable
Marshall releases, one separately faultable Lilly release running its actual
Control client, Store, Runtime, actors and journals, and one workload/oracle
container. Add a satellite, emulator or recorder only when a selected property
crosses that boundary. Two Marshall processes exercise shared-database races;
they do not create database HA. One Lilly placement is enough for admission,
restart and authority histories; cross-host transfer/relocation needs two
independent Lilly execution boundaries or the native fleet.

The current hosted machine cannot supply nested KVM. A bounded TCG guest and a
separate TCG Linux/ZFS router are useful real mechanisms with explicitly
limited claims. Real Firecracker jail, cgroup, kernel ownership, native ZFS and
independent host acceptance belong to the native KVM campaign. A property may
appear in several configurations only when each run names its distinct oracle
and evidence scope. No template should contain a branch that silently skips an
unavailable service and then reports a passing property.

## Container roles and image sources

All service images come from the repository's source-built, pinned Nix release
outputs and complete recursive runtime closures. The repository has no existing
OCI export. Build layered OCI images from deliberate Nix root layouts using the
locked `dockerTools.buildLayeredImage`, or a deterministic `FROM scratch` closure
context. Pin immutable image digests, not tags alone. Build each release in
`MIX_ENV=prod` with the exact matching OTP/Elixir and its normal external tools.
The image ledger must state which harness-only source paths and compile flags
were selected. Production releases remain independent; Marshall's test-only
Lilly/Porsche/Audi dependencies do not enter its production image. No runtime
module replacement, test Mix environment, mounted working tree, live Nix daemon
or startup dependency download is an acceptable image source.

| Component | Role and replica count when selected | Image source and state | Links and independent boundary |
| --- | --- | --- | --- |
| `pg` | Dependency, one PostgreSQL 18 primary | Pinned official or Nix PostgreSQL image, initialized with reviewed synthetic credentials; own durable data | Marshall A/B connect separately. DB outage, lock contention and restart have their own fault boundary; no standby claim. |
| `marshall-a`, `marshall-b` | SUT services, two in the shared-control template; narrow satellite-only cases may select one | Two containers of the same pinned source-built Marshall release, separate process/cookie/temp state, shared `pg` | Independent container/node faults; both can accept workload/API traffic and compete for the same Ash/Oban rows. No in-container multiplexing. |
| `lilly-a` | SUT service, one in host/control and guest templates | Source-built Lilly release, real Runtime/Store/actors/journals; own persistent state and native helper closure | Control to Marshall, local host-owner and executor interfaces, optional guest emulator. State must survive daemon restart. Hosted-only lower seams are compile-time explicit. |
| `lilly-b` | Optional SUT service, one extra for transfer or cross-host authority templates | Same image, distinct identity/state/helper namespace | Separate fault domain and independently observed source/destination. Do not imply two containers on one outer machine are two physical hosts. |
| `audi`, `porsche`, `ziggy`, `galileo`, `brady`, `enrico` | SUT services, one container each **only** for their focused templates | Their own source-built OTP releases, own runtime identity/state; required native tools included explicitly | Audi↔Marshall/Lilly private connector, Porsche↔Marshall, Ziggy/Galileo↔Marshall and fixture upstream, Brady↔intercepted origin/attribution, Enrico↔Marshall/local Git fixture. Each is independently faultable from its authority and dependency. |
| `native-owner` or `recorder` | Optional service/observer, one per actual selected boundary | Source-built Rust helper/trace spool/request recorder with own persistent files; a short-lived helper invoked by Lilly remains in Lilly's container when its fate is necessarily host-local | Use a separate container when testing recorder ACK loss, independent diagnostic custody or remote transport. Do not call a process in the same container an independent node fault. |
| `origin` | Dependency, one per selected upstream family | Fixed local HTTP/TLS/Git fixture with generated synthetic CA and immutable request/response log | Separate from Ziggy/Galileo/Brady/Enrico. It records exact effects; network fault can split SUT from upstream. Never contact public providers. |
| `workload` | Client, one per template | Pinned Python 3.13, official SDK and typed oracle code; optional browser/CLI closure only for a journey needing it | Calls actual public/private interfaces and independently queries database, native process, guest bytes, recorder or origin as appropriate. Emits `setup_complete` after readiness and then stays alive. |
| `guest-vmm` | Optional service for real guest template, one QEMU placement initially | Pinned QEMU/vhost-device-vsock, exact NixOS guest kernel/initrd/rootfs and a retained qcow2 overlay | Separate from Lilly so outer faults can disrupt its transport. Typed emulator executor mediates actual QMP/PID/overlay/boot evidence; no Firecracker identity forgery. |
| `router-vmm` | Optional service for storage/router template, one QEMU Linux VM | Fresh locked NixOS root/system closure, QEMU, two owned sparse mirror disks, source-built Lilly tools/Brady inside guest | Its inner ZFS/nftables/veth faults require explicit typed guest actions. Outer container faults do not independently partition inner client↔Brady↔origin links. |

The table is a menu, not one giant Compose graph. Each selected image should run
one principal service process; a VM's required QEMU/vsock backend pair is a
single owned emulator boundary with recorded child identities. The workload
image contains test commands under `/opt/antithesis/test/v1/{template}/`; helper
files there use `helper_` prefixes. The workload's bootstrap process, not a
`first_` command, is the **only `setup_complete` owner**. It waits for declared
service readiness, immutable fixture identities and a healthy independent
oracle before signaling. A failed dependency or slow TCG boot fails readiness
visibly; it never converts a selected case into a skipped/pass branch.

## Focused configurations and property families

Use a common Compose base for closed network, synthetic identity/CA, `pg`,
workload, persistent state and optional Marshall/Lilly services. Small override
files select the exact services named below. Each override gets a test template
with only commands whose preconditions it satisfies. The catalog is still being
frozen, so these are family mappings, not final property IDs. Freeze an explicit
property-to-template roster once discovery/evaluation is complete.

| Configuration / template | Selected failure boundaries | Property families and independent oracle | Exclusions or additional condition |
| --- | --- | --- | --- |
| `control-core` / `control` | `pg`, Marshall A/B, Lilly A, workload; real local owner/helper as needed | Admission idempotency, shared DB lock/capacity, operation receipts, Control version/auth/refusal/reconnect, host freshness, Lilly journal attempt-before-effect and exact ACK. Compare committed rows and physical helper/journal identities to API responses; uncertain replies remain unknown. | A hosted lower executor is explicitly an emulator/controlled effect for this template. It does not establish guest bytes, native ZFS or Firecracker. DB HA and relocation are excluded. |
| `access` / `access` | `control-core` plus **Audi or Porsche**, according to command, and guest-vmm only for real terminal/editor bytes | Current grant/roster/stream revocation, SSH and browser permission, terminal ordering/backpressure, editor current execution. Oracle combines Marshall authority, Audi/Porsche refusal, Lilly physical boot/connector and guest terminal/editor response. | Gateway-only refusal can run without guest; a terminal/editor success property selects guest-vmm and does not accept canned bytes. Audi/Porsche are separate containers and separately selected. |
| `upstream` / `inference`, `integration`, `repository` | `pg`, one or two Marshall, workload, **one of Ziggy, Galileo, Enrico**, plus local `origin`; guest-vmm only for repository checkout | Ziggy durable pre-effect accounting/dedup versus independently logged provider call; Galileo current lease and exactly one observed upstream attempt; Enrico mirror refresh/custody versus immutable local Git refs and retained Marshall intent. | Separate templates prevent a missing upstream from masking a branch. Enrico Git is real; fixed-origin local DNS/TLS is a bounded lower seam. No real public provider behavior claim. |
| `observability` / `recorder` | Minimal producer service plus independently faultable recorder/spool and workload; `pg`/Marshall only if the selected producer requires them | ACK loss, retained ciphertext/trace custody, producer progress despite diagnostic loss under ADR-0149. Oracle compares producer sequence/effect and recorder durable receipt or archive; missing diagnostics never prove guest absence. | Keep recorder separate if testing network/node loss. Do not place all eight telemetry producers in one run. |
| `guest-journey` / `guest` | `control-core`, guest-vmm, Audi for private ingress, optionally Porsche for SSH and local origin for checkout | Real current boot/readiness/trust, retained fsync bytes, workspace source v2/HEAD, terminal/editor session authority and access. Oracle reads guest boot UUID, exact placement/epoch/challenge, overlay identity, guest bytes/HEAD and network/stream refusal after authority changes. | One q35 TCG guest with one vCPU/2 GiB initially; retain disk overlay and backend/QEMU PIDs. No Firecracker/jail/KVM or ZFS claim. Add only the gateway needed by the selected command. |
| `storage-router` / `storage` | Router-vmm and workload; optional separate origin container if crossing outer network | Actual Linux ZFS GUID/content/nonce/custody, Brady cache completeness, pressure and nftables/TPROXY refusal. Oracle queries post-reboot zpool/dataset GUIDs and bytes, pressure freshness, nft counters/original socket tuple and origin request log. | Brady runs inside the VM for real kernel interception; inner network faults are explicit, not inferred from outer partitions. No authoritative per-VM attribution without a real current execution source. |
| `native-kvm` / repository Nix checks, **outside hosted Compose** | Existing forced-KVM NixOS/Ubuntu machine fixtures with real Firecracker, ZFS, systemd/cgroups and host network | Physical ownership/isolation, guest readiness, native transfer/relocation, kernel egress attribution, backups, native recorder and database outage variants. Record each exact check derivation/driver and current execution result. | Sequential local campaign; source test presence or historical passes do not close current acceptance. Existing fixture failures must be repaired and rerun. |

For a family that needs two Lilly instances, create a distinct `transfer` override
from `control-core`, adding `lilly-b`, separate state and exact source/destination
oracles. Keep stopped-only full-copy semantics under ADR-0155; a simulated
success reply cannot establish real SSH stream, ZFS GUID, source restoration or
destination boot. Prefer the native fleet for complete relocation claims. The
`storage-router` target is a standalone real storage/router test; it is not an
implicit implementation of production Lilly's backing pool for `guest-journey`.

## Exact hosted lower seams and bootstrap

Lilly's actual Runtime hardcodes the native executor at
`lilly/lib/lilly/control/runtime.ex:1118`. Hosted builds need an explicit,
compile-time harness-only selection for ownership acquire/verification,
Collector/ZFSIO observation and executor choice at Runtime's lower boundaries.
Keep real Control, Store, actor, journal and durable attempt/effect ordering.
The adapter must report its own QEMU/process/overlay evidence and typed
unavailable/refused/committed outcomes. A runtime-selectable production bypass,
fake running row, unconditional readiness or fabricated Firecracker observation
would invalidate the relevant property. Same-container native helpers retain
flock/descendant custody; independently faulted recorder/outcome systems stay
separate. Preserve `rest_for_one` application restart behavior.

The guest template uses the evaluated q35 variant with `virtio_pci`,
`virtio_blk`, `virtio_net`, `vmw_vsock_virtio_transport`, ext4 and removal of
`pci=off`. The intended QEMU path is `-accel tcg,thread=single -smp 1 -m 2048`,
memfd-backed vhost-user-vsock, one backend per placement, private QMP/UDS and
a retained qcow2 overlay over the immutable raw image. TAP/routing must preserve
the guest's `10.10.0.2/32`, gateway `10.10.0.1`, private DNS at
`169.254.254.1`, and actual editor gateway source. Port 1024 readiness binds
placement, epoch, challenge and kernel boot UUID; 1030 trust must complete before
network/roster/SSH; 1031 workspace completion is separate from readiness; 1026
flush, 1075 terminald and TCP 4444 editor must each be probed through their
real protocol. One successful serial marker is not readiness. The image, QEMU
and vhost outputs have only been evaluated/inspected, not booted here.

For Enrico, serve a real fixed Git repository with immutable commits/refs and
request receipts behind provider-shaped local hostnames, DNS and synthetic TLS.
The lower seam is only origin transport: use real Enrico manager, native Git
owner, Git CLI and actual mirror files. Test default/ref/commit/change identity
only when the fixture implements the corresponding real smart HTTP/API behavior;
compare mirror/checkout `HEAD` and published content to the fixture's immutable
hash. An Enrico restart can lose bounded local attempt receipts while Marshall
retains durable intent; do not assert indefinite Enrico replay retention. The
same origin rule applies to Ziggy/Galileo: their provider/integration effects
must be counted by an independent request log, with exact error and ACK-loss
menus, rather than assumed from the service's own completion record. Repository
guest checkout additionally needs the actual trust, private DNS, roster and
workspace path; a local Git fixture alone does not satisfy it.

The storage/router VM is a separate locked NixOS system using source-built
Brady/Lilly tools, 2 GiB RAM, one TCG vCPU, 128 MiB ZFS ARC and two sparse 1 GiB
mirrored data disks with fixed serials. Preserve one retained root overlay and
both disk files across VM restarts; create/import by recorded GUID, never
unconditionally recreate a nonempty pool. Run actual Brady storage preparation,
then explicitly apply/read back a bounded fixture quota before pressure tests.
Brady must run under its reviewed UID/namespace/capability and real nftables
TPROXY route. A bounded typed control channel may request service stop/start,
link fault, quota change, disk offline/online or correlated QMP action; it must
not accept arbitrary shell, device path or QMP JSON from generated tests.

## Fault classes and liveness windows

Antithesis automatic faults act at **container** granularity. Separate service,
DB, origin, emulator and recorder containers provide meaningful asymmetric
links, hangs/throttles and, if enabled, termination/restart. A service pair
inside one container shares fate and gets no independently injectable network
fault. Baseline packet loss/latency is normal environment behavior. Node
termination, clock jumps, custom faults and instrumented thread pausing must be
confirmed for the tenant/webhook before claiming those histories. Clock jitter
is global, so it does not create independent clock skew between containers.

Label every witness with one of `outer-automatic`, `explicit-service`,
`explicit-guest-network`, `explicit-qmp`, `explicit-zfs-disk`, `explicit-quota`
or `native-kvm`, plus operation ID, current boot/process identity and observed
fault restoration. Outer loss of `guest-vmm` may stop all its child processes;
it is not a direct independent fault in a guest unit. Outer loss of
`router-vmm` does not inject a partition between veth peers inside its guest.
An acknowledged guest fsync surviving QEMU termination/reimport is emulated
process-crash evidence, not physical power-cut durability. A probe timeout or
missing origin/recorder reply is unavailable evidence, not absence, success or
an expected refusal.

Safety assertions run through faults. A liveness assertion requires recorded
restoration of its exact dependencies. `eventually_`/`finally_` are terminal
quiet checks; use `ANTITHESIS_STOP_FAULTS` for a mid-run quiet window that can
continue, and verify service/database/guest recovery before checking progress.
Internal production lease/freshness deadlines remain unchanged even if an
outer TCG readiness watchdog is longer. A TCG boot or pressure deadline that
cannot be met is a feasibility gap to measure, not a reason to weaken the SUT.

## Build, readiness and campaign ledger

Before each baseline, freeze a manifest containing full Git SHA and dirty
source status; selected source file content/modes and symlink targets; `flake.lock`,
Mix/Cargo/npm locks and hashes; Nix derivation paths and complete recursive
runtime closures; guest kernel/initrd/rootfs/manifest and private-root set;
emulator/helper binaries; Dockerfile/root layout and image digests; Compose
base/override; runtime schema and public synthetic fixture hashes; SDK and
instrumentation versions/options; exact test-template command list; property
catalog IDs and assertion locations. Retain a digest of the manifest with each
run. Rebuild/rebaseline after any relevant source or configuration change; do
not transfer an old green result to a new digest. Secrets are generated at
startup, kept outside logs/manifests and excluded from build inputs.

Bootstrap order is: materialize immutable images and owned durable volumes;
start `pg` and verify writable primary/migrations; start selected Marshall
instances and verify authenticated API/readiness; start Lilly and verify real
Control negotiation plus current host report; start only selected satellites,
origin, recorder or VMM; verify their property-specific real effects and oracle
availability; then the workload emits exactly one `setup_complete`. Migrate
mode must never serve or consume jobs. This owner records all readiness
failures, including guest trust/boot or storage pressure failure, with a bounded
watchdog. No `first_` action is used to signal setup completion.

Start with one **60-minute hosted baseline per focused configuration** that is
actually implemented and ready; run **15-minute targeted mutant runs** only
after its matching baseline and oracle are green. Limit remote submissions to
**three in flight** and the authorized total ceiling of **`5N`**, where `N`
is the safety-property count from the frozen catalog plus actual assertion
scan. `N` is not yet frozen, so this is a ceiling formula, not a run count.
Mutants must name one targeted property, a realistic changed effect and a
counterexample-specific witness; a failing environment bootstrap is not a
caught mutant. The native KVM campaign is sequential and separately budgeted;
it cannot be smuggled into hosted 60-minute timelines.

## Acceptance gates and open questions

1. Build and smoke each selected source-built image and its full closure. Add
   the missing Galileo release payload probe and Enrico probe branch before
   claiming all eight releases checked. Confirm actual Rust coverage hooks,
   build IDs/debug artifacts and matching `/symbols` **in the same image**;
   Python SDK assertions and BEAM fallback JSONL do not establish their source
   coverage. Validate BEAM atomic newline JSONL and one owner for lifecycle
   reporting in a hosted smoke.
2. Execute one focused baseline at a time with real effect and independent
   oracle. Confirm tenant fault enablement and hosted filesystem persistence/
   snapshot semantics before claiming restart/clock/disk histories. Do not
   count a merely evaluated Nix derivation or successful local JSONL probe as
   a hosted run.
3. Boot and measure the TCG guest and storage/router images before setting
   final cold-start watchdogs or concurrency. The guest's current 180-second
   trust deadline and storage's three-second fresh-pressure requirement may
   become the binding constraints. Record actual boot time, RSS, disk writes
   and closure bytes. If this budget fails, keep that property unproven and
   retain native evidence separately.
4. Execute the native KVM checks from [the campaign inventory](native-campaign-inventory.md)
   with exact derivation/output/current-run receipts. Its documented fixture
   blockers (`service-roles` Galileo option, `native-zfs` revision receipt and
   `zfs-io` obsolete control field) need repair and fresh execution. Existing
   source and historical review records are not current passing results.

Open decisions: exact final property roster per template and resulting `N`;
tenant node/clock/custom-fault availability; successful hosted guest and router
boots; hosted durable-volume behavior across automatic restart; measured TCG
freshness/pressure feasibility; exact SDK pin and instrumented module list;
and whether any property warrants two Lilly containers before the native fleet.
These do not license an unimplemented branch to pass. If a required precondition
is absent, the property is reported unexercised with its missing boundary.

This research artifact changes no architecture, runtime configuration, protocol
or production behavior. The proposed implementation would alter verification
topology and harness-only build seams; review against ADR-0017, ADR-0033,
ADR-0069/0135/0140, ADR-0149, ADR-0155, ADR-0157 and ADR-0158, then maintain
the HLDD and contracts in the implementation change. No architectural decision
status is changed here.
