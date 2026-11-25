{ pkgs, packages }:
# @cc [owner:ghuntley,label:verification] firecracker-vmm-identity-gate
# The patched VMM MUST still report upstream version 1.17.0, accept the
# `--enable-pci` flag, and remain a static x86-64 ELF pair named firecracker and
# jailer. A version drift or dynamic binary would break Lilly's running? check
# and its jail without any guest ever booting.
pkgs.runCommand "firecracker-vmm" {
  nativeBuildInputs = [ pkgs.binutils pkgs.file ];
} ''
  vmm=${packages.vmm}
  test -x "$vmm/bin/firecracker" && test -x "$vmm/bin/jailer"
  version="$("$vmm/bin/firecracker" --version | head -n 1)"
  echo "$version"
  [ "$version" = "Firecracker v1.17.0" ]
  "$vmm/bin/firecracker" --help | grep -q -- "--enable-pci"
  for binary in firecracker jailer; do
    readelf --file-header "$vmm/bin/$binary" | grep -q "Advanced Micro Devices X86-64"
    if readelf --program-headers "$vmm/bin/$binary" | grep -q "INTERP"; then
      echo "$binary is dynamically linked" >&2
      exit 1
    fi
  done
  # Every reviewed patch is recorded on the package and lives in nix/platform/patches.
  ${pkgs.lib.concatMapStringsSep "\n" (patch: "test -s ${patch}") packages.vmm.passthru.overallsPatches}
  touch "$out"
''
