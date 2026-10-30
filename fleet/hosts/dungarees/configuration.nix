{ config, lib, overallsPackages, pkgs, ... }:
let
  fleetServices = import ../../../nix/policy/fleet/services.nix { inherit lib; };
  roster = import ../../../nix/policy/fleet/hosts.nix { inherit lib; };
  ports = import ../../../nix/policy/fleet/ports.nix { };
in
{
  imports = [ ../../fleet-network.nix ];
  # A read-only client of Panterloons' Buck2 cache (ADR-0272). Its
  # remote-execution worker is declared but held off until Panterloons' worker
  # has run healthy beside its guests (single-host rollout).
  overalls.buckRemoteCache = lib.recursiveUpdate
    ((import ../../buck-re.nix { inherit lib; }).forHost "dungarees")
    { worker.enable = false; };
  services.overallsOtelFleet = {
    enable = true;
    role = "worker";
    hosts = (roster.deploymentOf "dungarees").telemetry;
  };
  # Resolve public fleet names through DNS instead of the private fleet tunnel.
  networking.hosts."127.0.0.2" = lib.mkForce [];
  # Use this host's stable systemd offset rather than a shared calendar burst.
  services.overallsBackups.randomizedDelaySec = 300;

  # Identical hardware to Panterloons; see the control-plane role's reviewed thresholds rationale.
  services.overallsNixGc = {
    interval = "1h";
    diskThresholdGiB = 200;
    maxFreedGiB = 400;
    preserveGenerations = "14d";
  };

  services.cachix-watch-store = {
    enable = true;
    cacheName = "overalls";
    cachixTokenFile = "/run/overalls-secrets/cachix/token";
  };
  services.overallsSecrets.bundles.cachix = {
    encryptedFile = "${../../../secrets/panterloons-cachix.enc.json}";
    outputs.token = { format = "raw"; secrets = [ "CACHIX_AUTH_TOKEN" ]; };
  };
  systemd.services.cachix-watch-store-agent = {
    requires = [ "overalls-secrets-cachix.service" ];
    after = [ "overalls-secrets-cachix.service" ];
  };

  overalls.remoteBuilders = {
    enable = true;
    localName = "dungarees";
    machines = import ../../remote-builders.nix { inherit lib; };
  };
  # Dungarees delegates to the Panterloons hub and serves a worker (ADR-0248).
  overalls.fleetBuilds = {
    enable = true;
    localName = "dungarees";
  } // import ../../fleet-builds.nix { inherit lib; };
  networking.enableIPv6 = false;
  overalls.tailscale.exitNode = true;
  services.openssh.ports = [ ports.adminSsh ];
  # @cc [owner:ghuntley,label:deployment] dungarees-worker-only
  # Dungarees MUST use Panterloons' control plane (ADR-0246) and its own enrolled identities.
  # It MUST NOT enable a local Marshall, database, public proxy or Porsche gateway.
  assertions = [{
    assertion = !config.services.marshall.enable
      && !config.services.postgresql.enable
      && !config.services.marshallProxy.enable
      && !config.services.porsche.enable;
    message = "Dungarees is a Lilly worker for the Panterloons control plane.";
  }];

  # @cc [owner:ghuntley,label:deployment;recovery] fastpath-template-producer-dungarees
  # Sealed templates (ADR-0130) keep the 32 GiB per-pool budget and grant no
  # VM capacity credit or execution authority; root disks are block-cloned
  # from them on demand (ADR-0177).
  services.lilly = {
    # 96 GiB covers every configured image (two Linux templates plus the 64 GiB
    # Windows firecracker disk, ADR-0173) so sealed templates never evict each other.
    imageTemplates.budgetBytes = 96 * 1024 * 1024 * 1024;
    images = map (image: { path = toString image.package; })
      (import ../../staged-guest-images.nix { inherit overallsPackages; });
    protectedAddressFiles = let files = config.overalls.fleetAddresses.files;
      in [ files.dungareesPrimary files.dungareesService files.panterloonsPrimary ];
    protectedAddressUnits = [ config.overalls.fleetAddresses.unit ];
    ingress.enable = true;
  };

  services.ziggy.secretsFile = "${../../../secrets/dungarees-ziggy.enc.json}";
  services.ziggy.enabledProviders = [ "openai" ];
  services.galileo.secretsFile = "${../../../secrets/dungarees-galileo.enc.json}";
  services.peach = {
    enable = true;
    secretsFile = "${../../../secrets/dungarees-peach.enc.json}";
  };
  services.audiPrivate = {
    enable = true;
    secretsFile = "${../../../secrets/dungarees-audi-private.enc.json}";
    rootsFile = "${../../../secrets/private-services-root.pem}";
  };
  services.overallsSecrets.bundles = {
    brady = {
      encryptedFile = "${../../../secrets/dungarees-brady.enc.json}";
      outputs = {
        "issuer.pem" = { format = "raw"; secrets = [ "BRADY_ISSUER_CERTIFICATE" ]; };
        "issuer.key" = { format = "raw"; secrets = [ "BRADY_ISSUER_KEY" ]; };
      };
    };
    audi = {
      encryptedFile = "${../../../secrets/dungarees-audi.enc.json}";
      outputs.token = { format = "raw"; secrets = [ "AUDI_GATEWAY_TOKEN" ]; };
    };
    audi-dns = {
      encryptedFile = "${../../../secrets/dungarees-audi-dns.enc.json}";
      outputs.token = { format = "raw"; secrets = [ "AUDI_DNS_TOKEN" ]; };
    };
    logstore = {
      encryptedFile = "${../../../secrets/dungarees-logstore.enc.json}";
      outputs."insert.password" = { format = "raw"; secrets = [ "INSERT_PASSWORD" ]; };
    };
  };
  # @cc [owner:ghuntley,label:security;deployment] dungarees-logstore-insert-only
  # This worker host MUST hold only the insert credential; reader authority
  # and the store TLS key never leave the control-plane host. Collector
  # sources MUST exclude audit, firecracker and guest content.
  services.overallsLogging = {
    enable = true;
    secretUnits = [ "overalls-secrets-logstore.service" ];
    outputs.logstore = {
      type = "native";
      plugin = "http";
      sources = fleetServices.logSources;
      queueBytes = 50331648;
      credentialFiles.http_passwd = "/run/overalls-secrets/logstore/insert.password";
      settings = {
        host = fleetServices.services.logStore.dnsName;
        port = fleetServices.services.logStore.port;
        uri = "/insert/jsonline?_msg_field=message";
        format = "json_lines";
        http_user = "insert";
        tls = true;
        "tls.verify" = true;
        "tls.verify_hostname" = true;
        "tls.ca_file" = "/etc/overalls/logstore-ca.crt";
      };
    };
  };
  # @cc [owner:ghuntley,label:security;deployment] dungarees-brady-signer
  # Brady MUST use this host's encrypted signer; the root key never enters a
  # host bundle or guest image.
  services.brady = {
    enable = true;
    issuerCertificateFile = "/run/overalls-secrets/brady/issuer.pem";
    issuerKeyFile = "/run/overalls-secrets/brady/issuer.key";
    secretUnits = [ "overalls-secrets-brady.service" ];
  };

  # @cc [owner:ghuntley,label:security;deployment] dungarees-audi-worker-plane
  # Audi gateway and DNS listeners MUST bind the reserved explicit address
  # DUNGAREES_SERVICE_IPV4 and remain reachable from the public internet through the
  # reviewed fleet-perimeter public service entry (TCP 22/80/443 and UDP/TCP
  # 53), and MUST reach the control plane only through the verified fleet
  # tunnel. The worker-only assertion MUST stay intact: no local Marshall,
  # database, public proxy or Porsche gateway may be enabled here.
  overalls.fleetFirewall.publicServices.audi = {
    addressFile = config.overalls.fleetAddresses.files.dungareesService;
    addressUnit = config.overalls.fleetAddresses.unit;
    tcpPorts = [ 22 53 80 443 ];
    udpPorts = [ 53 ];
    comment = "Audi public gateway and DNS";
  };

  services.audiDns = {
    enable = true;
    controlPlane = "https://ghuntley.dev:5443";
    caFile = "/etc/overalls/service-ca.crt";
    credentialFile = "/run/overalls-secrets/audi-dns/token";
    secretUnits = [ "overalls-secrets-audi-dns.service" ];
    zone = "apps.ghuntley.dev";
    nameservers = [ "ns1.ghuntley.dev" "ns2.ghuntley.dev" ];
    mailbox = "hostmaster.ghuntley.dev";
    bindAddressFile = config.overalls.fleetAddresses.files.dungareesService;
    bindAddressUnit = config.overalls.fleetAddresses.unit;
  };

  services.audi = {
    relay.enable = true;
    enable = true;
    hostId = config.services.lilly.hostId;
    controlPlane = "https://ghuntley.dev:5443";
    caFile = "/etc/overalls/service-ca.crt";
    credentialFile = "/run/overalls-secrets/audi/token";
    secretUnits = [ "overalls-secrets-audi.service" ];
    bindAddressFile = config.overalls.fleetAddresses.files.dungareesService;
    bindAddressUnit = config.overalls.fleetAddresses.unit;
    tls = {
      enable = true;
      zone = "apps.ghuntley.dev";
      browserOrigin = "https://ghuntley.dev";
      certificateRootsFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
  };

  # Discovery uses rescue's eth0 name; installed hardware uses enp193s0f0np0.
  services.overallsFleetExporter.externalInterfaces = lib.mkForce [ "enp193s0f0np0" ];
  services.overallsFleetExporter.units = [
    "lilly.service"
    "ziggy.service"
    "galileo.service"
    "audi.service"
    "audi-dns.service"
    "audi-private.service"
    "underclass.service"
    "underclass-tailscale-serve.service"
  ];
}
