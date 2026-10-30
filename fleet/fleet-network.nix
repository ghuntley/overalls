{ config, lib, ... }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  publicKeys = builtins.fromJSON (builtins.readFile ./fleet-public-keys.json);
  # Physical endpoints are fleet address names (nix/policy/network/fleet-addresses.nix);
  # the values arrive only through the shared fleet-addresses SOPS document.
  # Tunnel membership, addresses and peers come from the fleet host roster.
  roster = import ../nix/policy/fleet/hosts.nix { inherit lib; };
  fleetServices = import ../nix/policy/fleet/services.nix { inherit lib; };
  name = config.networking.hostName;
  network = (roster.deploymentOf name).tunnel;
  addresses = config.overalls.fleetAddresses;
  serviceCa = ./roles/control-plane/service-ca.crt;
  local = network.${name};
  document = lib.findFirst (item: item.name == "${name}-fleet-network")
    (throw "Missing fleet network credential") inventory.${name}.credentials;
  encryptedFile = ../. + ("/" + document.path);
in {
  assertions = [{
    assertion = lib.all (machine: lib.all (peer: network ? ${peer}) machine.peers) (lib.attrValues network);
    message = "Fleet network peers must belong to the same deployment tunnel.";
  }];
  networking.wireguard.useNetworkd = false;
  # @cc [owner:ghuntley,label:security] production-fleet-peer-custody
  # Physical fleet peers MUST use distinct encrypted host credentials and pinned
  # public keys, and peer only inside their own deployment's tunnel. Only that
  # tunnel's control plane (10.90.0.1) may admit fleet API traffic; Salopettes
  # admits only the Susan relay and metrics, and peers only with Panterloons. Guest
  # prefixes MUST remain protected, and transport failure MUST NOT select the
  # browser API.
  overalls.fleetNetwork = {
    inherit (local) address;
    endpointAddressFile = addresses.files.${local.endpoint};
    endpointUnits = [ addresses.unit ];
    enable = true;
    privateKeyFile = "/run/overalls-secrets/fleet-network/private-key";
    secretUnits = [ "overalls-secrets-fleet-network.service" ];
    tcpPorts = fleetServices.tunnelPorts name;
    peers = lib.genAttrs local.peers (peer: {
      inherit (network.${peer}) address;
      endpointAddressFile = addresses.files.${network.${peer}.endpoint};
      publicKey = publicKeys.${peer};
    });
  };
  services.overallsSecrets.bundles.fleet-network = {
    encryptedFile = "${encryptedFile}";
    outputs.private-key = { format = "raw"; secrets = [ "WIREGUARD_PRIVATE_KEY" ]; };
  };
  environment.etc."overalls/service-ca.crt".source = serviceCa;
  environment.etc."overalls/logstore-ca.crt".source = ./roles/control-plane/logstore-ca.crt;
  networking.hosts.${roster.controlPlaneAddress} = [ fleetServices.services.logStore.dnsName ];
  services.lilly = {
    controlPlaneCAFile = "/etc/overalls/service-ca.crt";
    protectedCidrs = [ roster.prefix ];
  };
  # @cc [owner:ghuntley,label:recovery;security] service-ca-consumers-follow-bundle
  # Consumers copy the service CA bundle at start (LoadCredential) or load it
  # once (HAProxy). A rotated bundle MUST restart or reload every enabled
  # consumer on activation; otherwise they keep verifying against the retired CA.
  systemd.services = lib.genAttrs (lib.attrNames (lib.filterAttrs (_: enabled: enabled) {
    lilly = config.services.lilly.enable;
    ziggy = config.services.ziggy.enable;
    audi = config.services.audi.enable;
    audi-dns = config.services.audiDns.enable;
    audi-private-certificate = config.services.audiPrivate.enable;
    overalls-logging = true;
  })) (_: {
    after = [ "wireguard-fleet0.service" ];
    wants = [ "wireguard-fleet0.service" ];
    restartTriggers = [ serviceCa ];
  }) // lib.optionalAttrs config.services.galileo.enable {
    galileo.restartTriggers = [ serviceCa ];
  } // lib.optionalAttrs config.services.porsche.enable {
    porsche.restartTriggers = [ serviceCa ];
  } // lib.optionalAttrs config.services.marshallProxy.enable {
    haproxy.reloadTriggers = [ serviceCa ];
  };
}
