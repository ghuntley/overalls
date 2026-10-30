{ pkgs, ... }:
let
  root = "/var/lib/inception-fixture-issuer";
  # @cc [owner:ghuntley,label=verification;network] inception-fixture-acme-length
  # The fixture must delimit its certificate-chain response explicitly. This
  # keeps the nested client from waiting for a connection close after certZ;
  # production issuers are unaffected.
  pebble = pkgs.pebble.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
${pkgs.python3}/bin/python3 - <<'PY'
from pathlib import Path

path = Path("wfe/wfe.go")
source = path.read_text()
needle = "\tresponse.Header().Set(\"Content-Type\", \"application/pem-certificate-chain; charset=utf-8\")\n\tresponse.WriteHeader(http.StatusOK)\n\t_, _ = response.Write(cert.Chain(no))\n"
replacement = "\tresponse.Header().Set(\"Content-Type\", \"application/pem-certificate-chain; charset=utf-8\")\n\tchain := cert.Chain(no)\n\tresponse.Header().Set(\"Content-Length\", strconv.Itoa(len(chain)))\n\tresponse.WriteHeader(http.StatusOK)\n\t_, _ = response.Write(chain)\n"
if needle not in source or replacement in source:
    raise SystemExit("Pebble certificate response patch did not match exactly")
path.write_text(source.replace(needle, replacement, 1))
PY
    '';
  });
  tlsExtensions = pkgs.writeText "inception-issuer-tls.extensions" ''
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    subjectAltName=DNS:localhost,DNS:github.com,DNS:api.openai.com,DNS:api.anthropic.com,IP:11.0.0.2,IP:127.0.0.1
  '';
  configuration = pkgs.writeText "inception-fixture-pebble.json" (builtins.toJSON {
    pebble = {
      listenAddress = "11.0.0.2:9443";
      managementListenAddress = "127.0.0.1:9444";
      certificate = "${root}/tls.crt";
      privateKey = "${root}/tls.key";
      httpPort = 5002;
      tlsPort = 5001;
      certificateValidityPeriod = 172800;
      retryAfter = { authz = 1; order = 1; };
    };
  });
in
{
  networking.firewall.allowedTCPPorts = [ 443 9443 ];
  environment.systemPackages = [ pkgs.curl pkgs.python3 ];
  environment.etc."inception-public-boundary.py".source = ./public_boundary.py;
  systemd.services.inception-provider-fixture = {
    wantedBy = [ "multi-user.target" ];
    after = [ "inception-fixture-issuer.service" ];
    requires = [ "inception-fixture-issuer.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./provider.py} ${root}/tls.crt ${root}/tls.key";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
    };
  };

  # @cc [owner:ghuntley,label:verification;security] inception-real-dns-issuer
  # The isolated issuer MUST validate actual DNS-01 proofs through the first
  # independent authority. It MUST NOT accept every challenge or reuse prior
  # authorizations. TLS keys MUST be created privately at runtime and never
  # printed or embedded in the Nix store. Management MUST bind IPv4 loopback.
  systemd.services.inception-fixture-issuer = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      PEBBLE_VA_NOSLEEP = "1";
      PEBBLE_VA_ALWAYS_VALID = "0";
      PEBBLE_WFE_NONCEREJECT = "0";
      PEBBLE_AUTHZREUSE = "0";
    };
    preStart = ''
      if ! test -s ${root}/tls.crt; then
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
          -subj '/CN=Inception isolated issuer transport CA' \
          -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
          -addext 'keyUsage=critical,keyCertSign,cRLSign' \
          -keyout ${root}/ca.key -out ${root}/ca.crt >/dev/null 2>&1
        ${pkgs.openssl}/bin/openssl req -new -newkey rsa:2048 -nodes \
          -subj '/CN=Inception isolated issuer' \
          -keyout ${root}/tls.key -out ${root}/tls.csr >/dev/null 2>&1
        ${pkgs.openssl}/bin/openssl x509 -req -in ${root}/tls.csr \
          -CA ${root}/ca.crt -CAkey ${root}/ca.key -CAcreateserial -days 2 \
          -extfile ${tlsExtensions} -out ${root}/tls.crt >/dev/null 2>&1
      fi
    '';
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pebble}/bin/pebble -config ${configuration} -dnsserver 11.0.0.3:53";
      StateDirectory = "inception-fixture-issuer";
      StateDirectoryMode = "0700";
      UMask = "0077";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
    };
  };
}
