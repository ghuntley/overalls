# ADR-0170: Lilly launches firmware-booted guests without guest agents

- ID: ADR-0170
- Date: 2026-10-14
- Status: proposed
- Implementation: partial
- Components: Protocol, Lilly, Marshall, nix-packages, guest-images
- Supersedes: none
- Superseded by: none

[ADR-0171](0171-windows-guest-agents.md) (proposed) amends decision clauses 3,
4 and 6 for guests with the `windows-v1` agent set; the agentless `none`
branch of every clause stands. The reciprocal supersession links are
activated when ADR-0171 is accepted.

## Context

[ADR-0169](0169-firmware-booted-windows-guests.md) produced a Windows Server
2025 image that boots under the patched Firecracker to the serial Special
Administration Console, described by a version-5 manifest that nothing admitted:
the protocol validated version 4 only, Lilly's image, template, disk, bundle,
jail, unit and driver code named `kernel`, `initrd` and `rootfs.ext4` directly,
boot identity reached a guest only on the kernel command line, and every
readiness, trust, terminal and workspace path assumed the Linux agents over
vsock. Marshall gated nothing on the agent set an image carries: only the
browser editor was derived from the manifest.

Verified facts that shape this decision:

- Firecracker 1.16.1 accepts `cpu-config` as an inline custom template and
  `mmds-config` inside `--config-file`, and `--metadata <file>` loads the MMDS
  data store inside `VmResources::from_json`, before the guest runs. Identity
  can therefore be bound to the durable boot record before launch with no API
  call after start.
- Frames for the MMDS address (`169.254.169.254`, ARP and IPv4) are answered
  inside the VMM and never reach the tap, so Lilly's nftables source guard is
  untouched and the guest's source address during bootstrap is irrelevant.
- The built image's firmware is 4 MiB and its root a 32 GiB sparse GPT disk
  whose `C:` is the last partition, so a host-side extension can be adopted by
  the guest.
- Under Firecracker the virtio NIC is a different plug-and-play instance than
  the one Windows saw during installation, so no per-adapter setting survives;
  the guest must configure whatever adapter it finds.
- Every Lilly must understand the new manifest and bundle shapes before a
  firmware placement exists: relocation destinations adopt purely from the
  streamed bundle and clones copy the bundle files
  ([ADR-0159](0159-remove-legacy-compatibility.md) ordering).

Authorization: the user's decision of 2026-10-14 to implement Phase 2 (manifest
admission, Lilly launch with MMDS identity, a PowerShell bootstrap in the image,
Marshall capability gating) on the spike branch, with no Rust Windows agents,
no fleet catalog entry and no merge until the phase is complete.

## Decision

1. **Manifest version 5 and bundle version 2 are admitted as additions, not
   replacements.** `OverallsProtocol.ImageManifest.validate/1` accepts exactly
   the eight-key firmware shape (`boot.kind = firmware`, `pci = true`, one
   firmware descriptor bounded at 64 MiB, `root.format = raw-gpt` with the
   128 GiB root bound, `guest_agents = none`, the minima, a null workspace
   source version; no editor, no boot arguments, no display name) and derives
   the identity from the ordered array tagged `lilly-image-v5`, pinned by an
   independently computed test vector beside the version-4 pin. Both results
   carry `boot_kind`, `root_format` and `guest_agents` so consumers branch on
   the validated manifest, never on file names. `OverallsProtocol.WorkloadBundle`
   gains the seven-key version-2 firmware bundle; version-1 encoding stays
   byte-identical. Artifact file names come from one protocol authority:
   `artifact_files/1`, `boot_artifacts/1`, `root_artifact/1`, `file_names/1`
   and `file_sets/0`.
2. **The pool-side root drive slot stays `rootfs.ext4` for every image.** It is
   part of dataset content identity, relocation reception, clone file sets,
   jail mounts and standby disks; the image-side artifact (`rootfs.ext4` or
   `disk.raw`) is mapped onto it by `Lilly.Host.Image.root_artifact/1`. Disk
   extension remains a truncate, which is GPT-safe; the guest grows its own
   partition.
3. **Firmware jails boot over virtio-pci with identity in MMDS.** For a
   firmware bundle `Lilly.VM.Jail.prepare/4` bind-mounts only `firmware`
   read-only, writes a root-owned read-only `metadata.json` holding exactly
   the identity a kernel guest receives on its command line (placement,
   execution epoch, boot challenge, IPv4) plus the static facts a firmware
   guest cannot derive (prefix length 32, gateway, MAC) under a versioned
   `lilly` key and never the generation (which advances without a reboot), and
   writes a Firecracker configuration with `kernel_image_path = /firmware`, no
   initrd or boot arguments, `cpu-config.hyperv = true`, MMDS V2 on `eth0` and
   no vsock device. `Lilly.VM.Unit` appends `--enable-pci` and
   `--metadata /metadata.json` only for firmware bundles; the kernel argument
   list is pinned unchanged.
   *Superseded in part by [ADR-0171](0171-windows-guest-agents.md) decision 2:
   a firmware bundle whose agent set speaks the vsock protocols
   (`windows-v1`) gets the jail-local vsock endpoint; the agentless
   configuration stays exactly as written here.*
4. **Guests without agents are running, never ready.** `Driver.guest_agents/2`
   reads the agent set from the placement's durable bundle. For `none`,
   `Driver.trust/4` persists a `skipped` trust receipt bound to the exact boot
   instead of delivering trust material; the executor calls
   `Driver.unattested/4`, which advances provisioning to the new terminal
   `unattested` phase (a challenge, never a boot UUID, and no path to `ready`),
   and reports `running` without a `guest_ready` fact. `Driver.ready/4`,
   terminal options and workspace source delivery refuse; `Driver.start/5`
   refuses the Inception profile before any host effect.
   *Superseded in part by [ADR-0171](0171-windows-guest-agents.md) decisions 1
   and 3: the driver now branches on `OverallsProtocol.GuestAgents`
   capabilities, so a `windows-v1` guest receives trust, is observed for
   readiness within its own budget and may open terminals and receive
   workspace sources; `none` behaves exactly as written here.*
5. **The Windows image bootstraps itself from MMDS.** A SYSTEM scheduled task
   (`overalls-bootstrap.ps1`, registered by `SetupComplete.cmd`) runs at every
   boot: it reaches MMDS over a temporary link-local address when the stack has
   none, obtains a V2 session token, fetches `/lilly`, validates every field
   (including that the MAC is the adapter's), applies exactly the delivered
   `/32` with an on-link route to the gateway and a default route through it,
   keeps DHCP and IPv6 off, grows `C:` into host-added space, records the
   applied identity under `C:\overalls\network` and never logs the token or the
   challenge. The Administrator credential, EMS and SAC are untouched; the
   serial login remains the recorded gap of ADR-0169.
6. **Marshall derives a guest-agents capability and refuses what it cannot
   serve.** `Marshall.Compute.Image.guest_agents_capability/1` mirrors the
   editor capability; views expose a finite `guest_agents_status`
   (`available`, `none`, `unavailable`). Presentation hides Terminal, Agents,
   the editor control and SSH connection commands for agentless images and
   explains why; independently, terminal authority, agent model calls, the
   agent executor binding and web search refuse, admission refuses the
   Inception profile for such an image, and provisioning admits only the
   physical service level (creation-to-ready can never be met without
   `guest_ready`). The Windows image stays out of `fleet/guest-images.nix`;
   staging and registration are operator actions after convergence.
   *Superseded in part by [ADR-0171](0171-windows-guest-agents.md) decision 5:
   the binary `guest_agents_status` is replaced by per-capability booleans
   (`Image.guest_capabilities/1`), and each surface keys on its own
   capability; the refusals described here are the `none` row of that table.*
   *Later admission restriction: [ADR-0198](0198-git-attribution-and-guest-identity.md)
   and [ADR-0204](0204-git-attribution-and-guest-identity.md) require explicit Git
   identity support for every new machine. Agentless manifests cannot advertise
   that support, so current Marshall refuses their admission before allocation;
   the physical-only path remains relevant to retained executions and Lilly-only
   fixtures, not new agentless machines.*
7. **Rollout ordering.** Protocol, Lilly and Marshall land together with no
   Windows image staged; every host converges; only then may an operator stage
   the image in `services.lilly.images` and register it. An old Lilly fails
   closed on a firmware bundle (relocation or clone), which is why the
   converged push precedes any placement.

## Alternatives

- **Deliver identity through `PUT /mmds` after start.** Needs a new API client
  path and a window between start and delivery; `--metadata` binds the file to
  the boot before launch and is cleaned with the jail. Rejected.
- **Rename the pool-side root file to `disk.raw` for firmware images.** Touches
  dataset identity, relocation and clone allowlists and standby disks across
  hosts; a storage-format migration for no functional gain. Rejected.
- **Report `guest_ready` from the host-side reachability probe.** A ping from
  the host is not the guest's own readiness proof and would let Marshall's
  SSH service levels count an unprovable fact. Rejected; the `unattested`
  phase is honest about what is known.
- **Hide the controls in the UI only.** Presentation is not authority; the
  terminal, agent and SSH refusals exist server-side as well.
- **Keep the display name in the manifest.** The version-4 shape has none and
  Marshall names images at registration; a ninth key would only widen the
  identity. The Nix builder drops it.

## Consequences

- Linux guests see no behaviour change: version-1 bundle encoding, the kernel
  jail configuration and the kernel unit argument list are pinned by tests;
  `--enable-pci` and MMDS exist only for firmware bundles; the cleanup
  allowlist and template file sets are supersets.
- A Windows VM in Marshall shows Settings and Access only; its state is
  `running` with no readiness, and SSH, terminals and agents are refused until
  Windows guest agents exist (Phase 3). Service-level measurements for such
  VMs cover physical running within the deadline only.
- The MMDS document exposes to the guest exactly what the kernel command line
  exposes to Linux guests plus the gateway and MAC it can see anyway.
- The agent set is a bundle fact: restart and adoption decide trust, readiness
  and terminals from the same durable record as the launch.

## Invariants and verification

- Version-4 and version-5 identities never collide and are pinned by
  independent vectors (`protocol/test/image_manifest_test.exs`); version-1
  bundle encoding is pinned (`protocol/test/workload_bundle_test.exs`).
- Kernel bundles produce an unchanged jail configuration and unit argument
  list; firmware bundles add exactly the PCI transport and the metadata file
  (`lilly/test/vm/jail_test.exs`, `lilly/test/vm/unit_metadata_test.exs`).
- `unattested` follows `awaiting_trust` only, carries no boot UUID and cannot
  become `ready`; `skipped` trust is terminal
  (`lilly/test/lifecycle/provisioning_test.exs`, `guest_trust_test.exs`,
  `lilly/test/vm/provisioning_test.exs`).
- A firmware image loads with exactly `firmware`, `disk.raw` and the manifest
  (`lilly/test/host/image_test.exs`).
- The original agentless Marshall admission measured only the physical service
  level; the [2026-10-14 review](../reviews/2026-10-14-windows-lilly-launch.md)
  retains that historical scope. Under ADR-0198/0204, the current
  [admission test](../../../marshall/test/marshall/compute/image_admission_test.exs)
  instead requires agentless Git capability refusal with no allocation, and
  physical plus readiness measurements for a Git-capable `windows-v1` image.
  The [2026-10-19 focused execution](../reviews/2026-10-19-localization-feature-catalogs.md)
  passed this admission suite; its BEAM fixture does not establish current native
  firmware launch acceptance. Capability and hidden-control tests remain in
  `image_guest_agents_capability_test.exs` and
  `marshall/test/marshall_web/editor_workspace_test.exs`.
- The image carries the bootstrap task and an eight-key manifest
  (`nix/verification/tests/evaluation/windows-guest.nix`).
- The Lilly-mode machine test places the image through the real driver on
  nested KVM: firmware bundle on the dataset, skipped trust, `unattested`
  provisioning, the SAC prompt on the boot log, the guest's bootstrap log and
  applied identity read from the EFI system partition of the live disk without
  a login, and reachability of the delivered `/32` through a test-only accept in
  the host policy for that address (Lilly's host policy otherwise drops every
  unmarked host-to-guest and guest-to-host packet; the per-tap guard stays
  intact and its accept counter proves the guest sends from its assigned MAC
  and address) (`nix/verification/tests/machines/windows-lilly-guest`).

Failure cases that would disprove the design: the guest cannot reach MMDS from
a link-local address; Windows refuses the on-link gateway route; the sparse
template materializes as full-size pool usage; an old Lilly accepts a firmware
bundle.

## Implementation evidence

- Protocol: [image manifest](../../../protocol/lib/overalls_protocol/image_manifest.ex),
  [workload bundle](../../../protocol/lib/overalls_protocol/workload_bundle.ex).
- Lilly: [image](../../../lilly/lib/lilly/host/image.ex),
  [image template](../../../lilly/lib/lilly/host/image_template.ex),
  [workload bundle](../../../lilly/lib/lilly/vm/workload_bundle.ex),
  [jail](../../../lilly/lib/lilly/vm/jail.ex), [unit](../../../lilly/lib/lilly/vm/unit.ex),
  [driver](../../../lilly/lib/lilly/vm/driver.ex), [executor](../../../lilly/lib/lilly/vm/executor.ex),
  [provisioning](../../../lilly/lib/lilly/vm/provisioning.ex) and the
  [provisioning](../../../lilly/lib/lilly/lifecycle/provisioning.ex) and
  [guest trust](../../../lilly/lib/lilly/lifecycle/guest_trust.ex) lifecycles.
- Marshall: [image](../../../marshall/lib/marshall/compute/image.ex),
  [images](../../../marshall/lib/marshall/compute/images.ex),
  [views](../../../marshall/lib/marshall/compute/views.ex),
  [admission](../../../marshall/lib/marshall/compute/admission.ex),
  [service-level admission](../../../marshall/lib/marshall/compute/service_level_admission.ex),
  [terminal authority](../../../marshall/lib/marshall/terminal/authority.ex),
  [workspace components](../../../marshall/lib/marshall_web/components/workspace_components.ex).
- Image: [bootstrap script](../../../nix/domains/artifacts/guest/windows/overalls-bootstrap.ps1),
  [post-setup script](../../../nix/domains/artifacts/guest/windows/SetupComplete.cmd),
  [builder](../../../nix/domains/artifacts/guest/windows/default.nix),
  [directory contracts](../../../nix/domains/artifacts/guest/windows/CONTRACTS).
- Checks: [Lilly-mode machine test](../../../nix/verification/tests/machines/windows-lilly-guest/default.nix)
  registered in [its suite's BUCK](../../../nix/verification/tests/machines/windows-lilly-guest/BUCK).
- Review: [Windows Lilly launch review](../reviews/2026-10-14-windows-lilly-launch.md)
  records which suites and machine tests were executed.

Remaining gaps: Windows guest agents (readiness, trust, SSH roster, terminals),
a fleet catalog entry and standby or template budgets for a 32 GiB template,
DNS for Windows guests, and the merge and converged rollout themselves.

## Open questions

- Whether any host-side observation of the `/32` should feed Marshall before
  Windows agents exist; today the host policy deliberately drops unmarked
  traffic to and from a Customer guest, and the machine test's probe is a
  test-only allowance, not a product path.
- Whether `C:` growth after a host-side extension needs a reboot or happens on
  the next bootstrap run (the machine test records only that the guest still
  boots after an extension).

## Related decisions

- [ADR-0169](0169-firmware-booted-windows-guests.md) firmware-booted Windows
  guests (the spike this decision makes launchable).
- [ADR-0011](0011-nixos-guest-and-console.md) and
  [ADR-0016](0016-executable-generations-and-lifecycle.md) guest images and
  execution lifecycle.
- [ADR-0098](0098-image-artifact-limits.md) image artifact limits.
- [ADR-0113](0113-guest-trust-at-boot.md) boot-bound trust delivery.
- [ADR-0130](0130-verified-provisioning-fastpath.md) verified provisioning fast path and sealed templates.
- [ADR-0154](0154-guest-boot-profile.md) guest boot profile.
- [ADR-0158](0158-durable-guest-identities.md) durable guest identities.
- [ADR-0159](0159-remove-legacy-compatibility.md) converged pushes.
