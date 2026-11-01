{ packages, memoryMiB, diskMiB }:
{ config, lib, pkgs, ... }:
{
  system.stateVersion = "26.05";
  networking.hostId = "aabbccdd";
  boot.supportedFilesystems = [ "zfs" ];
  systemd.services.zfs-zed.enable = false;
  virtualisation.memorySize = memoryMiB;
  virtualisation.cores = 2;
  virtualisation.emptyDiskImages = [ diskMiB diskMiB ];
  # @cc [owner:ghuntley,label:verification] zfs-machine-requires-kvm
  # This check MUST fail without KVM; software emulation is not acceptance.
  virtualisation.qemu.forceAccel = lib.mkForce true;
  virtualisation.qemu.options = [ "-cpu host" ];
  environment.etc."zfs-fixture.exs".source = ../../../../lilly/scripts/zfs_fixture.exs;
  environment.etc."zfs-check.exs".source = ../machines/native-zfs/probe.exs;
  environment.etc."zfs-lifecycle.exs".source = ../machines/zfs-lifecycle/probe.exs;
  environment.etc."zfs-observation-fault".source = pkgs.writeShellScript "zfs-observation-fault" ''
    set -eu
    export ZFS_OBSERVATION_FAULT="$(cat /run/zfs-observation-fault-mode 2>/dev/null || true)"
    ${config.boot.zfs.package}/bin/zfs "$@"
    recursive=false
    for argument in "$@"; do
      if [ "$argument" = -r ]; then recursive=true; fi
    done
    if [ "$1" = list ] && $recursive && [ ! -e /run/zfs-observation-changed ]; then
      touch /run/zfs-observation-changed
      case "$ZFS_OBSERVATION_FAULT" in
        usage)
          ${pkgs.coreutils}/bin/dd if=/dev/urandom of=/pool/fixture-growth bs=1M count=4 conv=fsync status=none
          ;;
        quota)
          ${config.boot.zfs.package}/bin/zfs set quota=1G tank/lilly
          ;;
        child-identity)
          child=tank/lilly/vm-eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
          ${config.boot.zfs.package}/bin/zfs destroy "$child"
          ${config.boot.zfs.package}/bin/zfs create -o mountpoint=/pool/vms/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee "$child"
          ;;
        *) exit 1 ;;
      esac
      ${config.boot.zfs.package}/bin/zpool sync tank
    fi
  '';
  systemd.services.lilly-hostd.path = lib.mkBefore [
    (pkgs.writeShellScriptBin "zfs" ''
      exec /etc/zfs-observation-fault "$@"
    '')
  ];
  environment.etc."zfs-fault".source = pkgs.writeShellScript "zfs-fault" ''
    # lilly-hostd runs every utility with only PATH and LC_ALL, so the paused
    # operation travels through a file the driver writes, as the observation
    # fault mode does.
    ZFS_PAUSE_OPERATION="''${ZFS_PAUSE_OPERATION:-$(cat /run/zfs-pause-operation 2>/dev/null || true)}"
    if [ "$1" = destroy ] && [ "''${ZFS_PAUSE_OPERATION:-}" = unmount ]; then
      ${config.boot.zfs.package}/bin/zfs unmount "$2" || exit 1
      touch /run/zfs-operation-committed
      exec sleep 300
    fi
    ${config.boot.zfs.package}/bin/zfs "$@"
    result=$?
    if [ "$result" = 0 ] && [ "''${ZFS_PAUSE_OPERATION:-}" = "$1" ]; then
      touch /run/zfs-operation-committed
      exec sleep 300
    fi
    exit "$result"
  '';
  environment.etc."copy-fault".source = pkgs.writeShellScript "copy-fault" ''
    ZFS_PAUSE_OPERATION="''${ZFS_PAUSE_OPERATION:-$(cat /run/zfs-pause-operation 2>/dev/null || true)}"
    ${packages.lilly}/host-tools/bin/lilly-image-copy "$@"
    result=$?
    # Only the copy pauses; `identity` reads (Image.identities) share this
    # executable and precede it.
    if [ "$result" = 0 ] && [ "$1" != identity ] && [ "''${ZFS_PAUSE_OPERATION:-}" = cp ]; then
      touch /run/zfs-operation-committed
      exec sleep 300
    fi
    exit "$result"
  '';
  environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq
    (pkgs.writeShellScriptBin "zfs-check" ''
      export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
      export ERL_FLAGS="+S 2:2"
      export RELEASE_COOKIE="isolated-zfs-test-cookie"
      export RELEASE_DISTRIBUTION="none"
      export RELEASE_TMP="/run/zfs-release"
      mkdir -p "$RELEASE_TMP"
      export ZFS_CHECK="$1"
      export ZFS_PATH="''${2:-/pool}"
      exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/zfs-check.exs")'
    '')
    (pkgs.writeShellScriptBin "zfs-lifecycle" ''
      export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
      if [ "''${ZFS_FAULT:-}" = 1 ]; then export PATH="/run/zfs-fault/bin:$PATH"; fi
      export ERL_FLAGS="+S 2:2"
      export RELEASE_COOKIE="isolated-zfs-lifecycle-cookie"
      export RELEASE_DISTRIBUTION="none"
      export RELEASE_TMP="/run/zfs-release"
      mkdir -p "$RELEASE_TMP"
      export ZFS_ACTION="$1"
      export ZFS_VM="''${2:-1}"
      export ZFS_GUEST_IMAGE="${packages.guest}"
      exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/zfs-lifecycle.exs")'
    '')
  ];
}
