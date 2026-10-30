# @cc [owner:ghuntley,label:security;deployment] fleet-service-roster
# Every service reached over the fleet tunnel MUST be declared here once with
# its placement and its port name from ports.nix. The tunnel firewall MUST
# admit exactly the ports of the services placed on a host, and fleet-internal
# DNS names MUST resolve to the deployment's control-plane tunnel address.
# Placement is "controlPlane" (the deployment's control plane), "everyHost",
# or an explicit list of roster host names.
{ lib
, ports ? import ./ports.nix { }
, roster ? import ./hosts.nix { inherit lib; }
, services ? {
    otlp = { placement = "controlPlane"; port = ports.otlpGrpc; };
    marshallFleet = { placement = "controlPlane"; port = ports.marshallFleet; };
    enrico = { placement = "controlPlane"; port = ports.enrico; dnsName = "enrico.fleet.internal"; };
    logStore = { placement = "controlPlane"; port = ports.logStore; dnsName = "logs.fleet.internal"; };
    otelMetrics = { placement = "everyHost"; port = ports.otelMetrics; };
    loggingHealth = { placement = "everyHost"; port = ports.loggingHealth; };
    susan = { placement = [ "salopettes" ]; port = ports.https; };
  }
}:
let
  placedOn = host: service: let deployment = roster.deploymentOf host; in
    if service.placement == "everyHost" then true
    else if service.placement == "controlPlane" then deployment.controlPlane == host
    else builtins.elem host service.placement;
  portValues = builtins.attrValues ports;
  validPlacement = placement: builtins.elem placement [ "controlPlane" "everyHost" ]
    || (builtins.isList placement && placement != [] && lib.all (host: roster.hosts ? ${host}) placement);
in
assert lib.assertMsg (lib.all (service: validPlacement service.placement && builtins.elem service.port portValues
  && (!(service ? dnsName) || builtins.match "[a-z][a-z0-9-]*\\.fleet\\.internal" service.dnsName != null))
  (builtins.attrValues services)) "Fleet service roster: unknown placement, unnamed port or invalid fleet DNS name";
assert lib.assertMsg (let placed = lib.concatMap (service: map (host: { inherit host; inherit (service) port; })
    (lib.filter (host: placedOn host service) (lib.concatMap (deployment: builtins.attrNames deployment.tunnel)
      (builtins.attrValues roster.deployments)))) (builtins.attrValues services);
  in builtins.length placed == builtins.length (lib.unique placed))
  "Fleet service roster: two services share a port on one host";
{
  inherit services;
  # Tunnel TCP ports a host admits, in ascending order.
  tunnelPorts = host: builtins.sort builtins.lessThan
    (map (service: service.port) (lib.filter (placedOn host) (builtins.attrValues services)));
  # Host-owned log sources shipped to the fleet log store; audit, firecracker
  # and guest content are excluded by omission.
  logSources = [
    "marshall" "lilly" "porsche" "audi" "ziggy" "enrico" "brady" "galileo" "underclass"
    "haproxy" "auth" "kernel" "storage" "mail" "operations" "system"
  ];
}
