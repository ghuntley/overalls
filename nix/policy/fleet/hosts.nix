# @cc [owner:ghuntley,label:deployment;security] fleet-host-roster
# Fleet roles, tunnel membership and reachability MUST be declared here once
# and read by the fleet tunnel, remote-builder, fleet-build, build-cache,
# telemetry and control-plane consumers. Every roster host MUST have a reviewed host.json
# declaration (fleet/hosts/NAME) and every declared host MUST appear here.
# Each deployment owns one tunnel (ADR-0239, ADR-0246): tunnel addresses repeat
# across deployments, peers MUST be reciprocal members of the same tunnel, and
# the control plane and central telemetry host MUST hold 10.90.0.1 and the
# telemetry worker 10.90.0.2. Address literals for public endpoints MUST NOT
# appear; endpoints name entries of nix/policy/network/fleet-addresses.nix.
{ lib
  # Reviewed host declarations; every roster host MUST have one and vice versa.
, inventory ? (import ../../platform/hosts/inventory.nix { inherit lib; }).hosts
  # Per-host reachability outside the fleet tunnel. CPU counts are measured
  # with nproc --all over inventory-pinned administrative SSH. Guest budgets
  # are not CPU discovery. Builders are reached over Tailscale so no public
  # address is evaluated; a host joins the tailnet only after enrollment.
, hosts ? {
    overalls = { tailnetAddress = null; builder = null; };
    salopettes = { tailnetAddress = null; builder = null; };
  }
  # Each deployment's roles and its own fleet tunnel. A deployment without
  # build delegation (ADR-0248) declares builds = null.
, deployments ? {
    # Overalls is the control plane, sole Lilly host and central telemetry
    # host after Panterloons and Dungarees were lost (ADR-0284). Salopettes
    # hosts the Susan relay (ADR-0224) and stays a tunnel member with no peer
    # until it is re-peered with Overalls.
    overalls = {
      controlPlane = "overalls";
      telemetry = { central = "overalls"; worker = null; };
      builds = null;
      tunnel = {
        overalls = { address = "10.90.0.1"; endpoint = "overallsPrimary"; peers = [ ]; };
        salopettes = { address = "10.90.0.3"; endpoint = "salopettesPrimary"; peers = [ ]; };
      };
    };
  }
}:
let
  addressNames = import ../network/fleet-addresses.nix;
  controlPlaneAddress = "10.90.0.1";
  workerAddress = "10.90.0.2";

  unique = values: builtins.length values == builtins.length (lib.unique values);
  isTunnelAddress = address: builtins.isString address
    && builtins.match "10\\.90\\.0\\.([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])" address != null;
  isTailnetAddress = address: address == null
    || (builtins.isString address && builtins.match "100\\.[0-9]+\\.[0-9]+\\.[0-9]+" address != null);
  members = lib.concatMap (deployment: builtins.attrNames deployment.tunnel) (builtins.attrValues deployments);
  tailnetAddresses = lib.filter (address: address != null) (map (host: host.tailnetAddress) (builtins.attrValues hosts));
  validDeployment = name: deployment: let
    tunnel = deployment.tunnel;
    inTunnel = host: tunnel ? ${host};
    builds = deployment.builds;
  in
    assert lib.assertMsg (lib.all (host: lib.all (peer: inTunnel peer && peer != host
      && builtins.elem host tunnel.${peer}.peers) tunnel.${host}.peers) (builtins.attrNames tunnel))
      "Fleet deployment ${name}: tunnel peers must be reciprocal members of the same tunnel";
    assert lib.assertMsg (lib.all (member: isTunnelAddress member.address && addressNames ? ${member.endpoint})
      (builtins.attrValues tunnel)) "Fleet deployment ${name}: invalid tunnel address or unknown endpoint name";
    assert lib.assertMsg (unique (map (member: member.address) (builtins.attrValues tunnel)))
      "Fleet deployment ${name}: duplicate tunnel address";
    assert lib.assertMsg (inTunnel deployment.controlPlane && tunnel.${deployment.controlPlane}.address == controlPlaneAddress)
      "Fleet deployment ${name}: the control plane must hold ${controlPlaneAddress}";
    assert lib.assertMsg (deployment.telemetry.central == deployment.controlPlane
      && (deployment.telemetry.worker == null
        || (inTunnel deployment.telemetry.worker && tunnel.${deployment.telemetry.worker}.address == workerAddress)))
      "Fleet deployment ${name}: central telemetry is the control plane and the worker holds ${workerAddress}";
    assert lib.assertMsg (builds == null || (builds.participants != [] && unique builds.participants
      && lib.all (host: inTunnel host && hosts.${host}.builder != null) builds.participants
      && builtins.elem builds.scheduler builds.participants))
      "Fleet deployment ${name}: build participants must be tunnel members with builder capacity, including the scheduler";
    true;
in
assert lib.assertMsg (builtins.attrNames hosts == builtins.attrNames inventory)
  "Fleet host roster and reviewed host declarations (fleet/hosts) must name the same hosts";
assert lib.assertMsg (lib.all (host: isTailnetAddress host.tailnetAddress
  && (host.builder == null || (builtins.isInt host.builder.logicalCpus && host.builder.logicalCpus > 0)))
  (builtins.attrValues hosts)) "Fleet host roster: invalid tailnet address or builder capacity";
assert lib.assertMsg (lib.all (host: host.builder == null || host.tailnetAddress != null) (builtins.attrValues hosts))
  "Fleet host roster: builders are reached over Tailscale and need a tailnet address";
assert lib.assertMsg (unique tailnetAddresses) "Fleet host roster: duplicate tailnet address";
assert lib.assertMsg (unique members && lib.all (host: hosts ? ${host}) members)
  "Fleet host roster: every tunnel member is a known host in exactly one deployment";
assert lib.all (name: validDeployment name deployments.${name}) (builtins.attrNames deployments);
{
  inherit hosts deployments controlPlaneAddress workerAddress;
  # The dedicated fleet tunnel prefix shared by every deployment.
  prefix = "10.90.0.0/24";
  # The deployment whose tunnel contains a host, or a throw for a host in none.
  deploymentOf = host: lib.findFirst (deployment: deployment.tunnel ? ${host})
    (throw "Host ${host} is in no fleet network") (builtins.attrValues deployments);
}
