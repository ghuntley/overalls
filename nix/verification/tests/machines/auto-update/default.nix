{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-auto-update";
  nodes.host = { config, lib, ... }:
    let
      variants = [ "one" "two" "unhealthy" ];
      relay = pkgs.writeText "update-relay.py" ''
        import socket

        listener: socket.socket = socket.fromfd(3, socket.AF_INET, socket.SOCK_STREAM)
        while True:
            connection, _ = listener.accept()
            with connection:
                connection.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok")
      '';
      candidates = (lib.genAttrs variants (name:
        "${config.specialisation.${name}.configuration.system.build.overallsDeployment}")) // {
        binding-change = "${pkgs.runCommand "overalls-binding-change" {} ''
          mkdir -p "$out"
          ln -s ${config.specialisation.two.configuration.system.build.toplevel} "$out/system"
          ${pkgs.jq}/bin/jq '.installationBinding = {platform: "ec2"}' \
            ${config.specialisation.two.configuration.system.build.overallsDeployment}/manifest.json > "$out/manifest.json"
        ''}";
        unready = "${pkgs.runCommand "overalls-health-candidate" {} ''
          mkdir -p "$out"
          ln -s ${config.specialisation.two.configuration.system.build.toplevel} "$out/system"
          ${pkgs.jq}/bin/jq '.healthUnits = ["update-health.service"] | .consumers += ["update-unused.service"]' \
            ${config.specialisation.two.configuration.system.build.overallsDeployment}/manifest.json > "$out/manifest.json"
        ''}";
      };
    in {
      imports = [ module (import ../../support/update-fixture.nix { inherit pkgs; inherit (packages) buck2; }).module ];
      system.stateVersion = "26.05";
      system.switch.enable = true;
      virtualisation.memorySize = 2048;
      services.overallsAutoUpdate = {
        enable = true;
        repository = "/var/lib/overalls-update-test/git";
        flakeAttr = "host";
        healthTimeout = 10;
        # Bounds the hanging-candidate subtest; fixture builds take seconds.
        buildTimeout = 90;
        activationSockets = [ "update-relay.socket" ];
      };
      # The driver controls update boundaries. Production timer wiring remains
      # exercised by evaluation checks and its boot-created unit.
      systemd.timers.overalls-auto-update.wantedBy = lib.mkForce [];
      environment.systemPackages = [ pkgs.git pkgs.nix pkgs.python3 ];
      systemd.slices.lilly = {
        unitConfig.X-RestartIfChanged = false;
        sliceConfig = { CPUQuota = "100%"; MemoryMax = "256M"; };
      };
      systemd.services.update-health.script = ''
        if [ -e /var/lib/update-health-allowed ]; then exec sleep infinity; fi
      '';
      systemd.services.update-unused.script = "touch /var/lib/unwanted-updater-start; exit 1";
      systemd.sockets.update-relay = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "127.0.0.1:47191" ];
      };
      systemd.services.update-relay.serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.python3}/bin/python ${relay}";
      };
      systemd.services.update-relay-probe.script = ''
        while true; do
          ${pkgs.curl}/bin/curl --silent --fail --max-time 1 http://127.0.0.1:47191/ >/dev/null || true
          sleep 0.1
        done
      '';
      environment.etc."overalls-update-candidates.json".text = builtins.toJSON candidates;
      specialisation = lib.genAttrs variants (name: {
        configuration = {
          systemd.slices.lilly.sliceConfig = {
            CPUQuota = lib.mkForce (if name == "two" then "200%" else "100%");
            MemoryMax = lib.mkForce (if name == "two" then "384M" else "256M");
          };
          environment.etc."overalls-update-candidates.json".enable = lib.mkForce false;
          environment.etc."overalls-update-generation".text = name;
          services.overallsAutoUpdate.verbose = lib.mkForce (name == "two");
          # A real required service fails activation; no switch command stub.
          systemd.services.update-fixture = lib.mkIf (name == "unhealthy") {
            wantedBy = [ "multi-user.target" ];
            script = "exit 1";
            serviceConfig.Type = "oneshot";
          };
        };
      });
    };
  testScript = pkgs.lib.concatMapStringsSep "\n" builtins.readFile [ ../../support/update.py ./driver.py ];
}
