# Hermetic Mila journey backend (ADR-0264): source-built Marshall, PostgreSQL
# and Porsche on one NixOS machine, plus a bearer-protected browser approver.
# The machine test and the `mila-journey-fixture` launcher import this same
# module; only the launcher adds QEMU port forwarding and a shared directory.
{ module, packages }:
{ config, lib, pkgs, ... }:
let
  host = "localhost";
  httpsPort = 8443;
  sshPort = 2222;
  approverPort = 8444;
  origin = "https://${host}:${toString httpsPort}";
  syntheticImage = "sha256:c898e080d9147dcfed2f21d4d3c88c6370ed78f41d8764dd8b89acbf58c707c2";
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # The executed approver passes its own type check against the packaged
  # Playwright runtime, independently of the composed driver gate.
  approver = pkgs.runCommand "mila-journey-approver-typed" { nativeBuildInputs = [ pkgs.ty ]; } ''
    mkdir -p "$out"
    cp ${./approver.py} "$out/approver.py"
    ty check --python ${python}/bin/python3 "$out/approver.py"
  '';
  terminalPython = pkgs.python3.withPackages (p: [ p.websockets ]);
  # The guest terminal stand-in passes its own type check against its runtime.
  terminalHost = pkgs.runCommand "mila-journey-terminal-host-typed" { nativeBuildInputs = [ pkgs.ty ]; } ''
    mkdir -p "$out"
    cp ${./terminal_host.py} "$out/terminal_host.py"
    ty check --python ${terminalPython}/bin/python3 "$out/terminal_host.py"
  '';
  marshallEnvironment = config.systemd.services.overalls-test-migrate.environment;
  action = pkgs.writeShellScriptBin "mila-fixture-action" ''
    set -eu
    install -d -m 0700 /run/mila-fixture
    set -a; . /run/overalls-test/marshall.env; set +a
    exec ${pkgs.coreutils}/bin/env -u PORT ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") marshallEnvironment)} \
      MARSHALL_INSTANCE_ID="mila-fixture-$1" MARSHALL_DB_TLS=verify MILA_FIXTURE_ACTION="$1" \
      ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./fixture.exs}")'
  '';
  # @cc [owner:ghuntley,label:verification;security] mila-fixture-descriptor-private
  # The descriptor carries the approver bearer and is written owner-only. Its
  # deployment host MUST equal Marshall's public host, which is the trust
  # document's management host and the Porsche certificate principal.
  descriptor = pkgs.writeShellScript "mila-fixture-descriptor" ''
    set -eu
    umask 077
    ${pkgs.jq}/bin/jq -n \
      --rawfile ca /run/overalls-test/ca.crt \
      --rawfile token /run/mila-fixture/approver.token \
      --slurpfile seed /run/mila-fixture/seed.json \
      '{version: 1,
        deployment: {host: "${host}", ssh_port: ${toString sshPort}, https_port: ${toString httpsPort}},
        tls: {ca_pem: $ca, server_name: "${host}"},
        approver: {url: "https://${host}:${toString approverPort}/approve",
                   fixture_url: "https://${host}:${toString approverPort}/fixture/",
                   bearer_token: ($token | rtrimstr("\n"))},
        seed: {machine_name: $seed[0].machine_name, machine_id: $seed[0].machine_id,
               terminal_machine_name: $seed[0].terminal_machine_name,
               terminal_machine_id: $seed[0].terminal_machine_id,
               share_principal: $seed[0].member_email, account_email: $seed[0].owner_email}}' \
      > /run/mila-fixture/descriptor.json.tmp
    mv /run/mila-fixture/descriptor.json.tmp /run/mila-fixture/descriptor.json
  '';
in
{
  imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
  virtualisation.memorySize = lib.mkForce 4096;
  virtualisation.cores = lib.mkForce 4;
  services.marshall = {
    enable = true;
    # The synthetic catalog image's content identity (fixture.exs `image/0`).
    defaultImageId = syntheticImage;
    publicHost = lib.mkForce host;
    instances.${config.networking.hostName} = {
      port = lib.mkForce httpsPort;
      bindAddress = "0.0.0.0";
    };
  };
  services.porsche = {
    enable = true;
    package = packages.porsche;
    port = sshPort;
    controlPlane = "https://localhost:${toString (httpsPort + 1000)}";
    publicOrigin = origin;
    credentialFile = "/run/overalls-test/gateway.token";
    caFile = "/run/overalls-test/ca.crt";
    administrativeAccess = "console";
    openFirewall = true;
  };
  systemd.services.porsche.wantedBy = lib.mkForce [];
  networking.firewall.allowedTCPPorts = [ httpsPort approverPort ];
  environment.systemPackages = [ action python pkgs.chromium pkgs.nssTools pkgs.curl pkgs.jq ];

  systemd.services.mila-fixture-approver = {
    description = "Mila journey browser approver";
    after = [ "overalls-test-fixture.service" ];
    requires = [ "overalls-test-fixture.service" ];
    path = [ action pkgs.nssTools ];
    environment.HOME = "/var/lib/mila-fixture-approver";
    serviceConfig = { StateDirectory = "mila-fixture-approver"; StateDirectoryMode = "0700"; UMask = "0077"; };
    preStart = ''
      install -d -m 0700 /run/mila-fixture "$HOME/.pki/nssdb"
      if [ ! -e "$HOME/.pki/nssdb/cert9.db" ]; then certutil -N --empty-password -d "sql:$HOME/.pki/nssdb"; fi
      certutil -D -d "sql:$HOME/.pki/nssdb" -n mila-fixture 2>/dev/null || true
      certutil -A -d "sql:$HOME/.pki/nssdb" -n mila-fixture -t C,, -i /run/overalls-test/ca.crt
    '';
    script = ''
      exec ${python}/bin/python3 ${approver}/approver.py ${origin} mila-fixture-action \
        ${toString approverPort} /run/overalls-test/tls.crt /run/overalls-test/tls.key
    '';
  };

  # Synthetic host control session and one-second headroom reports (no guest).
  systemd.services.mila-fixture-host = {
    description = "Mila journey synthetic host reports";
    path = [ action ];
    serviceConfig = { Restart = "always"; RestartSec = 2; UMask = "0077"; };
    script = "exec mila-fixture-action host";
  };

  # Guest shells for the terminal stand-in run as this unprivileged account.
  users.users.mila-guest = {
    isNormalUser = true;
    home = "/home/mila-guest";
    shell = pkgs.bashInteractive;
  };

  # Guest terminal stand-in (terminal_host.py): Lilly's terminal stream plus
  # terminald for the seeded terminal machine, backed by real PTYs.
  systemd.services.mila-fixture-terminal = {
    description = "Mila journey guest terminal stand-in";
    after = [ "mila-fixture-host.service" ];
    path = [ pkgs.bashInteractive pkgs.coreutils ];
    serviceConfig = { Restart = "always"; RestartSec = 2; UMask = "0077"; };
    script = ''
      until [ -s /run/mila-fixture/terminal-host.json ]; do sleep 1; done
      exec ${terminalPython}/bin/python3 -I ${terminalHost}/terminal_host.py \
        /run/mila-fixture/terminal-host.json /run/overalls-test/ca.crt
    '';
  };

  # @cc [owner:ghuntley,label:verification] mila-fixture-explicit-start
  # The fixture's schema migration and seed run only when this unit is started
  # explicitly (by the machine test or the launcher), never at module boot.
  systemd.services.mila-fixture = {
    description = "Seed and start the Mila journey backend";
    after = [ "postgresql-setup.service" "marshall-${config.networking.hostName}.service" ];
    path = [ action pkgs.curl pkgs.systemd pkgs.openssh pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; TimeoutStartSec = 900; };
    script = ''
      set -eu
      systemctl start overalls-test-migrate.service
      until curl -fsS --cacert /run/overalls-test/ca.crt ${origin}/health/ready >/dev/null; do sleep 1; done
      [ -s /run/mila-fixture/seed.json ] || mila-fixture-action seed
      rm -f /run/mila-fixture/terminal-host.json
      systemctl start mila-fixture-host.service porsche.service mila-fixture-approver.service
      until [ -s /run/mila-fixture/terminal-host.json ]; do sleep 1; done
      systemctl start mila-fixture-terminal.service
      # Ready only once Porsche presents its Marshall-issued host certificate.
      until ssh-keyscan -c -p ${toString sshPort} 127.0.0.1 2>/dev/null | grep -q 'ssh-ed25519-cert-v01@openssh.com'; do sleep 1; done
      until curl -fsS --cacert /run/overalls-test/ca.crt ${origin}/bin/ssh-trust.json >/dev/null; do sleep 1; done
      until [ -s /run/mila-fixture/approver.token ]; do sleep 1; done
      ${descriptor}
    '';
  };
}
