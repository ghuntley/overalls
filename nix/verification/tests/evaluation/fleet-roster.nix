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
  # A synthetic fleet with a worker and build delegation keeps every guarded
  # shape covered while the production deployment has neither (ADR-0284).
  fixtureInventory = { central = { }; worker = { }; relay = { }; };
  fixtureHosts = {
    central = { tailnetAddress = "100.64.0.1"; builder.logicalCpus = 8; };
    worker = { tailnetAddress = "100.64.0.2"; builder.logicalCpus = 8; };
    relay = { tailnetAddress = null; builder = null; };
  };
  base = {
    controlPlane = "central";
    telemetry = { central = "central"; worker = "worker"; };
    builds = { scheduler = "central"; participants = [ "central" "worker" ]; };
    tunnel = {
      central = { address = "10.90.0.1"; endpoint = "overallsPrimary"; peers = [ "worker" "relay" ]; };
      worker = { address = "10.90.0.2"; endpoint = "overallsService"; peers = [ "central" ]; };
      relay = { address = "10.90.0.3"; endpoint = "salopettesPrimary"; peers = [ "central" ]; };
    };
  };
  fixtureOf = args: rosterOf ({ inventory = fixtureInventory; hosts = fixtureHosts; deployments = { fixture = base; }; } // args);
  fixture = fixtureOf { };
  fixtureServices = servicesOf { roster = fixture; services = fleetServices.services // {
    susan = fleetServices.services.susan // { placement = [ "relay" ]; }; }; };
  # Each case forces the whole result so lazily evaluated assertions fire.
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  withTunnel = tunnel: { fixture = base // { tunnel = base.tunnel // tunnel; }; };
  withDeployment = changes: { fixture = base // changes; };
  rejectsDeployments = deployments: rejects (fixtureOf { inherit deployments; });
  cases = {
    accepts-reviewed-fleet = builtins.deepSeq [ ports roster fleetServices ] true;
    accepts-fixture-fleet = builtins.deepSeq [ fixture fixtureServices ] true;
    host-names-match-declarations = builtins.attrNames roster.hosts == [ "overalls" "salopettes" ];
    control-plane-ports = fleetServices.tunnelPorts "overalls" == [ 4317 5443 5445 8443 9464 9467 ];
    relay-ports = fleetServices.tunnelPorts "salopettes" == [ 443 9464 9467 ];
    worker-ports = fixtureServices.tunnelPorts "worker" == [ 9464 9467 ];
    no-build-delegation = roster.deployments.overalls.builds == null;
    unknown-tunnel-host = rejects (roster.deploymentOf "absent");
    duplicate-port = rejects (portsOf { ports = ports // { duplicate = ports.enrico; }; });
    out-of-range-port = rejects (portsOf { ports = ports // { invalid = 65536; }; });
    undeclared-host = rejects (rosterOf { hosts = roster.hosts // { absent = { tailnetAddress = null; builder = null; }; }; });
    missing-host = rejects (rosterOf { hosts = builtins.removeAttrs roster.hosts [ "salopettes" ]; });
    duplicate-tailnet = rejects (fixtureOf { hosts = fixtureHosts // {
      worker = fixtureHosts.worker // { tailnetAddress = fixtureHosts.central.tailnetAddress; }; }; });
    builder-without-tailnet = rejects (fixtureOf { hosts = fixtureHosts // {
      worker = fixtureHosts.worker // { tailnetAddress = null; }; }; });
    non-reciprocal-peer = rejectsDeployments (withTunnel { worker = base.tunnel.worker // { peers = [ "central" "relay" ]; }; });
    unknown-peer = rejectsDeployments (withTunnel { worker = base.tunnel.worker // { peers = [ "central" "absent" ]; }; });
    unknown-endpoint = rejectsDeployments (withTunnel { worker = base.tunnel.worker // { endpoint = "absentPrimary"; }; });
    duplicate-tunnel-address = rejectsDeployments (withTunnel { relay = base.tunnel.relay // { address = "10.90.0.2"; }; });
    outside-tunnel-prefix = rejectsDeployments (withTunnel { relay = base.tunnel.relay // { address = "10.90.1.3"; }; });
    misplaced-control-plane = rejectsDeployments (withDeployment { controlPlane = "worker"; });
    misplaced-worker = rejectsDeployments (withDeployment { telemetry = { central = "central"; worker = "relay"; }; });
    builder-free-participant = rejectsDeployments (withDeployment { builds = base.builds // { participants = [ "central" "relay" ]; }; });
    scheduler-outside-participants = rejectsDeployments (withDeployment { builds = base.builds // { participants = [ "worker" ]; }; });
    accepts-no-builds = !(rejectsDeployments (withDeployment { builds = null; }));
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
