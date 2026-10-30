{ pkgs, packages }:
let
  label = "vm-11111111111141118111111111111111";
  host = "${label}.vm.example.test";
  namespace = "${label}.inception.vm.example.test";
  workload = "${label}.apps.${namespace}";
  relay = pkgs.writeShellScript "fixture-ssh-relay" ''
    case "$SSH_ORIGINAL_COMMAND" in
      'inception ${label} audi')
        if test -e /run/audi-openssh/nested-workload; then
          exec ${pkgs.netcat-openbsd}/bin/nc -4 -N 127.0.0.1 2224
        fi ;;
      'connect ${label}'|'inception ${label} porsche') ;;
      *) exit 1 ;;
    esac
    exec ${pkgs.netcat-openbsd}/bin/nc -4 -N 127.0.0.1 2223
  '';
  innerRelay = pkgs.writeShellScript "fixture-inner-audi-relay" ''
    test -z "$SSH_AUTH_SOCK" || exit 1
    test "$SSH_ORIGINAL_COMMAND" = 'connect ${label}' || exit 1
    exec ${pkgs.netcat-openbsd}/bin/nc -4 -N 127.0.0.1 2223
  '';
  sshd = role: port: key: command: pkgs.writeText "${role}-sshd.conf" ''
    Port ${toString port}
    PidFile /run/${role}-${toString port}-sshd.pid
    ListenAddress 127.0.0.1
    HostKey /run/audi-openssh/${key}
    AuthorizedKeysFile /run/audi-openssh/client.pub
    AllowUsers ${role}
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    ${pkgs.lib.optionalString (command != null) "ForceCommand ${command}"}
  '';
in pkgs.testers.runNixOSTest {
  name = "overalls-audi-openssh";
  nodes.client = { ... }: {
    virtualisation.memorySize = 1536;
    networking.enableIPv6 = false;
    networking.extraHosts = "127.0.0.1 ${workload} ${host} control.example.test control.${namespace}\n";
    environment.systemPackages = [ pkgs.openssh pkgs.openssl pkgs.python3 packages.lyraLinux ];
    environment.etc."bounded-ssh.py".source = ./bounded_ssh.py;
    users.users.audi = { isNormalUser = true; password = "unused-fixture-password"; };
    users.users.guest = { isNormalUser = true; password = "unused-fixture-password"; };
    users.groups.sshd = {};
    users.users.sshd = { isSystemUser = true; group = "sshd"; home = "/var/empty"; };
    systemd.services.fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = [ pkgs.openssh pkgs.openssl ];
      script = ''
        install -d -m 0755 /run/audi-openssh
        cd /run/audi-openssh
        for name in client gateway_a gateway_b guest_key inner_gateway; do
          ssh-keygen -q -t ed25519 -N "" -C "" -f "$name"
          ssh-keygen -y -f "$name" > "$name.pub"
        done
        cp gateway_a gateway_active
        printf '%s ' '${host}' > published_key
        cat gateway_a.pub >> published_key
        cp gateway_a.pub published_gateway
        cp guest_key.pub published_inner
        printf 200 > status
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=fixture-ca -keyout ca.key -out ca.crt
        openssl req -newkey rsa:2048 -nodes -subj /CN=control.example.test -keyout tls.key -out tls.csr
        printf '%s\n' 'subjectAltName=DNS:control.example.test' 'extendedKeyUsage=serverAuth' > extensions
        openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile extensions -out tls.crt
        cp ${pkgs.replaceVars ./standard.conf.in {
          inherit label;
          zone = "vm.example.test";
          origin = "https://control.example.test:4443";
          port = "2222";
        }} /run/audi-openssh/config
        cp ${./inception.conf} /run/audi-openssh/inception-config
        cp ${./workload.conf} /run/audi-openssh/workload-config
        install -d -m 0700 /root/.ssh
        printf '%s ' '${host}' > /root/.ssh/known_hosts
        cat guest_key.pub >> /root/.ssh/known_hosts
        printf '%s ' '${workload}' >> /root/.ssh/known_hosts
        cat guest_key.pub >> /root/.ssh/known_hosts
      '';
    };
    systemd.services.outer = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fixture.service" ]; requires = [ "fixture.service" ];
      serviceConfig.ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${sshd "audi" 2222 "gateway_active" relay}";
    };
    systemd.services.inner = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fixture.service" ]; requires = [ "fixture.service" ];
      serviceConfig.ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${sshd "guest" 2223 "guest_key" null}";
    };
    systemd.services.middle = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fixture.service" ]; requires = [ "fixture.service" ];
      serviceConfig.ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${sshd "audi" 2224 "inner_gateway" innerRelay}";
    };
    systemd.services.lookup = {
      wantedBy = [ "multi-user.target" ];
      after = [ "fixture.service" ]; requires = [ "fixture.service" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./lookup.py}";
    };
  };
  # @cc [owner:ghuntley,label:verification] audi-fixture-openssh-scope
  # The fixture profiles MUST run real nested OpenSSH and Rust HTTPS lookup, verify
  # separate inner/outer identities and deny stale keys or failed lookup. The
  # stock sshd/HTTPS fixtures MUST NOT be described as Marshall publication,
  # production profile generation, Audi authorization, relocation or Firecracker
  # acceptance.
  testScript = builtins.readFile ./driver.py;
}
