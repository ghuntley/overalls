{ pkgs, packages }:
let
  providerHosts = [ "api.push.apple.com" "api.sandbox.push.apple.com" "oauth2.googleapis.com" "fcm.googleapis.com"
    "login.microsoftonline.com" "wns2-test.notify.windows.com" ];
  # A private CA stands in for the public roots so the release's real
  # verify_peer TLS path talks to the local fake provider origins.
  tls = pkgs.runCommand "susan-fake-provider-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj /CN=susan-provider-test-ca \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout ca.key -out $out/ca.pem 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -subj /CN=api.push.apple.com -keyout $out/server.key -out server.csr 2>/dev/null
    printf 'subjectAltName=${pkgs.lib.concatMapStringsSep "," (host: "DNS:" + host) providerHosts}\nextendedKeyUsage=serverAuth\n' > extensions
    openssl x509 -req -in server.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial \
      -days 3650 -extfile extensions -out $out/server.pem 2>/dev/null
  '';
  python = pkgs.python3.withPackages (ps: [ ps.cryptography ps.hypercorn ]);
in {
  inherit python;
  # Relay node shared by the Susan machine tests: the packaged release, local
  # PostgreSQL, SOPS tools and verify_peer TLS to local fake provider origins.
  node = { lib, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    services.openssh.enable = true;
    networking.extraHosts = "127.0.0.1 ${lib.concatStringsSep " " providerHosts}\n";
    security.pki.certificateFiles = [ "${tls}/ca.pem" ];
    services.susan = {
      enable = true;
      secretsFile = "/run/susan-sealed/susan.enc.json";
      apnsTopics = [ "dev.overalls.mila" ];
      fcmAppIds = [ "dev.overalls.mila" ];
      wnsAppIds = [ "dev.overalls.mila" ];
    };
    systemd.services.susan.wantedBy = lib.mkForce [ ];
    systemd.services.fake-provider = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${python}/bin/hypercorn --bind 127.0.0.1:443 --certfile ${tls}/server.pem --keyfile ${tls}/server.key --log-level warning fake_provider:app";
        WorkingDirectory = "/etc/susan-fake-provider";
        RuntimeDirectory = "fake-provider";
        RuntimeDirectoryPreserve = true;
      };
    };
    environment.etc."susan-fake-provider/fake_provider.py".source = ./fake_provider.py;
    environment.etc."susan-fixture.py".source = ./fixture.py;
    environment.etc."susan-client.py".source = ./client.py;
    environment.etc."susan-release".source = packages.susan;
    environment.systemPackages = [ python pkgs.curl pkgs.jq pkgs.openssh
      packages.secretTools.sops packages.secretTools.ssh-to-age ];
  };
}
