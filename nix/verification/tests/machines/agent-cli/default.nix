{ pkgs, packages, hegel }:
let
  tls = pkgs.runCommand "agent-cli-fixture-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=agent-cli-fixture -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=control.test -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:control.test\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in hegel.runTest {
  name = "overalls-agent-cli";
  properties = {
    enable = true;
    profile = "ci";
    testCases = 10;
    statefulStepCount = 30;
  };
  nodes.client = { ... }: {
    system.stateVersion = "26.05";
    networking.extraHosts = "127.0.0.1 control.test\n";
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    environment.systemPackages = [ packages.lyraLinux pkgs.curl pkgs.python3 ];
    systemd.services.agent-cli-fixture = {
      wantedBy = [ "multi-user.target" ];
      # The paired-fixture state machine restarts this unit deliberately and
      # repeatedly; systemd's default start rate limit would fail it.
      startLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./fixture.py} ${tls}/server.pem ${tls}/server.key";
        RuntimeDirectory = "agent-cli-fixture";
        RuntimeDirectoryMode = "0700";
      };
    };
  };
  # @cc [owner:ghuntley,label:verification] packaged-agent-cli-https-flow
  # The built CLI MUST use verified HTTPS, browser-digest pairing, a VM-scoped
  # prompt and terminal-result RPC. The unauthenticated request matrix and the
  # CLI's input gates MUST be property-driven over drawn shapes; the
  # driver-paired fixture lifecycle (pairing, approval revocation, restart
  # recovery) MUST be a state machine. This fixture is synthetic Marshall
  # authority; it does not prove the real control/host/guest orchestration.
  testScript = ''
    overalls_binary = "${packages.lyraLinux}/bin/overalls"
    shell_binary = "${pkgs.runtimeShell}"
    client_path = "${pkgs.lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}"
  '' + builtins.readFile ./driver.py;
}
