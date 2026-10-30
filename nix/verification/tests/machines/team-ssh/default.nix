{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
in pkgs.testers.runNixOSTest {
  name = "overalls-team-ssh";
  nodes.control = { config, ... }: {
    imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
    virtualisation.memorySize = lib.mkForce 3072;
    services.marshall = {
      enable = true;
      ingress.zone = "apps.example.test";
      instances.control.bindAddress = "0.0.0.0";
    };
    networking.firewall.allowedTCPPorts = [ 4443 ];
    services.porsche = {
      enable = true;
      package = packages.porsche;
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://control.example.test:4443";
      credentialFile = "/run/overalls-test/gateway.token";
      caFile = "/run/overalls-test/ca.crt";
      administrativeAccess = "console";
      openFirewall = true;
    };
    systemd.services.porsche.wantedBy = lib.mkForce [];
    systemd.services.team-ssh-seed = {
      after = [ "overalls-test-migrate.service" ];
      requires = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=team-ssh-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  nodes.client = { nodes, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 1024;
    virtualisation.cores = 1;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    networking.extraHosts = "${nodes.control.networking.primaryIPAddress} control.example.test\n";
    users.users.tester = { isNormalUser = true; };
    environment.systemPackages = [ pkgs.openssh pkgs.curl pkgs.util-linux ];
  };
  # @cc [owner:ghuntley,label:verification] teams-packaged-ssh-journey
  # Every tested team mutation MUST enter the packaged Porsche service over
  # strict host-key trust and verified internal HTTPS. Ordinary persisted users,
  # committed receipts and complete team/audit inventories MUST be checked.
  # This metadata-only fixture MUST NOT establish guest or integration access.
  testScript = builtins.readFile ./driver.py;
}
