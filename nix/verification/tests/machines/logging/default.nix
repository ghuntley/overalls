{ pkgs, packages }:
let
  tls = pkgs.runCommand "logging-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $out/key.pem -out $out/cert.pem \
      -subj /CN=sink -addext subjectAltName=DNS:sink -days 36500 >/dev/null 2>&1
  '';
  host = { ... }: {
    imports = [ (import ../../../../domains/system/logging { inherit packages; }) ];
    environment.systemPackages = [ pkgs.curl ];
    services.overallsLogging = {
      enable = true;
      environment = "fixture";
      # Disposable VM disks are smaller than production's two-GiB free guard.
      # Keep previous-boot journal evidence instead of vacuuming it on rotation.
      journalMaxBytes = 67108864;
      journalKeepFreeBytes = 16777216;
      aws = { mode = "file"; credentialsFile = "/run/logging-fixture/credentials"; };
      secretUnits = [ "logging-fixture-credentials.service" ];
      outputs.cloud = {
        type = "cloudwatch"; region = "us-east-1";
        sources = [ "system" "operations" "kernel" ]; queueBytes = 8388608;
        settings = { endpoint = "sink"; port = 8443; "tls.ca_file" = "${tls}/cert.pem"; };
      };
      outputs.otlp = {
        type = "otlp"; endpoint = "sink"; port = 8443;
        sources = [ "system" "operations" "kernel" ]; queueBytes = 8388608;
        settings."tls.ca_file" = "${tls}/cert.pem";
      };
      outputs.unreachable = {
        type = "native"; plugin = "http"; sources = [ "system" ]; queueBytes = 1048576;
        settings = { host = "127.0.0.1"; port = 9; uri = "/logs"; format = "json_lines"; };
      };
      outputs.fixture = {
        type = "native"; plugin = "http";
        sources = [ "system" "operations" "kernel" ];
        queueBytes = 8388608;
        settings = { host = "sink"; port = 8080; uri = "/logs"; format = "json_lines"; }; 
      };
    };
    systemd.services.logging-fixture-credentials = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "logging-fixture"; RuntimeDirectoryMode = "0700"; UMask = "0077"; };
      script = ''
        cat > /run/logging-fixture/credentials <<'CREDENTIALS'
        [default]
        aws_access_key_id = isolated-fixture-access
        aws_secret_access_key = isolated-fixture-secret
        aws_session_token = isolated-fixture-token
        CREDENTIALS
      '';
    };
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-independent-host-logging";
  nodes = {
    first = { ... }: {
      imports = [ host ../../../../domains/system/security-audit.nix ];
      services.overallsSecurityAudit.enable = true;
      services.overallsLogging.outputs.restricted = {
        type = "native"; plugin = "http"; sources = [ "audit" ]; queueBytes = 8388608;
        settings = { host = "sink"; port = 8080; uri = "/restricted"; format = "json_lines"; };
      };
      environment.etc."logging-runtime-test.py".source = ../../evaluation/logging-runtime.py;
      environment.etc."logging-runtime.py".source = ../../../../domains/system/logging/runtime.py;
      environment.etc."native-collector.py".source = ../../../../domains/system/firecracker-logging/collector.py;
      environment.systemPackages = [ pkgs.python3 ];
    };
    second = host; third = host;
    sink = { ... }: {
      networking.firewall.allowedTCPPorts = [ 8080 8443 ];
      systemd.services.fixture = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${./sink.py} ${tls}/cert.pem ${tls}/key.pem";
      };
    };
  };
  testScript = builtins.readFile ./driver.py;
}
