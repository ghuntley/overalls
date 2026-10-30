{ pkgs }:
let
  # @cc [owner:ghuntley,label:build] firecracker-patches-keep-upstream-identity
  # vmm MUST be the pinned nixpkgs static Firecracker 1.16.1 with only the
  # patches listed here applied. Patches MUST NOT change the crate version
  # string, Cargo.toml or Cargo.lock: Lilly matches `vmm_version` exactly and
  # the vendored dependency hash is keyed on the unpatched source.
  patches = [
    # @cc [owner:ghuntley,label:recovery] snapshot-block-barrier-before-publication
    # A failed asynchronous block drain/flush MUST terminate the VMM before
    # memory/device snapshot publication, never become a successful API reply.
    ../../../platform/patches/firecracker-snapshot-block-barrier.patch
    # @cc [owner:ghuntley,label:capacity;isolation] snapshot-restore-anonymous-memory
    # A File-backend snapshot load MUST copy the memory file into anonymous
    # private guest memory, never map it, so restored RAM is charged to the VM
    # cgroup at most once per guest page and a later checkpoint cannot fault
    # file page cache into that cgroup (ADR-0266). All-zero pages stay
    # unpopulated; a short memory file is refused.
    ../../../platform/patches/firecracker-snapshot-anonymous-restore.patch
    # PVH start info carries the ACPI RSDP address (ADR-0169). Firmware
    # payloads such as edk2 CloudHv find the tables only through this field.
    ../../../platform/patches/firecracker-pvh-rsdp-paddr.patch
    # Read-only ACPI PM timer at I/O port 0x608; CloudHv firmware busy-waits on
    # it for every delay and has no fallback timer.
    ../../../platform/patches/firecracker-acpi-pm-timer.patch
    # Opt-in Hyper-V enlightenment CPUID leaves via the custom CPU template
    # field `hyperv`; Windows uses the KVM reference time and TSC page.
    ../../../platform/patches/firecracker-hyperv-cpuid.patch
    # virtio-pci devices come up with memory decoding and bus mastering
    # enabled: Firecracker pre-assigns BARs and cannot relocate them, and the
    # firmware's BAR scan only counts devices that already decode.
    ../../../platform/patches/firecracker-pci-decode-enabled.patch
    # Read-only CMOS real-time clock at ports 0x70/0x71 following host UTC:
    # edk2's PcRtc asserts without it and Windows reads its wall clock there.
    ../../../platform/patches/firecracker-cmos-rtc.patch
    # edk2 CloudHv ResetShutdown writes one byte (0x34) to port 0x600 after the
    # native OS syncs its disks. Route that exact request to the VMM exit event.
    ../../../platform/patches/firecracker-cloudhv-poweroff.patch
    # OmniOS emits a fixed filesystem-sync marker before its firmware reboot prompt;
    # signal the same VMM exit event after that marker is written so clean shutdown
    # does not require an interactive console key.
    ../../../platform/patches/firecracker-omnios-serial-shutdown.patch
    # Exercise the pinned UART dependency through its production public API.
    ../../../platform/patches/firecracker-uart-thre-tests.patch
    # Guest-initiated BAR relocation: the MMIO bus follows a BAR the firmware
    # or OS reprograms (MMIO registration and queue doorbell ioeventfds), and a
    # sizing read keeps the 64-bit type bits, so edk2 can enumerate the bus
    # normally.
    ../../../platform/patches/firecracker-pci-bar-relocation.patch
    # Firmware configures virtio queues while the device is still in INIT;
    # retain those queue addresses until the guest completes feature negotiation.
    ../../../platform/patches/firecracker-virtio-init-queue.patch
    # CloudHv firmware uses the PCI configuration capability for queue kicks.
    # Those writes bypass MMIO ioeventfds and must signal the same queue event.
    ../../../platform/patches/firecracker-pci-config-notify.patch
    # Guest-visible MSI-X enable/function-mask reset bits match internal state.
    # illumos conditionally enables MSI-X; a pre-enabled capability otherwise
    # leaves the VMM's interrupts disabled and first block I/O waiting forever.
    ../../../platform/patches/firecracker-msix-reset-state.patch
    # virtio-blk and virtio-net implement device reset, so a device the
    # firmware activated can be re-initialized by the operating system.
    ../../../platform/patches/firecracker-virtio-reset.patch
    # Network reset runs under the vCPU seccomp filter. Retain its existing
    # receive mapping rather than attempting forbidden memfd allocation.
    ../../../platform/patches/firecracker-net-reset-reuse.patch
    # virtio-blk requests may spread their data over several descriptors
    # (Windows viostor uses one per physical page); both I/O engines transfer
    # every segment, io_uring through vectored operations.
    ../../../platform/patches/firecracker-virtio-blk-sg.patch
    # The vsock device walks indirect descriptor tables (ADR-0171): the
    # virtio-win ring library places every multi-descriptor buffer in one
    # whenever the driver holds a table, negotiated or not, and viosock does so
    # for each packet. The feature is still not offered, so Linux guests keep
    # their direct chains.
    ../../../platform/patches/firecracker-vsock-indirect-desc.patch
    # Reset the vsock backend at guest shutdown, reusing its preallocated packet
    # ring storage so the vCPU seccomp filter never needs memfd_create during reset.
    ../../../platform/patches/firecracker-vsock-reset.patch
    # Reset the entropy backend at guest shutdown, reusing its preallocated iovec
    # storage so the vCPU seccomp filter never needs memfd_create during reset.
    ../../../platform/patches/firecracker-rng-reset.patch
  ];
  # Applied to the pinned writable Cargo vendor copy, preserving Cargo metadata.
  uartPatch = ../../../platform/patches/firecracker-uart-thre-enable.patch;
in
{
  # @cc [owner:ghuntley,label:isolation] firecracker-static-pair
  # The result MUST stay a static musl x86-64 firecracker/jailer pair so Lilly's
  # jail chroot needs no host libraries (contract jailed-vmm-static-runtime).
  vmm = pkgs.pkgsStatic.firecracker.overrideAttrs (previous: {
    patches = (previous.patches or [ ]) ++ patches;
    postPatch = (previous.postPatch or "") + ''
      mapfile -t uart_sources < <(find "$cargoDepsCopy" -maxdepth 2 -type d -name vm-superio-0.8.1)
      test "''${#uart_sources[@]}" -eq 1
      patch -p1 -d "''${uart_sources[0]}" < ${uartPatch}
    '';
    passthru = (previous.passthru or { }) // { overallsPatches = patches ++ [ uartPatch ]; };
  });
}
