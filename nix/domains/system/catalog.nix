{ packages, nixCompact ? import ../artifacts/nix-compact/source.nix, only ? null }:
let
  # Every system module by name, in import order. `only` keeps just the named
  # ones, in the same order, for a machine test that declares only their
  # files (ADR-0270, buck/machine_tests.py). Each entry is lazy: a narrowed
  # catalog never reads a module it leaves out, and restrict-eval turns a
  # missing one into an evaluation error.
  catalog = [
    { name = "backups"; module = import ./backups { inherit packages; }; }
    { name = "fleet-exporter"; module = import ./fleet-exporter/default.nix { inherit packages; }; }
    { name = "brady"; module = import ./brady { inherit packages; }; }
    { name = "logging"; module = import ./logging/default.nix { inherit packages; }; }
    { name = "otel-guest"; module = import ./otel-guest/default.nix { inherit packages; }; }
    { name = "otel-fleet"; module = import ./otel-fleet/default.nix { inherit packages; }; }
    { name = "request-recorder"; module = import ./otel-fleet/request-recorder.nix { inherit packages; }; }
    { name = "log-store"; module = ./log-store/default.nix; }
    { name = "cloudwatch"; module = import ./cloudwatch/default.nix { inherit packages; }; }
    { name = "security-audit"; module = ./security-audit.nix; }
    { name = "access"; module = ./access.nix; }
    { name = "fleet-firewall"; module = ./fleet-firewall.nix; }
    { name = "fleet-addresses"; module = ./fleet-addresses.nix; }
    { name = "runtime-firewall"; module = ./runtime-firewall.nix; }
    { name = "tailscale"; module = ./tailscale.nix; }
    { name = "underclass"; module = import ./underclass.nix { inherit packages; }; }
    { name = "remote-builders"; module = ./remote-builders.nix; }
    { name = "nix-cache"; module = ./nix-cache.nix; }
    { name = "fleet-network"; module = ./fleet-network.nix; }
    { name = "nix-gc"; module = ./nix-gc.nix; }
    { name = "nix-compact"; module = import ./nix-compact.nix { inherit nixCompact; }; }
    { name = "sysctl"; module = ./sysctl.nix; }
    { name = "marshall"; module = import ./marshall.nix { inherit packages; }; }
    { name = "lilly"; module = import ./lilly.nix { inherit packages; }; }
    { name = "porsche"; module = import ./porsche.nix { inherit packages; }; }
    { name = "audi-private"; module = import ./audi-private.nix { inherit packages; }; }
    { name = "ziggy"; module = import ./ziggy.nix { inherit packages; }; }
    { name = "galileo"; module = import ./galileo.nix { inherit packages; }; }
    { name = "peach"; module = import ./peach.nix { inherit packages; }; }
    { name = "enrico"; module = import ./enrico.nix { inherit packages; }; }
    { name = "susan"; module = import ./susan.nix { inherit packages; }; }
    { name = "audi"; module = import ./audi.nix { inherit packages; }; }
    { name = "proxy"; module = ./proxy.nix; }
    { name = "runtime-socket"; module = ./runtime-socket.nix; }
    { name = "acme"; module = ./acme/default.nix; }
    { name = "secrets"; module = import ./secrets/default.nix { inherit packages; }; }
    { name = "auto-update"; module = import ./auto-update/default.nix { inherit packages; }; }
  ];
  names = map (entry: entry.name) catalog;
  unknown = builtins.filter (name: !(builtins.elem name names)) only;
in
assert only == null || unknown == [ ]
  || throw "system catalog: unknown modules ${builtins.concatStringsSep ", " unknown}";
{
  imports = map (entry: entry.module)
    (builtins.filter (entry: only == null || builtins.elem entry.name only) catalog);
}
