{ pkgs, module, packages }:
let
  inherit (pkgs) lib;
  # Reviewed static upstream tool and matching browser specification types.
  bombadil = pkgs.stdenvNoCC.mkDerivation {
    pname = "bombadil-localization-test";
    version = "0.7.7";
    src = pkgs.fetchurl {
      url = "https://github.com/antithesishq/bombadil/releases/download/v0.7.7/bombadil-x86_64-linux";
      sha256 = (import ../../../../domains/artifacts/pins.nix).bombadilBinary;
    };
    dontUnpack = true;
    installPhase = ''install -Dm755 "$src" "$out/bin/bombadil"'';
    meta.platforms = [ "x86_64-linux" ];
  };
  types = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@antithesishq/bombadil/-/bombadil-0.7.7.tgz";
    sha256 = (import ../../../../domains/artifacts/pins.nix).bombadilTypes;
  };
  probes = pkgs.runCommand "localization-browser-probe-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.ruff pkgs.typescript pkgs.gnutar pkgs.gzip ];
  } ''
    mkdir -p "$out/node_modules/@antithesishq/bombadil"
    cp ${../../../../../marshall/scripts/localization_browser/run.py} "$out/run.py"
    cp ${../../../../../marshall/scripts/localization_browser/probe.ts} "$out/probe.ts"
    cp ${../../../../../marshall/scripts/localization_browser/tsconfig.json} "$out/tsconfig.json"
    tar -xzf ${types} --strip-components=1 -C "$out/node_modules/@antithesishq/bombadil"
    ruff format --check --line-length 100 --target-version py313 "$out/run.py"
    ruff check --isolated --select E,F,I,ANN --line-length 100 --target-version py313 "$out/run.py"
    ty check --python ${pkgs.python313}/bin/python3 "$out/run.py"
    tsc --project "$out/tsconfig.json"
  '';
in
(pkgs.testers.runNixOSTest {
  name = "overalls-localization-account-porsche";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall = {
      enable = true;
      poolSize = lib.mkForce 10;
      databaseConnectionBudget = lib.mkForce 64;
      publicHost = lib.mkForce "localhost";
    };
    services.marshallProxy = {
      enable = true;
      publicHost = lib.mkForce "localhost";
    };
    services.porsche = {
      enable = true;
      package = packages.porsche;
      controlPlane = "https://localhost:5443";
      publicOrigin = "https://control.example.test";
      credentialFile = "/run/overalls-test/gateway.token";
      caFile = "/run/overalls-test/ca.crt";
      administrativeAccess = "console";
      openFirewall = true;
    };
    systemd.services.porsche.wantedBy = lib.mkForce [];
    networking.extraHosts = "127.0.0.1 control.example.test\n";
    environment.systemPackages = [ pkgs.python313 pkgs.chromium pkgs.nssTools pkgs.openssh bombadil ];
    systemd.services.localization-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = { Type = "oneshot"; EnvironmentFile = "/run/overalls-test/marshall.env"; UMask = "0077"; };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=localization-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
    environment.etc."localization-browser-context.py".source = ./context.py;
    environment.etc."localization-set-locale.exs".source = ./set-locale.exs;
  };
  # @cc [owner:ghuntley,label:verification] packaged-localization-journey
  # Language selection MUST use real packaged browser forms. Porsche MUST use
  # real SSH, certificate trust and Marshall locale authority. Metadata-only
  # execution MUST NOT establish guest isolation or independent translation quality.
  testScript = ''
    import json
    import shlex

    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost/health/ready", timeout=120)
    web.succeed("ssh-keygen -q -t ed25519 -N ${lib.escapeShellArg ""} -f /run/overalls-test/localization-key")
    web.succeed("systemctl start localization-seed.service")
    web.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    web.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    web.succeed("python3 /etc/localization-browser-context.py")
    with subtest("all 28 account locales persist across real routes"):
        web.succeed("python3 ${probes}/run.py /run/overalls-test/localization-context.json /run/overalls-test/localization-browser", timeout=960)
    with subtest("Porsche derives human language from durable account authority and preserves JSON"):
        web.succeed("systemctl start porsche.service")
        web.wait_for_open_port(22)
        ca = web.succeed("ssh-keygen -y -f /run/overalls-test/ssh-host-ca").split()
        web.succeed("printf '%s\\n' " + shlex.quote("@cert-authority control.example.test " + " ".join(ca[:2])) + " > /run/overalls-test/localization-known-hosts")
        ssh = "ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com -o UserKnownHostsFile=/run/overalls-test/localization-known-hosts -o IdentitiesOnly=yes -o ConnectTimeout=5 -i /run/overalls-test/localization-key untrusted@control.example.test "
        expected = ${builtins.toJSON (builtins.fromJSON (builtins.readFile ./expected-help.json))}
        def ssh_reply(command: str) -> str:
            status, output = web.execute(ssh + shlex.quote(command))
            if status != 0:
                raise RuntimeError("Packaged localization SSH request failed")
            return output

        baseline: object | None = None
        for locale, translated in expected.items():
            web.succeed("systemd-run --quiet --wait --pipe --property=EnvironmentFile=/run/overalls-test/marshall.env --setenv=LOCALIZATION_TEST_LOCALE=" + locale + " --setenv=MARSHALL_INSTANCE_ID=localization-locale --setenv=MARSHALL_DB_TLS=verify ${pkgs.coreutils}/bin/env -u PORT ${packages.marshall}/bin/marshall eval 'Code.eval_file(\"/etc/localization-set-locale.exs\")'")
            human = ssh_reply("help")
            assert translated in human, "Porsche help did not use the saved account language"
            assert "show" in human, "Localized help changed command tokens"
            raw = ssh_reply("help --json")
            decoded: object = json.loads(raw)
            assert isinstance(decoded, dict) and decoded.get("version") == 1
            if baseline is None:
                baseline = decoded
            else:
                assert decoded == baseline, "Locale changed machine-readable help"
  '';
}) // { inherit probes bombadil; }
