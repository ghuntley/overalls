{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-enrollment-operator";
  requiredFeatures.nested-kvm = true;
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes = {
    control = { config, ... }: {
      services.marshall.enable = true;
      services.marshall.instances.control.bindAddress = "0.0.0.0";
      services.marshall.instances.control.fleetBindAddress = config.networking.primaryIPAddress;
      services.marshall.instances.control.fleetLoopback = true;
      networking.firewall.allowedTCPPorts = [ 4443 ];
      networking.firewall.interfaces.eth1.allowedTCPPorts = [ 5443 ];
      services.openssh = { enable = true; settings = { PermitRootLogin = "no"; PasswordAuthentication = false; }; };
      users.users.operator = { isNormalUser = true; extraGroups = [ "wheel" ]; };
      security.sudo.wheelNeedsPassword = false;
      environment.systemPackages = [ pkgs.python3 ];
    };
    client = { config, lib, nodes, ... }: {
      networking.hostId = "45454545";
      virtualisation.qemu.options = [ "-uuid 45454545-4545-4545-8545-454545454545" ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      networking.extraHosts = "${nodes.control.networking.primaryIPAddress} control.example.test\n";
      virtualisation.memorySize = lib.mkForce 3072;
      virtualisation.emptyDiskImages = [{ size = 1024; driveConfig.deviceExtraOpts.serial = "enrollment-data"; }];
      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportRoot = false;
      services.openssh = { enable = true; settings = { PermitRootLogin = "no"; PasswordAuthentication = false; KbdInteractiveAuthentication = false; }; };
      users.users.operator = { isNormalUser = true; extraGroups = [ "wheel" ]; };
      security.sudo.wheelNeedsPassword = false;
      services.lilly = {
        enable = true;
        # ADR-0182: the real unit runs as `lilly`, credentials via LoadCredential.
        # The runtime pool (enrollment-storage); hostd's file roots, ZFS grammar
        # and lilly-ownership use its path and dataset. configure.py installs
        # the observed identities in the runtime configuration.
        pools = lib.mkForce [{
          id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
          path = "/var/lib/lilly/pool";
          filesystem_id = "zfs:123:456";
          storage = { dataset = "zroot/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
        }];
        controlPlane = lib.mkForce "https://control.example.test:5443";
        controlPlaneCAFile = lib.mkForce "/run/enrollment-ca.crt";
        credentialFile = lib.mkForce "/run/overalls-secrets/lilly/credential.json";
        secretUnits = [ "overalls-secrets-lilly.service" "enrollment-storage.service" ];
      };
      # This suite verifies real Lilly enrollment, not provider credentials or
      # inference. Keep the required Ziggy role outside the startup target.
      services.ziggy.secretsFile = "/run/enrollment-ziggy.enc.json";
      systemd.services.ziggy.wantedBy = lib.mkForce [];
      services.galileo.secretsFile = "/run/enrollment-galileo.enc.json";
      systemd.services.galileo.wantedBy = lib.mkForce [];
      services.overallsSecrets = {
        enable = true;
        bundles.lilly = {
          encryptedFile = "/run/enrollment.enc.json";
          outputs."credential.json" = { format = "raw"; secrets = [ "LILLY_CREDENTIAL" ]; };
        };
      };
      systemd.services.overalls-secrets-lilly.wantedBy = lib.mkForce [];
      systemd.services.lilly = {
        wantedBy = lib.mkForce [];
        path = [ config.boot.zfs.package ];
        # Dynamic runtime fixture UUIDs replace only public config after the
        # production module has populated its execution/tool configuration.
        preStart = lib.mkAfter ''
          ${pkgs.python3}/bin/python /etc/enrollment-config.py
        '';
      };
      # The pool exists only after enrollment-storage; hand it over then.
      systemd.services.lilly-ownership = {
        after = [ "enrollment-storage.service" ];
        requires = [ "enrollment-storage.service" ];
        wantedBy = lib.mkForce [];
      };
      systemd.services.enrollment-storage = {
        path = [ config.boot.zfs.package ];
        script = ''
          zpool create -f -O mountpoint=none -O compression=lz4 zroot /dev/vdb
          zfs create -o mountpoint=/var/lib/lilly/pool -o compression=lz4 -o reservation=none -o refreservation=none -o quota=536870912 zroot/lilly
        '';
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      };
      environment.systemPackages = [ (import ../../../../domains/artifacts/host { inherit pkgs; }) pkgs.git pkgs.nix pkgs.python3 pkgs.openssh pkgs.sops pkgs.ssh-to-age config.boot.zfs.package
        (pkgs.writeShellScriptBin "overalls-lilly-identity" ''
          export RELEASE_COOKIE=isolated-fixture RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
          exec ${packages.lilly}/bin/lilly eval '{:ok, id} = Lilly.Host.Identity.read(); IO.puts(id)'
        '')
      ];
      environment.etc."enrollment-test.py".source = ./client.py;
      environment.etc."enrollment-config.py".source = ./configure.py;
      environment.etc."enrollment-fixture.py".source = ./fixture.py;
      environment.etc."enrollment-remote.py".source = ../../../../domains/artifacts/host/remote.py;
      environment.etc."enrollment-inventory.nix".source = ../../../../platform/hosts/inventory.nix;
      environment.etc."enrollment-nixpkgs".text = "${pkgs.path}";
    };
  };
  testScript = builtins.readFile ./driver.py;
}
