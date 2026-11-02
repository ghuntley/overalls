{ pkgs, module, packages }:
let
  fixturePackage = packages.underclass.overrideAttrs (previous: {
    postPatch = (previous.postPatch or "") + ''
      mkdir -p src/bin
      cp ${../underclass-slo/fixture.rs} src/bin/slo_fixture.rs
    '';
  });
  tls = pkgs.runCommand "ziggy-underclass-control-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=ziggy-isolated-test -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=control.test -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=DNS:control.test,DNS:provider.test,DNS:panterloons.lorikeet-bangus.ts.net\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-ziggy-underclass";
  nodes.pool = { lib, ... }: {
    imports = [ module ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    networking.firewall.allowedTCPPorts = [ 443 ];
    networking.extraHosts = "127.0.0.1 provider.test\n";
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    services.underclass = {
      enable = true;
      package = fixturePackage;
      tailscaleServe.enable = false;
      environmentFile = "/etc/underclass-test.env";
    };
    environment.etc."underclass-test.env".text = ''
      UNDERCLASS_PROXY_KEY=synthetic-proxy-key
      UNDERCLASS_UI_TOKEN=synthetic-admin-token
      UNDERCLASS_CODEX_UPSTREAM=https://provider.test:8443/responses
      UNDERCLASS_CODEX_USAGE_BASE=https://provider.test:8443
      UNDERCLASS_AUTO_CODEX_RESETS=false
    '';
    systemd.services.underclass = {
      after = [ "nginx.service" "underclass-fixture.service" ];
      wants = [ "nginx.service" ];
      requires = [ "underclass-fixture.service" ];
      serviceConfig.ExecStartPre = lib.mkAfter [ "${fixturePackage}/bin/slo_fixture seed /var/lib/underclass" ];
    };
    systemd.services.underclass-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${fixturePackage}/bin/slo_fixture serve /run/underclass-fixture";
        DynamicUser = true;
        RuntimeDirectory = "underclass-fixture";
        RuntimeDirectoryMode = "0755";
      };
    };
    services.nginx = {
      enable = true;
      virtualHosts = {
        "provider.test" = {
          onlySSL = true;
          listen = [{ addr = "127.0.0.1"; port = 8443; ssl = true; }];
          sslCertificate = "${tls}/server.pem";
          sslCertificateKey = "${tls}/server.key";
          locations."/" = { proxyPass = "http://127.0.0.1:8081"; extraConfig = "proxy_buffering off;"; };
          locations."= /responses" = {
            proxyPass = "http://127.0.0.1:8081";
            extraConfig = ''
              proxy_buffering off;
              proxy_hide_header Content-Type;
              add_header Content-Type application/json always;
            '';
          };
        };
        "panterloons.lorikeet-bangus.ts.net" = {
          onlySSL = true;
          sslCertificate = "${tls}/server.pem";
          sslCertificateKey = "${tls}/server.key";
          locations."/" = { proxyPass = "http://127.0.0.1:8080"; extraConfig = "proxy_buffering off;"; };
        };
      };
    };
    environment.systemPackages = [ pkgs.curl pkgs.python3 pkgs.sqlite ];
  };
  nodes.machine = { lib, nodes, ... }: {
    imports = [ module ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    services.openssh.enable = true;
    networking.hostId = "12345678";
    networking.extraHosts = ''
      127.0.0.1 control.test
      ${nodes.pool.networking.primaryIPAddress} panterloons.lorikeet-bangus.ts.net
    '';
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
      openaiOrigin = "https://panterloons.lorikeet-bangus.ts.net";
      agentEnable = true;
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
  # Real NixOS units MUST use verified remote HTTPS and the Underclass proxy key,
  # correlate a completed agent stream, reject administrative credentials, and
  # recover a fresh request after outage without replaying the previous request.
  # Underclass MUST normalize successful SSE that the provider mislabels as JSON
  # so Ziggy completes the original model call without another provider attempt.
  # Decoded fixture records MUST have validated string-keyed object shapes.
  testScript = ''
    import base64
    import json
    import shlex
    import uuid

    def json_object(raw: str) -> dict[str, object]:
        value: object = json.loads(raw)
        assert isinstance(value, dict)
        document: dict[str, object] = {}
        for key, item in value.items():
            assert isinstance(key, str)
            document[key] = item
        return document

    start_all()
    pool.wait_for_unit("underclass.service")
    pool.wait_for_open_port(443)
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

    with subtest("remote proxy credential boundary"):
        for key in ["synthetic-admin-token", "wrong", ""]:
            assert machine.succeed("curl --silent --output /dev/null --write-out '%{http_code}' -H " + shlex.quote("Authorization: Bearer " + key) + " https://panterloons.lorikeet-bangus.ts.net/v1/models").strip() == "401"
        assert machine.succeed("curl --silent --output /dev/null --write-out '%{http_code}' -H 'Authorization: Bearer synthetic-proxy-key' https://panterloons.lorikeet-bangus.ts.net/admin/api/state").strip() == "401"

    with subtest("provider sends a completed SSE body mislabeled as JSON"):
        pool.succeed(
            "curl --noproxy '*' --silent --show-error --fail --max-time 10 "
            "--dump-header /tmp/provider-headers --output /tmp/provider-body "
            "-H 'Content-Type: application/json' --data '{\"stream\":true}' "
            "https://provider.test:8443/responses"
        )
        provider_content_types: list[str] = [
            line.split(":", 1)[1].strip().lower()
            for line in pool.succeed("cat /tmp/provider-headers").splitlines()
            if line.lower().startswith("content-type:")
        ]
        assert provider_content_types == ["application/json"]
        provider_body: str = pool.succeed("cat /tmp/provider-body")
        assert provider_body.startswith("event: response.completed\n")
        assert "synthetic agent reply" in provider_body
        provider_calls_before_agent: int = int(pool.succeed("cat /run/underclass-fixture/calls"))
        assert provider_calls_before_agent == 1

    with subtest("startup model call completes mislabeled SSE across HTTPS with one v7 identity"):
        machine.succeed("printf gpt-6-sol > /run/ziggy-fixture/agent-model; touch /run/ziggy-fixture/agent-ready")
        machine.wait_until_succeeds("test -s /run/ziggy-fixture/agent-results.jsonl")
        result = json_object(machine.succeed("head -1 /run/ziggy-fixture/agent-results.jsonl"))
        call_id = result["call_id"]
        assert isinstance(call_id, str) and uuid.UUID(call_id).version == 7
        assert "synthetic agent reply" in json.dumps(result["response"])
        pool.succeed("journalctl -u underclass.service --no-pager | grep -F " + shlex.quote(call_id))
        assert int(pool.succeed("cat /run/underclass-fixture/calls")) == provider_calls_before_agent + 1

    with subtest("outage cannot replay inference and restoration admits a fresh request"):
        host: str = "11111111-1111-4111-8111-111111111111"
        binding: str = base64.urlsafe_b64encode(json.dumps(dict(host_id=host, vm_id=host, placement_id=host, execution_epoch=1)).encode()).decode().rstrip("=")
        headers: str = " -H " + shlex.quote("x-overalls-binding: " + binding) + " -H 'Content-Type: application/json'"
        body: str = shlex.quote(json.dumps(dict(model="gpt-6-sol", input="synthetic", stream=True, store=False)))
        pool.succeed("systemctl stop nginx.service")
        machine.execute(curl + headers + " --data-binary " + body + " http://llm.internal/v1/responses")
        pool.succeed("systemctl start nginx.service")
        machine.succeed(curl + headers + " --data-binary " + body + " http://llm.internal/v1/responses | grep -F 'synthetic agent reply'")
        machine.wait_until_succeeds("test $(wc -l < /run/ziggy-fixture/completions.jsonl) -eq 3")
        assert int(pool.succeed("cat /run/underclass-fixture/calls")) == provider_calls_before_agent + 2
        records = [json_object(line) for line in machine.succeed("cat /run/ziggy-fixture/admissions.jsonl").splitlines()]
        ids: list[str] = []
        for record in records:
            identifier = record["request_id"]
            assert isinstance(identifier, str)
            ids.append(identifier)
        assert len(ids) == 3 and len(set(ids)) == 3
        assert all(uuid.UUID(identifier).version == 7 for identifier in ids)
  '';
}
