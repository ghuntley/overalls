{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  evaluate = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      services.openssh.enable = true;
      networking.hostId = "12345678";
      services.lilly = {
        enable = true;
        guestTrustRoots = [ ../../../../marshall/test/fixtures/tls/ca.pem ];
        hostId = "11111111-1111-4111-8111-111111111111";
        controlPlane = "https://control.example.test";
        egressInterface = "eth0";
        guestCpuCores = 1;
        guestMemoryMiB = 256;
        pools = [{
          id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
          path = "/pool";
          filesystem_id = "zfs:123:456";
          storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
        }];
      };
      services.ziggy = {
        secretsFile = "/etc/overalls/ziggy.enc.json";
      };
      services.galileo.secretsFile = "/etc/overalls/galileo.enc.json";
    } extra ];
  }).config;
  ready = evaluate {
    services.audiPrivate = {
      enable = true;
      secretsFile = "/etc/overalls/audi-private.enc.json";
      rootsFile = "/etc/overalls/private-roots.pem";
    };
    services.overallsFleetExporter.enable = true;
  };
  issuerBase = {
    services.marshall = {
      enable = true; replicaCount = 1; poolSize = 10; publicHost = "control.example.test";
      databaseConnectionBudget = 64;
      instances.one = { port = 4443; certificateFile = "/run/tls/cert.pem"; keyFile = "/run/tls/key.pem"; };
    };
  };
  # The issuer module left the default host module when Galileo replaced it;
  # only the Inception guest imports it (nix/domains/artifacts/guest/inception/private.nix).
  issuerModule = import ../../../domains/system/audi-private-issuer.nix { inherit packages; };
  issuerWith = options: evaluate {
    imports = [ issuerModule (lib.recursiveUpdate issuerBase { services.audiPrivateIssuer = { enable = true; } // options; }) ];
  };
  issuer = issuerWith { secretsFile = "/etc/overalls/issuer.enc.json"; };
  runtimeIssuer = issuerWith {
    issuerKeyFile = "/var/lib/isolated-issuer/issuer.key";
    issuerCertificateFile = "/var/lib/isolated-issuer/issuer.pem";
    secretUnits = [ "isolated-custody.service" ];
  };
  absentIssuer = issuerWith {};
  partialIssuer = issuerWith { issuerKeyFile = "/var/lib/isolated-issuer/issuer.key"; };
  ambiguousIssuer = issuerWith {
    secretsFile = "/etc/overalls/issuer.enc.json";
    issuerKeyFile = "/var/lib/isolated-issuer/issuer.key";
    issuerCertificateFile = "/var/lib/isolated-issuer/issuer.pem";
  };
  wrong = evaluate { services.ziggy.hostId = lib.mkForce "22222222-2222-4222-8222-222222222222"; };
  disabled = evaluate { services.ziggy.enable = false; };
  forcedOff = evaluate { services.ziggy.enable = lib.mkForce false; };
  openaiOnly = evaluate { services.ziggy.enabledProviders = [ "openai" ]; };
  noProviders = evaluate { services.ziggy.enabledProviders = []; };
  duplicateProviders = evaluate { services.ziggy.enabledProviders = [ "openai" "openai" ]; };
  neither = evaluate { services.lilly.enable = lib.mkForce false; };
  valid = config: lib.all (a: a.assertion) config.assertions;
  # @cc [owner:ghuntley,label:verification;recovery] lilly-dependents-follow-lilly-start
  # Every always-on unit that Requires= lilly.service loses its process when
  # Lilly stops; each MUST also be wanted by lilly.service so a later Lilly
  # start restores it. This checks evaluated unit wiring, not native restarts.
  lillyDependents = config: lib.filterAttrs (_: unit:
    builtins.elem "lilly.service" unit.requires && builtins.elem "multi-user.target" unit.wantedBy
  ) config.systemd.services;
  followsLilly = config: lib.all (unit: builtins.elem "lilly.service" unit.wantedBy)
    (builtins.attrValues (lillyDependents config));
  unit = ready.systemd.services.ziggy;
in
assert valid openaiOnly;
assert !valid noProviders;
assert !valid duplicateProviders;
assert ready.services.ziggy.enabledProviders == [ "openai" "anthropic" ];
assert lib.assertMsg (valid ready) (lib.concatMapStringsSep "\n" (a: a.message) (lib.filter (a: !a.assertion) ready.assertions));
assert builtins.elem "ziggy" ready.services.overallsFleetExporter.roles;
assert builtins.elem "ziggy.service" ready.services.overallsFleetExporter.units;
assert builtins.elem "ziggy-proxy" ready.systemd.services.overalls-fleet-exporter.serviceConfig.SupplementaryGroups;
assert ready.services.lilly.privateServices.enable;
assert !ready.services.peach.enable;
assert lillyDependents ready ? audi-private;
assert followsLilly ready;
assert !ready.services.lilly.ingress.enable;
assert ready.systemd.services.audi-private.serviceConfig.NetworkNamespacePath == "/run/netns/lilly-${builtins.substring 0 12 (builtins.hashString "sha256" ready.services.lilly.hostId)}";
assert builtins.length ready.systemd.services.audi-private.serviceConfig.LoadCredential == 3;
assert !(builtins.elem "OPENAI_API_KEY" (builtins.attrNames ready.systemd.services.audi-private.environment));
assert lib.assertMsg (valid issuer) (lib.concatMapStringsSep "\n" (a: a.message) (lib.filter (a: !a.assertion) issuer.assertions));
assert valid runtimeIssuer;
assert !valid absentIssuer;
assert !valid partialIssuer;
assert !valid ambiguousIssuer;
assert runtimeIssuer.systemd.services.audi-private-issuer.serviceConfig.LoadCredential == [
  "issuer.key:/var/lib/isolated-issuer/issuer.key" "issuer.pem:/var/lib/isolated-issuer/issuer.pem"
];
assert runtimeIssuer.systemd.services.audi-private-issuer.requires == [ "isolated-custody.service" ];
assert !(runtimeIssuer.services.overallsSecrets.bundles ? audi-private-issuer);
assert builtins.elem "overalls-secrets-audi-private-issuer.service" issuer.systemd.services.audi-private-issuer.requires;
assert !(issuer.users.users ? marshall);
assert issuer.systemd.services.marshall-one.serviceConfig.DynamicUser;
assert builtins.elem "audi-private-signing" issuer.systemd.services.marshall-one.serviceConfig.SupplementaryGroups;
assert !valid wrong;
assert !valid disabled;
assert !valid forcedOff;
assert !neither.services.ziggy.enable;
assert !(neither.systemd.services ? ziggy);
assert ready.services.ziggy.enable;
assert ready.services.ziggy.hostId == ready.services.lilly.hostId;
assert ready.services.ziggy.controlPlane == ready.services.lilly.controlPlane;
assert ready.services.ziggy.caFile == ready.services.lilly.controlPlaneCAFile;
assert unit.serviceConfig.User == "ziggy";
assert builtins.length unit.serviceConfig.LoadCredential == 4;
assert builtins.elem "overalls-secrets-ziggy.service" unit.requires;
assert ready.services.overallsSecrets.bundles.ziggy.outputs."openai.key".secrets == [ "OPENAI_API_KEY" ];
assert ready.services.overallsSecrets.bundles.ziggy.outputs."anthropic.key".secrets == [ "ANTHROPIC_API_KEY" ];
assert !(unit.environment ? OPENAI_API_KEY);
assert !(unit.environment ? ANTHROPIC_API_KEY);
# ADR-0159: the durable SLO checkpoint has no rollout switch.
assert !(ready.services.ziggy ? durableSloCounters);
assert !(unit.environment ? ZIGGY_DURABLE_SLO);
assert !(ready.networking.firewall.allowedTCPPorts == [ 443 ]);
pkgs.runCommand "ziggy-configuration-check" {} ''touch "$out"''
