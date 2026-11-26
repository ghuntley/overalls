{ ... }:
{
  # Overalls replaces the lost Panterloons and Dungarees (ADR-0284): one
  # on-premises control plane with its own database, secrets and fleet tunnel,
  # serving as the sole Lilly host. It has no telemetry worker and no build
  # delegation (the roster declares builds = null).
  imports = [ ../../roles/control-plane/configuration.nix ];
  overalls.controlPlaneHost = {
    # The administrative address comes from the fleet host roster
    # (nix/policy/fleet/hosts.nix) once the host joins the tailnet.
    name = "overalls";
    # No other Audi DNS replica exists in this deployment.
    peerNameservers = [ ];
    # First activation (ADR-0246 two-stage flow): Porsche, Audi, Ziggy,
    # Galileo, Brady and guest telemetry intake wait for this deployment's own
    # Marshall to issue their credentials.
    bootstrap = true;
  };
}
