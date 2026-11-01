# ADR-0171: Windows guest agents over virtio-vsock and fleet enablement

- ID: ADR-0171
- Date: 2026-10-14
- Status: proposed
- Implementation: partial
- Components: Protocol, Lilly, Marshall, nix-packages, guest-images, fleet
- Supersedes: none
- Superseded by: none

Once accepted, this record supersedes [ADR-0170](0170-lilly-firmware-guest-launch.md)
in part (decision clauses 3, 4 and 6: firmware jails without vsock,
agentless-only firmware guests, the binary guest-agents status); the
reciprocal links are activated at acceptance, as the ADR checker requires.

## Context

[ADR-0170](0170-lilly-firmware-guest-launch.md) made the Windows Server 2025
image a Lilly placement without guest agents: identity reaches the guest
through MMDS, trust is `skipped`, provisioning ends `unattested`, and Marshall
hides and refuses Terminal, Agents, the editor and SSH for the image. That
branch is deployed (push `9715932aa`, both fleet hosts healthy on 2026-10-14).
A Windows guest is useful only once the roster can log in, the browser terminal
and the agent executor work and a workspace can be cloned, which needs guest
agents and a transport to Lilly.

Verified facts that shape this decision:

- The pinned virtio-win 0.1.285-1 ships `viosock/2k25/amd64`: the kernel
  driver `viosock.sys`, the Winsock provider service `viosockwspsvc.exe`
  (`VirtioSocketWSP`, auto start, registered by the INF together with the
  demand-start kernel service) and `viosocklib_x64.dll`. The INF binds
  `PCI\VEN_1AF4&DEV_1053`, the modern virtio-vsock PCI identifier that
  Firecracker 1.16.1 exposes with `--enable-pci`.
- `AF_VSOCK` is not a constant on Windows: the provider's address family is
  discovered at runtime (the `\\.\Viosock` control device or the Winsock
  catalog), and `SOCKADDR_VM` is a 12-byte structure in host byte order.
- Every Lilly guest protocol (readiness 1024, credentials 1025, flush 1026,
  trust 1030, workspace 1031, terminal 1075) is a line or frame protocol over
  vsock with no Linux assumption, so a Windows guest can answer them byte for
  byte.
- The Lyra crate already cross-compiles four targets through cargo-zigbuild
  with a pinned Rust 1.97.1 toolchain; the lock carries `windows-sys` 0.61.
  Its shared modules used Unix-only APIs (`O_NOFOLLOW`, POSIX modes, process
  groups) that the Windows build must not link.
- `nix/domains/system/lilly.nix` asserted `standbyDisks.perImage × length images ≤ 64`
  and both hosts run 32 × 2; `StandbyRefill` planned every configured image
  except Inception; the Windows template (32 GiB plus 4 MiB) exceeded the
  32 GiB template budget, so each pass would have hashed 32 GiB per minute and
  failed with `standby_template_unavailable`.
- Marshall's gates were a binary `guest_agents_status` and Lilly branched on
  `:none` versus everything else; neither could express "readiness, trust,
  terminal, SSH and agents but no editor and no Inception".
- The Windows installation is not byte-stable, so two hosts building the same
  derivation produce two images with two identities; hosts substitute only from
  the peer host.
- The non-Inception readiness budget was 120 s; Windows applied its `/32` about
  two minutes after power-on on bare KVM.

## Decision

1. **A third agent set, `windows-v1`, and a pure capability table.**
   `OverallsProtocol.GuestAgents` names the closed set `:linux | :none |
   :windows_v1` (`wire/1`, `parse/1`) and its capability table
   `capabilities/1` (`readiness`, `trust`, `terminal`, `workspace`,
   `inception`, `flush`, `ssh`, `agents`, `editor`): Linux has everything,
   `none` nothing, `windows-v1` everything except `inception` and `editor`.
   `vsock?/1` is true for the sets that speak the vsock protocols, and
   `readiness_budget_ms/2` gives 120 s for Linux, 2400 s for Linux Inception
   and 600 s for `windows-v1`, matching Marshall's provision service level.
   Lilly and Marshall branch on capabilities, never on the atom. The version-5
   manifest admits `guest_agents` in `none | windows-v1` and
   `workspace_source_version` 2 only with `windows-v1`; the identity array
   already carried both values, so IDs change and nothing collides. Bundle
   version 2 carries the value; an old Lilly refuses a `windows-v1` bundle
   (fails closed), which is why the converged push precedes any placement.
2. **Firmware jails get the vsock endpoint iff the agent set uses it.**
   `Lilly.VM.Jail.configuration/3` adds the jail-local `/v.sock` (guest CID 3)
   to a firmware bundle exactly when `GuestAgents.vsock?/1` holds; the
   agentless configuration is pinned unchanged. The MMDS document is unchanged.
3. **Lilly's driver follows the capability table.** Launch records the agent
   set's readiness budget as the provisioning deadline
   (`Provisioning.launching/4`); trust is delivered when `trust` holds and
   skipped otherwise; readiness is observed when `readiness` holds; terminals,
   workspace delivery and the Inception profile follow their capabilities.
4. **Standby eligibility is configured per image.** `services.lilly.images`
   entries are `{ path; standby }` objects; the module assertion counts
   standby-eligible images; `Lilly.Control.Config` accepts only that shape and
   preserves order; `StandbyRefill.eligible_images/3` plans only eligible,
   non-Inception, cacheable (`ImageTemplate.cacheable?/2`, a size check with no
   hashing) images; the catalog verifies images smallest first. Both hosts'
   `imageTemplates.budgetBytes` rises to 48 GiB (all images sum to about
   40 GiB logical; physical use stays near 12 GiB because the copy is sparse
   and lz4-compressed). The Windows image is staged with `standby = false`.
5. **Marshall projects per-capability facts.** `Image.guest_capabilities/1`
   returns booleans (`available`, `ssh`, `terminal`, `agents`, `editor`,
   `readiness`, `inception`) derived from the table on the row-bound validated
   manifest, all false when the manifest is missing, corrupt or mismatched;
   `Images.guest_capabilities/1` reads the durable row by ID; views project it.
   Presentation, terminal authority, agent model calls, the executor binding,
   web search, Inception admission and the creation-to-ready service level each
   key on their own capability. An unknown or absent snapshot image keeps the
   creation-to-ready measurement as before; only a known image without
   `readiness` waives it. An image change in the creation form resets the size
   defaults to the selected image's minima.
6. **Windows agents are Rust, cross-built as `lyraWindows`.** The Lyra crate
   gains the `x86_64-pc-windows-gnu` standard library in its pinned toolchain
   and a sibling derivation that zigbuilds the Windows binaries, caps each
   `.exe` at 100 MiB and lists them with digests in a manifest. Shared modules
   are portable: `ssh_files` refuses symlinks with `O_NOFOLLOW` on Unix and
   `FILE_FLAG_OPEN_REPARSE_POINT` on Windows, POSIX modes and process-group
   kills are `cfg(unix)` with Windows equivalents (directory ACL inheritance,
   Job Objects from gate 5), and the Lyra check type-checks every bin for the
   Windows target so Unix-only code cannot creep back in. Linux binaries keep
   byte-identical behaviour.
7. **Transport is virtio-vsock through viosock.** The image ships the
   `viosock` driver beside the other virtio drivers; it binds through PnP at
   first boot under Firecracker and its Winsock provider service starts
   afterwards. Agents discover the address family at runtime (the `\\.\Viosock`
   control device answered family 40 on the first boot) and wait for the
   provider for up to ten minutes. The virtio-win ring library places every
   multi-descriptor buffer in an indirect descriptor table whenever the driver
   holds one, whether or not `VIRTIO_RING_F_INDIRECT_DESC` was negotiated, and
   viosock does so for each RX and TX packet; Firecracker's queue had no
   indirect support and discarded every packet as an unwritable head. A ninth
   Overalls patch, `firecracker-vsock-indirect-desc`, makes the vsock packet
   parsers resolve an indirect head into its table (refusing nested, empty,
   descriptor-misaligned, oversized or onward-chaining tables; viosock keeps
   its tables 8-byte aligned inside its packet structures) while the feature stays
   unoffered, so Linux guests never post one and keep their direct chains. Gate 1 proves the path with a spike probe
   (`overalls-winprobe`, a SYSTEM task listening on port 1099 that answers the
   host's `CONNECT 1099` with one JSON line and publishes its log on the EFI
   system partition); the real agents replace it.
8. **Agent, account and service model (gates 2 to 5).** Every agent runs as
   a LocalSystem scheduled task started at boot, registered by
   `SetupComplete.cmd` like the bootstrap task, with no dependency on the
   provider service (each agent discovers the vsock family itself within a
   ten-minute budget). `schtasks` gives tasks a 72-hour execution limit, so
   one settings pass removes it, refuses a second instance and requests
   restart on failure for every agent task. The plan's SCM shim was not
   needed for `sshd` control (the roster agent starts the in-box service
   directly) and is not built; whether Task Scheduler restarts a daemon that
   exits with an error is unproven, so crash supervision is a recorded gap
   and an SCM service host is the replacement if it proves necessary. A
   per-boot `boot_id` lives in a volatile registry key.
   Trust installs into `LocalMachine\Root` plus a PEM bundle for Git and HTTP
   clients. Win32-OpenSSH does not implement `AuthorizedKeysCommand` (its
   wiki and Microsoft's key-management guide list the directive as
   unsupported), so the Linux live-authorize path cannot be mirrored.
   Windows guests instead pull: the roster agent (`overalls-ssh-sync-windows`)
   fetches, every two seconds like the Linux roster timer, the roster and a
   new private route `GET /ssh/v1/authorized-keys` that Marshall serves through
   Ziggy and Audi with the same writer computation as the roster plus each
   writer's registered, unarchived keys, and writes one `AuthorizedKeysFile`
   per account (`C:\overalls\ssh\authorized_keys\<user>`, SYSTEM-owned,
   readable by that account only). The inner sshd therefore accepts any
   registered key of a current writer for that writer's own account, not only
   the key of the live Audi session; the identity binding (a user's key opens
   only that user's account) and the write-grant check are kept, the
   session binding is not, and the host policy still admits port 22 only
   through Audi's ingress path. Login receipts come from sshd's own file log
   (`SyslogFacility LOCAL0`, `%ProgramData%\ssh\logs\sshd.log`) instead of
   a PAM hook: the roster agent tails it and reports each `Accepted publickey`
   line whose fingerprint matches a key it pulled for that account to
   `/ssh/v1/login`, which Marshall still binds to the live Audi session. A
   per-boot host certificate is kept; roster accounts are local users
   `u<uid>` in Administrators, disabled rather than expired; the bootstrap Administrator is rotated to a
   random unrecorded password and disabled after the first activated roster
   account, closing the ADR-0169 serial-login gap. The terminal daemon is the
   Linux `terminald` source built for Windows (`terminaldWindows`): one
   session engine, framing, ring and HELLO, with only sockets, the PTY and the
   boot identity selected by target. Sessions run in ConPTY under a
   kill-on-close job; `root` keeps its Linux meaning (the host-admin session,
   here LocalSystem) and any other name must be an enabled local account,
   which runs under an S4U logon as Win32-OpenSSH does for key logins. The
   boot identity comes from MMDS, viewer sockets are non-blocking with
   bounded waits so a credit stall pauses instead of dropping bytes, and
   ConPTY's re-rendering of the screen is a recorded fidelity difference. The
   agent executor runs PowerShell 5.1 under a
   Job Object; the workspace receiver runs a pinned MinGit (replaced by
   winget's Git for Windows, [ADR-0173](0173-windows-images-winget-desktop-experience.md)). Self-update does
   not exist on Windows (image rebuild) and host key material lives on disk:
   both are recorded gaps.
9. **Image distribution and rollout.** The final image is built once and its
   closure copied to both hosts with `nix copy` before the staging push, so
   hosts substitute instead of building two different images. Push 3a lands
   protocol, Lilly, Marshall, module and host changes and the agents code with
   no image staged; after convergence push 3b stages the image in
   `fleet/guest-images.nix` with `standby = false`; acceptance (readiness,
   roster SSH, browser terminal, an agent turn, a workspace clone, relocation
   and clone between hosts) is recorded in the review.

## Alternatives

- **Serial or virtio-serial as the agent transport.** COM1 belongs to EMS and
  the SAC; virtio-serial would need a second protocol family on the Lilly side.
  vsock reuses every existing protocol unchanged.
- **PowerShell agents.** No shared protocol code with the Linux agents, weak
  typing, and the HELLO HMAC and framing would be reimplemented. Rust shares
  the crate.
- **Keep the binary agents status and special-case Windows.** Every surface
  would carry a second condition; the table makes each surface read one fact.
- **Admit a third standby-eligible image by raising the 64 bound.** The
  Windows template is uncacheable within budget and a 32 GiB hash per minute
  is the actual hazard; eligibility and the size check remove it.
- **Let each host build the Windows image.** Two identities for one image;
  relocation and clone between the hosts would fail on identity.

## Consequences

- Linux guests see no behaviour change: the Linux capability table is
  everything, budgets are unchanged, jail and unit output for kernel bundles
  are pinned, and the Lyra Linux binaries are byte-identical in behaviour.
- Agentless firmware images (ADR-0170) keep working: the `none` capability
  table matches the previous binary status, and the agentless jail
  configuration is pinned without vsock.
- Operators configure `{ path; standby }` for every image; a bare path refuses
  the configuration.
- The Windows image identity changes when `guest_agents` becomes `windows-v1`;
  the agentless image remains buildable for the ADR-0170 machine test.

## Invariants and verification

- The capability table and wire set are closed and pinned by
  `protocol/test/guest_agents_test.exs`; manifest and bundle vectors for
  `windows-v1` (with and without workspace source version 2) are independently
  computed beside the `none` and version-4 pins.
- Firmware jails: the agentless configuration is unchanged; `windows-v1` adds
  exactly the vsock key (`lilly/test/vm/jail_test.exs`).
- Provisioning records the caller's readiness budget once and never extends
  it on relaunch (`lilly/test/vm/provisioning_test.exs`).
- Image configuration shape, order and duplicate refusal
  (`lilly/test/lilly/control/config_test.exs`); cacheability is a size check and
  refill eligibility drops ineligible, Inception and uncacheable images
  (`lilly/test/host/image_template_cacheable_test.exs`).
- Marshall: capabilities are bound to the exact image ID for every agent set
  (property), the workspace renders Terminal, Agents and SSH without the editor
  for `windows-v1`, admission refuses Inception for both firmware sets and
  admits `marshall_ready` for `windows-v1`, and the creation form resets sizes
  on an image change.
- Lyra: `cargo test`, clippy and a Windows-target `cargo check` run in the Nix
  check; `lyraWindows` builds the probe through zig (gate 0 recorded
  2026-10-14: `overalls-winprobe.exe`, 320 000 bytes, PE32+) and, by gate 3,
  the readiness, trust, roster and host-certificate agents, the last two
  linking the rustls private HTTPS client.
- Roster rules are pinned with a fake account backend (`guest/ssh_roster`
  tests: both platforms' name rules, stale and diverging rosters refused
  without mutation, departures disabled before arrivals, staged union kept
  on failure); Marshall's `authorized_keys/2` is tested to list exactly the
  writers' unarchived keys, follow key removal and refuse foreign, bootstrap
  or unauthenticated bindings without recording a login; Ziggy's route tests
  refuse the bootstrap binding on `/ssh/v1/authorized-keys`.
- Image builder rules are evaluated by `windows-guest-unit`: viosock in the
  driver tree, the agents directory on the media only when supplied, the
  probe task registered only when present, the manifest's agent set and
  workspace source version from the builder arguments, the launcher's vsock
  device.
- The vsock indirect-descriptor patch carries unit tests in the patched vmm
  crate (`firecracker-patch-tests`): an RX chain and a TX chain posted through
  an indirect table parse like direct ones and the header commit lands in the
  table's first buffer; a head that chains onward, an empty, partial,
  misaligned or nested table are refused; an 8-byte aligned table is accepted; a direct chain is returned unchanged; the
  upstream RX and TX assembly tests still pass.
- terminald keeps its Linux suite (52 tests including the property tests) on
  the shared engine after the platform split; the MMDS identity decoder is
  unit tested on Linux (subtree accepted, envelope and zero epoch refused, no
  wait for MMDS to close); the Windows target is type-checked and built by
  the `terminald-windows` flake check; the roster name rule is a Windows-only
  unit test.
- Machine tests on nested KVM: `windows-guest` dials the probe through the
  launcher's vsock socket and reads its published log;
  `windows-lilly-guest-agents` asserts `installed` trust bound to the boot,
  `ready` provisioning through the executor's completion path with the same
  guest boot UUID and a 600 s budget, a new boot UUID after restart, and
  (gate 4) a terminald HELLO, `PING`, `USERS` listing `root` first, refusal of
  an account the roster never created and a root PowerShell session under
  ConPTY that prints a computed marker, and (gate 5) a public workspace
  source delivered through the production Driver and recorded settled for
  the boot. The clone needs egress the nested test lacks and is a fleet
  proof. Executions are recorded in the review.

## Implementation evidence

- The [published fleet artifact](../../../nix/domains/artifacts/guest/windows/published.nix)
  enforces clause 9's built-once identity through a reviewed recursive NAR pin,
  exactly three regular files and no store references. The
  [fleet selector](../../../fleet/guest-images.nix) uses it while retaining the
  separate offline source builder for development. Missing publication refuses
  rather than constructing another Windows installation. The
  [matrix review](../reviews/2026-10-18-guest-os-matrix.md) records custody,
  verification and remaining execution gaps; this does not complete the runtime
  rollout or change this ADR's status.
- Protocol: [guest agents](../../../protocol/lib/overalls_protocol/guest_agents.ex),
  [image manifest](../../../protocol/lib/overalls_protocol/image_manifest.ex),
  [workload bundle](../../../protocol/lib/overalls_protocol/workload_bundle.ex).
- Lilly: [jail](../../../lilly/lib/lilly/vm/jail.ex),
  [driver](../../../lilly/lib/lilly/vm/driver.ex),
  [provisioning](../../../lilly/lib/lilly/vm/provisioning.ex),
  [executor](../../../lilly/lib/lilly/vm/executor.ex),
  [config](../../../lilly/lib/lilly/control/config.ex),
  `standby refill` (`lilly/lib/lilly/host/standby_refill.ex`, removed by ADR-0177),
  [image template](../../../lilly/lib/lilly/host/image_template.ex).
- Marshall: [image](../../../marshall/lib/marshall/compute/image.ex),
  [images](../../../marshall/lib/marshall/compute/images.ex),
  [service level admission](../../../marshall/lib/marshall/compute/service_level_admission.ex),
  [admission](../../../marshall/lib/marshall/compute/admission.ex),
  [workspace components](../../../marshall/lib/marshall_web/components/workspace_components.ex),
  [machines live](../../../marshall/lib/marshall_web/live/machines_live.ex).
- Module and fleet: [Lilly module](../../../nix/domains/system/lilly.nix),
  [guest images](../../../fleet/guest-images.nix),
  [dungarees](../../../fleet/hosts/dungarees/configuration.nix),
  [overalls image catalog](../../../fleet/roles/control-plane/image-catalog.nix).
- Agents: [Lyra packaging](../../../nix/domains/artifacts/infrastructure/lyra.nix),
  [probe](../../../lyra/src/bin/overalls-winprobe.rs),
  [SSH files](../../../lyra/src/ssh_files.rs),
  [workspace receiver](../../../lyra/src/workspace_receiver.rs).
- Image: [builder](../../../nix/domains/artifacts/guest/windows/default.nix),
  [SetupComplete](../../../nix/domains/artifacts/guest/windows/SetupComplete.cmd),
  [launcher](../../../nix/domains/artifacts/guest/windows/boot.nix).
- Checks: [unit evaluation](../../../nix/verification/tests/evaluation/windows-guest.nix),
  [machine test](../../../nix/verification/tests/machines/windows-guest/default.nix).
- Review: [Windows guest agents review](../reviews/2026-10-14-windows-guest-agents.md).

Gate 2 (readiness and trust daemons: [readiness](../../../lyra/src/bin/overalls-readinessd.rs),
[trust](../../../lyra/src/bin/overalls-trustd-windows.rs), the shared
[readiness](../../../lyra/src/guest/readiness.rs), [trust](../../../lyra/src/guest/trust.rs)
and [MMDS](../../../lyra/src/guest/mmds.rs) modules and the Windows
[platform layer](../../../lyra/src/platform/windows/mod.rs)) is implemented and
proven by the `windows-lilly-guest-agents` machine test once its execution is
recorded in the review. Gate 3 (SSH: [roster agent](../../../lyra/src/bin/overalls-ssh-sync-windows.rs),
[host certificate](../../../lyra/src/bin/overalls-host-certificate-windows.rs),
[sshd configuration](../../../nix/domains/artifacts/guest/windows/sshd_config)) is
implemented with unit tests and no Windows fleet test. Gate 4 (terminal: the
[ConPTY layer](../../../nix/domains/artifacts/terminald/src/pty_windows.rs),
[viosock sockets](../../../nix/domains/artifacts/terminald/src/conn_windows.rs),
[listener](../../../nix/domains/artifacts/terminald/src/vsock_windows.rs),
[MMDS identity](../../../nix/domains/artifacts/terminald/src/identity_mmds.rs) and
[packaging](../../../nix/domains/artifacts/infrastructure/terminald-windows.nix)) is implemented and
asserted by the same machine test. Gate 5's workspace receiver
([Windows transport](../../../lyra/src/bin/overalls-workspaced-windows.rs) around
the shared [receiver](../../../lyra/src/workspace_receiver.rs), the
[job helper](../../../lyra/src/platform/windows/job.rs) and the
Git, first a MinGit pin and since [ADR-0173](0173-windows-images-winget-desktop-experience.md)
Git for Windows from the [winget pins](../../../nix/domains/artifacts/guest/windows/winget.json)) is implemented;
the machine test asserts its boot-bound acceptance, not a clone (no egress).
The agent executor is the shared [executor core](../../../lyra/src/agent.rs)
moved into the Lyra library behind a `Host` trait, run on Windows by
[`overalls-agentd-windows`](../../../lyra/src/bin/overalls-agentd-windows.rs)
(PowerShell 5.1 in a job, Windows path rule, no self-update); `.internal`
names reach the local resolver through the bootstrap's NRPT rule, and the
private HTTPS client uses native TLS (schannel) on Windows as it does on
Linux. No machine test registers an executor (that needs Marshall), so an
agent turn is a fleet proof. Push 3b is not done; this ADR stays `partial`
until the review records the machine-test executions and the production
acceptance.

The 2026-10-18 [matrix review](../reviews/2026-10-18-guest-os-matrix.md)
records a source repair to gates 2 and 3. A `MAX_PATH`-bounded native profile
call is followed by SID-bound registration verification. New-boot SSH
bootstrap clears prior keys, waits for a verified host certificate, starts a
keyless listener and publishes its receipt before ordinary key delivery.
Readiness requires both current-boot receipts and live sshd; key delivery
retains the existing completed-start authority. The frozen Lyra gate passed
223 portable tests plus cross-target checks. A disposable native API diagnosis
reproduced the prior buffer failure but mutated its fixture; it establishes
neither unchanged-image lifecycle acceptance nor the new sealed image's
runtime behavior. No decision or implementation status is promoted by these
records.

The repaired exact image `8ca0a11f` then passed its actual 1,834.2-second
installation and immutable NTFS readback of all three repaired executables.
The sealed no-reference recursive NAR has a separate custody receipt. Signed
cache publication and exact NAR-fingerprint Ed25519 verification then passed.
Independent fresh Dungarees substitution, full NAR contents and whole-artifact
hashes then passed; source selection pins those exact reviewed bytes. Deployment
was subsequently observed healthy at `132bc28b5`. Fresh run `103842` then
completed create/readiness, strict personal-account CLI SSH with exact
Win32NT/Server 2025 build 26100, stop with an independent stopped checkpoint,
restart, repeated strict SSH and completed deletion. The matrix review
binds its immutable receipts and preserves the original warning-only refusal;
only the exact stock Windows OpenSSH warning is classified as expected.
This closes that exact-image CLI lifecycle gap. It does not establish terminal,
executor, workspace, growth, isolation or crash-supervision acceptance, and this
record remains proposed/partial.

The editor target-boundary evaluation
([`editor-target-boundaries.nix`](../../../nix/verification/tests/evaluation/editor-target-boundaries.nix))
asserts that the reviewed editor and broker metadata target only
`x86_64-linux`, and that the Windows v5 package has neither an editor field nor
an editor capability. This is static artifact evidence; it does not implement a
Windows editor, broker, browser origin or browser acceptance. The explicit
`editor: false` row therefore remains the accepted Windows boundary.

The Windows editor bring-up is staged, fail-closed material rather than a
capability promotion. [`windows-runtime.nix`](../../../nix/domains/artifacts/vscode-web/windows-runtime.nix)
builds pinned Windows Node and ripgrep payloads with `editorCapability = false`
and no store references. [`windows-source.nix`](../../../nix/domains/artifacts/vscode-web/windows-source.nix)
assembles pinned Code OSS source inputs, Windows headers and language adapters
for a later native build; its release identity includes those inputs, patches
and build scripts, while its payload remains editor-disabled. The runtime and
static boundary evaluations passed, but no completed native Windows bundle or
browser run is recorded here.

The portable broker model in
[`windows_model.rs`](../../../nix/domains/artifacts/vscode-web-broker/src/windows_model.rs)
binds a worker to the validated boot, descriptor, placement, epoch, roster UID,
GuestAccount UUID, local SAM SID and origin. It derives names from that identity,
rejects foreign or incomplete process/pipe custody, refuses ambiguous Windows
paths, and preserves owned workers across broker restart. The Win32 launcher in
[`windows/`](../../../nix/domains/artifacts/vscode-web-broker/src/windows/mod.rs)
uses S4U account tokens, profile-backed paths, SYSTEM-owned jobs and exact
process/PID-time/SID/executable/pipe checks; `windows_main.rs` obtains MMDS
identity, runs the reviewed authorizer, serializes one account startup and
adopts only a matching receipt. These are source and portable-model boundaries:
the broker has no admitted image, native Windows listener execution or browser
acceptance. The broker library's 22 Linux tests and clippy check passed; the
final Windows-target link, VM journey and browser proof remain open.

The Windows roster authorizer now shares `C:\overalls\ssh\accounts.lock`
with the roster daemon and verifies the exact username/UID pair before account
mutation. This closes a concurrent-authorizer race in the Windows source path;
it does not widen the guest capability table or establish a native editor run.

## Open questions

- Whether an S4U network logon of a roster account (a member of
  Administrators) yields the full, elevated token roster users expect inside
  a ConPTY session, and whether its window station is usable; the machine
  test covers `root` and the refusal path only, so a roster-user terminal is a
  manual fleet proof (gate 4).
- Whether Task Scheduler's restart-on-failure restarts an agent that exits
  with an error status, or whether an SCM service host is needed (decision 8).
- Allocated-bytes template accounting and hole-aware hashing for sparse
  images, which would let the Windows template become standby-eligible.
- A Windows browser editor remains outside this decision. Any proposal must add
  a reviewed Windows image/editor package, agent and protocol contract, broker
  admission and native browser sign-in/edit/readback/recovery evidence before
  changing the capability table. [ADR-0200](0200-windows-browser-editor-candidate.md)
  accepts that candidate in the separate `windows-editor-v1` namespace without
  activating supersession or changing the existing false editor capability.

## Related decisions

- [ADR-0169](0169-firmware-booted-windows-guests.md) firmware-booted Windows
  guests; its serial-login gap closes with gate 3.
- [ADR-0170](0170-lilly-firmware-guest-launch.md) firmware guest launch
  without agents; clauses 3, 4 and 6 are replaced by decisions 2, 3 and 5.
- [ADR-0113](0113-guest-trust-at-boot.md) boot-bound trust delivery.
- [ADR-0128](0128-repository-launch-links.md) repository launch links and
  workspace sources.
- [ADR-0146](0146-standby-guest-disks.md) standby guest disks.
- [ADR-0157](0157-multi-provider-authenticated-repository-launch.md) guest
  workspace clone.
- [ADR-0159](0159-remove-legacy-compatibility.md) converged pushes.
