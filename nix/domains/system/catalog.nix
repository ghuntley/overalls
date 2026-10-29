{ packages, nixCompact ? import ../artifacts/nix-compact/source.nix }:
{
  imports = [
    (import ./backups { inherit packages; })
    ./fleet-exporter/default.nix
    (import ./brady { inherit packages; })
    ./logging/default.nix
    ./otel-guest/default.nix
    ./otel-fleet/default.nix
    ./otel-fleet/request-recorder.nix
    ./log-store/default.nix
    ./cloudwatch/default.nix
    ./security-audit.nix
    ./access.nix
    ./fleet-firewall.nix
    ./fleet-addresses.nix
    ./runtime-firewall.nix
    ./tailscale.nix
    (import ./underclass.nix { inherit packages; })
    ./remote-builders.nix
    ./nix-cache.nix
    ./fleet-network.nix
    ./nix-gc.nix
    (import ./nix-compact.nix { inherit nixCompact; })
    ./sysctl.nix
    (import ./marshall.nix { inherit packages; })
    (import ./lilly.nix { inherit packages; })
    (import ./porsche.nix { inherit packages; })
    (import ./audi-private.nix { inherit packages; })
    (import ./ziggy.nix { inherit packages; })
    (import ./galileo.nix { inherit packages; })
    (import ./peach.nix { inherit packages; })
    (import ./enrico.nix { inherit packages; })
    (import ./susan.nix { inherit packages; })
    (import ./audi.nix { inherit packages; })
    ./proxy.nix
    ./runtime-socket.nix
    ./acme/default.nix
    (import ./secrets/default.nix { inherit packages; })
    (import ./auto-update/default.nix { inherit packages; })
  ];
}
