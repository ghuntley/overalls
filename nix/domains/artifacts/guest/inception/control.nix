{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
  hook = pkgs.writeShellScript "inception-control-dns-proof" ''
    exec ${python}/bin/python3 ${./.}/control_proofs.py ${../.} "$@"
  '';
  image = pkgs.writeText "inception-control-tools.json" (builtins.toJSON {
    lego = "${pkgs.lego}/bin/lego";
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
