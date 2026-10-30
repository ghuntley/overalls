{ packages }:
{ ... }:
{
  services.openssh = { enable = true; ports = [ 2222 ]; };
  services.porsche = {
    enable = true;
    openFirewall = true;
    controlPlane = "https://control.example.test:5443";
    publicOrigin = "https://control.example.test";
    caFile = "/var/lib/overalls-fleet/ca.crt";
    credentialFile = "/var/lib/overalls-fleet/porsche.token";
    secretUnits = [ "fleet-credentials.service" "fleet-porsche-credentials.service" ];
  };
  # Keep the production boot target: later whole-host recovery must restart
  # Porsche too. Only initial fixture issuance waits for the real migration.
  systemd.services.fleet-porsche-credentials = {
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "infinity"; };
    script = ''
      while [ ! -s /var/lib/overalls-fleet/porsche.token ]; do sleep 1; done
    '';
  };
}
