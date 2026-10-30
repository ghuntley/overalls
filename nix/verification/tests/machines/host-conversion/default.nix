{ pkgs, nixpkgs, module, diskoModule, kexec, imageSource, sourceOS }:
let
  # Publicly known upstream fixture identity, confined to this isolated suite.
  key = imageSource + "/nix/kexec-installer/ssh-keys/id_ed25519";
  public = pkgs.lib.removeSuffix "\n" (builtins.readFile (imageSource + "/nix/kexec-installer/ssh-keys/id_ed25519.pub"));
  access = { lib, ... }: {
    overalls.access.users = lib.mkForce {
      tester = { sshKeys = [ public ]; login = true; admin = true; };
    };
  };
  # Exact public facts for the serial-numbered QEMU hardware below. The real
  # profile's immutable declaration and guarded installer are used unchanged.
  original = import ../../fixtures/hosts { platform = "hetzner"; firmware = "bios"; };
  ids = [ "disk-a7442feada5c5e87c3db0c92" "disk-4dbb9b95b4622be2eba057e6" ];
  host = original // {
    inventory = original.inventory // {
      machine = "11111111-1111-4111-8111-111111111111";
      disks = pkgs.lib.imap0 (i: d: d // { id = builtins.elemAt ids i; model = ""; }) original.inventory.disks;
    };
    storage = original.storage // { system = ids; };
  };
  target = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ module access (import ../../../../platform/hosts/profile.nix { inherit host diskoModule; }) {
      boot.kernelParams = [ "console=ttyS0" ];
      boot.loader.grub.extraConfig = "serial; terminal_output serial";
    } ];
  };
  formatter = target.config.system.build.overallsHostInstall;
  recovery = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ../../../../domains/system/access.nix access ({ config, lib, modulesPath, pkgs, ... }: {
      imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") (modulesPath + "/testing/test-instrumentation.nix") ];
      system.stateVersion = "26.05";
      overalls.access.enable = true;
      users.users.root.hashedPasswordFile = lib.mkForce null;
      environment.systemPackages = [ pkgs.python3 ];
      boot.kernelParams = [ "console=ttyS0" ];
    }) ];
  };
  ubuntu = pkgs.fetchurl {
    url = "https://cloud-images.ubuntu.com/noble/20260911/noble-server-cloudimg-amd64.img";
    sha256 = (import ../../../../domains/artifacts/pins.nix).ubuntuNobleCloudImage;
  };
  anywhere = import ../../../../domains/artifacts/host/installer.nix { inherit pkgs; };
in pkgs.testers.runNixOSTest {
  name = "overalls-host-conversion-${sourceOS}";
  nodes = {};
  requiredFeatures.kvm = true;
  globalTimeout = 3600;
  testScript = ''
    platform = ${builtins.toJSON host.platform}
    sources = ${builtins.toJSON [ sourceOS ]}
    qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
    qemu_img = "${pkgs.qemu_kvm}/bin/qemu-img"
    ssh_bin = "${pkgs.openssh}/bin/ssh"
    keygen = "${pkgs.openssh}/bin/ssh-keygen"
    geniso = "${pkgs.cdrkit}/bin/genisoimage"
    operator_key = "${key}"
    operator_public = ${builtins.toJSON public}
    ubuntu_image = "${ubuntu}"
    recovery_iso = "${recovery.config.system.build.isoImage}/iso/${recovery.config.image.fileName}"
    anywhere = "${anywhere}/bin/nixos-anywhere"
    kexec_image = "${kexec}"
    system = "${target.config.system.build.toplevel}"
    formatter = "${formatter}"
    nix_store = "${pkgs.nix}/bin/nix-store"
    registration = "${pkgs.closureInfo { rootPaths = [ formatter target.config.system.build.toplevel ]; }}/registration"
    remote_script = "${../../../../domains/artifacts/host/remote.py}"
  '' + builtins.readFile ./driver.py;
}
