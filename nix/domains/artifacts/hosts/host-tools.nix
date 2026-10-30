{ pkgs
  # The Buck2-built helper bundle (//lilly:host-helpers-import), when assembly
  # imports one; it then replaces every per-helper Nix build below.
, buck ? null
}:
let
  imageCopy = import ../guests/image-copy.nix { inherit pkgs; };
  hostd = import ./hostd.nix { inherit pkgs; };
  kvmProbe = import ./kvm-probe.nix { inherit pkgs; };
  launchGuard = import ./launch-guard.nix { inherit pkgs; };
  bootLog = import ../guests/boot-log.nix { inherit pkgs; };
  zfsNamespaceUnmount = import ../guests/zfs-namespace-unmount.nix { inherit pkgs; };
  sourceExport = import ../applications/source-export.nix { inherit pkgs; };
  transferStream = import ../infrastructure/transfer-stream.nix { inherit pkgs; };
  ingressBridge = import ../infrastructure/ingress-bridge.nix { inherit pkgs; };
  exportChannel = import ../applications/export-channel.nix { inherit pkgs; };
  resumeToken = import ./resume-token.nix { inherit pkgs; };
  flowLabel = import ../infrastructure/flow-label.nix { inherit pkgs; };
  vmWatch = import ./vm-watch.nix { inherit pkgs; };
in
# @cc [owner:ghuntley,label:deployment] host-helper-executable-set
# The assembly MUST deliver lilly-hostd, lilly-launch-guard, lilly-boot-log,
# lilly-kvm-probe, lilly-transfer-stream, lilly-ingress-bridge, lilly-source-export,
# lilly-export-channel, lilly-resume-token, lilly-flow-label, lilly-vm-watch and
# lilly-zfs-namespace-unmount as executables under bin, matching Lilly's runtime
# lookups. Each is a separately gated Rust derivation; the assembly installs
# symlinks only, and building an empty or unexpected utility MUST fail the
# hostTools evaluation by construction of the fixed list.
pkgs.symlinkJoin {
  name = "lilly-host-tools";
  paths = if buck != null then [ buck ] else
    [ imageCopy hostd kvmProbe launchGuard bootLog zfsNamespaceUnmount sourceExport transferStream ingressBridge exportChannel resumeToken flowLabel vmWatch ];
  postBuild = ''
    # Fail loudly if any Rust derivation start deviating from the fixed names.
    expected="lilly-boot-log lilly-export-channel lilly-flow-label lilly-hostd lilly-image-copy lilly-ingress-bridge lilly-kvm-probe lilly-launch-guard lilly-resume-token lilly-source-export lilly-transfer-stream lilly-vm-watch lilly-zfs-namespace-unmount"
    actual=$(${pkgs.findutils}/bin/find $out/bin -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    expected=$(echo $expected | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    [ "$actual" = "$expected" ]
  '';
}
