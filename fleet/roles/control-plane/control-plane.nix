{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.overalls.controlPlaneHost;
  roster = import ../../../nix/policy/fleet/hosts.nix { inherit lib; };
  deployment = lib.findFirst (candidate: candidate.controlPlane == cfg.name) null (builtins.attrValues roster.deployments);
  name = types.strMatching "[a-z][a-z0-9-]*";
  addressName = types.strMatching "[a-z][A-Za-z0-9]*";
in
{
  # @cc [owner:ghuntley,label:deployment;security] control-plane-host-identity
  # The Overalls host roles MUST serve exactly one deployment, named here. Its
  # SOPS documents, fleet address files, administrative address and telemetry
  # roster MUST all derive from these values so a copied deployment (ADR-0246)
  # never reads another deployment's secrets or binds another host's address.
  options.overalls.controlPlaneHost = {
    name = mkOption {
      type = name;
      description = "Host name; selects `secrets/<name>-*.enc.json` and the `<name>Primary`/`<name>Service` address files.";
    };
    peerNameservers = mkOption {
      type = types.listOf addressName;
      default = [ "dungareesService" ];
      description = "Fleet address names of the other Audi DNS replicas used by the wildcard issuer.";
    };
    adminAddress = mkOption {
      type = types.strMatching "100\\.[0-9]+\\.[0-9]+\\.[0-9]+";
      default = roster.hosts.${cfg.name}.tailnetAddress or (throw "Control-plane host ${cfg.name} has no roster tailnet address");
      defaultText = lib.literalExpression "(import nix/policy/fleet/hosts.nix { inherit lib; }).hosts.\${name}.tailnetAddress";
      description = "This host's Tailscale address, the only listener for administrative SSH.";
    };
    otelWorker = mkOption {
      type = types.nullOr name;
      default = if deployment == null then null else deployment.telemetry.worker;
      defaultText = lib.literalMD "the fleet host roster's telemetry worker for this control plane, or null";
      description = "The deployment's telemetry worker host, or null when the host observes only itself.";
    };
    bootstrap = mkOption {
      type = types.bool;
      default = false;
      description = ''
        First activation of a new deployment, before its own Marshall can bind
        Lilly and issue Porsche, Audi, Ziggy and Galileo credentials: those
        roles, Brady and guest telemetry intake stay off, and administrative SSH
        keeps the base host's port 22.
      '';
    };
    audiRelay = mkOption {
      type = types.bool;
      default = false;
      description = "Whether Audi relays through a gateway peer in the deployment's tunnel.";
    };
  };
}
