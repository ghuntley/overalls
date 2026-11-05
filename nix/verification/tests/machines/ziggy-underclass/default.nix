{ pkgs, module, packages }:
let
  tls = pkgs.runCommand "ziggy-underclass-control-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=ziggy-isolated-test -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=control.test -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:control.test\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-ziggy-underclass";
  nodes.machine = { lib, ... }: {
    imports = [ module ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    services.openssh.enable = true;
    networking.hostId = "12345678";
    networking.extraHosts = "127.0.0.1 control.test\n";
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    services.lilly = {
      enable = true;
      hostId = "11111111-1111-4111-8111-111111111111";
      controlPlane = "https://control.test";
      egressInterface = "eth0";
      guestCpuCores = 1;
      guestMemoryMiB = 256;
      pools = [{
        id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        path = "/pool";
        filesystem_id = "zfs:123:456";
        storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
      }];
    };
    systemd.services.lilly.wantedBy = lib.mkForce [];
    services.underclass = {
      enable = true;
      tailscaleServe.enable = false;
      environmentFile = "/etc/underclass-test.env";
    };
    environment.etc."underclass-test.env".text = ''
      UNDERCLASS_PROXY_KEY=synthetic-proxy-key
      UNDERCLASS_UI_TOKEN=synthetic-admin-token
    '';
    services.ziggy = {
      caFile = "${tls}/ca.pem";
      secretsFile = "/run/ziggy-fixture/ziggy.enc.json";
      enabledProviders = [ "openai" ];
      openaiOrigin = "http://127.0.0.1:8080";
      openaiKeyFile = "/run/underclass-test/proxy.key";
      secretUnits = [ "underclass-test-key.service" ];
      cpuCores = 2;
      memoryMiB = 1024;
      maxPendingRequests = 8;
    };
    services.galileo.secretsFile = "/run/ziggy-fixture/galileo.enc.json";
    systemd.services.ziggy.wantedBy = lib.mkForce [];
    systemd.services.underclass-test-key = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "underclass-test";
        RuntimeDirectoryMode = "0700";
      };
      script = ''
        printf synthetic-proxy-key > /run/underclass-test/proxy.key
        chmod 0400 /run/underclass-test/proxy.key
      '';
    };
    environment.systemPackages = [ pkgs.curl pkgs.python3 packages.secretTools.sops packages.secretTools.ssh-to-age ];
    environment.etc."ziggy-seal.py".source = ../ziggy-service/seal.py;
    systemd.services.ziggy-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${../ziggy-service/fixture.py} ${tls}/server.pem ${tls}/server.key";
        RuntimeDirectory = "ziggy-fixture";
        RuntimeDirectoryMode = "0700";
      };
    };
  };

  # @cc [owner:ghuntley,label:verification] ziggy-underclass-route-machine
  # Real NixOS units MUST use the Underclass proxy credential for model discovery,
  # reject the UI token, and recover the route after a service restart.
  testScript = ''
    machine.start()
    machine.wait_for_unit("underclass.service")
    machine.wait_for_open_port(8080)
    machine.wait_for_unit("ziggy-fixture.service")
    machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
    machine.succeed("python3 /etc/ziggy-seal.py")
    machine.succeed("systemctl start ziggy.service")
    machine.wait_for_unit("ziggy.service")
    curl: str = "curl --noproxy '*' --silent --show-error --fail --max-time 10 --unix-socket /run/ziggy/proxy.sock"
    machine.wait_until_succeeds(curl + " http://ziggy/health/ready")
    machine.succeed("curl --silent --fail -H 'Authorization: Bearer synthetic-proxy-key' http://127.0.0.1:8080/v1/models | grep -q gpt-5.5")
    machine.fail("curl --silent --fail -H 'Authorization: Bearer synthetic-admin-token' http://127.0.0.1:8080/v1/models")
    request: str = "'{\"model\":\"gpt-6-sol\",\"input\":\"synthetic prompt\",\"store\":false}'"
    machine.succeed(
      "curl --silent --output /dev/null --write-out '%{http_code}' "
      "-H 'Authorization: Bearer synthetic-admin-token' -H 'Content-Type: application/json' "
      "--data " + request + " http://127.0.0.1:8080/v1/responses | grep -qx 401"
    )
    machine.succeed(
      "curl --silent --output /dev/null --write-out '%{http_code}' "
      "-H 'Authorization: Bearer synthetic-proxy-key' -H 'Content-Type: application/json' "
      "--data " + request + " http://127.0.0.1:8080/v1/responses | grep -qx 503"
    )
    machine.fail("journalctl -u ziggy.service --no-pager | grep -F synthetic-proxy-key")
    machine.fail("journalctl -u ziggy.service --no-pager | grep -F synthetic-admin-token")
    machine.succeed("systemctl restart ziggy.service")
    machine.wait_until_succeeds(curl + " http://ziggy/health/ready")
  '';
}
