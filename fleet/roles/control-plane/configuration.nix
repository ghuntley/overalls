{ config, lib, pkgs, ... }:
let
  host = config.overalls.controlPlaneHost;
  secret = name: ../../../secrets + "/${host.name}-${name}.enc.json";
  ports = import ../../../nix/policy/fleet/ports.nix { };
in
{
  # Spread periodic captures across hosts, including Marshall database dumps.
  services.overallsBackups.randomizedDelaySec = 300;
  services.overallsBackups.postgres.enable = true;

  # Reviewed on the 1.73 TiB zroot mirror: the 1593 GiB guest quota leaves a
  # ~170 GiB root-side share, and 200 GiB free sits just above the ZFS
  # performance cliff. One run may reclaim the whole current root-side usage.
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
    encryptedFile = "${secret "cachix"}";
    outputs.token = { format = "raw"; secrets = [ "CACHIX_AUTH_TOKEN" ]; };
  };
  services.marshall.integrations.github = {
    clientId = "placeholder-github-client-id";
    clientSecretFile = "/run/overalls-secrets/github-oauth/secret";
    redirectUri = "https://ghuntley.dev/auth/github-com/callback";
  };
  systemd.services.cachix-watch-store-agent = {
    requires = [ "overalls-secrets-cachix.service" ];
    after = [ "overalls-secrets-cachix.service" ];
  };

  # Peers awaiting an installed identity are omitted, so the control plane keeps
  # evaluating while a replacement host is a base declaration.
  overalls.remoteBuilders = let machines = import ../../remote-builders.nix { inherit lib; }; in {
    enable = lib.attrNames machines != [ host.name ];
    localName = host.name;
    inherit machines;
  };
  imports = [ ./control-plane.nix ./services.nix ../../fleet-network.nix ];
  services.overallsOtelFleet = {
    enable = true;
    role = "central";
    # The roster's telemetry worker serves this control plane (ADR-0238).
    hosts = { central = host.name; worker = host.otelWorker; };
    tempoDataset = "zroot/tempo";
    tempoQuotaGiB = 20;
    publicGrafana = { enable = true; port = ports.publicGrafana; };
  };
  # @cc [owner:ghuntley,label:security;verification] overalls-private-browser-probe-fixtures
  # Browser probes MUST use a real operator session and separately provisioned
  # guest fixtures. Missing credentials MUST leave application health unknown.
  services.overallsBrowserProbes.instances = {
    nixos = {
      fixtureFile = "/var/lib/overalls-browser-probes/nixos/fixture.json";
      storageStateFile = "/var/lib/overalls-browser-probes/nixos/storage-state.json";
    };
    ubuntu = {
      fixtureFile = "/var/lib/overalls-browser-probes/ubuntu/fixture.json";
      storageStateFile = "/var/lib/overalls-browser-probes/ubuntu/storage-state.json";
    };
  };
  # Guest telemetry intake needs the bound Lilly and Audi private services.
  services.overallsOtelGuest.enable = lib.mkIf host.bootstrap (lib.mkForce false);
  services.overallsAutoUpdate.activationSockets = [ "marshall-fleet-relay.socket" ];
  # Port 2222 was verified before handing management port 22 to Porsche. A
  # bootstrapping deployment has no Porsche yet and keeps the base port 22.
  services.openssh.ports = lib.mkIf (!host.bootstrap) [ ports.adminSsh ];

  services.openssh.listenAddresses = lib.mkIf (!host.bootstrap) [{ addr = host.adminAddress; port = ports.adminSsh; }];
  
  # @cc [owner:ghuntley,label:recovery] overalls-administrative-ssh-boot
  # Address-bound administrative SSH MUST wait for network readiness and retry
  # slowly enough to avoid exhausting systemd's start limit during boot.
  systemd.services.sshd = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig.RestartSec = "5s";
  };
  services.openssh.openFirewall = false;
  networking.enableIPv6 = false;
  # The fleet perimeter (ADR-0075) owns every input rule; administrative SSH on
  # 2222 and mosh are reached over Tailscale and the reviewed source grants.
  programs.mosh.openFirewall = false;
  overalls.tailscale.exitNode = true;
  networking.domain = "dev";
  # Resolve public fleet names through DNS so local clients exercise the same
  # ingress paths as remote clients.
  networking.hosts."127.0.0.2" = lib.mkForce [];
  environment.etc."overalls/service-ca.crt".source = ./service-ca.crt;

  # @cc [owner:ghuntley,label:security;deployment] overalls-fleet-api-relay
  # The public fleet hostname MUST reach Marshall's authenticated TLS fleet API
  # without an /etc/hosts alias. The relay MUST preserve TLS end to end, bind
  # only the primary Overalls address, and remain source-restricted by the fleet
  # firewall; it MUST NOT expose a plaintext or wildcard listener.

  # @cc [owner:ghuntley,label:recovery] overalls-fleet-relay-socket-follows-marshall
  # The relay socket MUST stop with Marshall: a listening socket would otherwise
  # re-activate the relay, whose Requires= pulls Marshall back up while an
  # activation is stopping it (overalls, 2026-10-13). The updater restarts the
  # socket with the relay after the switch; Porsche and Audi also want it.
  # Marshall upholds the socket while active, so any start of Marshall (manual
  # or updater) restores the relay without overriding the stop above.
  systemd.services.marshall-overalls.upholds = [ "marshall-fleet-relay.socket" ];
  systemd.sockets.marshall-fleet-relay = {
    description = "Source-restricted Marshall fleet API relay";
    # The address arrives at runtime (ADR-0233); the socket has no static
    # listener and starts once overalls-runtime-socket-marshall-fleet-relay
    # has written its drop-in.
    wantedBy = [];
    partOf = [ "marshall-overalls.service" ];
    socketConfig.FreeBind = true;
  };
  overalls.runtimeSockets.marshall-fleet-relay = {
    addressFile = config.overalls.fleetAddresses.files."${host.name}Primary";
    addressUnit = config.overalls.fleetAddresses.unit;
    port = ports.marshallFleet;
  };
  # @cc [owner:ghuntley,label:recovery] overalls-gateway-certificate-transport
  # Initial gateway certificate acquisition MUST activate the local fleet API
  # socket after updater quiescence, rather than wait for post-gateway restore.
  systemd.services.porsche = lib.mkIf (!host.bootstrap) {
    wants = [ "marshall-fleet-relay.socket" ];
    after = [ "marshall-fleet-relay.socket" ];
  };
  systemd.services.audi = lib.mkIf (!host.bootstrap) {
    wants = [ "marshall-fleet-relay.socket" ];
    after = [ "marshall-fleet-relay.socket" ];
  };
  systemd.services.marshall-fleet-relay = {
    description = "Relay the public fleet address to Marshall's loopback TLS listener";
    after = [ "marshall-overalls.service" ];
    requires = [ "marshall-overalls.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString ports.marshallFleet}";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
    };
  };

  services.overallsSecrets.bundles.database = {
    encryptedFile = "${secret "database"}";
    outputs = {
      "environment" = { format = "environment"; secrets = [ "DB_PASSWORD" ]; };
      "tls.crt" = { format = "raw"; secrets = [ "DB_CERT" ]; };
      "tls.key" = { format = "raw"; secrets = [ "DB_KEY" ]; };
    };
  };

  # @cc [owner:ghuntley,label:security] overalls-private-database
  # PostgreSQL MUST listen only on loopback, require verified TLS/SCRAM for
  # Marshall TCP connections, and retain durable WAL writes. Private TLS keys
  # and passwords MUST come from runtime secrets, never Nix values or arguments.
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
    enableTCPIP = true;
    ensureDatabases = [ "marshall" ];
    ensureUsers = [{ name = "marshall"; ensureDBOwnership = true; }];
    authentication = lib.mkForce ''
      local all postgres peer
      hostssl marshall marshall 127.0.0.1/32 scram-sha-256
    '';
    settings = {
      listen_addresses = lib.mkForce "127.0.0.1";
      max_connections = 64;
      ssl = true;
      ssl_cert_file = "/var/lib/postgresql/tls/server.crt";
      ssl_key_file = "/var/lib/postgresql/tls/server.key";
      ssl_min_protocol_version = "TLSv1.2";
      password_encryption = "scram-sha-256";
      fsync = true;
      full_page_writes = true;
      synchronous_commit = "on";
      log_statement = "none";
      log_min_error_statement = "panic";
    };
  };

  # @cc [owner:ghuntley,label:recovery;security] overalls-database-tls-follows-secret
  # A rotated database certificate MUST reach PostgreSQL on activation: the copy
  # reruns whenever the encrypted document changes and reloads a running server,
  # so clients verifying the rotated service CA never meet the previous leaf.
  systemd.services.overalls-database-tls = {
    before = [ "postgresql.service" ];
    after = [ "overalls-secrets-database.service" ];
    requires = [ "overalls-secrets-database.service" ];
    restartTriggers = [ config.services.overallsSecrets.bundles.database.encryptedFile ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    script = ''
      install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/tls
      install -m 0600 -o postgres -g postgres /run/overalls-secrets/database/tls.crt /var/lib/postgresql/tls/server.crt
      install -m 0600 -o postgres -g postgres /run/overalls-secrets/database/tls.key /var/lib/postgresql/tls/server.key
      if ${pkgs.systemd}/bin/systemctl is-active --quiet postgresql.service; then
        ${pkgs.systemd}/bin/systemctl reload postgresql.service
      fi
    '';
  };
  systemd.services.postgresql = {
    after = [ "overalls-database-tls.service" ];
    requires = [ "overalls-database-tls.service" ];
  };
  systemd.services.overalls-database-password = {
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql-setup.service" "overalls-secrets-database.service" ];
    requires = [ "postgresql-setup.service" "overalls-secrets-database.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      Group = "postgres";
      UMask = "0077";
      EnvironmentFile = "/run/overalls-secrets/database/environment";
    };
    script = ''
      if ! ${config.services.postgresql.package}/bin/psql --no-psqlrc --set=ON_ERROR_STOP=1 --dbname=postgres --file=${pkgs.writeText "overalls-database-password.sql" ''
        \getenv marshall_password DB_PASSWORD
        ALTER ROLE marshall WITH LOGIN PASSWORD :'marshall_password';
      ''} >/dev/null 2>&1; then
        echo "Marshall database credential setup failed" >&2
        exit 1
      fi
    '';
  };
  # Re-authenticate the freshly installed host before publishing tailnet HTTPS.
  services.underclass.tailscaleServe.enable = lib.mkForce false;
}
