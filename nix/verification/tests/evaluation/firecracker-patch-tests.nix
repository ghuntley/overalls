{ pkgs, packages }:
# @cc [owner:ghuntley,label:verification] firecracker-patch-unit-tests
# The unit tests introduced or extended by the Overalls Firecracker patches MUST
# run against the patched vmm crate: PVH start info carries the RSDP address,
# the ACPI PM timer advances within 24 bits and refuses partial access, the
# legacy port manager registers the timer, the `hyperv` template installs
# the Hyper-V leaves while relocating the KVM leaves, the CMOS clock encodes
# the host time, the fixed firmware shutdown port
# signals exit only for the exact CloudHv byte request and rejects malformed
# writes through both the device and registered I/O bus, and the OmniOS serial
# sync marker signals that same exit event only after an exact split-safe match,
# a BAR reprogrammed by
# the guest moves on the MMIO bus with its queue notification ioeventfds, PCI configuration capability queue
# notifications signal only valid matching queue events, MSI-X capability and
# routing reset states agree and disabled MSI-X cannot inject queue interrupts,
# the block and net devices reset
# and re-activate, block requests spanning several descriptors are
# transferred whole by both I/O engines (the upstream parser, engine and
# property tests run again against the changed request shape), and the vsock
# device resolves indirect descriptor tables for RX and TX packets while
# refusing malformed or nested tables, and a File-backend snapshot restores into
# anonymous memory with exactly the file's bytes, populating only non-zero pages
# across regions and copy-chunk boundaries and refusing a short file (the
# upstream snapshot-file and discard tests run again against the copy). The nixpkgs
# package only
# runs the firecracker and jailer crate tests, so this derivation re-runs cargo
# on the vmm crate with those filters. KVM is needed for the legacy device test.
packages.vmm.overrideAttrs (previous: {
  pname = "firecracker-patch-tests";
  requiredSystemFeatures = [ "kvm" ];
  cargoTestFlags = [ "--package" "vmm" ];
  # Upstream MSI-X tests assert deltas in process-global metric counters.
  # Serialize this unit-test binary so other PCI tests cannot change a delta.
  dontUseCargoParallelTests = true;
  checkFlags = [
    "test_system_configuration"
    "acpi_pm_timer::tests"
    "test_register_legacy_devices"
    "test_apply_hyperv_leaves"
    "cmos_rtc::tests"
    "cloudhv_power::tests"
    "serial::tests::test_omnios_shutdown_marker_signals_after_split_output"
    "serial::tests::test_omnios_shutdown_marker_refuses_near_match"
    "test_native_uart_thre_enable_after_fifo"
    "bar_tests"
    "test_bar_relocation_follows_config_write"
    "test_bar_relocation_moves_notification_ioevents"
    "test_bar_relocation_defers_until_high_half"
    "test_hotplug_block"
    "test_queue_setup_in_init_status"
    "test_pci_configuration_notification"
    "msix::tests"
    "test_native_msix_disabled_refuses_queue_interrupt"
    "test_native_rx_reset_reuses_mapping_without_memfd"
    "test_reset_deactivates_and_allows_reinitialization"
    "rng::device::tests::test_reset_deactivates_and_allows_reinitialization"
    # The net variant of this test needs /dev/net/tun, which the sandbox lacks;
    # it is run outside the sandbox and recorded in the spike review.
    "block::virtio::device::tests::test_reset_returns_interrupt_and_deactivates"
    "test_reset_deactivates_and_allows_reinitialization"
    "test_parse_scatter_gather"
    "test_scatter_gather"
    "test_parse_generic"
    "test_parse_in"
    "test_parse_out"
    "test_parse_flush"
    "test_parse_get_id"
    "test_sync"
    "test_async"
    "parse_random_requests"
    "test_rx_packet_indirect_chain"
    "test_tx_packet_indirect_chain"
    "test_indirect_chain_refusals"
    "test_rx_packet_assembly"
    "test_tx_packet_assembly"
    "test_snapshot_file"
    "snapshot_file_copy_matches_file_and_populates_nonzero_pages"
    "test_discard_range_on_file"
  ];
  doInstallCheck = false;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    echo "vmm patch tests passed" > "$out/result"
    runHook postInstall
  '';
})
