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
  # Per-host reachability outside the fleet tunnel. CPU counts were measured
  # with nproc --all over inventory-pinned administrative SSH: the replacement
  # Dungarees and Panterloons on 2026-10-20. Guest budgets are not CPU discovery.
  # Builders are reached over Tailscale so no public address is evaluated.
, hosts ? {
    dungarees = { tailnetAddress = "100.96.244.44"; builder.logicalCpus = 96; };
    panterloons = { tailnetAddress = "100.98.214.120"; builder.logicalCpus = 96; };
    salopettes = { tailnetAddress = null; builder = null; };
  }
  # Each deployment's roles and its own fleet tunnel.
, deployments ? {
    # Panterloons is the control plane; Dungarees is its Lilly worker
    # (ADR-0246) and Salopettes hosts the Susan relay (ADR-0224).
    panterloons = {
      controlPlane = "panterloons";
      telemetry = { central = "panterloons"; worker = "dungarees"; };
      # Panterloons runs the tribuchet hub and the scheduler (ADR-0248).
      builds = { scheduler = "panterloons"; hub = "panterloons"; participants = [ "dungarees" "panterloons" ]; };
      # Panterloons serves the Buck2 cache and schedules remote execution;
      # readers hold read-only identities and workers run actions (ADR-0272).
      buildCache = { server = "panterloons"; readers = [ "dungarees" "panterloons" ]; workers = [ "dungarees" "panterloons" ]; };
      tunnel = {
        panterloons = { address = "10.90.0.1"; endpoint = "panterloonsPrimary"; peers = [ "dungarees" "salopettes" ]; };
        dungarees = { address = "10.90.0.2"; endpoint = "dungareesPrimary"; peers = [ "panterloons" ]; };
        # Salopettes reaches only Panterloons: Marshall delivers Susan pokes over fleet0.
        salopettes = { address = "10.90.0.3"; endpoint = "salopettesPrimary"; peers = [ "panterloons" ]; };
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
    participants = deployment.builds.participants;
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
    assert lib.assertMsg (participants != [] && unique participants && lib.all (host: inTunnel host && hosts.${host}.builder != null) participants
      && builtins.elem deployment.builds.scheduler participants && builtins.elem deployment.builds.hub participants)
      "Fleet deployment ${name}: build participants must be tunnel members with builder capacity, including the scheduler and hub";
    assert lib.assertMsg (let cache = deployment.buildCache or null; in cache == null
      || (lib.all (host: inTunnel host && hosts.${host}.tailnetAddress != null) ([ cache.server ] ++ cache.readers ++ cache.workers or [])
        && unique cache.readers && unique (cache.workers or [])
        && lib.all (host: hosts.${host}.builder != null) (cache.workers or [])))
      "Fleet deployment ${name}: the build cache server, readers and workers must be tunnel members with tailnet addresses, and workers need builder capacity";
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
