{ lib, ... }:
{
  # Panterloons is a separate copy of the Overalls deployment (ADR-0246) with
  # its own database, secrets and fleet tunnel; Dungarees is its worker.
  imports = [ ../../roles/control-plane/configuration.nix ];
  overalls.controlPlaneHost = {
    # The administrative address and telemetry worker come from the fleet
    # host roster (nix/policy/fleet/hosts.nix).
    name = "panterloons";
    # Dungarees is a gateway peer in its tunnel, as it was for Overalls.
    audiRelay = true;
  };
  # Panterloons runs the fleet tribuchet hub and a worker (ADR-0248).
  overalls.fleetBuilds = {
    enable = true;
    localName = "panterloons";
  } // import ../../fleet-builds.nix { inherit lib; };
  # The NativeLink cache, scheduler and worker (ADR-0272) are retired:
  # Namespace is the Buck2 cache and remote-execution backend (ADR-0276).
  # The module and fleet/buck-re.nix stay for reactivation.
}
