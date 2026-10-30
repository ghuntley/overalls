# The fleet roster (nix/policy/fleet) accepts the reviewed fleet and rejects
# each malformed shape its assertions guard: duplicate ports, unknown or
# non-reciprocal peers, misplaced control planes and unknown hosts.
{ pkgs }:
let
  inherit (pkgs) lib;
  policy = ../../../policy/fleet;
  portsOf = args: import (policy + "/ports.nix") args;
  rosterOf = args: import (policy + "/hosts.nix") ({ inherit lib; } // args);
  servicesOf = args: import (policy + "/services.nix") ({ inherit lib; } // args);
  ports = portsOf { };
  roster = rosterOf { };
  fleetServices = servicesOf { };
  base = roster.deployments.panterloons;
  # Each case forces the whole result so lazily evaluated assertions fire.
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  withTunnel = tunnel: { panterloons = base // { tunnel = base.tunnel // tunnel; }; };
  withDeployment = changes: { panterloons = base // changes; };
  rejectsDeployments = deployments: rejects (rosterOf { inherit deployments; });
  cases = {
    accepts-reviewed-fleet = builtins.deepSeq [ ports roster fleetServices ] true;
    host-names-match-declarations = builtins.attrNames roster.hosts == [ "dungarees" "panterloons" "salopettes" ];
    control-plane-ports = fleetServices.tunnelPorts "panterloons" == [ 4317 5443 5445 8443 9464 9467 ];
    relay-ports = fleetServices.tunnelPorts "salopettes" == [ 443 9464 9467 ];
    worker-ports = fleetServices.tunnelPorts "dungarees" == [ 9464 9467 ];
    unknown-tunnel-host = rejects (roster.deploymentOf "absent");
    duplicate-port = rejects (portsOf { ports = ports // { duplicate = ports.enrico; }; });
    out-of-range-port = rejects (portsOf { ports = ports // { invalid = 65536; }; });
    undeclared-host = rejects (rosterOf { hosts = roster.hosts // { absent = { tailnetAddress = null; builder = null; }; }; });
    missing-host = rejects (rosterOf { hosts = builtins.removeAttrs roster.hosts [ "salopettes" ]; });
    duplicate-tailnet = rejects (rosterOf { hosts = roster.hosts // {
      dungarees = roster.hosts.dungarees // { tailnetAddress = roster.hosts.panterloons.tailnetAddress; }; }; });
    builder-without-tailnet = rejects (rosterOf { hosts = roster.hosts // {
      dungarees = roster.hosts.dungarees // { tailnetAddress = null; }; }; });
    non-reciprocal-peer = rejectsDeployments (withTunnel { dungarees = base.tunnel.dungarees // { peers = [ "panterloons" "salopettes" ]; }; });
    unknown-peer = rejectsDeployments (withTunnel { dungarees = base.tunnel.dungarees // { peers = [ "panterloons" "absent" ]; }; });
    unknown-endpoint = rejectsDeployments (withTunnel { dungarees = base.tunnel.dungarees // { endpoint = "absentPrimary"; }; });
    duplicate-tunnel-address = rejectsDeployments (withTunnel { salopettes = base.tunnel.salopettes // { address = "10.90.0.2"; }; });
    outside-tunnel-prefix = rejectsDeployments (withTunnel { salopettes = base.tunnel.salopettes // { address = "10.90.1.3"; }; });
    misplaced-control-plane = rejectsDeployments (withDeployment { controlPlane = "dungarees"; });
    misplaced-worker = rejectsDeployments (withDeployment { telemetry = { central = "panterloons"; worker = "salopettes"; }; });
    builder-free-participant = rejectsDeployments (withDeployment { builds = base.builds // { participants = [ "panterloons" "salopettes" ]; }; });
    scheduler-outside-participants = rejectsDeployments (withDeployment { builds = base.builds // { participants = [ "dungarees" ]; }; });
    host-in-two-deployments = rejectsDeployments (withTunnel { } // { copy = base; });
    unnamed-service-port = rejects (servicesOf { services = fleetServices.services // { extra = { placement = "everyHost"; port = 1; }; }; });
    unknown-placement = rejects (servicesOf { services = fleetServices.services // { extra = { placement = [ "absent" ]; port = ports.audiRelay; }; }; });
    shared-host-port = rejects (servicesOf { services = fleetServices.services // { extra = { placement = "controlPlane"; port = ports.enrico; }; }; });
    invalid-dns-name = rejects (servicesOf { services = fleetServices.services // {
      enrico = fleetServices.services.enrico // { dnsName = "enrico.example.test"; }; }; });
  };
in
assert lib.assertMsg (lib.all (v: v) (lib.attrValues cases))
  ("Fleet roster evaluation failed: " + lib.concatStringsSep "," (lib.attrNames (lib.filterAttrs (_: v: !v) cases)));
pkgs.writeText "fleet-roster-evaluation.json" (builtins.toJSON cases)
