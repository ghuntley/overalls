{ pkgs, vmm }:
# @cc [owner:ghuntley,label:isolation] windows-boot-firmware-only
# overalls-windows-boot MUST start the patched Firecracker with `--enable-pci`,
# the image's `firmware` as `kernel_image_path`, no initrd and no kernel
# command line, the Hyper-V CPU template, a private copy of `disk.raw` as the
# only root drive and one vsock device (guest CID 3) whose Unix socket is
# `WORK_DIR/v.sock`. It is an operator spike tool: it runs without the jailer,
# without the host network guard and MUST NOT be used by Lilly.
pkgs.writeShellApplication {
  name = "overalls-windows-boot";
  runtimeInputs = [ vmm pkgs.coreutils pkgs.iproute2 pkgs.jq ];
  text = ''
    usage() {
      echo "usage: overalls-windows-boot IMAGE_DIR WORK_DIR [MEM_MIB] [VCPUS]" >&2
      echo "  IMAGE_DIR holds firmware, disk.raw and manifest.json (tools/buck2 build //:package-guest-windows)" >&2
      echo "  WORK_DIR receives the writable disk copy, the Firecracker config and API socket" >&2
      echo "  Serial console (Windows EMS/SAC) is this terminal; needs root for the tap device" >&2
      exit 64
    }
    [ "$#" -ge 2 ] || usage
    image="$(realpath "$1")"
    work="$2"
    mem_mib="''${3:-4096}"
    vcpus="''${4:-2}"
    tap="''${OVERALLS_WINDOWS_TAP:-fcwin0}"
    mkdir -p "$work"
    work="$(realpath "$work")"

    for artifact in firmware disk.raw manifest.json; do
      [ -e "$image/$artifact" ] || { echo "missing $image/$artifact" >&2; exit 65; }
    done
    kind="$(jq -r '.boot.kind' "$image/manifest.json")"
    [ "$kind" = firmware ] || { echo "manifest boot.kind is $kind, expected firmware" >&2; exit 65; }

    if [ ! -e "$work/disk.raw" ]; then
      echo "copying disk template (sparse, reflink when possible)" >&2
      cp --sparse=always --reflink=auto "$image/disk.raw" "$work/disk.raw"
      chmod u+w "$work/disk.raw"
    fi

    if ! ip link show "$tap" > /dev/null 2>&1; then
      ip tuntap add dev "$tap" mode tap
      ip addr add 172.16.0.1/30 dev "$tap"
      ip link set "$tap" up
    fi

    rm -f "$work/v.sock"
    jq -n \
      --arg firmware "$image/firmware" \
      --arg disk "$work/disk.raw" \
      --arg tap "$tap" \
      --arg vsock "$work/v.sock" \
      --argjson vcpus "$vcpus" \
      --argjson mem "$mem_mib" \
      '{
        "boot-source": { kernel_image_path: $firmware },
        drives: [{
          drive_id: "root", path_on_host: $disk, is_root_device: true,
          is_read_only: false, cache_type: "Writeback", io_engine: "Sync"
        }],
        "machine-config": { vcpu_count: $vcpus, mem_size_mib: $mem, smt: false },
        "cpu-config": { hyperv: true },
        "network-interfaces": [{ iface_id: "eth0", host_dev_name: $tap, guest_mac: "AA:FC:00:00:00:01" }],
        "mmds-config": { version: "V2", network_interfaces: ["eth0"] },
        vsock: { guest_cid: 3, uds_path: $vsock }
      }' > "$work/firecracker.json"

    # Unix socket paths are limited to 107 bytes, so the API socket lives in a
    # short temporary path rather than beside a possibly deep work directory.
    api_sock="$(mktemp -u "''${TMPDIR:-/tmp}/overalls-windows-XXXXXX.sock")"
    rm -f "$api_sock"
    echo "$api_sock" > "$work/api.sock.path"
    # Firecracker's own log and metrics stay beside the disk copy so unhandled
    # guest accesses and device errors can be read after the session.
    : > "$work/firecracker.log"
    : > "$work/metrics.json"
    level="''${OVERALLS_WINDOWS_LOG_LEVEL:-Info}"
    echo "booting $image with $vcpus vCPU, $mem_mib MiB; serial console follows (SAC> expected)" >&2
    echo "firecracker log: $work/firecracker.log (level $level), metrics: $work/metrics.json, vsock: $work/v.sock" >&2
    exec firecracker --enable-pci --api-sock "$api_sock" --config-file "$work/firecracker.json" \
      --log-path "$work/firecracker.log" --level "$level" --show-level --show-log-origin \
      --metrics-path "$work/metrics.json"
  '';
}
