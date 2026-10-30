{ config, lib, overallsPackages, pkgs, ... }:
let
  host = config.overalls.controlPlaneHost;
  secret = name: ../../../secrets + "/${host.name}-${name}.enc.json";
  # SOPS-delivered fleet addresses (ADR-0233); no address literal is evaluated.
  addresses = config.overalls.fleetAddresses;
  primary = addresses.files."${host.name}Primary";
  service = addresses.files."${host.name}Service";
  # Roles whose credentials the deployment's own Marshall issues.
  issued = !host.bootstrap;
  roster = import ../../../nix/policy/fleet/hosts.nix { inherit lib; };
  fleetServices = (import ../../../nix/policy/fleet/services.nix { inherit lib; }).services;
  inherit (roster) controlPlaneAddress;
  ports = import ../../../nix/policy/fleet/ports.nix { };
in
{
  imports = [ ./image-catalog.nix ./porsche-authority.nix ./private-services.nix ];

  services.overallsSecrets.bundles = {
    ssh-host-ca = {
      encryptedFile = "${secret "ssh-host-ca"}";
      outputs.key = { format = "raw"; secrets = [ "SSH_HOST_CA_KEY" ]; };
    };
    brady = {
      encryptedFile = "${secret "brady"}";
      outputs = {
        "issuer.pem" = { format = "raw"; secrets = [ "BRADY_ISSUER_CERTIFICATE" ]; };
        "issuer.key" = { format = "raw"; secrets = [ "BRADY_ISSUER_KEY" ]; };
      };
    };
    porsche = lib.mkIf issued {
      encryptedFile = "${secret "porsche"}";
      outputs.token = { format = "raw"; secrets = [ "PORSCHE_GATEWAY_TOKEN" ]; };
    };
    audi = lib.mkIf issued {
      encryptedFile = "${secret "audi"}";
      outputs.token = { format = "raw"; secrets = [ "AUDI_GATEWAY_TOKEN" ]; };
    };
    audi-dns = lib.mkIf issued {
      encryptedFile = "${secret "audi-dns"}";
      outputs.token = { format = "raw"; secrets = [ "AUDI_DNS_TOKEN" ]; };
    };
    marshall = {
      encryptedFile = "${secret "marshall"}";
      outputs.environment = {
        format = "environment";
        secrets = [ "DATABASE_URL" "SECRET_KEY_BASE" "TOKEN_SIGNING_SECRET" "MARSHALL_CLOAK_KEYS" ];
      };
      outputs."serper.key" = { format = "raw"; secrets = [ "SERPER_API_KEY" ]; };
    };
    github-oauth = {
      encryptedFile = "${secret "github-oauth"}";
      outputs.secret = { format = "raw"; secrets = [ "GITHUB_CLIENT_SECRET" ]; };
    };
    enrico = {
      encryptedFile = "${secret "enrico"}";
      outputs = {
        token = { format = "raw"; secrets = [ "ENRICO_TOKEN" ]; };
        "tls.crt" = { format = "raw"; secrets = [ "TLS_CERT" ]; };
        "tls.key" = { format = "raw"; secrets = [ "TLS_KEY" ]; };
      };
    };
    backend-tls = {
      encryptedFile = "${secret "backend-tls"}";
      outputs = {
        "tls.crt" = { format = "raw"; secrets = [ "TLS_CERT" ]; };
        "tls.key" = { format = "raw"; secrets = [ "TLS_KEY" ]; };
      };
    };
    smtp = {
      encryptedFile = "${secret "smtp"}";
      outputs = {
        username = { format = "raw"; secrets = [ "SMTP_USERNAME" ]; };
        password = { format = "raw"; secrets = [ "SMTP_PASSWORD" ]; };
      };
    };
    logstore = {
      encryptedFile = "${secret "logstore"}";
      outputs = {
        "tls.crt" = { format = "raw"; secrets = [ "TLS_CERT" ]; };
        "tls.key" = { format = "raw"; secrets = [ "TLS_KEY" ]; };
        "insert.password" = { format = "raw"; secrets = [ "INSERT_PASSWORD" ]; };
        "reader.password" = { format = "raw"; secrets = [ "READER_PASSWORD" ]; };
      };
    };
  };
  # @cc [owner:ghuntley,label:security;deployment] overalls-logstore-fleet-only
  # The fleet log store entry MUST bind the WireGuard control-plane address,
  # admit only peer traffic on its port, and keep insert/reader authority split.
  # Collector sources MUST exclude audit, firecracker and guest content.
  services.overallsLogStore = {
    enable = true;
    address = controlPlaneAddress;
    certificateFile = "/run/overalls-secrets/logstore/tls.crt";
    keyFile = "/run/overalls-secrets/logstore/tls.key";
    insertPasswordFile = "/run/overalls-secrets/logstore/insert.password";
    readerPasswordFile = "/run/overalls-secrets/logstore/reader.password";
    stateDataset = "zroot/logstore";
    stateQuotaGiB = 20;
    secretUnits = [ "overalls-secrets-logstore.service" ];
  };
  systemd.services.logstore-entry = {
    after = [ "wireguard-fleet0.service" ];
    requires = [ "wireguard-fleet0.service" ];
    partOf = [ "wireguard-fleet0.service" ];
  };
  services.overallsLogging = {
    enable = true;
    secretUnits = [ "overalls-secrets-logstore.service" ];
    outputs.logstore = {
      type = "native";
      plugin = "http";
      sources = (import ../../../nix/policy/fleet/services.nix { inherit lib; }).logSources;
      queueBytes = 50331648;
      credentialFiles.http_passwd = "/run/overalls-secrets/logstore/insert.password";
      settings = {
        host = fleetServices.logStore.dnsName;
        port = fleetServices.logStore.port;
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
  # @cc [owner:ghuntley,label:security;deployment] overalls-brady-signer
  # Brady MUST start only with this host's encrypted signer bundle. The public
  # root is the guest trust anchor; its signing key stays recovery-only.
  services.brady = lib.mkIf issued {
    enable = true;
    issuerCertificateFile = "/run/overalls-secrets/brady/issuer.pem";
    issuerKeyFile = "/run/overalls-secrets/brady/issuer.key";
    secretUnits = [ "overalls-secrets-brady.service" ];
  };

  # @cc [owner:ghuntley,label:deployment] overalls-single-control-plane
  # This deployment MUST declare and start exactly one Marshall instance using
  # the local verified-TLS database. Schema migration MUST precede activation;
  # no serving startup command may migrate or bypass database/TLS validation.
  services.marshall = {
    enable = true;
    replicaCount = 1;
    publicHost = "ghuntley.dev";
    sshHostCa = {
      publicKey = pkgs.lib.removeSuffix "\n" (builtins.readFile ../../../secrets/ssh-host-ca.pub);
      keyFile = "/run/overalls-secrets/ssh-host-ca/key";
      retirement = 2421446400;
    };
    ingress.zone = "apps.ghuntley.dev";
    ingress.wildcardAcme = {
      issuerInstance = "overalls";
      directory = "https://acme-v02.api.letsencrypt.org/directory";
      issuerCaFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      certificateRootsFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      acceptTerms = true;
      nameservers = [ { addressFile = service; } ]
        ++ map (peer: { addressFile = addresses.files.${peer}; }) host.peerNameservers;
    };
    # One replica serves every LiveView timer, Oban queue and host exchange;
    # ten connections saturated under steady agent load (2026-10-23 incident).
    # Budget: 1 * (20 + 3) + 10 = 33 of the 64 PostgreSQL connections.
    poolSize = 20;
    databaseConnectionBudget = 64;
    databaseCAFile = "/etc/overalls/service-ca.crt";
    environmentFile = "/run/overalls-secrets/marshall/environment";
    serperKeyFile = "/run/overalls-secrets/marshall/serper.key";
    secretUnits = [
      "overalls-secrets-marshall.service"
      "overalls-secrets-ssh-host-ca.service"
      "overalls-secrets-backend-tls.service"
      "overalls-database-password.service"
      # The wildcard issuer's Audi DNS replica addresses (ADR-0233).
      addresses.unit
    ];
    cpuCores = 2;
    memoryMiB = 4096;
    instances.overalls = {
      bindAddress = "127.0.0.1";
      port = ports.marshallBackend;
      terminalPeerUrl = "https://ghuntley.dev:5443";
      terminalPeerCAFile = "/etc/overalls/service-ca.crt";
      fleetBindAddress = controlPlaneAddress;
      fleetLoopback = true;
      certificateFile = "/run/overalls-secrets/backend-tls/tls.crt";
      keyFile = "/run/overalls-secrets/backend-tls/tls.key";
    };
    smtpRelay = {
      enable = true;
      from = "noreply@ghuntley.dev";
      upstream = {
        provider = "resend";
        host = "smtp.resend.com";
        port = 587;
        tls = "starttls";
        usernameFile = "/run/overalls-secrets/smtp/username";
        passwordFile = "/run/overalls-secrets/smtp/password";
      };
      secretUnits = [ "overalls-secrets-smtp.service" ];
    };
  };
  services.enrico = {
    enable = true;
    bindAddress = controlPlaneAddress;
    port = fleetServices.enrico.port;
    cacheDataset = "zroot/enrico";
    cacheQuotaGiB = 100;
    tokenFile = "/run/overalls-secrets/enrico/token";
    certificateFile = "/run/overalls-secrets/enrico/tls.crt";
    keyFile = "/run/overalls-secrets/enrico/tls.key";
    secretUnits = [ "overalls-secrets-enrico.service" ];
  };
  systemd.services.enrico = {
    after = [ "wireguard-fleet0.service" ];
    requires = [ "wireguard-fleet0.service" ];
    partOf = [ "wireguard-fleet0.service" ];
  };
  networking.hosts.${controlPlaneAddress} = [ fleetServices.enrico.dnsName ];
  environment.etc."overalls/enrico-ca.crt".source = ./enrico-ca.crt;
  systemd.services.marshall-overalls = {
    after = [ "enrico.service" "wireguard-fleet0.service" ];
    wants = [ "enrico.service" ];
    requires = [ "wireguard-fleet0.service" ];
    partOf = [ "wireguard-fleet0.service" ];
    environment = {
      MARSHALL_ENRICO_URL = "https://${fleetServices.enrico.dnsName}:${toString fleetServices.enrico.port}";
      MARSHALL_ENRICO_TOKEN_FILE = "/run/credentials/marshall-overalls.service/enrico-token";
      MARSHALL_ENRICO_CA_FILE = "/run/credentials/marshall-overalls.service/enrico-ca.crt";
    };
    serviceConfig.LoadCredential = [
      "enrico-token:/run/overalls-secrets/enrico/token"
      "enrico-ca.crt:/etc/overalls/enrico-ca.crt"
    ];
  };
  services.overallsAutoUpdate.marshallHealth.overalls = {
    serverName = "ghuntley.dev";
    caFile = "/etc/overalls/service-ca.crt";
  };
  # @cc [owner:ghuntley,label:deployment;security] overalls-porsche-authority
  # Porsche MUST use verified backend HTTPS and separately encrypted gateway
  # authority. Startup MUST wait for idempotent Ash authority registration.
  services.porsche = lib.mkIf issued {
    enable = true;
    bindAddressFile = primary;
    bindAddressUnit = addresses.unit;
    controlPlane = "https://ghuntley.dev:5443";
    publicOrigin = "https://ghuntley.dev";
    caFile = "/etc/overalls/service-ca.crt";
    credentialFile = "/run/overalls-secrets/porsche/token";
    secretUnits = [ "overalls-secrets-porsche.service" "overalls-porsche-authority.service" ];
  };

  # @cc [owner:ghuntley,label:deployment;security] overalls-artifact-content-origin
  # The isolated artifact content origin stays off until a host sets
  # services.marshall.artifactContent.host. The proxy MUST then follow that
  # one value, so the colocated proxy routes, ACME issues and Marshall binds
  # the same content host on the instance's artifactPort (6443) behind the
  # existing public listener; no additional public port is opened.
  services.marshallProxy.artifactContent.host = lib.mkDefault config.services.marshall.artifactContent.host;
  services.marshallProxy = {
    enable = true;
    bindAddressFile = primary;
    bindAddressUnit = addresses.unit;
    publicHost = "ghuntley.dev";
    backendCAFile = "/etc/overalls/service-ca.crt";
    backends.overalls = {
      address = "127.0.0.1";
      port = ports.marshallBackend;
      serverName = "ghuntley.dev";
    };
    acme = {
      enable = true;
      email = "noreply@ghuntley.dev";
      # ADR-0181: the public CA must reach HTTP-01 on .55:80 through the perimeter.
      http01.publicIngress = true;
    };
  };
  security.acme.acceptTerms = true;

  # Host enrollment supplies Lilly's instance identity, credential and pool GUIDs.

  # @cc [owner:ghuntley,label:deployment;recovery] fastpath-template-producer-overalls
  # Sealed templates (ADR-0130) keep a 48 GiB per-pool budget that covers every
  # configured image (two Linux templates plus a 32 GiB firmware disk) and grant
  # no VM capacity credit or execution authority; root disks are block-cloned
  # from them on demand (ADR-0177).
  services.lilly = {
    # 96 GiB: the Linux templates plus the 64 GiB Windows disk (ADR-0173).
    imageTemplates.budgetBytes = 96 * 1024 * 1024 * 1024;
    controlPlaneCAFile = "/etc/overalls/service-ca.crt";
    # The host's own addresses arrive at runtime (ADR-0233); the effective
    # protected set, and so Lilly's network claim, is unchanged.
    protectedAddressFiles = [ primary service ];
    protectedAddressUnits = [ addresses.unit ];
    ingress.enable = true;
  };

  # @cc [owner:ghuntley,label:security;deployment] overalls-audi-public-plane
  # Audi gateway and DNS listeners MUST bind the reserved explicit address
  # (the deployment's `<name>Service` fleet address) and remain reachable from the public internet through the
  # reviewed fleet-perimeter public service entry (TCP 22/80/443 and UDP/TCP
  # 53); ordinary per-service firewall openings stay suppressed by ADR-0075.
  # Wildcard binds MUST fail evaluation against Porsche's shared port. The
  # delegated zone MUST remain a strict subzone of ghuntley.dev; the apex keeps
  # serving the proxy's HTTP-01 issuance and Porsche's public origin, so it
  # MUST never be delegated to Audi DNS.
  overalls.fleetFirewall.publicServices.audi = lib.mkIf issued {
    addressFile = service;
    addressUnit = addresses.unit;
    tcpPorts = [ 22 53 80 443 ];
    udpPorts = [ 53 ];
    comment = "Audi public gateway and DNS";
  };

  services.audiDns = lib.mkIf issued {
    enable = true;
    controlPlane = "https://ghuntley.dev:5443";
    caFile = "/etc/overalls/service-ca.crt";
    credentialFile = "/run/overalls-secrets/audi-dns/token";
    secretUnits = [ "overalls-secrets-audi-dns.service" ];
    zone = "apps.ghuntley.dev";
    nameservers = [ "ns1.ghuntley.dev" "ns2.ghuntley.dev" ];
    mailbox = "hostmaster.ghuntley.dev";
    bindAddressFile = service;
    bindAddressUnit = addresses.unit;
  };

  services.audi = lib.mkIf issued {
    # Relay only when the deployment's tunnel has a gateway peer (ADR-0239).
    relay.enable = host.audiRelay;
    enable = true;
    hostId = config.services.lilly.hostId;
    controlPlane = "https://ghuntley.dev:5443";
    caFile = "/etc/overalls/service-ca.crt";
    credentialFile = "/run/overalls-secrets/audi/token";
    secretUnits = [ "overalls-secrets-audi.service" ];
    bindAddressFile = service;
    bindAddressUnit = addresses.unit;
    tls = {
      enable = true;
      zone = "apps.ghuntley.dev";
      browserOrigin = "https://ghuntley.dev";
      certificateRootsFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
  };
}
