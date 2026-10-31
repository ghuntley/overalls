{ nixpkgs, modules, disko }:
let
  make = platform: firmware: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ modules.default (import ../../../../platform/hosts/profile.nix {
      host = import ./. { inherit platform firmware; }; diskoModule = disko.nixosModules.disko;
    }) ({ config, lib, extendModules, ... }: let
      # Diagnostics only, and only in the exported test images (fleet storage
      # images keep this configuration's closure): GRUB and the kernel also
      # write to the first serial port, which the machine-test driver logs.
      # The profile's EC2 lines already do this; tty0 stays a console for the
      # VGA screenshot.
      exported = (extendModules { modules = [ {
        boot.kernelParams = lib.mkIf (platform != "ec2") [ "console=tty0" "console=ttyS0,115200n8" ];
        boot.loader.grub.extraConfig = lib.mkIf (platform != "ec2") ''
          serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
          terminal_output console serial
        '';
      } ]; }).config;
    in {
      disko.memSize = 2048;
      disko.imageBuilder.imageFormat = "qcow2";

      # Disk-image building has no physical serial discovery. The fixture maps
      # declared identities onto the image builder's private virtual devices.

      disko.devices.disk = lib.mkMerge [
        (lib.genAttrs (if platform == "hetzner" then [ "system0" "system1" ] else if platform == "hcloud" then [ "system0" ] else [ "system0" "local1" "local2" ]) (_: { imageSize = "12G"; }))
        { system0.device = lib.mkForce "/dev/vda"; }
        (lib.optionalAttrs (platform == "hetzner") { system1.device = lib.mkForce "/dev/vdb"; })
        (lib.optionalAttrs (platform == "ec2") { local1.device = lib.mkForce "/dev/vdb"; local2.device = lib.mkForce "/dev/vdc"; })
      ];
      # @cc [owner:ghuntley,label:verification;security] exported-image-installer-source
      # A base system admits administrative SSH only from the source its
      # guarded installation recorded (ADR-0234). The exported test images
      # MUST carry exactly what `remote.py install-base-source` writes for an
      # installer reaching the host through QEMU user networking (10.0.2.2):
      # one root-only address file, no key, credential or firewall change.
      system.build.overallsTestImages = lib.overrideDerivation exported.system.build.diskoImages (previous: {
        buildCommand = previous.buildCommand + lib.optionalString (platform != "ec2") ''
          installed=$(mktemp -d)
          ${config.boot.zfs.package}/bin/mount.zfs zroot/root "$installed"
          install -d -m 0700 "$installed/var/lib/overalls-host"
          (umask 077; printf '10.0.2.2\n' > "$installed/var/lib/overalls-host/base-source")
          umount "$installed"
        '' + ''
          ${config.boot.zfs.package}/bin/zpool export ${if platform == "ec2" then "guests" else "zroot"}
        '';
      });
    }) ];
  };
in {
  hetzner-uefi = make "hetzner" "uefi";
  hetzner-bios = make "hetzner" "bios";
  ec2-uefi = make "ec2" "uefi";
  ec2-bios = make "ec2" "bios";
  hcloud-uefi = make "hcloud" "uefi";
  hcloud-bios = make "hcloud" "bios";
}
