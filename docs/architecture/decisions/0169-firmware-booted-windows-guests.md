# ADR-0169: Firmware-booted Windows guests under Firecracker

- ID: ADR-0169
- Date: 2026-10-13
- Status: proposed
- Implementation: partial
- Components: nix-packages, firecracker, guest-images
- Supersedes: none
- Superseded by: none

## Context

Every Overalls guest is a direct Linux boot: an uncompressed ELF kernel, its
initrd and a bare ext4 rootfs described by a version-4 manifest
([ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0068](0068-nix-built-ubuntu-guests.md)). Lilly launches these with
virtio-mmio devices and `pci=off`, and every guest-side service (readiness,
trust, terminals, workspace delivery) is a Linux program keyed on `lilly.*`
kernel command-line parameters.

The product needs a bootable **Windows** guest on the same Firecracker fleet.
Windows requires UEFI firmware, ACPI, PCI-attached virtio devices with the
signed virtio-win drivers, and a serial management console in place of a
display. Firecracker has no BIOS or UEFI loader; it boots an ELF payload
through the Linux 64-bit protocol or, since 1.12, through PVH, and since 1.13
offers an opt-in virtio-pci transport (`--enable-pci`).

Observed facts (verified against Firecracker 1.16.1 and edk2 202605 sources):

- edk2's `OvmfPkg/CloudHv/CloudHvX64.dsc` firmware is a PVH ELF with
  virtio-pci and serial-only console; Cloud Hypervisor boots Windows with it.
- Firecracker's PCI host bridge reports vendor `0x8086` device `0x0d57`, the
  `CLOUDHV_DEVICE_ID` the firmware keys its platform detection on, and it
  emulates the `0xCF8/0xCFC` configuration ports the firmware uses.
- Four platform-contract mismatches remained: Firecracker's PVH start info
  carried no RSDP address; the firmware busy-waits on an ACPI PM timer at I/O
  port `0x608` that Firecracker (hardware-reduced ACPI) did not emulate; the
  firmware's 32-bit PCI aperture `0xC0000000+0x38000000` covered Firecracker's
  MMCONFIG window at `0xDEC00000`; and Windows expects Hyper-V enlightenments
  (reference time, TSC page) that Firecracker never advertised and custom CPU
  templates could not add.
- The Windows Server 2025 evaluation ISO is a stable, hash-pinnable download
  from Microsoft's Evaluation Center (180-day licence, no account or key).

Assumptions: Windows Server 2025 Standard Core is the target edition; the
image is a spike for booting, not yet a Lilly-launchable guest family.

## Decision

1. **Patched static Firecracker.** `nix/domains/artifacts/infrastructure/firecracker.nix` applies eight
   reviewed patches to the pinned nixpkgs static Firecracker 1.16.1 and is the
   only VMM Lilly's release metadata and the development shell reference. The
   patches do not change the version string, `Cargo.toml` or `Cargo.lock`:
   `firecracker-pvh-rsdp-paddr` (PVH start info carries `RSDP_ADDR`),
   `firecracker-acpi-pm-timer` (read-only PM timer at port `0x608`, not
   advertised in the FADT), `firecracker-hyperv-cpuid` (custom CPU template
   field `hyperv` installs the Hyper-V CPUID leaves `0x40000000..=0x4000000a`,
   relocates the KVM signature leaves to `0x40000100` and completes
   `KVM_EXIT_HYPERV` exits instead of stopping the VM),
   `firecracker-pci-decode-enabled` (virtio-pci devices start with memory
   decoding and bus mastering on), `firecracker-cmos-rtc` (read-only CMOS
   clock at ports `0x70/0x71` following host UTC) and
   `firecracker-pci-bar-relocation` (a BAR sizing read keeps the read-only
   type bits, and the MMIO registration and queue doorbell ioeventfds follow a
   BAR the guest reprograms, so firmware may enumerate and assign the bus
   normally), `firecracker-virtio-reset` (virtio-blk and virtio-net
   implement device reset and the transport keeps its MSI-X object, so the
   operating system can re-initialize a device the firmware activated) and
   `firecracker-virtio-blk-sg` (block requests may spread their data over
   several descriptors; both I/O engines transfer every segment).
   [ADR-0171](0171-windows-guest-agents.md) adds a ninth,
   `firecracker-vsock-indirect-desc` (the vsock device walks the indirect
   descriptor tables the virtio-win viosock driver posts), under the same
   rules; this list is otherwise unchanged.
2. **CloudHv firmware as the PVH payload.** `nix/domains/artifacts/guest/windows/firmware.nix`
   builds `CLOUDHV.fd` from the pinned edk2 with one patch that ends the 32-bit
   PCI aperture at Firecracker's MMCONFIG base; bus enumeration and BAR
   assignment stay the firmware's normal behavior. Firecracker loads it through
   `boot-source.kernel_image_path`; there is no initrd and no boot argument.
3. **Offline Windows image build.** `nix/domains/artifacts/guest/windows/default.nix`
   installs Windows Server 2025 from the hash-pinned evaluation ISO
   (`iso.json`) inside a KVM Nix sandbox under QEMU/OVMF with restricted
   user networking, an answer file, the pinned virtio-win drivers and a
   post-setup script that enables EMS/SAC on COM1, disables sleep, Windows
   Update restarts, DHCP and IPv6, and powers off. The result is a sparse raw
   GPT disk plus the firmware and a **version-5 manifest** (`boot.kind =
   firmware`, `pci = true`, `root.format = raw-gpt`, `guest_agents = none`).
4. **Standalone launcher only.** `overalls-windows-boot` starts the patched
   Firecracker with `--enable-pci`, the firmware, a private disk copy and the
   Hyper-V template, with the serial console on the operator terminal. It is a
   spike tool: no jailer, no host network guard, not used by Lilly.
5. **Non-goals recorded.** At the time of this decision manifest v5 was not
   accepted by the protocol, Marshall or Lilly; snapshots, readiness, trust,
   terminals, workspace source, fleet catalog entry and Windows guest agents
   were follow-on decisions. Production images need licensed media swapped
   into `iso.json`. Correction (2026-10-14): manifest v5 admission, the Lilly
   launch path with MMDS identity and Marshall's capability gating are decided
   in [ADR-0170](0170-lilly-firmware-guest-launch.md); agents, the fleet
   catalog entry and template budgets remain open.

Authorization: the approved implementation plan of 2026-10-13 (bootable spike,
Server 2025, Nix/KVM build, patches on nixpkgs 1.16.1, ISO fetched from
Microsoft).

## Alternatives

- **Cloud Hypervisor instead of Firecracker.** Supports Windows out of the box
  but replaces the jailer, seccomp, snapshot and Lilly integration already
  built around Firecracker. Rejected for this product; kept as the fallback if
  Firecracker's PCI transport proves unfit.
- **Firmware embedded in Firecracker (a `--firmware` loader).** More invasive
  than reusing the PVH ELF path, which upstream already supports for kernels.
- **Patching the firmware's timer library instead of adding a PM timer.** A
  firmware-only fix leaves Windows without any ACPI timer; the PM timer device
  is also the smaller change and may serve Windows later.
- **Moving Firecracker's MMCONFIG instead of shrinking the firmware aperture.**
  Would change the memory layout seen by every existing Linux guest.
- **Firmware keeps the hypervisor-assigned BARs (`PcdPciDisableBusEnumeration`).**
  Tried first to avoid teaching Firecracker BAR relocation. edk2's scanning
  host bridge library only counts devices that already decode and sizes a
  64-bit BAR as 32-bit, and `PciBusDxe` asserts in that mode without a root
  bridge handle. Rejected: relocation in the VMM is the smaller and more
  general change, and Windows re-enumerates the bus anyway.
- **Hand-supplied ISO via `requireFile`.** Rejected by the user; a pinned
  `fetchurl` keeps the image an ordinary reproducible-input build.

## Consequences

- Linux guests see no behavior change: the PM timer is not in their ACPI
  tables, Hyper-V leaves require an explicit template field, and the RSDP
  address in PVH start info matches what the Linux boot path already set.
- Lilly's `vmm_version == "1.16.1"` check and static-binary checks remain
  valid because the version string is unchanged. The syscall surface changes
  in exactly one place: the vCPU thread's seccomp filter additionally allows
  the `KVM_IOEVENTFD` ioctl, which the BAR relocation uses to move queue
  doorbells (the VMM thread already allowed it for hotplug). The PM timer and
  CMOS clock read the clocks through the vDSO and add no syscalls.
- Windows installation is not byte-stable: every rebuild yields a new image
  identity. This is an explicit exception to the reproducibility goals of
  ADR-0011 and ADR-0154 and is recorded here.
- The build needs the `kvm` system feature on the builder and roughly 6 GiB of
  download plus 20 to 40 minutes of installation.
- A Windows image exposes an interactive SAC login on serial, unlike Linux
  guests (`no-serial-login-shell`). It stays a recorded security gap until
  Windows guest agents and roster integration exist.

## Invariants and verification

- The patched VMM reports `Firecracker v1.16.1`, lists `--enable-pci` and is a
  static x86-64 pair (`nix/verification/tests/evaluation/firecracker-vmm.nix`).
- The firmware is a single PVH ELF with a Xen note and the patched aperture
  (`postInstall` checks in `firmware.nix`; the `windows-firmware` check builds it).
- Image assembly is offline, KVM-sandboxed, modern-only virtio-pci, with EMS
  enabled and no autologon (`nix/verification/tests/evaluation/windows-guest.nix`).
- Booting the image under the patched Firecracker reaches the `SAC>` prompt
  (`nix/verification/tests/machines/windows-guest`, nested KVM, long-running).
- Firecracker unit tests for the patches (`nix/verification/tests/evaluation/firecracker-patch-tests.nix`):
  PVH start info carries the RSDP, the PM timer counter advances within 24
  bits and rejects partial access, the Hyper-V template installs the leaves
  and relocates the KVM leaves, the CMOS clock encodes the host time, a BAR
  sizing read returns the size mask with the 64-bit type bit, a BAR
  reprogrammed through config space moves on the MMIO bus together with its
  queue notification ioeventfds, block and net devices deactivate on reset
  and accept a second activation, and multi-descriptor block requests parse
  and transfer whole on both I/O engines.

Failure cases that would disprove the design: the firmware fails to find ACPI
tables; Windows refuses hardware-reduced ACPI; BAR assignment collides with
MMCONFIG; Windows timekeeping is unstable without synthetic timers.

## Implementation evidence

- Firecracker patches:
  [PVH RSDP address](../../../nix/platform/patches/firecracker-pvh-rsdp-paddr.patch),
  [ACPI PM timer](../../../nix/platform/patches/firecracker-acpi-pm-timer.patch),
  [Hyper-V CPUID leaves](../../../nix/platform/patches/firecracker-hyperv-cpuid.patch),
  [PCI decode enabled](../../../nix/platform/patches/firecracker-pci-decode-enabled.patch),
  [CMOS RTC](../../../nix/platform/patches/firecracker-cmos-rtc.patch),
  [BAR relocation](../../../nix/platform/patches/firecracker-pci-bar-relocation.patch),
  [virtio reset](../../../nix/platform/patches/firecracker-virtio-reset.patch) and
  [virtio-blk scatter-gather](../../../nix/platform/patches/firecracker-virtio-blk-sg.patch)
  and, from ADR-0171, [vsock indirect descriptors](../../../nix/platform/patches/firecracker-vsock-indirect-desc.patch),
  applied by the [patched VMM package](../../../nix/domains/artifacts/infrastructure/firecracker.nix)
  and unit-tested by [the patch test check](../../../nix/verification/tests/evaluation/firecracker-patch-tests.nix).
- Firmware patch:
  [MMIO aperture](../../../nix/platform/patches/edk2-cloudhv-firecracker-mmio-hole.patch),
  applied by the [firmware package](../../../nix/domains/artifacts/guest/windows/firmware.nix).
- Image: [builder](../../../nix/domains/artifacts/guest/windows/default.nix),
  [QEMU driver](../../../nix/domains/artifacts/guest/windows/install.py),
  [answer file](../../../nix/domains/artifacts/guest/windows/autounattend.xml),
  [post-setup script](../../../nix/domains/artifacts/guest/windows/SetupComplete.cmd),
  [ISO pin](../../../nix/domains/artifacts/guest/windows/iso.json),
  [launcher](../../../nix/domains/artifacts/guest/windows/boot.nix) and
  [directory contracts](../../../nix/domains/artifacts/guest/windows/CONTRACTS); wired in
  [the package set](../../../nix/domains/artifacts/default.nix), [devenv](../../../devenv.nix)
  and [the flake](../../../flake.nix).
- Checks: [VMM identity](../../../nix/verification/tests/evaluation/firecracker-vmm.nix),
  [builder rules](../../../nix/verification/tests/evaluation/windows-guest.nix),
  [SAC boot machine test](../../../nix/verification/tests/machines/windows-guest/default.nix),
  registered in [its suite's BUCK](../../../nix/verification/tests/machines/windows-guest/BUCK)
  and [outputs.nix](../../../nix/assemble/outputs.nix).
- Operator guide: [Windows guests](../../guests/windows-guests.md).
- Review: [Windows Firecracker spike review](../reviews/2026-10-13-windows-firecracker-spike.md)
  records which builds and boots were executed.

- Recorded execution of the `windows-guest` machine test (2026-10-14, nested
  KVM on the spike commit `66052b340`): firmware banner after 253 s of guest
  time, `SAC>` 6 s later, 274 s in total; see the
  [Windows Lilly launch review](../reviews/2026-10-14-windows-lilly-launch.md).

Remaining gaps: Windows guest agents and the fleet catalog entry. Manifest v5
admission and the Lilly launch path are decided and implemented under
[ADR-0170](0170-lilly-firmware-guest-launch.md).

## Open questions

- Whether Windows needs the synthetic timers (SynIC) in addition to the
  reference time counter; the spike advertises only MSRs KVM implements
  without extra capabilities.
- Whether a CMOS RTC at `0x70/0x71` is needed for stable guest time.
- Sparse-file preservation through `lilly-image-copy` and standby disks before
  any fleet use.

## Related decisions

- [ADR-0011](0011-nixos-guest-and-console.md) NixOS guest image and console.
- [ADR-0068](0068-nix-built-ubuntu-guests.md) Nix-built Ubuntu guests.
- [ADR-0016](0016-executable-generations-and-lifecycle.md) and
  [ADR-0098](0098-image-artifact-limits.md) image admission and limits.
- [ADR-0113](0113-guest-trust-at-boot.md) boot-bound trust delivery.
- [ADR-0154](0154-guest-boot-profile.md) guest boot profile.
- [ADR-0158](0158-durable-guest-identities.md) durable guest identities.
- [ADR-0170](0170-lilly-firmware-guest-launch.md) Lilly launches firmware-booted
  guests without guest agents (admits this image's manifest).
