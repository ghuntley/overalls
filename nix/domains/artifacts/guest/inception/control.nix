{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
  # @cc [owner:ghuntley,label=recovery;network] inception-acme-no-keepalive
  # The nested ACME client MUST use a fresh HTTP connection for each signed
  # exchange. Reusing the issuer connection across the directory/order flow
  # can leave the final POST-as-GET certificate body unread at the TAP boundary.
  lego = pkgs.lego.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lego/client_config.go \
        --replace-fail 'TLSHandshakeTimeout:   30 * time.Second,' \
          'TLSHandshakeTimeout:   30 * time.Second, DisableKeepAlives: true,'
      ${pkgs.python3}/bin/python3 - <<'PY'
from pathlib import Path

path = Path("acme/api/certificate.go")
source = path.read_text()
if "defer resp.Body.Close()" not in source:
    needles = [
        "\tresp, err := c.core.postAsGet(ctx, certURL, nil)\n",
        "\tresp, err := c.core.postAsGet(certURL, nil)\n",
    ]
    needle = next((candidate for candidate in needles if candidate in source), None)
    if needle is None:
        raise SystemExit("certificate response close patch did not match exactly")
    source = source.replace(
        needle,
        needle + "\tif resp != nil {\n\t\tdefer resp.Body.Close()\n\t}\n",
        1,
    )
path.write_text(source)
PY
    '';
  });
  hook = pkgs.writeShellScript "inception-control-dns-proof" ''
    exec ${python}/bin/python3 ${./.}/control_proofs.py ${../.} "$@"
  '';
  image = pkgs.writeText "inception-control-tools.json" (builtins.toJSON {
    lego = "${lego}/bin/lego";
    inherit hook;
    guest_root = "${../.}";
    openssl = "${pkgs.openssl}/bin/openssl";
    haproxy = "${pkgs.haproxy}/bin/haproxy";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    validator = "${../../../system/acme/publish.py}";
  });
in
{
  users.groups.inception-proxy = {};
  users.users.inception-proxy = { isSystemUser = true; group = "inception-proxy"; };
  systemd.tmpfiles.rules = [
    "d /var/lib/inception-control-proxy 0750 root inception-proxy -"
  ];

  # @cc [owner:ghuntley,label:security;recovery] inception-control-service-isolation
  # Public control issuance MUST remain independent of core execution readiness.
  # Only its root worker may write certificate material. The serving proxy MUST
  # run unprivileged, accept only IPv4/local sockets, and stop with its worker.
  # Reload MUST signal the HAProxy master to preserve established connections.
  systemd.services.inception-control-proxy = {
    after = [ "marshall-inception.service" "inception-control-certificate.service" ];
    bindsTo = [ "inception-control-certificate.service" ];
    partOf = [ "inception-control-certificate.service" ];
    serviceConfig = {
      Type = "exec"; User = "inception-proxy"; Group = "inception-proxy";
      UMask = "0077";
      LoadCredential = [ "haproxy.cfg:/run/inception-control/haproxy.cfg" ];
      ExecStart = "${pkgs.haproxy}/bin/haproxy -W -db -f %d/haproxy.cfg";
      ExecReload = "${pkgs.coreutils}/bin/kill -USR2 $MAINPID";
      KillMode = "mixed"; KillSignal = "SIGUSR1"; TimeoutStopSec = 10;
      Restart = "on-failure"; RestartSec = 2;
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
      ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
      CPUQuota = "100%"; MemoryMax = "256M"; TasksMax = 64;
    };
  };

  systemd.services.inception-control-certificate = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-audi.service" "inception-network-offloads.service" ];
    after = [
      "inception-audi.service"
      "inception-network-offloads.service"
      "marshall-inception.service"
    ];
    serviceConfig = {
      Type = "exec"; User = "root"; UMask = "0077";
      ExecStart = "${python}/bin/python3 ${./.}/control_worker.py ${image}";
      StateDirectory = "inception-control"; StateDirectoryMode = "0700";
      RuntimeDirectory = "inception-control"; RuntimeDirectoryMode = "0700";
      Restart = "on-failure"; RestartSec = 10; TimeoutStopSec = 20;
      KillMode = "control-group";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      CapabilityBoundingSet = [ "CAP_CHOWN" "CAP_DAC_READ_SEARCH" ];
      NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
      ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
      ReadWritePaths = [ "/run/inception" "/var/lib/inception-control-proxy" ];
      CPUQuota = "100%"; MemoryMax = "512M"; TasksMax = 64;
    };
  };
}
