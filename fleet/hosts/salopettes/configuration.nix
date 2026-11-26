{ config, lib, ... }:
let
  origin = "notifications.overalls.dev";
  addresses = config.overalls.fleetAddresses;
in
{
  # Salopettes is a fleet tunnel member (ADR-0233,
  # ADR-0239); the fleet tunnel is IPv4-only, so salopettes runs without IPv6. Its public
  # address lives only in the shared fleet-addresses SOPS document, and IPv4
  # comes up by DHCP, so the base system never needs the secret.
  imports = [ ../../fleet-network.nix ];
  networking.enableIPv6 = false;

  # Discovery ran under Ubuntu's eth0 name; installed NixOS names it enp1s0.
  services.overallsFleetExporter.externalInterfaces = lib.mkForce [ "enp1s0" ];

  # @cc [owner:ghuntley,label:deployment;security] salopettes-susan-only
  # Salopettes MUST run only the Susan push relay (ADR-0224, ADR-0231), its
  # local PostgreSQL and the TLS proxy for the fixed origin. It MUST NOT enable
  # Marshall, Lilly, Porsche, Audi, Brady, Galileo, Ziggy or the Marshall proxy.
  assertions = [{
    assertion = config.services.susan.enable
      && !config.services.marshall.enable
      && !config.services.marshallProxy.enable
      && !config.services.lilly.enable
      && !config.services.porsche.enable
      && !config.services.audi.enable
      && !config.services.brady.enable
      && !config.services.galileo.enable
      && !config.services.ziggy.enable;
    message = "Salopettes runs only the Susan push relay.";
  }];

  services.susan = {
    enable = true;
    secretsFile = "${../../../secrets/overalls-susan.enc.json}";
    # Mila's bundle identifier and Android application id.
    apnsTopics = [ "dev.overalls.mila" ];
    fcmAppIds = [ "dev.overalls.mila" ];
  };

  # @cc [owner:ghuntley,label:security;deployment] salopettes-susan-tls-origin
  # The proxy MUST terminate publicly trusted TLS for the fixed Susan origin
  # only, forward to Susan's loopback listener, and keep no access log: Susan
  # never records client addresses (ADR-0224). Plain HTTP serves only ACME
  # challenges and the redirect.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    logError = "stderr crit";
    virtualHosts.${origin} = {
      enableACME = true;
      forceSSL = true;
      extraConfig = ''
        access_log off;
        client_max_body_size 4k;
      '';
      locations."/".proxyPass = "http://127.0.0.1:${toString config.services.susan.port}";
    };
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "noreply@ghuntley.dev";
  };

  # The listener binds every address; the firewall admits the public path only
  # at the SOPS-delivered IPv4 address, and tunnel peers through fleet0 (none until
  # it is re-peered with Overalls, ADR-0284).
  overalls.fleetFirewall.publicServices.susan = {
    addressFile = addresses.files.salopettesPrimary;
    addressUnit = addresses.unit;
    tcpPorts = [ 80 443 ];
    comment = "Susan push relay HTTPS and ACME";
  };

  # Like the other fleet hosts, salopettes offers a Tailscale exit node; joining
  # the tailnet and approving the route stay explicit operator actions.
  overalls.tailscale.exitNode = true;

  # Susan is small; keep store reclamation bounded for the 150 GiB root.
  services.overallsNixGc = {
    diskThresholdGiB = 30;
    maxFreedGiB = 60;
  };

  services.overallsFleetExporter.units = [ "susan.service" "nginx.service" "postgresql.service" ];
}
