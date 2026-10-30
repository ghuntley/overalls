{ pkgs, module, packages }:
let
  identities = import ../../../../domains/system/otel-fleet/request-identities.nix;
  keys = pkgs.runCommand "audi-service-disposable-wireguard-keys" {
    nativeBuildInputs = [ pkgs.wireguard-tools ];
  } ''
    mkdir -p "$out"
    for name in gateway connector; do
      wg genkey > "$out/$name.key"
      wg pubkey < "$out/$name.key" > "$out/$name.pub"
    done
  '';
  fleetHost = name: other: address: peerAddress: { config, nodes, lib, ... }: {
    overalls.fleetNetwork = {
      enable = true;
      inherit address;
      endpointAddress = config.networking.primaryIPAddress;
      privateKeyFile = "/run/fleet-key/private";
      secretUnits = [ "fleet-fixture-key.service" ];
      peers.${other} = {
        address = peerAddress;
        endpointAddress = nodes.${other}.networking.primaryIPAddress;
        publicKey = lib.removeSuffix "\n" (builtins.readFile "${keys}/${other}.pub");
      };
    };
    systemd.services.fleet-fixture-key = {
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "fleet-key";
        RuntimeDirectoryMode = "0700";
      };
      script = "install -m 0600 ${keys}/${name}.key /run/fleet-key/private";
    };
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-audi-service";
  nodes.gateway = { lib, ... }: {
    imports = [ module (import ../../support/ssh-host-certificate.nix { inherit pkgs; role = "audi"; }) (fleetHost "gateway" "connector" "10.90.0.1" "10.90.0.2") ];
    virtualisation.memorySize = 4096;
    services.overallsOtelFleet = { enable = true; role = "central"; hosts = { central = "gateway"; worker = "connector"; }; };
    services.overallsOtelGuest.enable = lib.mkForce false;
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.audi = {
      enable = true;
      package = packages.audi;
      controlPlane = "https://localhost:5443";
      hostId = "11111111-1111-4111-8111-111111111111";
      credentialFile = "/run/audi-fixture/gateway.token";
      secretUnits = [ "audi-fixture.service" ];
      openFirewall = true;
    };
    systemd.services.audi-fixture = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = ''
        mkdir -p /run/audi-fixture
        printf '%s\n' 'audi_service_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > /run/audi-fixture/gateway.token
      '';
    };
    environment.systemPackages = [ pkgs.openssh pkgs.iproute2 pkgs.python3 ];

  };
  nodes.connector = { config, lib, ... }: {
    imports = [ (import ../../support/role-node.nix { inherit module packages; }) (import ../../support/ssh-host-certificate.nix { inherit pkgs; role = "audi"; }) (fleetHost "connector" "gateway" "10.90.0.2" "10.90.0.1") ];
    services.lilly = { enable = true; ingress.enable = true; };
    virtualisation.emptyDiskImages = [ 1024 ];
    # The connector starts the real Lilly configuration validator, which binds
    # every declared pool to observed ZFS identity even without guest execution.
    systemd.services.audi-storage-fixture = {
      before = [ "lilly.service" ];
      path = [ config.boot.zfs.package ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        zpool create -f -O mountpoint=none -O compression=lz4 tank /dev/vdb
        zfs create -o mountpoint=/pool tank/lilly
      '';
    };
    systemd.services.lilly = {
      requires = [ "audi-storage-fixture.service" ];
      after = [ "audi-storage-fixture.service" ];
      preStart = lib.mkAfter ''
        pool_guid="$(zpool get -Hp -o value guid tank)"
        dataset_guid="$(zfs get -Hp -o value guid tank/lilly)"
        ${pkgs.jq}/bin/jq --arg pool "$pool_guid" --arg dataset "$dataset_guid" \
          '.pools[0].filesystem_id = ("zfs:" + $pool + ":" + $dataset) |
           .pools[0].storage.zpool_guid = $pool | .pools[0].storage.dataset_guid = $dataset' \
          /run/lilly-release/config.json > /run/lilly-release/config.json.new
        chmod 0600 /run/lilly-release/config.json.new
        mv /run/lilly-release/config.json.new /run/lilly-release/config.json
      '';
    };
    # This service-custody fixture has no private inference/integration authority.
    # The fleet journeys exercise those roles with real encrypted credentials.
    services.galileo.secretsFile = "/run/audi-fixture/absent-galileo.enc.json";
    services.ziggy.secretsFile = "/run/audi-fixture/absent-ziggy.enc.json";
    systemd.services.galileo.wantedBy = lib.mkForce [];
    systemd.services.ziggy.wantedBy = lib.mkForce [];
    services.audi = {
      enable = true;
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = "https://localhost:5443";
      credentialFile = "/run/audi-fixture/token";
      secretUnits = [ "audi-fixture.service" ];
      port = 2200;
    };
    systemd.services.audi-fixture = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = "mkdir -p /run/audi-fixture; printf '%s' audi_service_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA > /run/audi-fixture/token";
    };
    environment.systemPackages = [ pkgs.python3 ];
    environment.etc."probe-connector.py".text = ''
      import socket
      with socket.socket(socket.AF_UNIX) as client:
          client.settimeout(3)
          client.connect("/run/lilly-ingress/audi.sock")
          client.sendall(bytes([0, 0, 0, 2, 123, 125]))
          assert client.recv(1) == b""
    '';
  };
  # @cc [owner:ghuntley,label:verification] audi-service-test-scope
  # This check MUST boot the actual source release and module, verify private
  # custody, port separation, persistent host identity and fail-closed startup.
  # It MUST also test the real Lilly connector service and crash recovery.
  # It MUST NOT claim domain or guest execution: Marshall is absent here.
  testScript = ''
    start_all()
    connector.wait_for_unit("lilly.service")
    connector.wait_for_unit("audi.service")
    connector.wait_until_succeeds("test -S /run/lilly-ingress/audi.sock", timeout=45)
    assert connector.succeed("stat -c '%U:%G:%a' /run/lilly-ingress/audi.sock").strip() == "lilly:audi:660"
    connector.succeed("su -s /bin/sh audi -c 'python3 /etc/probe-connector.py'")
    previous = connector.succeed("stat -c %i /run/lilly-ingress/audi.sock").strip()
    connector.succeed("systemctl kill --kill-whom=main -s KILL lilly.service")
    connector.wait_until_succeeds("test $(systemctl show lilly.service -p NRestarts --value) -ge 1")
    connector.wait_until_succeeds("test -S /run/lilly-ingress/audi.sock && test $(stat -c %i /run/lilly-ingress/audi.sock) != " + previous, timeout=45)
    connector.succeed("su -s /bin/sh audi -c 'python3 /etc/probe-connector.py'")
    gateway.wait_for_unit("audi.service")
    gateway.wait_for_unit("opentelemetry-collector.service")
    gateway.wait_for_unit("overalls-request-audi-ssh-exporter.service")
    gateway.wait_until_succeeds("test -s /run/overalls-request-audi-ssh-source/slo.json")
    gateway.succeed("test $(stat -c %a /run/overalls-request-audi-ssh-source) = 750")
    gateway.succeed("test $(stat -c %a /run/overalls-request-audi-ssh-source/slo.json) = 640")
    gateway.succeed("test $(stat -c %G /run/overalls-request-audi-ssh-source/slo.json) = ${identities.readerGroup "audi-ssh"}")
    gateway.succeed("id -u ${identities.exporterUser "audi-ssh"}")
    gateway.fail("runuser -u ${identities.exporterUser "audi-ssh"} -- test -w /run/overalls-request-audi-ssh-source")
    gateway.succeed("code=$(runuser -u audi -g audi -- curl --silent --output /dev/null --write-out '%{http_code}' --unix-socket /run/overalls-otel-audi-ssh/collector.sock http://localhost/v1/metrics || true); test \"$code\" = 000")
    gateway.wait_until_succeeds("curl -fsS http://10.90.0.1:9464/metrics | grep -E 'overalls_outer_audi_ssh_requests_total\\{[^}]*overalls_telemetry_origin=\"application\"[^}]*service_name=\"audi_ssh\"[^}]*\\} 0'", timeout=90)
    try:
        gateway.wait_for_open_port(22, timeout=45)
    except Exception:
        print(gateway.succeed("journalctl -u audi.service --no-pager"))
        raise
    gateway.wait_for_open_port(2222)
    fingerprint = gateway.succeed("ssh-keyscan -c -t ed25519 -p 22 127.0.0.1 2>/dev/null | ssh-keygen -lf -")
    admin = gateway.succeed("ssh-keyscan -t ed25519 -p 2222 127.0.0.1 2>/dev/null | ssh-keygen -lf -")
    assert fingerprint.split()[1] != admin.split()[1]
    assert gateway.succeed("stat -c '%U:%a' /var/lib/audi/keys/ssh_host_ed25519_key").strip() == "audi:600"
    assert gateway.succeed("stat -c '%U:%a:%h' /run/audi/gateway.token").strip() == "audi:400:1"
    assert gateway.succeed("systemctl show audi.service -p User --value").strip() == "audi"
    gateway.fail("su -s /bin/sh nobody -c 'cat /var/lib/audi/keys/ssh_host_ed25519_key'")
    gateway.succeed("systemctl restart audi.service")
    gateway.wait_for_open_port(22)
    assert gateway.succeed("ssh-keyscan -c -t ed25519 -p 22 127.0.0.1 2>/dev/null | ssh-keygen -lf -") == fingerprint
    with subtest("missing certificate retries beyond the former start limit"):
        gateway.succeed("systemctl stop audi.service; mv /var/lib/audi/keys/ssh_host_ed25519_key-cert.pub /var/lib/audi/keys/saved-cert.pub; systemctl start --no-block audi.service")
        gateway.wait_until_succeeds("test $(systemctl show audi.service -p NRestarts --value) -ge 7", timeout=90)
        gateway.fail("ss -ltnH 'sport = :22' | grep -q LISTEN")
        gateway.succeed("mv /var/lib/audi/keys/saved-cert.pub /var/lib/audi/keys/ssh_host_ed25519_key-cert.pub")
        gateway.wait_until_succeeds("systemctl is-active --quiet audi.service", timeout=90)
        gateway.wait_for_open_port(22)
        assert gateway.succeed("ssh-keyscan -c -t ed25519 -p 22 127.0.0.1 2>/dev/null | ssh-keygen -lf -") == fingerprint
    gateway.succeed("ssh-keygen -q -t ed25519 -N ${pkgs.lib.escapeShellArg ""} -f /tmp/denied-client")
    gateway.fail("ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes -i /tmp/denied-client -p 22 127.0.0.1 'connect v11111111111141118111111111111111'")
    gateway.fail("journalctl -u audi.service --no-pager | grep -F audi_service_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    gateway.succeed("systemctl stop audi.service; printf invalid > /run/audi-fixture/gateway.token; systemctl start audi.service")
    gateway.wait_until_succeeds("test $(systemctl show audi.service -p NRestarts --value) -ge 1")
    gateway.fail("ss -ltnH 'sport = :22' | grep -q LISTEN")
    gateway.succeed("systemctl stop audi.service")
    gateway.wait_for_open_port(2222)
  '';
}
