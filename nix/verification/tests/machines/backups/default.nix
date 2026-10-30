{ pkgs, module, packages }:
let
  fixturePkgs = import pkgs.path {
    system = pkgs.stdenv.hostPlatform.system;
    # Pinned legacy MinIO is only an isolated S3 protocol fixture with
    # synthetic credentials, never a production service recommendation.
    config.permittedInsecurePackages = [ "minio-2025-10-15T17-29-55Z" ];
  };
  # Synthetic credentials and CA exist only inside this isolated test closure.
  tls = pkgs.runCommand "backup-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=backup-fixture \
      -keyout $out/ca.key -out $out/ca.crt
    for name in s3.test db.test; do
      openssl req -newkey rsa:2048 -nodes -subj /CN=$name -keyout $out/$name.key -out $name.csr
      echo "subjectAltName=DNS:$name" > $name.ext
      openssl x509 -req -in $name.csr -CA $out/ca.crt -CAkey $out/ca.key -CAcreateserial \
        -days 3650 -extfile $name.ext -out $out/$name.crt
    done
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-backup-recovery";
  nodes = {
    storage = { config, lib, ... }: {
      imports = [ module ];
      system.stateVersion = "26.05";
      networking.hostId = "aabbccdd";
      networking.extraHosts = "127.0.0.1 s3.test\n192.168.1.1 db.test\n";
      boot.supportedFilesystems = [ "zfs" ];
      boot.extraModprobeConfig = "options zfs zfs_arc_max=268435456";
      systemd.services.zfs-zed.enable = false;
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      virtualisation.emptyDiskImages = [ 4096 ];
      virtualisation.qemu.forceAccel = lib.mkForce true;
      services.marshall = {
        enable = true;
        publicHost = "unused.test";
        databaseConnectionBudget = 43;
        environmentFile = "/run/backup-fixture/marshall.env";
        databaseCAFile = "${tls}/ca.crt";
        secretUnits = [];
        instances.fixture = { port = 4443; certificateFile = "/run/unused.crt"; keyFile = "/run/unused.key"; };
      };
      systemd.services.marshall-fixture.enable = false;
      systemd.services.backup-cloak-probe = {
        environment = {
          PHX_SERVER = "false";
          PHX_HOST = "control.example.test";
          RELEASE_DISTRIBUTION = "none";
          RELEASE_COOKIE = "isolated-backup-cloak-probe";
          RELEASE_TMP = "/run/backup-cloak-probe";
          ERL_CRASH_DUMP = "/dev/null";
          ERL_FLAGS = "+S 2:2";
          MARSHALL_INSTANCE_ID = "backup-cloak-probe";
          MARSHALL_REPLICA_COUNT = "1";
          MARSHALL_DB_CONNECTION_BUDGET = "25";
          POOL_SIZE = "2";
          MARSHALL_MAIL_TRANSPORT = "local_relay";
          MARSHALL_SMTP_HOST = "127.0.0.1";
          MARSHALL_MAIL_FROM = "backup-fixture@example.test";
        };
        script = ''
          exec ${config.services.marshall.package}/bin/marshall eval 'Code.eval_file("${./cloak-probe.exs}")'
        '';
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = "/run/backup-fixture/marshall.env";
          RuntimeDirectory = "backup-cloak-probe";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = 180;
        };
      };
      services.overallsBackups = {
        enable = true;
        defaults.enable = false;
        extraPaths = [ "/persistent" ];
        s3 = { endpoint = "https://s3.test"; bucket = "backups"; region = "us-east-1"; };
        passwordFile = "/run/backup-fixture/password";
        environmentFile = "/run/backup-fixture/s3.env";
        secretUnits = [];
        postgres.enable = true;
        retention.keepLast = 2;
        # A real upload window wide enough for the operator kill below, without
        # changing transport coverage for the small recovery points.
        uploadLimitKiB = 8192;
        excludePaths = [ "/persistent/disposable.txt" ];
        randomizedDelaySec = 300;
      };
      systemd.timers = lib.genAttrs
        [ "overalls-backup" "overalls-backup-prune" "overalls-backup-check" "overalls-backup-read-check" "overalls-backup-cleanup" ]
        (_: { wantedBy = lib.mkForce []; });
      systemd.services.overalls-backup-cleanup.wantedBy = lib.mkForce [];
      security.pki.certificateFiles = [ "${tls}/ca.crt" ];
      services.minio = { enable = true; package = fixturePkgs.minio; rootCredentialsFile = pkgs.writeText "fixture-minio.env" ''
        MINIO_ROOT_USER=fixture-access
        MINIO_ROOT_PASSWORD=fixture-secret-password
      ''; };
      services.nginx = {
        enable = true;
        virtualHosts."s3.test" = {
          forceSSL = true;
          sslCertificate = "${tls}/s3.test.crt";
          sslCertificateKey = "${tls}/s3.test.key";
          extraConfig = "client_max_body_size 0;";
          locations."/" = {
            proxyPass = "http://127.0.0.1:9000";
            extraConfig = "proxy_set_header Host s3.test;";
          };
        };
      };
      users.users.recovery = { isSystemUser = true; group = "recovery"; };
      users.groups.recovery = {};
      environment.systemPackages = [ pkgs.minio-client pkgs.jq pkgs.postgresql_18 pkgs.python3 pkgs.curl
        config.boot.zfs.package ];
    };
    database = { config, lib, ... }: {
      system.stateVersion = "26.05";
      networking.firewall.allowedTCPPorts = [ 6543 ];
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_18;
        enableTCPIP = true;
        settings = { port = 6543; ssl = true;
          ssl_cert_file = "${tls}/db.test.crt"; ssl_key_file = "/run/postgresql/fixture.key"; };
        authentication = lib.mkForce ''
          local all all trust
          hostssl control marshall 192.168.1.0/24 scram-sha-256
        '';
        initialScript = pkgs.writeText "backup-database.sql" ''
          CREATE ROLE marshall LOGIN PASSWORD 'fixture-db-password';
          CREATE DATABASE control OWNER marshall;
          \connect control
          SET ROLE marshall;
          CREATE TABLE recovery_probe (id integer PRIMARY KEY, value text NOT NULL);
          INSERT INTO recovery_probe VALUES (1, 'recover-me');
        '';
      };
      systemd.services.postgresql.preStart = lib.mkBefore ''
        install -m 0600 ${tls}/db.test.key /run/postgresql/fixture.key
      '';
    };
  };
  testScript = builtins.readFile ./driver.py;
}
