{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  tools = packages.secretTools;
  root = "/var/lib/overalls-fleet";
  names = [
    "DATABASE_URL" "MARSHALL_CLOAK_KEYS" "SECRET_KEY_BASE" "TOKEN_SIGNING_SECRET"
    "MARSHALL_SMTP_HOST" "MARSHALL_SMTP_USERNAME" "MARSHALL_SMTP_PASSWORD"
    "MARSHALL_SMTP_CA_CERTFILE" "MARSHALL_MAIL_FROM"
  ];
  marshall = name: { config, ... }: {
    imports = [ (import ../../support/update-fixture.nix { inherit pkgs; inherit (packages) buck2; }).module ];
    system.switch.enable = true;
    services.overallsAutoUpdate = {
      enable = true;
      repository = "/var/lib/overalls-update-test/git";
      flakeAttr = "host";
      marshallHealth.${name} = { serverName = name; caFile = "${root}/ca.crt"; };
    };
    systemd.timers.overalls-auto-update.wantedBy = lib.mkForce [];
    environment.etc."overalls-update-candidates.json".text = builtins.toJSON {
      updated = "${config.specialisation.updated.configuration.system.build.overallsDeployment}";
      broken = "${config.specialisation.broken.configuration.system.build.overallsDeployment}";
    };
    specialisation = {
      updated.configuration = {
        environment.etc."overalls-update-candidates.json".enable = lib.mkForce false;
        environment.etc."overalls-update-generation".text = "updated";
        services.overallsAutoUpdate.verbose = lib.mkForce true;
        services.marshall.package = lib.mkForce (packages.marshall.overrideAttrs (previous: {
          postInstall = (previous.postInstall or "") + ''
            migrations=$(echo "$out"/lib/marshall-*/priv/repo/migrations)
            cat > "$migrations/20990101000000_update_success.exs" <<'ELIXIR'
            defmodule Marshall.Repo.Migrations.UpdateSuccess do
              use Ecto.Migration
              def up do
                execute "SELECT pg_sleep(20)"
                create table(:updater_fixture) do
                  add :marker, :text, null: false
                end
                execute "INSERT INTO updater_fixture (marker) VALUES ('once')"
              end
              def down, do: drop(table(:updater_fixture))
            end
            ELIXIR
          '';
        }));
      };
      broken.configuration = {
        environment.etc."overalls-update-candidates.json".enable = lib.mkForce false;
        # Exercise an actual failing migration from an otherwise runnable release.
        services.marshall.package = lib.mkForce (packages.marshall.overrideAttrs (previous: {
          postInstall = (previous.postInstall or "") + ''
            migrations=$(echo "$out"/lib/marshall-*/priv/repo/migrations)
            cat > "$migrations/20990101000001_update_failure.exs" <<'ELIXIR'
            defmodule Marshall.Repo.Migrations.UpdateFailure do
              use Ecto.Migration
              def up, do: raise("isolated migration failure")
              def down, do: :ok
            end
            ELIXIR
          '';
        }));
      };
    };
    virtualisation.memorySize = 2048;
    services.overallsSecrets = {
      enable = true;
      bundles.marshall = {
        encryptedFile = "${root}/marshall.enc.json";
        outputs.environment = { format = "environment"; secrets = names; };
      };
    };
    services.marshall = {
      enable = true;
      publicHost = "control.example.test";
      poolSize = 2;
      databaseConnectionBudget = 25;
      cpuCores = 1;
      memoryMiB = 1536;
      environmentFile = "${config.services.overallsSecrets.bundles.marshall.directory}/environment";
      databaseCAFile = "${root}/ca.crt";
      secretUnits = [ "rotation-ready.service" config.services.overallsSecrets.bundles.marshall.unit ];
      openFirewall = true;
      instances.${name} = {
        port = 4443;
        bindAddress = "0.0.0.0";
        # Host credentials authenticate only on the separate fleet listener.
        fleetBindAddress = config.networking.primaryIPAddress;
        certificateFile = "${root}/tls.crt";
        keyFile = "${root}/tls.key";
      };
    };
    systemd.services = {
      rotation-delivered = {
        script = "while [ ! -f ${root}/delivered ]; do sleep 1; done";
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 300; };
      };
      rotation-ready = {
        script = "while [ ! -f ${root}/ready ]; do sleep 1; done";
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 300; };
      };
      overalls-secrets-marshall = {
        after = [ "rotation-delivered.service" ];
        requires = [ "rotation-delivered.service" ];
      };
      rotation-probe = {
        environment = {
          PHX_SERVER = "false";
          PHX_HOST = "control.example.test";
          RELEASE_DISTRIBUTION = "none";
          RELEASE_COOKIE = "isolated-rotation-probe";
          RELEASE_TMP = "/run/rotation-probe";
          ERL_CRASH_DUMP = "/dev/null";
          ERL_FLAGS = "+S 2:2";
          MARSHALL_INSTANCE_ID = "rotation-probe-${name}";
          MARSHALL_REPLICA_COUNT = "3";
          MARSHALL_DB_CONNECTION_BUDGET = "25";
          POOL_SIZE = "2";
          MARSHALL_DB_TLS = "verify";
          MARSHALL_DB_CA_CERTFILE = "${root}/ca.crt";
        };
        script = ''
          exec ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./probe.exs}")'
        '';
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.services.marshall.environmentFile;
          RuntimeDirectory = "rotation-probe";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = 120;
        };
      };
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "overalls-credential-rotation";
  globalTimeout = 1200;
  defaults = { lib, ... }: {
    imports = [ module ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = lib.mkDefault 1024;
    virtualisation.cores = 2;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    environment.systemPackages = [ pkgs.curl pkgs.openssh pkgs.python3 pkgs.git pkgs.nix tools.sops tools.ssh-to-age
      (pkgs.writeShellScriptBin "rotation-fixture" ''
        exec ${pkgs.python3}/bin/python ${./fixture.py} "$@"
      '')
    ];
    systemd.tmpfiles.rules = [ "d ${root} 0700 root root -" ];
  };
  nodes = {
    m1 = marshall "m1";
    m2 = marshall "m2";
    m3 = marshall "m3";
    db = { config, ... }: {
      environment.etc."rotation-db-address".text = config.networking.primaryIPAddress;
      imports = [ (import ../../support/fleet-database.nix {
        generationService = "rotation-generate";
        maxConnections = 32;
        allowedNetwork = "192.168.1.0/24";
      }) ];
    };
  };
  testScript = lib.concatMapStringsSep "\n" builtins.readFile [
    ../../support/transfer.py ../../support/update.py ./driver.py ./updates.py
  ];
}
