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
  # Panterloons serves the Buck2 NativeLink cache and reads it (ADR-0272).
  overalls.buckRemoteCache = (import ../../buck-re.nix { inherit lib; }).forHost "panterloons";
}
